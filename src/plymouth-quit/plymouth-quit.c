/*
 * plymouth-quit.c
 *
 *      This program is free software; you can redistribute it and/or
 *      modify it under the terms of the GNU General Public License
 *      version 2 as published by the Free Software Foundation.
 *
 * Copyright (c) 2020 Daniel Thau <danthau@bedrocklinux.org>
 *
 * Tells plymouth to quit.
 */

#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define PLYMOUTH_ABSTRACT_SOCKET_PATH "/org/freedesktop/plymouthd"
#define PLYMOUTH_QUIT_CHAR 'Q'

int main(int argc, char *argv[])
{
	(void)argc;
	(void)argv;

	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) {
		perror("socket");
		return -1;
	}

	struct sockaddr_un addr;
	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	addr.sun_path[0] = '\0';
	strncpy(addr.sun_path + 1, PLYMOUTH_ABSTRACT_SOCKET_PATH, strlen(PLYMOUTH_ABSTRACT_SOCKET_PATH) + 1);

	if (connect(fd, (struct sockaddr *)&addr, sizeof(addr) - 81) < 0) {
		switch (errno) {
		case ECONNREFUSED:
			/*
			 * Plymouth isn't running
			 */
			return 0;
		default:
			perror("connect");
			return -1;
		}
	}

	char buf[4];
	buf[0] = PLYMOUTH_QUIT_CHAR;
	buf[1] = '\2';
	buf[2] = '\1';
	buf[3] = '\0';
	write(fd, buf, sizeof(buf));
	return 0;
}
