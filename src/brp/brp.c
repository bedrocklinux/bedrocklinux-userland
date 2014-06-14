/*
 * brp.c
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * version 2 as published by the Free Software Foundation.
 *
 * Copyright (c) 2014 Daniel Thau <danthau@bedrocklinux.org>
 *
 * This program mounts a filesystem which:
 *
 * - Unions directories together.  If any of the directories contain a file, it
 *   is available here.  This can be used, for example, to ensure man can see
 *   man pages placed in a variety of locations.
 * - Modifies files to handle Bedrock Linux local context issues.  For example,
 *   executables in directories such as /usr/bin are wrapped in Bedrock Linux's
 *   brc utility.
 * - Modifies symbolic links to handle the new mount point.
 * - Is (baring the /reparse_config file) entirely read-only.
 * - The contents are updated on-the-fly and/or in-the-background so whenever a
 *   file is accessed it is always up-to-date.
 * - The filesystem can be told to reload its config on-the-fly to, for example,
 *   handle the addition or removal of the directories it is unioning.
 *
 * Various notes:
 *
 * This program regularly loops over items[], clients[] and items.ins[].  To
 * make it easier to follow, each of these will use the same indexing variable
 * throughout:
 *
 * - items[i]
 * - clients[c]
 * - items[i].ins[n]
 *
 * Where other indices are required, they will similarly use a one-character
 * mnemonic index.
 */

#define FUSE_USE_VERSION 30
#include <fuse3/fuse.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>
#include <dirent.h>
#include <linux/limits.h>

#include <libbedrock.h>

#define CONFIG "/bedrock/etc/brp.conf"
#define CONFIGLEN strlen(CONFIG)

#define BRP_PASS        0 /* pass file through unaltered */
#define BRP_BRC_WRAP    1 /* return a script that wraps executable in brc */
#define BRP_EXEC_FILTER 2 /* filter [Try]Exec= lines as needed */

/*
* Quite a few times in this program it loops over items[], clients[] and
* items.ins[] generating a series of paths, "out_path", based on those three
* lists and the contents of the path stored in "in_path".  This is used to
* search for which real file brp should return given the input file path,
* configuration, and actual contents on disk.
*
* Since this happens numerous times in the code base and is very performance
* sensitive, it is a macro.
*
* Example:
* - in_path = "/bin/vim"
* - items[i].out = "/"
* - clients[c] = "gentoo"
* - items.in[n] = "/usr/local/bin"
*
* Will create:
* - out_path = "/bedrock/clients/gentoo/usr/local/bin/vim"
* - in_path = "/bin/vim"
* - base_path =    ^^^^
*
*
* We use strncmp() to check up to the relevant part of the string, after which
* could be either a null (indicating the strings match entirely) or a forward
* (indicating it contains a directory).  If the following character is not a
* null or a forward slash, this means the directories do not match up.
*
* The following variables should be allocated before calling this:
*
* int i, n, c, len_remaining;
* char out_path[PATH_MAX+1];
* const char* base_path;
*/
#define BRP_LOOP_START                                                 \
for (i=0; i<item_count; i++) {                                         \
	if (strncmp(in_path, items[i].out, items[i].out_len) == 0 &&       \
		(in_path[items[i].out_len] == '\0' ||                          \
				in_path[items[i].out_len] == '/')) {                   \
		base_path = in_path + items[i].out_len;                        \
		for (c=0; c<client_count; c++) {                               \
			for (n=0; n<items[i].in_count; n++) {                      \
				len_remaining = PATH_MAX;                              \
				strncpy(out_path, "/bedrock/clients/", len_remaining); \
				len_remaining -= 17;                                   \
				strncat(out_path, clients[c], len_remaining);          \
				len_remaining -= client_lens[c];                       \
				strncat(out_path, items[i].ins[n], len_remaining);     \
				len_remaining -= items[i].in_lens[n];                  \
				strncat(out_path, base_path, len_remaining);

#define BRP_LOOP_END \
			}        \
		}            \
	}                \
}

/*
* This is a collection of the brp root-level output directories, the input
* directories they correspond to, and the operation that should be done
* translating the input content to output content.
*/
struct item {
	/* operation */
	unsigned int oper;
	/* output directory */
	char *out;
	int out_len;
	/* input directories */
	char **ins;
	size_t *in_lens;
	size_t in_count;
};

struct item *items;
size_t item_count;

/* this will hold the list of clients, in priority order */
char **clients;
size_t *client_lens;
size_t client_count;

/* default stat information so we don't have to recalculate at runtime. */
struct stat root_stat;
struct stat reparse_stat;

/*
 * One cannot directly feed strcmp() to qsort().  This is a small wrapper to
 * remedy this issue.
 */
int strcmpwrap(void const *a, void const *b)
{
	return strcmp(*(char * const *)a, *(char * const *)b);
}

/*
 * Walks along the path and resolves all symlinks.  Returns 0 for success or a
 * negative value if it failed for whatever reason, including if the symlink
 * does not point to an existing file.  If it is successful, the argument
 * in_path is replaced with the resolved location.  Assumes the incoming string
 * is of size PATH_MAX+1.
 */
int resolve_symlink(char *path)
{

	/*
	 * Find client root.  This will be useful in case we run into an absolute
	 * symlink, in which case this becomes the new root.  Think of the way
	 * chroot operates; symlinks are being resolved as though they are
	 * chrooted.
	 * For example, if an symlink found at
	 *     /bedrock/clients/gentoo/tmp/foo
	 * contains
	 *     /bar
	 * It should be redirected to
	 *     /bedrock/clients/gentoo/bar
	 */
	int root_start = strlen("/bedrock/clients/");
	while (path[root_start] != '/') {
		root_start++;
	}

	/* This will hold one directory or the final file in the path */
	char new_elem[PATH_MAX+1];
	/* This will hold a test path to check if we should resolve a symlink or
	 * simply append a new directory */
	char tmp_path[PATH_MAX+1];
	/* This will hold a symlink's output */
	char link[PATH_MAX+1];
	/* This will hold the current state of the path we are building.  If we are
	 * successful, when done this will be copied into the provided path so the
	 * calling function can access it. */
	char out_path[PATH_MAX+1];
	/* Start and end will point to the start and end of the current path element */
	int start;
	int end;
	int bytes_read;
	/* tracks how much of the out_path buffer is available to strncat() into */
	int len_remaining;
	/* To determine if something is a symlink, we're stat()'ing it.  This holds
	 * the stat output. */
	struct stat tmp_stbuf;
	/*
	 * The length of the incoming path may be needed multiple times; calculate
	 * it once per loop to reference later.
	 */
	int path_len;

	/*
	 * Symlinks can point to symlinks.  This should loop until the symlink is
	 * fully resolved or we hit some limit set to catch infinite loops.
	 *
	 * TODO: When a symlink in the path is resolved, we could check that new
	 * component for symlinks.  That may be faster than looping over the entire
	 * path repeatedly.
	 */
	int loop_count = 0;
	while (lstat(path, &tmp_stbuf) == 0 && S_ISLNK(tmp_stbuf.st_mode) && loop_count < 20) {
		/*
		 * Build the output we are going to use in out_path.  Once we're done, if
		 * successful, we'll strcpy it into path so the calling function can access
		 * it.  Start with the client root (again, think chroot).
		 */
		strncpy(out_path, path, root_start);
		out_path[root_start] = '\0';
		start = root_start;
		len_remaining = PATH_MAX - root_start;
		path_len = strlen(path);

		for (end = start + 1; end < path_len + 1; end++) {
			/* we found the end of a new element */
			if (path[end] == '/' || path[end] == '\0') {
				/* copy the element into new_elem */
				strncpy(new_elem, path + start, end - start < PATH_MAX ? end - start : PATH_MAX);
				new_elem[end - start < PATH_MAX ? end - start : PATH_MAX] = '\0';
				/* update the new start position for the next element */
				start = end;
				/* check if path with new elem is a symlink */
				strncpy(tmp_path, out_path, PATH_MAX);
				strncat(tmp_path, new_elem, PATH_MAX - strlen(out_path));
				if (lstat(tmp_path, &tmp_stbuf) != 0) {
					/* could not resolve path */
					return -ENOENT;
				}
				if (S_ISLNK(tmp_stbuf.st_mode)) {
					/* is a symlink - read it */
					bytes_read = readlink(tmp_path, link, PATH_MAX);
					if (bytes_read <= 0) {
						return -1;
					}
					link[bytes_read] = '\0';
					/* absolute and relative symlinks must be handled differently */
					if (link[0] == '/') {
						/* absolute link - reset to root path */
						strncpy(out_path, path, root_start);
						out_path[root_start] = '\0';
						len_remaining = PATH_MAX - root_start;
						strncat(out_path, link, len_remaining);
					} else {
						/* relative link - just append */
						strncat(out_path, "/", len_remaining);
						len_remaining -= 1;
						strncat(out_path, link, len_remaining);
						len_remaining -= bytes_read;
					}
				} else {
					/* not a symlink - append term */
					strncat(out_path, new_elem, PATH_MAX - strlen(out_path));
				}
			}
		}
		loop_count++;
		/* did not resolve (or originally point to) a real file */
		if (lstat(out_path, &tmp_stbuf) != 0) {
			return -ENOENT;
		}
		/* might be infinite loop, abort */
		if (loop_count >= 10) {
			return -ELOOP;
		}
		/* success - copy resolved path into provided string */
		strcpy(path, out_path);
	}
	return 0;
}

/*
 * Free the structures storing the config.  Usually called before repopulating
 * them.
 */
void free_config()
{
	int i, c, n;
	for (c=0; c<client_count; c++) {
		free(clients[c]);
	}
	free(clients);
	free(client_lens);
	client_count = 0;

	for (i=0; i<item_count; i++) {
		free(items[i].out);
		for (n=0; n<items[n].in_count; n++) {
			free(items[i].ins[n]);
		}
		free(items[i].ins);
	}
	free(items);
	item_count = 0;
}

/*
 * Return a pointer to a string describing the current configuration.  Up to
 * the calling program to free() it.  This is used when /reparse_config is read
 * to show the current configuration.  It is useful for debugging.
 */
char* config_contents()
{
	int i, c, n;
	/*
	 * Run through twice - first time get sizes so we can malloc, next time
	 * build string.
	 */

	size_t len = 0;
	len += strlen("clients:\n");
	for (c=0; c<client_count; c++) {
		len += strlen("  ");
		len += client_lens[c];
		len += strlen("\n");
	}
	len += strlen("items:\n");
	for (i=0; i<item_count; i++) {
		len += strlen("  oper = ");
		if (items[i].oper == BRP_PASS) {
			len += strlen("pass");
		} else if (items[i].oper == BRP_BRC_WRAP) {
			len += strlen("brc-wrap");
		} else if (items[i].oper == BRP_EXEC_FILTER) {
			len += strlen("exec-filter");
		}
		len += strlen("\n");
		len += strlen("  out = ");
		len += items[i].out_len;
		len += strlen("/\n");
		len += strlen("  in:\n");
		for (n=0; n<items[i].in_count; n++) {
			len += strlen("    ");
			len += items[i].in_lens[n];
			len += strlen("/\n");
		}
	}
	len += strlen("\n");

	char *config_str = malloc(len * sizeof(char*));

	strcpy(config_str, "clients:\n");
	for (c=0; c<client_count; c++) {
		strcat(config_str, "  ");
		strcat(config_str, clients[c]);
		strcat(config_str, "\n");
	}

	strcat(config_str, "items:\n");
	for (i=0; i<item_count; i++) {
		strcat(config_str, "  oper = ");
		if (items[i].oper == BRP_PASS) {
			strcat(config_str, "pass");
		} else if (items[i].oper == BRP_BRC_WRAP) {
			strcat(config_str, "brc-wrap");
		} else if (items[i].oper == BRP_EXEC_FILTER) {
			strcat(config_str, "exec-filter");
		}
		strcat(config_str, "\n");
		strcat(config_str, "  out = ");
		strcat(config_str, items[i].out);
		strcat(config_str, "/\n");
		strcat(config_str, "  in:\n");
		for (n=0; n<items[i].in_count; n++) {
			strcat(config_str, "    ");
			strcat(config_str, items[i].ins[n]);
			strcat(config_str, "/\n");
		}
	}
	strcat(config_str, "\n");

	return config_str;
}

/*
* Read the configuration file and client list and populate the global variables
* for those accordingly.
*/
void parse_config()
{
	/*
	 * Ensure we're using a root-modifiable-only configuration file, just in case.
	 */
	ensure_config_secure(CONFIG);

	/*
	 * TODO: Maybe don't call out to shell to parse the config.
	 */

	/*
	 * Pre-parse config.
	 * This outputs, one item per line:
	 * - the maximum line length
	 * - client_count
	 * - each client (in order)
	 * - item_count
	 * - For each item:
	 *   - oper
	 *   - out
	 *   - in_count
	 *   - ins
	 *
	 * The "count" items need to come before what they are counting to make it
	 * easy to malloc().
	 */

	FILE* fp = popen(
			"/bedrock/bin/busybox awk '\n"
			"BEGIN {\n"
			"	FS=\"[, ]\\+\"\n"
			"	while (\"/bedrock/bin/bri -l\" | getline) {\n"
			"		existing_clients[$0] = $0\n"
			"	}\n"
			"	close(\"/bedrock/bin/bri -l\")\n"
			"}\n"
			"length($0)>m {\n"
			"	m=length($0)\n"
			"}\n"
			"!/^\\s*#/ && !/^\\s*$/ && !/^\\s*\\[/ && (s == \"pass\" || s == \"brc-wrap\" || s == \"exec-filter\") {\n"
			"	split($1,a,\"/\")\n"
			"	if (substr($1,1,1) == \"/\" && length(a) == 2) {\n"
			"		item_i+=0\n"
			"		items[item_i\".oper\"] = s\n"
			"		items[item_i\".out\"] = $1\n"
			"		for (i=3; i<=NF; i++) {\n"
			"			items[item_i\".in.\"(i-3)] = $i\n"
			"		}\n"
			"		items[item_i\".in_count\"] = (i-3)\n"
			"		item_i++;\n"
			"	}\n"
			"}\n"
			" !/^\\s*#/ && !/^\\s*$/ && s == \"client-order\" {\n"
			"	if ($0 in existing_clients) {\n"
			"		clients_ordered[client_i++] = $0\n"
			"		clients[$0] = $0\n"
			"	}\n"
			"}\n"
			"/^\\s*\\[[^]]*\\]\\s*$/ {\n"
			"	s = substr($1, 2, length($1)-2)\n"
			"}\n"
			"END {\n"
			"	print m\n"
			"	for (client in existing_clients) {\n"
			"		if (!(client in clients)) {\n"
			"			clients_ordered[client_i++] = client\n"
			"		}\n"
			"	}\n"
			"	close(\"bri -l\")\n"
			"	print client_i\n"
			"	for (i=0; i<client_i; i++) {\n"
			"		print clients_ordered[i]\n"
			"	}\n"
			"	print item_i\n"
			"	for (i=0; i<item_i; i++) {\n"
			"		print items[i\".oper\"]\n"
			"		print items[i\".out\"]\n"
			"		print items[i\".in_count\"]\n"
			"		for (j=0; j<items[i\".in_count\"]; j++) {\n"
			"			print items[i\".in.\"j]\n"
			"		}\n"
			"	}\n"
			"}\n"
			"' " CONFIG, "r");

	if (fp == NULL) {
		fprintf(stderr, "Failed to parse config\n");
		exit(1);
	}

	/* malloc to hold one line */
	int maxlinelen;
	fscanf(fp, "%d\n", &maxlinelen);
	char* line = malloc(maxlinelen * sizeof(char));

	/* clients */
	fgets(line, maxlinelen, fp);
	sscanf(line, "%ld", &client_count);
	int c;
	clients = malloc(client_count * sizeof(char*));
	client_lens = malloc(client_count * sizeof(size_t));
	for (c=0; c<client_count; c++) {
		fgets(line, maxlinelen, fp);
		line[strlen(line)-1] = '\0'; /* strip newline */
		client_lens[c] = strlen(line);
		clients[c] = malloc((client_lens[c]+1) * sizeof(char*));
		strcpy(clients[c], line);
	}

	/* get items */
	fgets(line, maxlinelen, fp);
	sscanf(line, "%ld", &item_count);
	int i, n;
	items = malloc(item_count * sizeof(struct item));
	for (i=0; i<item_count; i++) {
		fgets(line, maxlinelen, fp);
		line[strlen(line)-1] = '\0'; /* strip newline */
		if (strcmp(line, "pass") == 0) {
			items[i].oper = BRP_PASS;
		} else if (strcmp(line, "brc-wrap") == 0) {
			items[i].oper = BRP_BRC_WRAP;
		} else if (strcmp(line, "exec-filter") == 0) {
			items[i].oper = BRP_EXEC_FILTER;
		} else {
			fprintf(stderr, "Failed to parse config\n");
			exit(1);
		}
		fgets(line, maxlinelen, fp);
		line[strlen(line)-1] = '\0'; /* strip newline */
		if (line[strlen(line)-1] == '/') {
			line[strlen(line)-1] = '\0'; /* strip trailing slash */
		}
		items[i].out_len = strlen(line);
		items[i].out = malloc((items[i].out_len+1) * sizeof(char*));
		strcpy(items[i].out, line);
		fgets(line, maxlinelen, fp);
		sscanf(line, "%ld", &items[i].in_count);
		items[i].ins = malloc(items[i].in_count * sizeof(char*));
		items[i].in_lens = malloc(items[i].in_count * sizeof(size_t));
		for (n=0; n<items[i].in_count; n++) {
			fgets(line, maxlinelen, fp);
			line[strlen(line)-1] = '\0'; /* strip newline */
			if (line[strlen(line)-1] == '/') {
				line[strlen(line)-1] = '\0'; /* strip trailing slash */
			}
			items[i].in_lens[n] = strlen(line);
			items[i].ins[n] = malloc((items[i].in_lens[n]+1) * sizeof(char*));
			strcpy(items[i].ins[n], line);
		}
	}

	free(line);
	fclose(fp);
}

/*
 * Writing to this filesystem is only used as a way to signal that the
 * configuration and client list should be repopulated.  Thus, it does not
 * matter which writing function is called - they should all act the same.
 * They all call this.
 */
int write_attempt(const char* path) {
	/*
	 * The *only* thing writable is the /reparse_config, and only by root.
	 * When it is written to, it will cause brp to reparse its configuration
	 * and client list.
	 */
	if (strcmp(path, "/reparse_config") == 0) {
		struct fuse_context *context = fuse_get_context();
		if (context->uid != 0) {
			/* Non-root users cannot do anything with this file. */
			return -EACCES;
		}
		free_config();
		parse_config();
		return 0;
	}
	return -EACCES;
}

/*
 * Populate stat() information for file.  This is metadata such as file size,
 * type and permissions.
 */
static int brp_getattr(const char *in_path, struct stat *stbuf)
{
	SET_CALLER_UID();

	/*
	 * The biggest performance issue with this program is when someone does a
	 * stat() on the output of a readdir() - such as `ls --color`.  This calls
	 * getattr() repeatedly in quick succession.  In this situation, the
	 * hardcoded items such as "/" and "/reparse_config" won't be called.
	 * Hence, in order to improve our worst-case scenario performance, we check
	 * for the hardcoded items *after* the configured items.
	 */

	/*
	 * Loop over all of the possible out_path items to see if we can stat()
	 * something.  If so, return that, baring brc-wrap and exec-filter, both of
	 * which have special considerations.
	 */
	int i, n, c, len_remaining;
	char out_path[PATH_MAX+1];
	char line[PATH_MAX+1];
	FILE *fp;
	const char* base_path;
	BRP_LOOP_START;
	if (lstat(out_path, stbuf) == 0) {
		/*
		 * We've successfully (1) confirmed the file exists and (2) populated
		 * stbuf.  If it is a pass item, we can return here.  Otherwise, we may
		 * need to do additional modifications to stbuf for brc-wrap and
		 * exec-filter items.
		 *
		 * The base_path[0] != '\0' check is to ensure that the given item is
		 * not in the root of the filesystem.  For example, if the in_path is
		 * "bin/vim" then the base path would be "/vim" and we'd know its not
		 * on the root.  However, if the in_path is "/bin" then the base path
		 * is "" and we should treat it as a normal directory, not a brc-wrap
		 * item.
		 */
		if (items[i].oper == BRP_BRC_WRAP && base_path[0] != '\0') {
			/*
			 * If it is a symlink, resolve it so we can set the proper
			 * permissions of the file it points to on the wrapper.
			 */
			if (resolve_symlink(out_path) < 0 || lstat(out_path, stbuf) < 0) {
				return -ENOENT;
			}
			/*
			 * Remove an setuid/setgid properties and write properties  The
			 * program we are wrapping could be setuid and owned by something
			 * other than root, in which case this would have been an exploit.
			 * Moreover, no one can write to these.
			 */
			stbuf->st_mode &= ~ (S_ISUID | S_ISGID | S_IWUSR | S_IWGRP | S_IWOTH);
			/*
			 * Set size accordingly.  This is necessary for read() to know how
			 * much to read.
			 */
			stbuf->st_size = strlen("#!/bin/sh\nexec brc ") \
							+ client_lens[c] \
							+ strlen(" ") \
							+ items[i].in_lens[n] \
							+ strlen(base_path) \
							+ strlen(" \"$@\"\n");
		} else if (items[i].oper == BRP_EXEC_FILTER && base_path[0] != '\0') {
			/*
			 * If it contains "^Exec=" and/or "^TryExec=/", read() will add in
			 * more content.  This additional content must be taken into
			 * consideration for size information.
			 */
			fp = fopen(out_path, "r");
			if (fp != NULL) {
				while (fgets(line, PATH_MAX, fp) != NULL) {
					if (strncmp(line, "Exec=", strlen("Exec=")) == 0) {
						stbuf->st_size += strlen("/bedrock/bin/brc ");
						stbuf->st_size += client_lens[c];
						stbuf->st_size += strlen(" ");
					} else if (strncmp(line, "TryExec=/", strlen("TryExec=/")) == 0) {
						stbuf->st_size += strlen("/bedrock/clients/");
						stbuf->st_size += client_lens[c];
					}
				}
				fclose(fp);
			}
		} else if (base_path[0] == '\0') {
			/*
			 * Anything on the root of the filesystem should be a directory.
			 * This check is in the root item is a symlink or has odd access
			 * permissions which would make the rest of the things in them
			 * inaccessible if the highest priority client does it.
			 */
			memcpy(stbuf, &root_stat, sizeof(struct stat));
		}
		return 0;
	}
	BRP_LOOP_END;

	/* check if the root directory */
	if (in_path[0] == '/' && in_path[1] == '\0') {
		memcpy(stbuf, &root_stat, sizeof(struct stat));
		return 0;
	}

	/* check if reparse_config */
	if (strcmp(in_path, "/reparse_config") == 0) {
		memcpy(stbuf, &reparse_stat, sizeof(struct stat));
		char *config_str = config_contents();
		stbuf->st_size = strlen(config_str);
		free(config_str);
		return 0;
	}

	/* could not find a corresponding file */
	return -ENOENT;
}

/*
 * Returns the filenames in a specified directory.  This is the heart of what
 * you think of when `ls` is run.
 */
static int brp_readdir(const char *in_path, void *buf, fuse_fill_dir_t filler,
					 off_t offset, struct fuse_file_info *fi)
{
	SET_CALLER_UID();

	(void) offset;
	(void) fi;

	int i, n, c, len_remaining;
	char out_path[PATH_MAX+1];
	const char* base_path;

	/*
	 * Check if in the root directory
	 */
	if (in_path[0] == '/' && in_path[1] == '\0') {
		/* add . and .. */
		filler(buf, ".", NULL, 0);
		filler(buf, "..", NULL, 0);
		/* add the reparse_config file */
		filler(buf, "reparse_config", NULL, 0);
		/* Add all of the items[i].out root-level directories */
		for (i=0; i<item_count; i++) {
			filler(buf, items[i].out+1, NULL, 0);
		}
		return 0;
	}

	/*
	 * Not in the root directory.  Thus, it is either in an items[i].out or it
	 * doesn't exist.  Loop over all of the items[i].out to find matches.
	 *
	 * brc-wrap items should not point to broken symlinks.
	 *
	 * We need to return a de-duplicated collection of the items we find.  For
	 * simplicity's sake, we're just going to get a list with duplicates, sort
	 * and iterate over to de-dup.  There are faster ways to do this, such as
	 * storing what we find in a hash table or self-balancing tree.
	 * TODO: make faster.
	 */
	int found_existing = 0;
	int file_count = 0;
	DIR *d;
	struct dirent *dir;
	char tmp_path[PATH_MAX+1];
	BRP_LOOP_START;
	d = opendir(out_path);
	/* found a directory - add all of its contents */
	if (d) {
		found_existing = 1;
		if (items[i].oper == BRP_BRC_WRAP) {
			/* only add brc-wrap items if they point to real files */
			while ((dir = readdir(d)) != NULL) {
				strncpy(tmp_path, out_path, PATH_MAX);
				strncat(tmp_path, "/", PATH_MAX - strlen(out_path));
				strncat(tmp_path, dir->d_name, PATH_MAX - strlen(out_path) - 1);
				if (resolve_symlink(tmp_path) == 0) {
					file_count++;
				}
			}
		} else {
			while ((dir = readdir(d)) != NULL) {
				file_count++;
			}
		}
		closedir(d);
	}
	BRP_LOOP_END;

	/*
	 * If we did not find any directories, return ENOENT
	 */
	if (found_existing == 0) {
		return -ENOENT;
	}

	/*
	 * Now that we have a count of the number of items, we can malloc that much
	 * space.
	 */
	char **files = malloc(file_count * sizeof(char*));

	/*
	 * Populate files[] with the contents of the requested directory
	 */
	int file_i = 0;
	BRP_LOOP_START;
	d = opendir(out_path);
	if (d) {
		if (items[i].oper == BRP_BRC_WRAP) {
			while ((dir = readdir(d)) != NULL) {
				strncpy(tmp_path, out_path, PATH_MAX);
				strncat(tmp_path, "/", PATH_MAX - strlen(out_path));
				strncat(tmp_path, dir->d_name, PATH_MAX - strlen(out_path));
				if (resolve_symlink(tmp_path) == 0) {
					files[file_i] = malloc((strlen(dir->d_name)+1) * sizeof(char));
					strcpy(files[file_i], dir->d_name);
					file_i++;
				}
			}
		} else {
			while ((dir = readdir(d)) != NULL) {
				files[file_i] = malloc((strlen(dir->d_name)+1) * sizeof(char));
				strcpy(files[file_i], dir->d_name);
				file_i++;
			}
		}
		closedir(d);
	}
	BRP_LOOP_END;

	/*
	 * De-duplicate, filler() the files and free() as needed
	 */
	qsort(files, file_i, sizeof(char*), strcmpwrap);
	if (file_i > 0) {
		filler(buf, files[0], NULL, 0);
	}
	for (i=1; i<file_i; i++) {
		if (strcmp(files[i], files[i-1]) != 0) {
			filler(buf, files[i], NULL, 0);
		}
	}
	/* free */
	for (i=0; i<file_i; i++) {
		free(files[i]);
	}
	free(files);

	return 0;
}

/*
 * This is what is used to determine where a symlink is pointing.  We cannot
 * directly return the output as the symlinks will be broken; however, we can
 * easily direct them into the appropriate explicit path.
 *
 * resolve_symlink() will do most of the work here once we've successfully
 * found a symlink.
 */
static int brp_readlink(const char *in_path, char *buf, size_t bufsize)
{
	SET_CALLER_UID();

	int i, n, c, len_remaining;
	char out_path[PATH_MAX+1];
	const char* base_path;
	struct stat tmp_stbuf;
	BRP_LOOP_START;
	/* check if file is a symlink */
	if (lstat(out_path, &tmp_stbuf) == 0 && S_ISLNK(tmp_stbuf.st_mode)) {
		strncpy(buf, out_path, bufsize);
		return resolve_symlink(buf);
	}
	BRP_LOOP_END;
	return -1;
}

/*
 * open() is necessary before a file can be read(), write(), etc.  I suspect
 * the kernel and/or fuse allocate resources when this is called.  However,
 * from the point of view of someone writing a fuse function, the main purpose
 * this serves is performance checks.
 */

static int brp_open(const char *in_path, struct fuse_file_info *fi)
{
	SET_CALLER_UID();

	/*
	 * /reparse_config is the only file which could possibly be written to.
	 * Get that out of the way here so we can assume everything else later is
	 * only being read.
	 */
	if (strcmp(in_path, "/reparse_config") == 0) {
		struct fuse_context *context = fuse_get_context();
		if (context->uid != 0) {
			/* Non-root users cannot do anything with this file. */
			return -EACCES;
		} else {
			return 0;
		}
	}

	/*
	 * Everything else in this filesystem is read-only.  If the user requested
	 * anything else, return EACCES.
	 *
	 * Note the way permissions are stored in fi->flags do *not* have a single
	 * bit flag for read or write, hence the unusual looking check below.  See
	 * `man 2 open`.
	 */
	if ((fi->flags & 3) != O_RDONLY ) {
		return -EACCES;
	}

	/*
	 * Loop over the various out_path possibilities and check if any can be
	 * read.  If so, return ok.  brc-wrap items, since their permissions are
	 * based on the resolved value.
	 */
	int i, n, c, len_remaining;
	char out_path[PATH_MAX+1];
	const char* base_path;
	BRP_LOOP_START;
	if (resolve_symlink(out_path) == 0) {
		if (items[i].oper == BRP_BRC_WRAP && base_path[0] != '\0') {
			if (resolve_symlink(out_path) == 0 && access(out_path, F_OK) == 0) {
				return 0;
			}
		} else {
			if (access(out_path, R_OK) >= 0) {
				return 0;
			}
		}
	}
	BRP_LOOP_END;

	return -ENOENT;
}

/*
 * This is called, unsurprisingly, when a user wishes to read a file.
 */
static int brp_read(const char *in_path, char *buf, size_t size, off_t offset, struct fuse_file_info *fi)
{
	SET_CALLER_UID();

	/*
	 * /reparse_config is populated by the config_contents() function.
	 */
	if (strcmp(in_path, "/reparse_config") == 0) {
		struct fuse_context *context = fuse_get_context();
		if (context->uid != 0) {
			/* Non-root users cannot do anything with this file. */
			return -EACCES;
		}
		char *config_str = config_contents();
		strncpy(buf, config_str, size);
		free(config_str);
		return(strlen(buf));
	}

	int i, n, c, len_remaining;
	char out_path[PATH_MAX+1];
	const char* base_path;
	FILE *fp;
	char line[PATH_MAX+1];
	BRP_LOOP_START;

	if (resolve_symlink(out_path) == 0) {
		if (items[i].oper == BRP_BRC_WRAP && base_path[0] != '\0') {
			/*
			 * Accessing brc-wrap item.  Instead of returning the file, return
			 * a shell script that wraps the command in brc.
			 *
			 * TODO: This could probably be written much cleaner with an sprintf()
			 */
			if (access(out_path, F_OK) == 0) {
				len_remaining = size;
				strncpy(buf, "#!/bin/sh\nexec brc ", size);
				len_remaining -= strlen("#!/bin/sh\nexec brc");
				strncat(buf, clients[c], len_remaining);
				len_remaining -= client_lens[c];
				strncat(buf, " ", len_remaining);
				len_remaining -= strlen(" ");
				strncat(buf, items[i].ins[n], len_remaining);
				len_remaining -= items[i].in_lens[n];
				strncat(buf, base_path, len_remaining);
				len_remaining -= strlen(base_path);
				strncat(buf, " \"$@\"\n", len_remaining);
				/*
				 * TODO: can we replace "strlen(buf)" with "size - len_remaining" ?
				 */
				return strlen(buf);
			}
		} else if (items[i].oper == BRP_EXEC_FILTER && base_path[0] != '\0') {
			fp = fopen(out_path, "r");
			/*
			 * Accessing a exec-filter item.  Filter any line that starts with
			 * "Exec=" to wrap the value in brc to the appropriate client.  For
			 * example, change:
			 *     Exec=/usr/bin/vim
			 * To
			 *     Exec=/bedrock/bin/brc wheezy /usr/bin/vim
			 * Also, change "TryExec= lines to use the explicit path.  For
			 * example, change
			 *     TryExec=/usr/bin/vim
			 * to
			 *     TryExec=/bedrock/clients/wheezy/usr/bin/vim
			 *
			 * See here for what these keys we are changing do:
			 * http://standards.freedesktop.org/desktop-entry-spec/latest/ar01s05.html
			 */
			if (fp != NULL) {
				len_remaining = size;
				buf[0] = '\0';
				while (fgets(line, PATH_MAX, fp) != NULL) {
					if (strncmp(line, "Exec=", strlen("Exec=")) == 0) {
						/* include "brc" */
						strncat(buf, "Exec=/bedrock/bin/brc ", len_remaining);
						len_remaining -= strlen("Exec=/bedrock/bin/brc ");
						strncat(buf, clients[c], client_lens[c]);
						len_remaining -= client_lens[c];
						strncat(buf, " ", 1);
						len_remaining -= 1;
						strncat(buf, line + strlen("Exec="), len_remaining);
						len_remaining -= strlen(line + strlen("Exec="));
					} else if (strncmp(line, "TryExec=/", strlen("TryExec=/")) == 0) {
						/* change path to explicit path */
						strncat(buf, "TryExec=/bedrock/clients/", len_remaining);
						len_remaining -= strlen("/bedrock/clients/");
						strncat(buf, clients[c], len_remaining);
						len_remaining -= client_lens[c];
						strncat(buf, line+8, len_remaining);
						len_remaining -= strlen(line+8);
					} else {
						strncat(buf, line, len_remaining);
						len_remaining -= strlen(line);
					}
				}
				fclose(fp);
				return strlen(buf);
			}
		} else {
			int fd = open(out_path, O_RDONLY);
			if (fd >= 0) {
				int ret = pread(fd, buf, size, offset);
				close(fd);
				if (ret >= 0) {
					return ret;
				}
			}
		}
	}
	BRP_LOOP_END;

	return -ENOENT;
}

/*
 * This is typically used to write to a file, just as you'd expect from the
 * name.  However, for this filesystem, we only use it as an indication to
 * reload the configuration and client information.
 */
static int brp_write(const char *in_path, const char *buf, size_t size, off_t offset, struct fuse_file_info *fi)
{
	SET_CALLER_UID();

	if (write_attempt(in_path) == 0) {
		return strlen(buf);
	}

	return -EACCES;
}

/*
 * This is typically used to indicate a file should be shortened.  Like
 * write(), it is only being used here as an indication to reload the
 * configuration and client information.
 */
static int brp_truncate(const char *in_path, off_t length)
{
	SET_CALLER_UID();

	if (write_attempt(in_path) == 0) {
		return 0;
	}

	return -EACCES;
}

static struct fuse_operations brp_oper = {
	.getattr  = brp_getattr,
	.readdir  = brp_readdir,
	.readlink = brp_readlink,
	.open     = brp_open,
	.read     = brp_read,
	.write    = brp_write,
	.truncate = brp_truncate,
};

int main(int argc, char* argv[])
{
	/*
	 * Sanity checks
	 */

	/*
	 * Ensure we are running as root so that any requests by root to this
	 * filesystem can be provided.
	 */
	if(getuid() != 0){
		fprintf(stderr, "ERROR: not running as root, aborting.\n");
		return 1;
	}

	 /*
	  * The mount point should be provided.
	  */
	if(argc < 2) {
		fprintf(stderr, "ERROR: Insufficient arguments.\n");
		return 1;
	}

	/*
	 * The mount point should exist.
	 */
	struct stat test_is_dir_stat;
	if (stat(argv[1], &test_is_dir_stat) != 0 || S_ISDIR(test_is_dir_stat.st_mode) == 0) {
		fprintf(stderr, "ERROR: Could not find directory \"%s\"\n", argv[1]);
		return 1;
	}

	/*
	 * Default stat() values for certain output files.  Some of these may be
	 * called quite a lot in quick succession; better to calculate them here
	 * and memcpy() them over than calculate on-the-fly.
	 */

	memset(&root_stat, 0, sizeof(struct stat));
	root_stat.st_ctime = root_stat.st_mtime = root_stat.st_atime = time(NULL);
	root_stat.st_mode = S_IFDIR | 0555;

	memcpy(&reparse_stat, &root_stat, sizeof(struct stat));
	reparse_stat.st_mode = S_IFREG | 0600;

	/*
	 * Generate arguments for fuse:
	 * - start with no arguments
	 * - add argv[0] (which I think is just ignored)
	 * - add mount point
	 * - disable multithreading, as with the UID/GID switching it will result
	 *   in abusable race conditions.
	 * - add argument to:
	 *   - let all users access filesystem
	 *   - allow mounting over non-empty directories
	 */
	struct fuse_args args = FUSE_ARGS_INIT(0, NULL);
	fuse_opt_add_arg(&args, argv[0]);
	fuse_opt_add_arg(&args, argv[1]);
	fuse_opt_add_arg(&args, "-s");
	fuse_opt_add_arg(&args, "-oallow_other,nonempty");
	/* stay in foreground, useful for debugging */
	fuse_opt_add_arg(&args, "-f");

	/* initial config parse */
	parse_config();

	return fuse_main(args.argc, args.argv, &brp_oper, NULL);
}
