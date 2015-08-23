/*
 * brp.c
 *
 *      This program is free software; you can redistribute it and/or
 *      modify it under the terms of the GNU General Public License
 *      version 2 as published by the Free Software Foundation.
 *
 * Copyright (c) 2014-2015 Daniel Thau <danthau@bedrocklinux.org>
 *
 * This program mounts a filesystem which will provide read-only copies of
 * files at configured output locations dependent on various possible input
 * locations.  For example, if "<mount>/bin/vlc" is requested, this program can
 * search through a configured list of possible locations for "vlc" and provide
 * the first match, if any.
 */

#define FUSE_USE_VERSION 29
#include <fuse.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <libbedrock.h>

#define CONFIG "/bedrock/etc/brp.conf"
#define CONFIG_LEN strlen(CONFIG)
#define STRATA_ROOT "/bedrock/strata/"
#define STRATA_ROOT_LEN strlen(STRATA_ROOT)

enum filter {
	FILTER_PASS,     /* pass file through unaltered */
	FILTER_BRC_WRAP, /* return a script that wraps executable with brc */
	FILTER_EXEC,     /* wrap [Try]Exec[Start|Stop|Reload]= ini-style key-value pairs with brc */
// 	FILTER_FONT,     /* combines fonts.dir and fonts.alias files for Xorg fonts */
};

enum file_type {
	FILE_TYPE_NORMAL,
	FILE_TYPE_DIRECTORY,
};

/*
 * Possible input source for a file.
 */
struct in_item {
	/* full path including STRATA_ROOT, e.g. "/bedrock/strata/gentoo/bin/ls" */
	char *full_path;
	size_t full_path_len;
	/* stratum-specific component of path, e.g. "/bin/ls" */
	char *stratum_path;
	size_t stratum_path_len;
	/* stratum which provides file, e.g. 'gentoo" */
	char *stratum;
	size_t stratum_len;
};

/*
 * Possible output file or directory, if a matching in_item is found.
 */
struct out_item {
	/* incoming path stratum may request for file, e.g. <mount-point>"/bin/ls" */
	char *path;
	size_t path_len;
	/* what kind of filter to apply to outgoing files */
	int filter;
	/* is this a directory that can contain multiple files, or just a single file */
	int file_type;
	/* array of possible in_items for the output item */
	struct in_item *in_items;
	size_t in_item_count;
};

/*
 * The functions corresponding to the various filesystem calls have
 * FUSE-defined arguments which are not easily changed.  Easiest/cleanest way to pass
 * additional information to each function is via globals.
 */

/* output file paths */
struct out_item *out_items;
size_t out_item_count = 0;

/* default stat information so we don't have to recalculate at runtime. */
struct stat parent_stat;
struct stat reparse_stat;

/*
 * ============================================================================
 * config management
 * ============================================================================
 */

void free_config()
{
	if (out_item_count <= 0) {
		return;
	}

	int i, j;
	for (i = 0; i < out_item_count; i++) {
		for (j = 0; j < out_items[i].in_item_count; j++) {
			free(out_items[i].in_items[j].full_path);
			free(out_items[i].in_items[j].stratum_path);
			free(out_items[i].in_items[j].stratum);
		}
		free(out_items[i].in_items);
		free(out_items[i].path);
	}
	free(out_items);
	out_item_count = 0;
}

void parse_config()
{
	/*
	 * Free memory associated with previous config parsing
	 */
	free_config();

	/*
	 * Ensure we're using a root-modifiable-only configuration file, just in case.
	 */
	if (!check_config_secure(CONFIG)) {
		fprintf(stderr, "brp: config file at "CONFIG" is not secure, refusing to continue.\n");
		exit(1);
	}

	/*
	 * Pre-parse config with awk to simplify C parsing code.
	 */

	FILE* fp = popen(
			"/bedrock/libexec/busybox awk '\n"
			"BEGIN {\n"
			"	FS=\"[=, ]\\+\"\n"
			"\n"
			"	# get enabled strata\n"
			"	cmd=\"/bedrock/bin/bri -l\"\n"
			"	while (cmd | getline) {\n"
			"		existing_strata[$0] = $0\n"
			"	}\n"
			"	close(cmd)\n"
			"}\n"
			"\n"
			"/^\\s*#/ || /^\\s*;/ || /^\\s*$/ {\n"
			"	# empty line or comment, skip\n"
			"	next\n"
			"}\n"
			"\n"
			"length($0) > max_line_len {\n"
			"	max_line_len = length($0)\n"
			"}\n"
			"\n"
			"/^\\s*\\[[^]]*\\]\\s*$/ {\n"
			"	# section header\n"
			"	section = substr($1, 2, length($1)-2)\n"
			"	next\n"
			"}\n"
			"\n"
			"section == \"stratum-order\" {\n"
			"	if ($0 in existing_strata && !($0 in strata)) {\n"
			"		strata_ordered[stratum_count++] = $0\n"
			"		strata[$0] = $0\n"
			"	}\n"
			"	next\n"
			"}\n"
			"\n"
			"section == \"pass\" || section == \"brc-wrap\" || section == \"exec-filter\" {\n"
			"	item_count+=0; # ensure is a integer, not a string\n"
			"	if (substr($1, length($1)) != \"/\") {\n"
			"		items[item_count\".path\"] = $1\n"
			"		items[item_count\".type\"] = \"normal\"\n"
			"	} else {\n"
			"		items[item_count\".path\"] = substr($1, 1, length($1)-1)\n"
			"		items[item_count\".type\"] = \"directory\"\n"
			"	}\n"
			"\n"
			"	items[item_count\".filter\"] = section\n"
			"\n"
			"	items[item_count\".in_count\"] = NF - 1\n"
			"	\n"
			"	for (i=2; i <= NF; i++) {\n"
			"		if ( index($i, \":\") == 0) {\n"
			"			items[item_count\".in.\"(i-2)\".stratum\"] = \"\"\n"
			"			items[item_count\".in.\"(i-2)\".path\"] = $i\n"
			"		} else {\n"
			"			items[item_count\".in.\"(i-2)\".stratum\"] = substr($i, 0, index($i, \":\")-1)\n"
			"			items[item_count\".in.\"(i-2)\".path\"] = substr($i, index($i, \":\")+1)\n"
			"		}\n"
			"	}\n"
			"\n"
			"	item_count++;\n"
			"}\n"
			"\n"
			"END {\n"
			"	for (stratum in existing_strata) {\n"
			"		if (!(stratum in strata)) {\n"
			"			strata_ordered[stratum_count++] = stratum\n"
			"		}\n"
			"	}\n"
			"\n"
			"	print max_line_len\n"
			"	print item_count\n"
			"\n"
			"	for (item_i = 0; item_i < item_count; item_i++) {\n"
			"		print items[item_i\".path\"]\n"
			"		print items[item_i\".type\"]\n"
			"		print items[item_i\".filter\"]\n"
			"		in_count = 0\n"
			"		for (in_i = 0; in_i < items[item_i\".in_count\"]; in_i++) {\n"
			"			if (items[item_i\".in.\"in_i\".stratum\"] != \"\") {\n"
			"				in_count++\n"
			"			} else {\n"
			"				in_count+=stratum_count\n"
			"			}\n"
			"		}\n"
			"		print in_count\n"
			"		for (in_i = 0; in_i < items[item_i\".in_count\"]; in_i++) {\n"
			"			if (items[item_i\".in.\"in_i\".stratum\"] != \"\") {\n"
			"				print items[item_i\".in.\"in_i\".stratum\"]\n"
			"				print items[item_i\".in.\"in_i\".path\"]\n"
			"			}\n"
			"		}\n"
			"		for (stratum_i = 0; stratum_i < stratum_count; stratum_i++) {\n"
			"			for (in_i = 0; in_i < items[item_i\".in_count\"]; in_i++) {\n"
			"				if (items[item_i\".in.\"in_i\".stratum\"] == \"\") {\n"
			"					print strata_ordered[stratum_i]\n"
			"					print items[item_i\".in.\"in_i\".path\"]\n"
			"				}\n"
			"			}\n"
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

	/* get items */
	fgets(line, maxlinelen, fp);
	sscanf(line, "%ld", &out_item_count);

	out_items = malloc(out_item_count * sizeof(struct out_item));
	int i, j;
	for (i=0; i < out_item_count; i++) {
		/* get path */
		fgets(line, maxlinelen, fp);
		line[strlen(line)-1] = '\0'; /* strip newline */
		out_items[i].path = malloc((strlen(line)+1) * sizeof(char));
		strcpy(out_items[i].path, line);
		out_items[i].path_len = strlen(line);

		/* get type */
		fgets(line, maxlinelen, fp);
		line[strlen(line)-1] = '\0'; /* strip newline */
		if (strcmp(line, "normal") == 0) {
			out_items[i].file_type = FILE_TYPE_NORMAL;
		} else if (strcmp(line, "directory") == 0) {
			out_items[i].file_type = FILE_TYPE_DIRECTORY;
		} else {
			fprintf(stderr, "Failed to parse config\n");
			exit(1);
		}

		/* get filter */
		fgets(line, maxlinelen, fp);
		line[strlen(line)-1] = '\0'; /* strip newline */
		if (strcmp(line, "pass") == 0) {
			out_items[i].filter = FILTER_PASS;
		} else if (strcmp(line, "brc-wrap") == 0) {
			out_items[i].filter = FILTER_BRC_WRAP;
		} else if (strcmp(line, "exec-filter") == 0) {
			out_items[i].filter = FILTER_EXEC;
		} else {
			fprintf(stderr, "Failed to parse config\n");
			exit(1);
		}

		/* get input items */
		fgets(line, maxlinelen, fp);
		sscanf(line, "%ld", &out_items[i].in_item_count);
		out_items[i].in_items = malloc(out_items[i].in_item_count * sizeof(struct in_item));
		for (j=0; j < out_items[i].in_item_count; j++) {
			/* get stratum */
			fgets(line, maxlinelen, fp);
			line[strlen(line)-1] = '\0'; /* strip newline */
			out_items[i].in_items[j].stratum = malloc((strlen(line)+1) * sizeof(char));
			strcpy(out_items[i].in_items[j].stratum, line);
			out_items[i].in_items[j].stratum_len = strlen(line);
			
			/* get stratum path */
			fgets(line, maxlinelen, fp);
			line[strlen(line)-1] = '\0'; /* strip newline */
			if (line[strlen(line)-1] == '/') {
				line[strlen(line)-1] = '\0'; /* strip trailing slash */
			}
			out_items[i].in_items[j].stratum_path = malloc((strlen(line)+1) * sizeof(char));
			strcpy(out_items[i].in_items[j].stratum_path, line);
			out_items[i].in_items[j].stratum_path_len = strlen(line);

			/* calculate full path */
			out_items[i].in_items[j].full_path = malloc((
						STRATA_ROOT_LEN +
						out_items[i].in_items[j].stratum_len +
						out_items[i].in_items[j].stratum_path_len + 1) * sizeof(char));
			strcpy(out_items[i].in_items[j].full_path, STRATA_ROOT);
			strcat(out_items[i].in_items[j].full_path, out_items[i].in_items[j].stratum);
			strcat(out_items[i].in_items[j].full_path, out_items[i].in_items[j].stratum_path);
		}
	}

	free(line);
	pclose(fp);
}

/*
 * Return a pointer to a string describing the current configuration.  Up to
 * the calling program to free() it.  This is used when /reparse_config is read
 * to show the current configuration.  It is useful for debugging.
 */
char* config_contents()
{
	int i, j;

	size_t len = 0;
	for (i = 0; i < out_item_count; i++) {
		len += strlen("path = ");
		len += strlen(out_items[i].path);
		len += strlen("\n");

		len += strlen("type = ");
		switch (out_items[i].file_type) {
		case FILE_TYPE_NORMAL:
			len += strlen("normal");
			break;
		case FILE_TYPE_DIRECTORY:
			len += strlen("directory");
			break;
		}
		len += strlen("\n");

		len += strlen("filter = ");
		switch (out_items[i].filter) {
		case FILTER_PASS:
			len += strlen("pass");
			break;
		case FILTER_BRC_WRAP:
			len += strlen("brc-wrap");
			break;
		case FILTER_EXEC:
			len += strlen("exec");
			break;
		}
		len += strlen("\n");

		for (j = 0; j < out_items[i].in_item_count; j++) {
			len += strlen("  stratum = ");
			len += strlen(out_items[i].in_items[j].stratum);
			len += strlen("\n");
			len += strlen("  stratum_path = ");
			len += strlen(out_items[i].in_items[j].stratum_path);
			len += strlen("\n");
			len += strlen("  full_path = ");
			len += strlen(out_items[i].in_items[j].full_path);
			len += strlen("\n");
		}
	}
	len += strlen("\n");

	char *config_str = malloc(len * sizeof(char*));
	if (!config_str) {
		return NULL;
	}
	config_str[0] = '\0';

	for (i = 0; i < out_item_count; i++) {
		strcat(config_str, "path = ");
		strcat(config_str, out_items[i].path);
		strcat(config_str, "\n");

		strcat(config_str, "type = ");
		switch (out_items[i].file_type) {
		case FILE_TYPE_NORMAL:
			strcat(config_str, "normal");
			break;
		case FILE_TYPE_DIRECTORY:
			strcat(config_str, "directory");
			break;
		}
		strcat(config_str, "\n");

		strcat(config_str, "filter = ");
		switch (out_items[i].filter) {
		case FILTER_PASS:
			strcat(config_str, "pass");
			break;
		case FILTER_BRC_WRAP:
			strcat(config_str, "brc-wrap");
			break;
		case FILTER_EXEC:
			strcat(config_str, "exec");
			break;
		}
		strcat(config_str, "\n");

		for (j = 0; j < out_items[i].in_item_count; j++) {
			strcat(config_str, "  stratum = ");
			strcat(config_str, out_items[i].in_items[j].stratum);
			strcat(config_str, "\n");
			strcat(config_str, "  stratum_path = ");
			strcat(config_str, out_items[i].in_items[j].stratum_path);
			strcat(config_str, "\n");
			strcat(config_str, "  full_path = ");
			strcat(config_str, out_items[i].in_items[j].full_path);
			strcat(config_str, "\n");
		}
	}
	len += strlen("\n");

	return config_str;
}

/*
 * ============================================================================
 * str_vec
 * ============================================================================
 *
 * Growable array of strings.
 */

struct str_vec {
	char** array;
	size_t len;
	size_t allocated;
};

int str_vec_new(struct str_vec *v)
{
	const int DEFAULT_ALLOC_SIZE = 1024;
	v->allocated = DEFAULT_ALLOC_SIZE;
	v->len = 0;
	v->array = malloc(v->allocated * sizeof(char*));
	return !!v->array;
}

void str_vec_free(struct str_vec *v)
{
	size_t i;
	for (i = 0; i < v->len; i++) {
		free(v->array[i]);
	}
	free(v->array);
	v->array = NULL;
	v->len = 0;
	v->allocated = 0;
	/*
	 * Purposefully cannot append anymore (0 * 2 = 0).  have to call
	 * str_vec_new() again to continue to use.
	 */
}

int str_vec_append(struct str_vec *v, char *str)
{
	/* cannot append on free()'d str_vec */
	if (v->allocated == 0) {
		return 0;
	}

	size_t str_len = strlen(str);
	v->array[v->len] = malloc((str_len+1) * sizeof(char));
	if (!v->array[v->len]) {
		return 0;
	}
	strcpy(v->array[v->len], str);

	v->len++;
	if (v->len > v->allocated) {
		v->allocated *= 2; /* TODO: research scaling 1.5 vs 2 */
		v->array = realloc(v->array, v->allocated * sizeof(char*));
		if (!v->array) {
			return 0;
		}
	}
	return 1;
}

int str_vec_concat(struct str_vec *v1, struct str_vec *v2)
{
	size_t i;
	for (i = 0; i < v2->len; i++) {
		if (str_vec_append(v1, v2->array[i]) < 0) {
			return 0;
		}
	}
	return 1;
}

int qsort_strcmp_wrap(const void *a, const void *b)
{
	return strcmp(*((char**) a), *((char**) b));
}

void str_vec_sort(struct str_vec *v) {
	if (v->len < 2) {
		return;
	}
	qsort(v->array, v->len, sizeof(v->array[0]), qsort_strcmp_wrap);
	return;
}

/*
 * TODO: Just empty's repeated items, does not remove.  Expects calling code to
 * check for empty strings.  That's ugly, see if we can cleanly fix.
 */
int str_vec_uniq(struct str_vec *v)
{
	if (v->len < 2) {
		return 0;
	}

	str_vec_sort(v);

	ssize_t i;
	for (i = 1; i < v->len; i++) {
		if (strcmp(v->array[i], v->array[i-1]) == 0) {
			v->array[i-1][0] = '\0';
		}
	}

	return 0;
}

/*
 * ============================================================================
 * miscellaneous/support
 * ============================================================================
 */

/*
 * Writing to this filesystem is only used as a way to signal that the
 * configuration and should be reparsed.  Thus, it does not matter which
 * writing function is called - they should all act the same.  They all call
 * this.
 */
int write_attempt(const char* path)
{
	/*
	 * The *only* thing writable is the /reparse_config, and only by root.
	 * When it is written to, it will cause brp to reparse its configuration.
	 */
	if (strcmp(path, "/reparse_config") == 0) {
		struct fuse_context *context = fuse_get_context();
		if (context->uid != 0) {
			/* Non-root users cannot do anything with this file. */
			return -EACCES;
		} else {
			parse_config();
			return 0;
		}
	} else {
		return -EACCES;
	}
}

/*
 * Determines the real path to a file in a strata, treating absolute symlinks
 * as symlinks relative to the strata's root.  Returns >=0 on success, <0 on
 * failure.  If there is no resulting file/directory it is considered an error
 * (unlike, for example, readlink(2)).
 *
 * All incoming paths must be in STRATA_ROOT/<stratum>/.
 *
 * This is used over something like realpath() due to the need to have absolute
 * symlinks start at the symlink's stratum's root.  e.g. if a symlink at
 * "/bedrock/strata/foo/bar" symlinks to "/qux" that should be treated as
 * "/bedrock/strata/foo/qux".
 */
int brp_realpath(char *in_path, char *out_path, size_t bufsize)
{
	if (strlen(in_path) >= bufsize) {
		return -ENAMETOOLONG;
	}

	char *slash;
	const int LOOP_MAX = 20;
	int end = 0;
	int loop = 0;
	size_t offset;
	ssize_t readlink_len;
	struct stat stbuf;

	char current_path[bufsize];
	char link_path[bufsize];
	char path_fragment[bufsize];
	char stratum_prefix[bufsize];

	/*
	 * Ensure incoming path is in stratum_prefix/<stratum>/, get stratum
	 * prefix.
	 */
	if (strncmp(in_path, STRATA_ROOT, STRATA_ROOT_LEN) != 0) {
		return -EINVAL;
	}
	slash = in_path + STRATA_ROOT_LEN + 1;
	while (*slash != '/') {
		slash++;
	}
	strncpy(stratum_prefix, in_path, slash - in_path + 1);
	stratum_prefix[slash - in_path + 1] = '\0';
	size_t stratum_prefix_len = strlen(stratum_prefix);
	offset = stratum_prefix_len+1;

	strcpy(current_path, in_path);

	/*
	 * Loop over every directory in a given file path, e.g. in
	 * "/foo/bar/baz/" loop over "/foo" then "/foo/bar" then
	 * "/foo/bar/baz", starting with the stratum_prefix.  If any directory
	 * is found to be a symlink, resolve symlink then start over.
	 */
	while (1) {
		/* find next file/directory in file path */
		while (current_path[offset] != '/' && current_path[offset] != '\0') {
			offset++;
		}
		/* on final item in file path, the file itself */
		if (current_path[offset] == '\0') {
			end = 1;
		}
		/* starting / */
		if (offset == 0 && current_path[offset] == '/') {
			offset++;
			continue;
		}
		/* would overflow */
		if (offset >= bufsize) {
			return -ENAMETOOLONG;
		}

		strncpy(path_fragment, current_path, offset);
		path_fragment[offset] = '\0';

		if (lstat(path_fragment, &stbuf) != 0) {
			return -ENOENT;
		}
		if (!S_ISLNK(stbuf.st_mode) && !end) {
			offset++;
			continue;
		}
		if (!S_ISLNK(stbuf.st_mode) && end) {
			strcpy(out_path, current_path);
			return 1;
		}
		if (S_ISLNK(stbuf.st_mode)) {
			if ((readlink_len = readlink(path_fragment, link_path, bufsize)) < 0) {
				return -errno;
			}
			link_path[readlink_len] = '\0';
			if (link_path[0] == '/') {
				/* absolute symlink */
				strcpy(out_path, stratum_prefix);
				strcat(out_path, link_path+1);
				strcat(out_path, current_path + offset);
			} else {
				/* relative symlink */
				if ( (slash = strrchr(path_fragment, '/')) ) {
					strncpy(out_path, path_fragment, slash - path_fragment + 1);
					out_path[slash - path_fragment + 1] = '\0';
				} else {
					strcpy(out_path, "./");
				}
				strcat(out_path, link_path);
				strcat(out_path, current_path + offset);
			}
			offset = stratum_prefix_len+1;
			end = 0;
			strcpy(current_path, out_path);
			if ((loop++) >= LOOP_MAX) {
				return -ELOOP;
			}
		}
	}
}

/*
 * Like stat(2), except resolves symlinks with brp-specific resolve_symlink()
 * logic.
 */
int brp_stat(char *path, struct stat *stbuf)
{
	char out_path[PATH_MAX+1];
	int ret;
	if ((ret = brp_realpath(path, out_path, PATH_MAX+1)) < 0) {
		/* could not resolve symlink */
		return ret;
	} else if (!stbuf) {
		/* no stbuf provided to populate */
		return 0;
	} else {
		return lstat(out_path, stbuf);
	}
}

/*
 * Given an input path, finds the corresponding content to output (if any) and
 * populates various related fields (e.g. stat info) accordingly.
 */
int corresponding(char *in_path,
		char* out_path,
		size_t out_path_size,
		struct stat *stbuf,
		struct out_item **arg_out_item,
		struct in_item **arg_in_item,
		char **tail)
{
	/* handle root specially */
	if (in_path[0] == '/' && in_path[1] == '\0') {
		memcpy(stbuf, &parent_stat, sizeof(parent_stat));
		return 0;
	}

	size_t i, j;
	size_t in_path_len = strlen(in_path);
	char tmp_path[out_path_size+1];

	/* check for a match on something contained in one of the configured
	 * directories */
	for (i = 0; i < out_item_count; i++) {
		if (strncmp(in_path, out_items[i].path, out_items[i].path_len) == 0 &&
				in_path[out_items[i].path_len] == '/' &&
				out_items[i].file_type == FILE_TYPE_DIRECTORY) {
			for (j = 0; j < out_items[i].in_item_count; j++) {
				strncpy(tmp_path, out_items[i].in_items[j].full_path, out_path_size);
				strncat(tmp_path, in_path + out_items[i].path_len, out_path_size - out_items[i].in_items[j].full_path_len);
				if (strlen(tmp_path) == out_path_size) {
					/* would have buffer overflowed, treat as bad value */
					continue;
				}
				if (brp_realpath(tmp_path, out_path, out_path_size) >= 0 && lstat(out_path, stbuf) >= 0) {
					*arg_out_item = &out_items[i];
					*arg_in_item = &out_items[i].in_items[j];
					*tail = in_path + out_items[i].path_len;
					return 0;
				}
			}
		}
	}

	/*
	 * Check for a match directly on one of the configured items.
	 */
	for (i = 0; i < out_item_count; i++) {
		if (strncmp(out_items[i].path, in_path, in_path_len) == 0 &&
				(out_items[i].path[in_path_len] == '\0')) {
			for (j = 0; j < out_items[i].in_item_count; j++) {
				if (brp_realpath(out_items[i].in_items[j].full_path, out_path, out_path_size) >=0) {
					if (out_items[i].file_type == FILE_TYPE_DIRECTORY) {
						memcpy(stbuf, &parent_stat, sizeof(parent_stat));
					} else {
						lstat(out_path, stbuf);
					}
					*arg_out_item = &out_items[i];
					*arg_in_item = &out_items[i].in_items[j];
					*tail = "";
					return 0;
				}
			}
		}
	}

	/*
	 * Check for a match on a virtual parent directory of a configured
	 * item.
	 */
	for (i = 0; i < out_item_count; i++) {
		if (strncmp(out_items[i].path, in_path, in_path_len) == 0 &&
				(out_items[i].path[in_path_len] == '/')) {
			for (j = 0; j < out_items[i].in_item_count; j++) {
				if (brp_realpath(out_items[i].in_items[j].full_path, out_path, out_path_size) >=0 &&
						lstat(out_path, stbuf) >= 0) {
					memcpy(stbuf, &parent_stat, sizeof(parent_stat));
					*arg_out_item = &out_items[i];
					*arg_in_item = &out_items[i].in_items[j];
					*tail = "";
					return 0;
				}
			}
		}
	}

	return -ENOENT;
}

/*
 * Apply relevant filter to getattr output.
 */
void stat_filter(struct stat *stbuf,
		const char const *in_path,
		int filter,
		struct in_item *item,
		const char *tail)
{
	/*
	 * Remove an setuid/setgid properties and write properties  The
	 * program we are wrapping could be setuid and owned by something
	 * other than root, in which case this would have been an exploit.
	 * Moreover, no one can write to these.
	 */
	stbuf->st_mode &= ~ (S_ISUID | S_ISGID | S_IWUSR | S_IWGRP | S_IWOTH);

	if (S_ISDIR(stbuf->st_mode)) {
		/* filters below only touch files */
		return;
	}

	FILE *fp;
	char line[PATH_MAX+1];

	switch (filter) {

	case FILTER_PASS:
		break;

	case FILTER_BRC_WRAP:
		stbuf->st_size = strlen("#!/bedrock/libexec/busybox sh\nexec /bedrock/bin/brc ")
						+ item->stratum_len
						+ strlen(" ")
						+ item->stratum_path_len
						+ strlen(tail)
						+ strlen(" \"$@\"\n");
		break;

	case FILTER_EXEC:
		fp = fopen(in_path, "r");
		if (fp != NULL) {
			while (fgets(line, PATH_MAX, fp) != NULL) {
				if (strncmp(line, "Exec=", strlen("Exec=")) == 0 ||
						strncmp(line, "TryExec=", strlen("TryExec=")) == 0 ||
						strncmp(line, "ExecStart=", strlen("ExecStart=")) == 0 ||
						strncmp(line, "ExecStop=", strlen("ExecStop=")) == 0 ||
						strncmp(line, "ExecReload=", strlen("ExecReload=")) == 0) {
					stbuf->st_size += strlen("/bedrock/bin/brc ");
					stbuf->st_size += item->stratum_len;
					stbuf->st_size += strlen(" ");
				}
			}
			fclose(fp);
		}
		break;

	}
}

/*
 * Do read() and apply relevant filter.
 */
int read_filter(const char *in_path,
		int filter,
		struct in_item *item,
		const char *tail,
		char *buf,
		size_t size,
		off_t offset)
{
	char *execs[] = {"TryExec=", "ExecStart=", "ExecStop=", "ExecReload=", "Exec="};
	size_t exec_cnt = sizeof(execs) / sizeof(execs[0]);
	int fd, ret, len_remaining;
	const size_t line_max = PATH_MAX;
	char line[line_max+1];
	FILE *fp;

	switch (filter) {

	case FILTER_PASS:
		if ((fd = open(in_path, O_RDONLY)) >= 0) {
			ret = pread(fd, buf, size, offset);
			close(fd);
			return ret;
		}
		return fd;
		break;

	case FILTER_BRC_WRAP:
		if (access(in_path, F_OK) == 0) {
			len_remaining = size;
			strncpy(buf, "#!/bedrock/libexec/busybox sh\nexec /bedrock/bin/brc ", size);
			len_remaining -= strlen("#!/bedrock/libexec/busybox sh\nexec /bedrock/bin/brc ");
			strncat(buf, item->stratum, len_remaining);
			len_remaining -= item->stratum_len;
			strncat(buf, " ", len_remaining);
			len_remaining -= strlen(" ");
			strncat(buf, item->stratum_path, len_remaining);
			len_remaining -= item->stratum_path_len;
			strncat(buf, tail, len_remaining);
			len_remaining -= strlen(tail);
			strncat(buf, " \"$@\"\n", len_remaining);
			/*
			 * TODO: can we replace "strlen(buf)" with "size - len_remaining" ?
			 */
			return strlen(buf);
		} else {
			return -EPERM;
		}
		break;

	case FILTER_EXEC:
		if (access(in_path, F_OK) == 0) {
			len_remaining = size;
			buf[0] = '\0';
			fp = fopen(in_path, "r");
			while (fgets(line, line_max, fp) != NULL) {
				size_t i;
				int found = 0;
				for (i = 0; i < exec_cnt; i++) {
					if (strncmp(line, execs[i], strlen(execs[i])) == 0) {
						found = 1;
						strncat(buf, execs[i], len_remaining);
						len_remaining -= strlen(execs[i]);
						strncat(buf, "/bedrock/bin/brc ", len_remaining);
						len_remaining -= strlen("/bedrock/bin/brc");
						strncat(buf, item->stratum, len_remaining);
						len_remaining -= item->stratum_len;
						strncat(buf, " ", 1);
						len_remaining -= 1;
						strncat(buf, line + strlen(execs[i]), len_remaining);
						len_remaining -= strlen(line + strlen(execs[i]));
					}
				}
				if (!found) {
					strncat(buf, line, len_remaining);
					len_remaining -= strlen(line);
				}
			}
			fclose(fp);
			return strlen(buf);
		} else {
			return -EPERM;
		}
		break;
	}

	return -ENOENT;
}

/*
 * ============================================================================
 * FUSE functions
 * ============================================================================
 */

/*
 * FUSE calls its equivalent of stat(2) "getattr".  This just gets stat
 * information, e.g. file size and permissions.
 */
static int brp_getattr(const char const *in_path, struct stat *stbuf)
{
	SET_CALLER_UID();

	char out_path[PATH_MAX+1];
	struct out_item *out_item;
	struct in_item *in_item;
	char *tail;
	char *config_str;
	int ret;

	if (in_path[0] == '/' && in_path[1] == '\0') {
		memcpy(stbuf, &parent_stat, sizeof(parent_stat));
		return 0;
	}

	if (strcmp(in_path, "/reparse_config") == 0) {
		memcpy(stbuf, &reparse_stat, sizeof(reparse_stat));
		config_str = config_contents();
		if (config_str) {
			stbuf->st_size = strlen(config_str);
			free(config_str);
			return 0;
		} else {
			return -ENOMEM;
		}
	}

	if ( (ret = corresponding((char*)in_path, out_path, PATH_MAX, stbuf, &out_item, &in_item, &tail)) >= 0) {
		stat_filter(stbuf, out_path, out_item->filter, in_item, tail);
		return 0;
	} else {
		return ret;
	}
}

/*
 * Provides contents of a directory, e.g. as used by `ls`.
 */
static int brp_readdir(const char *in_path, void *buf, fuse_fill_dir_t filler, off_t offset, struct fuse_file_info *fi)
{
	SET_CALLER_UID();

	(void) offset;
	(void) fi;

	const size_t out_path_size = PATH_MAX;
	char out_path[out_path_size+1];
	size_t i, j;
	size_t in_path_len = strlen(in_path);
	/* handle root directory specially */
	if (in_path_len == 1) {
		in_path_len = 0;
	}
	struct stat stbuf;
	int ret_val = -ENOENT;
	char *slash;

	DIR *d;
	struct dirent *dir;

	struct str_vec v;
	str_vec_new(&v);

	for (i = 0; i < out_item_count; i++) {
		/*
		 * Check for contents of one of the configured directories
		 */
		if (strncmp(in_path, out_items[i].path, out_items[i].path_len) == 0 &&
				(in_path[out_items[i].path_len] == '\0' ||
				in_path[out_items[i].path_len] == '/') &&
				out_items[i].file_type == FILE_TYPE_DIRECTORY) {
			for (j = 0; j < out_items[i].in_item_count; j++) {
				strncpy(out_path, out_items[i].in_items[j].full_path, out_path_size);
				strncat(out_path, in_path + out_items[i].path_len, out_path_size - out_items[i].in_items[j].full_path_len);
				if (strlen(out_path) == out_path_size) {
					/* would have buffer overflowed, treat as bad value */
					continue;
				}
				if (brp_stat(out_path, &stbuf) < 0) {
					continue;
				}
				if (S_ISDIR(stbuf.st_mode)) {
					if (! (d = opendir(out_path)) ) {
						continue;
					}
					while ( (dir = readdir(d)) ) {
						str_vec_append(&v, dir->d_name);
					}
					closedir(d);
				} else {
					if (strrchr(out_path, '/')) {
						str_vec_append(&v, strrchr(out_path, '/')+1);
					} else {
						str_vec_append(&v, out_path);
					}
				}
			}
		}
		/*
		 * Check for a match directly on one of the configured items or a virtual parent directory
		 */
		if (strncmp(out_items[i].path, in_path, in_path_len) == 0 &&
				out_items[i].path[in_path_len] == '/') {
			for (j = 0; j < out_items[i].in_item_count; j++) {
				if (brp_stat(out_items[i].in_items[j].full_path, NULL) >= 0) {
					strncpy(out_path, out_items[i].path + in_path_len + 1, out_path_size);
					if (strlen(out_path) == out_path_size) {
						/* would have buffer overflowed, treat as bad value */
						continue;
					}
					if ( (slash = strchr(out_path, '/')) ) {
						*slash = '\0';
					}
					str_vec_append(&v, out_path);
					break;
				}
			}
		}

		/*
		 * Handle reparse_config on root
		 */
		if (in_path[0] == '/' && in_path[1] == '\0') {
			str_vec_append(&v, "reparse_config");
		}
	}

	str_vec_uniq(&v);
	for (i = 0; i < v.len; i++) {
		if (v.array[i][0] != '\0') {
			filler(buf, v.array[i], NULL, 0);
			ret_val = 0;
		}
	}

	str_vec_free(&v);

	return ret_val;
}

/*
 * Check if user has permissions to do something with file. e.g. read or write.
 */
static int brp_open(const char *in_path, struct fuse_file_info *fi)
{
	SET_CALLER_UID();

	char out_path[PATH_MAX+1];
	struct out_item *out_item;
	struct in_item *in_item;
	char *tail;
	int ret;
	struct stat stbuf;

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

	if ( (ret = corresponding((char*)in_path, out_path, PATH_MAX, &stbuf, &out_item, &in_item, &tail)) >= 0) {
		return 0;
	}
	return -ENOENT;
}

/*
 * Read file contents.
 */
static int brp_read(const char *in_path, char *buf, size_t size, off_t offset, struct fuse_file_info *fi)
{
	SET_CALLER_UID();

	char out_path[PATH_MAX+1];
	struct out_item *out_item;
	struct in_item *in_item;
	char *tail;
	char *config_str;
	int ret;
	struct stat stbuf;

	if (strcmp(in_path, "/reparse_config") == 0) {
		config_str = config_contents();
		if (config_str) {
			strncpy(buf, config_str, size);
			free(config_str);
			return strlen(buf);
		} else {
			return -ENOMEM;
		}
	}

	if ( (ret = corresponding((char*) in_path, out_path, PATH_MAX, &stbuf, &out_item, &in_item, &tail)) >= 0) {
		return read_filter(out_path, out_item->filter, in_item, tail, buf, size, offset);
	}

	return ret;
}

/*
 * This is typically used to write to a file, just as you'd expect from the
 * name.  However, for this filesystem, we only use it as an indication to
 * reload the configuration and stratum information.
 */
static int brp_write(const char *in_path, const char *buf, size_t size, off_t offset, struct fuse_file_info *fi)
{
	SET_CALLER_UID();

	if (write_attempt(in_path) == 0) {
		return strlen(buf);
	} else {
		return -EACCES;
	}
}

/*
 * This is typically used to indicate a file should be shortened.  Like
 * write(), it is only being used here as an indication to reload the
 * configuration and stratum information.
 */
static int brp_truncate(const char *in_path, off_t length)
{
	SET_CALLER_UID();

	if (write_attempt(in_path) == 0) {
		return 0;
	} else {
		return -EACCES;
	}
}

static struct fuse_operations brp_oper = {
	.getattr  = brp_getattr,
	.readdir  = brp_readdir,
	.open     = brp_open,
	.read     = brp_read,
	.write    = brp_write,
	.truncate = brp_truncate,
};

/*
 * ============================================================================
 * main
 * ============================================================================
 */

int main(int argc, char *argv[])
{
	(void)argc;
	(void)argv;

	/*
	 * Ensure we are running as root so that any requests by root to this
	 * filesystem can be provided.
	 */
	if (getuid() != 0){
		fprintf(stderr, "ERROR: not running as root, aborting.\n");
		return 1;
	}

	 /*
	  * The mount point should be provided.
	  */
	if (argc < 2) {
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

	memset(&parent_stat, 0, sizeof(struct stat));
	parent_stat.st_ctime = parent_stat.st_mtime = parent_stat.st_atime = time(NULL);
	parent_stat.st_mode = S_IFDIR | 0555;

	memcpy(&reparse_stat, &parent_stat, sizeof(struct stat));
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
