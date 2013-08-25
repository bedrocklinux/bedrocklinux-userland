### Bedrock Linux 1.0alpha4 Flopsie
### make_dirs.sh
# Since git will not track empty directories, this script is used to make the
# directories which should be in place.  It also makes directories which are
# likely populatd and thus should be tracked by git as well, just in case.

mkdir -p bedrock/bin
mkdir -p bedrock/brpath
mkdir -p bedrock/clients
mkdir -p bedrock/etc
mkdir -p bedrock/sbin
mkdir -p bin
mkdir -p boot
mkdir -p dev
mkdir -p home
mkdir -p lib/firmware
mkdir -p lib/modules
mkdir -p proc
mkdir -p root
mkdir -p sbin
mkdir -p sys
mkdir -p tmp
mkdir -p usr/bin
mkdir -p usr/sbin
mkdir -p var/lib/urandom
