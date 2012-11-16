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

/* client name     -> chroot path mappings */
#define BRCLIENTSCONF "/opt/bedrock/etc/brclients.conf"
/* executable name -> chroot path mappings */
#define BRPATHCONF    "/usr/local/brpath.conf"

/* ensure this process has the required capabilities */
void ensure_capsyschroot(char* executable_name){
	/* will store (all) current capabilities */
	cap_t current_capabilities;
	/* will store cap_sys_chroot capabilities */
	cap_flag_value_t chroot_permitted, chroot_effective;
	/* get (all) capabilities for this process */
	current_capabilities = cap_get_proc();
	if(current_capabilities == NULL)
		perror("get_get_proc");
	/* from current_capabilities, get effective and permitted flags for cap_sys_chroot */
	cap_get_flag(current_capabilities, CAP_SYS_CHROOT, CAP_PERMITTED, &chroot_permitted);
	cap_get_flag(current_capabilities, CAP_SYS_CHROOT, CAP_EFFECTIVE, &chroot_effective);
	/* if either chroot_permitted or chroot_effective is unset, abort explaining error */
	if(chroot_permitted != CAP_SET || chroot_effective != CAP_SET){
		fprintf(stderr, "This file is missing the cap_sys_chroot capability. To remedy this,\n"
				"Run 'setcap cap_sys_chroot=ep %s' as root. \n",executable_name);
		exit(1);
	}
	/* free memory used current_capabilities as it is no longer needed */
	cap_free(current_capabilities);
}

/* ensure config files are only writable by root */
void ensure_config_secure(){
	/* gather information on configuration files */
	struct stat brclientsconf_stat;
	struct stat brpathconf_stat;
	if(stat(BRCLIENTSCONF,&brclientsconf_stat) != 0){
		perror("stat: " BRCLIENTSCONF);
		exit(1);
	}
	if(stat(BRPATHCONF,&brpathconf_stat) != 0){
		perror("stat: " BRPATHCONF);
		exit(1);
	}
	/* ensure config files are owned by root*/
	if(brclientsconf_stat.st_uid != 0){
		fprintf(stderr, BRCLIENTSCONF" is not owned by root.\n"
				"This is a potential security issue; refusing to run.\n");
		exit(1);
	}
	if(brpathconf_stat.st_uid != 0){
		fprintf(stderr, BRPATHCONF" is not owned by root.\n"
				"This is a potential security issue; refusing to run.\n");
		exit(1);
	}
	/* ensure config files have limited permissions */
	if(brclientsconf_stat.st_mode & (S_IWGRP | S_IWOTH)) {
		fprintf(stderr, BRCLIENTSCONF" is writable by someone other than root.\n"
				"This is a potential security issue; refusing to run.\n");
		exit(1);
	}
	if(brpathconf_stat.st_mode & (S_IWGRP | S_IWOTH)) {
		fprintf(stderr, BRPATHCONF" is writable by someone other than root.\n"
				"This is a potential security issue; refusing to run.\n");
		exit(1);
	}
}

/* ensure config files readable */
void ensure_config_readable(){
	if(euidaccess(BRCLIENTSCONF, R_OK) != 0){
		fprintf(stderr, "Cannot read "BRCLIENTSCONF);
		exit(1);
	}
	if(euidaccess(BRPATHCONF, R_OK) != 0){
		fprintf(stderr, "Cannot read "BRPATHCONF);
		exit(1);
	}
}

/* ensure there are enough arguments */
void ensure_enough_arguments(int argc, char* argv[]){
	if(strncmp(argv[0],"brc",4) == 0 && argc < 2){
		fprintf(stderr, "If calling this as \"brc\", it should be given at "
				"least one argument: the name of the client desired\n");
		exit(1);
	}
}

/* get command to run in chroot */
char** get_chroot_command(int argc, char* argv[], char* shell[]){
	/*
	 * if called as something other than "brc", whatever the called command is,
	 * with its arguments, should be exactly what we want to run in the chroot.
	 * */
	if(strncmp(argv[0],"brc",4) != 0) {
		return argv;
	}
	/*
	 * if called as "brc", the second argument will be the name of the client to
	 * chroot into, and all of the remaining terms will be the command to run
	 * in the client.  thus, stripping the first two arguments gives us the
	 * command to run in the client.
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
char* get_chroot_path(char* argv[], char* chroot_path){
	/* will store path to chroot */
	strcpy(chroot_path,".");
	/* pointer to config file about to parse */
	FILE* fp;
	/*
	 * will hold the currently-being-parsed line
	 * line length: max path length + len("path ")
	 */
	char line[PATH_MAX+5];
	/*
	 * if called as "brc", reference second term in BRCLIENTSCONF to find
	 * chroot path.  Otherwise, reference first term in BRPATHCONF to find
	 * chroot path.
	 */
	if(strncmp(argv[0],"brc",4) == 0){
		/*
		 * parse config looking for line in form of "[argv[1]]" (ie, .ini-style
		 * heading).  The first line starting with "path " under it will be
		 * contain the path we want.
		 *
		 * section_heading will hold "[argv[1]]" - ie, the string we are
		 * initially looking for in the config file.  the length - PATH_MAX -
		 * was chosen arbitrarily.
		 */
		char section_heading[PATH_MAX];
		section_heading[0] = '[';
		strcat(section_heading, argv[1]);
		strcat(section_heading,"]");
		/* will store whether we've found the section or not */
		int found_section = 0;
		/* parse file */
		fp = fopen(BRCLIENTSCONF,"r");
		while(fgets(line, PATH_MAX+5, fp) != NULL){
			if(strncmp(line, section_heading, strlen(section_heading)) == 0)
				found_section = 1;
			else if(strncmp(line, "[", 1) == 0) /* found another heading */
				found_section = 0;
			if(found_section == 1 && strncmp(line,"path ",5) == 0){
				/*
				 * found chroot path - store in chroot_path and return
				 *
				 * storing into something other than chroot_path so we can
				 * concatonate it to chroot_path's "." to get relative path.
				 * Reusing line since we won't need it after this.
				 */
				sscanf(line,"path %s",line);
				strcat(chroot_path,line);
				fclose(fp);
				return;
			}
		}
		fprintf(stderr, "Unable to find path for client \"%s\" in "BRCLIENTSCONF"\n", argv[1]);
		fclose(fp);
		exit(1);
	}else{
		/*
		 * parse config looking for line starting with argv[0].  the second
		 * term will be the path we want.
		 *
		 * will hold the command on the parsed line to compare against argv[0].
		 * The size was chosen arbitrarily - not necessarily related to path
		 * length */
		char command_name[PATH_MAX];
		fp = fopen(BRPATHCONF,"r");
		while(fgets(line, PATH_MAX+strlen(argv[0])+1, fp) != NULL){
			sscanf(line,"%s %s",command_name, line);
			if(strncmp(command_name,argv[0],strlen(command_name)) == 0){
				/* found command */
				strcat(chroot_path,line);
				fclose(fp);
				return;
			}
		}
		fprintf(stderr, "Unable to find path for command \"%s\" in "BRPATHCONF"\n", argv[0]);
		fclose(fp);
		exit(1);
	}
}

/* break out of chroot */
void break_out_of_chroot(){
	/* go as high in the tree as possible */
	chdir("/");
	 /*
	  * since brc is supposed to be in /opt, /opt *should* exist
	  *
	  * changing root dir to /opt while we're in / means we're out of the root
	  * dir - ie, out of the chroot if we were previously in one.
	  */
	chroot("/opt");
	/*
	 * cd up until we hit the actual, absolute root directory
	 */
	struct stat stat_pwd;
	struct stat stat_parent;
	while(stat_pwd.st_ino != stat_parent.st_ino){
		chdir("..");
		stat(".", &stat_pwd);
		stat("..", &stat_parent);
	}
}


int main(int argc, char* argv[]){
	/* basename(argv[0]) is required several times, while argv[0] without basename
	 * is not needed.  Simply replace argv[0] with basename(argv[0]) here to
	 * simplify later code. */
	argv[0] = basename(argv[0]);

	/*
	 * ensure the following items are proper:
	 * - this process has cap_sys_chroot=ep
	 * - the config files are secure
	 * - the config files are  readable
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
	 * - chroot the new directory
	 * - change cwd
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
	/* run command */
	execvp(chroot_command[0], chroot_command);
	/* if there is an error, abort cleanly */
	perror("execvp");
	return 2;
}
