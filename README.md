Bedrock Linux 1.0beta2 Nyla
===========================

This is the bulk of the userland for Bedrock Linux.  Further information can be
found at [http://bedrocklinux.org](http://bedrocklinux.org).

Specifically, this is the README and files for the second beta, Nyla.  More
information about this release of Bedrock Linux can be found here:
[http://bedrocklinux.org/1.0beta2/](http://bedrocklinux.org/1.0beta2/).

------------------
Build dependencies
------------------

In addition to the third party source code listed below, building Bedrock Linux
requires:

- Standard UNIX tools such as sh, grep, sed, awk, and tar
- optionally gzip
- gcc (EXCEPT 4.8.X and 4.9.0 - older ones such as gcc 4.7.X or newer ones such
  as 4.9.1+ should be fine.)
- autoconf (for FUSE)
- automake (for FUSE)
- libtool (for FUSE)
- gettext (for FUSE)

----------------------
Third party souce code
----------------------

If make does not see the required third party source code it will attempt to
automatically require it via git.  If you do not want this, acquire the source
code for the following projects:

- busybox (tested with version 1.23.1, but newer should be fine)
- fuse (version 2.9.X)
- libattr (latest version)
- libcap (latest version)
- the Linux kernel (tested with 4.1, but newer should be fine)
- musl libc (latest from 1.0.X branch)

then unpackage and place in src/ with the following names:

- src/busybox/
- src/fuse/
- src/libattr/
- src/libcap/
- src/linux_headers/
- src/musl/

Then, create a file named ".success_retreiving_source" in the directory, like
so:

- src/busybox/.success_retreiving_source
- src/fuse/.success_retreiving_source
- src/libattr/.success_retreiving_source
- src/libcap/.success_retreiving_source
- src/linux_headers/.success_retreiving_source
- src/musl/.success_retreiving_source

--------
Building
--------

To build a gzip'd tarball of the Bedrock Linux userland, ready to be installed
via untar'ing, run:

    make

This will pull in third party source code (if you did not already), compile,
create the tarball and gzip it.

To build just a tarball - skip gzip'ing it - run

    make tarball

To clean up a build, run

    make clean

To remove (either manually or automatically acquired) third party source code,
run

    make clean_source_all

------------
Installation
------------

To install (very brief overview - see release's website for details), method A:

- Install some other distro to handle partitioning and bootloader (as well as
  things such as full disk encryption).
- Boot into other distro, then run:

    cd / && tar xvf <path-to-bedrock-tarball>

- Acquire other distros' userlands into /bedrock/strata/
- Configure Bedrock Linux
- Configure bootloader to use init=/bedrock/sbin/brn
- Reboot into Bedrock Linux.

To install (very brief overview - see release's website for details), method B:

- Manually partition and set up desired bootloader, as well as things such as
  full disk encryption.
- Mount partition somewhere (e.g. /mnt/bedrock)
- Run:

    cd <mount-point> && tar xvf <path-to-bedrock-tarball>

- Acquire other distros' userlands into <mount>/bedrock/strata/
- Configure Bedrock Linux
- Configure bootloader to use init=/bedrock/sbin/brn
- Reboot into Bedrock Linux.
