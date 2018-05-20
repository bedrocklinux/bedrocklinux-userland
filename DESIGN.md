Bedrock Linux 0.7 Design
========================

This documents the design decisions for Bedrock Linux 0.7.  It is intended to
provide the Bedrock-specific needed to contribute to this code base.

Bedrock Linux Concepts
----------------------

- Local files: If two pieces of software both require different file contents
  at a given path, two instances of the given file must exist for Bedrock to
  support both pieces of software.  Bedrock refers to this class of files as
  "local files".  For example, /etc/apt/sources.list is a local file.  Debian's
  apt and Ubuntu's apt both expect different contents when reading that file
  path.
- Strata: Bedrock groups related local files into "strata".  These are often
  one-to-one with Linux distributions.  For example, a Debian stratum would
  include both /usr/bin/apt and /etc/apt/sources.list.  Bedrock's design
  assumes each stratum contains all of its own "hard" dependencies.  If a given
  executable depends on a given library, both must be provided by the same
  stratum.
- Global files: If every stratum only saw its local files, the strata would be
  unable to interact.  Some file paths must appear the same to processes from
  all strata.  These are called "global files".  For example, /run/dbus is a
  global path.  Thus, a dbus server from one stratum may communicate with a
  dbus client from another.
- Every file path and every process must either be associated with a given
  stratum or be considered global (and thus belongs to all strata).
- Pseudo-global files: /boot must be treated specially; it is shared across
  some strata, but not all.  Thus, it is pseudo-global.
- Enabled/disabled: To make software from various strata interact properly,
  Bedrock must take steps to integrate them at runtime.  A stratum which is
  integrated with the system is "enabled".  To safely remove or rename a
  stratum, this integration must first be undone; that is, the stratum must be
  disabled.
- Aliases: Strata may be referred to through alternative names called
  "aliases".  For example, one may have a stratum for several Debian releases,
  with "stable" aliased to the current Debian Stable release and "testing"
  aliased to the current Debian Testing release.  When Debian cuts a new
  release, the aliases can be updated accordingly without changing the actual
  strata names.

Code Base Layout
----------------

- src/ contains Bedrock's own code, in contrast to upstream libraries.
- src/slash-bedrock/ contains files and directories which will populate the
  eventual install's /bedrock/ directory as-is.  Anything from here is copied
  over preexisting files in an update, and thus this should not contain
  configuration the user may change.
- src/default-configs/ contains default configuration files.  These are files
  which may be used in a fresh install but should not be applied over existing
  files in an update.
- src/installer/ contains the actual installer script.  The build system will
  embed the eventual system files into the installation script.
- Other src/ directories correspond to source for binary executables.  These
  binaries will be included in the slash-bedrock structure embedded within the
  installation script.
- vendor/ (initially absent) will contain upstream build dependencies.  The
  build system will automatically fetch these and populate vendor/ accordingly.
  The build system will attempt to automatically get the latest stable version
  and may occasionally fail if an upstream component changes too drastically.
  This is purposeful, as it will service as a canary indicating developer
  attention is required and preferable to distributing outdated upstream
  components which may contain security vulnerabilities.
- vendor/*/.success_fetching_source files indicate that the given vendor
  component's files have been successfully acquired.  This is used to properly
  handle interrupted downloads.
- build/ (initially absent) will contain intermediate build output which can be
  safely removed.
- build/support/ will contain build-time support code and will not directly end
  up in the resulting install.
- build/bedrock/ will contain files which eventually end up in the installed
  system's /bedrock/ directory.  This will be populated by src/slash-bedrock/
  contents and the various src/ binaries.
- build/completed/ will contain files which indicate various build steps have
  been completed.  These are for build steps that may produce many output
  files as an alternative to verbosely tracking each individual output file.
- Makefile services as the build system.
- `*.md` files service as documentation.

/bedrock Directory
------------------

Every Bedrock Linux system includes a /bedrock directory.  This directory
includes the "glue" used to make parts of other Linux distributions work
together.

- /bedrock/ is locked (see man 2 flock) by various Bedrock processes to
  serialize operations such as enabling/disabling strata.
- /bedrock/bin/ contains user-facing executables.
- /bedrock/bin/strat is an executable is used to run executables across strata.
  Bedrock ensures this is called behind-the-scenes to ensure cross-stratum
  functionality works transparently in most contexts.
- /bedrock/bin/brl is an executable which provides most user-facing Bedrock
  functionality, including strata management and introspection tools.
- /bedrock/cross/ is a virtual filesystem (only populated at runtime)
  which provides a view of files from other strata, modified to work
  across strata.  For example, /bedrock/cross/bin/ includes executables that
  internally redirect through /bedrock/bin/strat.  Bedrock ensures various
  programs look in /bedrock/cross to transparently support cross-stratum
  coordination.
- /bedrock/etc/ contains Bedrock configuration and other miscellaneous files.
- /bedrock/etc/bedrock.conf is an ini-formatted file containing all user-facing
  Bedrock-specific configuration.
- /bedrock/etc/bedrock-release contains the current Bedrock Linux version.
- /bedrock/libexec/ contains non-user-facing executables.  These should not be
  included in a user's $PATH.
- /bedrock/run/ contains various runtime files for Bedrock.  This is a tmpfs
  filesystem and is cleared across reboots.
- /bedrock/run/enabled_strata/ is used to track which stratum are enabled.
  When a stratum is successfully enabled, a file with the stratum's name is
  created in the directory.  When a stratum is disabled, this file is deleted.
  Various Bedrock subsystems check this directory.
- /bedrock/run/init is a symlink to the /bedrock/strata/<stratum> directory
  corresponding to the stratum providing PID1.  This is used as part of the
  process of maintaining an "init" alias to the current init-providing stratum.
  This stratum is used internally to ensure the appropriate stratum provides
  the init-related commands such as reboot.
- /bedrock/share/ contains various architecture-independent data.  In addition
  to the directories listed below, it contains files used to support
  integration with various pieces of software.  For example, it contains tab
  completion scripts for various shells and configuration to teach various
  programs about /bedrock/cross/.
- /bedrock/share/brl-fetch/distros/ contains distro-specific code for the `brl
  fetch` command.
- /bedrock/share/info/ is included in the list of directories used to populate
  /bedrock/cross/info/.  At the moment it only includes a `.keepinfodir` file
  as a hack to support Gentoo/portage's handling of info files.  Should someone
  eventually write info files for Bedrock, they will be included in here.
- /bedrock/share/man/ contains man pages for Bedrock Linux.
- /bedrock/strata contains the root directories of the various strata.  For
  example, a Gentoo stratum's files may be found at /bedrock/strata/gentoo.
  One may add a new stratum by creating and populating a new directory in
  /bedrock/strata then telling `brl` to unignore and enable it.  Aliases are
  implemented as symlinks in /bedrock/strata/ which (ultimately) resolve to a
  directory in /bedrock/strata.  For example, a /bedrock/strata/lts symlink
  pointing to /bedrock/strata/bionic indicates the "lts" is an alias for
  "bionic".  One may create an alias by simply creating such a symlink.

The Offline Filesystem Layout
-----------------------------

The offline view filesystem layout is how Bedrock's filesystem looks before any
Bedrock code has run.  This is what the bootloader sees, and is what one would
see if booting another operating system then mounting a Bedrock system's
partition(s).

- /bedrock exists, as described in "/bedrock Directory" section.
- All the (pseudo-)global files (such as /etc/passwd and /home and /boot) exist
  exactly here they are expected to.
- Some local files exist in their typical paths, such as /sbin/init and
  /bin/sh.  These are owned by the "bedrock" stratum.  Most if not all are
  symlinks into /bedrock.
- /bedrock/strata/ is populated with the root directories of the various
  strata.  A /bedrock/strata/bedrock directory will exist but should be empty
  when offline.

The Online Filesystem Layout
----------------------------

The online view is the various processes see the filesystem when Bedrock is
running.

- /bedrock exists, as described in "/bedrock Directory" section.
- All the global files (such as /etc/passwd and /home) exist exactly here they
  are expected to.  Under the hood, Bedrock redirects access to such files to
  the bedrock stratum.
- If the stratum has an instance of a local file, it can be found at the
  typical path.  For example, each stratum sees its own /sbin/init at
  /sbin/init.
- /bedrock/strata/ is populated with the root directories of the various
  strata.  Any stratum's local instance of a file can be found through
  /bedrock/strata/<stratum>/<local-filepath>.  What one sees when appending
  global file paths to /bedrock/strata/<stratum> is undefined.

Extended filesystem attributes
------------------------------

In some circumstances, Bedrock populates the `user.bedrock.stratum` filesystem
attribute with the name of the stratum that owns a given file.

These include:

- Every (enabled) stratum root in /bedrock/strata/.  Given this, a process
  can determine which stratum it is from by reading the attribute off of the
  (local) filesystem root directory.
- The filesystem mounted at /bedrock/cross populates this field.
- The filesystem mounted at /etc populates this field.

This `user.bedrock.stratum` attribute is utilized by `brl which` to determine
which stratum provides a given file path.  It is also utilized by the
executables in /bedrock/cross/ to determine which stratum should provide the
request.

In some circumstances, Bedrock populates the `user.bedrock.localpath` filesystem
attribute with the name of the stratum that owns a given file.  These include:

- The filesystem mounted at /bedrock/cross populates this field.
- The filesystem mounted at /etc populates this field.

This is utilized by the executables in /bedrock/cross/ to determine which file
should provide the given request.  At the moment there are no plans to make use
of the fact /etc also provides this, although it may be useful in debugging.

The strata roots in /bedrock/strata/ may also have a `user.bedrock.unignored`
attribute if the given stratum is unignored.

Configuration
-------------

All user-facing configuration TODO

Expected command UI
-------------------

Below are proposed outputs for various `--help` calls.  This should be suitable
for prototyping things such as shell completion and man pages.  This is in flux
and may change.

```
$ ./bedrock-linux-<version>-<arch>.sh --help
Usage: $0 [options]

Install a Bedrock Linux system.  May also be fed into `brl update` to update
the system.

Options:
  --hijack              Convert the current system installation to a Bedrock
                        Linux system.
  --direct <directory>  Install Bedrock Linux directly to a pre-formatted
                        partition.
  --chroot <directory>  Setup and enter a chroot.  Used to in support of
                        --direct.
  -h, --help            print this message
```

```
$ strat --help
Usage: strat [options] <stratum> <command>

Run specified stratum's instance of an executable.

Options:
  -l, --local       disable cross-stratum hooks
  -a, --arg0 <ARG0> specify arg0
  -h, --help        print this message

Examples:
  Run centos's ls command:
  $ strat centos ls
  Run gentoo's busybox with arg0="ls":
  $ strat --arg0 ls gentoo busybox
  Run arch's makepkg against only arch files:
  $ strat --local arch makepkg
```

```
$ brl --help
Usage: brl <command> [arguments]

Bedrock Linux system management and introspection.

Common commands:
  strat     Run specified stratum's executable
            Note: `strat` is available without the `brl` prefix
  list      List strata
  which     Query which stratum provides an object

Strata management commands:
  fetch     Fetch new strata
  remove    Remove strata (or aliases)
  rename    Rename a stratum

Strata status management commands:
  status    Query stratum status
  enable    Enable strata
  disable   Disable strata
  reenable  Disable then re-enable strata

Strata ignore management commands:
  ignore    Ignore strata
  unignore  Unignore strata

Alias management commands:
  alias     Create a stratum alias
  deref     Dereference stratum aliases

Miscellaneous commands:
  update    Update Bedrock Linux system
  version   Query Bedrock Linux version
  report    Generate report

See `brl <command> --help` for further details per command.
```

`brl strat --help` gets passed through directly to `strat --help`.

```
$ brl list --help
Usage: brl list [options] [categories]

Lists strata.

Options:
  -a, --include-aliases  include strata aliases in ouptut
  -h, --help             print this message

Categories:
  <none>     defaults to listing enabled strata
  enabled    list enabled strata
  disabled   list disabled strata
  unignored  list unignored strata (enabled and disabled)
  ignored    list ignored strata
  aliases    list strata aliases

Examples:
  $ brl list
  arch
  bedrock
  gentoo
  void
  $ brl list -a enabled
  arch
  bedrock
  gentoo
  init -> void
  void
  $ brl list disabled
  sid
  $ brl list aliases
  init -> void
  unstable -> sid
```

```
$ brl which --help
Usage: brl which [options] [identifier]

Indicates which stratum provides a given object.

Options:
  <none>          which stratum provides this process
  -b, --bin       which stratum provides a given executable in $PATH
  -f, --filepath  which stratum provides a given file path
  -p, --pid       which stratum provides a given PID
  -x, --xwindow   which stratum provides a given X11 window (requires xprop)
  -h, --help      print this message

Examples:
  $ brl which # which stratum provides the current shell?
  void
  $ brl which -b vim # which stratum provides the `vim` command?
  gentoo
  $ brl which -f ~/.vimrc # which stratum provides ~/.vimrc?
  global
  $ brl which -f /etc/os-release # which stratum provides /etc/os-release?
  void
  $ brl which -f /etc/passwd # which stratum provides /etc/passwd?
  global
  $ brl which -p 1 # which stratum provides PID1/init?
  alpine
  $ brl which -x # after running click mouse on X11 window
  arch
```

```
$ brl fetch --help
Usage: brl fetch [options] [distros]

Acquire a given Linux distribution's files as a new stratum.  Actual fetch
operation requires root.

The code to determine mirrors and releases is prone to breaking as upstream
distros make changes.  If automated efforts to look them up fail, try looking
up the information yourself and providing it to `brl fetch` via flags.

Options:
  -L, --list-distros   list supported distros
  -R, --list-releases  list releases [distro] provides
  -M, --list-mirrors   list mirrors [distro] provides
  -r, --release        specify desired release
  -m, --mirror         specify desired mirror
  -h, --help           print this message

Examples:
  $ brl fetch --list-distros | head -n5
  alpine
  arch
  centos
  debian
  devuan
  $ brl fetch --list-releases arch
  rolling
  $ brl fetch --list-releases debian
  jessie
  stretch
  buster
  sid
  $ brl fetch --list-mirrors debian | head -n5
  http://ftp.am.debian.org/debian/
  http://ftp.au.debian.org/debian/
  http://ftp.at.debian.org/debian/
  http://ftp.by.debian.org/debian/
  http://ftp.be.debian.org/debian/
  # brl fetch centos
  <acquires centos with automatically determined release and mirror>
  # brl fetch -r sid -m http://ftp.us.debian.org/debian/ debian
  <acquires debian with specified release and mirror>
  # brl fetch alpine arch devuan
  <acquires multiple distros in one command>
```

```
$ brl remove --help
Usage: brl remove [options] <strata>

Removes specified strata.  Requires root.

Options:
  -f, --force  perform operation even if stratum-owned processes are detected.
  -h, --help   print this message

Examples:
  # brl remove alpine arch centos
  # brl remove debian
  brl remove error: stratum has running processes
  # brl remove --force debian
```

```
$ brl rename --help
Usage: brl rename [options] <stratum> <new-name>

Renames stratum.  Requires root.

Options:
  -f, --force  perform operation even if stratum-owned processes are detected.
  -h, --help   print this message

Examples:
  $ brl list unignored | grep -e debian -e stretch
  debian
  # brl rename debian stretch
  $ brl list unignored | grep -e debian -e stretch
  stretch
```

```
$ brl status --help
Usage: brl status [options] <strata>

Prints specified stratum's status.  The status may be one of the following:
enabled, disabled, ignored, or broken.

Options:
  -h, --help   print this message

Examples:
  $ brl status solus
  solus: enabled
  # strat solus umount /etc
  $ brl status solus
  solus: broken
  $ sudo brl disable solus
  $ brl status solus
  solus: disabled
  $ sudo brl ignore solus
  $ brl status solus
  solus: ignored
  $ brl status alpine arch
  alpine: enabled
  arch: enabled
  $ brl status $(brl list) | head -n5
  alpine: enabled
  arch: enabled
  centos: enabled
  debian: enabled
  devuan: enabled

```

```
$ brl enable --help
Usage: brl enable [options] <strata>

Makes disabled and broken strata enabled.

Options:
  -h, --help   print this message

Examples:
  $ brl status solus
  solus: disabled
  # brl enable solus
  $ brl status solus
  solus: enabled
  # strat solus umount /etc
  $ brl status solus
  solus: broken
  # brl enable solus
  $ brl status solus
  solus: enabled
  # brl enable alpine arch centos
  $ brl status alpine arch centos
  alpine: enabled
  arch: enabled
  centos: enabled
```

```
$ brl disable --help
Usage: brl disable [options] <strata>

Disabled strata.

Options:
  -f, --force  perform operation even if stratum-owned processes are detected.
  -h, --help   print this message

Examples:
  $ brl status solus
  enabled
  # brl disable solus
  brl disable error: stratum has running processes
  # brl disable --force solus
  $ brl status solus
  disabled
  # brl disable alpine arch centos
  alpine: disabled
  $ brl status alpine arch centos
  alpine: disabled
  arch: disabled
  centos: disabled
```

```
$ brl reenable --help
Usage: brl reename [options] <strata>

Disables then re-enables strata.

Options:
  -f, --force  perform operation even if stratum-owned processes are detected.
  -h, --help   print this message

Examples:
  $ brl status solus
  broken
  # brl reeanble solus
  $ brl status solus
  enabled
```

```
$ brl ignore --help
Usage: brl ignore [options] <strata>

Marks disabled strata to be ignored.  Requires root.

Options:
  -h, --help   print this message

Examples:
  $ brl list | grep centos
  centos
  # brl ignore centos
  brl ignore error: gentoo is not disabled
  # brl disable centos
  # brl ignore centos
  $ brl list | grep centos
```

```
$ brl unignore --help
Usage: brl unignore [options] <strata>

Marks disabled strata to be unignored.  Requires root.

Options:
  -h, --help   print this message

Examples:
  $ brl list unignored | grep centos
  # brl unignore centos
  $ brl list unignored | grep centos
  centos
```

```
$ brl alias --help
Usage: brl alias [options] <stratum> <alias>

Creates an stratum alias.  References to this alias can be used in place of the
stratum name in most contexts.  Requires root.

Options:
  -h, --help   print this message

Example:
  # brl fetch fedora --release 27 --name fedora27
  $ brl list | grep fedora
  fedora27
  $ sudo brl alias fedora27 fedora
  $ brl deref fedora
  fedora27
  $ brl status fedora
  fedora27: enabled
  $ cat /bedrock/strata/fedora/etc/fedora-release
  Fedora release 27 (Twenty Seven)
  $ strat fedora cat /etc/fedora-release
  Fedora release 27 (Twenty Seven)
  $ cat /bedrock/strata/fedora27/etc/fedora-release
  Fedora release 27 (Twenty Seven)
  $ strat fedora27 cat /etc/fedora-release
  Fedora release 27 (Twenty Seven)
```

```
$ brl deref --help
Usage: brl deref [options] <strata>

Dereferences strata aliases.  Dereferencing a non-alias stratum returns the
stratum.  Requires root.

Options:
  -h, --help   print this message

Example:
  # brl fetch fedora --release 27 --name fedora27
  # brl fetch debian --release unstable --name sid
  # brl alias fedora27 fedora
  # brl alias sid unstable
  $ brl deref fedora
  fedora27
  $ brl deref unstable
  sid
  $ brl deref fedora27
  fedora27
  $ brl deref sid
  sid
```

```
$ brl update --help
Usage: brl update [options]

Updates a Bedrock Linux system.  Requires root.  Depending on update contents,
might require reboot to fully apply.

Options:
  <none>             attempt to fetch and apply update from configured mirror
  -m, --mirror       attempt to fetch and apply update from specified mirror
  -f, --file <file>  apply specified bedrock-linux-<version>-<arch>.sh update
  -s, --skip-check   do not check update file's cryptographic signature
  -h, --help         print this message

Example:
  # brl update
  <applies online update from mirror>
  $ git pull && make SKIPSIGN=true
  <builds latest version of installer locally>
  # brl update --file ./bedrock-linux-0.7.999-amd64.sh --skip-check
  <applies installer's bedrock system files of files as update>
```

```
$ brl version --help
Usage: brl version [options]

Prints Bedrock Linux install's version.

Options:
  -h, --help   print this message

Example:
  $ brl version
  Bedrock Linux 0.7.0 Poki
```

```
$ brl report --help
Usage: brl report [options] <output>

Generates a report about the current Bedrock Linux system, intended for
debugging issues.  Output must be a file path to store the resulting report.

Options:
  -h, --help   print this message

Example:
  $ brl report /tmp/log
  $ cat /tmp/log | xclip
```
