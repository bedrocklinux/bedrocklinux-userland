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
- Add snap and flatpak items to bedrock.conf
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
