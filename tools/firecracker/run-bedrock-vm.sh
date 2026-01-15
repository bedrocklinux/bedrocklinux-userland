#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$root_dir/../.." && pwd)
out_dir="$root_dir/out"
include_dir="$root_dir/include-in-vm"

alpine_version="3.19.1"
alpine_arch="x86_64"
alpine_branch="v${alpine_version%.*}"
rootfs_size="20G"

guest_ip="172.16.0.2"
guest_netmask="255.255.255.0"
guest_netmask_bits="24"
guest_gateway="172.16.0.1"
dns_server="1.1.1.1"

tap_dev="fc0"
tap_mac="AA:FC:00:00:00:01"

ncpus="2"
mem_mib="2048"
kernel_opts="console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw rootfstype=ext4"

tarball="$out_dir/alpine-minirootfs-${alpine_version}-${alpine_arch}.tar.gz"
rootfs_img="$out_dir/vm-rootfs.ext4"
kernel_img="$out_dir/vm-vmlinuz"
initrd_img="$out_dir/vm-initramfs"
hijack_marker="$out_dir/vm-is-hijacked"

api_sock="$out_dir/firecracker.sock"
config_path="$out_dir/firecracker-config.json"

apk_packages="openrc busybox ifupdown-ng iproute2 linux-virt"

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "Missing required command: $1" >&2
		exit 1
	}
}

fetch() {
	local url="$1"
	local dest="$2"

	if command -v curl >/dev/null 2>&1; then
		curl -fL -o "$dest" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -O "$dest" "$url"
	else
		echo "Need curl or wget to download $url" >&2
		exit 1
	fi
}

encode_b64() {
	if command -v base64 >/dev/null 2>&1; then
		printf '%s' "$1" | base64 | tr -d '\n'
		return 0
	fi
	if command -v python3 >/dev/null 2>&1; then
		printf '%s' "$1" | python3 -c 'import base64, sys; sys.stdout.write(base64.b64encode(sys.stdin.buffer.read()).decode("ascii"))'
		return 0
	fi
	return 1
}

sudo_cmd=""
if [ "$(id -u)" -ne 0 ]; then
	if command -v sudo >/dev/null 2>&1; then
		sudo_cmd="sudo"
	else
		echo "Need root or sudo to configure TAP networking and build rootfs" >&2
		exit 1
	fi
fi
owner_user="${SUDO_USER:-$(id -un)}"
owner_uid=$(id -u "$owner_user")
owner_gid=$(id -g "$owner_user")

abs_path() {
	local path="$1"
	if [ -d "$path" ]; then
		(cd "$path" && pwd)
	else
		(cd "$(dirname "$path")" && printf '%s/%s\n' "$(pwd)" "$(basename "$path")")
	fi
}

find_installer() {
	local candidates
	candidates=("$repo_root"/bedrock-linux-*-x86_64.sh)
	if [ "${candidates[0]}" = "$repo_root/bedrock-linux-*-x86_64.sh" ]; then
		echo "No bedrock-linux-*-x86_64.sh found in repo root" >&2
		exit 1
	fi
	printf '%s\n' "${candidates[@]}" | sort -V | tail -n 1
}

sync_installer() {
	local installer
	local installer_name
	local dest
	local old

	installer=$(find_installer)
	installer_name=$(basename "$installer")
	dest="$include_dir/$installer_name"

	# Check if already up-to-date
	if [ -f "$dest" ] && [ ! "$installer" -nt "$dest" ]; then
		return 0
	fi

	# Remove old versioned installers before copying new one
	for old in "$include_dir"/bedrock-linux-*-x86_64.sh; do
		if [ -f "$old" ] && [ "$old" != "$dest" ]; then
			rm -f "$old"
		fi
	done

	sync_include_file "$installer" "$dest" 0700
}

sync_include_file() {
	local src="$1"
	local dest="$2"
	local mode="$3"

	if [ ! -f "$src" ]; then
		return 1
	fi

	if [ "$src" != "$dest" ]; then
		if [ ! -f "$dest" ] || [ "$src" -nt "$dest" ]; then
			cp "$src" "$dest"
		else
			return 0
		fi
	fi

	chmod "$mode" "$dest"
	if [ "$(id -u)" -eq 0 ]; then
		chown "$owner_uid:$owner_gid" "$dest"
	fi
}

latest_mtime_in_dir() {
	local dir="$1"
	local latest=0
	local ts

	if [ ! -d "$dir" ]; then
		printf '%s\n' "$latest"
		return 0
	fi

	while IFS= read -r -d '' file; do
		ts=$(stat -c %Y "$file")
		if [ "$ts" -gt "$latest" ]; then
			latest=$ts
		fi
	done < <(find "$dir" -type f -print0)

	printf '%s\n' "$latest"
}

ensure_include_dir() {
	mkdir -p "$include_dir"
	sync_installer
}

maybe_rebuild_rootfs() {
	local rootfs_ts
	local script_ts
	local installer
	local installer_ts
	local include_ts
	local tarball_ts

	if [ ! -f "$rootfs_img" ]; then
		return 0
	fi

	rootfs_ts=$(stat -c %Y "$rootfs_img")
	script_ts=$(stat -c %Y "$0")
	installer=$(find_installer)
	installer_ts=$(stat -c %Y "$installer")
	include_ts=$(latest_mtime_in_dir "$include_dir")
	tarball_ts=$(stat -c %Y "$tarball")

	if [ "$script_ts" -gt "$rootfs_ts" ] \
		|| [ "$installer_ts" -gt "$rootfs_ts" ] \
		|| [ "$include_ts" -gt "$rootfs_ts" ] \
		|| [ "$tarball_ts" -gt "$rootfs_ts" ]; then
		rm -f "$rootfs_img" "$kernel_img" "$initrd_img" "$hijack_marker"
	fi
}

ensure_tarball() {
	local url

	if [ -f "$tarball" ]; then
		return 0
	fi
	mkdir -p "$out_dir"
	url="https://dl-cdn.alpinelinux.org/alpine/${alpine_branch}/releases/${alpine_arch}/$(basename "$tarball")"
	fetch "$url" "$tarball"
}

ensure_rootfs() {
	local mount_dir
	local extra_mounts
	local kernel_src
	local initrd_src
	local extractor

	if [ -f "$rootfs_img" ]; then
		return 0
	fi

	need_cmd mkfs.ext4
	mkdir -p "$out_dir"

	truncate -s "$rootfs_size" "$rootfs_img"
	mkfs.ext4 -F "$rootfs_img" >/dev/null

	mount_dir=$(mktemp -d "$out_dir/mnt.XXXX")
	extra_mounts=()
	cleanup() {
		for mount_path in "${extra_mounts[@]}"; do
			if grep -qs " $mount_path " /proc/mounts; then
				$sudo_cmd umount "$mount_path"
			fi
		done
		if grep -qs " $mount_dir " /proc/mounts; then
			$sudo_cmd umount "$mount_dir"
		fi
		rmdir "$mount_dir"
	}
	trap cleanup EXIT

	$sudo_cmd mount -o loop "$rootfs_img" "$mount_dir"
	$sudo_cmd tar -xzf "$tarball" -C "$mount_dir"

	echo "nameserver $dns_server" | $sudo_cmd tee "$mount_dir/etc/resolv.conf" >/dev/null

	$sudo_cmd mount -t proc none "$mount_dir/proc"
	extra_mounts+=("$mount_dir/proc")
	$sudo_cmd mount --bind /dev "$mount_dir/dev"
	extra_mounts+=("$mount_dir/dev")

	$sudo_cmd chroot "$mount_dir" /sbin/apk --no-progress --update-cache add $apk_packages

	$sudo_cmd ln -sf /bin/busybox "$mount_dir/sbin/init"
	$sudo_cmd chroot "$mount_dir" /sbin/rc-update add local default || true
	$sudo_cmd chroot "$mount_dir" /sbin/rc-update add networking default || true
	for cmd in halt poweroff shutdown; do
		$sudo_cmd ln -sf /sbin/reboot "$mount_dir/sbin/$cmd"
	done

	$sudo_cmd mkdir -p "$mount_dir/etc/local.d"
	cat <<'EOF' | $sudo_cmd tee "$mount_dir/etc/local.d/bedrock-hijack.start" >/dev/null
#!/bin/sh
set -eu

installer_dir=/root/include-in-vm
done_marker=/root/.bedrock-hijack-done
log=/root/bedrock-hijack.log
one_shot_log_dir=/root/one-shot-vm-command-logs
cmd_file=/root/.bedrock-cmd
cmd_shutdown_file=/root/.bedrock-cmd-shutdown

console_out=/dev/console
if [ ! -w "$console_out" ]; then
	console_out=/dev/ttyS0
fi
if [ ! -w "$console_out" ]; then
	console_out=/dev/null
fi

log_console() {
	printf '%s\n' "$*" | tee -a "$log" >"$console_out"
}

decode_b64() {
	if command -v base64 >/dev/null 2>&1; then
		printf '%s' "$1" | base64 -d 2>/dev/null
		return $?
	fi
	if command -v busybox >/dev/null 2>&1; then
		printf '%s' "$1" | busybox base64 -d 2>/dev/null
		return $?
	fi
	return 1
}

find_installer() {
	for f in "$installer_dir"/bedrock-linux-*-x86_64.sh; do
		if [ -x "$f" ]; then
			printf '%s\n' "$f"
			return 0
		fi
	done
	return 1
}

cmd_b64=$(sed -n 's/.*bedrock_cmd=\([^ ]*\).*/\1/p' /proc/cmdline || true)
shutdown_req=0
if grep -q 'bedrock_cmd_shutdown=1' /proc/cmdline; then
	shutdown_req=1
fi

if [ -f "$done_marker" ]; then
	decoded=""
	if [ -f "$cmd_file" ]; then
		decoded=$(cat "$cmd_file")
		rm -f "$cmd_file"
		if [ -f "$cmd_shutdown_file" ]; then
			shutdown_req=1
			rm -f "$cmd_shutdown_file"
		fi
	elif [ -n "$cmd_b64" ]; then
		decoded=$(decode_b64 "$cmd_b64") || decoded=""
	fi

	if [ -n "$decoded" ]; then
		mkdir -p "$one_shot_log_dir"
		log="$one_shot_log_dir/one-shot-$(date -u +%Y%m%d-%H%M%S)-$$.log"
		log_console ""
		log_console "--- BEGIN: one-shot VM command ---"
		log_console "$decoded"
		log_console "--- OUTPUT ---"
		(cd /root && sh -c "$decoded") 2>&1 | tee -a "$log" >"$console_out" || true
		log_console "--- END: one-shot VM command ---"
		log_console ""
		if [ "$shutdown_req" -eq 1 ]; then
			reboot -f
		fi
	elif [ -n "$cmd_b64" ]; then
		log_console "Failed to decode bedrock_cmd"
	fi
	exit 0
fi

if [ -n "$cmd_b64" ] && [ ! -f "$cmd_file" ]; then
	decoded=$(decode_b64 "$cmd_b64") || decoded=""
	if [ -n "$decoded" ]; then
		printf '%s\n' "$decoded" >"$cmd_file"
		if [ "$shutdown_req" -eq 1 ]; then
			touch "$cmd_shutdown_file"
		fi
		log_console "Queued bedrock_cmd for post-hijack boot: $decoded"
	else
		log_console "Failed to decode bedrock_cmd before hijack"
	fi
fi

installer=$(find_installer) || {
	log_console "No installer found matching $installer_dir/bedrock-linux-*-x86_64.sh"
	exit 1
}

: >"$log"
log_console "Starting Bedrock hijack using $installer..."
echo "Not reversible!" | "$installer" --hijack >>"$log" 2>&1

if [ ! -f /bedrock/etc/bedrock.conf ]; then
	log_console "bedrock.conf not found after hijack"
	exit 1
fi

sed 's/^timeout =.*$/timeout = 0/' /bedrock/etc/bedrock.conf \
	>/bedrock/etc/bedrock.conf~new
mv /bedrock/etc/bedrock.conf~new /bedrock/etc/bedrock.conf

touch "$done_marker"
sync
reboot -f
EOF
	$sudo_cmd chmod 0755 "$mount_dir/etc/local.d/bedrock-hijack.start"

	if [ -f "$mount_dir/etc/inittab" ] \
		&& ! $sudo_cmd grep -q '^ttyS0::' "$mount_dir/etc/inittab"; then
		echo 'ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100' \
			| $sudo_cmd tee -a "$mount_dir/etc/inittab" >/dev/null
	fi

	if [ -f "$mount_dir/etc/securetty" ] \
		&& ! $sudo_cmd grep -q '^ttyS0$' "$mount_dir/etc/securetty"; then
		echo 'ttyS0' | $sudo_cmd tee -a "$mount_dir/etc/securetty" >/dev/null
	fi

	if [ -f "$mount_dir/etc/shadow" ]; then
		$sudo_cmd sed -i 's/^root:[^:]*:/root::/' "$mount_dir/etc/shadow"
	fi

	$sudo_cmd rm -rf "$mount_dir/root/include-in-vm"
	$sudo_cmd mkdir -p "$mount_dir/root/include-in-vm"
	if [ -n "$(ls -A "$include_dir" 2>/dev/null)" ]; then
		tar -C "$include_dir" -cf - . | $sudo_cmd tar -C "$mount_dir/root/include-in-vm" -xpf -
	fi

	$sudo_cmd tee "$mount_dir/etc/network/interfaces" >/dev/null <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
	address $guest_ip
	netmask $guest_netmask
	gateway $guest_gateway
EOF

	echo "bedrock-fc" | $sudo_cmd tee "$mount_dir/etc/hostname" >/dev/null

	kernel_src=""
	initrd_src=""
	for candidate in "$mount_dir/boot/vmlinuz-virt" "$mount_dir"/boot/vmlinuz-*; do
		if [ -f "$candidate" ]; then
			kernel_src="$candidate"
			break
		fi
	done
	for candidate in "$mount_dir/boot/initramfs-virt" "$mount_dir"/boot/initramfs-*; do
		if [ -f "$candidate" ]; then
			initrd_src="$candidate"
			break
		fi
	done

	if [ -z "$kernel_src" ]; then
		echo "Kernel not found in rootfs /boot; linux-virt install failed" >&2
		exit 1
	fi

	if [ -z "$initrd_src" ]; then
		echo "Initramfs not found in rootfs /boot; linux-virt install failed" >&2
		exit 1
	fi

	need_cmd readelf
	extractor="$repo_root/vendor~/linux_headers/scripts/extract-vmlinux"
	if [ ! -x "$extractor" ]; then
		echo "Missing extract-vmlinux at $extractor" >&2
		exit 1
	fi

	if ! $sudo_cmd "$extractor" "$kernel_src" >"$kernel_img" 2>/dev/null; then
		echo "Failed to extract vmlinux from $kernel_src" >&2
		exit 1
	fi

	$sudo_cmd cp "$initrd_src" "$initrd_img"
	if [ -n "$sudo_cmd" ]; then
		$sudo_cmd chown "$owner_uid:$owner_gid" "$kernel_img" "$initrd_img"
	fi
	$sudo_cmd chmod 0644 "$kernel_img" "$initrd_img"

	cleanup
	trap - EXIT
}

ensure_kernel() {
	local mount_dir
	local kernel_src
	local initrd_src
	local extractor

	if [ -f "$kernel_img" ] && [ -f "$initrd_img" ]; then
		if [ "$rootfs_img" -nt "$kernel_img" ] || [ "$rootfs_img" -nt "$initrd_img" ]; then
			rm -f "$kernel_img" "$initrd_img"
		else
			return 0
		fi
	fi
	if [ ! -f "$rootfs_img" ]; then
		ensure_rootfs
		return 0
	fi

	need_cmd readelf
	extractor="$repo_root/vendor~/linux_headers/scripts/extract-vmlinux"
	if [ ! -x "$extractor" ]; then
		echo "Missing extract-vmlinux at $extractor" >&2
		exit 1
	fi

	mount_dir=$(mktemp -d "$out_dir/mnt.XXXX")
	cleanup() {
		if grep -qs " $mount_dir " /proc/mounts; then
			$sudo_cmd umount "$mount_dir"
		fi
		rmdir "$mount_dir"
	}
	trap cleanup EXIT

	$sudo_cmd mount -o loop "$rootfs_img" "$mount_dir"
	kernel_src=""
	initrd_src=""
	for candidate in "$mount_dir/boot/vmlinuz-virt" "$mount_dir"/boot/vmlinuz-*; do
		if [ -f "$candidate" ]; then
			kernel_src="$candidate"
			break
		fi
	done
	for candidate in "$mount_dir/boot/initramfs-virt" "$mount_dir"/boot/initramfs-*; do
		if [ -f "$candidate" ]; then
			initrd_src="$candidate"
			break
		fi
	done

	if [ -z "$kernel_src" ] || [ -z "$initrd_src" ]; then
		echo "Kernel or initramfs missing in rootfs; delete $rootfs_img to rebuild" >&2
		exit 1
	fi

	if ! $sudo_cmd "$extractor" "$kernel_src" >"$kernel_img" 2>/dev/null; then
		echo "Failed to extract vmlinux from $kernel_src" >&2
		exit 1
	fi
	$sudo_cmd cp "$initrd_src" "$initrd_img"
	if [ -n "$sudo_cmd" ]; then
		$sudo_cmd chown "$owner_uid:$owner_gid" "$kernel_img" "$initrd_img"
	fi
	$sudo_cmd chmod 0644 "$kernel_img" "$initrd_img"

	cleanup
	trap - EXIT
}

ensure_tap() {
	local out_iface

	need_cmd ip
	need_cmd iptables

	if ! ip link show "$tap_dev" >/dev/null 2>&1; then
		$sudo_cmd ip tuntap add dev "$tap_dev" mode tap
	fi

	if ! ip addr show dev "$tap_dev" | grep -q "$guest_gateway/$guest_netmask_bits"; then
		$sudo_cmd ip addr add "$guest_gateway/$guest_netmask_bits" dev "$tap_dev" 2>/dev/null || true
	fi
	$sudo_cmd ip link set "$tap_dev" up

	$sudo_cmd sysctl -w net.ipv4.ip_forward=1 >/dev/null

	out_iface=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {print $5; exit}')
	if [ -z "$out_iface" ]; then
		echo "Unable to detect outbound interface for NAT" >&2
		exit 1
	fi

	$sudo_cmd iptables -t nat -C POSTROUTING -s 172.16.0.0/24 -o "$out_iface" -j MASQUERADE 2>/dev/null \
		|| $sudo_cmd iptables -t nat -A POSTROUTING -s 172.16.0.0/24 -o "$out_iface" -j MASQUERADE
	$sudo_cmd iptables -C FORWARD -i "$tap_dev" -o "$out_iface" -j ACCEPT 2>/dev/null \
		|| $sudo_cmd iptables -A FORWARD -i "$tap_dev" -o "$out_iface" -j ACCEPT
	$sudo_cmd iptables -C FORWARD -i "$out_iface" -o "$tap_dev" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
		|| $sudo_cmd iptables -A FORWARD -i "$out_iface" -o "$tap_dev" -m state --state RELATED,ESTABLISHED -j ACCEPT
}

run_firecracker() {
	local cmd_b64="${1:-}"
	local boot_args="$kernel_opts"

	if [ -n "$cmd_b64" ]; then
		boot_args="$boot_args bedrock_cmd=$cmd_b64 bedrock_cmd_shutdown=1"
	fi

	rm -f "$api_sock"
	cat >"$config_path" <<EOF
{
  "boot-source": {
    "kernel_image_path": "$(abs_path "$kernel_img")",
    "initrd_path": "$(abs_path "$initrd_img")",
    "boot_args": "$boot_args"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "$(abs_path "$rootfs_img")",
      "is_root_device": true,
      "is_read_only": false
    }
  ],
  "machine-config": {
    "vcpu_count": $ncpus,
    "mem_size_mib": $mem_mib,
    "smt": false
  },
  "network-interfaces": [
    {
      "iface_id": "eth0",
      "host_dev_name": "$tap_dev",
      "guest_mac": "$tap_mac"
    }
  ]
}
EOF

	if [ -n "$sudo_cmd" ]; then
		$sudo_cmd firecracker --api-sock "$api_sock" --config-file "$config_path"
	else
		firecracker --api-sock "$api_sock" --config-file "$config_path"
	fi
}

main() {
	local cmd_b64

	need_cmd firecracker
	mkdir -p "$out_dir"

	ensure_include_dir
	ensure_tarball
	maybe_rebuild_rootfs
	ensure_rootfs
	ensure_kernel
	ensure_tap

	cmd_b64=""
	if [ "$#" -gt 0 ]; then
		cmd_b64=$(encode_b64 "$*") || {
			echo "Need base64 or python3 to encode command" >&2
			exit 1
		}
	fi

	if [ ! -f "$hijack_marker" ]; then
		run_firecracker ""
		touch "$hijack_marker"
	fi

	if [ -n "$cmd_b64" ]; then
		run_firecracker "$cmd_b64"
	else
		run_firecracker ""
	fi
}

main "$@"
