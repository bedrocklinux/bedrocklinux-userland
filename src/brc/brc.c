/*
 * brc.c
 *
 *      This program is free software; you can redistribute it and/or
 *      modify it under the terms of the GNU General Public License
 *      version 2 as published by the Free Software Foundation.
 *
 * Copyright (c) 2012-2015 Daniel Thau <danthau@bedrocklinux.org>
 *
 * This program is a derivative work of capchroot 0.1, and thus:
 * Copyright (c) 2009 Thomas Bächler <thomas@archlinux.org>
 *
 * This program will allow non-root users to chroot programs into (explicitly
 * white-listed) directories relative to the absolute root directory, breaking
 * out of a chroot if needed.
 */

#include <sys/capability.h> /* linux capabilities */
#include <stdio.h>          /* printf()           */
#include <stdlib.h>         /* exit()             */
#include <sys/stat.h>       /* stat()             */
#include <unistd.h>         /* chroot()           */
#include <string.h>         /* strncmp(),strcat() */
#include <sys/param.h>      /* PATH_MAX           */
#include <unistd.h>         /* execvp()           */
#include <sys/types.h>      /* opendir()          */
#include <dirent.h>         /* opendir()          */
#include <errno.h>          /* errno              */

#include <libbedrock.h>

/*
 * This directory contains files corresponding to enabled strata
 */
#define STATEDIR "/bedrock/run/enabled_strata/"
#define STATEDIRLEN strlen(STATEDIR)
/*
 * Directory containing actual strata files.
 * This is what we will chroot() into
 */
#define STRATADIR "/bedrock/strata/"
#define STRATADIRLEN strlen(STRATADIR)
/*
 * This directory is used to access executables in non-local strata.  If
 * someone calls brc, they are specifying a specific strata, and are thus not
 * looking for something in this directory. Thus we want to skip any $PATH
 * entries that refer to this directory.
 */
#define BRPATHDIR "/bedrock/brpath/"


/*
 * Like execvp(), except skips any $PATH items starting with the "skip"
 * argument.  "skip" should end with a "/".
 */
void execvp_skip(char *file, char *argv[], char *skip)
{
	/*
	 * Ensure provided a NULL or empty string for file.
	 */
	if (!file || !*file) {
		errno = ENOENT;
		return;
	}

	/*
	 * If file has a "/" in it, it is a specific path to a file; do not
	 * search PATH.
	 */
	if (strchr(file, '/')) {
		execv(file, argv);
		/*
		 * If we got here, there was some error.  errno should be set
		 * accordingly.
		 */
		return;
	}

	/*
	 * File does not have a "/" in it.  Search the $PATH.
	 */

	/*
	 * get PATH variable
	 */
	char *path = getenv("PATH");

	/*
	 * If PATH is empty, set a default.
	 */
	if (!path) {
		path = "/usr/local/bin:/usr/bin:/bin";
	}

	/*
	 * Will be populated with filenames which could contain the target
	 * executable.
	 */
	char path_entry[strlen(path) + 1 + strlen(file)];

	int skip_len = strlen(skip);

	/*
	 * Iterate over PATH entries looking for executable.
	 */
	char* start;
	char* end;

	int loop = 1;
	for (start = path, end = strchr(start, ':');
			loop != 0;
			start = end+1, end = strchr(start, ':')) {
		/*
		 * Get PATH entry
		 */
		if (end) {
			strncpy(path_entry, start, end-start);
			path_entry[end-start] = '\0';
		} else {
			/*
			 * This is the last loop
			 */
			loop = 0;
			end = path;
			/*
			 * Copy rest of path
			 */
			strcpy(path_entry, start);
		}

		/*
		 * Check for empty path entry
		 */
		if (path_entry[0] == '\0') {
			continue;
		}

		/*
		 * Check if current entry is a skip entry
		 */
		if (strncmp(path_entry, skip, skip_len) == 0) {
			continue;
		}

		/*
		 * Concatenate file to the path.
		 */
		strcat(path_entry, "/");
		strcat(path_entry, file);

		/*
		 * Attempt to execute.  If this succeeds, execution hands off
		 * there and this program effectively ends. Otherwise - if this
		 * program continues - check next entry next loop.
		 */
		execv(path_entry, argv);
		if (!loop) {
			break;
		}
	}

	/*
	 * Could not find item in PATH
	 */
	errno = ENOENT;
	return;
}

/* check if this process has the required capabilities */
int check_capsyschroot(char* executable_name)
{
	/* will store (all) current capabilities */
	cap_t current_capabilities;
	/* will store cap_sys_chroot capabilities */
	cap_flag_value_t chroot_permitted, chroot_effective;

	/* get (all) capabilities for this process */
	current_capabilities = cap_get_proc();
	if (current_capabilities == NULL)
		perror("cap_get_proc");

	/* from current_capabilities, get effective and permitted flags for cap_sys_chroot */
	cap_get_flag(current_capabilities, CAP_SYS_CHROOT, CAP_PERMITTED, &chroot_permitted);
	cap_get_flag(current_capabilities, CAP_SYS_CHROOT, CAP_EFFECTIVE, &chroot_effective);

	/* if either chroot_permitted or chroot_effective is unset, return false */
	int ret;
	if (chroot_permitted != CAP_SET || chroot_effective != CAP_SET) {
		ret = 0;
	} else {
		ret = 1;
	}

	/* free memory used by current_capabilities as it is no longer needed */
	cap_free(current_capabilities);

	/* required capabilities are in place */
	return ret;
}

/*
 * Break out of chroot().
 *
 * This requires some accessible directory to be specified via reference_dir.
 */
void break_out_of_chroot(char* reference_dir)
{
	/* go as high in the tree as possible */
	chdir("/");

	if (chroot(reference_dir) == -1) {
		fprintf(stderr, "brc: unable to use '%s' as a reference, aborting\n", reference_dir);
		exit(1);
	}
	/*
	 * We're in the dirt.  Change directory up the tree until we hit the
	 * actual, absolute root directory.  We'll know we're there when the
	 * current and parent directories both have the same device number and
	 * inode.
	 *
	 * Note that it is technically possible for a directory and its parent
	 * directory to have the same device number and inode without being the
	 * real root. For example, this could occur if one bind mounts a directory
	 * into itself, or using a filesystem (e.g. fuse) which does not use unique
	 * inode numbers for every directory.  However, provided the directory
	 * we are chroot()ed into on on the real root (e.g.
	 * /bedrock/strata/<stratum>) does not have any of these situations,
	 * the chdir("/") above will bypass any remaining possibility.
	 */
	struct stat stat_pwd;
	struct stat stat_parent;
	do {
		chdir("..");
		lstat(".", &stat_pwd);
		lstat("..", &stat_parent);
	} while(stat_pwd.st_ino != stat_parent.st_ino || stat_pwd.st_dev != stat_parent.st_dev);

	/* We're at the absolute root directory, so set the root to where we are. */
	chroot(".");
}

int main(int argc, char* argv[])
{
	/*
	 * Sanity check
	 * - ensure there are sufficient arguments
	 */
	if (argc < 2) {
		fprintf(stderr, "brc: no stratum specified, aborting\n");
		exit(1);
	}

	/*
	 * Gather information we'll need later
	 * - path to the stratum
	 * - path to enabled/disabled state directory
	 * - current working directory (relative to the current chroot, if we're in
	 *   one)
	 */

	/*
	 * /bedrock/strata/jessie\0
	 * |              ||    |\+ 1 for terminating NULL
	 * |              |\----+ strlen(argv[1])
	 * \--------------+ STRATADIRLEN
	 */
	char stratum_path[STRATADIRLEN + strlen(argv[1]) + 1];
	strcpy(stratum_path, STRATADIR);
	strcat(stratum_path, argv[1]);

	/*
	 * /bedrock/run/enabled_strata/jessie\0
	 * |                          ||    |\+ 1 for terminating NULL
	 * |                          ||    |
	 * |                          |\----+ argv[1]
	 * \--------------------------+ STATEDIRLEN
	 */
	char state_file_path[STATEDIRLEN + strlen(argv[1]) + 1];
	strcpy(state_file_path, STATEDIR);
	strcat(state_file_path, argv[1]);

	char cwd_path[PATH_MAX + 1];
	if (getcwd(cwd_path, PATH_MAX + 1) == NULL) {
		/* failed to get cwd, falling back to root */
		cwd_path[0] = '/';
		cwd_path[1] = '\0';
		fprintf(stderr,"brc: could not determine current working directory,\n"
				"falling back to root directory\n");
	}

	/*
	 * Sanity checks
	 * - ensure state file exists and is secure if not using init or local
	 *   alias
	 * - ensure this process has the required capabilities
	 */

	if (strcmp(argv[1], "init") != 0 && strcmp(argv[1], "local") != 0) {
		if (check_config_secure(state_file_path)) {
			/* config is found and secure, we're good to go */
		} else if (errno == EACCES) {
			fprintf(stderr, "brc: the state file for stratum\n"
					"    %s\n"
					"at\n"
					"    %s\n"
					"is insecure, refusing to continue.\n",
					argv[1], state_file_path);
			exit(1);
		} else if (errno == ENOENT) {
			fprintf(stderr, "brc: could not find state file for stratum\n"
					"    %s\n"
					"at\n"
					"    %s\n"
					"Perhaps the stratum is disabled or you typod the name?\n",
					argv[1], state_file_path);
			exit(1);
		} else {
			fprintf(stderr, "brc: error sanity checking request for stratum\n"
					"    %s\n"
					"via state file at\n"
					"    %s\n",
					argv[1], state_file_path);
			exit(1);
		}
	}

	if (!check_capsyschroot(argv[0])) {
		fprintf(stderr, "brc is missing the cap_sys_chroot capability. To remedy this,\n"
				"Run '/bedrock/libexec/setcap cap_sys_chroot=ep /path/to/%s' as root.\n", argv[0]);
		exit(1);
	}

	/*
	 * The next goal is to try to change directory to the target stratum's root
	 * so we can chroot(".") the appropriate root.
	 *
	 * All of the strata will be in stratum_path relative to the real root
	 * except two:
	 *
	 * - "local", the current stratum.  It is effectively a no-op with
	 *   regards to changing local context.
	 * - "init", the stratum that provides pid1.  This will be in the actual
	 *   real root.
	 *
	 * When the init stratum is chosen, it is bind-mounted to its
	 * stratum_path.  Thus, from the real root we can detect if the target
	 * stratum is the real root stratum by comparing device number and inode
	 * number of the real root to the stratum_path.  The down side to this
	 * technique, however, is that if somehow that bind-mount is removed,
	 * one cannot brc to the real root.  Without access to the real root,
	 * problematic situations such as that bind-mount being removed will be
	 * difficult to resolve.  In case this situation occurs, "init" is hard
	 * coded as an alias to whatever stratum provides pid1.  Note that the
	 * "init" stratum cannot be disabled.
	 */

	if (strcmp(argv[1], "local") != 0) {
		/*
		 * If we're in a chroot, break out.
		 *
		 * brc is normally installed in /bedrock, so if this is
		 * running, /bedrock should exist.  TODO: a better solution
		 * would be to chdir("/") then readdir() and just pick
		 * something we know exists.
		 */
		break_out_of_chroot("/bedrock");

		struct stat stat_real_root;
		struct stat stat_stratum_path;
		stat(".", &stat_real_root);
		stat(stratum_path, &stat_stratum_path);

		/* not using init alias... */
		if (strcmp(argv[1], "init") != 0 &&
				/* ...and specified path is not bind mount to real
				 * root, so it's not init, and so we need to chdir() and
				 * chroot() to the new root */
				(stat_real_root.st_dev != stat_stratum_path.st_dev ||
				 stat_real_root.st_ino != stat_stratum_path.st_ino)) {
			if (chdir(stratum_path) != 0) {
				fprintf(stderr, "brc: could not find stratum's files, aborting\n");
				exit(1);
			}
			/* We're at the desired stratum's root. */
			chroot(".");
		}
	}

	/*
	 * Get the command to run in the stratum.  If a command was provided, use
	 * that.  If not, but $SHELL exists in the stratum, use that.  Failing
	 * either of those, fall back to /bin/sh.
	 */
	char** cmd;
	if (argc > 2) {
		/*
		 * The desired command was given as an argument to this program; use
		 * that.
		 *
		 * brc jessie ls -l
		 * |   |      \ argv + 2
		 * |   \argv+1
		 * \ argv
		 */
		cmd = argv + 2;
	} else {
		/*
		 * Use $SHELL if it exists in the current chroot.  Otherwise, use /bin/sh.
		 */
		cmd = (char* []){'\0','\0'};
		/*               |  | \--+ lack of second argument
		 *               \--+ will point to shell in next if statement */
		char* shell;
		struct stat shell_stat;
		if ((shell = getenv("SHELL")) != NULL && stat(shell, &shell_stat) == 0)
			cmd[0] = shell;
		else
			cmd[0] = "/bin/sh";
	}

	/*
	 * Set the current working directory in this new stratum to the same as it
	 * was originally, if possible; fall back to the root otherwise.
	 */
	if(chdir(cwd_path) != 0) {
		int err = errno;
		chdir("/");
		fprintf(stderr, "brc: warning: unable to set pwd to\n"
				"    %s\n"
				"for stratum\n"
				"    %s\n"
				"and command\n"
				"    %s\n",
				cwd_path, argv[1], cmd[0]);
		switch (err) {
		case EACCES:
			fprintf(stderr, "due to: permission denied (EACCES).\n");
			break;
		case ENOENT:
			fprintf(stderr, "due to: no such directory (ENOENT).\n");
			break;
		default:
			perror("due to: chdir:\n");
			break;
		}
		fprintf(stderr, "falling back to root directory\n");
	}

	/*
	 * Everything is set, run the command, skipping the brpath directory in
	 * the $PATH search.
	 */
	execvp_skip(cmd[0], cmd, BRPATHDIR);

	/*
	 * execvp() would have taken over if it worked.  If we're here, there
	 * was an error.
	 */
	fprintf(stderr, "brc: could not run\n"
			"    %s\n"
			"in stratum\n"
			"    %s\n",
			cmd[0], argv[1]);
	switch (errno) {
	case EACCES:
		fprintf(stderr, "due to: permission denied (EACCES).\n");
		break;
	case ENOENT:
		fprintf(stderr, "due to: unable to find file (ENOENT)\n");
		break;
	default:
		perror("due to: execvp:\n");
		break;
	}
	exit(1);
}
