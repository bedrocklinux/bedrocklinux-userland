/*
 * keyboard_is_present.c
 *
 *      This program is free software; you can redistribute it and/or
 *      modify it under the terms of the GNU General Public License
 *      version 2 as published by the Free Software Foundation.
 *
 * Copyright (c) 2019 Daniel Thau <danthau@bedrocklinux.org>
 *
 * Based on the keyboard detection system described here:
 * https://www.mattfischer.com/blog/archives/182
 *
 * Returns zero if a keyboard is detected and non-zero otherwise.
 */

#include <dirent.h>
#include <unistd.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/limits.h>
#include <stdio.h>

/*
 * Input device directory
 */
#define INPUT_DIR "/sys/class/input"
/*
 * Escape key, the number row, and Q through D
 */
#define KEYBOARD_MASK 0xFFFFFFFE

int main(int argc, char *argv[])
{
	(void)argc;
	(void)argv;

	DIR *dir;
	if ((dir = opendir(INPUT_DIR)) == NULL) {
		fprintf(stderr, "Unable to open \"%s\"\n", INPUT_DIR);
		return 2;
	}

	struct dirent *entry;
	char path[PATH_MAX];
	char buf[PATH_MAX];
	while ((entry = readdir(dir)) != NULL) {
		/*
		 * Skip `.` and `..`.  Also dotfiles if they some how end up
		 * here.
		 */
		if (entry->d_name[0] == '.') {
			continue;
		}

		/*
		 * Check if device has keyboard event code support
		 */
		int s = snprintf(path, sizeof(path),
			INPUT_DIR "/%s/capabilities/ev", entry->d_name);
		if (s < 0 || s >= (int)sizeof(path)) {
			fprintf(stderr, "Unable to build ev path string\n");
			return 2;
		}
		int fd;
		if ((fd = open(path, O_RDONLY)) < 0) {
			continue;
		}
		if (read(fd, buf, sizeof(buf) - 1) < 0) {
			fprintf(stderr, "Unable to read \"%s\"\n", path);
			return 2;
		}
		close(fd);
		unsigned int bits;
		if (sscanf(buf, "%x", &bits) != 1) {
			continue;
		}
		if ((bits & EV_KEY) != EV_KEY) {
			continue;
		}

		/*
		 * Check if device supports expected keyboard keys such as escape, the number row, and Q through D
		 */
		s = snprintf(path, sizeof(path),
			INPUT_DIR "/%s/capabilities/key", entry->d_name);
		if (s < 0 || s >= (int)sizeof(path)) {
			fprintf(stderr, "Unable to build key path string\n");
			return 2;
		}
		if ((fd = open(path, O_RDONLY)) < 0) {
			continue;
		}
		if (read(fd, buf, sizeof(buf) - 1) < 0) {
			fprintf(stderr, "Unable to read \"%s\"\n", path);
			return 2;
		}
		close(fd);
		if (sscanf(buf, "%*x %*x %*x %x", &bits) != 1) {
			continue;
		}
		if ((bits & KEYBOARD_MASK) != KEYBOARD_MASK) {
			continue;
		}

		/*
		 * Found keyboard
		 */
		return 0;
	}

	return 1;
}
