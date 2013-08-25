### Bedrock Linux 1.0alpha4 Flopsie
### set_permissions.sh
# Git only tracks whether a given file is executable or not.  This script will
# go through and set proper permission ownership on all expected files in the
# core of a Bedrock Linux system.

if [ "$(id -u)" -ne 0 ]
then
	echo "Requires root"
	exit 1
fi

# Set permissions on directories
for dir in bedrock bedrock/bin bedrock/brpath bedrock/clients bedrock/etc bedrock/sbin bin boot dev home lib/firmware lib/modules proc root sbin sys tmp usr usr/bin usr/sbin var var/lib var/lib/urandom
do
	chown root:root $dir
	chmod 755 $dir
done
chmod a+rwxt tmp

# Set permissions on files
for file in bedrock/sbin/poweroff bedrock/sbin/halt bedrock/sbin/reboot bedrock/sbin/brp bedrock/sbin/brs bedrock/sbin/bru bedrock/sbin/shutdown bedrock/bin/brw bedrock/bin/brl bedrock/bin/bri bedrock/bin/brsh bedrock/etc/rc.conf bedrock/etc/brclients.conf etc/fstab etc/passwd etc/init.d/rcS etc/init.d/rcS.clients etc/init.d/rcK etc/init.d/rcK.clients etc/hosts etc/rc.local etc/shadow etc/hostname etc/mdev.conf etc/shells etc/lsb-release etc/issue etc/group etc/inittab etc/profile src/brc/brc.c src/brc/Makefile
do
	chown root:root $file
	chmod 744 $file
done
chmod go-r etc/shadow

# Set permissions on executables
for file in bin/*
do
	chown root:root $file
	# other permissions should be set by whatever puts the file in here
done
for file in bedrock/bin/*
do
	chown root:root $file
	chmod 755 $file
done
for file in bedrock/sbin/*
do
	chown root:root $file
	chmod 744 $file
done
if [ -e bedrock/bin/brc ]
then
	setcap cap_sys_chroot=ep bedrock/bin/brc
fi
