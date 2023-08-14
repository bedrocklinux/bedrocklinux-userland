#!/bedrock/libexec/busybox sh
#
# Some systemd version circa systemd 237 in 2018 was found to have difficulty
# unmounting FUSE filesystems which resulted in shutdown delays.  Bedrock
# worked around this with a unit file that assists in unmounting Bedrock's FUSE
# filesytems.
#
# Some systemd version circa systemd 245 in 2020 was found to have improved the
# FUSE filesystem handling, but changed something which resulted in Bedrock's
# FUSE assistance causing a shutdown delay.
#
# Thus, we only want to assist unmounting for pre-245 systemd versions.

if command -v systemctl >/dev/null 2>&1 && [ "$(systemctl --version | awk '{print$2;exit}')" -lt 245 ]; then
	umount -l /etc /bedrock/strata/*/etc /bedrock/cross /bedrock/strata/*/bedrock/cross
fi

# Some systemd version circa systemd 254 in 2023 was found to have difficulty
# unmounting some mount points within the bedrock stratum for some users.
# Specifics were difficult to nail down.  Unmount everything in the bedrock
# stratum en mass as a work-around.
for m in $(awk '{print$2}' /proc/mounts | grep '^/bedrock/strata/bedrock/'); do
	mount --make-private "${m}"
	umount -l "${m}"
done
