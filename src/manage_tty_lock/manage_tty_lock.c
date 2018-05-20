/*
 * manage_stty_lock.c
 *
 *      This program is free software; you can redistribute it and/or
 *      modify it under the terms of the GNU General Public License
 *      version 2 as published by the Free Software Foundation.
 *
 * Copyright (c) 2015 Daniel Thau <danthau@bedrocklinux.org>
 *
 * This program sets/unsets the locks on a given terminal.  See tty_ioctl(4).
 */

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <termios.h>
#include <unistd.h>

void print_help()
{
	printf(""
		"Usage: manage_stty_lock [lock|unlock] [tty]\n"
		"requires root (or CAP_SYS_ADMIN)\n"
		"\n"
		"To lock a terminal, use `lock` as the first argument.  To unlock one, use\n"
		"`unlock` as the first argument.  The second argument can be utilized to specify\n"
		"which terminal to lock/unlock; if it is left unset, the current terminal is\n"
		"utilized.\n"
		"\n"
		"Example, locking /dev/pts/1:\n"
		"\n"
		"	manage_stty_lock lock /dev/pts/1\n"
		"\n"
		"Example, unlocking the current terminal:\n"
		"\n	Example: manage_stty_lock unlock\n");
}

int lock_tty(int fd)
{
	/*
	 * Non-zero bits indicate a field to lock.  Since we're locking
	 * everything, set everything to non-zero.
	 */

	struct termios term;
	memset(&term, 0xff, sizeof(term));

	errno = 0;
	if (ioctl(fd, TIOCSLCKTRMIOS, &term) < 0) {
		perror("ioctl error");
	}

	return errno;
}

int unlock_tty(int fd)
{
	/*
	 * Non-zero bits indicate a field to lock.  Since we're unlocking
	 * everything, set everything to zero.
	 */

	struct termios term;
	memset(&term, 0, sizeof(term));

	errno = 0;
	if (ioctl(fd, TIOCSLCKTRMIOS, &term) < 0) {
		perror("ioctl error");
	}

	return errno;
}

int main(int argc, char *argv[])
{
	if (argc < 2) {
		fprintf(stderr, "Insufficient arguments\n");
		return EINVAL;
	}

	if (!strcmp(argv[1], "-h") || !strcmp(argv[1], "--help")) {
		print_help();
		return 0;
	}

	int fd = 0;
	if (argc >= 3) {
		fd = open(argv[2], O_RDONLY);
		if (fd < 0) {
			fprintf(stderr, "Unable to open specified tty \"%s\"\n",
				argv[2]);
			return EBADF;
		}
	}

	if (!strcmp(argv[1], "lock")) {
		return lock_tty(fd);
	} else if (!strcmp(argv[1], "unlock")) {
		return unlock_tty(fd);
	} else {
		printf("Unrecognized argument \"%s\"\n", argv[1]);
		return EINVAL;
	}
}
