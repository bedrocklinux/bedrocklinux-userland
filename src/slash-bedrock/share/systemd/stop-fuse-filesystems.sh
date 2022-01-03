#!/bedrock/libexec/busybox sh
#
# Some systemd version circa systemd 237 in 2018 was found to have difficulty
# unmounting FUSE filesystems which resulted in shutdown delays.  Bedrock
# worked around this with a unit file that assists in unmounting Bedrock's FUSE
# filesytems.
#
# Some systemd version circa systemd 247 in 2020 was found to have improved the
# FUSE filesystem handling, but changed something which resulted in Bedrock's
# FUSE assistance causing a shutdown delay.
#
# Thus, we only want to assist unmounting for pre-247 systemd versions.

if command -v systemctl >/dev/null 2>&1 && [ "$(systemctl --version | awk '{print$2;exit}')" -lt 247 ]; then
	umount -l /etc /bedrock/strata/*/etc /bedrock/cross /bedrock/strata/*/bedrock/cross
fi
