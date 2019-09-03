/*
 * crossfs.c
 *
 *      This program is free software; you can redistribute it and/or
 *      modify it under the terms of the GNU General Public License
 *      version 2 as published by the Free Software Foundation.
 *
 * Copyright (c) 2014-2018 Daniel Thau <danthau@bedrocklinux.org>
 *
 * This program implements a filesystem which provides cross-stratum file
 * access.  It fulfills filesystem requests by forwarding the appropriate
 * stratum's copy of a given file, possibly modifying it in transit if needed.
 *
 * This filesystem makes heavy use of the word "path" in different contexts.
 * For conceptual consistency, paths are broken up into four categories:
 *
 * - "ipath", or "incoming path", refers to the file paths incoming from the
 *   processes' request to this filesystem.  For example, if a process wants to
 *   know about <mount>/foo/bar, /foo/bar is ipath.
 * - "cpath", or "configured path", is a path the filesystem is configured to
 *   handle.  For example, a cpath may be /bin, indicating the filesystem knows
 *   how to fulfill an ipath on /bin or a subdirectory of /bin.
 * - "lpath", or "local path", is a path relative to a given stratum.  These
 *   are usually paired with a reference to a corresponding stratum's root
 *   directory such as a "root_fd".  These are used to map cpaths to
 *   files/directories that may fulfill requests on/around the cpath.
 * - "bpath", or "backing path", is a reference to a file that may fulfill a
 *   given ipath.  Like lpath, it is usually paired with a reference to a
 *   stratum root directory.  This is usually calculated based on ipath, cpath,
 *   and lpath.
 *
 * For example, if a process may query about the ipath /bin/vi.  There may be a
 * cpath at /bin which is mapped to three lpaths: /usr/local/bin, /usr/bin, and
 * /bin.  bpaths are generated from this information:  /usr/local/bin/vi,
 * /usr/bin/vi, and /bin/vi.  Each of these are checked to fulfill the given
 * ipath.
 *
 * Various functions starting with "m_" implement filesystem calls.  These are
 * the main entry point once the filesystem is running.  A thread may be
 * spawned for each call such that several may be running at once.  Special
 * care must be taken with them:
 *
 * - The thread's fsuid/fsgid should be set to the incoming caller's to export
 *   permissions access to the kernel.  This should happen immediately, before
 *   any file system calls are made.  Use set_caller_fsid().
 * - cfg_lock should be locked around cfg access to ensure it is not read while
 *   being modified.  The vast majority of accesses will be read-only, and
 *   non-contended read locks/unlocks are cheap.  Thus, it is not unreasonable
 *   to do this very early/late in the function.  Careful not to early return
 *   before unlocking.
 * - File system calls relative to the root or cwd are not thread safe.  Use
 *   fchroot_* wrappers which internally lock.  Filesystem calls relative to a
 *   file descriptor (e.g. readlinkat()) are thread safe.
 *
 * Having to lock around chroot() calls is obviously undesirable.  The
 * alternative is to write our own function to walk a path as though it was
 * chrooted, resolving to the ultimate path.  In practice, such attempts were
 * found to be slower than the lock-and-chroot method used here, primarily due
 * to the large number of expensive system calls (repeated readlink()).
 *
 * Another obviously undesirable performance hit revolves around repeated work
 * between readdir() and getattr().  readdir() does a lot of work to find the
 * corresponding backing files.  Immediately afterwards, getattr() is usually
 * called and has to again calculate the same backing file.  In theory, this
 * information could be cached for a short time for getattr.  Linux/FUSE
 * actually provide a caching solution for exactly this called "readdirplus".
 * However, at the time of writing this feature is broken:
 *
 *     https://sourceforge.net/p/fuse/mailman/fuse-devel/thread/878tcgxvp2.fsf@vostro.rath.org/#msg36209107
 *
 * Our own implementation of caching may be useful.  We could cache the getattr
 * metadata in the readdir() loop, and/or we could cache the ipath->cpath
 * calculation.  Cache invalidation may be tricky.
 */

#define FUSE_USE_VERSION 32
#define _GNU_SOURCE

#include <dirent.h>
#include <sys/types.h>
#include <sys/xattr.h>
#include <errno.h>
#include <fuse3/fuse.h>
#include <linux/limits.h>
#include <pthread.h>
#include <stdio.h>
#include <sys/fsuid.h>
#include <unistd.h>

#include <uthash.h>

#define ARRAY_LEN(x) (sizeof(x) / sizeof(x[0]))
#define MIN(x, y) (x < y ? x : y)

/*
 * The directory containing the roots of the various strata.  References to a
 * specific stratum's instance of a file go through this directory.
 */
#define STRATA_ROOT "/bedrock/strata/"
#define STRATA_ROOT_LEN strlen(STRATA_ROOT)

/*
 * Strat runs an executable from given stratum as specified in argument list.
 * Crossfs injects this into various references to executables to ensure the
 * appropriate stratum's instance of the executable is utilized in that
 * context.  This is useful for things such as .desktop files with `Exec=`
 * references to executables.
 */
#define STRAT_PATH "/bedrock/bin/strat"
#define STRAT_PATH_LEN strlen(STRAT_PATH)

/*
 * Bouncer, like strat, redirects to the appropriate stratum's instance of an
 * executable.  It differs from strat in that it determines which executable by
 * looking at its extended filesystem attributes rather than its arguments.
 * This is useful for binaries the user will directly execute, as the user
 * controls the argument list.
 */
#define BOUNCER_PATH "/bedrock/libexec/bouncer"
#define BOUNCER_PATH_LEN strlen(BOUNCER_PATH)

/*
 * Surface the associated stratum and file path for files via xattrs.
 */
#define STRATUM_XATTR "user.bedrock.stratum"
#define STRATUM_XATTR_LEN strlen(STRATUM_XATTR)

#define LPATH_XATTR "user.bedrock.localpath"
#define LPATH_XATTR_LEN strlen(LPATH_XATTR)

#define RESTRICT_XATTR "user.bedrock.restrict"
#define RESTRICT_XATTR_LEN strlen(RESTRICT_XATTR)
#define RESTRICT "restrict"
#define RESTRICT_LEN strlen(RESTRICT)

/*
 * Crossfs may be configured to present a file without being explicitly
 * configured to also present its parent directory.  It will dynamically create
 * a virtual directory in these cases.
 *
 * This filesystem is typically mounted in the bedrock stratum then shared with
 * other strata as a global path.  Thus, by definition, anything that isn't
 * crossed to another stratum is owned by the bedrock stratum, including these
 * virtual directories.
 */
#define VIRTUAL_STRATUM "bedrock"
#define VIRTUAL_STRATUM_LEN strlen(VIRTUAL_STRATUM)
/*
 * All crossfs files have an associated file path.  While "/" isn't
 * particularly meaningful here, no other path is obviously better.
 */
#define VIRTUAL_LPATH "/"
#define VIRTUAL_LPATH_LEN strlen(VIRTUAL_LPATH)

/*
 * When merging font directories, these files require extra attention.
 */
#define FONTS_DIR "fonts.dir"
#define FONTS_DIR_LEN strlen(FONTS_DIR)

#define FONTS_ALIAS "fonts.alias"
#define FONTS_ALIAS_LEN strlen(FONTS_ALIAS)

/*
 * The file path used to configure this filesystem.
 */
#define CFG_NAME ".bedrock-config-filesystem"
#define CFG_NAME_LEN strlen(CFG_NAME)

#define CFG_PATH "/.bedrock-config-filesystem"
#define CFG_PATH_LEN strlen(CFG_PATH)

/*
 * Symlink to stratum root, used for local alias.
 */
#define LOCAL_ALIAS_NAME ".local-alias"
#define LOCAL_ALIAS_NAME_LEN strlen(LOCAL_ALIAS_NAME)

#define LOCAL_ALIAS_PATH "/.local-alias"
#define LOCAL_ALIAS_PATH_LEN strlen(LOCAL_ALIAS_PATH)

/*
 * local alias
 */
#define LOCAL "local"
#define LOCAL_LEN strlen(LOCAL)

/*
 * Headers for content written to CFG_NAME
 */
#define CMD_CLEAR "clear"
#define CMD_CLEAR_LEN strlen(CMD_CLEAR)

#define CMD_ADD "add"
#define CMD_ADD_LEN strlen(CMD_ADD)

#define CMD_RM "rm"
#define CMD_RM_LEN strlen(CMD_RM)

#define FS_IMP_SETUP(lock_type)                                              \
	int rv;                                                              \
	set_caller_fsid();                                                   \
	if ((rv = set_local_stratum()) < 0) {                                \
		return rv;                                                   \
	}                                                                    \
	if (lock_type == CFG_RDLOCK) {                                       \
		pthread_rwlock_rdlock(&cfg_lock);                            \
	} else {                                                             \
		pthread_rwlock_wrlock(&cfg_lock);                            \
	}

#define FS_IMP_RETURN(rv)                                                    \
	pthread_rwlock_unlock(&cfg_lock);                                    \
	close(local_stratum.root_fd);                                        \
	return rv;

/*
 * Indicates whether the given critical section needs to be exclusive.
 */
enum cfg_lock_type {
	CFG_WRLOCK,
	CFG_RDLOCK,
};

/*
 * Incoming paths are classified into the following categories.
 */
enum ipath_class {
	/*
	 * Refers to a path which may be implemented by a backing file.
	 */
	CLASS_BACK,
	/*
	 * Refers to a virtual directory (other than the root directory).
	 */
	CLASS_VDIR,
	/*
	 * Refers to the root directory.
	 */
	CLASS_ROOT,
	/*
	 * Refers to this filesystem's configuration interface.
	 */
	CLASS_CFG,
	/*
	 * Refers to symlink pointing to calling process stratum root.
	 */
	CLASS_LOCAL,
	/*
	 * Does not refer to any expected file path.
	 */
	CLASS_ENOENT,
};

/*
 * This filesystem may modify contents as it passes the backing file to the
 * requesting process.  The filter indicates the scheme used to modify the
 * contents.
 */
enum filter {
	/*
	 * Files are expected to be executables.  Return bouncer.
	 */
	FILTER_BIN,
	/*
	 * Files are expected to be executables.  Return bouncer with restrict set.
	 */
	FILTER_BIN_RESTRICT,
	/*
	 * Files are expected to be in ini-format.
	 *
	 * Wrap [Try]Exec[Start|Stop|Reload]= ini key-value pairs with strat.
	 *
	 * For example:
	 *     Exec=/usr/bin/vim
	 * becomes
	 *     Exec=/bedrock/bin/strat opensuse /usr/bin/vim
	 */
	FILTER_INI,
	/*
	 * Combine fonts.dir and fonts.aliases files.
	 */
	FILTER_FONT,
	/*
	 * Pass file through unaltered.
	 */
	FILTER_PASS,
};

const char *const filter_str[] = {
	"bin",
	"bin-restrict",
	"ini",
	"font",
	"pass",
};

const char *const ini_exec_str[] = {
	"Exec=",
	"ExecReload=",
	"ExecStart=",
	"ExecStartPost=",
	"ExecStartPre=",
	"ExecStop=",
	"ExecStopPost=",
	"TryExec=",
};

const size_t ini_exec_len[] = {
	5,
	11,
	10,
	14,
	13,
	9,
	13,
	8,
};

struct stratum {
	/*
	 * stratum name
	 */
	char *name;
	size_t name_len;
	/*
	 * A file descriptor relating to the corresponding stratum's root
	 * directory.
	 */
	int root_fd;
};

/*
 * Each back_entry represents a file or directory which may fulfill a given
 * cfg_entry file.
 */
struct back_entry {
	/*
	 * The stratum-local path.
	 */
	char *lpath;
	size_t lpath_len;
	/*
	 * The corresponding stratum/alias.  Run through deref() before
	 * consumption.
	 */
	struct stratum alias;
	/*
	 * Boolean indicating if this back_entry uses the local alias.  If so,
	 * deref() forwards calls to the local stratum rather than this
	 * struct's alias field.
	 */
	int local;
};

/*
 * Each cfg_entry represents a user-facing file or directory in the mount
 * point.
 */
struct cfg_entry {
	/*
	 * Filter to apply to output.
	 */
	enum filter filter;
	/*
	 * Path to append to mount point's path.  For example, if this
	 * filesystem is mounted at "/bedrock/cross" and path="/man", this
	 * cfg_entry refers to "/bedrock/cross/man".  Note the preceding slash.
	 */
	char *cpath;
	size_t cpath_len;
	/*
	 * Array of filesystem paths to be searched for this cfg_entry's
	 * backing file(s).
	 */
	struct back_entry *back;
	size_t back_cnt;
	size_t back_alloc;
};

/*
 * Hash table entry for a single string.
 */
struct h_str {
	UT_hash_handle hh;
	char str[];
};

/*
 * Hash table entry for a key-value pair
 */
struct h_kv {
	UT_hash_handle hh;
	char *value;
	char key[];
};

/*
 * An array of cfg_entry's listing all of the user-facing files and directories
 * in this mount point.
 *
 * Access should be locked with cfg_lock.
 */
struct cfg_entry *cfgs = NULL;
size_t cfg_cnt = 0;
size_t cfg_alloc = 0;

/*
 * Per-thread information about calling process' stratum.
 */
static __thread char local_stratum_name[PATH_MAX];
static __thread struct stratum local_stratum;

/*
 * Reference file descriptors.  Used as fixed reference points while
 * chroot()'ing around.
 */
int init_root_fd;
int strata_root_fd;
int current_root_fd;
int bouncer_fd;

/*
 * Locks
 */
pthread_rwlock_t cfg_lock;
pthread_mutex_t root_lock;

/*
 * Pre-calculated stat information.
 */
struct stat vdir_stat;
struct stat cfg_stat;
struct stat local_stat;
off_t bouncer_size;

/*
 * Set the fsuid and fsgid to that of the calling function.  setfsuid/setfsgid
 * do not indicate success/failure; we have to trust they succeed.  A check
 * against `getuid()==0` is performed when this process starts to ensure
 * adequate permissions are in place.
 */
static inline void set_caller_fsid()
{
	struct fuse_context *context = fuse_get_context();
	setfsuid(context->uid);
	setfsgid(context->gid);
}

/*
 * Returns non-zero if path a is a parent (or grand parent, etc) of path b.
 *
 * For example:
 *     is_parent("/proc", ..., "/proc", ...) == 0
 *     is_parent("/proc", ..., "/proc/1", ...) != 0
 *     is_parent("/proc", ..., "/proc/1/root", ...) != 0
 *     is_parent("/proc", ..., "/", ...) == 0
 *     is_parent("/proc", ..., "/dev", ...) == 0
 *     is_parent("/proc", ..., "/dev/shm", ...) == 0
 */
static inline int is_parent(const char *const a, const size_t a_len,
	const char *b, const size_t b_len)
{
	if (a_len >= b_len) {
		return 0;
	}

	if (b[a_len] != '/') {
		return 0;
	}

	return memcmp(b, a, a_len) == 0;
}

/*
 * Returns non-zero if strcmp(a,b)==0 or if a contains b.
 *
 * For example:
 *     is_equal_or_parent("/proc", ..., "/proc", ...) == 0
 *     is_equal_or_parent("/proc", ..., "/proc/1", ...) == 0
 *     is_equal_or_parent("/proc", ..., "/proc/1/root", ...) == 0
 *     is_equal_or_parent("/proc", ..., "/", ...) != 0
 *     is_equal_or_parent("/proc", ..., "/dev", ...) != 0
 *     is_equal_or_parent("/proc", ..., "/dev/shm", ...) != 0
 */
static inline int is_equal_or_parent(const char *const a, const size_t a_len,
	const char *b, const size_t b_len)
{
	if (a_len > b_len) {
		return 0;
	}

	if (b[a_len] != '\0' && b[a_len] != '/') {
		return 0;
	}

	return memcmp(b, a, a_len) == 0;
}

/*
 * Returns 0 if the strings are equivalent, roughly like strcmp but without
 * guarantees around ordering consideration if they're non-equal.
 *
 * This is preferable to strcmp() as it is faster, but comes at the cost of
 * requiring that both strings have pre-calculated lengths.
 */
static inline int pstrcmp(const char *const a, const size_t a_len,
	const char *b, const size_t b_len)
{
	if (a_len != b_len) {
		return 1;
	}

	return memcmp(a, b, a_len);
}

/*
 * Dereference a back_entry's alias.
 */
static inline struct stratum *deref(struct back_entry *back)
{
	if (back->local) {
		return &local_stratum;
	} else {
		return &back->alias;
	}
}

/*
 * Classify an incoming file path into one of ipath_class.
 */
static inline enum ipath_class classify_ipath(const char *ipath,
	size_t ipath_len, struct cfg_entry **cfg)
{
	/*
	 * In the most performance sensitive situations, CLASS_PATH is the most
	 * common possibility.  Thus, check for it first.
	 */
	for (size_t i = 0; i < cfg_cnt; i++) {
		if (is_equal_or_parent(cfgs[i].cpath, cfgs[i].cpath_len,
				ipath, ipath_len)) {
			*cfg = &cfgs[i];
			return CLASS_BACK;
		}
	}

	for (size_t i = 0; i < cfg_cnt; i++) {
		if (is_parent(ipath, ipath_len, cfgs[i].cpath,
				cfgs[i].cpath_len)) {
			*cfg = &cfgs[i];
			return CLASS_VDIR;
		}
	}

	if (ipath[0] == '/' && ipath[1] == '\0') {
		return CLASS_ROOT;
	}

	if (pstrcmp(ipath, ipath_len, CFG_PATH, CFG_PATH_LEN) == 0) {
		return CLASS_CFG;
	}

	if (pstrcmp(ipath, ipath_len, LOCAL_ALIAS_PATH,
			LOCAL_ALIAS_PATH_LEN) == 0) {
		return CLASS_LOCAL;
	}

	return CLASS_ENOENT;
}

/*
 * Calculate the backing path for a given cfg_entry, back_entry, and incoming
 * path.
 *
 * Assumes classify_ipath() already confirmed that the ipath is a CLASS_BACK.
 */
static inline char *calc_bpath(struct cfg_entry *cfg, struct back_entry *back,
	const char *ipath, size_t ipath_len, char tmp[PATH_MAX])
{
	if (ipath_len < cfg->cpath_len) {
		return NULL;
	}
	if (ipath[cfg->cpath_len] == '\0') {
		return back->lpath;
	} else if (ipath[cfg->cpath_len] != '/') {
		return NULL;
	} else if (back->lpath_len + ipath_len - cfg->cpath_len + 1 > PATH_MAX) {
		return NULL;
	} else {
		memcpy(tmp, back->lpath, back->lpath_len);
		memcpy(tmp + back->lpath_len,
			ipath + cfg->cpath_len, ipath_len - cfg->cpath_len + 1);
		return tmp;
	}
}

/*
 * Insert a string into a hash table.
 */
static inline int insert_h_str(struct h_str **strs, char *str, size_t str_len)
{
	struct h_str *e = NULL;

	/*
	 * If we already have a match, use pre-existing.
	 */
	HASH_FIND(hh, *strs, str, str_len, e);
	if (e != NULL) {
		return 0;
	}

	e = malloc(sizeof(struct h_str) + str_len + 1);
	if (e == NULL) {
		return -ENOMEM;
	}

	memcpy(e->str, str, str_len + 1);

	HASH_ADD_KEYPTR(hh, *strs, e->str, str_len, e);
	return 0;
}

/*
 * Insert a key/value pair into a hash table.
 */
static inline int insert_h_kv(struct h_kv **kvs, char *key, size_t key_len,
	char *value)
{
	struct h_kv *e = NULL;

	/*
	 * If we already have a match, use pre-existing.
	 */
	HASH_FIND(hh, *kvs, key, key_len, e);
	if (e != NULL) {
		return 0;
	}

	e = malloc(sizeof(struct h_kv) + key_len + 1);
	if (e == NULL) {
		return -ENOMEM;
	}

	size_t value_len = strlen(value);
	e->value = malloc(value_len + 1);
	if (e->value == NULL) {
		free(e);
		return -ENOMEM;
	}

	memcpy(e->key, key, key_len + 1);
	memcpy(e->value, value, value_len + 1);

	HASH_ADD_KEYPTR(hh, *kvs, e->key, key_len, e);
	return 0;
}

/*
 * Perform open() with a given chroot()
 */
static inline int fchroot_open(int root_fd, const char *bpath, int flags)
{
	int rv = -EINVAL;
	pthread_mutex_lock(&root_lock);

	if ((current_root_fd == root_fd)
		|| (fchdir(root_fd) >= 0 && chroot(".") >= 0)) {
		current_root_fd = root_fd;

		rv = open(bpath, flags);
	}

	pthread_mutex_unlock(&root_lock);
	return rv;
}

/*
 * Perform stat() with a given chroot()
 */
static inline int fchroot_stat(int root_fd, const char *bpath, struct stat *buf)
{
	int rv = -EAGAIN;
	pthread_mutex_lock(&root_lock);

	if ((current_root_fd == root_fd)
		|| (fchdir(root_fd) >= 0 && chroot(".") >= 0)) {
		current_root_fd = root_fd;

		rv = stat(bpath, buf);
	}

	pthread_mutex_unlock(&root_lock);
	return rv;
}

/*
 * Perform readlink() with a given chroot()
 */
static inline int fchroot_readlink(int root_fd, const char *bpath, char *buf,
	size_t size)
{
	int rv = -EINVAL;
	pthread_mutex_lock(&root_lock);

	if ((current_root_fd == root_fd)
		|| (fchdir(root_fd) >= 0 && chroot(".") >= 0)) {
		current_root_fd = root_fd;

		rv = readlink(bpath, buf, size);
	}

	pthread_mutex_unlock(&root_lock);
	return rv;
}

/*
 * Perform fopen() with a given chroot()
 */
static inline FILE *fchroot_fopen(int root_fd, const char *bpath,
	const char *mode)
{
	FILE *rv = NULL;
	pthread_mutex_lock(&root_lock);

	if ((current_root_fd == root_fd)
		|| (fchdir(root_fd) >= 0 && chroot(".") >= 0)) {
		current_root_fd = root_fd;

		rv = fopen(bpath, mode);
	}

	pthread_mutex_unlock(&root_lock);
	return rv;
}

/*
 * Fill a hash table with directory entries given a chroot().
 */
static inline int fchroot_filldir(int root_fd, const char *const bpath,
	struct h_str *files)
{
	int rv = 0;
	pthread_mutex_lock(&root_lock);

	if ((current_root_fd == root_fd)
		|| (fchdir(root_fd) >= 0 && chroot(".") >= 0)) {
		current_root_fd = root_fd;

		DIR *d = NULL;
		if (chdir(bpath) >= 0 && (d = opendir(".")) != NULL) {
			struct dirent *dir;
			while ((dir = readdir(d)) != NULL) {
				struct h_str *e = NULL;
				size_t len = strlen(dir->d_name);
				HASH_FIND(hh, files, dir->d_name, len, e);
				if (e != NULL) {
					continue;
				}

				struct stat stbuf;
				if (stat(dir->d_name, &stbuf) < 0) {
					continue;
				}
				rv |= insert_h_str(&files, dir->d_name, len);
			}
			closedir(d);
		} else if (errno != ENOENT) {
			rv = -errno;
		}
	}

	pthread_mutex_unlock(&root_lock);
	return rv;
}

/*
 * Perform a stat() against every bpath and return after the first non-ENOENT
 * hit.
 */
static inline int stat_first_bpath(struct cfg_entry *cfg, const char *ipath,
	size_t ipath_len, struct stat *stbuf)
{
	int rv = -ENOENT;
	for (size_t i = 0; i < cfg->back_cnt; i++) {
		char tmp[PATH_MAX];
		char *bpath = calc_bpath(cfg, &cfg->back[i], ipath,
			ipath_len, tmp);
		if (bpath == NULL) {
			continue;
		}

		rv = fchroot_stat(deref(&cfg->back[i])->root_fd, bpath, stbuf);
		if (rv >= 0 || errno != ENOENT) {
			break;
		}
	}
	return rv;
}

/*
 * Perform a open() against every bpath and return after the first non-ENOENT
 * hit.
 */
static inline int open_first_bpath(struct cfg_entry *entry, const char *ipath,
	size_t ipath_len, int flags)
{
	int rv = -ENOENT;
	for (size_t i = 0; i < entry->back_cnt; i++) {
		char tmp[PATH_MAX];
		char *bpath = calc_bpath(entry, &entry->back[i], ipath,
			ipath_len, tmp);
		if (bpath == NULL) {
			continue;
		}

		rv = fchroot_open(deref(&entry->back[i])->root_fd, bpath,
			flags);
		if (rv >= 0 || errno != ENOENT) {
			break;
		}
	}
	return rv;
}

/*
 * Retrieves the location of the first non-ENOENT file for the given
 * ipath/entry.
 */
static inline int loc_first_bpath(struct cfg_entry *cfg,
	const char *ipath, size_t ipath_len, struct back_entry **back,
	char obpath[PATH_MAX])
{
	int rv = -ENOENT;
	for (size_t i = 0; i < cfg->back_cnt; i++) {
		char *bpath = calc_bpath(cfg, &cfg->back[i], ipath,
			ipath_len, obpath);
		if (bpath == NULL) {
			continue;
		}

		char c;
		rv = fchroot_readlink(deref(&cfg->back[i])->root_fd, bpath, &c,
			1);
		if (rv >= 0 || errno != ENOENT) {
			*back = &cfg->back[i];
			obpath[PATH_MAX - 1] = '\0';
			strncpy(obpath, bpath, PATH_MAX);
			if (obpath[PATH_MAX - 1] != '\0') {
				rv = -E2BIG;
			} else {
				rv = 0;
			}
			break;
		}
	}
	return rv;
}

/*
 * Perform a filldir() against every bpath.
 */
static inline int filldir_all_bpath(struct cfg_entry *cfg, const char *ipath,
	size_t ipath_len, struct h_str *files)
{
	int rv = 0;
	for (size_t i = 0; i < cfg->back_cnt; i++) {
		char tmp[PATH_MAX];
		char *bpath = calc_bpath(cfg, &cfg->back[i], ipath,
			ipath_len, tmp);
		if (bpath == NULL) {
			continue;
		}

		rv |= fchroot_filldir(deref(&cfg->back[i])->root_fd, bpath,
			files);
	}
	return rv;
}

/*
 * Like strncat, except:
 * - Do not use trailing null; track offset into buffer instead
 * - Skip set number of input bytes before writing into buffer
 */
void strcatoff(char *buf, const char *const str, size_t str_len,
	size_t * offset, size_t * wrote, size_t max)
{
	if ((*offset) >= str_len) {
		(*offset) -= str_len;
		return;
	}

	size_t len = MIN(str_len - (*offset), max - (*wrote));
	memcpy(buf + (*wrote), str + (*offset), len);

	(*wrote) += len;
	(*offset) = 0;
}

/*
 * Clear in-memory copy of configuration information
 */
static void cfg_clear(void)
{
	for (size_t i = 0; i < cfg_cnt; i++) {
		for (size_t j = 0; j < cfgs[i].back_cnt; j++) {
			free(cfgs[i].back[j].lpath);
			free(cfgs[i].back[j].alias.name);
			if (!cfgs[i].back[j].local) {
				close(cfgs[i].back[j].alias.root_fd);
			}
		}
		free(cfgs[i].cpath);
		free(cfgs[i].back);
	}
	if (cfgs != NULL) {
		free(cfgs);
		cfgs = NULL;
	}
	cfg_cnt = 0;
	cfg_alloc = 0;
	cfg_stat.st_size = 0;
}

/*
 * Parse and apply instruction to add configuration.  Expected format is:
 *
 *     add [filter] [path] [stratum]:[value-path]\n
 *
 * For example:
 *
 *     add bin /pin/bin/sv void:/usr/bin/sv\n
 *
 * Another example:
 *
 *     add ini /applications solus:/usr/share/applications\n
 *
 * Every line should have a trailing newline, as shown above.
 *
 * Every path item should start with a forward slash.
 *
 * Entire line must be expressed within a single call and must fit within
 * PIPE_BUF, including trailing null.  Close and sync after each line.
 *
 * The filter value is only meaningful in the first submission for a path.
 */
static int cfg_add(const char *const buf, size_t size)
{
	/*
	 * Ensure there is a trailing null so that sscanf doesn't overflow if
	 * we somehow get bad input.
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
	char buf_filter[PIPE_BUF];
	char space2;
	char buf_cpath[PIPE_BUF];
	char space3;
	char buf_stratum[PIPE_BUF];
	char buf_lpath[PIPE_BUF];
	char newline;
	if (sscanf(nbuf, "%s%c%s%c%s%c%[^:]:%s%c", buf_cmd, &space1,
			buf_filter, &space2, buf_cpath, &space3,
			buf_stratum, buf_lpath, &newline) != 9) {
		return -EINVAL;
	}

	/*
	 * Sanity check
	 */
	if (strcmp(buf_cmd, CMD_ADD) != 0 || buf_cpath[0] != '/'
		|| buf_lpath[0] != '/' || space1 != ' '
		|| space2 != ' ' || space3 != ' ' || newline != '\n'
		|| strchr(buf_stratum, '/') != NULL) {
		return -EINVAL;
	}

	/*
	 * Determine filter
	 */
	enum filter filter = ARRAY_LEN(filter_str);
	for (size_t i = 0; i < ARRAY_LEN(filter_str); i++) {
		if (strcmp(buf_filter, filter_str[i]) == 0) {
			filter = i;
			break;
		}
	}
	if (filter == ARRAY_LEN(filter_str)) {
		return -EINVAL;
	}

	/*
	 * Look for preexisting cfg to expand
	 */
	struct cfg_entry *cfg = NULL;
	size_t cpath_len = strlen(buf_cpath);
	for (size_t i = 0; i < cfg_cnt; i++) {
		if (pstrcmp(cfgs[i].cpath, cfgs[i].cpath_len, buf_cpath,
				cpath_len) == 0) {
			cfg = &cfgs[i];
			break;
		}
	}

	/*
	 * No preexisting cfg_entry, make a new one
	 */
	if (cfg == NULL) {
		char *cpath = malloc(cpath_len + 1);
		if (cpath == NULL) {
			return -ENOMEM;
		}
		memcpy(cpath, buf_cpath, cpath_len + 1);

		if (cfg_alloc < cfg_cnt + 1) {
			cfg = realloc(cfgs, (cfg_cnt + 1) *
				sizeof(struct cfg_entry));
			if (cfg == NULL) {
				free(cpath);
				return -ENOMEM;
			}
			cfgs = cfg;
			cfg_alloc = cfg_cnt + 1;
		}

		cfg = &cfgs[cfg_cnt];
		cfg->cpath = cpath;
		cfg->cpath_len = cpath_len;
		cfg->filter = filter;
		cfg->back = NULL;
		cfg->back_cnt = 0;
		cfg->back_alloc = 0;

		cfg_cnt++;
	}

	/*
	 * Look for a preexisting back_entry for the given cfg.  If we
	 * find one, don't re-add; we're done.
	 */
	size_t stratum_len = strlen(buf_stratum);
	size_t lpath_len = strlen(buf_lpath);
	for (size_t i = 0; i < cfg->back_cnt; i++) {
		if (pstrcmp(cfg->back[i].alias.name,
				cfg->back[i].alias.name_len, buf_stratum,
				stratum_len) == 0
			&& pstrcmp(cfg->back[i].lpath, cfg->back[i].lpath_len,
				buf_lpath, lpath_len) == 0) {
			return size;
		}
	}

	/*
	 * Make a new back_entry.
	 */
	char *lpath = NULL;
	char *stratum = NULL;
	int root_fd = -1;
	int new_fd = 0;
	struct back_entry *back = NULL;

	lpath = malloc(lpath_len + 1);
	if (lpath == NULL) {
		goto free_and_abort_enomem;
	}
	memcpy(lpath, buf_lpath, lpath_len + 1);

	stratum = malloc(stratum_len + 1);
	if (stratum == NULL) {
		goto free_and_abort_enomem;
	}
	memcpy(stratum, buf_stratum, stratum_len + 1);

	int local = pstrcmp(stratum, stratum_len, LOCAL, LOCAL_LEN) == 0;

	/*
	 * Re-use root_fd for the given stratum, if available.
	 */
	for (size_t i = 0; i < cfg_cnt; i++) {
		for (size_t j = 0; j < cfgs[i].back_cnt; j++) {
			if (pstrcmp(cfgs[i].back[j].alias.name,
					cfgs[i].back[j].alias.name_len, stratum,
					stratum_len) == 0) {
				root_fd = cfgs[i].back[j].alias.root_fd;
				break;
			}
		}
	}
	/*
	 * No previous one exists and we are not local alias (which ignores
	 * .root_fd), open a new one.
	 *
	 * If local alias, keep it -1 to ensure a bug elsewhere does not
	 * accidentally close a desired file descriptor.
	 */
	if (!local && root_fd < 0) {
		root_fd = fchroot_open(strata_root_fd, stratum, O_DIRECTORY);
		new_fd = 1;
	}
	if (!local && root_fd < 0) {
		goto free_and_abort_enomem;
	}

	if (cfg->back_alloc < cfg->back_cnt + 1) {
		back = realloc(cfg->back, (cfg->back_cnt + 1) *
			sizeof(struct back_entry));
		if (back == NULL) {
			goto free_and_abort_enomem;
		}
		cfg->back = back;
		cfg->back_alloc = cfg->back_cnt + 1;
	}
	back = &cfg->back[cfg->back_cnt];

	back->lpath = lpath;
	back->lpath_len = lpath_len;
	back->alias.name = stratum;
	back->alias.name_len = stratum_len;
	back->alias.root_fd = root_fd;
	back->local = local;
	cfg->back_cnt++;

	cfg_stat.st_size += strlen(nbuf) - CMD_ADD_LEN - 1;

	return size;

free_and_abort_enomem:
	if (lpath != NULL) {
		free(lpath);
	}
	if (stratum != NULL) {
		free(stratum);
	}
	if (root_fd >= 0 && new_fd == 1) {
		close(root_fd);
	}

	return -ENOMEM;
}

/*
 * Parse and apply instruction to rm configuration.  Expected format is:
 *
 *     rm [path] [stratum]:[value-path]\n
 *
 * For example:
 *
 *     rm /pin/bin/sv void:/usr/bin/sv\n
 *
 * Another example:
 *
 *     rm /applications solus:/usr/share/applications\n
 *
 * Every line should have a trailing newline, as shown above.
 *
 * Every path item should start with a forward slash.
 *
 * Entire line must be expressed within a single call and must fit within
 * PIPE_BUF, including trailing null.  Close and sync after each line.
 *
 * The filter value is only meaningful in the first submission for a path.
 */
static int cfg_rm(const char *const buf, size_t size)
{
	/*
	 * Ensure there is a trailing null so that sscanf doesn't overflow if
	 * we somehow get bad input.
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
	char buf_filter[PIPE_BUF];
	char space2;
	char buf_cpath[PIPE_BUF];
	char space3;
	char buf_stratum[PIPE_BUF];
	char buf_lpath[PIPE_BUF];
	char newline;
	if (sscanf(nbuf, "%s%c%s%c%s%c%[^:]:%s%c", buf_cmd, &space1,
			buf_filter, &space2, buf_cpath, &space3,
			buf_stratum, buf_lpath, &newline) != 9) {
		return -EINVAL;
	}

	/*
	 * Sanity check
	 */
	if (strcmp(buf_cmd, CMD_RM) != 0 || buf_cpath[0] != '/'
		|| buf_lpath[0] != '/' || space1 != ' '
		|| space2 != ' ' || space3 != ' ' || newline != '\n'
		|| strchr(buf_stratum, '/') != NULL) {
		return -EINVAL;
	}

	/*
	 * Find cfg_entry
	 */
	struct cfg_entry *cfg = NULL;
	size_t cpath_len = strlen(buf_cpath);
	for (size_t i = 0; i < cfg_cnt; i++) {
		if (pstrcmp(cfgs[i].cpath, cfgs[i].cpath_len, buf_cpath,
				cpath_len) == 0) {
			cfg = &cfgs[i];
			break;
		}
	}
	if (cfg == NULL) {
		return -EINVAL;
	}

	/*
	 * Find back_entry
	 */
	struct back_entry *back = NULL;
	size_t stratum_len = strlen(buf_stratum);
	size_t lpath_len = strlen(buf_lpath);
	for (size_t i = 0; i < cfg->back_cnt; i++) {
		if (pstrcmp(cfg->back[i].alias.name,
				cfg->back[i].alias.name_len, buf_stratum,
				stratum_len) == 0
			&& pstrcmp(cfg->back[i].lpath, cfg->back[i].lpath_len,
				buf_lpath, lpath_len) == 0) {
			back = &cfg->back[i];
			break;
		}
	}
	if (back == NULL) {
		return -EINVAL;
	}

	/*
	 * Check if root_fd is shared
	 */
	int root_fd_cnt = 0;
	for (size_t i = 0; i < cfg_cnt; i++) {
		for (size_t j = 0; j < cfgs[i].back_cnt; j++) {
			if (cfgs[i].back[j].alias.root_fd ==
				back->alias.root_fd) {
				root_fd_cnt++;
			}
		}
	}

	/*
	 * Free
	 */
	free(back->alias.name);
	free(back->lpath);
	if (!back->local && root_fd_cnt == 1) {
		close(back->alias.root_fd);
	}

	if (&cfg->back[cfg->back_cnt - 1] != back) {
		*back = cfg->back[cfg->back_cnt - 1];
	}
	cfg->back_cnt--;
	cfg_stat.st_size -= strlen(nbuf) - CMD_RM_LEN - 1;

	if (cfg->back_cnt == 0) {
		free(cfg->cpath);
		free(cfg->back);
		if (&cfgs[cfg_cnt - 1] != cfg) {
			*cfg = cfgs[cfg_cnt - 1];
		}
		cfg_cnt--;
	}

	return size;
}

static int cfg_read(char *buf, size_t size, off_t offset)
{
	if (cfg_cnt == 0) {
		buf[0] = '\0';
		return 0;
	}

	char *str = malloc(cfg_stat.st_size + 1);
	if (str == NULL) {
		return -ENOMEM;
	}
	str[0] = '\0';

	for (size_t i = 0; i < cfg_cnt; i++) {
		for (size_t j = 0; j < cfgs[i].back_cnt; j++) {
			strcat(str, filter_str[cfgs[i].filter]);
			strcat(str, " ");
			strcat(str, cfgs[i].cpath);
			strcat(str, " ");
			strcat(str, cfgs[i].back[j].alias.name);
			strcat(str, ":");
			strcat(str, cfgs[i].back[j].lpath);
			strcat(str, "\n");
		}
	}

	int rv = MIN(strlen(str + offset), size);
	memcpy(buf, str + offset, rv);
	free(str);
	return rv;
}

int vstrcmp(void *a, void *b)
{
	struct h_kv *kv1 = (struct h_kv *)a;
	struct h_kv *kv2 = (struct h_kv *)b;
	return strcmp(kv1->key, kv2->key);
}

/*
 * Populate hash table with the contents of all backing fonts.dir or
 * fonts.alias file contents.
 */
static inline int font_merge_kv(struct cfg_entry *cfg, const char *ipath,
	size_t ipath_len, struct h_kv **kvs)
{
	int rv = -ENOENT;
	for (size_t i = 0; i < cfg->back_cnt; i++) {
		char tmp[PATH_MAX];
		char *bpath = calc_bpath(cfg, &cfg->back[i], ipath,
			ipath_len, tmp);
		if (bpath == NULL) {
			continue;
		}

		FILE *fp = fchroot_fopen(deref(&cfg->back[i])->root_fd, bpath,
			"r");
		if (fp == NULL) {
			continue;
		}
		/*
		 * An open-able file exists.
		 */
		rv = 0;

		char line[PATH_MAX];
		while (fgets(line, sizeof(line), fp) != NULL) {
			/*
			 * Skip comments
			 */
			if (line[0] == '!') {
				continue;
			}
			/*
			 * These files are key-value pairs.  There should be a
			 * separator between the keys and values.
			 */
			char *sep;
			if ((sep = strchr(line, ' ')) == NULL &&
				(sep = strchr(line, '\t')) == NULL) {
				continue;
			}
			size_t key_len = sep - line;
			/*
			 * The separator may be multiple characters long.
			 */
			do {
				*sep = '\0';
				sep++;
			} while (*sep == ' ' || *sep == '\t');
			rv = insert_h_kv(kvs, line, key_len, sep);
			if (rv < 0) {
				break;
			}
		}
		fclose(fp);

	}
	return rv;
}

/*
 * Populate contents of a virtual directory.
 */
static inline int virt_filldir(const char *ipath, size_t ipath_len,
	struct h_str *files)
{
	int rv = 0;
	for (size_t i = 0; i < cfg_cnt; i++) {
		/*
		 * We're only considering contents of a virtual path.
		 */
		if (!is_parent(ipath, ipath_len, cfgs[i].cpath,
				cfgs[i].cpath_len)) {
			continue;
		}

		char *slash = memchr(cfgs[i].cpath + ipath_len + 1, '/',
			cfgs[i].cpath_len - ipath_len - 1);
		if (slash != NULL) {
			/*
			 * cpath is a grand child of the ipath.  The direct
			 * child must be a virtual directory.  Consider:
			 *
			 *     cpath = /pin/bin/sv
			 *     ipath = /pin
			 *
			 * bin, the direct child of the ipath, is virtual.
			 */
			char tmp[PATH_MAX];
			ssize_t tmp_size = sizeof(tmp);
			if ((slash - cfgs[i].cpath) + 1 > tmp_size) {
				continue;
			}
			memcpy(tmp, cfgs[i].cpath + ipath_len + 1,
				slash - cfgs[i].cpath);
			size_t len = slash - cfgs[i].cpath - ipath_len - 1;
			tmp[len] = '\0';
			rv |= insert_h_str(&files, tmp, len);
			continue;
		}

		/*
		 * cpath is a direct child of the ipath.  There needs to be a
		 * backing file to list it.
		 */
		for (size_t j = 0; j < cfgs[i].back_cnt; j++) {
			struct stat stbuf;
			if (fchroot_stat(deref(&cfgs[i].back[j])->root_fd,
					cfgs[i].back[j].lpath, &stbuf) >= 0) {
				size_t len =
					strlen(cfgs[i].cpath + ipath_len + 1);
				rv |= insert_h_str(&files,
					cfgs[i].cpath + ipath_len + 1, len);
				break;
			}
		}

	}
	return rv;
}

/*
 * Populate thread-local storage with information about calling process'
 * stratum.
 */
static inline int set_local_stratum(void)
{
	local_stratum.name = local_stratum_name;
	local_stratum.name[0] = '\0';
	local_stratum.name_len = 0;
	local_stratum.root_fd = 0;

	struct fuse_context *context = fuse_get_context();
	if (context == NULL) {
		goto fallback_virtual;
	}

	char procroot[PATH_MAX];
	int s = snprintf(procroot, PATH_MAX, "/proc/%d/root", context->pid);
	if (s < 0 || s >= (int)sizeof(procroot)) {
		goto fallback_virtual;
	}

	local_stratum.root_fd =
		fchroot_open(init_root_fd, procroot, O_DIRECTORY);
	if (local_stratum.root_fd < 0) {
		goto fallback_virtual;
	}

	ssize_t len = fgetxattr(local_stratum.root_fd, STRATUM_XATTR,
		local_stratum_name, sizeof(local_stratum_name) - 1);
	if (len < 0) {
		close(local_stratum.root_fd);
		goto fallback_virtual;
	}
	local_stratum.name_len = len;
	local_stratum_name[len] = '\0';
	return 0;

fallback_virtual:
	/*
	 * The above attempt to associate a stratum will fail on some
	 * processes, including kernel processes and sandboxed userland
	 * processes.
	 *
	 * Treat them as the virtual stratum.
	 */
	local_stratum.root_fd = fchroot_open(strata_root_fd, VIRTUAL_STRATUM,
		O_DIRECTORY);
	if (local_stratum.root_fd < 0) {
		return -ESRCH;
	}
	if (VIRTUAL_STRATUM_LEN >= sizeof(local_stratum_name)) {
		return -ENAMETOOLONG;
	}
	strcpy(local_stratum_name, VIRTUAL_STRATUM);
	local_stratum.name_len = VIRTUAL_STRATUM_LEN;
	return 0;
}

static inline int getattr_back(struct cfg_entry *cfg, const char *ipath,
	size_t ipath_len, struct stat *stbuf)
{
	int rv = stat_first_bpath(cfg, ipath, ipath_len, stbuf);
	if (rv < 0) {
		return -errno;
	}

	switch (cfg->filter) {
	case FILTER_BIN:
	case FILTER_BIN_RESTRICT:
		if (!S_ISDIR(stbuf->st_mode)) {
			stbuf->st_size = bouncer_size;
			/*
			 * The bouncer needs to permissions to read itself in
			 * order to check its xattrs to know where to redirect.
			 *
			 * Note this is only changing the bouncer's
			 * permissions, not that of the underlying file, and
			 * thus is not exposing anything sensitive.  Bouncer is
			 * world-readable anyways at BOUNCER_PATH.
			 */
			stbuf->st_mode |= S_IRUSR | S_IRGRP | S_IROTH;
		}
		break;

	case FILTER_INI:
		if (!S_ISREG(stbuf->st_mode)) {
			break;
		}

		struct back_entry *back;
		char bpath[PATH_MAX];
		rv = loc_first_bpath(cfg, ipath, ipath_len, &back, bpath);
		if (rv < 0) {
			rv = -errno;
			break;
		}

		FILE *fp = fchroot_fopen(deref(back)->root_fd, bpath, "r");
		if (fp == NULL) {
			rv = -errno;
			break;
		}

		char line[PATH_MAX];
		while (fgets(line, sizeof(line), fp) != NULL) {
			for (size_t i = 0; i < ARRAY_LEN(ini_exec_str); i++) {
				/*
				 * No ini_exec_len will exceed line's PATH_MAX,
				 * this should be safe.
				 */
				if (memcmp(line, ini_exec_str[i],
						ini_exec_len[i]) != 0) {
					continue;
				}
				stbuf->st_size += STRAT_PATH_LEN;
				stbuf->st_size += strlen(" ");
				stbuf->st_size += deref(back)->name_len;
				stbuf->st_size += strlen(" ");
				break;
			}
		}
		fclose(fp);
		break;

	case FILTER_FONT:
		;
		/*
		 * Check if file needs to be merged
		 */
		char *slash = strrchr(ipath, '/');
		if (slash == NULL) {
			break;
		}
		size_t len = ipath_len - (slash - ipath) - 1;
		if (pstrcmp(slash + 1, len, FONTS_DIR, FONTS_DIR_LEN) != 0
			&& pstrcmp(slash + 1, len, FONTS_ALIAS,
				FONTS_ALIAS_LEN) != 0) {
			break;
		}

		/*
		 * Need to get lines from every instance of file and merge
		 * them.
		 */
		struct h_kv *kvs = NULL;
		rv = font_merge_kv(cfg, ipath, ipath_len, &kvs);
		if (rv < 0) {
			break;
		}

		stbuf->st_size = 0;
		size_t count = 0;
		struct h_kv *kv;
		struct h_kv *tmp;
		HASH_ITER(hh, kvs, kv, tmp) {
			if (rv == 0) {
				stbuf->st_size += strlen(kv->key);
				stbuf->st_size += strlen("\t");
				stbuf->st_size += strlen(kv->value);
			}
#ifndef __clang_analyzer__
			/*
			 * clang-analyzer gets confused by uthash:
			 * https://groups.google.com/forum/#!topic/uthash/l6vflep00p0
			 */
			HASH_DEL(kvs, kv);
#endif
			free(kv->value);
			free(kv);
		}
		if (pstrcmp(slash + 1, len, FONTS_DIR, FONTS_DIR_LEN) == 0) {
			/* TODO: populate count line */
			char buf[PATH_MAX];
			int wrote = snprintf(buf, sizeof(buf), "%lu\n", count);
			if (wrote < 0 || wrote >= (int)sizeof(buf)) {
				rv = -EINVAL;
			} else {
				stbuf->st_size += wrote;
			}
		}
		break;

	case FILTER_PASS:
	default:
		break;
	}

	/*
	 * Remove setuid/setgid properties and write properties.
	 *
	 * setuid/setgid is a possible attack vector, and doesn't actually
	 * benefit us as an underlying executable to which we're redirecting
	 * will retain that property.
	 *
	 * Baring CFG_PATH, this filesystem is read-only.
	 */
	stbuf->st_mode &=
		~(S_ISUID | S_ISGID | S_ISVTX | S_IWUSR | S_IWGRP | S_IWOTH);

	return rv;
}

static int m_getattr(const char *ipath, struct stat *stbuf,
	struct fuse_file_info *fi)
{
	(void)fi;

	FS_IMP_SETUP(CFG_RDLOCK);

	size_t ipath_len = strlen(ipath);
	struct cfg_entry *cfg;
	switch (classify_ipath(ipath, ipath_len, &cfg)) {
	case CLASS_BACK:
		rv = getattr_back(cfg, ipath, ipath_len, stbuf);
		break;

	case CLASS_VDIR:
	case CLASS_ROOT:
		*stbuf = vdir_stat;
		rv = 0;
		break;

	case CLASS_CFG:
		*stbuf = cfg_stat;
		rv = 0;
		break;

	case CLASS_LOCAL:
		*stbuf = local_stat;
		stbuf->st_size = local_stratum.name_len;
		break;

	case CLASS_ENOENT:
	default:
		rv = -ENOENT;
		break;
	}

	FS_IMP_RETURN(rv);
}

static int m_readlink(const char *ipath, char *buf, size_t size)
{
	FS_IMP_SETUP(CFG_RDLOCK);

	size_t ipath_len = strlen(ipath);
	struct cfg_entry *cfg;
	switch (classify_ipath(ipath, ipath_len, &cfg)) {
	case CLASS_BACK:
	case CLASS_VDIR:
	case CLASS_ROOT:
	case CLASS_CFG:
		rv = -EINVAL;
		break;

	case CLASS_LOCAL:
		if (STRATA_ROOT_LEN + local_stratum.name_len >= size) {
			return -ENAMETOOLONG;
		} else {
			strcpy(buf, STRATA_ROOT);
			strcat(buf, local_stratum.name);
		}
		break;

	case CLASS_ENOENT:
	default:
		rv = -ENOENT;
		break;
	}

	FS_IMP_RETURN(rv);
}

static int m_readdir(const char *ipath, void *buf, fuse_fill_dir_t filler,
	off_t offset, struct fuse_file_info *fi, enum fuse_readdir_flags flags)
{
	(void)offset;
	(void)fi;
	(void)flags;

	FS_IMP_SETUP(CFG_RDLOCK);

	struct h_str *files = NULL;
	rv |= insert_h_str(&files, ".", 1);
	rv |= insert_h_str(&files, "..", 2);

	size_t ipath_len = strlen(ipath);
	struct cfg_entry *cfg;
	switch (classify_ipath(ipath, ipath_len, &cfg)) {
	case CLASS_BACK:
		rv |= filldir_all_bpath(cfg, ipath, ipath_len, files);

		break;

	case CLASS_ROOT:
		rv |= insert_h_str(&files, CFG_NAME, CFG_NAME_LEN);
		rv |= insert_h_str(&files, LOCAL_ALIAS_NAME,
			LOCAL_ALIAS_NAME_LEN);
		ipath_len = 0;
		/* fallthrough */
	case CLASS_VDIR:
		rv |= virt_filldir(ipath, ipath_len, files);
		break;

	case CLASS_CFG:
	case CLASS_LOCAL:
	case CLASS_ENOENT:
	default:
		rv = -ENOENT;
		break;
	}

	struct h_str *file = NULL;
	struct h_str *tmp = NULL;
	HASH_ITER(hh, files, file, tmp) {
		if (rv == 0) {
			filler(buf, file->str, NULL, 0, 0);
		}
#ifndef __clang_analyzer__
		/*
		 * clang-analyzer gets confused by uthash:
		 * https://groups.google.com/forum/#!topic/uthash/l6vflep00p0
		 */
		HASH_DEL(files, file);
#endif
		free(file);
	}

	FS_IMP_RETURN(rv);
}

static int m_open(const char *ipath, struct fuse_file_info *fi)
{
	FS_IMP_SETUP(CFG_RDLOCK);

	size_t ipath_len = strlen(ipath);
	struct cfg_entry *cfg;
	switch (classify_ipath(ipath, ipath_len, &cfg)) {
	case CLASS_BACK:
		;
		int fd = open_first_bpath(cfg, ipath, ipath_len, fi->flags);
		if (fd >= 0) {
			close(fd);
		}
		/*
		 * The bouncer needs to permissions to read itself in order to
		 * check its xattrs to know where to redirect.
		 *
		 * Note this is only changing the bouncer's permissions, not
		 * that of the underlying file, and thus is not exposing
		 * anything sensitive.  Bouncer is world-readable anyways at
		 * BOUNCER_PATH.
		 */
		if ((cfg->filter == FILTER_BIN
				|| cfg->filter == FILTER_BIN_RESTRICT)
			&& ((fi->flags & 3) == O_RDONLY)
			&& fd < 0 && errno == EACCES) {
			rv = 0;
		} else if (fd < 0) {
			rv = -errno;
		} else if ((fi->flags & 3) != O_RDONLY) {
			rv = -EROFS;
		} else {
			rv = 0;
		}
		break;

	case CLASS_VDIR:
	case CLASS_ROOT:
		rv = 0;
		break;

	case CLASS_CFG:
		;
		struct fuse_context *context = fuse_get_context();
		if (context->uid != 0) {
			rv = -EACCES;
		} else {
			rv = 0;
		}
		break;

	case CLASS_LOCAL:
		rv = -ELOOP;
		break;

	case CLASS_ENOENT:
	default:
		rv = -ENOENT;
		break;
	}

	FS_IMP_RETURN(rv);
}

static inline int read_pass(struct cfg_entry *cfg, const char *const ipath,
	size_t ipath_len, char *buf, size_t size, off_t offset)
{
	int rv;
	int fd = open_first_bpath(cfg, ipath, ipath_len, O_RDONLY);
	if (fd < 0) {
		rv = -errno;
	} else {
		rv = pread(fd, buf, size, offset);
		close(fd);
	}
	return rv;
}

static inline int read_back(struct cfg_entry *cfg, const char *ipath, size_t
	ipath_len, char *buf, size_t size, off_t offset)
{
	int rv;

	switch (cfg->filter) {
	case FILTER_BIN:
	case FILTER_BIN_RESTRICT:
		rv = pread(bouncer_fd, buf, size, offset);
		break;

	case FILTER_INI:
		;
		struct back_entry *back;
		char bpath[PATH_MAX];
		rv = loc_first_bpath(cfg, ipath, ipath_len, &back, bpath);
		if (rv < 0) {
			rv = -errno;
			break;
		}

		FILE *fp = fchroot_fopen(deref(back)->root_fd, bpath, "r");
		if (fp == NULL) {
			rv = -errno;
			break;
		}

		size_t wrote = 0;
		char line[PATH_MAX];
		if (offset < 0) {
			rv = -EINVAL;
			break;
		}
		size_t off = offset;
		while (fgets(line, sizeof(line), fp) != NULL) {
			int found = 0;
			for (size_t i = 0; i < ARRAY_LEN(ini_exec_str); i++) {
				if (strncmp(line, ini_exec_str[i],
						ini_exec_len[i]) != 0) {
					continue;
				}
				strcatoff(buf, ini_exec_str[i], ini_exec_len[i],
					&off, &wrote, size);
				strcatoff(buf, STRAT_PATH, STRAT_PATH_LEN,
					&off, &wrote, size);
				strcatoff(buf, " ", 1, &off, &wrote, size);
				strcatoff(buf, deref(back)->name,
					deref(back)->name_len, &off, &wrote,
					size);
				strcatoff(buf, " ", 1, &off, &wrote, size);
				strcatoff(buf, line + ini_exec_len[i],
					strlen(line + ini_exec_len[i]),
					&off, &wrote, size);
				found = 1;
				break;
			}
			if (!found) {
				strcatoff(buf, line, strlen(line), &off,
					&wrote, size);
			}
			if (wrote >= size) {
				break;
			}
		}
		rv = wrote;
		fclose(fp);
		break;

	case FILTER_FONT:
		;
		/*
		 * Check if file needs to be merged
		 */
		char *slash = strrchr(ipath, '/');
		if (slash == NULL) {
			rv = read_pass(cfg, ipath, ipath_len, buf, size,
				offset);
			break;
		}
		size_t len = ipath_len - (slash - ipath) - 1;
		if (pstrcmp(slash + 1, len, FONTS_DIR, FONTS_DIR_LEN) != 0
			&& pstrcmp(slash + 1, len, FONTS_ALIAS,
				FONTS_ALIAS_LEN) != 0) {
			rv = read_pass(cfg, ipath, ipath_len, buf, size,
				offset);
			break;
		}

		/*
		 * Need to get lines from every instance of file and merge
		 * them.
		 */
		struct h_kv *kvs = NULL;
		rv = font_merge_kv(cfg, ipath, ipath_len, &kvs);
		if (rv < 0) {
			break;
		}

		wrote = 0;
		off = offset;

		/*
		 * Handle line count line
		 */
		if (pstrcmp(slash + 1, len, FONTS_DIR, FONTS_DIR_LEN) == 0) {
			char count[PATH_MAX];
			int s = snprintf(count, sizeof(count), "%u\n",
				HASH_COUNT(kvs));
			if (s < 0 || s >= (int)sizeof(buf)) {
				rv = -EINVAL;
				break;
			}
			strcatoff(buf, count, s, &off, &wrote, size);
		}

		/*
		 * return key-value pairs, sorted
		 */
		HASH_SORT(kvs, vstrcmp);
		struct h_kv *kv;
		struct h_kv *tmp;
		HASH_ITER(hh, kvs, kv, tmp) {
			if (rv >= 0) {
				strcatoff(buf, kv->key, strlen(kv->key),
					&off, &wrote, size);
				strcatoff(buf, "\t", 1, &off, &wrote, size);
				strcatoff(buf, kv->value, strlen(kv->value),
					&off, &wrote, size);
			}
#ifndef __clang_analyzer__
			/*
			 * clang-analyzer gets confused by uthash:
			 * https://groups.google.com/forum/#!topic/uthash/l6vflep00p0
			 */
			HASH_DEL(kvs, kv);
#endif
			free(kv->value);
			free(kv);
		}
		rv = wrote;
		break;

	case FILTER_PASS:
	default:
		rv = read_pass(cfg, ipath, ipath_len, buf, size, offset);
		break;
	}

	return rv;
}

static int m_read(const char *ipath, char *buf, size_t size, off_t offset,
	struct fuse_file_info *fi)
{
	(void)fi;

	FS_IMP_SETUP(CFG_RDLOCK);

	size_t ipath_len = strlen(ipath);
	struct cfg_entry *cfg;
	switch (classify_ipath(ipath, ipath_len, &cfg)) {
	case CLASS_BACK:
		rv = read_back(cfg, ipath, ipath_len, buf, size, offset);
		break;

	case CLASS_CFG:
		;
		struct fuse_context *context = fuse_get_context();
		if (context->uid == 0) {
			rv = cfg_read(buf, size, offset);
		} else {
			rv = -EACCES;
		}
		break;

	case CLASS_VDIR:
	case CLASS_ROOT:
		rv = -EISDIR;
		break;

	case CLASS_LOCAL:
		rv = -EBADF;
		break;

	case CLASS_ENOENT:
	default:
		rv = -ENOENT;
		break;
	}

	FS_IMP_RETURN(rv);
}

static int m_write(const char *ipath, const char *buf, size_t size,
	off_t offset, struct fuse_file_info *fi)
{
	(void)offset;
	(void)fi;

	FS_IMP_SETUP(CFG_WRLOCK);

	size_t ipath_len = strlen(ipath);
	struct fuse_context *context = fuse_get_context();
	if (pstrcmp(ipath, ipath_len, CFG_PATH, CFG_PATH_LEN) != 0) {
		rv = -EROFS;
	} else if (context->uid != 0) {
		rv = -EACCES;
	} else if (size >= CMD_CLEAR_LEN && memcmp(buf, CMD_CLEAR,
			CMD_CLEAR_LEN) == 0) {
		cfg_clear();
		rv = size;
	} else if (size >= CMD_ADD_LEN && memcmp(buf, CMD_ADD,
			CMD_ADD_LEN) == 0) {
		rv = cfg_add(buf, size);
	} else if (size >= CMD_RM_LEN && memcmp(buf, CMD_RM, CMD_RM_LEN) == 0) {
		rv = cfg_rm(buf, size);
	} else {
		rv = -EINVAL;
	}

	FS_IMP_RETURN(rv);
}

static int m_getxattr(const char *ipath, const char *name, char *value,
	size_t size)
{
	FS_IMP_SETUP(CFG_WRLOCK);

	size_t name_len = strlen(name);
	char *target;
	size_t target_len;

	size_t ipath_len = strlen(ipath);
	struct cfg_entry *cfg;
	switch (classify_ipath(ipath, ipath_len, &cfg)) {
	case CLASS_BACK:
		;
		char bpath[PATH_MAX];
		struct back_entry *back;
		if (pstrcmp(name, name_len, STRATUM_XATTR,
				STRATUM_XATTR_LEN) == 0) {
			rv = loc_first_bpath(cfg, ipath, ipath_len, &back,
				bpath);
			if (rv >= 0) {
				target = deref(back)->name;
				target_len = deref(back)->name_len;
			}
		} else if (pstrcmp(name, name_len, LPATH_XATTR,
				LPATH_XATTR_LEN) == 0) {
			rv = loc_first_bpath(cfg, ipath, ipath_len, &back,
				bpath);
			if (rv >= 0) {
				target = bpath;
				target_len = strlen(bpath);
			}
		} else if (pstrcmp(name, name_len, RESTRICT_XATTR,
				RESTRICT_XATTR_LEN) == 0 &&
			cfg->filter == FILTER_BIN_RESTRICT) {
			rv = 0;
			target = RESTRICT;
			target_len = RESTRICT_LEN;
		} else {
			rv = -ENOTSUP;
		}
		break;

	case CLASS_VDIR:
	case CLASS_ROOT:
	case CLASS_CFG:
	case CLASS_LOCAL:
		if (pstrcmp(name, name_len, STRATUM_XATTR,
				STRATUM_XATTR_LEN) == 0) {
			rv = 0;
			target = VIRTUAL_STRATUM;
			target_len = VIRTUAL_STRATUM_LEN;
		} else if (pstrcmp(name, name_len, LPATH_XATTR,
				LPATH_XATTR_LEN) == 0) {
			rv = 0;
			target = VIRTUAL_LPATH;
			target_len = VIRTUAL_LPATH_LEN;
		} else {
			rv = -ENOTSUP;
		}
		break;

	case CLASS_ENOENT:
	default:
		rv = -ENOENT;
		break;
	}

	if (rv >= 0) {
		/*
		 * Include trailing null
		 */
		target_len++;

		if (size == 0) {
			rv = target_len;
		} else if (size < target_len) {
			rv = -ERANGE;
		} else {
			memcpy(value, target, target_len);
			rv = target_len;
		}
	}

	FS_IMP_RETURN(rv);
}

/*
 * Run on umount.
 */
static void m_destroy(void *private_data)
{
	(void)private_data;
	/*
	 * Valgrind's cachegrind and callgrind tools expect the program
	 * to end in the same chroot as it started.
	 */
	fchdir(init_root_fd);
	chroot(".");
	exit(0);
}

/*
 * Implemented FUSE functions
 */
static struct fuse_operations m_oper = {
	.getattr = m_getattr,
	.readlink = m_readlink,
	.readdir = m_readdir,
	.open = m_open,
	.read = m_read,
	.write = m_write,
	.getxattr = m_getxattr,
	.destroy = m_destroy,
};

int main(int argc, char *argv[])
{
	/*
	 * Ensure we are running as root.  This is needed both to setfsuid() to
	 * any user (including root) and chroot().
	 */
	if (getuid() != 0) {
		fprintf(stderr, "crossfs: error not running as root.\n");
		return 1;
	}

	/*
	 * Get reference file descriptors
	 */
	if ((init_root_fd = open("/", O_DIRECTORY)) < 0) {
		fprintf(stderr, "crossfs: unable to open \"/\".\n");
		return 1;
	}
	current_root_fd = init_root_fd;
	if ((strata_root_fd = open(STRATA_ROOT, O_DIRECTORY)) < 0) {
		fprintf(stderr, "crossfs: unable to open \"" STRATA_ROOT
			"\".\n");
		return 1;
	}
	if ((bouncer_fd = open(BOUNCER_PATH, O_RDONLY)) < 0) {
		fprintf(stderr, "crossfs: unable to open \"" BOUNCER_PATH
			"\".\n");
		return 1;
	}

	/*
	 * Initialize mutexes
	 */
	if (pthread_rwlock_init(&cfg_lock, NULL) < 0
		|| pthread_mutex_init(&root_lock, NULL) < 0) {
		fprintf(stderr, "crossfs: error initializing mutexes\n");
		return 1;
	}

	/*
	 * Pre-calculate common stat() values.
	 */

	memset(&vdir_stat, 0, sizeof(struct stat));
	vdir_stat.st_ctime = time(NULL);
	vdir_stat.st_mtime = vdir_stat.st_ctime;
	vdir_stat.st_atime = vdir_stat.st_ctime;
	vdir_stat.st_mode = S_IFDIR | 0555;

	memcpy(&cfg_stat, &vdir_stat, sizeof(struct stat));
	cfg_stat.st_mode = S_IFREG | 0600;
	cfg_stat.st_size = 0;

	memcpy(&local_stat, &vdir_stat, sizeof(struct stat));
	local_stat.st_mode = S_IFLNK | 0777;

	struct stat bouncer_stat;
	if (fstat(bouncer_fd, &bouncer_stat) < 0) {
		fprintf(stderr, "crossfs: could not stat \"" BOUNCER_PATH
			"\"\n");
		return 1;
	}
	bouncer_size = bouncer_stat.st_size;

	/*
	 * Mount filesystem.
	 *
	 * Incoming filesystem calls will be fulfilled by the functions listed
	 * in m_oper above.
	 */
	return fuse_main(argc, argv, &m_oper, NULL);
}
