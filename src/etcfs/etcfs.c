/*
 * etcfs.c
 *
 *      This program is free software; you can redistribute it and/or
 *      modify it under the terms of the GNU General Public License
 *      version 2 as published by the Free Software Foundation.
 *
 * Copyright (c) 2013-2018 Daniel Thau <danthau@bedrocklinux.org>
 *
 * This program will pass filesystem requests through to either the global
 * stratum's instance of a file, or the calling process' local stratum instance
 * of a file.  It may also modify files as needed to enforce specific file
 * content, such as configuration file values.
 */

#define FUSE_USE_VERSION 32
#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fuse3/fuse.h>
#include <fuse3/fuse_lowlevel.h>
#include <linux/limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/xattr.h>
#include <unistd.h>

#define ARRAY_LEN(x) (sizeof(x) / sizeof(x[0]))
#define MIN(x, y) (x < y ? x : y)

#define STRATUM_XATTR "user.bedrock.stratum"
#define STRATUM_XATTR_LEN strlen(STRATUM_XATTR)

#define LPATH_XATTR "user.bedrock.localpath"
#define LPATH_XATTR_LEN strlen(LPATH_XATTR)

#define CFG_NAME ".bedrock-config-filesystem"
#define CFG_NAME_LEN strlen(CFG_NAME)

#define global_root "/proc/1/root/bedrock/strata/bedrock"

#define GLOBAL_STRATUM "global"

#define ROOTDIR "/"

#define CMD_ADD_GLOBAL "add_global"
#define CMD_ADD_GLOBAL_LEN strlen(CMD_ADD_GLOBAL)

#define CMD_RM_GLOBAL "rm_global"
#define CMD_RM_GLOBAL_LEN strlen(CMD_RM_GLOBAL)

#define CMD_ADD_OVERRIDE "add_override"
#define CMD_ADD_OVERRIDE_LEN strlen(CMD_ADD_OVERRIDE)

#define CMD_RM_OVERRIDE "rm_override"
#define CMD_RM_OVERRIDE_LEN strlen(CMD_RM_OVERRIDE)

/*
 * Various permissions related POSIX functions are per-process, not per thread.
 * The underlying Linux filesystem calls, however, are per-thread.  We can
 * bypass libc and directly talk to the kernel in order to set the desired
 * properties per thread.
 */
#ifdef SYS_setreuid32
#define SET_THREAD_EUID(euid) syscall(SYS_setreuid32, -1, euid)
#else
#define SET_THREAD_EUID(euid) syscall(SYS_setreuid, -1, euid)
#endif
#ifdef SYS_setregid32
#define SET_THREAD_EGID(egid) syscall(SYS_setregid32, -1, egid)
#else
#define SET_THREAD_EGID(egid) syscall(SYS_setregid, -1, egid)
#endif
#ifdef SYS_setgroups32
#define SET_THREAD_GROUPS(size, gids) syscall(SYS_setgroups32, size, gids)
#else
#define SET_THREAD_GROUPS(size, gids) syscall(SYS_setgroups, size, gids)
#endif

/*
 * The bulk of this program consists of filesystem calls which share a fair bit
 * of structure.
 */
#define FS_IMP_SETUP(path)                                                   \
	const char *const rpath = (path && path[1]) ? path + 1 : ".";        \
	if (SET_THREAD_EUID(0) < 0) {                                        \
		return -EPERM;                                               \
	}                                                                    \
	int ref_fd = get_ref_fd(path);                                       \
	if (ref_fd < 0) {                                                    \
		return -EDOM;                                                \
	}                                                                    \
	if (apply_override(ref_fd, path, rpath) < 0) {                       \
		return -ERANGE;                                              \
	}                                                                    \
	if (set_caller_permissions() < 0) {                                  \
		return -EPERM;                                               \
	}                                                                    \
	pthread_rwlock_rdlock(&cfg_lock);                                    \
	int rv;

#define FS_IMP_RETURN(rv)                                                    \
	pthread_rwlock_unlock(&cfg_lock);                                    \
	return rv >= 0 ? rv : -errno

#define DISALLOW_ON_CFG(rpath)                                               \
	if (strcmp(rpath, CFG_NAME) == 0) {                                  \
		errno = EINVAL;                                              \
		FS_IMP_RETURN(-1);                                           \
	}

/*
 * Override type.
 */
enum o_type {
	TYPE_SYMLINK,
	TYPE_DIRECTORY,
	TYPE_INJECT,
};

const char *const o_type_str[] = {
	"symlink",
	"directory",
	"inject",
};

/*
 * Override the underlying contents at a given file path with something else.
 */
struct override {
	/*
	 * The filepath to overwrite.
	 */
	char *path;
	/*
	 * The type of overwrite operation desired.
	 */
	enum o_type type;
	/*
	 * The new content at the file path.
	 */
	char *content;
	size_t content_len;
	/*
	 * If the type is TYPE_INJECT, the content to inject.
	 */
	char *inject;
	size_t inject_len;
};

/*
 * File descriptors to which into filesystem calls will be directed
 */

/*
 * File descriptors referring to directories.
 */
int global_ref_fd = -1;
int local_ref_fd = -1;

/*
 * Paths which should be global.
 */
char **globals = NULL;
size_t global_cnt = 0;
size_t global_alloc = 0;

/*
 * Overrides
 */
struct override *overrides = NULL;
size_t override_cnt = 0;
size_t override_alloc = 0;

/*
 * Config file's stat information
 */
struct stat cfg_stat;

/*
 * The path onto which this filesystem is mounted.
 */
static char *mntpt = NULL;

/*
 * Local stratum name
 */
char local_name[PATH_MAX];

/*
 * Lock around configuration access.  The vast majority of config access is
 * non-conflicting read-only, and thus a read-write lock is preferred.
 */
pthread_rwlock_t cfg_lock;

/*
 * Set the thread's euid, egid, and grouplist to that of the
 * process calling a given FUSE filesystem call.
 *
 * This should be called at the beginning of every implemented filesystem call
 * before any internal filesystem calls are made.
 *
 * SET_THREAD_EUID(0) should be called before this function to ensure this
 * function has adequate permissions to run.
 */
static inline int set_caller_permissions(void)
{
	int rv;

	/*
	 * Set group list.  For performance, try on the stack before heap.
	 */
	gid_t list[64];
	if ((rv = fuse_getgroups(ARRAY_LEN(list), list)) < 0) {
		return rv;
	}
	if (rv <= (int)ARRAY_LEN(list)) {
		if ((rv = SET_THREAD_GROUPS(rv, list)) < 0) {
			return -errno;
		}
	} else {
		gid_t *list_heap = malloc(rv * sizeof(gid_t));
		if (list_heap == NULL) {
			return -ENOMEM;
		}
		int rv_heap;
		if ((rv_heap = fuse_getgroups(rv, list)) < 0) {
			free(list_heap);
			return rv;
		}
		if (rv_heap > rv) {
			free(list_heap);
			return -ENOMEM;
		}
		if ((rv = SET_THREAD_GROUPS(rv, list_heap)) < 0) {
			free(list_heap);
			return -errno;
		}
		free(list_heap);
	}

	/*
	 * Set euid and egid
	 */
	struct fuse_context *context = fuse_get_context();
	if ((rv = SET_THREAD_EGID(context->gid)) < 0) {
		return -errno;
	}
	if ((rv = SET_THREAD_EUID(context->uid)) < 0) {
		return -errno;
	}
	return 0;
}

static inline int get_ref_fd(const char *const path)
{
	/*
	 * Check if file is global
	 */
	for (size_t i = 0; i < global_cnt; i++) {
		if (strcmp(globals[i], path) == 0) {
			return global_ref_fd;
		}
	}

	return local_ref_fd;
}

/*
 * Linux fails to provide system calls which apply to file descriptors and
 * directly (without following) on symlinks.  For example, neither lgetxattr()
 * nor fgetxattr() have both of these attributes.  We can use /proc as a work
 * around to get a path dependent only on a file descriptor which can be fed
 * into system calls that do not follow symlinks (e.g. lgetxattr).
 */
static inline int procpath(const int fd, char *buf, size_t size)
{
	int s = snprintf(buf, size, "/proc/self/fd/%d", fd);
	if (s < 0 || s >= (int)size) {
		return -1;
	}
	return 0;
}

/*
 * Ensure a given file path contains a specific string.
 */
static int inject(int ref_dir, const char *rpath, const char *inject,
	const size_t inject_len)
{
	int fd = openat(ref_dir, rpath, O_RDWR);
	if (fd < 0) {
		return -1;
	}

	struct stat stbuf;
	if (fstat(fd, &stbuf) < 0) {
		close(fd);
		return -1;
	}
	size_t init_len = stbuf.st_size;

	/*
	 * If the file already contains the target contents, we can skip
	 * writing to disk.
	 */
	if (init_len >= inject_len) {
		char *content = mmap(NULL, init_len, PROT_READ, MAP_SHARED,
			fd, 0);
		if (content == MAP_FAILED) {
			close(fd);
			return -1;
		}

		char *match = memmem(content, init_len, inject,
			inject_len);

		if (match != NULL) {
			munmap(content, init_len);
			close(fd);
			return 0;
		}
		munmap(content, init_len);
	}

	if (lseek(fd, init_len, SEEK_SET) < 0) {
		close(fd);
		return -1;
	}
	if (write(fd, inject, inject_len) < 0) {
		close(fd);
		return -1;
	}

	close(fd);
	return 0;
}

/*
 * Remove up to one instance of a given string from a file.
 */
static int uninject(int ref_dir, const char *rpath, const char *inject,
	const size_t inject_len)
{
	int fd = openat(ref_dir, rpath, O_RDWR);

	struct stat stbuf;
	if (fstat(fd, &stbuf) < 0) {
		close(fd);
		return -1;
	}
	size_t init_len = stbuf.st_size;

	if (init_len < inject_len) {
		close(fd);
		return 0;
	}

	char *content = mmap(NULL, init_len, PROT_READ | PROT_WRITE,
		MAP_SHARED, fd, 0);
	if (content == MAP_FAILED) {
		close(fd);
		return -1;
	}

	char *match = memmem(content, init_len, inject, inject_len);

	if (match == NULL) {
		munmap(content, init_len);
		close(fd);
		return 0;
	}

	memmove(match, match + inject_len,
		init_len - (match - content) - inject_len);
	msync(content, init_len, MS_SYNC);
	munmap(content, init_len);

	ftruncate(fd, init_len - inject_len);
	close(fd);
	return 0;
}

/*
 * Requires root.
 */
static inline int apply_override(const int ref_fd, const char *const path,
	const char *const rpath)
{
	/*
	 * Find override
	 */
	size_t i = 0;
	for (; i < override_cnt; i++) {
		if (strcmp(overrides[i].path, path) == 0) {
			break;
		}
	}

	/*
	 * No override, nothing to do
	 */
	if (i == override_cnt) {
		return 0;
	}

	/*
	 * Enforce override
	 */
	int rv = 0;
	char buf[PATH_MAX];
	struct stat stbuf;

	pthread_rwlock_wrlock(&cfg_lock);

	switch (overrides[i].type) {
	case TYPE_SYMLINK:
		if (readlinkat(ref_fd, rpath, buf, sizeof(buf) - 1) >= 0
			&& strcmp(buf, overrides[i].content) == 0) {
			break;
		}
		unlinkat(ref_fd, rpath, 0);
		unlinkat(ref_fd, rpath, AT_REMOVEDIR);
		rv = symlinkat(overrides[i].content, ref_fd, rpath);
		break;

	case TYPE_DIRECTORY:
		if (fstatat(ref_fd, rpath, &stbuf, AT_SYMLINK_NOFOLLOW) >= 0
			&& S_ISDIR(stbuf.st_mode)) {
			break;
		}
		unlinkat(ref_fd, rpath, 0);
		unlinkat(ref_fd, rpath, AT_REMOVEDIR);
		rv = mkdirat(ref_fd, rpath, 0755);
		break;

	case TYPE_INJECT:
		if (fstatat(ref_fd, rpath, &stbuf, AT_SYMLINK_NOFOLLOW) < 0
			|| !S_ISREG(stbuf.st_mode)) {
			break;
		}
		rv = inject(ref_fd, rpath, overrides[i].inject,
			overrides[i].inject_len);
		break;
	}

	pthread_rwlock_unlock(&cfg_lock);
	return rv;
}

static int cfg_add_global(const char *const buf, size_t size)
{
	/*
	 * Ensure there is a trailing null so that sscanf doesn't overflow if
	 * we get bad input.
	 */
	char nbuf[PIPE_BUF];
	if (size > sizeof(nbuf) - 1) {
		return -ENAMETOOLONG;
	}
	memcpy(nbuf, buf, size);
	nbuf[size] = '\0';

	/*
	 * Tokenize
	 */
	char buf_cmd[PIPE_BUF];
	char space;
	char buf_global[PIPE_BUF];
	char newline;
	if (sscanf(nbuf, "%s%c%s%c", buf_cmd, &space, buf_global,
			&newline) != 4) {
		return -EINVAL;
	}

	/*
	 * Sanity check
	 */
	if (strcmp(buf_cmd, CMD_ADD_GLOBAL) != 0 || space != ' ' ||
		newline != '\n' || strchr(buf_global, '/') == NULL) {
		return -EINVAL;
	}

	/*
	 * Don't double add.
	 */
	for (size_t i = 0; i < global_cnt; i++) {
		if (strcmp(globals[i], buf_global) == 0) {
			return 0;
		}
	}

	if (global_alloc < global_cnt + 1) {
		char **new_globals = realloc(globals, (global_cnt + 1) *
			sizeof(char *));
		if (new_globals == NULL) {
			return -ENOMEM;
		}
		globals = new_globals;
		global_alloc = global_cnt + 1;
	}

	char *global = malloc(strlen(buf_global) + 1);
	if (global == NULL) {
		return -ENOMEM;
	}
	strcpy(global, buf_global);

	globals[global_cnt] = global;
	global_cnt++;

	cfg_stat.st_size += strlen("global ") + strlen(global) + strlen("\n");

	return size;
}

static int cfg_rm_global(const char *const buf, size_t size)
{
	/*
	 * Ensure there is a trailing null so that sscanf doesn't overflow if
	 * we get bad input.
	 */
	char nbuf[PIPE_BUF];
	if (size > sizeof(nbuf) - 1) {
		return -ENAMETOOLONG;
	}
	memcpy(nbuf, buf, size);
	nbuf[size] = '\0';

	/*
	 * Tokenize
	 */
	char buf_cmd[PIPE_BUF];
	char space;
	char buf_global[PIPE_BUF];
	char newline;
	if (sscanf(nbuf, "%s%c%s%c", buf_cmd, &space, buf_global,
			&newline) != 4) {
		return -EINVAL;
	}

	/*
	 * Sanity check
	 */
	if (strcmp(buf_cmd, CMD_RM_GLOBAL) != 0 || space != ' ' ||
		newline != '\n' || strchr(buf_global, '/') == NULL) {
		return -EINVAL;
	}

	size_t i;
	for (i = 0; i < global_cnt; i++) {
		if (strcmp(globals[i], buf_global) == 0) {
			break;
		}
	}
	if (i == global_cnt) {
		return size;
	}

	cfg_stat.st_size -= strlen("global ") + strlen(globals[i]) +
		strlen("\n");

	free(globals[i]);
	global_cnt--;

	if (i != global_cnt) {
		globals[i] = globals[global_cnt];
	}

	return size;
}

static int cfg_add_override(const char *const buf, size_t size)
{
	/*
	 * Ensure there is a trailing null so that sscanf doesn't overflow if
	 * we get bad input.
	 */
	char nbuf[PIPE_BUF];
	if (size > sizeof(nbuf) - 1) {
		return -ENAMETOOLONG;
	}
	memcpy(nbuf, buf, size);
	nbuf[size] = '\0';

	/*
	 * Tokenize
	 */
	char buf_cmd[PIPE_BUF];
	char space1;
	char buf_type[PIPE_BUF];
	char space2;
	char buf_path[PIPE_BUF];
	char space3;
	char buf_content[PIPE_BUF];
	char newline;
	if (sscanf(nbuf, "%s%c%s%c%s%c%s%c", buf_cmd, &space1, buf_type,
			&space2, buf_path, &space3, buf_content,
			&newline) != 8) {
		return -EINVAL;
	}

	/*
	 * Sanity check
	 */
	if (strcmp(buf_cmd, CMD_ADD_OVERRIDE) != 0 || space1 != ' ' ||
		space2 != ' ' || space3 != ' ' || newline != '\n' ||
		strchr(buf_path, '/') == NULL) {
		return -EINVAL;
	}

	/*
	 * Determine type
	 */
	enum o_type type = ARRAY_LEN(o_type_str);
	for (size_t i = 0; i < ARRAY_LEN(o_type_str); i++) {
		if (strcmp(buf_type, o_type_str[i]) == 0) {
			type = i;
			break;
		}
	}
	if (type == ARRAY_LEN(o_type_str)) {
		return -EINVAL;
	}

	int fd = -1;
	char *path = NULL;
	char *content = NULL;
	char *inject = NULL;
	size_t inject_len = 0;

	if (type == TYPE_INJECT) {
		fd = open(buf_content, O_RDONLY);
		struct stat stbuf;
		if (fstat(fd, &stbuf) < 0) {
			goto free_and_abort_enomem;
		}
		inject_len = stbuf.st_size;
		inject = malloc(inject_len + 1);
		if (inject == NULL) {
			goto free_and_abort_enomem;
		}
		if (read(fd, inject, inject_len) != (ssize_t) inject_len) {
			goto free_and_abort_enomem;
		}
		inject[inject_len] = '\0';
		close(fd);
	} else {
		inject = NULL;
	}

	if (type == TYPE_INJECT) {
		for (size_t i = 0; i < override_cnt; i++) {
			if (strcmp(overrides[i].path, buf_path) != 0) {
				continue;
			}
			if (overrides[i].type != type) {
				continue;
			}
			/*
			 * double add inject indicates replace old content with
			 * new
			 */
			(void)uninject(local_ref_fd, overrides[i].path + 1,
				overrides[i].inject, overrides[i].inject_len);
			free(overrides[i].inject);
			overrides[i].inject = inject;
			overrides[i].inject_len = inject_len;
			return 0;
		}
	}

	/*
	 * Avoid duplicate entries
	 */
	for (size_t i = 0; i < override_cnt; i++) {
		if (strcmp(overrides[i].path, buf_path) == 0) {
			return 0;
		}
	}

	if (override_alloc < override_cnt + 1) {
		struct override *new_overrides = realloc(overrides,
			(override_cnt + 1) * sizeof(struct override));
		if (new_overrides == NULL) {
			goto free_and_abort_enomem;
		}
		overrides = new_overrides;
		override_alloc = override_cnt + 1;
	}

	path = malloc(strlen(buf_path) + 1);
	if (path == NULL) {
		goto free_and_abort_enomem;
	}
	strcpy(path, buf_path);

	content = malloc(strlen(buf_content) + 1);
	if (content == NULL) {
		goto free_and_abort_enomem;
	}
	strcpy(content, buf_content);

	overrides[override_cnt].path = path;
	overrides[override_cnt].type = type;
	overrides[override_cnt].content = content;
	overrides[override_cnt].content_len = strlen(content);
	overrides[override_cnt].inject = inject;
	overrides[override_cnt].inject_len = inject_len;
	override_cnt++;

	cfg_stat.st_size += strlen("override ") + strlen(o_type_str[type]) +
		strlen(" ") + strlen(path) + strlen(" ") + strlen(content) +
		strlen("\n");

	return size;

free_and_abort_enomem:
	if (content != NULL) {
		free(content);
	}
	if (path != NULL) {
		free(path);
	}
	if (inject != NULL) {
		free(inject);
	}
	if (fd > 0) {
		close(fd);
	}
	return -EINVAL;
}

static int cfg_rm_override(const char *const buf, size_t size)
{
	/*
	 * Ensure there is a trailing null so that sscanf doesn't overflow if
	 * we get bad input.
	 */
	char nbuf[PIPE_BUF];
	if (size > sizeof(nbuf) - 1) {
		return -ENAMETOOLONG;
	}
	memcpy(nbuf, buf, size);
	nbuf[size] = '\0';

	/*
	 * Tokenize
	 */
	char buf_cmd[PIPE_BUF];
	char space;
	char buf_path[PIPE_BUF];
	char newline;
	if (sscanf(nbuf, "%s%c%s%c", buf_cmd, &space, buf_path, &newline) != 4) {
		return -EINVAL;
	}

	/*
	 * Sanity check
	 */
	if (strcmp(buf_cmd, CMD_RM_OVERRIDE) != 0 || space != ' ' ||
		newline != '\n') {
		return -EINVAL;
	}

	size_t i;
	for (i = 0; i < override_cnt; i++) {
		if (strcmp(overrides[i].path, buf_path) == 0) {
			break;
		}
	}
	if (i == override_cnt) {
		return size;
	}

	if (overrides[i].type == TYPE_INJECT) {
		(void)uninject(local_ref_fd, overrides[i].path + 1,
			overrides[i].inject, overrides[i].inject_len);
	}

	cfg_stat.st_size -= strlen("override ") +
		strlen(o_type_str[overrides[i].type]) +
		strlen(" ") + strlen(overrides[i].path) + strlen(" ") +
		strlen(overrides[i].content) + strlen("\n");

	free(overrides[i].path);
	free(overrides[i].content);
	if (overrides[i].inject != NULL) {
		free(overrides[i].inject);
	}
	override_cnt--;

	if (i != override_cnt) {
		overrides[i] = overrides[override_cnt];
	}

	return size;
}

static int cfg_read(char *buf, size_t size, off_t offset)
{
	char *str = malloc(cfg_stat.st_size + 1);
	if (str == NULL) {
		return -ENOMEM;
	}
	memset(str, 0, cfg_stat.st_size);

	for (size_t i = 0; i < global_cnt; i++) {
		strcat(str, "global ");
		strcat(str, globals[i]);
		strcat(str, "\n");
	}
	for (size_t i = 0; i < override_cnt; i++) {
		strcat(str, "override ");
		strcat(str, o_type_str[overrides[i].type]);
		strcat(str, " ");
		strcat(str, overrides[i].path);
		strcat(str, " ");
		strcat(str, overrides[i].content);
		strcat(str, "\n");
	}

	int rv = MIN(strlen(str + offset), size);
	memcpy(buf, str + offset, rv);
	free(str);
	return rv;
}

static int m_getattr(const char *path, struct stat *stbuf,
	struct fuse_file_info *fi)
{
	(void)fi;

	FS_IMP_SETUP(path);

	if (strcmp(rpath, CFG_NAME) == 0) {
		*stbuf = cfg_stat;
		rv = 0;
	} else {
		rv = fstatat(ref_fd, rpath, stbuf, AT_SYMLINK_NOFOLLOW);
	}

	FS_IMP_RETURN(rv);
}

static int m_access(const char *path, int mask)
{
	FS_IMP_SETUP(path);
	DISALLOW_ON_CFG(rpath);

	/*
	 * TODO: musl does not currently support AT_SYMLINK_NOFOLLOW on
	 * faccessat.  Ask them to add support then utilize it, if possible.
	 */
	rv = faccessat(ref_fd, rpath, mask, AT_EACCESS);

	FS_IMP_RETURN(rv);
}

static int m_readlink(const char *path, char *buf, size_t size)
{
	FS_IMP_SETUP(path);
	DISALLOW_ON_CFG(rpath);

	ssize_t bytes_read = readlinkat(ref_fd, rpath, buf, size);
	if (bytes_read < 0 || (size_t) bytes_read >= size) {
		rv = -1;
	} else {
		rv = 0;
		buf[bytes_read] = '\0';
	}

	FS_IMP_RETURN(rv);
}

static int m_opendir(const char *path, struct fuse_file_info *fi)
{
	(void)fi;

	FS_IMP_SETUP(path);
	DISALLOW_ON_CFG(rpath);

	DIR *d;
	int fd = openat(ref_fd, rpath, O_DIRECTORY | O_RDONLY | O_NOFOLLOW);
	if (fd < 0) {
		rv = -1;
	} else if ((d = fdopendir(fd)) == NULL) {
		rv = -1;
	} else {
		rv = 0;
		closedir(d);
	}
	close(fd);

	FS_IMP_RETURN(rv);
}

static int m_readdir(const char *path, void *buf, fuse_fill_dir_t filler, off_t
	offset, struct fuse_file_info *fi, enum fuse_readdir_flags flags)
{
	(void)offset;
	(void)fi;
	(void)flags;

	FS_IMP_SETUP(path);
	DISALLOW_ON_CFG(rpath);

	size_t path_len = strlen(path);

	int dir_exists = 0;

	int fd = openat(global_ref_fd, rpath, O_DIRECTORY | O_RDONLY);
	DIR *d = fdopendir(fd);
	if (d) {
		dir_exists = 1;
		struct dirent *dir;
		while ((dir = readdir(d)) != NULL) {
			char full_path[PATH_MAX];
			int s = snprintf(full_path, sizeof(full_path),
				path[1] ? "%s/%s" : "%s%s", path, dir->d_name);
			if (s < 0 || s >= (int)sizeof(full_path)) {
				continue;
			}
			for (size_t i = 0; i < global_cnt; i++) {
				if (strcmp(full_path, globals[i]) == 0) {
					filler(buf, dir->d_name, NULL, 0, 0);
					break;
				}
			}
		}
		closedir(d);
	}
	if (fd >= 0) {
		close(fd);
	}

	for (size_t i = 0; i < override_cnt; i++) {
		if (overrides[i].type == TYPE_INJECT) {
			continue;
		}
		if (strncmp(overrides[i].path, path, path_len) != 0) {
			continue;
		}
		if (path[1] == '\0') {
			if (strchr(overrides[i].path + 1, '/') == NULL) {
				filler(buf, overrides[i].path + path_len, NULL,
					0, 0);
			}
		} else {
			if (overrides[i].path[path_len] != '/') {
				continue;
			}
			if (strchr(overrides[i].path + path_len + 1, '/')
				== NULL) {
				filler(buf, overrides[i].path + path_len + 1,
					NULL, 0, 0);
			}
		}
	}

	fd = openat(ref_fd, rpath, O_DIRECTORY | O_RDONLY);
	d = fdopendir(fd);
	if (d) {
		dir_exists = 1;
		struct dirent *dir;
		while ((dir = readdir(d)) != NULL) {
			char full_path[PATH_MAX];
			int s = snprintf(full_path, sizeof(full_path),
				path[1] ? "%s/%s" : "%s%s", path, dir->d_name);
			if (s < 0 || s >= (int)sizeof(full_path)) {
				continue;
			}
			int is_global = 0;
			for (size_t i = 0; i < global_cnt; i++) {
				if (strcmp(full_path, globals[i]) == 0) {
					is_global = 1;
					break;
				}
			}
			int is_override = 0;
			for (size_t i = 0; i < override_cnt; i++) {
				if (overrides[i].type == TYPE_INJECT) {
					continue;
				}
				if (strcmp(full_path, overrides[i].path) == 0) {
					is_override = 1;
					break;
				}
			}
			if (!is_global && !is_override &&
				strcmp(buf, CFG_NAME) != 0) {
				filler(buf, dir->d_name, NULL, 0, 0);
			}
		}
		closedir(d);
	}
	if (fd >= 0) {
		close(fd);
	}

	if (dir_exists) {
		rv = 0;
		if (path[1] == '\0') {
			filler(buf, CFG_NAME, NULL, 0, 0);
		}
	} else {
		rv = -1;
		errno = -ENOENT;
	}

	FS_IMP_RETURN(rv);
}

static int m_releasedir(const char *path, struct fuse_file_info *fi)
{
	(void)fi;

	FS_IMP_SETUP(path);
	(void)ref_fd;
	DISALLOW_ON_CFG(rpath);

	rv = 0;

	FS_IMP_RETURN(rv);
}

static int m_mknod(const char *path, mode_t mode, dev_t rdev)
{
	FS_IMP_SETUP(path);
	DISALLOW_ON_CFG(rpath);

	rv = mknodat(ref_fd, rpath, mode, rdev);

	FS_IMP_RETURN(rv);
}

static int m_mkdir(const char *path, mode_t mode)
{
	FS_IMP_SETUP(path);
	DISALLOW_ON_CFG(rpath);

	rv = mkdirat(ref_fd, rpath, mode);

	FS_IMP_RETURN(rv);
}

static int m_symlink(const char *symlink_string, const char *path)
{
	FS_IMP_SETUP(path);
	DISALLOW_ON_CFG(rpath);

	rv = symlinkat(symlink_string, ref_fd, rpath);

	FS_IMP_RETURN(rv);
}

static int m_unlink(const char *path)
{
	FS_IMP_SETUP(path);
	DISALLOW_ON_CFG(rpath);

	rv = unlinkat(ref_fd, rpath, 0);

	FS_IMP_RETURN(rv);
}

static int m_rmdir(const char *path)
{
	FS_IMP_SETUP(path);
	DISALLOW_ON_CFG(rpath);

	rv = unlinkat(ref_fd, rpath, AT_REMOVEDIR);

	FS_IMP_RETURN(rv);
}

/*
 * TODO: This overwrites the target location during the transfer, which means
 * an interrupted transfer could leave a corrupt target file, failing to uphold
 * rename() atomic properties.
 *
 * Alternative implementations to resolve this issue include:
 *
 * - Creating a temporary file in the target's directory, transferring into it,
 *   then rename()ing it.  With this pattern, the worst case scenario would be
 *   the creation of a partial duplicate file.  The main difficulty here is
 *   safely creating that temporary file.  tempnam() generates warnings about
 *   being unsafe, and the usual alternatives like mkstemp don't accept a
 *   target directory.
 * - open()ing with O_TMPFILE, populating, then linkat()ing the new file.  This
 *   will be ideal once AT_REPLACE support for linkat() lands, but at the moment
 *   it is not available.  This also bumps the kernel version requirement
 *   substantially.
 */
static int m_rename(const char *from, const char *to, unsigned int flags)
{
	FS_IMP_SETUP(from);
	int to_ref_fd = get_ref_fd(to);
	from = (from && from[1]) ? from + 1 : ".";
	to = (to && to[1]) ? to + 1 : ".";
	DISALLOW_ON_CFG(from);
	DISALLOW_ON_CFG(to);

	rv = -1;
	int from_fd = -1;
	int to_fd = -1;
	struct stat stbuf;
	void *from_p = NULL;
	void *to_p = NULL;
	char buf[PATH_MAX];
	ssize_t bytes_read;

	if (flags) {
		/*
		 * TODO: implement flags.
		 */
		errno = EOPNOTSUPP;
		goto free_unlock_and_return;
	}

	/*
	 * Try to renameat() first.  Only if it fails due to EXDEV fall back to
	 * manually handling the request.
	 */
	rv = renameat(ref_fd, from, to_ref_fd, to);
	if (rv >= 0 || (rv < 0 && errno != EXDEV)) {
		goto free_unlock_and_return;
	}

	if (fstatat(ref_fd, from, &stbuf, AT_SYMLINK_NOFOLLOW) < 0) {
		goto free_unlock_and_return;
	}

	switch (stbuf.st_mode & S_IFMT) {
	case S_IFBLK:
	case S_IFCHR:
	case S_IFIFO:
	case S_IFSOCK:
		if (mknodat(to_ref_fd, to, stbuf.st_mode, stbuf.st_rdev) < 0) {
			goto free_unlock_and_return;
		}
		break;
	case S_IFLNK:
		bytes_read = readlinkat(ref_fd, from, buf, sizeof(buf));
		if (bytes_read < 0 || (size_t) bytes_read >= sizeof(buf)) {
			goto free_unlock_and_return;
		}
		buf[bytes_read] = '\0';
		if (symlinkat(buf, to_ref_fd, to) < 0) {
			goto free_unlock_and_return;
		}
		break;
	case S_IFDIR:
		if (mkdirat(to_ref_fd, to, stbuf.st_mode) < 0) {
			goto free_unlock_and_return;
		}
		break;
	case S_IFREG:
		if ((from_fd = openat(ref_fd, from, O_RDONLY | O_NOFOLLOW)) < 0) {
			goto free_unlock_and_return;
		}
		if ((to_fd = openat(to_ref_fd, to,
					O_CREAT | O_RDWR | O_NOFOLLOW,
					stbuf.st_mode)) < 0) {
			goto free_unlock_and_return;
		}
		while ((bytes_read = read(from_fd, buf, sizeof(buf))) > 0) {
			if (write(to_fd, buf, bytes_read) != bytes_read) {
				goto free_unlock_and_return;
			}
		}
		if (ftruncate(to_fd, stbuf.st_size) < 0) {
			goto free_unlock_and_return;
		}
		break;
	}

	if (fchownat(to_ref_fd, to, stbuf.st_uid, stbuf.st_gid,
			AT_SYMLINK_NOFOLLOW) < 0) {
		goto free_unlock_and_return;
	}

	if (fchmodat(to_ref_fd, to, stbuf.st_mode, AT_SYMLINK_NOFOLLOW) < 0) {
		goto free_unlock_and_return;
	}

	int unlinkflag = 0;
	if (S_ISDIR(stbuf.st_mode)) {
		unlinkflag = AT_REMOVEDIR;
	}
	if (unlinkat(ref_fd, from, unlinkflag) < 0) {
		goto free_unlock_and_return;
	}

	rv = 0;

free_unlock_and_return:
	if (from_p != NULL) {
		munmap(from_p, stbuf.st_size);
	}
	if (to_p != NULL) {
		munmap(to_p, stbuf.st_size);
	}
	if (from_fd >= 0) {
		close(from_fd);
	}
	if (to_fd >= 0) {
		close(to_fd);
	}

	FS_IMP_RETURN(rv);
}

static int m_link(const char *from, const char *to)
{
	FS_IMP_SETUP(from);
	from = (from && from[1]) ? from + 1 : ".";
	to = (to && to[1]) ? to + 1 : ".";
	DISALLOW_ON_CFG(from);
	DISALLOW_ON_CFG(to);
	int to_ref_fd = get_ref_fd(to);

	rv = linkat(ref_fd, from, to_ref_fd, to, 0);

	FS_IMP_RETURN(rv);
}

static int m_chmod(const char *path, mode_t mode, struct fuse_file_info *fi)
{
	(void)fi;

	FS_IMP_SETUP(path);
	DISALLOW_ON_CFG(rpath);

	rv = fchmodat(ref_fd, rpath, mode, AT_SYMLINK_NOFOLLOW);

	FS_IMP_RETURN(rv);
}

static int m_chown(const char *path, uid_t uid, gid_t gid,
	struct fuse_file_info *fi)
{
	(void)fi;

	FS_IMP_SETUP(path);
	DISALLOW_ON_CFG(rpath);

	rv = fchownat(ref_fd, rpath, uid, gid, AT_SYMLINK_NOFOLLOW);

	FS_IMP_RETURN(rv);
}

static int m_truncate(const char *path, off_t size, struct fuse_file_info *fi)
{
	(void)fi;

	FS_IMP_SETUP(path);
	DISALLOW_ON_CFG(rpath);

	int fd = openat(ref_fd, rpath, O_RDWR | O_NOFOLLOW);
	if (fd < 0) {
		rv = fd;
	} else {
		rv = ftruncate(fd, size);
		close(fd);
	}

	FS_IMP_RETURN(rv);
}

static int m_utimens(const char *path, const struct timespec ts[2],
	struct fuse_file_info *fi)
{
	(void)fi;

	FS_IMP_SETUP(path);
	DISALLOW_ON_CFG(rpath);

	rv = utimensat(ref_fd, rpath, ts, AT_SYMLINK_NOFOLLOW);

	FS_IMP_RETURN(rv);
}

static int m_create(const char *path, mode_t mode, struct fuse_file_info *fi)
{
	FS_IMP_SETUP(path);
	DISALLOW_ON_CFG(rpath);

	int fd = openat(ref_fd, rpath, fi->flags, mode);
	if (fd < 0) {
		rv = -1;
	} else {
		rv = 0;
		fi->fh = fd;
	}

	FS_IMP_RETURN(rv);
}

static int m_open(const char *path, struct fuse_file_info *fi)
{
	FS_IMP_SETUP(path);

	if (strcmp(rpath, CFG_NAME) == 0) {
		struct fuse_context *context = fuse_get_context();
		if (context->uid != 0) {
			rv = -1;
			errno = EACCES;
		} else {
			rv = 0;
		}
	} else {
		int fd = openat(ref_fd, rpath, fi->flags);
		if (fd < 0) {
			rv = -1;
		} else {
			rv = 0;
			close(fd);
		}
	}

	FS_IMP_RETURN(rv);
}

static int m_read(const char *path, char *buf, size_t size, off_t offset,
	struct fuse_file_info *fi)
{
	(void)fi;

	FS_IMP_SETUP(path);

	if (strcmp(rpath, CFG_NAME) == 0) {
		struct fuse_context *context = fuse_get_context();
		if (context->uid == 0) {
			rv = cfg_read(buf, size, offset);
		} else {
			rv = -1;
			errno = EACCES;
		}
	} else {
		int fd = openat(ref_fd, rpath, O_RDONLY | O_NOFOLLOW);
		if (fd >= 0) {
			rv = pread(fd, buf, size, offset);
			close(fd);
		} else {
			rv = -1;
		}
	}

	FS_IMP_RETURN(rv);
}

static int m_write(const char *path, const char *buf, size_t size,
	off_t offset, struct fuse_file_info *fi)
{
	(void)offset;
	(void)fi;

	FS_IMP_SETUP(path);

	if (strcmp(rpath, CFG_NAME) == 0) {
		pthread_rwlock_unlock(&cfg_lock);
		pthread_rwlock_wrlock(&cfg_lock);
		struct fuse_context *context = fuse_get_context();
		if (context->uid != 0) {
			rv = -EACCES;
		} else if (strncmp(buf, CMD_ADD_GLOBAL,
				CMD_ADD_GLOBAL_LEN) == 0) {
			rv = cfg_add_global(buf, size);
		} else if (strncmp(buf, CMD_RM_GLOBAL, CMD_RM_GLOBAL_LEN) == 0) {
			rv = cfg_rm_global(buf, size);
		} else if (strncmp(buf, CMD_ADD_OVERRIDE,
				CMD_ADD_OVERRIDE_LEN) == 0) {
			rv = cfg_add_override(buf, size);
		} else if (strncmp(buf, CMD_RM_OVERRIDE,
				CMD_RM_OVERRIDE_LEN) == 0) {
			rv = cfg_rm_override(buf, size);
		} else {
			rv = -EINVAL;
		}
		pthread_rwlock_unlock(&cfg_lock);
		pthread_rwlock_rdlock(&cfg_lock);
	} else {
		int fd = openat(ref_fd, rpath, O_WRONLY | O_NOFOLLOW);
		if (fd >= 0) {
			rv = pwrite(fd, buf, size, offset);
			close(fd);
		} else {
			rv = -1;
		}
	}

	FS_IMP_RETURN(rv);
}

static int m_statfs(const char *path, struct statvfs *stbuf)
{
	FS_IMP_SETUP(path);
	DISALLOW_ON_CFG(rpath);

	int fd = openat(ref_fd, rpath, O_RDWR | O_NOFOLLOW);
	if (fd >= 0) {
		rv = fstatvfs(fd, stbuf);
		close(fd);
	} else {
		rv = -1;
	}

	FS_IMP_RETURN(rv);
}

/*
 * flush() is asking us to close the file descriptor to flush everything to
 * disk, *but* this may be called multiple times (multiple file descriptors to
 * same file?), so we can't actually close the file.  We can abuse dup() to get
 * the desired effect.
 */
static int m_flush(const char *path, struct fuse_file_info *fi)
{
	FS_IMP_SETUP(path);

	rv = close(dup(fi->fh));

	FS_IMP_RETURN(rv);
}

/*
 * Final close() call on the file.
 */
static int m_release(const char *path, struct fuse_file_info *fi)
{
	FS_IMP_SETUP(path);

	rv = close(fi->fh);

	FS_IMP_RETURN(rv);
}

/*
 * The FUSE API talks about a 'datasync parameter' being non-zero - presumably
 * that's the second parameter, since its the only number (int).
 */
static int m_fsync(const char *path, int datasync, struct fuse_file_info *fi)
{
	FS_IMP_SETUP(path);
	DISALLOW_ON_CFG(rpath);

	if (datasync) {
		rv = fdatasync(fi->fh);
	} else {
		rv = fsync(fi->fh);
	}
	/*
	 * libfuse provides two examples on how to implement this function.
	 *
	 * - One example is effectively the same as the implementation above.
	 *   However, sometimes the implementation above fails because fi->fh
	 *   is not a valid file descriptor.
	 *
	 * - The other example is a stub which fails to do anything.  Per its
	 *   comments, this is fine - this filesystem call is non-essential.
	 *
	 * We'll try our best above, but if that fails fall back to silently
	 * continuing rather than unproductively interrupting the calling
	 * program.
	 */
	if (rv < 0 && errno == EINVAL) {
		rv = 0;
	}

	FS_IMP_RETURN(rv);
}

static int m_fallocate(const char *path, int mode,
	off_t offset, off_t length, struct fuse_file_info *fi)
{
	(void)fi;

	FS_IMP_SETUP(path);
	DISALLOW_ON_CFG(rpath);

	int fd = openat(ref_fd, rpath, O_RDWR | O_NOFOLLOW);
	if (fd >= 0) {
		rv = fallocate(fd, mode, offset, length);
		close(fd);
	} else {
		rv = -1;
	}

	FS_IMP_RETURN(rv);

}

static int m_setxattr(const char *path, const char *name, const char *value,
	size_t size, int flags)
{
	FS_IMP_SETUP(path);
	DISALLOW_ON_CFG(rpath);

	int fd = openat(ref_fd, rpath, O_RDWR | O_NOFOLLOW);
	if (fd >= 0) {
		char buf[PATH_MAX];
		if (procpath(fd, buf, sizeof(buf)) < 0) {
			rv = -1;
			errno = ENAMETOOLONG;
		} else {
			rv = lsetxattr(buf, name, value, size, flags);
		}
		close(fd);
	} else {
		rv = -1;
	}

	FS_IMP_RETURN(rv);
}

static int m_getxattr(const char *path, const char *name, char *value,
	size_t size)
{
	FS_IMP_SETUP(path);

	int fd = -1;
	if (strcmp(rpath, CFG_NAME) == 0 && strcmp(STRATUM_XATTR, name) == 0) {
		if (size <= 0) {
			rv = strlen(GLOBAL_STRATUM);
		} else if (size < strlen(GLOBAL_STRATUM)) {
			rv = -1;
			errno = ERANGE;
		} else {
			rv = strlen(GLOBAL_STRATUM);
			strcpy(value, GLOBAL_STRATUM);
		}
	} else if (strcmp(rpath, CFG_NAME) == 0
		&& strcmp(LPATH_XATTR, name) == 0) {
		if (size <= 0) {
			rv = strlen(ROOTDIR);
		} else if (size < strlen(ROOTDIR)) {
			rv = -1;
			errno = ERANGE;
		} else {
			rv = strlen(ROOTDIR);
			strcpy(value, ROOTDIR);
		}
	} else if (strcmp(rpath, CFG_NAME) == 0) {
		rv = -1;
		errno = ENODATA;
	} else if ((fd = openat(ref_fd, rpath, O_RDONLY | O_NOFOLLOW)) < 0) {
		/*
		 * Apparently lgetxattr directly on the file path works where
		 * openat()+fgetxattr/lgetxattr() gets EACCES.  However, we
		 * can't access the files with the direct path as that would
		 * just recurse back to this filesystem; this entire design
		 * revolves around using the file descriptors.
		 *
		 * The vast, vast majority of the time this is an issue in
		 * practice is when GNU ls is called on files in /etc on which
		 * it does not have read permissions, such as `ls -l /etc`,
		 * looking for selinux tags.  Since we know what that would
		 * typically return - ENODATA - we can just return that as an
		 * ugly hack.
		 */
		if (errno == EACCES) {
			errno = ENODATA;
		}
		rv = -1;
	} else if (strcmp(STRATUM_XATTR, name) == 0 && ref_fd == global_ref_fd) {
		if (size <= 0) {
			rv = strlen(GLOBAL_STRATUM);
		} else if (size < strlen(GLOBAL_STRATUM)) {
			rv = -1;
			errno = ERANGE;
		} else {
			rv = strlen(GLOBAL_STRATUM);
			strcpy(value, GLOBAL_STRATUM);
		}
	} else if (strcmp(STRATUM_XATTR, name) == 0) {
		if (size <= 0) {
			rv = strlen(local_name);
		} else if (size < strlen(local_name)) {
			rv = -1;
			errno = ERANGE;
		} else {
			rv = strlen(local_name);
			strcpy(value, local_name);
		}
	} else if (strcmp(LPATH_XATTR, name) == 0) {
		char lpath[PATH_MAX];
		int s = snprintf(lpath, sizeof(lpath), "%s%s", mntpt, path);
		if (s < 0 || s >= (int)sizeof(lpath)) {
			rv = -1;
			errno = E2BIG;
		} else if (size <= 0) {
			rv = strlen(lpath);
		} else if (size < strlen(lpath)) {
			rv = -1;
			errno = ERANGE;
		} else {
			rv = strlen(lpath);
			strcpy(value, lpath);
		}
	} else {
		char buf[PATH_MAX];
		if (procpath(fd, buf, sizeof(buf)) < 0) {
			rv = -1;
			errno = ENAMETOOLONG;
		} else {
			rv = lgetxattr(buf, name, value, size);
		}
	}
	if (fd >= 0) {
		close(fd);
	}

	FS_IMP_RETURN(rv);
}

static int m_listxattr(const char *path, char *list, size_t size)
{
	FS_IMP_SETUP(path);
	DISALLOW_ON_CFG(rpath);

	int fd = openat(ref_fd, rpath, O_RDWR | O_NOFOLLOW);
	if (fd >= 0) {
		char buf[PATH_MAX];
		if (procpath(fd, buf, sizeof(buf)) < 0) {
			rv = -1;
			errno = ENAMETOOLONG;
		} else {
			rv = llistxattr(buf, list, size);
		}
		close(fd);
	} else {
		rv = -1;
	}

	FS_IMP_RETURN(rv);
}

static int m_removexattr(const char *path, const char *name)
{
	FS_IMP_SETUP(path);
	DISALLOW_ON_CFG(rpath);

	int fd = openat(ref_fd, rpath, O_RDWR | O_NOFOLLOW);
	if (fd >= 0) {
		char buf[PATH_MAX];
		if (procpath(fd, buf, sizeof(buf)) < 0) {
			rv = -1;
			errno = ENAMETOOLONG;
		} else {
			rv = lremovexattr(buf, name);
		}
		close(fd);
	} else {
		rv = -1;
	}

	FS_IMP_RETURN(rv);
}

static int m_flock(const char *path, struct fuse_file_info *fi, int op)
{
	FS_IMP_SETUP(path);
	DISALLOW_ON_CFG(rpath);

	rv = flock(fi->fh, op);

	FS_IMP_RETURN(rv);
}

/*
 * Implemented filesystem calls
 *
 * Do not implement ioctl.  FUSE's ioctl acts differently from that of other
 * filesystems in a way which causes significant problems, and not implementing
 * ioctl appears to be the cleanest solution.  See the following links for more
 * information about FS_IOC_GETFLAGS's issue:
 *
 * http://linux-fsdevel.vger.kernel.narkive.com/eUZdzNjw/argument-type-for-fs-ioc-getflags-fs-ioc-setflags-ioctls
 * http://sourceforge.net/p/fuse/mailman/message/31773852/
 *
 */
static struct fuse_operations m_oper = {
	/* .init = m_init, */
	.getattr = m_getattr,
	.access = m_access,
	.readlink = m_readlink,
	.opendir = m_opendir,
	.readdir = m_readdir,
	.releasedir = m_releasedir,
	.mknod = m_mknod,
	.mkdir = m_mkdir,
	.symlink = m_symlink,
	.unlink = m_unlink,
	.rmdir = m_rmdir,
	.rename = m_rename,
	.link = m_link,
	.chmod = m_chmod,
	.chown = m_chown,
	.truncate = m_truncate,
	.utimens = m_utimens,
	.create = m_create,
	.open = m_open,
	.read = m_read,
	/* .read_buf = m_read_buf, */
	.write = m_write,
	/* .write_buf = m_write_buf, */
	.statfs = m_statfs,
	.flush = m_flush,
	.release = m_release,
	.fsync = m_fsync,
	.fallocate = m_fallocate,
	.setxattr = m_setxattr,
	.getxattr = m_getxattr,
	.listxattr = m_listxattr,
	.removexattr = m_removexattr,
	/* .lock = m_lock, TODO */
	.flock = m_flock,
};

int main(int argc, char *argv[])
{
	/*
	 * Ensure we are running as root.  This is needed to mimic caller
	 * process permissions.
	 */
	if (getuid() != 0) {
		fprintf(stderr, "error: not running as root.\n");
		return 1;
	}

	/*
	 * Extract mount point from arguments
	 */
	struct fuse_args args = FUSE_ARGS_INIT(argc, argv);
	if (fuse_opt_parse(&args, NULL, NULL, NULL) < 0) {
		fprintf(stderr, "error: unable to parse arguments.\n");
		return 1;
	}
	struct fuse_cmdline_opts opts;
	if (fuse_parse_cmdline(&args, &opts) < 0) {
		fprintf(stderr, "error: unable to parse arguments.\n");
		return 1;
	}
	if (opts.mountpoint == NULL) {
		fprintf(stderr, "error: no mount point provided.\n");
		return 1;
	}

	/*
	 * Get local mount point reference before mounting over.
	 */
	mntpt = opts.mountpoint;
	if ((local_ref_fd = open(mntpt, O_DIRECTORY)) < 0) {
		fprintf(stderr, "error: unable to open local mount point\n");
		return 1;
	}
	/*
	 * Get global mount point reference
	 */
	int global_root_fd = open(global_root, O_DIRECTORY);
	const char *const rmntpt = (mntpt && mntpt[1]) ? mntpt + 1 : ".";
	if ((global_ref_fd = openat(global_root_fd, rmntpt, O_DIRECTORY)) < 0) {
		fprintf(stderr, "error: unable to open global mount point\n");
		return 1;
	}
	close(global_root_fd);

	/*
	 * Get local stratum name
	 */
	if (lgetxattr("/", STRATUM_XATTR, local_name, sizeof(local_name)) < 0) {
		fprintf(stderr, "error: unable to determine local stratum\n");
		return 1;
	}

	/*
	 * Initialize mutex
	 */
	if (pthread_rwlock_init(&cfg_lock, NULL) < 0) {
		fprintf(stderr, "error: initializing mutexes\n");
		return 1;
	}

	/*
	 * Initialize config stat
	 */
	memset(&cfg_stat, 0, sizeof(struct stat));
	cfg_stat.st_ctime = time(NULL);
	cfg_stat.st_mtime = cfg_stat.st_ctime;
	cfg_stat.st_atime = cfg_stat.st_ctime;
	cfg_stat.st_mode = S_IFREG | 0600;
	cfg_stat.st_size = 0;

	/*
	 * Clear umask
	 */
	umask(0);

	/*
	 * Mount filesystem.
	 *
	 * Incoming filesystem calls will be fulfilled by the functions listed
	 * in m_oper above.
	 */
	return fuse_main(argc, argv, &m_oper, NULL);
}
