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
