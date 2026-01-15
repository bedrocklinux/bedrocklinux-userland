# 0.7.31

- Added brl-fetch opensuse
- Added brl-import support for multi-partition VM images
- Added brl-import first-class support for docker/podman containers
- Added pmm support for cargo
- Deprecate big-endian 32-bit mips
- Deprecate brl-fetch clear
- Fixed brl-fetch alma
- Fixed brl-fetch arch
- Fixed brl-fetch artix-s6
- Fixed brl-fetch centos
- Fixed brl-fetch centos -r 9-stream
- Fixed brl-fetch crux
- Fixed brl-fetch debian
- Fixed brl-fetch devuan
- Fixed brl-fetch exherbo
- Fixed brl-fetch exherbo
- Fixed brl-fetch exherbo-musl
- Fixed brl-fetch fedora
- Fixed brl-fetch manjaro
- Fixed brl-fetch manjaro
- Fixed brl-fetch openwrt
- Fixed brl-fetch solus
- Fixed brl-fetch void-musl
- Fixed brl-tutorial typos
- Fixed pmm handling of $PATH without Bedrock entries
- Improved etcfs robustness

# 0.7.30

- Fixed brl-fetch Void
- Fixed etcfs listxattr read-only requests
- Fixed etcfs statfs on non-directories
- Fixed handling of missing/erroring /etc/profiles

# 0.7.29

- Build system updates
- Fixed brl-fetch Arch
- Fixed brl-fetch Artix
- Fixed brl-fetch Exherbo
- Fixed brl-fetch Fedora
- Improve build system dynamic link detection
- Various dependency updates
- Work-around systemd shutdown freeze

# 0.7.28

- Improved brl-fetch handling of GPT and multi-partition images
- Removed redundant Ubuntu vt.handoff hack handling
- Fixed brl-fetch arch, artix, gentoo, exherbo

# 0.7.27

- Fixed brl-fetch arch

# 0.7.26

- Fixed GRUB+BTRFS check false-positives.

# 0.7.25

- Fixed brl-fetch centos
- Fixed brl-fetch fedora
- Fixed brl-fetch gentoo
- Improved brl-fetch error message
- Improved systemd 250 shutdown performance
- Increased hijack-time GRUB+BTRFS detection sensitivity

# 0.7.24

- Added pmm zsh completion
- Fixed brl zsh completion
- Fixed brl-fetch centos
- Fixed brl-fetch fedora locale
- Fixed brl-fetch ubuntu
- Fixed resolve.conf handling with some distros/inits
- Improved theoretical robustness of init selection menu

# 0.7.23

- Add support for s6
- Security updates for openssl

# 0.7.22

- Added code to handle errant program clearing modules.dep
- Fixed brl-fetch debian for bullseye
- Fixed hijacked GRUB theme handling
- Fixed resolv.conf on some distros

# 0.7.21

- Added automatic restriction of cmake, dkms
- Added brl-fetch alma
- Added brl-fetch artix-s6
- Added brl-fetch rocky
- Added pmm upgrade-packages*,remove-orphans operations
- Added zstd support to modprobe
- Fixed Gentoo/portage attempting to write to /bedrock/cross/info
- Fixed booting with s6 breaking Bedrock's /run setup
- Fixed brl-fetch artix
- Fixed brl-fetch debian
- Fixed brl-fetch ubuntu

# 0.7.20

- Added brl-import command
- Fixed brl-fetch centos
- Fixed brl-fetch localegen logic issue in some situations
- Fixed brl-fetch solus
- Fixed various pmm issues
- Improved brl SSL handling portability
- Worked around Linux kernel FUSE atomic write bug

# 0.7.18

- Added automatic restriction of CRUX's prt-get, pkgmk
- Added code to load modules on init to help with keyboard detection
- Added crossfs support for wayland-sessions
- Added envvar crossfs settings
- Added more setfattr hijack sanity checks
- Added pmm support for dnf short aliases
- Added retention of BEDROCK_RESTRICTION across sudo call
- Added themes, backgrounds to crossfs defaults
- Fixed /bedrock/cross/bin/X11 self-reference loop
- Fixed brl fetch --list tab completion comment
- Fixed brl priority color handling when brl colors are disabled
- Fixed brl-fetch Alpine
- Fixed brl-fetch Fedora
- Fixed brl-fetch Gentoo
- Fixed brl-fetch KISS
- Fixed brl-fetch centos
- Fixed brl-fetch devuan detection of stable release
- Fixed brl-fetch manjaro
- Fixed brl-strat completion
- Fixed detection of package manager user interface at hijack
- Fixed fish envvar handling
- Fixed overwriting system and user-set PATH entries
- Fixed pmm creation of redundant items when superseding
- Fixed pmm support for pacman,yay search-for-package-by-name
- Fixed pmm support for portage which-packages-provide-file
- Fixed pmm using supersede logic when unneeded
- Fixed portage is-file-db-available noise
- Fixed restriction of XDG_DATA_DIRS
- Fixed zprofile restriction check
- Improved brl-fetch handling of different ssl standards
- Improved brl-fetch locale-gen failure handling
- Improved brl-fetch void to use smaller base-minimal
- Improved crossfs multithread performance if openat2 available (Linux 5.6 and up)
- Improved env-var handling
- Improved etcfs debug output
- Improved plymouth handling

# 0.7.17

- Fixed sudoers injection return value

# 0.7.16

- Added cross-stratum /etc/crypttab support
- Added cross-stratum /etc/profile.d/*.sh support
- Added cross-stratum dkms support
- Fixed brl-fetch fedora, void, void-musl
- Improve brl-fetch error messages
- Improve pmm pacman/yay handling to only supersede identical commands
- Restrict kiss package manager

# 0.7.15

- Added pmm to brl-tutorial
- Fixed brl-tutorial typo
- Fixed pmm apt no-cache package availability check

# 0.7.14

- Added ppc and ppc64 support
- Added Package Manager Manager ("pmm")
- Added code to recover from bad bedrock.conf timezone values
- Added sanity check against GRUB+BTRFS/ZFS issue
- Fixed Path, TryExec handling in crossfs ini filter
- Fixed brl-fetch centos, kiss, void, void-musl, debian sid,

# 0.7.13

- Fixed brl-fetch arch
- Fixed brl-fetch kiss

# 0.7.12

- Fixed brl-fetch artix
- Fixed bash completion for brl-tutorial

# 0.7.11

- Added brl-tutorial command
- Added basics tutorial
- Added brl-fetch tutorial
- Added brl-fetch support for Fedora 31
- Added brl-fetch support for Manjaro
- Fixed brl-fetch debug handling
- Fixed brl-disable handling of invalid stratum

# 0.7.10

- Add brl-fetch centos support for CentOS 8 and 8-stream
- Add brl-fetch support for Artix
- Fix brl-fetch debian, devuan, raspbian and ubuntu libapt-pkg.so warning
- Fix brl-fetch ubuntu default release detection considering "devel" a release
- Improve hijack warning to better explain what it will do

# 0.7.9

- Ensure bouncer updates do not confuse pre-0.7.8 crossfs builds

# 0.7.8

- Added LVM support
- Added brl-fetch Arch Linux 32
- Added brl-fetch Exherbo
- Added caching support
- Added debug subsystem
	- Add etcfs debug support
	- Add brl-fetch debug support
- Added i386, i486, i586, and i686 support
- Added wait for keyboard initialisation
	- This fixed no keyboard in init selection menu issue
- Fixed brl-fetch exherbo
- Fixed crossfs handling of live bouncer changes
- Fixed etcfs file descriptor leak
	- This fixed Void init emergence shell issue
- Improved build system performance
- Restrict apt-key by default
- Restrict debuild by default

# 0.7.7

- Added brl-fetch KISS Linux support
- Added brl-report check for environment variables
- Added brl-update support for verifying signature of offline updates
- Added brl-update support scanning multiple configured mirrors
- Added init message about bedrock.conf
- Added installer check for corrupt embedded tarball
- Added installer check for grub2-mkrelpath bug
- Added installer message about bedrock.conf
- Added official installer/update binaries for ppc64le
- Fixed brl-fetch arch
- Fixed brl-fetch fedora
- Fixed brl-fetch mirrors with paths in http indexes
- Fixed brl-fetch non-native void
- Fixed brl-fetch solus
- Fixed installer handling of quotes in distro name
- Fixed login.defs handling bug
- Fixed resolv.conf handling for some distros
- Fixed various shell tab completion issues
- Improved etcfs robustness to power outages
- Removed /var/tmp from share list
- Update expiration date of signing key
- Various minor fixes and improvements.

# 0.7.6

- Added experimental non-native CPU architecture strata support.
	- Requires `qemu-user-static`.
- Added experimental non-native CPU capabilities to brl-fetch.
	- See new `-a` and `-A` flags in `brl fetch --help`.
- Added official installer/update binaries for additional CPU architectures.
- Fixed Firefox font handling issue.  Work-around is no longer needed.
- Various minor fixes and improvements.

# 0.7.5

- Fixed crossfs local alias dereferencing of sandboxed software.

# 0.7.4

- Added `[restriction]` feature, superseding previous `[cross-bin-restrict]` feature.
	- Configured restriction is not dropped by `strat` unless explicitly indicated so via `--unrestrict`.
	- Local stratum instance of restricted command is used if available.
- Added local alias.
- Fixed Alpine networking issues.
- Fixed `brl fetch -LX` ignoring `-X`
- Fixed determining default Ubuntu release
- Fixed dist-upgrading Ubuntu
- Fixed hijack on bsdtar distros
- Fixed system uid/gid range consistency issues

# 0.7.3

- Added "current" to list of Slackware releases.
- Added code to handle users providing brl-fetch an Arch Linux mirror with
  unquoted/escaped shell variables.
- Added cross pixmap support.
- Added resolvconf support.
- Added support for multiple localegen lines.
- Added warning when default init does not exist.
- Fixed `strat -r ... zsh` escaping restriction via sourcing zprofile.
- Fixed fetch handling of Clear Linux.
- Fixed reboot handling after hijacking systems with PID1 provided by SysV init.
- Generalized brl-fetch user/group handling.
- Implemented work-around for Chromium/Electron/et al TZ bug.
- Improved hijack distro name detection to handle MX Linux. (Note other issues
  with Bedrock Linux/MX Linux compatibility are known at this time.)
- Various minor UI tweaks.

# 0.7.2

- Made `makepkg` and similar programs restricted by default via new
  `[cross-bin-restrict]` configuration.
- Added snap and flatpak items to bedrock.conf
- Added delay between etcfs overrides, which fixes `xbps-install` updating
  etcfs-override files such as /etc/environment.
- Added confirmation prompt to installer when hijacking.
- Added sanity checks to installer for WSL and LVM global directories.
- `strat` now sets SHELL=/bin/sh when restricted, as crossfs SHELL entries do
  not work when restricted.
- Improved various error messages.
- Added experimental brl-fetch support for Clear Linux, Slackware, and Solus.
- Various minor fixes.

# 0.7.1

- Fixed various issues with init/initrd system for some distros.
	- Fixed hidden init-selection menu with Ubuntu
	- Fixed systemd freezing with Fedora
	- Fixed doubling of output due to lingering plymouthd with Fedora
- Added code to handle various conflicts automatically
	- Automatically handle machine-id conflicts
	- Automatically clean up dangling /etc/resolv.conf symlinks which confuse some networking software.
- Various and improvements fixes to brl-fetch
	- Improved `brl fetch --help` description of -i flag.
	- Fixed `brl fetch --releases debian`
	- Fixed `brl fetch gentoo` locale configuration.
	- Fixed mirror-prefix handling for Fedora.
	- Fixed `brl fetch fedora` step count.
- Various reliability improvements for etcfs
	- Increased defensiveness of handling of libfuse-provided values.
	- Simplified injection logic
- Added new `Exec*` fields to crossfs ini filter
- Fixed brl-repair/enable handling of missing directories
- Fixed brl-which recognition of `/bedrock/strata/*` paths.
- Fixed brl-apply failing to apply new bedrock.conf share/bind fields
- Fixed brl-update unnecessary error message
- Added lsmod to brl-report.
- Fixed bedrock.conf comment typo.

# 0.7.0

- First Poki release.  Changes are too numerous from Nyla, starting fresh release notes.
