#!/bin/sh
#
# Quick and dirty script to track a `make release` build status.
#
# - Run `make release` in another terminal
# - While that's running, run this script. It should detect the `make` PID and follow its progress.
# - Estimate time remaining is an under-count as it assumes all archs complete in the same time, but some will complete earlier and drag-down the estimate

ARCHS="aarch64 armv7hl armv7l i386 i486 i586 i686 mips64el mipsel ppc ppc64 ppc64le s390x x86_64"
ARCH_COUNT="$(echo "${ARCHS}" | sed 's/ /\n/g' | wc -l)"

BUILD_COMPLETEDS="builddir libaio libattr libcap libfuse linux_headers lvm2 musl openssl uthash util-linux xz zlib zstd"
BUILD_COMPLETEDS_COUNT="$(echo "${BUILD_COMPLETEDS}" | sed 's/ /\n/g' | wc -l)"

BEDROCK_BIN_BINS="strat"
BEDROCK_BIN_BINS_COUNT="$(echo "${BEDROCK_BIN_BINS}" | sed 's/ /\n/g' | wc -l)"

BEDROCK_LIBEXEC_BINS="bouncer busybox crossfs curl dmsetup etcfs getfattr keyboard_is_present kmod lvm manage_tty_lock netselect plymouth-quit setcap setfattr zstd"
BEDROCK_LIBEXEC_BINS_COUNT="$(echo "${BEDROCK_LIBEXEC_BINS}" | sed 's/ /\n/g' | wc -l)"

HIJACK_SCRIPT_COUNT=1

CURRENT=0
MAX_COMPLETED=14 # ./build/${arch}/completed/ entries
MAX=$(( $BUILD_COMPLETEDS_COUNT + $BEDROCK_BIN_BINS_COUNT + $BEDROCK_LIBEXEC_BINS_COUNT + HIJACK_SCRIPT_COUNT ))
TOTAL=$(( ${MAX} * ${ARCH_COUNT} ))

MAKE_PID="$(ps -ef | grep 'make.*release' | grep -ve grep | grep -ve time | awk '{print$2}')"

get_worker_pid() {
	local arch="${1}"

	if ! [ -e /proc/${MAKE_PID}/task/${MAKE_PID}/children ]; then
		false
		return
	fi

	for pid in $(cat "/proc/${MAKE_PID}/task/${MAKE_PID}/children"); do
		if grep -q "${arch}" /proc/${pid}/cmdline; then
			echo ${pid}
			true
			return
		fi
	done
	false
}

get_arch_status() {
	local arch=${1}

	if [ -e bedrock-linux-*-"${arch}".sh ]; then
		printf "%-9s%d%%\n" "${arch}" "100"
		CURRENT=$(( $CURRENT + ${MAX} ))
		return
	fi

	if pid=$(get_worker_pid "${arch}"); then
		local worker="(${pid})"
	else
		local worker="(N/A)"
	fi

	if ! [ -d "./build/${arch}/completed" ]; then
		printf "%-9s%d%% %s\n" "${arch}" "0" "${worker}"
		return
	fi

	completed="$(ls -1 "./build/${arch}/completed" | wc -l)"

	if [ -e "./build/${arch}/bedrock/bin/strat" ]; then
		completed=$(( completed + 1))
	fi

	for bin in bouncer busybox crossfs curl dmsetup etcfs getfattr keyboard_is_present kmod lvm manage_tty_lock netselect plymouth-quit setcap setfattr zstd; do
		if [ -e "./build/${arch}/bedrock/libexec/${bin}" ]; then
			completed=$(( completed + 1))
		fi
	done

	# conftest run inside qemu sometimes stalls when it should pass
	local conftest_warn=""
	if conf_pid=$(ps -ef | grep "${arch}\>.*conftest" | grep -ve grep | awk '{print$2}' | grep .); then
		if etime="$(ps -p "${conf_pid}" -o etimes= 2>/dev/null)"; then
			if [ ${etime} -gt 5 ]; then
				conftest_warn=" STUCK IN CONFTEST KILL ${conf_pid}"
			fi
		fi
	fi

	printf "%-9s%d%% %s%s\n" "${arch}" "$(( $completed * 100 / ${MAX} ))" "${worker}" "${conftest_warn}"
	CURRENT=$(( $CURRENT + $completed ))
}

get_all_status() {
	for arch in $ARCHS; do
		get_arch_status "${arch}"
	done
	echo ---
	printf "%-9s%d%%\n" "TOTAL" "$(( $CURRENT * 100 / $TOTAL ))"

	local etime="$(ps -p "${MAKE_PID}" -o etimes= 2>/dev/null)"
	local remaining="$(( $etime * ($TOTAL - $CURRENT)/ $CURRENT ))"

	printf "Time elapsed: %02dh%02dm%02ds\n" $((etime/3600)) $(((etime%3600)/60)) $((etime%60))
	printf "Estimate remaining: %02dh%02dm%02ds\n" $((remaining/3600)) $(((remaining%3600)/60)) $((remaining%60))
}

while true; do
	s="$(get_all_status)"
	clear
	printf "%s" "$s"

	if ! [ -e /proc/${MAKE_PID}/autogroup ]; then
		echo ""
		echo ""
		echo "make exited"
		break
	fi

	sleep 1
done
