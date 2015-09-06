/*
 * libbedrock.h
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * version 2 as published by the Free Software Foundation.
 *
 * Copyright (c) 2012-2015 Daniel Thau <danthau@bedrocklinux.org>
 *
 * This is a shared header file for various Bedrock Linux C programs.
 */

/*
 * This macro sets the filesystem uid and gid to that of the calling user for
 * FUSE filesystems.  This allows the kernel to take care of permissions for
 * us with regards to filesystem calls.
 */
#define SET_CALLER_UID()                                           \
	do {                                                       \
		struct fuse_context *context = fuse_get_context(); \
		seteuid(context->uid);                             \
		setegid(context->gid);                             \
	} while (0);


/* ensure config file is only writable by root */
int check_config_secure(char *config_path);
