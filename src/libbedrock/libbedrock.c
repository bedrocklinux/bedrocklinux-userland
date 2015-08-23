/*
 * libbedrock.c
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * version 2 as published by the Free Software Foundation.
 *
 * Copyright (c) 2012-2015 Daniel Thau <danthau@bedrocklinux.org>
 *
 * This is a shared library for various Bedrock Linux C programs.
 */

#include <stdio.h>          /* printf()           */
#include <stdlib.h>         /* exit()             */
#include <sys/stat.h>       /* stat()             */
#include <errno.h>          /* errno              */

/*
 * Check if config file is only writable by root.
 * If the item provided is a symlink, checks symlink and where it ultimately
 * resolves but does NOT check intermediate symlinks. TODO: check intermediate
 * symlinks.
 */
int check_config_secure(char *config_path)
{
	/* will hold config file stats - owner, UNIX permissions, etc */
	struct stat config_stat;

	/* get stats on file.  If we can't, file doesn't exist */
	if (lstat(config_path, &config_stat) != 0) {
		errno = ENOENT;
		return 0;
	}

	/* ensure file is owned by root */
	if (config_stat.st_uid != 0) {
		errno = EACCES;
		return 0;
	}

	/* ensure config file is not writable by anyone other than root */
	if (!S_ISLNK(config_stat.st_mode) && config_stat.st_mode & (S_IWGRP | S_IWOTH)) {
		errno = EACCES;
		return 0;
	}

	/* if it is not a symlink, we're good */
	if (!S_ISLNK(config_stat.st_mode)) {
		return 1;
	}

	/*
	 * If it is a symlink, also check where it (ultimately) resolves.
	 */

	/* get stats on file.  If we can't, file doesn't exist */
	if (stat(config_path, &config_stat) != 0) {
		errno = ENOENT;
		return 0;
	}

	/* ensure file is owned by root */
	if (config_stat.st_uid != 0) {
		errno = EACCES;
		return 0;
	}

	/* ensure config file is not writable by anyone other than root */
	if (config_stat.st_mode & (S_IWGRP | S_IWOTH)) {
		errno = EACCES;
		return 0;
	}

	/* config looks good */
	return 1;
}
