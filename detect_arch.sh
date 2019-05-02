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

case $(uname -m) in
	aarch64)
		echo "aarch64"
		echo "aarch64"
		;;
	armv7l)
		if gcc -dumpmachine | grep -q "gnueabihf$"; then
			echo "armv7hl"
			echo "EABI5"
		else
			echo "armv7l"
			echo "EABI5"
		fi
		;;
	mips)
		if gcc -dumpmachine | grep -q "^mipsel"; then
			echo "mipsel"
			echo "MIPS32"
		else
			echo "mips"
			echo "MIPS32"
		fi
		;;
	mips64)
		if gcc -dumpmachine | grep -q "^mips64el"; then
			echo "mips64el"
			echo "MIPS64"
		else
			echo "mips64"
			echo "MIPS64"
		fi
		;;
	ppc64le)
		echo "ppc64le"
		echo "PowerPC"
		;;
	s390x) 
		echo "s390x"
		echo "S/390"
		;;
	i*86) 
		echo "x86"
		echo "80386"
		;;
	x86_64)
		if gcc -dumpmachine | grep -q "^i.86"; then
			echo "x86"
			echo "80386"
		else
			echo "x86_64"
			echo "x86-64"
		fi
		;;
	*) echo "Unrecognized CPU architecture \"$(uname -m)\"" 2>&1 ; exit 1;;
esac
