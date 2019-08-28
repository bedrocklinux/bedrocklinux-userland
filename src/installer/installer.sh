#!/bin/sh
#
# installer.sh
#
#      This program is free software; you can redistribute it and/or
#      modify it under the terms of the GNU General Public License
#      version 2 as published by the Free Software Foundation.
#
# Copyright (c) 2018 Daniel Thau <danthau@bedrocklinux.org>
#
# Installs or updates a Bedrock Linux system.

. /bedrock/share/common-code # replace with file content during build process

ARCHITECTURE= # replace with build target CPU architecture during build process
TARBALL_SHA1SUM= # replace with tarball sha1sum during build process

print_help() {
	printf "Usage: ${color_cmd}${0} ${color_sub}<operations>${color_norm}

Install or update a Bedrock Linux system.

Operations:
  ${color_cmd}--hijack ${color_sub}[name]       ${color_norm}convert current installation to Bedrock Linux.
                        ${color_priority}this operation is not intended to be reversible!${color_norm}
                        ${color_norm}optionally specify initial ${color_term}stratum${color_norm} name.
  ${color_cmd}--update              ${color_norm}update current Bedrock Linux system.
  ${color_cmd}--force-update        ${color_norm}update current system, ignoring warnings.
  ${color_cmd}-h${color_norm}, ${color_cmd}--help            ${color_norm}print this message
${color_norm}"
}

extract_tarball() {
	# Many implementations of common UNIX utilities fail to properly handle
	# null characters, severely restricting our options.  The solution here
	# assumes only one embedded file with nulls - here, the tarball - and
	# will not scale to additional null-containing embedded files.

	# Utilities that completely work with null across tested implementations:
	#
	# - cat
	# - wc
	#
	# Utilities that work with caveats:
	#
	# - head, tail: only with direct `-n N`, no `-n +N`
	# - sed:  does not print lines with nulls correctly, but prints line
	# count correctly.

	lines_total="$(wc -l <"${0}")"
	lines_before="$(sed -n "1,/^-----BEGIN TARBALL-----\$/p" "${0}" | wc -l)"
	lines_after="$(sed -n "/^-----END TARBALL-----\$/,\$p" "${0}" | wc -l)"
	lines_tarball="$((lines_total - lines_before - lines_after))"

	# Since the tarball is a binary, it can end in a non-newline character.
	# To ensure the END marker is on its own line, a newline is appended to
	# the tarball.  The `head -c -1` here strips it.
	tail -n "$((lines_tarball + lines_after))" "${0}" | head -n "${lines_tarball}" | head -c -1 | gzip -d
}

sanity_check_grub_mkrelpath() {
	if grub2-mkrelpath --help 2>&1 | grep -q "relative"; then
		orig="$(grub2-mkrelpath --relative /boot)"
		mount --bind /boot /boot
		new="$(grub2-mkrelpath --relative /boot)"
		umount -l /boot
		[ "${orig}" = "${new}" ]
	elif grub-mkrelpath --help 2>&1 | grep -q "relative"; then
		orig="$(grub-mkrelpath --relative /boot)"
		mount --bind /boot /boot
		new="$(grub-mkrelpath --relative /boot)"
		umount -l /boot
		[ "${orig}" = "${new}" ]
	fi
}

hijack() {
	printf "\
${color_priority}* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *${color_norm}
${color_priority}*${color_alert} YOU ARE ABOUT TO CONVERT YOUR EXISTING LINUX INSTALL INTO A   ${color_priority}*${color_norm}
${color_priority}*${color_alert} BEDROCK LINUX INSTALL! THIS IS NOT INTENDED TO BE REVERSIBLE! ${color_priority}*${color_norm}
${color_priority}* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *${color_norm}

Please type \"Not reversible!\" without quotes at the prompt to continue:
> "
	read -r line
	echo ""
	if [ "${line}" != "Not reversible!" ]; then
		abort "Warning not copied exactly."
	fi

	release="$(extract_tarball | tar xOf - bedrock/etc/bedrock-release 2>/dev/null || true)"
	print_logo "${release}"

	step_init 6

	step "Performing sanity checks"
	modprobe fuse || true
	if [ "$(id -u)" != "0" ]; then
		abort "root required"
	elif [ -r /proc/sys/kernel/osrelease ] && grep -qi 'microsoft' /proc/sys/kernel/osrelease; then
		abort "Windows Subsystem for Linux does not support the required features for Bedrock Linux."
	elif ! grep -q "\\<fuse\\>" /proc/filesystems; then
		abort "/proc/filesystems does not contain \"fuse\".  FUSE is required for Bedrock Linux to operate.  Install the module fuse kernel module and try again."
	elif ! [ -e /dev/fuse ]; then
		abort "/dev/fuse not found.  FUSE is required for Bedrock Linux to operate.  Install the module fuse kernel module and try again."
	elif ! type sha1sum >/dev/null 2>&1; then
		abort "Could not find sha1sum executable.  Install it then try again."
	elif ! extract_tarball >/dev/null 2>&1 || [ "${TARBALL_SHA1SUM}" != "$(extract_tarball | sha1sum - | cut -d' ' -f1)" ]; then
		abort "Embedded tarball is corrupt.  Did you edit this script with software that does not support null characters?"
	elif ! sanity_check_grub_mkrelpath; then
		abort "grub-mkrelpath/grub2-mkrelpath --relative does not support bind-mounts on /boot.  Continuing may break the bootloader on a kernel update.  This is a known Bedrock issue with OpenSUSE+btrfs/GRUB."
	elif [ -e /bedrock/ ]; then
		# Prefer this check at end of sanity check list so other sanity
		# checks can be tested directly on a Bedrock system.
		abort "/bedrock found.  Cannot hijack Bedrock Linux."
	fi

	bb="/true"
	if ! extract_tarball | tar xOf - bedrock/libexec/busybox >"${bb}"; then
		rm -f "${bb}"
		abort "Unable to write to root filesystem.  Read-only root filesystems are not supported."
	fi
	chmod +x "${bb}"
	if ! "${bb}"; then
		rm -f "${bb}"
		abort "Unable to execute reference binary.  Perhaps this installer is intended for a different CPU architecture."
	fi
	rm -f "${bb}"

	setf="/bedrock-linux-installer-$$-setfattr"
	getf="/bedrock-linux-installer-$$-getfattr"
	extract_tarball | tar xOf - bedrock/libexec/setfattr >"${setf}"
	extract_tarball | tar xOf - bedrock/libexec/getfattr >"${getf}"
	chmod +x "${setf}"
	chmod +x "${getf}"
	if ! "${setf}" -n 'user.bedrock.test' -v 'x' "${getf}"; then
		rm "${setf}"
		rm "${getf}"
		abort "Unable to set xattr.  Bedrock Linux only works with filesystems which support extended filesystem attributes (\"xattrs\")."
	fi
	if [ "$("${getf}" --only-values --absolute-names -n "user.bedrock.test" "${getf}")" != "x" ]; then
		rm "${setf}"
		rm "${getf}"
		abort "Unable to get xattr.  Bedrock Linux only works with filesystems which support extended filesystem attributes (\"xattrs\")."
	fi
	rm "${setf}"
	rm "${getf}"

	step "Gathering information"

	name=""
	if [ -n "${1:-}" ]; then
		name="${1}"
	elif grep -q '^DISTRIB_ID=' /etc/lsb-release 2>/dev/null; then
		name="$(awk -F= '$1 == "DISTRIB_ID" {print tolower($2)}' /etc/lsb-release | strip_illegal_stratum_name_characters)"
	elif grep -q '^ID=' /etc/os-release 2>/dev/null; then
		name="$(. /etc/os-release && echo "${ID}" | strip_illegal_stratum_name_characters)"
	else
		for file in /etc/*; do
			if [ "${file}" = "os-release" ]; then
				continue
			elif [ "${file}" = "lsb-release" ]; then
				continue
			elif echo "${file}" | grep -q -- "-release$" 2>/dev/null; then
				name="$(awk '{print tolower($1);exit}' "${file}" | strip_illegal_stratum_name_characters)"
				break
			fi
		done
	fi
	if [ -z "${name}" ]; then
		name="hijacked"
	fi
	ensure_legal_stratum_name "${name}"
	notice "Using ${color_strat}${name}${color_norm} for initial stratum"

	if ! [ -r "/sbin/init" ]; then
		abort "No file detected at /sbin/init.  Unable to hijack init system."
	fi
	notice "Using ${color_strat}${name}${color_glue}:${color_cmd}/sbin/init${color_norm} as default init selection"

	localegen=""
	if [ -r "/etc/locale.gen" ]; then
		localegen="$(awk '/^[^#]/{printf "%s, ", $0}' /etc/locale.gen | sed 's/, $//')"
	fi
	if [ -n "${localegen:-}" ] && echo "${localegen}" | grep -q ","; then
		notice "Discovered multiple locale.gen lines"
	elif [ -n "${localegen:-}" ]; then
		notice "Using ${color_file}${localegen}${color_norm} for ${color_file}locale.gen${color_norm} language"
	else
		notice "Unable to determine locale.gen language, continuing without it"
	fi

	if [ -n "${LANG:-}" ]; then
		notice "Using ${color_cmd}${LANG}${color_norm} for ${color_cmd}\$LANG${color_norm}"
	fi

	timezone=""
	if [ -r /etc/timezone ] && [ -r "/usr/share/zoneinfo/$(cat /etc/timezone)" ]; then
		timezone="$(cat /etc/timezone)"
	elif [ -h /etc/localtime ] && readlink /etc/localtime | grep -q '^/usr/share/zoneinfo/' && [ -r /etc/localtime ]; then
		timezone="$(readlink /etc/localtime | sed 's,^/usr/share/zoneinfo/,,')"
	elif [ -r /etc/rc.conf ] && grep -q '^TIMEZONE=' /etc/rc.conf; then
		timezone="$(awk -F[=] '$1 == "TIMEZONE" {print$NF}')"
	elif [ -r /etc/localtime ]; then
		timezone="$(find /usr/share/zoneinfo -type f -exec sha1sum {} \; 2>/dev/null | awk -v"l=$(sha1sum /etc/localtime | cut -d' ' -f1)" '$1 == l {print$NF;exit}' | sed 's,/usr/share/zoneinfo/,,')"
	fi
	if [ -n "${timezone:-}" ]; then
		notice "Using ${color_file}${timezone}${color_norm} for timezone"
	else
		notice "Unable to automatically determine timezone, continuing without it"
	fi

	step "Hijacking init system"
	# Bedrock wants to take control of /sbin/init. Back up that so we can
	# put our own file there.
	#
	# Some initrds assume init is systemd if they find systemd on disk and
	# do not respect the Bedrock meta-init at /sbin/init.  Thus we need to
	# hide the systemd executables.
	for init in /sbin/init /usr/bin/init /usr/sbin/init /lib/systemd/systemd /usr/lib/systemd/systemd; do
		if [ -h "${init}" ] || [ -e "${init}" ]; then
			mv "${init}" "${init}-bedrock-backup"
		fi
	done

	step "Extracting ${color_file}/bedrock${color_norm}"
	extract_tarball | (
		cd /
		tar xf -
	)
	extract_tarball | tar tf - | grep -v bedrock.conf | sort >/bedrock/var/bedrock-files

	step "Configuring"

	notice "Configuring ${color_strat}bedrock${color_norm} stratum"
	set_attr "/" "stratum" "bedrock"
	set_attr "/" "arch" "${ARCHITECTURE}"
	set_attr "/bedrock/strata/bedrock" "stratum" "bedrock"
	notice "Configuring ${color_strat}${name}${color_norm} stratum"
	mkdir -p "/bedrock/strata/${name}"
	if [ "${name}" != "hijacked" ]; then
		ln -s "${name}" /bedrock/strata/hijacked
	fi
	for dir in / /bedrock/strata/bedrock /bedrock/strata/${name}; do
		set_attr "${dir}" "show_boot" ""
		set_attr "${dir}" "show_cross" ""
		set_attr "${dir}" "show_init" ""
		set_attr "${dir}" "show_list" ""
	done

	notice "Configuring ${color_file}bedrock.conf${color_norm}"
	mv /bedrock/etc/bedrock.conf-* /bedrock/etc/bedrock.conf
	sha1sum </bedrock/etc/bedrock.conf >/bedrock/var/conf-sha1sum

	awk -v"value=${name}:/sbin/init" '!/^default =/{print} /^default =/{print "default = "value}' /bedrock/etc/bedrock.conf >/bedrock/etc/bedrock.conf-new
	mv /bedrock/etc/bedrock.conf-new /bedrock/etc/bedrock.conf
	if [ -n "${timezone:-}" ]; then
		awk -v"value=${timezone}" '!/^timezone =/{print} /^timezone =/{print "timezone = "value}' /bedrock/etc/bedrock.conf >/bedrock/etc/bedrock.conf-new
		mv /bedrock/etc/bedrock.conf-new /bedrock/etc/bedrock.conf
	fi
	if [ -n "${localegen:-}" ]; then
		awk -v"values=${localegen}" '!/^localegen =/{print} /^localegen =/{print "localegen = "values}' /bedrock/etc/bedrock.conf >/bedrock/etc/bedrock.conf-new
		mv /bedrock/etc/bedrock.conf-new /bedrock/etc/bedrock.conf
	fi
	if [ -n "${LANG:-}" ]; then
		awk -v"value=${LANG}" '!/^LANG =/{print} /^LANG =/{print "LANG = "value}' /bedrock/etc/bedrock.conf >/bedrock/etc/bedrock.conf-new
		mv /bedrock/etc/bedrock.conf-new /bedrock/etc/bedrock.conf
	fi

	notice "Configuring ${color_file}/etc/fstab${color_norm}"
	if [ -r /etc/fstab ]; then
		awk '$1 !~ /^#/ && NF >= 6 {$6 = "0"} 1' /etc/fstab >/etc/fstab-new
		mv /etc/fstab-new /etc/fstab
	fi

	if [ -r /boot/grub/grub.cfg ] && \
		grep -q 'vt.handoff' /boot/grub/grub.cfg && \
		grep -q 'splash' /boot/grub/grub.cfg && \
		type grub-mkconfig >/dev/null 2>&1; then

		notice "Configuring bootloader"
		sed 's/splash//g' /etc/default/grub > /etc/default/grub-new
		mv /etc/default/grub-new /etc/default/grub
		grub-mkconfig -o /boot/grub/grub.cfg
	fi

	step "Finalizing"
	touch "/bedrock/complete-hijack-install"
	notice "Reboot to complete installation"
	notice "After reboot explore the ${color_cmd}brl${color_norm} command"
	notice "and ${color_file}/bedrock/etc/bedrock.conf${color_norm} configuration file."
}

update() {
	if [ -n "${1:-}" ]; then
		force=true
	else
		force=false
	fi

	step_init 7

	step "Performing sanity checks"
	require_root
	if ! [ -r /bedrock/etc/bedrock-release ]; then
		abort "No /bedrock/etc/bedrock-release file.  Are you running Bedrock Linux 0.7.0 or higher?"
	fi

	step "Determining version change"
	current_version="$(awk '{print$3}' </bedrock/etc/bedrock-release)"
	new_release="$(extract_tarball | tar xOf - bedrock/etc/bedrock-release)"
	new_version="$(echo "${new_release}" | awk '{print$3}')"

	if ! ${force} && ! ver_cmp_first_newer "${new_version}" "${current_version}"; then
		abort "${new_version} is not newer than ${current_version}, aborting."
	fi

	if ver_cmp_first_newer "${new_version}" "${current_version}"; then
		notice "Updating from ${current_version} to ${new_version}"
	elif [ "${new_version}" = "${current_version}" ]; then
		notice "Re-installing ${current_version} over same version"
	else
		notice "Downgrading from ${current_version} to ${new_version}"
	fi

	step "Running pre-install steps"

	# Early Bedrock versions used a symlink at /sbin/init, which was found
	# to be problematic.  Ensure the userland extraction places a real file
	# at /sbin/init.
	if [ -h /bedrock/strata/bedrock/sbin/init ]; then
		rm -f /bedrock/strata/bedrock/sbin/init
	fi

	step "Installing new files and updating existing ones"
	extract_tarball | (
		cd /
		/bedrock/bin/strat bedrock /bedrock/libexec/busybox tar xf -
	)
	/bedrock/libexec/setcap cap_sys_chroot=ep /bedrock/bin/strat

	step "Removing unneeded files"
	# Remove previously installed files not part of this release
	extract_tarball | tar tf - | grep -v bedrock.conf | sort >/bedrock/var/bedrock-files-new
	diff -d /bedrock/var/bedrock-files-new /bedrock/var/bedrock-files | grep '^>' | cut -d' ' -f2- | tac | while read -r file; do
		if echo "${file}" | grep '/$'; then
			/bedrock/bin/strat bedrock /bedrock/libexec/busybox rmdir "/${file}" 2>/dev/null || true
		else
			/bedrock/bin/strat bedrock /bedrock/libexec/busybox rm -f "/${file}" 2>/dev/null || true
		fi
	done
	mv /bedrock/var/bedrock-files-new /bedrock/var/bedrock-files

	step "Handling possible bedrock.conf update"
	# If bedrock.conf did not change since last update, remove new instance
	new_conf=true
	new_sha1sum="$(sha1sum <"/bedrock/etc/bedrock.conf-${new_version}")"
	if [ "${new_sha1sum}" = "$(cat /bedrock/var/conf-sha1sum)" ]; then
		rm "/bedrock/etc/bedrock.conf-${new_version}"
		new_conf=false
	fi
	echo "${new_sha1sum}" >/bedrock/var/conf-sha1sum

	step "Running post-install steps"

	if ver_cmp_first_newer "0.7.0beta4" "${current_version}"; then
		# Busybox utility list was updated in 0.7.0beta3, but their symlinks were not changed.
		# Ensure new utilities have their symlinks.
		/bedrock/libexec/busybox --list-full | while read -r applet; do
			strat bedrock /bedrock/libexec/busybox rm -f "/${applet}"
		done
		strat bedrock /bedrock/libexec/busybox --install -s
	fi

	if ver_cmp_first_newer "0.7.6" "${current_version}"; then
		set_attr "/bedrock/strata/bedrock" "arch" "${ARCHITECTURE}"
	fi

	if ver_cmp_first_newer "0.7.7beta1" "${current_version}" && [ -r /etc/login.defs ]; then
		# A typo in /bedrock/share/common-code's enforce_id_ranges()
		# resulted in spam at the bottom of /etc/login.defs files.  The
		# typo was fixed in this release such that we won't generate
		# new spam, but we still need to remove any existing spam.
		#
		# /etc/login.defs is global such that we only have to update
		# one file.
		#
		# Remove all SYS_UID_MIN and SYS_GID_MIN lines after the first
		# of each.
		awk '
			/^[ \t]*SYS_UID_MIN[ \t]/ {
				if (uid == 0) {
					print
					uid++
				}
				next
			}
			/^[ \t]*SYS_GID_MIN[ \t]/ {
				if (gid == 0) {
					print
					gid++
				}
				next
			}
			1
		' "/etc/login.defs" > "/etc/login.defs-new"
		mv "/etc/login.defs-new" "/etc/login.defs"

		# Run working enforce_id_ranges to fix add potentially missing
		# lines
		enforce_id_ranges
	fi

	notice "Successfully updated to ${new_version}"
	new_crossfs=false
	new_etcfs=false

	if ver_cmp_first_newer "0.7.0beta3" "${current_version}"; then
		new_crossfs=true
		notice "Added brl-fetch-mirrors section to bedrock.conf.  This can be used to specify preferred mirrors to use with brl-fetch."
	fi

	if ver_cmp_first_newer "0.7.0beta4" "${current_version}"; then
		new_crossfs=true
		new_etcfs=true
		notice "Added ${color_cmd}brl copy${color_norm}."
		notice "${color_alert}New, required section added to bedrock.conf.  Merge new config with existing and reboot.${color_norm}"
	fi

	if ver_cmp_first_newer "0.7.0beta6" "${current_version}"; then
		new_etcfs=true
		notice "Reworked ${color_cmd}brl retain${color_norm} options."
		notice "Made ${color_cmd}brl status${color_norm} more robust.  Many strata may now report as broken.  Reboot to remedy."
	fi

	if ver_cmp_first_newer "0.7.2" "${current_version}"; then
		new_etcfs=true
		new_crossfs=true
	fi

	if ver_cmp_first_newer "0.7.4" "${current_version}"; then
		new_crossfs=true
	fi

	if ver_cmp_first_newer "0.7.5" "${current_version}"; then
		new_crossfs=true
	fi

	if ver_cmp_first_newer "0.7.7beta1" "${current_version}"; then
		new_etcfs=true
	fi

	if "${new_crossfs}"; then
		notice "Updated crossfs.  Cannot restart Bedrock FUSE filesystems live.  Reboot to complete change."
	fi
	if "${new_etcfs}"; then
		notice "Updated etcfs.  Cannot restart Bedrock FUSE filesystems live.  Reboot to complete change."
	fi
	if "${new_conf}"; then
		notice "New reference configuration created at ${color_file}/bedrock/etc/bedrock.conf-${new_version}${color_norm}."
		notice "Compare against ${color_file}/bedrock/etc/bedrock.conf${color_norm} and consider merging changes."
		notice "Remove ${color_file}/bedrock/etc/bedrock.conf-${new_version}${color_norm} at your convenience."
	fi
}

case "${1:-}" in
"--hijack")
	shift
	hijack "$@"
	;;
"--update")
	update
	;;
"--force-update")
	update "force"
	;;
*)
	print_help
	;;
esac

trap '' EXIT
exit 0
