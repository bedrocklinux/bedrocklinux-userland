/*
 * brc.c
 *
 *      This program is free software; you can redistribute it and/or
 *      modify it under the terms of the GNU General Public License
 *      version 2 as published by the Free Software Foundation.
 *
 * Copyright (c) 2012 Daniel Thau <paradigm@bedrocklinux.org>
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
#include <libgen.h>         /* basename()         */
#include <string.h>         /* strncmp(),strcat() */
#include <sys/param.h>      /* PATH_MAX           */
#include <unistd.h>         /* execvp()           */

/* configuration file mapping clients to their path */
#define BRCLIENTSCONF "/bedrock/etc/brclients.conf"

/* ensure this process has the required capabilities */
void ensure_capsyschroot(char* executable_name){
	/* will store (all) current capabilities */
	cap_t current_capabilities;
	/* will store cap_sys_chroot capabilities */
	cap_flag_value_t chroot_permitted, chroot_effective;
	/* get (all) capabilities for this process */
	current_capabilities = cap_get_proc();
	if(current_capabilities == NULL)
		perror("cap_get_proc");
	/* from current_capabilities, get effective and permitted flags for cap_sys_chroot */
	cap_get_flag(current_capabilities, CAP_SYS_CHROOT, CAP_PERMITTED, &chroot_permitted);
	cap_get_flag(current_capabilities, CAP_SYS_CHROOT, CAP_EFFECTIVE, &chroot_effective);
	/* if either chroot_permitted or chroot_effective is unset, abort */
	if(chroot_permitted != CAP_SET || chroot_effective != CAP_SET){
		fprintf(stderr, "This file is missing the cap_sys_chroot capability. To remedy this,\n"
				"Run 'setcap cap_sys_chroot=ep %s' as root. \n",executable_name);
		exit(1);
	}
	/* free memory used by current_capabilities as it is no longer needed */
	cap_free(current_capabilities);
}

/* ensure config file is only writable by root */
void ensure_config_secure(){
	/* gather information on configuration files */
	struct stat brclientsconf_stat;
	if(stat(BRCLIENTSCONF,&brclientsconf_stat) != 0){
		perror("stat: " BRCLIENTSCONF);
		exit(1);
	}
	/* ensure config file is owned by root*/
	if(brclientsconf_stat.st_uid != 0){
		fprintf(stderr, BRCLIENTSCONF" is not owned by root.\n"
				"This is a potential security issue; refusing to run.\n");
		exit(1);
	}
	/* ensure config file has limited permissions */
	if(brclientsconf_stat.st_mode & (S_IWGRP | S_IWOTH)) {
		fprintf(stderr, BRCLIENTSCONF" is writable by someone other than root.\n"
				"This is a potential security issue; refusing to run.\n");
		exit(1);
	}
}

/* ensure config file is readable */
void ensure_config_readable(){
	if(access(BRCLIENTSCONF, R_OK) != 0){
		fprintf(stderr, "Cannot read "BRCLIENTSCONF"\n");
		exit(1);
	}
}

/* ensure there are enough arguments */
void ensure_enough_arguments(int argc, char* argv[]){
	if(argc < 2){
		fprintf(stderr, "no client specified, aborting\n");
		exit(1);
	}
}

/* get command to run in chroot */
char** get_chroot_command(int argc, char* argv[], char* shell[]){
	/*
	 * The second argument should be the name of the client to chroot into and
	 * all of the remaining terms will be the command to run in the client.
	 * thus, stripping the first two arguments gives us the command to run in
	 * the chroot.
	 */
	if(argc > 2){
		return argv+2;
	}else{
		/*
		 * however, if no third term is given, we have nothing to run.
		 * instead, run the $SHELL, if we can find $SHELL.  otherwise, fall
		 * back to /bin/sh.
		 */
		shell[0] = getenv("SHELL");
		if(shell[0] == NULL)
			shell[0] = "/bin/sh";
		return shell;
	}
}

/* determine path to chroot */
void get_chroot_path(char* argv[], char* chroot_path){
	/*
	 * will store path to chroot. needs to start with "." so the path is
	 * relative to the real absolute path, since non-relative paths don't work
	 * very well once we've broken out of a chroot.
	 */
	strcpy(chroot_path,".");
	/*
	 * will hold the currently-being-parsed line
	 * line length: len("path = ") + max path length
	 */
	char line[PATH_MAX+7];
	/* will store the key name to check if it is "path" */
	char key[5];
	/* will store the value for the key*/
	char value[PATH_MAX];
	/*
	 * will store the section heading we are looking for.
	 * it will look like '[client "argv[1]"]' (ie, .ini-style
	 * "client" heading).  The first line starting with "path =" (with
	 * flexible whitespace) under it will be contain the path we want.
	 * length was arbitrarily chosen
	 */
	char target_section[PATH_MAX];
	snprintf(target_section, PATH_MAX, "[client \"%s\"]", argv[1]);
	/* will store whether we're currently in the target section */
	int in_section = 0;


	FILE* fp;
	fp = fopen(BRCLIENTSCONF,"r");
	if(fp == NULL){
		perror("fopen "BRCLIENTSCONF);
		exit(1);
	}
	while(fgets(line, PATH_MAX+7, fp) != NULL){
		/* in target section*/
		if(strncmp(line, target_section, strlen(target_section)) == 0)
			in_section = 1;
		/* in some other section */
		else if(strncmp(line, "[", 1) == 0)
			in_section = 0;
		/*
		 * if we're in the proper section and we've found a path setting,
		 * store the desired value and return
		 */
		if(in_section == 1){
			/*
			 * look for a line where key is "path" - the value there, once
			 * appended to ".", is the chroot_path we want
			 */
			sscanf(line," %[^= ] = %s",key,value);
			if(strncmp(key,"path",5) == 0 && strncmp(value,"",1) != 0){
				snprintf(chroot_path, PATH_MAX, "%s%s", chroot_path, value);
				fclose(fp);
				return;
			}
		}
	}
	fprintf(stderr, "Unable to find path for client \"%s\" in "BRCLIENTSCONF"\n", argv[1]);
	fclose(fp);
	exit(1);
}

/* break out of chroot */
void break_out_of_chroot(){
	/* go as high in the tree as possible */
	chdir("/");
	 /*
	  * A check to ensure BRCLIENTSCONF exists (and is readable) has already
	  * happened at this point.  Since it is within /bedrock, this means
	  * /bedrock must exist.
	  *
	  * changing root dir to /bedrock while we're in / means we're out of the root
	  * dir - ie, out of the chroot if we were previously in one.
	  */
	if(chroot("/bedrock") == -1){
		perror("chroot");
		exit(1);
	}
	/*
	 * cd up until we hit the actual, absolute root directory.  we'll know
	 * where there when the current and parent directorys both have the same
	 * inode.
	 */
	struct stat stat_pwd;
	struct stat stat_parent;
	do {
		chdir("..");
		stat(".", &stat_pwd);
		stat("..", &stat_parent);
	} while(stat_pwd.st_ino != stat_parent.st_ino);
}

int main(int argc, char* argv[]){
	/*
	 * ensure the following items are proper:
	 * - this process has cap_sys_chroot=ep
	 * - the config files are secure
	 * - the config files are readable
	 * - enough arguments were provided
	 */

	/* ensure this process has the required capabilities */
	ensure_capsyschroot(argv[0]);
	/* ensure config files are only writable by root */
	ensure_config_secure();
	/* ensure config files are only writable by root */
	ensure_config_readable();
	/* ensure there are enough arguments */
	ensure_enough_arguments(argc, argv);

	/*
	 * gather the following pieces of information:
	 * - the command (and its arguments) to run in the chroot
	 * - the path to the chroot
	 * - the directory to be cwd in the chroot
	 */

	/* get command to run in chroot */
	char* shell[PATH_MAX];
	char** chroot_command = get_chroot_command(argc, argv, shell);
	/* get path to chroot */
	char chroot_path[PATH_MAX];
	get_chroot_path(argv,chroot_path);
	/* get cwd - will attempt to make this cwd in chroot */
	char* chroot_cwd = getcwd(NULL, PATH_MAX);

	/*
	 * run the command in the proper context:
	 * - if we're in a chroot, break out
	 * - chroot the new directory, ensuring cwd is within it.
	 * - change cwd to desired directory if it exists; remain in / otherwise.
	 * - run command
	 * - if needed, abort cleanly
	 */

	/* break out of chroot */
	break_out_of_chroot();
	/* chroot to new directory */
	chdir(chroot_path);
	chroot(".");
	/* change cwd in the chroot to what it was previously, if possible */
	if(chdir(chroot_cwd) != 0)
		fprintf(stderr,"WARNING: \"%s\" not present in target client, falling back to root directory\n", chroot_cwd);
	
	/* We need to free previously allocated memory */
	free(chroot_cwd);
	/* run command */
	execvp(chroot_command[0], chroot_command);
	/* if there is an error, abort cleanly */
	perror("execvp");
	return 2;
}
