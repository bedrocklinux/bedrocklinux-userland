#!/bin/sh
#
# detect_arch.sh
#
#      This program is free software; you can redistribute it and/or
#      modify it under the terms of the GNU General Public License
#      version 2 as published by the Free Software Foundation.
#
# Copyright (c) 2012-2018 Daniel Thau <danthau@bedrocklinux.org>
#
# Detects which CPU architecture Bedrock Linux's build system is producing.
# Outputs two lines:
# - First line is Bedrock's name for the architecture.  This is used, for
# example, in the output installer/updater file name.
# - Second line is context expected in `file` output on one of the binaries.
# This is used to sanity check the resulting binaries are in fact of the
# expected type.

if ! gcc --version >/dev/null 2>&1; then
	echo "ERROR: gcc not found" >&2
	exit 1
fi

case "$(gcc -dumpmachine)" in
	aarch64-*)
		echo "aarch64"
		echo "ARM aarch64"
		;;
	arm-*abi)
		echo "armv7l"
		echo "EABI5"
		;;
	arm-*abihf)
		echo "armv7hl"
		echo "EABI5"
		;;
	i386-*)
		echo "i386"
		echo "Intel 80386"
		;;
	i486-*)
		echo "i486"
		echo "Intel 80386"
		;;
	i586-*)
		echo "i586"
		echo "Intel 80386"
		;;
	i686-*)
		echo "i686"
		echo "Intel 80386"
		;;
	mips-*)
		echo "mips"
		echo "MIPS32"
		;;
	mipsel-*)
		echo "mipsel"
		echo "MIPS32"
		;;
	mips64el-*)
		echo "mips64el"
		echo "MIPS64"
		;;
	powerpc64le-*)
		echo "ppc64le"
		echo "64-bit PowerPC"
		;;
	s390x-*)
		echo "s390x"
		echo "IBM s/390"
		;;
	x86_64-*)
		echo "x86_64"
		echo "x86-64"
		;;
	*)
		echo "Unrecognized CPU architecture"
		exit 1
		;;
esac
