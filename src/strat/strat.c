/*
 * strat.c
 *
 *      This program is free software; you can redistribute it and/or
 *      modify it under the terms of the GNU General Public License
 *      version 2 as published by the Free Software Foundation.
 *
 * Copyright (c) 2012-2020 Daniel Thau <danthau@bedrocklinux.org>
 *
 * This program is a derivative work of capchroot 0.1, and thus:
 * Copyright (c) 2009 Thomas Bächler <thomas@archlinux.org>
 *
 * This will run the specified Bedrock Linux stratum's instance of an
 * executable.
 */

#define _GNU_SOURCE

#include <errno.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/capability.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/xattr.h>
#include <unistd.h>

#define STATE_DIR "/bedrock/run/enabled_strata/"
#define STATE_DIR_LEN strlen(STATE_DIR)
#define RESTRICTED_CMD_DIR "/bedrock/run/restricted_cmds/"
#define RESTRICTED_CMD_DIR_LEN strlen(RESTRICTED_CMD_DIR)
#define STRATA_ROOT "/bedrock/strata/"
#define STRATA_ROOT_LEN strlen(STRATA_ROOT)
#define CROSS_DIR "/bedrock/cross"
#define CROSS_DIR_LEN strlen(CROSS_DIR)
#define LOCAL_ALIAS "local"
#define LOCAL_ALIAS_LEN strlen(LOCAL_ALIAS_LEN)

#ifdef MIN
#undef MIN
#endif
#define MIN(x, y) (x < y ? x : y)

enum root_mode {
	root_mode_chroot,
	root_mode_namespace,
};

/*
 * Check if this process has the proper CAP_SYS_CHROOT properties.
 */
int check_capsyschroot(void)
{
	/*
	 * Get all capabilities for this process.
	 */
	cap_t caps = cap_get_proc();
	if (caps == NULL) {
		perror("strat: cap_get_proc: ");
		return -1;
	}

	/*
	 * Extract cap_sys_chroot fields from capabilities.
	 */
	cap_flag_value_t permitted;
	cap_flag_value_t effective;
	cap_flag_value_t inheritable;
	cap_get_flag(caps, CAP_SYS_CHROOT, CAP_PERMITTED, &permitted);
	cap_get_flag(caps, CAP_SYS_CHROOT, CAP_EFFECTIVE, &effective);
	cap_get_flag(caps, CAP_SYS_CHROOT, CAP_INHERITABLE, &inheritable);

	/*
	 * Free memory used by capabilities as it is no longer needed.
	 */
	cap_free(caps);

	if (permitted == CAP_SET && effective == CAP_SET && inheritable == CAP_CLEAR) {
		return 0;
	} else {
		return -1;
	}
}

void parse_args(int argc, char *argv[], int *flag_help, int *flag_restrict,
	int *flag_unrestrict, int *flag_namespace, char **param_stratum, char **param_arg0, char ***param_arglist)
{
	*flag_help = 0;
	*flag_restrict = 0;
	*flag_unrestrict = 0;
	*flag_namespace = 0;
	*param_stratum = NULL;
	*param_arg0 = NULL;
	*param_arglist = NULL;

	argc--;
	argv++;

	for (;;) {
		if (argc > 0 && (strcmp(argv[0], "-h") == 0 || strcmp(argv[0], "--help") == 0)) {
			*flag_help = 1;
			return;
		} else if (argc > 0 && (strcmp(argv[0], "-r") == 0 || strcmp(argv[0], "--restrict") == 0)) {
			*flag_restrict = 1;
			argv++;
			argc--;
		} else if (argc > 0 && (strcmp(argv[0], "-u") == 0 || strcmp(argv[0], "--unrestrict") == 0)) {
			*flag_unrestrict = 1;
			argv++;
			argc--;
		} else if (argc > 0 && (strcmp(argv[0], "-n") == 0 || strcmp(argv[0], "--namespace") == 0)) {
			*flag_namespace = 1;
			argv++;
			argc--;
		} else if (argc > 1 && (strcmp(argv[0], "-a") == 0 || strcmp(argv[0], "--arg0") == 0)) {
			*param_arg0 = argv[1];
			argv += 2;
			argc -= 2;
		} else {
			break;
		}
	}

	if (argc > 0) {
		*param_stratum = argv[0];
		argv++;
		argc--;
	} else {
		fprintf(stderr, "strat: no stratum specified, aborting\n");
		exit(1);
	}

	*param_arglist = argv;
}

void print_help(void)
{
	printf(""
		"Usage: strat [options] <stratum> <command>\n"
		"\n"
		"Options:\n"
		"  -r, --restrict    disable cross-stratum hooks\n"
		"  -u, --unrestrict  do not disable cross-stratum hooks\n"
		"  -n, --namespace   make a new mount namespace with the new stratum at the root, instead of using chroot\n"
		"  -a, --arg0 <ARG0> specify arg0\n"
		"  -h, --help        print this message\n"
		"\n"
		"Examples:\n"
		"  Run centos's ls command:\n"
		"  $ strat centos ls\n"
		"  Run gentoo's busybox with arg0=\"ls\":\n"
		"  $ strat --arg0 ls gentoo busybox\n"
		"  By default make is unrestricted.\n"
		"  Run debian's make restricted to only debian's files:\n"
		"  $ strat -r debian make\n"
		"  By default makepkg is restricted.\n"
		"  Run arch's makepkg without restricting it to arch's files:\n" "  $ strat -u arch makepkg\n");
}

/*
 * Strata aliases are symlinks in STRATA_ROOT which (eventually) resolve to
 * directories in STRATA_ROOT.  Dereferencing aliases is effectively:
 *
 *     basename "$(realpath "/bedrock/strata/$alias")"
 */
int deref_alias(const char *const alias, char *stratum, size_t len)
{
	size_t alias_len = strlen(alias);
	char alias_path[STRATA_ROOT_LEN + alias_len + 1];
	strcpy(alias_path, STRATA_ROOT);
	strcat(alias_path, alias);

	/*
	 * realpath(3) assumes resolved_path is of size PATH_MAX.
	 */
	char resolved_path[PATH_MAX];
	if (realpath(alias_path, resolved_path) == NULL) {
		return -1;
	}

	if (strncmp(resolved_path, STRATA_ROOT, STRATA_ROOT_LEN) != 0) {
		return -1;
	} else if (strchr(resolved_path + STRATA_ROOT_LEN, '/') != NULL) {
		return -1;
	} else if (strlen(resolved_path) - STRATA_ROOT_LEN > len - 1) {
		return -1;
	}

	strncpy(stratum, resolved_path + STRATA_ROOT_LEN, len);
	return 0;
}

int check_config_secure(char *config_path)
{
	/*
	 * Copy path so we can modify it
	 */
	char path[strlen(config_path) + 1];
	strcpy(path, config_path);

	/*
	 * Iterate through file and parent directories, checking each.
	 * If a parent directory has loose permissions, someone may `mv`
	 * a root-owned file over the config.
	 */
	for (char *p = NULL; (p = strrchr(path, '/')) != NULL; *p = '\0') {
		struct stat stbuf;
		/*
		 * Get stats on file.  If we can't, file doesn't exist.
		 */
		if (lstat(path, &stbuf) != 0) {
			errno = ENOENT;
			return -1;
		}
		/*
		 * If the file is a symlink, we'd have to check the target
		 * location is secure as well.  As a lazy shortcut, just
		 * disallow symlinks.
		 */
		if (S_ISLNK(stbuf.st_mode)) {
			errno = EMLINK;
			return -1;
		}
		/*
		 * Ensure file is owned by root.
		 */
		if (stbuf.st_uid != 0) {
			errno = EACCES;
			return -1;
		}
		/*
		 * Ensure config file is not writable by anyone other than
		 * root.
		 */
		if ((stbuf.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
			errno = EACCES;
			return -1;
		}
	}

	return 0;
}

/*
 * Remove all CROSS_DIR references in specified environment variable.
 */
int restrict_envvar(const char *const envvar)
{
	char *val = getenv(envvar);
	if (val == NULL) {
		return 0;
	}

	char new_val[strlen(val) + 1];
	new_val[0] = '\0';

	char *start;
	char *end;
	for (start = val, end = strchr(start, ':'); end != NULL; start = end + 1, end = strchr(start, ':')) {
		if (strncmp(start, CROSS_DIR, CROSS_DIR_LEN) == 0) {
			continue;
		}
		if (new_val[0] != '\0') {
			strcat(new_val, ":");
		}
		strncat(new_val, start, end - start);
		new_val[end - val] = '\0';
	}
	if (start != NULL && strncmp(start, CROSS_DIR, CROSS_DIR_LEN) != 0) {
		if (new_val[0] != '\0') {
			strcat(new_val, ":");
		}
		strcat(new_val, start);
	}

	return setenv(envvar, new_val, 1);
}

/*
 * Various environment variable tweaks to minimize automatic cross-stratum
 * access.
 */
int restrict_env(void)
{
	int err = 0;
	err |= restrict_envvar("PATH");
	err |= restrict_envvar("MANPATH");
	err |= restrict_envvar("INFOPATH");
	err |= restrict_envvar("XDG_DATA_DIRS");
	err |= setenv("SHELL", "/bin/sh", 1);
	err |= setenv("BEDROCK_RESTRICT", "1", 1);
	/*
	 * While an argument could be made to restrict TERMINFO_DIRS, it is
	 * more likely in practice to confuse users than help.
	 *
	 * err |= restrict_envvar("TERMINFO_DIRS");
	 */
	return err;
}

int check_cmd_restricted(char *file)
{
	if (file == NULL || file[0] == '\0') {
		return 0;
	}

	char *cmd;
	if ((cmd = strrchr(file, '/')) != NULL) {
		cmd++;
	} else {
		cmd = file;
	}

	int cmd_len = strlen(cmd);
	char path[RESTRICTED_CMD_DIR_LEN + cmd_len + 1];
	strcpy(path, RESTRICTED_CMD_DIR);
	strcat(path, cmd);

	return check_config_secure(path) >= 0;
}

int break_out_of_chroot(char *reference_dir)
{
	/*
	 * Go as high in the tree as possible
	 */
	chdir("/");

	/*
	 * Change the root directory to something that doesn't contain the cwd.
	 */
	if (chroot(reference_dir) < 0) {
		return -1;
	}
	/*
	 * One cannot chdir("..") through the root directory.  However, the
	 * root directory no longer contains our current working directory, and
	 * thus we're free to chdir("..") until we hit the "real" root
	 * directory.  We'll know we're there when the current and parent
	 * directories both have the same device number and inode.
	 *
	 * It is technically possible for a directory and its parent directory
	 * to have the same device number and inode without being the real
	 * root. For example, this could occur if one bind mounts a directory
	 * into itself or using a filesystem (e.g. fuse) which does not use
	 * unique inode numbers for every directory.  However, once we've run
	 * the chdir("/") above, we're past any such possibility with the
	 * expected Bedrock Linux directory structure.
	 */
	struct stat stat_cwd;
	struct stat stat_parent;
	do {
		chdir("..");
		lstat(".", &stat_cwd);
		lstat("..", &stat_parent);
	} while (stat_cwd.st_ino != stat_parent.st_ino || stat_cwd.st_dev != stat_parent.st_dev);

	/*
	 * We're at the absolute root directory.  However, the root directory
	 * is still back at reference_dir.  Set the new location.
	 */
	return chroot(".");
}

int chroot_to_stratum(char *stratum_path)
{
	/*
	 * One stratum - typically the init providing one - will be at the
	 * "real" root.  If we're already there, we don't want to chroot.
	 *
	 * We can detect this scenario if the root directory and stratum_path
	 * both have the same device and inode numbers.
	 */
	struct stat stat_real_root;
	struct stat stat_stratum_path;
	stat("/", &stat_real_root);
	stat(stratum_path, &stat_stratum_path);
	if (stat_real_root.st_dev == stat_stratum_path.st_dev && stat_real_root.st_ino == stat_stratum_path.st_ino) {
		return 0;
	}

	if (chdir(stratum_path) != 0) {
		return -1;
	}
	return chroot(".");
}

int pivot_root_to_stratum(char *stratum_path, char *current_stratum)
{
	/*
	 * This moves around mounts in the namespace, ultimately making it
	 * look like the stratum we are switching to was the init stratum.
	 *
	 * This was originally written as a shell script. The shell commands
	 * are preserved here as comments.
	 */

	char src_buf[strlen(stratum_path) + strlen("/bedrock/strata/") + strlen(current_stratum) + 1];
	char dst_buf[strlen(stratum_path) + strlen("/bedrock/strata/") + strlen(current_stratum) + 1];

	/* unshare --mount */
	if (unshare(CLONE_NEWNS) != 0) {
		perror("unshare(CLONE_NEWNS)");
		return -1;
	}
	if (mount(NULL, "/", NULL, MS_PRIVATE | MS_REC, NULL) != 0) {
		perror("mount(/, MS_PRIVATE | MS_REC)");
		return -1;
	}

	/* pivot_root /bedrock/strata/${to} /bedrock/strata/${to}/bedrock/strata/${from} */
	sprintf(dst_buf, "%s/bedrock/strata/%s", stratum_path, current_stratum);
	if (syscall(SYS_pivot_root, stratum_path, dst_buf) != 0) {
		perror("pivot_root");
		return -1;
	}

	/* mount --move /bedrock/strata/${from}/bedrock /tmp */
	sprintf(src_buf, "/bedrock/strata/%s/bedrock", current_stratum);
	sprintf(dst_buf, "/tmp");
	if (mount(src_buf, dst_buf, NULL, MS_MOVE, NULL) != 0) {
		perror("move /bedrock/strata/current/bedrock -> /tmp");
		return -1;
	}

	/* mount --move /bedrock/strata/${from} /tmp/strata/${from} */
	sprintf(src_buf, "/bedrock/strata/%s", current_stratum);
	sprintf(dst_buf, "/tmp/strata/%s", current_stratum);
	if (mount(src_buf, dst_buf, NULL, MS_MOVE, NULL) != 0) {
		perror("move /bedrock/strata/current -> /tmp/strata/current");
		return -1;
	}

	/* mount --move /bedrock /tmp/strata/${from}/bedrock */
	sprintf(src_buf, "/bedrock");
	sprintf(dst_buf, "/tmp/strata/%s/bedrock", current_stratum);
	if (mount(src_buf, dst_buf, NULL, MS_MOVE, NULL) != 0) {
		perror("move /bedrock -> /tmp/strata/current/bedrock");
		return -1;
	}

	/* mount --move /tmp /bedrock */
	if (mount("/tmp", "/bedrock", NULL, MS_MOVE, NULL) != 0) {
		perror("move /tmp -> /bedrock");
		return -1;
	}

	return 0;
}

/*
 * Like execvp(), but skips certain $PATH entries
 */
void execv_skip(char *file, char *argv[], char *skip)
{
	if (file == NULL || file[0] == '\0') {
		errno = ENOENT;
		return;
	}

	/*
	 * If file has a "/" in it, it is a specific path to a file; do not
	 * search PATH.
	 */
	if (strchr(file, '/') != NULL) {
		execv(file, argv);
		/*
		 * If we got here, there was some error.  errno should be set
		 * accordingly.
		 */
		return;
	}

	char *path = getenv("PATH");
	if (path == NULL) {
		path = "/usr/bin:/bin";
	}

	int skip_len = strlen(skip);
	int entry_len = strlen(path) + 1 + strlen(file) + 1;
	char entry[entry_len];
	char *start;
	char *end;
	for (start = path, end = strchr(start, ':'); end != NULL; start = end + 1, end = strchr(start, ':')) {
		if (strncmp(start, skip, skip_len) == 0) {
			continue;
		}
		strncpy(entry, start, end - start);
		entry[end - start] = '/';
		entry[end - start + 1] = '\0';
		strcat(entry, file);
		/*
		 * Attempt to execute.  If this succeeds, execution hands off
		 * there and this program effectively ends. Otherwise - if this
		 * program continues - check next entry next loop.
		 */
		execv(entry, argv);
	}
	if (start != NULL && strncmp(start, skip, skip_len) != 0) {
		int wrote = snprintf(entry, entry_len, "%s/%s", start, file);
		if (wrote > 0 && wrote < entry_len) {
			execv(entry, argv);
		}
	}

	/*
	 * Could not find item in PATH
	 */
	errno = ENOENT;
	return;
}

int switch_stratum(const char *alias, enum root_mode mode)
{
	/*
	 * local alias indicates no stratum change is needed.  Hard code this
	 * to avoid unnecessary overhead.
	 */
	if (strcmp(alias, LOCAL_ALIAS) == 0) {
		return 0;
	}

	char stratum[PATH_MAX];
	if (deref_alias(alias, stratum, sizeof(stratum)) < 0) {
		fprintf(stderr, "strat: unable to find stratum \"%s\"\n", alias);
		return -1;
	}

	char current_stratum[PATH_MAX];
	ssize_t len = getxattr("/", "user.bedrock.stratum",
		current_stratum, sizeof(current_stratum) - 1);
	if (len < 0) {
		fprintf(stderr, "strat: unable to determine current stratum\n");
		return -errno;
	}
	current_stratum[len] = '\0';

	/*
	 * Already at specified stratum.
	 */
	if (strcmp(current_stratum, stratum) == 0) {
		return 0;
	}

	/*
	 * Above early returns are used to minimize ptrace concern described
	 * below.
	 */
	if (check_capsyschroot() < 0) {
		fprintf(stderr,
			"strat: wrong cap_sys_chroot capability.\n"
			"This may occur when using ptrace across stratum boundaries such as with\n"
			"`strace` or `gdb`.  To remedy this install strace/gdb/etc from same stratum\n"
			"as the traced program and use `strat` to specify appropriate strace/gdb/etc.\n");
		return -1;
	}

	char cwd[PATH_MAX];
	if (getcwd(cwd, sizeof(cwd)) == NULL) {
		fprintf(stderr, "strat: error determining current working directory\n");
		return -1;
	}

	size_t stratum_len = strlen(stratum);
	char state_file_path[STATE_DIR_LEN + stratum_len + 1];
	strcpy(state_file_path, STATE_DIR);
	strcat(state_file_path, stratum);

	if (check_config_secure(state_file_path) >= 0) {
		/*
		 * Config is found and secure, we're good to go
		 */
	} else if (errno == EACCES) {
		fprintf(stderr,
			"strat: the state file for stratum\n"
			"    %s\n" "at\n" "    %s\n" "is insecure, refusing to continue.\n", stratum, state_file_path);
		return -1;
	} else if (errno == EMLINK) {
		fprintf(stderr,
			"strat: the path to the state file for stratum\n"
			"    %s\n"
			"at\n" "    %s\n" "contains a symlink, refusing to continue.\n", stratum, state_file_path);
		return -1;
	} else if (errno == ENOENT) {
		fprintf(stderr,
			"strat: could not find state file for stratum\n"
			"    %s\n"
			"at\n" "    %s\n" "Perhaps the stratum is disabled or typo'd?\n", stratum, state_file_path);
		return -1;
	} else {
		fprintf(stderr,
			"strat: error sanity checking request for stratum\n"
			"    %s\n" "via state file at\n    %s\n", stratum, state_file_path);
		return -1;
	}

	if (break_out_of_chroot("/bedrock") < 0) {
		fprintf(stderr, "strat: unable to break out of chroot\n");
		return -1;
	}

	char stratum_path[STRATA_ROOT_LEN + stratum_len + 1];
	strcpy(stratum_path, STRATA_ROOT);
	strcat(stratum_path, stratum);

	switch (mode) {
	case root_mode_chroot:
		if (chroot_to_stratum(stratum_path) < 0) {
			fprintf(stderr, "strat: unable chroot() to %s\n", stratum_path);
			return -1;
		}
		break;

	case root_mode_namespace:
		if (pivot_root_to_stratum(stratum_path, current_stratum) < 0) {
			fprintf(stderr, "strat: unable to create namespace for stratum %s\n", stratum);
			return -1;
		}
		break;
	}

	/*
	 * Set the current working directory in this new stratum to the same as
	 * it was originally, if possible; fall back to the root otherwise.
	 */
	if (chdir(cwd) < 0) {
		chdir("/");
		fprintf(stderr, "strat: warning: unable to set cwd to\n" "    %s\nfor stratum\n    %s\n", cwd, stratum);
		switch (errno) {
		case EACCES:
			fprintf(stderr, "due to: permission denied (EACCES).\n");
			break;
		case ENOENT:
			fprintf(stderr, "due to: no such directory (ENOENT).\n");
			break;
		default:
			perror("due to: execv:\n");
			break;
		}
		fprintf(stderr, "falling back to root directory\n");
	}

	return 0;
}

int main(int argc, char *argv[])
{
	int flag_help;
	int flag_restrict;
	int flag_unrestrict;
	int flag_namespace;
	char *param_stratum;
	char *param_arg0;
	char **param_arglist;
	parse_args(argc, argv, &flag_help, &flag_restrict, &flag_unrestrict,
		&flag_namespace, &param_stratum, &param_arg0, &param_arglist);

	if (flag_help) {
		print_help();
		return 0;
	}

	if (flag_unrestrict) {
		/* flag_unrestrict overrides else-branched restriction code */
	} else if (flag_restrict && restrict_env() < 0) {
		fprintf(stderr, "strat: unable to set restricted environment\n");
		return 1;
	} else if (check_cmd_restricted(param_arglist[0]) && restrict_env() < 0) {
		fprintf(stderr, "strat: unable to set restricted environment\n");
		return 1;
	}

	if (switch_stratum(param_stratum, flag_namespace) < 0) {
		return 1;
	}

	/*
	 * If a command was specified, try to execute it.  Otherwise, fall back
	 * to $SHELL.  If that fails, fall back to /bin/sh.
	 */
	char *file = NULL;
	if (param_arglist[0] != NULL) {
		file = param_arglist[0];
		if (param_arg0 != NULL) {
			param_arglist[0] = param_arg0;
		}
		execv_skip(file, param_arglist, CROSS_DIR);
	} else {
		/*
		 * No command specified.  Try $SHELL.
		 */
		char **arglist = (char *[]) { NULL, NULL };
		file = getenv("SHELL");
		/*
		 * Strip the path, leaving only the filename itself.  The same
		 * executable may be in different locations in different
		 * strata, e.g. /bin/zsh vs /usr/bin/zsh.  This also ensures
		 * shells pointing to /bedrock/cross aren't followed, as that
		 * would defeat the purpose of the strat call.
		 */
		if (file != NULL && strrchr(file, '/') != NULL) {
			file = strrchr(file, '/') + 1;
		}
		if (file) {
			arglist[0] = file;
			execv_skip(file, arglist, CROSS_DIR);
		}
		/*
		 * $SHELL didn't work.  Fall back to /bin/sh.
		 */
		file = "/bin/sh";
		arglist[0] = file;
		execv_skip(file, arglist, CROSS_DIR);
	}

	/*
	 * execv() would have taken over execution if it worked.  If we're
	 * here, there was an error.
	 */
	fprintf(stderr, "strat: could not run\n" "    %s\nfrom stratum\n    %s\n", file, param_stratum);
	switch (errno) {
	case EACCES:
		fprintf(stderr, "due to: permission denied (EACCES).\n");
		break;
	case ENOENT:
		fprintf(stderr, "due to: unable to find file (ENOENT)\n");
		break;
	default:
		perror("due to: execv:\n");
		break;
	}

	return 1;
}
