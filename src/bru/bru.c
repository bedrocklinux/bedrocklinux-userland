/*
 * bru.c
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * version 2 as published by the Free Software Foundation.
 *
 * Copyright (c) 2013 Daniel Thau <paradigm@bedrocklinux.org>
 *
 * This program will mount a virtual filesystem in the directory provided as
 * the first argument.  It will redirect filesystem calls to the directory
 * provided either as the second or third argument, depending on whether or not
 * file(s) being operated on show up in the following arguments.
 *
 * For example, if bru is called with
 *     ./bru /tmp /mnt/realtmp /dev/shm /.X11-unix /.X0-lock
 * all calls to /tmp or its contents will be redirected to /mnt/realtmp
 * except for .X11-unix and .X0-lock, which will be redirected to
 * /dev/shm/.X11-unix and /dev/shm/.X0-lock.
 *
 * Makes heavy use of this FUSE API reference:
 *     http://fuse.sourceforge.net/doxygen/structfuse__operations.html
 *
 * Utilizes fuse 3, which at the time of writing is still pre-release.
 *
 * If you're using a standard Linux glibc-based stack, compile with:
 *     gcc -g -Wall `pkg-config fuse --cflags --libs` bru.c -o bru
 *
 * If you're using musl, compile with:
 *     musl-gcc -Wall bru.c -o bru -lfuse3
 */


#define _XOPEN_SOURCE 500

/*
 * explicitly mentioned as required in the following fuse tutorial:
 * http://sourceforge.net/apps/mediawiki/fuse/index.php?title=Hello_World
 */
#define FUSE_USE_VERSION 30
#include <fuse3/fuse.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>

#include <dirent.h>    /* DIR       */
#include <stdlib.h>    /* exit()    */
#include <sys/types.h> /* xattr     */
#include <sys/xattr.h> /* xattr     */
#include <sys/param.h> /* PATH_MAX  */
#include <sys/ioctl.h> /* ioctl     */
#include <poll.h>      /* poll      */


/*
 * Global variables.
 */
char*  mount_point;      /* where this filesystem is mounted             */
char*  default_dir;      /* where most calls will be redirected          */
int    default_dir_len;  /* length of above var                          */
char*  redir_dir;        /* where exceptions to above will be redirected */
int    redir_dir_len;    /* length of above var                          */
int    dir_len;          /* max(default_dir_len, redir_dir_len)          */
char** redir_files;      /* the list of files in which redirect to redir_dir.
                            Note these must all start with a slash but cannot
                            end with a slash.                            */
int    redir_file_count; /* the number of items in above array           */
int*   redir_file_lens;  /* length of each of the redir_file entries     */


/*
 * Macros
 *
 * These are (ab)used heavily below in order to squeeze out additional
 * performance.  This filesystem itself is overhead - most systems don't use
 * it.  This overhead should be minimized.
 */

/*
 * This macro is the core of the entire filesystem.  It is what determines
 * where things get redirected - to either default_dir or redir_dir.  It macro
 * compares the provided path against the redir_files.  If there is a match, it
 * returns the path of the file as if it was in redir_dir.  Otherwise, it
 * returns the path of the file as if it was in default_dir.
 *
 * Note that, since this is a macro and not a function, we can initialize the
 * string we are returning *on the stack* - we don't have to free() it.  This
 * is a C99-ism which is not portable to C89.  Also note due to the fact we're
 * initializing a variable in the macro which needs to be utilized after the
 * macro, we can't wrap in do{}while(0) or the scoping will make the variable
 * unavailable.
 *
 * We want to see if the passed file is either one of the redir_files
 * itself or if it is a file within a directory that is one of the
 * redir_files.  We have to check the path matching up until the redir_file's
 * terminating null, at which point the requested path could have either a null
 * as well (i.e., it is the same file) or a trailing slash (indicating it is a
 * subdirectory).
 * e.g.:
 * redir_files[i] = /foo/bar
 * path           = /foo/bar/baz
 *                          ^ different, NULL vs '/'
 *                         ^ check to here, then check for NULL or '/'
 *
 * Scoping is used to ensure the declared i variable is local.
 */
#define REDIR_PATH(path, new_path)                                         \
	char new_path[strlen(path) + dir_len + 1];                             \
	new_path[0] = '\0';                                                    \
	{                                                                      \
		int i;                                                             \
		for (i=0; i < redir_file_count; i++) {                             \
			if (strncmp(redir_files[i], path, redir_file_lens[i]) == 0     \
					&& (path[redir_file_lens[i]] == '\0'                   \
						|| path[redir_file_lens[i]] == '/')) {             \
				/*                                                         \
				 * We have a match.  Create new path concatenating the     \
				 * requested path onto redir_dir.                          \
				 */                                                        \
				strcat(new_path, redir_dir);                               \
				i = redir_file_count + 1;                                  \
			}                                                              \
		}                                                                  \
		/*                                                                 \
		 * We did not find a match against any of the redir_files.  Create \
		 * the new path concatenating the requested path onto the          \
		 * default_dir.                                                    \
		 */                                                                \
		if (i <= redir_file_count)                                         \
			strcat(new_path, default_dir);                                 \
		strcat(new_path, path);                                            \
	}

/*
 * This macro sets the filesystem uid and gid to that of the calling user.
 * This allows the kernel to take care of permissions for us.
 */
#define SET_CALLER_UID()                                                     \
	/*                                                                       \
	 * Get context (uid, gid, etc).                                          \
	 */                                                                      \
	struct fuse_context *context = fuse_get_context();                       \
	seteuid(context->uid);                                                   \
	setegid(context->gid);


/*
 * The FUSE API and Linux APIs do not match up perfectly.  One area they seem
 * to differ is that the Linux system calls tend to return -1 on error and set
 * errno to the value corresponding to the error.  FUSE, on the other hand,
 * wants (the negated version of) the error number returned.  This macro will
 * test for an error condition returned from a Linux system call and adjust it
 * for FUSE.
 */
#define SET_RET_ERRNO() if(ret < 0) ret = -errno;


/*
 * The following functions up until main() are all specific to FUSE.  See
 * FUSE's documentation - and general C POSIX filesystem documentation - for
 * details.
 *
 * It seems FUSE will handle details such as whether a given filesystem call
 * should resolve a symlink for us, and so we should always utilize the
 * versions of calls which work directly on symlinks rather than those which
 * resolve symlinks.  For example, lstat() should be utilized rather than
 * stat() when implementing getattr().
 *
 * Similarly, things like pread() and pwrite() should be utilized over read()
 * and write(); if the user wants non-p read() or write() FUSE will handle that
 * for us.
 *
 *
 * TODO/NOTE: some of the more obscure items below have not been tested, and
 * were simply written by comparing APIs.
 */

static int bru_getattr(const char *path, struct stat *stbuf)
{
	SET_CALLER_UID();
	REDIR_PATH(path, new_path);

	int ret = lstat(new_path, stbuf);

	SET_RET_ERRNO();
	return ret;
}

/*
 * The Linux readlink() manpage says it will not create the terminating null.
 * However, FUSE apparently does expect a terminating null or commands like `ls
 * -l` and `readlink` will respond incorrectly.  Linux readlink() will return the
 *  number of bytes placed in the buffer; thus, we can add the terminating null
 *  ourselves at the following byte.
 *
 * Moreover, the FUSE API says to truncate if we're over `bufsize`; so compare
 * `bufsize` to the number of bytes readlink() write to ensure we're not going
 * over `bufsize` when we write the terminating null.
 *
 * A simpler approach would be to zero-out the memory before having readlink()
 * write over it.  However, that is probably slower.
 *
 * Finally, note that readlink() returns the number of bytes placed in the
 * buffer if successful and a -1 otherwise.  FUSE readlink(), however, wants 0
 * for success.
 */

static int bru_readlink(const char *path, char *buf, size_t bufsize)
{
	SET_CALLER_UID();
	REDIR_PATH(path, new_path);

	/*
	 * Alternative approach zero out out the buffer:
	 * memset(buf, '\0', bufsize);
	 * TODO: Benchmark if this is faster.
	 */
	int bytes_read = readlink(new_path, buf, bufsize);
	int ret = 0;
	if(bytes_read < 0)
		ret = -errno;
	else if(bytes_read <= bufsize)
		buf[bytes_read] = '\0';

	return ret;
}

static int bru_mknod(const char *path, mode_t mode, dev_t dev)
{
	SET_CALLER_UID();
	REDIR_PATH(path, new_path);

	int ret = mknod(new_path, mode, dev);

	SET_RET_ERRNO();
	return ret;
}

static int bru_mkdir(const char *path, mode_t mode)
{
	SET_CALLER_UID();
	REDIR_PATH(path, new_path);

	int ret = mkdir(new_path, mode);

	SET_RET_ERRNO();
	return ret;
}

static int bru_unlink(const char *path)
{
	SET_CALLER_UID();
	REDIR_PATH(path, new_path);

	int ret = unlink(new_path);

	SET_RET_ERRNO();
	return ret;
}

static int bru_rmdir(const char *path)
{
	SET_CALLER_UID();
	REDIR_PATH(path, new_path);

	int ret = rmdir(new_path);

	SET_RET_ERRNO();
	return ret;
}

static int bru_symlink(const char *symlink_string, const char *path)
{
	SET_CALLER_UID();
	REDIR_PATH(path, new_path);

	int ret = symlink(symlink_string, new_path);

	SET_RET_ERRNO();
	return ret;
}

/*
 * rename() cannot work across filesystems/partitions due to how it works
 * under-the-hood. The way Linux checks if it is valid is by comparing the
 * mount points - even if both mount points are of the same
 * filesystem/partition, it still disallows the operation.
 *
 * Some programs, such as `mv`, will fall back to a copy/unlink if rename()
 * doesn't work.  However, others - such as groupadd - do not.  They seem
 * to assume that if two files are in the same directory - such as
 * "/etc/group-" and "/etc/group" - are in the root of same directory, they are
 * likely on the same filesystem.  This is typically a sane assumption, but
 * not with bru.  Hence we cannot simply pass rename() along as we do in
 * some of the other system calls here.  Instead, we check for EXDEV
 * (indicating the issue discussed above has happened) and, if we get that,
 * fall back to copy/unlink as something like `mv` would do.
 *
 * This could theoretically break applications which depend on rename() to
 * detect if files are on the same or different filesystems for something
 * outside outside the scope of bru.
 *
 * TODO: if an error occurs in the copy/unlink section, would we rather
 * return EXDEV or the error that actually happened?  Returning a read() or
 * write() error in a rename() could be a bit confusing, but hiding what
 * actually happened behind EXDEV could be problematic as well.
 */
static int bru_rename(const char *old_path, const char *new_path)
{
	SET_CALLER_UID();
	REDIR_PATH(old_path, redir_old_path);
	REDIR_PATH(new_path, redir_new_path);

	int ret = 0;
	/*
	 * Try rename() normally, first.
	 */
	if(rename(redir_old_path, redir_new_path) < 0)
		ret = -errno;

	/*
	 * If it did *NOT* result in an EXDEV error, return.
	 */
	if (ret != -EXDEV) {
		SET_RET_ERRNO();
		return ret;
	}

	/*
	 * The rename() operation resulted in EXDEV. Falling back to copy/unlink.
	 */

	/*
	 * Open redir_old_path for reading and create redir_new_path for writing.
	 */
	struct stat old_path_stat;
	lstat(redir_old_path, &old_path_stat);
	int redir_old_path_fd = open(redir_old_path, O_RDONLY);
	int redir_new_path_fd = creat(redir_new_path, old_path_stat.st_mode);

	int bufsize = 8192;
	char buffer[bufsize]; /* 8k */

	/*
	 * Copy
	 */
	int transfered;
	while (1) {
		transfered = read(redir_old_path_fd, buffer, bufsize);
		if (transfered < 0) {
			/*
			 * Error occurred, clean up and quit.
			 */
			close(redir_old_path_fd);
			close(redir_new_path_fd);
			ret = transfered;
			SET_RET_ERRNO();
			return ret;
		}
		/*
		 * Completed copy.
		 */
		if (transfered == 0)
			break;
		transfered = write(redir_new_path_fd, buffer, transfered);
		if (transfered < 0) {
			/*
			 * Error occurred, clean up and quit
			 */
			close(redir_old_path_fd);
			close(redir_new_path_fd);
			ret = transfered;
			SET_RET_ERRNO();
			return ret;
		}
	}

	/*
	 * Copy should have went well at this point.  Close both files.
	 */
	close(redir_old_path_fd);
	close(redir_new_path_fd);
	/*
	 * Unlink old file
	 */
	ret = unlink(redir_old_path);
	/*
	 * Check for error during unlink
	 */
	SET_RET_ERRNO();
	return ret;
}

static int bru_link(const char *old_path, const char *new_path){
	SET_CALLER_UID();
	REDIR_PATH(old_path, redir_old_path);
	REDIR_PATH(new_path, redir_new_path);

	int ret = link(redir_old_path, redir_new_path);

	SET_RET_ERRNO();
	return ret;
}

static int bru_chmod(const char *path, mode_t mode){
	SET_CALLER_UID();
	REDIR_PATH(path, new_path);
	
	int ret = chmod(new_path, mode);

	SET_RET_ERRNO();
	return ret;
}

static int bru_chown(const char *path, uid_t owner, gid_t group){
	SET_CALLER_UID();
	REDIR_PATH(path, new_path);
	
	int ret = lchown(new_path, owner, group);

	SET_RET_ERRNO();
	return ret;
}

static int bru_truncate(const char *path, off_t length){
	SET_CALLER_UID();
	REDIR_PATH(path, new_path);

	int ret = truncate(new_path, length);

	SET_RET_ERRNO();
	return ret;
}

/*
 * Unlike POSIX open(), it seems the return value should be 0 for success, not
 * the file descriptor.
 */
static int bru_open(const char *path, struct fuse_file_info *fi)
{
	SET_CALLER_UID();
	REDIR_PATH(path, new_path);

	int ret = open(new_path, fi->flags);

	if (ret < 0) {
		ret = -errno;
	} else {
		fi->fh = ret;
		ret = 0;
	}

	return ret;
}

static int bru_read(const char *path, char *buf, size_t size, off_t offset, struct fuse_file_info *fi)
{
	SET_CALLER_UID();

	int ret = pread(fi->fh, buf, size, offset);

	SET_RET_ERRNO();
	return ret;
}

static int bru_write(const char *path, const char *buf, size_t size, off_t offset, struct fuse_file_info *fi)
{
	SET_CALLER_UID();

	int ret = pwrite(fi->fh, buf, size, offset);

	SET_RET_ERRNO();
	return ret;
}

/*
 * Using statvfs instead of statfs, per FUSE API.
 */
static int bru_statfs(const char *path, struct statvfs *buf)
{
	SET_CALLER_UID();
	REDIR_PATH(path, new_path);
	
	int ret = statvfs(new_path, buf);

	SET_RET_ERRNO();
	return ret;
}

/*
 * FUSE uses the word "release" rather than "close".
 */
static int bru_release(const char *path, struct fuse_file_info *fi)
{
	SET_CALLER_UID();

	int ret = close(fi->fh);

	SET_RET_ERRNO();
	return ret;
}

/*
 * The FUSE API talks about a 'datasync parameter' being non-zero - presumably
 * that's the second parameter, since its the only number (int).
 */
static int bru_fsync(const char *path, int datasync, struct fuse_file_info *fi)
{
	SET_CALLER_UID();

	int ret;
	if(datasync)
		ret = fdatasync(fi->fh);
	else
		ret = fsync(fi->fh);

	SET_RET_ERRNO();
	return ret;
}

static int bru_setxattr(const char *path, const char *name, const char *value, size_t size, int flags)
{
	SET_CALLER_UID();
	REDIR_PATH(path, new_path);

	int ret = lsetxattr(new_path, name, value, size, flags);

	SET_RET_ERRNO();
	return ret;
}

static int bru_getxattr(const char *path, const char *name, char *value, size_t size)
{
	SET_CALLER_UID();
	REDIR_PATH(path, new_path);

	int ret = lgetxattr(new_path, name, value, size);

	SET_RET_ERRNO();
	return ret;
}

static int bru_listxattr(const char *path, char *list, size_t size)
{
	SET_CALLER_UID();
	REDIR_PATH(path, new_path);

	int ret = llistxattr(new_path, list, size);

	SET_RET_ERRNO();
	return ret;
}

static int bru_removexattr(const char *path, const char *name)
{
	SET_CALLER_UID();
	REDIR_PATH(path, new_path);

	int ret = lremovexattr(new_path, name);

	SET_RET_ERRNO();
	return ret;
}

/*
 * FUSE uses this primarily for a permissions check.  Actually returning a
 * file handler is optional.  Unlike POSIX, this does not directly return
 * the file handler, but rather returns indictation of whether or not the user
 * may use opendir().
 */
static int bru_opendir(const char *path, struct fuse_file_info *fi)
{
	SET_CALLER_UID();
	REDIR_PATH(path, new_path);

	int ret;
	DIR *d = opendir(new_path);
	/*
	 * It seems FUSE wants an int pointer, not a directory stream pointer.
	 */
	fi->fh = (intptr_t) d;
	if (d)
		ret = 0;
	else
		ret = -errno;

	return ret;
}

/*
 * This function returns the files in a given directory.  We want to
 * actually return three groups:
 * - "." and ".."
 * - Files that match redir_files and are in the same place on redir_dir.
 * - Files that do not match redir_files and are in the same place in
 *   default_dir.
 */
static int bru_readdir(const char *path, void *buf, fuse_fill_dir_t filler, off_t offset, struct fuse_file_info *fi, enum fuse_readdir_flags flags)
{

	SET_CALLER_UID();

	int path_len = strlen(path);
	int i;
	DIR *d;
	struct dirent *dir;
	char *full_path;
	int full_path_len;
	int exists = 0;
	int match;

	/*
	 * Every directory has these.
	 */
	filler(buf, ".", NULL, 0, flags);
	filler(buf, "..", NULL, 0, flags);

	/*
	 * Populate with items from redir_dir.
	 */
	char redir_new_path[path_len + redir_dir_len + 1];
	redir_new_path[0] = '\0';
	strcat(redir_new_path, redir_dir);
	strcat(redir_new_path, path);

	d = opendir(redir_new_path);
	if (d) {
		while ((dir = readdir(d)) != NULL) {
			/*
			 * If the file is "." or "..", we can skip the rest of this iteration.
			 */
			if (strcmp(dir->d_name, ".") == 0 || strcmp(dir->d_name, "..") == 0)
				continue;
			/*
			 * dir->d_name is a file in redir_new_path.  Get the full path to
			 * this file to compare against redir_files.
			 */
			full_path_len = path_len + strlen(dir->d_name);
			full_path = malloc(full_path_len + 2);
			full_path[0] = '\0';
			strcat(full_path, path);
			if (path[1] != '\0')
				strcat(full_path, "/");
			strcat(full_path, dir->d_name);
			/*
			 * Compare to every item in redir_files.  If there are any matches, add it.
			 */
			for (i=0; i<redir_file_count; i++) {
				if (strncmp(full_path, redir_files[i], redir_file_lens[i]) == 0
						&& (full_path[redir_file_lens[i]] == '\0'
							|| full_path[redir_file_lens[i]] == '/')) {
					filler(buf, dir->d_name, NULL, 0, flags);
					break;
				}
			}
			free(full_path);
		}
		closedir(d);
		exists = 1;
	}

	/*
	 * Populate with items from default_dir.
	 */

	char default_new_path[path_len + default_dir_len + 1];
	default_new_path[0] = '\0';
	strcat(default_new_path, default_dir);
	strcat(default_new_path, path);

	d = opendir(default_new_path);
	if (d) {
		while ((dir = readdir(d)) != NULL) {
			/*
			 * If the file is "." or "..", we can skip the rest of this iteration.
			 */
			if (strcmp(dir->d_name, ".") == 0 || strcmp(dir->d_name, "..") == 0)
				continue;
			/*
			 * dir->d_name is a file in default_new_path.  Get the full path to
			 * this file to compare against redir_files.
			 */
			full_path_len = path_len + strlen(dir->d_name);
			full_path = malloc(full_path_len + 2);
			full_path[0] = '\0';
			strcat(full_path, path);
			if (path[1] != '\0')
				strcat(full_path, "/");
			strcat(full_path, dir->d_name);
			/*
			 * Compare to every item in redir_files.  If there are no matches, add it.
			 */
			match = 0;
			for (i=0; i<redir_file_count; i++) {
				if (strncmp(full_path, redir_files[i], redir_file_lens[i]) == 0
						&& (full_path[redir_file_lens[i]] == '\0'
							|| full_path[redir_file_lens[i]] == '/')) {
					match = 1;
					break;
				}
			}
			if (match == 0)
				filler(buf, dir->d_name, NULL, 0, flags);
			free(full_path);
		}
		closedir(d);
		exists = 1;
	}

	if (!exists) {
		return -ENOENT;
	}
	return 0;
}

/*
 * FUSE uses the word "release" rather than "close".
 */
static int bru_releasedir(const char *path, struct fuse_file_info *fi)
{
	SET_CALLER_UID();

	/*
	 * FUSE provides an "uint64_t" rather than DIR*
	 */
	int ret = closedir((DIR *) fi->fh);

	SET_RET_ERRNO();
	return ret;
}

/*
 * There is no POSIX fsyncdir - presumably this is just fsync when called on a
 * directory.  Mimicking code from (non-dir) fsync.
 */
static int bru_fsyncdir(const char *path, int datasync, struct fuse_file_info *fi)
{
	SET_CALLER_UID();

	int ret;
	if(datasync)
		ret = fdatasync(fi->fh);
	else
		ret = fsync(fi->fh);

	SET_RET_ERRNO();
	return ret;
}

/*
 * We cannot use POSIX access() for two reasons:
 * 1. It uses real uid, rather than effective or filesystem uid.
 * 2. It dereferences symlinks.
 * Instead, we're using faccessat().
 * TODO: To simplify things, we're mandating absolute paths.  We should
 * probably properly handle relative paths for this later and remove this
 * restriction.  Given this, the first argument to faccessat() is ignored.
 * TODO: POSIX faccessat() doesn't support AT_SYMLINK_NOFOLLOW, and neither
 * does musl.  See if we can upstream support into musl.  Utilizing
 * AT_SYMLINK_NOFOLLOW is disabled for now so it will compile against musl.
 */
static int bru_access(const char *path, int mask)
{
	SET_CALLER_UID();
	REDIR_PATH(path, new_path);

	/*
	 * Disabling AT_SYMLINK_NOFOLLOW since musl does not (yet?) support it.
	 * int ret = faccessat(0, new_path, mask, AT_EACCESS | AT_SYMLINK_NOFOLLOW);
	 */
    int ret = faccessat(0, new_path, mask, AT_EACCESS);

	SET_RET_ERRNO();
	return ret;
}

/*
 * Yes, FUSE uses creat*e* and POSIX uses creat.
 */
static int bru_create(const char *path, mode_t mode, struct fuse_file_info *fi)
{
	SET_CALLER_UID();
	REDIR_PATH(path, new_path);

	int ret = 0;
	if ((fi->fh = creat(new_path, mode)) < 0)
		ret = -errno;

	return ret;
}

static int bru_ftruncate(const char *path, off_t length, struct fuse_file_info *fi)
{
	SET_CALLER_UID();

	int ret = ftruncate(fi->fh, length);

	SET_RET_ERRNO();
	return ret;
}

static int bru_fgetattr(const char *path, struct stat *stbuf, struct fuse_file_info *fi)
{
	SET_CALLER_UID();

	int ret = fstat(fi->fh, stbuf);

	SET_RET_ERRNO();
	return ret;
}

/*
 * TODO: To simplify things, we're mandating absolute paths.  We should
 * probably properly handle relative paths for this later and remove this
 * restriction.  Given this, the first argument to utimensat() is ignored.
 */
static int bru_utimens(const char *path, const struct timespec *times)
{
	SET_CALLER_UID();
	REDIR_PATH(path, new_path);

	int ret = utimensat(0, new_path, times, AT_SYMLINK_NOFOLLOW);

	SET_RET_ERRNO();
	return ret;
}

/*
 * TODO: implement
 * static int bru_ioctl(const char *path, int request, void *arg, struct
 * 		fuse_file_info *fi, unsigned int flags, void *data)
 * {
 * 	SET_CALLER_UID();
 * 
 * 	int ret = ioctl(fi->fh, request, data);
 * 
 * 	SET_RET_ERRNO();
 * 	return ret;
 * }
 */


/*
 * This struct is a list of implemented fuse functions which is provided to
 * FUSE in main().
 */
static struct fuse_operations bru_oper = {
	.getattr = bru_getattr,
	.readlink = bru_readlink,
	.mknod = bru_mknod,
	.mkdir = bru_mkdir,
	.unlink = bru_unlink,
	.rmdir = bru_rmdir,
	.symlink = bru_symlink,
	.rename = bru_rename,
	.link = bru_link,
	.chmod = bru_chmod,
	.chown = bru_chown,
	.truncate = bru_truncate,
	.open = bru_open,
	.read = bru_read,
	.write = bru_write,
	.statfs = bru_statfs,
	/*
	 * I *think* we can skip implementing this, as the underlying filesystem
	 * will take care of it. TODO: Confirm.
	 * .flush = bru_flush,
	 */
	.release = bru_release,
	.fsync = bru_fsync,
	.setxattr = bru_setxattr,
	.getxattr = bru_getxattr,
	.listxattr = bru_listxattr,
	.removexattr = bru_removexattr,
	.opendir = bru_opendir,
	.readdir = bru_readdir,
	.releasedir = bru_releasedir,
	.fsyncdir = bru_fsyncdir,
	/*
	 * These seem to be hooks at mount/unmount time of which bru does not need
	 * to take advantage.
	 * .init = bru_init,
	 * .destroy = bru_destroy,
	 */
	.access = bru_access,
	.create = bru_create,
	.ftruncate = bru_ftruncate,
	.fgetattr = bru_fgetattr,
	/*
	 * TODO: Apparently this is unimplemented in the Linux kernel?
	 * .lock = bru_lock,
	 */
	.utimens = bru_utimens,
	/*
	 * This only makes sense for block devices.
	 * .bmap = bru_bmap,
	 */
	/*
	 * TODO: implement these:
	 * .ioctl = bru_ioctl,
	 * .poll = bru_poll,
	 * .write_buf = bru_write_buf,
	 * .read_buf = bru_read_buf,
	 * .flock = bru_flock,
	 * .fallocate = bru_fallocate,
	 */
};



int main(int argc, char* argv[])
{
	/*
	 * Print help.  If there are less than two arguments the user probably
	 * doesn't know how to use this, and will also cover things like --help and
	 * -h.
	 */
	if (argc < 3) {
		printf(
"bru - BedRock linux Union filesystem\n"
"\n"
"Usage: bru [mount-point] [default directory] [redir directory] [paths]\n"
"\n"
"Example: bru /tmp /mnt/realtmp /dev/shm /.X11-unix /.X0-lock\n"
"\n"
"[mount-point]       is the directory where the filesystem will be mounted.\n"
"[default directory] is where filesystem calls which aren't to [paths] will be\n"
"                    redirected.  This must be an absolute path.\n"
"[redir directory]   is where filesystem calls which are to [paths] will be\n"
"                    redirected.  This must be an absolute path.\n"
"[paths]             is the list of file paths relative to [mount-point]\n"
"                    which will be redirected to [redir directory].\n"
"                    Everything else will be redirected to\n"
"                    [default directory].  Note the items in [paths] must\n"
"                    all start with a slash and not end in a slash.\n");
		return 1;
	}

	/*
	 * Ensure we are running as root so that any requests by root to this
	 * filesystem can be provided.
	 */
	if(getuid() != 0){
		fprintf(stderr, "ERROR: not running as root, aborting.\n");
		return 1;
	}

	 /*
	  * There should be a minimum of four arguments (plus argv[0])
	  */
	if(argc < 5) {
		fprintf(stderr, "ERROR: Insufficient arguments.\n");
		return 1;
	}

	/*
	 * The second, third and fourth arguments should all be existing directories.
	 */
	int i;
	struct stat test_is_dir_stat;
	for(i=1;i<4;i++) {
		if (stat(argv[i], &test_is_dir_stat) != 0) {
			fprintf(stderr, "ERROR: Could not find directory \"%s\"\n", argv[i]);
			perror("stat()");
			return 1;
		}
	}

	/*
	 * The third and fourth arguments should all have absolute paths.
	 */
	for(i=2;i<4;i++) {
		if (argv[i][0] != '/'){
			fprintf(stderr, "ERROR: The following item is not a full path: \"%s\"\n", argv[i]);
			return 1;
		}
	}

	/*
	 * Store arguments in global variables
	 */
	mount_point       = argv[1];
	default_dir       = argv[2];
	default_dir_len   = strlen(argv[2]);
	redir_dir         = argv[3];
	redir_dir_len     = strlen(argv[3]);
	redir_files       = argv + 4;
	redir_file_count  = argc - 4;
	redir_file_lens = malloc(redir_file_count * sizeof(int));
	for(i = 0; i<redir_file_count; i++){
		redir_file_lens[i] = strlen(redir_files[i]);
	}
	if (default_dir_len > redir_dir_len)
		dir_len = default_dir_len;
	else
		dir_len = redir_dir_len;

	/*
	 * All of the redir_files should start with a slash and should not end with
	 * a slash.
	 */
	for(i=0;i<redir_file_count;i++) {
		if(redir_files[i][0] != '/' || redir_files[i][redir_file_lens[i]-1] == '/'){
			fprintf(stderr, "The redirection files should (1) start with a '/'"
					"and (2) *not* end with a '/'.  This one is problematic: "
					"\"%s\"\n", redir_files[i]);
			return 1;
		}
	}

	/* Generate arguments for fuse:
	 * - start with no arguments
	 * - add argv[0] (which I think is just ignored)
	 * - add mount point
	 * - disable multithreading, as with the UID/GID switching it will result
	 *   in abusable race conditions.
	 * - add argument to:
	 *   - let all users access filesystem
	 *   - allow mounting over non-empty directories
	 * */
	struct fuse_args args = FUSE_ARGS_INIT(0, NULL);
	fuse_opt_add_arg(&args, argv[0]);
	fuse_opt_add_arg(&args, mount_point);
	fuse_opt_add_arg(&args, "-s");
	fuse_opt_add_arg(&args, "-oallow_other,nonempty");
	/* stay in foreground, useful for debugging */
	fuse_opt_add_arg(&args, "-f");

	/* start fuse */
	return fuse_main(args.argc, args.argv, &bru_oper, NULL);
}
