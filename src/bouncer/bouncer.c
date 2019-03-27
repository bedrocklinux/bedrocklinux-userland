/*
 * bouncer.c
 *
 *      This program is free software; you can redistribute it and/or
 *      modify it under the terms of the GNU General Public License
 *      version 2 as published by the Free Software Foundation.
 *
 * Copyright (c) 2017-2018 Daniel Thau <danthau@bedrocklinux.org>
 *
 * This program redirects to the specified executable in the specified stratum
 * via strat.  The appropriate stratum and executable are determined by the
 * 'user.bedrock_stratum' and 'user.bedrock_localpath' xattrs on
 * /proc/self/exe.
 *
 * This is preferable to a script such as
 *
 *     #!/bin/sh
 *     exec strat <stratum> <local-path> $@
 *
 * as it can pass its own argv[0] where as a hashbang loses this information.
 */

#include <errno.h>
#include <limits.h>
#include <linux/limits.h>
#include <stdio.h>
#include <sys/xattr.h>
#include <unistd.h>

int main(int argc, char *argv[])
{
	/*
	 * Which stratum do we want to be in?
	 */
	char target_stratum[PATH_MAX];
	ssize_t len = getxattr("/proc/self/exe", "user.bedrock.stratum",
		target_stratum, sizeof(target_stratum) - 1);
	if (len < 0) {
		fprintf(stderr,
			"bouncer: unable to determine target stratum\n");
		return errno;
	}
	target_stratum[len] = '\0';

	/*
	 * Which executable do we want to run?
	 */
	char target_path[PATH_MAX];
	len = getxattr("/proc/self/exe", "user.bedrock.localpath", target_path,
		sizeof(target_path) - 1);
	if (len < 0) {
		fprintf(stderr, "bouncer: unable to determine target path\n");
		return errno;
	}
	target_path[len] = '\0';

	/*
	 * Do we want to restrict the process to its own stratum?
	 */
	int restrict_flag = 0;
	char target_restrict[PATH_MAX];
	len = getxattr("/proc/self/exe", "user.bedrock.restrict",
		target_restrict, sizeof(target_restrict) - 1);
	if (len >= 0) {
		restrict_flag = 1;
	}

	char *strat = "/bedrock/bin/strat";
	/*
	 * Example:
	 *
	 * incoming: apt install foo bar baz -- (argc does not count NULL)
	 *            \   \      \   \   \___________________________________________________
	 *             \   \      \   \___________________________________________________   \
	 *              \   \      \___________________________________________________   \   \
	 *               \   \__________________________________________________       \   \   \
	 *                \___________________                                  \       \   \   \
	 *                                    \                                  \       \   \   \
	 * outgoing: /bedrock/bin/strat --arg0 apt --restrict debian /usr/bin/apt install foo bar baz NULL
	 *           /bedrock/bin/strat --arg0 apt --restrict debian /usr/bin/apt install foo bar baz NULL
	 *            \                  \          \          \      \                                \
	 *             \- 1               \- 2       \- 3       \- 4   \- 5                             \- 6
	 *
	 * Potentially need 6 more than argc.
	 */
	char *new_argv[argc + 6];

	new_argv[0] = strat;
	new_argv[1] = "--arg0";
	new_argv[2] = argv[0];
	if (restrict_flag) {
		new_argv[3] = "--restrict";
	}
	new_argv[3 + restrict_flag] = target_stratum;
	new_argv[4 + restrict_flag] = target_path;
	/* start at 1 to skip argv[0] which was already consumed above */
	for (int i = 1; i < argc; i++) {
		new_argv[i + 4 + restrict_flag] = argv[i];
	}
	new_argv[argc + 4 + restrict_flag] = NULL;

	execv(strat, new_argv);

	fprintf(stderr, "bouncer: could not execute\n    %s\n", strat);
	switch (errno) {
	case EACCES:
		fprintf(stderr, "due to: permission denied (EACCES).\n");
		break;
	case ENOENT:
		fprintf(stderr, "due to: unable to find file (ENOENT).\n");
		break;
	default:
		perror("due to: execv:\n");
		break;
	}

	return 1;
}
