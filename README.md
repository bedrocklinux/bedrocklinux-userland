Bedrock Linux 1.0alpha4 Flopsie Userland
========================================

This is the bulk of the userland for Bedrock Linux.  Further information can be
found at [http://bedrocklinux.org](http://bedrocklinux.org).

Specifically, this is the README and files for the fourth alpha, Flopsie.  More
information about this release of Bedrock Linux can be found here:
[http://bedrocklinux.org/1.0alpha4/](http://bedrocklinux.org/1.0alpha4/).

You should probably read everything there before continuing to do anything with
these files, if you have not already.  The instructions in this README are not
sufficient on their own.

Installation
============

This README is not intended to be sufficient alone.  More detailed instructions
should be found here: http://bedrocklinux.org/1.0alpha4/install.html

Briefly, you need to do the following to install Bedrock Linux 1.0alpha4 using
the files bundled with this README:

- Partition, format, and mount the filesystem(s) on which you would like to
  install Bedrock Linux.  The location on which you've mounted the filesystem
  which will become the root filesystem of the new system will be referred to
  as $BRINSTALL.
- mv/untar/git-clone/etc the userland files/tarball/repository (which should
  include this README) into $BRINSTALL so that this README file will be on the
  root of the Bedrock Linux install.
- Place the source for required third-party software (listed below) and place
  them in "$BRINSTALL/src/".  This directory should already contain the source
  for Bedrock Linux utilities such as brc and bru - place the third-party
  software along side these directories.  If your system has the GNU tar (which
  will automatically detect and decompress compressed tarballs), you can leave
  (compressed) tarballs in the '$BRINSTALL/src" directory.  Otherwise, you will
  need to decompress these and leave directories in "$BRINSTALL/src".
  - musl (NEWER than 0.9.14 - such as git HEAD) from
    http://www.musl-libc.org/download.html
    or
    git clone git://git.musl-libc.org/musl
  - Linux kernel from
    https://www.kernel.org
  - FUSE (NEWER than 2.9.3 - probably 3.X or git HEAD) from
    http://sourceforge.net/projects/fuse/files/
    or
    git clone git://git.code.sf.net/p/fuse/fuse fuse-fuse
  - busybox (NEWER than 1.21.1 - such as git HEAD) from
    http://www.busybox.net
    or
    git clone git://busybox.net/busybox.git
  - linux capabilities from
    git clone git://git.kernel.org/pub/scm/linux/kernel/git/morgan/libcap.git
    using a specific commit
    git checkout 056ffb0bd25d91ffbcb83c521fc4d3d9904ec4d4
- Run the following:
  - cd $BRINSTALL
  - ./installer make all
  - sudo ./installer install all
- If you run into any errors, see
  "/tmp/bedrocklinux-installer-tmp-$(whoami)/log".  You may simply be missing a
  build dependency.
- Acquire the following kernel related files (such as from another Linux
  distribution, or build them yourself) and place them accordingly:
  - A kernel image at $BRINSTALL/boot/
  - Kernel modules at $BRINSTALL/lib/modules/$KERNEL-VERSION/
  - Optionally (may be required depending on the system and kernel image) an
    initrd/initramfs at $BRINSTALL/boot/
  - Optionally, a system map file at $BRINSTALL/boot/
  - Optionally, a .config file for the kernel at $BRINSTALL/boot/
  - Optionally, firmware for your hardware in /lib/firmware
- Acquire initial client distributions.
- Configure the system as described at http://bedrocklinux.org/1.0alpha4/configure.html
- Install a bootloader of your choice.

Assistance
==========
If you run into any trouble, feel free to seek help via IRC in #bedrock on
freenode (https://webchat.freenode.net/?channels=bedrock).
