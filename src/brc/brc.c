/*
 * brc.c
 *
 *      This program is free software; you can redistribute it and/or
 *      modify it under the terms of the GNU General Public License
 *      version 2 as published by the Free Software Foundation.
 *
 * Copyright (c) 2012-2014 Daniel Thau <danthau@bedrocklinux.org>
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

#define CONFIGDIR "/bedrock/etc/clients.d/"
#define CLIENTDIR "/bedrock/clients/"
#define CONFIGDIRLEN strlen(CONFIGDIR)
#define CLIENTDIRLEN strlen(CONFIGDIR)

/* ensure this process has the required capabilities */
void ensure_capsyschroot(char* executable_name)
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

	/* if either chroot_permitted or chroot_effective is unset, abort */
	if (chroot_permitted != CAP_SET || chroot_effective != CAP_SET) {
		fprintf(stderr, "This file is missing the cap_sys_chroot capability. To remedy this,\n"
				"Run 'setcap cap_sys_chroot=ep %s' as root. \n",executable_name);
		exit(1);
	}

	/* free memory used by current_capabilities as it is no longer needed */
	cap_free(current_capabilities);

	/* required capabilities are in place */
	return;
}

/* break out of chroot */
void break_out_of_chroot()
{
	/* go as high in the tree as possible */
	chdir("/");
	 /*
	  * If CONFIGDIR did not exists, the config for the requested client would
	  * not exist and the process would have aborted already.  Thus, CONFIGDIR
	  * exists.
	  *
	  * Changing root to CONFIGDIR while we're in / means we're below the root
	  * and thus outside of the chroot.
	  *
	  * What's below the roots (of the clients) but above the bedrock?  Dirt.
	  */
	if(chroot(CONFIGDIR) == -1){
		perror("chroot");
		exit(1);
	}
	/*
	 * We're in the dirt.  cd up the tree until we hit the actual, absolute
	 * root directory.  We'll know we're there when the current and parent
	 * directories both have the same inode.
	 */
	struct stat stat_pwd;
	struct stat stat_parent;
	do {
		chdir("..");
		stat(".", &stat_pwd);
		stat("..", &stat_parent);
	} while(stat_pwd.st_ino != stat_parent.st_ino);

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
		fprintf(stderr, "No client specified, aborting\n");
		exit(1);
	}

	/*
	 * Gather information we'll need later
	 * - path to the client
	 * - path to the config
	 * - current working directory (relative to the current chroot, if we're in
	 *   one)
	 */

	/*
	 * "bedrock" client goes directly to the (real) root; everyone else goes in CLIENTDIR.
	 *
	 * /bedrock/clients/squeeze\0
	 * |               ||     |\+ 1 for terminating NULL
	 * |               |\-----+ strlen(argv[1])
	 * \---------------+ CLIENTDIRLEN
	 *
	 * /\0
	 * \-+ always shorter than above since "bedrock" is more than two characters.
	 */
	char client_path[CLIENTDIRLEN + strlen(argv[1]) + 1];
	if (strcmp(argv[1],"bedrock") == 0) {
		strcpy(client_path, "/");
	} else {
		strcpy(client_path, CLIENTDIR);
		strcat(client_path, argv[1]);
	}

	/*
	 * /bedrock/etc/clients.d/squeeze.conf\0
	 * |                     ||    | |   |\+ 1 for terminating NULL
	 * |                     ||    | \---+ 5 for ".conf"
	 * |                     |\----+ argv[1]
	 * \---------------------+ CONFIGDIRLEN
	 */
	char config_path[CONFIGDIRLEN + strlen(argv[1]) + 5 + 1];
	strcpy(config_path, CONFIGDIR);
	strcat(config_path, argv[1]);
	strcat(config_path, ".conf");

	char cwd_path[PATH_MAX + 1];
	if (getcwd(cwd_path, PATH_MAX + 1) == NULL) {
		/* failed to get cwd, falling back to root */
		cwd_path[0] = '/';
		cwd_path[1] = '\0';
		fprintf(stderr,"WARNING: could not determine current working directory, "
				"falling back to /");
	}

	/*
	 * Sanity checks
	 * - ensure this process has the required capabilities
	 * - ensure config exists and is secure
	 */
	ensure_capsyschroot(argv[0]);
	ensure_config_secure(config_path);

	/*
	 * If we're in a chroot, break out
	 */
	break_out_of_chroot();

	/*
	 * Try to cd to the client's root (relative to the now absolute root we're
	 * at).  If this fails, it could be because the client doesn't actually exist.
	 */
	if (chdir(client_path) != 0) {
		fprintf(stderr, "Could not find client, aborting.");
		exit(1);
	}

	/*
	 * We're at the desired client's root.  Set this as the root.
	 */
	chroot(".");

	/*
	 * Set the current working directory in this new client to the same as it
	 * was originally, if possible; fall back to the root otherwise.
	 */
	if(chdir(cwd_path) != 0) {
		chdir("/");
		fprintf(stderr,"WARNING: \"%s\" not present in target client, "
				"falling back to root directory\n", cwd_path);
	}

	/*
	 * Get the command to run in the client.  If a command was provided, use
	 * that.  If not, but $SHELL exists in the client, use that.  Failing
	 * either of those, fall back to /bin/sh.
	 */
	char** cmd;
	if (argc > 2) {
		/*
		 * The desired command was given as an argument to this program; use
		 * that.
		 * brc squeeze ls -l
		 * ^ argv      |
		 *             ^ argv + 2
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
	 * Everything is set, run the command.
	 */
	execvp(cmd[0], cmd);

	/*
	 * execvp() would have taken over if it worked.  If we're here, there was an error.
	 */
	perror("execvp");
	return -1;
}
