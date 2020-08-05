#pragma once

#include <stddef.h>

/*
 * The directory containing the roots of the various strata.  References to a
 * specific stratum's instance of a file go through this directory.
 */
#define STRATA_ROOT "/bedrock/strata/"
#define STRATA_ROOT_LEN strlen(STRATA_ROOT)

/*
 * Strat runs an executable from given stratum as specified in argument list.
 * Crossfs injects this into various references to executables to ensure the
 * appropriate stratum's instance of the executable is utilized in that
 * context.  This is useful for things such as .desktop files with `Exec=`
 * references to executables.
 */
#define STRAT_PATH "/bedrock/bin/strat"
#define STRAT_PATH_LEN strlen(STRAT_PATH)

/*
 * Bouncer, like strat, redirects to the appropriate stratum's instance of an
 * executable.  It differs from strat in that it determines which executable by
 * looking at its extended filesystem attributes rather than its arguments.
 * This is useful for binaries the user will directly execute, as the user
 * controls the argument list.
 */
#define BOUNCER_PATH "/bedrock/libexec/bouncer"
#define BOUNCER_PATH_LEN strlen(BOUNCER_PATH)

/*
 * The root of the procfs filesystem
 */
#define PROCFS_ROOT "/proc"

/*
 * Surface the associated stratum and file path for files via xattrs.
 */
#define STRATUM_XATTR "user.bedrock.stratum"
#define STRATUM_XATTR_LEN strlen(STRATUM_XATTR)

#define LPATH_XATTR "user.bedrock.localpath"
#define LPATH_XATTR_LEN strlen(LPATH_XATTR)

#define RESTRICT_XATTR "user.bedrock.restrict"
#define RESTRICT_XATTR_LEN strlen(RESTRICT_XATTR)
#define RESTRICT "restrict"
#define RESTRICT_LEN strlen(RESTRICT)

/*
 * Crossfs may be configured to present a file without being explicitly
 * configured to also present its parent directory.  It will dynamically create
 * a virtual directory in these cases.
 *
 * This filesystem is typically mounted in the bedrock stratum then shared with
 * other strata as a global path.  Thus, by definition, anything that isn't
 * crossed to another stratum is owned by the bedrock stratum, including these
 * virtual directories.
 */
#define VIRTUAL_STRATUM "bedrock"
#define VIRTUAL_STRATUM_LEN strlen(VIRTUAL_STRATUM)
/*
 * All crossfs files have an associated file path.  While "/" isn't
 * particularly meaningful here, no other path is obviously better.
 */
#define VIRTUAL_LPATH "/"
#define VIRTUAL_LPATH_LEN strlen(VIRTUAL_LPATH)

/*
 * When merging font directories, these files require extra attention.
 */
#define FONTS_DIR "fonts.dir"
#define FONTS_DIR_LEN strlen(FONTS_DIR)

#define FONTS_ALIAS "fonts.alias"
#define FONTS_ALIAS_LEN strlen(FONTS_ALIAS)

/*
 * The file path used to configure this filesystem.
 */
#define CFG_NAME ".bedrock-config-filesystem"
#define CFG_NAME_LEN strlen(CFG_NAME)

#define CFG_PATH "/.bedrock-config-filesystem"
#define CFG_PATH_LEN strlen(CFG_PATH)

/*
 * Symlink to stratum root, used for local alias.
 */
#define LOCAL_ALIAS_NAME ".local-alias"
#define LOCAL_ALIAS_NAME_LEN strlen(LOCAL_ALIAS_NAME)

#define LOCAL_ALIAS_PATH "/.local-alias"
#define LOCAL_ALIAS_PATH_LEN strlen(LOCAL_ALIAS_PATH)

/*
 * local alias
 */
#define LOCAL "local"
#define LOCAL_LEN strlen(LOCAL)

/*
 * Headers for content written to CFG_NAME
 */
#define CMD_CLEAR "clear"
#define CMD_CLEAR_LEN strlen(CMD_CLEAR)

#define CMD_ADD "add"
#define CMD_ADD_LEN strlen(CMD_ADD)

#define CMD_RM "rm"
#define CMD_RM_LEN strlen(CMD_RM)

/*
 * This filesystem may modify contents as it passes the backing file to the
 * requesting process.  The filter indicates the scheme used to modify the
 * contents.
 */
enum filter {
    /*
     * Files are expected to be executables.  Return bouncer.
     */
    FILTER_BIN,
    /*
     * Files are expected to be executables.  Return bouncer with restrict set.
     */
    FILTER_BIN_RESTRICT,
    /*
     * Files are expected to be in ini-format.  Performs various
     * transformations such as injecting calls to strat or stratum root
     * paths.
     */
    FILTER_INI,
    /*
     * Combine fonts.dir and fonts.aliases files.
     */
    FILTER_FONT,

    FILTER_SERVICE,
    /*
     * Pass file through unaltered.
     */
    FILTER_PASS,
};

const char *const filter_str[] = {
    "bin",
    "bin-restrict",
    "ini",
    "font",
    "service",
    "pass",
};

struct stratum {
    /*
     * stratum name
     */
    char *name;
    size_t name_len;
    /*
     * A file descriptor relating to the corresponding stratum's root
     * directory.
     */
    int root_fd;
};

/*
 * Each back_entry represents a file or directory which may fulfill a given
 * cfg_entry file.
 */
struct back_entry {
    /*
     * The stratum-local path.
     */
    char *lpath;
    size_t lpath_len;
    /*
     * The corresponding stratum/alias.  Run through deref() before
     * consumption.
     */
    struct stratum alias;
    /*
     * Boolean indicating if this back_entry uses the local alias.  If so,
     * deref() forwards calls to the local stratum rather than this
     * struct's alias field.
     */
    int local;
};

/*
 * Each cfg_entry represents a user-facing file or directory in the mount
 * point.
 */
struct cfg_entry {
    /*
     * Filter to apply to output.
     */
    enum filter filter;
    /*
     * Path to append to mount point's path.  For example, if this
     * filesystem is mounted at "/bedrock/cross" and path="/man", this
     * cfg_entry refers to "/bedrock/cross/man".  Note the preceding slash.
     */
    char *cpath;
    size_t cpath_len;
    /*
     * Array of filesystem paths to be searched for this cfg_entry's
     * backing file(s).
     */
    struct back_entry *back;
    size_t back_cnt;
    size_t back_alloc;
};
