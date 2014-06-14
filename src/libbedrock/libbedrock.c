/*
 * libbedrock.c
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * version 2 as published by the Free Software Foundation.
 *
 * Copyright (c) 2012-2014 Daniel Thau <danthau@bedrocklinux.org>
 *
 * This is a shared library for various Bedrock Linux C programs.
 */

#include <stdio.h>          /* printf()           */
#include <stdlib.h>         /* exit()             */
#include <sys/stat.h>       /* stat()             */

/* ensure config file is only writable by root */
void ensure_config_secure(char *config_path)
{
	/* will hold config file stats - owner, UNIX permissions, etc */
	struct stat config_stat;

	/* get stats on file.  If we can't, file doesn't exist */
	if (stat(config_path, &config_stat) != 0) {
		fprintf(stderr, "The file \"%s\" does not exist, aborting.\n",
				config_path);
		exit(1);
	}

	/* ensure file is owned by root */
	if (config_stat.st_uid != 0) {
		fprintf(stderr, "\"%s\" is not owned by root.\n"
				"This is a potential security issue; refusing to run.\n",
				config_path);
		exit(1);
	}

	/* ensure config file is not writable by anyone other than root */
	if (config_stat.st_mode & (S_IWGRP | S_IWOTH)) {
		fprintf(stderr, "\"%s\" is writable by someone other than root.\n"
				"This is a potential security issue; refusing to run.\n",
				config_path);
		exit(1);
	}

	/* config looks good */
	return;
}
