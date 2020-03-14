# 0.7.14beta9

- Recover from bad bedrock.conf timezone values
- pmm: various pacman fixes
- Fix brl-fetch centos, kiss, void, void-musl
- Added check for GRUB+BTRFS/ZFS issue.

# 0.7.14beta8

- Improve pmm output differentiation between --diff-world and --update-world*
- pmm: fixed --diff-world pmm-hidden `<` vs `>` direction.
- pmm: made --update-world single prompt
- pmm: removed `-sync` suffix
- pmm: swapped --diff-world order

# 0.7.14beta7

- pmm: diff-world propose removing non-pmm strata
- pmm: have world ops respect assume-yes/no
- pmm: remove xbps-pkgdb ${flags}

# 0.7.14beta6

- pmm: propose removing pmm-hidden and non-pmm lines from world file
- pmm: handle world file without ending newline
- pmm: do not shell escape `+` or `.`

# 0.7.14beta5

- Fix pmm apt list-installed-package-files

# 0.7.14beta4

- Fix pmm dnf, pacman, portage support
- Fix pmm --help handling of --every
- Fix pmm cache utilization

# 0.7.14beta3

- Fix various pmm configuration items
- Prioritize brl-hide --pmm over bedrock.conf pmm configuration
- Improve pmm error message

# 0.7.14beta2

- Fixed overzealous pmm runtime check

# 0.7.14beta1

- Added Package Manager Manager ("pmm")

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
