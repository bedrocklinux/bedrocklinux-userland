# Bedrock Linux Makefile
#
#      This program is free software; you can redistribute it and/or
#      modify it under the terms of the GNU General Public License
#      version 2 as published by the Free Software Foundation.
#
# Copyright (c) 2012-2019 Daniel Thau <danthau@bedrocklinux.org>
#
# This creates a script which can be used to install or update a Bedrock Linux
# system.
#
# First install the necessary build dependencies:
#
# - Standard UNIX utilities: grep, sed, awk, etc.
# - autoconf
# - autopoint
# - bison
# - fakeroot
# - gcc 4.9.1 or newer
# - git 1.8 or newer
# - gpg (optional)
# - gzip
# - libtool
# - make
# - meson 0.38 or newer
# - ninja-build
# - pkg-config
# - rsyn
# - rsync
# - udev (build-time only)
#
# Ensure you have internet access (to fetch upstream dependencies), then run:
#
#     make GPGID=<gpg-id-with-which-to-sign>
#
# to build a signed install/update script or
#
#     make SKIPSIGN=true
#
# to build an unsigned install/update script.
#
# To build for all supported architectures on a Bedrock Linux system, run:
#
#     make release-build-environment
#
# as root to set up various build strata, and finally
#
#     make GPGID=<gpg-id-with-which-to-sign> release
#
# This build system attempts to strike a balance between being overly dependent
# on the host system at the expense of portability, and maximizing portability
# at the expense of build time.  Build tools such as gcc and meson are taken
# from the host system rather than recompiled.  Upstream code which ends up
# within the output script is compiled from source.
#
# In order to ensure portability, the code base is compiled against musl.  To
# do so easily, this uses the `musl-gcc` wrapper, which in turn means gcc is
# required.  Effort to support other compilers, such a clang, should be made at
# some point in the future.
#
# Directory layout:
#
# - src/ contains Bedrock's own code, in contrast to upstream libraries.
# - src/slash-bedrock/ contains all files and directories which will populate
#   the eventual install's /bedrock/ directory except binary executables which
#   must be compiled.
# - src/installer/ contains the actual installer script.  The build system will
#   embed the eventual system files into the installation script.
# - Other src/ directories correspond to source for binary executables.  These
#   binaries will be included in the slash-bedrock structure embedded within the
#   installation script.
# - vendor/ (initially absent) will contain upstream build dependencies.  The
#   build system will automatically fetch these and populate vendor/ accordingly.
#   The build system will attempt to automatically get the latest stable version
#   and may occasionally fail if an upstream component changes too drastically.
#   This is purposeful; it will serve as a canary indicating developer attention
#   is required and is preferable to distributing outdated upstream components
#   which may contain security vulnerabilities.
# - vendor/*/.success_fetching_source files indicate that the given vendor
#   component's files have been successfully acquired.  This is used to properly
#   handle interrupted downloads.
# - build/ (initially absent) will contain intermediate build output
# - build/<arch>/ separates build artifacts per-CPU-architecture which allows
#   parallelized builds for different CPU architectures.  See the "release"
#   recipe.
# - build/<arch>/support/ will contain build-time support code and will not
#   directly end up in the resulting install.
# - build/<arch>/bedrock/ will contain files which eventually end up in the
#   installed system's /bedrock/ directory.  This will be populated by
#   src/slash-bedrock/ contents and the various src/ binaries.
# - build/<arch>/completed/ will contain files which indicate various build
#   steps have been completed.  These are for build steps that may produce many
#   output files as an alternative to verbosely tracking each individual output
#   file.
# - Makefile service as the build system.
# - `*.md` files service as documentation.
#
# Many dependencies have deep paths which may be awkward to type at a command
# line.  For these, shorter recipe aliases are created.
#
# Where possible, recipes which acquire upstream source should attempt to get
# the latest stable version.  This does risk the possibility that an upstream
# change breaks the build system, but this is preferable to acquiring outdated,
# insecure files.  If the build system breaks, someone will be notified, while
# a missed security update may go unnoticed for a while.
#
# To format the code base, install:
#
# - shfmt (https://github.com/mvdan/sh)
# - indent (GNU)
#
# and run
#
#     make format
#
# To run various static analysis tools against the code base, install
#
# - shellcheck
# - cppcheck
# - clang
# - gcc
# - scan-build (usually distributed with clang)
# - shfmt (https://github.com/mvdan/sh)
# - indent (GNU)
# - uthash
# - libfuse3
# - libcap
# - libattr
#
# and run
#
#     make check

BEDROCK_VERSION=0.7.11beta2
CODENAME=Poki
ARCHITECTURE=$(shell ./detect_arch.sh | head -n1)
FILE_ARCH_NAME=$(shell ./detect_arch.sh | tail -1)
RELEASE=Bedrock Linux $(BEDROCK_VERSION) $(CODENAME)
INSTALLER=bedrock-linux-$(BEDROCK_VERSION)-$(ARCHITECTURE).sh

RELEASE_CFLAGS=-O2

ROOT=$(shell pwd)
BUILD=$(ROOT)/build/$(ARCHITECTURE)
SRC=$(BUILD)/src
VENDOR=$(BUILD)/vendor
SUPPORT=$(BUILD)/support
SLASHBR=$(BUILD)/bedrock
COMPLETED=$(BUILD)/completed
MUSLCC=$(SUPPORT)/bin/musl-gcc

INDENT_FLAGS=--linux-style --dont-line-up-parentheses \
	--continuation-indentation8 --indent-label0 --case-indentation0
WERROR_FLAGS=-Werror -Wall -Wextra -std=c99 -pedantic

all: $(INSTALLER)

remove_vendor_source:
	rm -rf ./vendor
  
fetch_vendor_sources: \
	vendor/busybox/.success_retrieving_source \
	vendor/libaio/.success_retrieving_source \
	vendor/libattr/.success_retrieving_source \
	vendor/libcap/.success_fetching_source \
	vendor/libfuse/.success_fetching_source \
	vendor/linux_headers/.success_fetching_source \
	vendor/lvm2/.success_retrieving_source \
	vendor/musl/.success_fetching_source \
	vendor/netselect/.success_retrieving_source \
	vendor/uthash/.success_fetching_source \
	vendor/util-linux/.success_fetching_source \
	vendor/zstd/.success_retrieving_source

clean:
	rm -rf build/*
	rm -f bedrock-linux-*-*.sh

#
# The build directory structure.  This is a dependency of just about
# everything.
#

$(COMPLETED)/builddir:
	# Support symlinking build into a tmpfs
	if [ -h "$(ROOT)/build" ]; then \
		mkdir -p $$(readlink $(ROOT)/build); \
	fi; \
	# build internal directory structure
	mkdir -p $(BUILD) $(SRC) $(VENDOR)
	mkdir -p $(SUPPORT)/include $(SUPPORT)/lib
	# copy /bedrock into build structure
	cp -r src/slash-bedrock/ $(SLASHBR)
	# create bedrock-release
	echo "$(RELEASE)" > $(SLASHBR)/etc/bedrock-release
	# create os-release
	sed -e "s,^VERSION=.*,VERISON=\"$(BEDROCK_VERSION) ($(CODENAME))\"," \
		-e "s,^VERSION_ID=.*,VERSION_ID=\"$(BEDROCK_VERSION)\"," \
		-e "s,^PRETTY_NAME=.*,PRETTY_NAME=\"$(RELEASE)\"," \
		$(SLASHBR)/etc/os-release > $(SLASHBR)/etc/os-release-new
	mv $(SLASHBR)/etc/os-release-new $(SLASHBR)/etc/os-release
	# create release-specific bedrock.conf
	mv $(SLASHBR)/etc/bedrock.conf $(SLASHBR)/etc/bedrock.conf-$(BEDROCK_VERSION)
	# git does not track empty directories.  Ensure known required
	# directories are created.
	mkdir -p $(SLASHBR)/bin
	mkdir -p $(SLASHBR)/etc
	mkdir -p $(SLASHBR)/gnupg-keys
	mkdir -p $(SLASHBR)/info
	mkdir -p $(SLASHBR)/libexec
	mkdir -p $(SLASHBR)/run
	mkdir -p $(SLASHBR)/share/brl-fetch/distros
	mkdir -p $(SLASHBR)/strata/bedrock
	mkdir -p $(SLASHBR)/var
	mkdir -p $(COMPLETED)
	mkdir -p $(BUILD)/sbin/
	# Most files going into the tarball exist in /bedrock, but Bedrock's
	# /sbin/init is not one of them.  Copy it separately.
	cp src/init/init $(BUILD)/sbin/init
	touch $(COMPLETED)/builddir
builddir: $(COMPLETED)/builddir

#
# Support libraries and tools.  Populates $(SUPPORT)
#
 
vendor/linux_headers/.success_fetching_source:
	rm -rf vendor/linux_headers
	mkdir -p vendor/linux_headers
	git clone --depth=1 'https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git' vendor/linux_headers
	touch vendor/linux_headers/.success_fetching_source
$(COMPLETED)/linux_headers: vendor/linux_headers/.success_fetching_source $(COMPLETED)/builddir
	rm -rf $(VENDOR)/linux_headers/
	mkdir -p $(VENDOR)/linux_headers
	cd $(ROOT)/vendor/linux_headers/ && \
		$(MAKE) headers_install INSTALL_HDR_PATH=$(SUPPORT) O=$(VENDOR)/linux_headers
	touch $(COMPLETED)/linux_headers
linux_headers: $(COMPLETED)/linux_headers

vendor/musl/.success_fetching_source:
	rm -rf vendor/musl
	mkdir -p vendor/musl
	git clone --depth=1 \
		-b `git ls-remote --tags 'git://git.musl-libc.org/musl' | \
		awk -F/ '{print $$NF}' | \
		sed 's/^v//g' | \
		grep '^[0-9.]*$$' | \
		sort -t . -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | \
		tail -n1 | \
		sed 's/^/v/'` 'git://git.musl-libc.org/musl' \
		vendor/musl
	touch vendor/musl/.success_fetching_source
$(COMPLETED)/musl: vendor/musl/.success_fetching_source $(COMPLETED)/builddir $(COMPLETED)/linux_headers
	rm -rf $(VENDOR)/musl
	cp -r vendor/musl $(VENDOR)
	cd $(VENDOR)/musl/ && \
		./configure --prefix=$(SUPPORT) --enable-static --enable-gcc-wrapper && \
		$(MAKE) && \
		$(MAKE) install
	if ! [ -e $(SUPPORT)/lib64 ]; then \
		ln -fs lib $(SUPPORT)/lib64; \
	fi
	if ! [ -e $(SUPPORT)/sbin ]; then \
		ln -fs bin $(SUPPORT)/sbin; \
	fi
	# gcc can get confused when using musl depending on -static/-pie setup,
	# and so we need to enforce -static.  meson apparently ignores CFLAGS
	# et al when sanity testing a compiler, requiring another method to
	# ensure meson tests the compiler with -static.  Thus this hack: embed
	# the -static flag into musl-gcc.
	sed 's/ -specs/ -static -specs/' $(SUPPORT)/bin/musl-gcc > $(SUPPORT)/bin/musl-gcc-new
	mv $(SUPPORT)/bin/musl-gcc-new $(SUPPORT)/bin/musl-gcc
	chmod a+rx $(SUPPORT)/bin/musl-gcc
	touch $(COMPLETED)/musl
musl: $(COMPLETED)/musl

vendor/libcap/.success_fetching_source:
	rm -rf vendor/libcap
	mkdir -p vendor/libcap
	git clone --depth=1 \
		-b `git ls-remote --tags 'https://git.kernel.org/pub/scm/linux/kernel/git/morgan/libcap.git' | \
		awk -F/ '{print $$NF}' | \
		sed 's/^libcap-//g' | \
		grep '^[0-9.]*$$' | \
		grep '[.]' | \
		sort -t . -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | \
		tail -n1 | \
		sed 's/^/libcap-/'` 'https://git.kernel.org/pub/scm/linux/kernel/git/morgan/libcap.git' \
		vendor/libcap
	touch vendor/libcap/.success_fetching_source
$(COMPLETED)/libcap: vendor/libcap/.success_fetching_source $(COMPLETED)/builddir $(COMPLETED)/musl
	rm -rf $(VENDOR)/libcap
	cp -r vendor/libcap/ $(VENDOR)
	mkdir -p $(SUPPORT)/include/sys
	if ! [ -e $(SUPPORT)/include/sys/capability.h ]; then \
		cp $(SUPPORT)/include/linux/capability.h $(SUPPORT)/include/sys/capability.h; \
	fi
	sed 's/^BUILD_GPERF.*/BUILD_GPERF=no/' $(VENDOR)/libcap/Make.Rules > $(VENDOR)/libcap/Make.Rules-new
	mv $(VENDOR)/libcap/Make.Rules-new $(VENDOR)/libcap/Make.Rules
	cd $(VENDOR)/libcap/libcap && \
		$(MAKE) BUILD_CC=$(MUSLCC) CC=$(MUSLCC) LD="$(MUSLCC) -Wl,-x -shared" lib=$(SUPPORT)/lib prefix=$(SUPPORT) BUILD_CFLAGS="$(CFLAGS) -static" && \
		$(MAKE) install RAISE_SETFCAP=no DESTDIR=$(SUPPORT) prefix=/ lib=lib
	cd $(VENDOR)/libcap/progs && \
		$(MAKE) BUILD_CC=$(MUSLCC) CC=$(MUSLCC) LD="$(MUSLCC) -Wl,-x -shared" lib=$(SUPPORT)/lib prefix=$(SUPPORT) LDFLAGS=-static && \
		$(MAKE) install RAISE_SETFCAP=no DESTDIR=$(SUPPORT) prefix=/ lib=lib
	touch $(COMPLETED)/libcap
libcap: $(COMPLETED)/libcap

vendor/libfuse/.success_fetching_source:
	rm -rf vendor/libfuse
	mkdir -p vendor/libfuse
	git clone --depth=1 \
		-b `git ls-remote --tags 'https://github.com/libfuse/libfuse.git' | \
		awk -F/ '{print $$NF}' | \
		sed 's/^fuse-//g' | \
		grep '^[0-9.]*$$' | \
		sort -t . -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | \
		tail -n1 | \
		sed 's/^/fuse-/'` 'https://github.com/libfuse/libfuse.git' \
		vendor/libfuse
	touch vendor/libfuse/.success_fetching_source
$(COMPLETED)/libfuse: vendor/libfuse/.success_fetching_source $(COMPLETED)/builddir $(COMPLETED)/musl
	rm -rf $(VENDOR)/libfuse
	cp -r vendor/libfuse/ $(VENDOR)
	mkdir -p $(VENDOR)/libfuse/build
	# meson/ninja sometimes fails with
	#     ninja: error: unknown target 'lib/libfuse3.a'
	# for no apparent reason.  It seems to eventually take after multiple
	# tries.  Thus, retry a few times.
	cd $(VENDOR)/libfuse/build && \
		CC=$(MUSLCC) CFLAGS="$(CFLAGS) -static" meson && \
		meson configure -D buildtype=release && \
		meson configure -D default_library=static && \
		meson configure -D strip=true && \
		meson configure -D prefix=$(SUPPORT) && \
		CC=$(MUSLCC) ninja lib/libfuse3.a || \
		CC=$(MUSLCC) CFLAGS="$(CFLAGS) -static" meson && \
		meson configure -D buildtype=release && \
		meson configure -D default_library=static && \
		meson configure -D strip=true && \
		meson configure -D prefix=$(SUPPORT) && \
		CC=$(MUSLCC) ninja lib/libfuse3.a || \
		CC=$(MUSLCC) CFLAGS="$(CFLAGS) -static" meson && \
		meson configure -D buildtype=release && \
		meson configure -D default_library=static && \
		meson configure -D strip=true && \
		meson configure -D prefix=$(SUPPORT) && \
		CC=$(MUSLCC) ninja lib/libfuse3.a || \
		CC=$(MUSLCC) CFLAGS="$(CFLAGS) -static" meson && \
		meson configure -D buildtype=release && \
		meson configure -D default_library=static && \
		meson configure -D strip=true && \
		meson configure -D prefix=$(SUPPORT) && \
		CC=$(MUSLCC) ninja lib/libfuse3.a || \
		CC=$(MUSLCC) CFLAGS="$(CFLAGS) -static" meson && \
		meson configure -D buildtype=release && \
		meson configure -D default_library=static && \
		meson configure -D strip=true && \
		meson configure -D prefix=$(SUPPORT) && \
		CC=$(MUSLCC) ninja lib/libfuse3.a
	cp -r $(VENDOR)/libfuse/build/lib/* $(SUPPORT)/lib/
	mkdir -p $(SUPPORT)/include/fuse3/
	cp $(VENDOR)/libfuse/include/*.h $(SUPPORT)/include/fuse3/
	touch $(COMPLETED)/libfuse
libfuse: $(COMPLETED)/libfuse

vendor/uthash/.success_fetching_source:
	rm -rf vendor/uthash
	mkdir -p vendor/uthash
	git clone --depth=1 \
		-b `git ls-remote --tags 'https://github.com/troydhanson/uthash.git' | \
		awk -F/ '{print $$NF}' | \
		sed 's/^v//g' | \
		grep '^[0-9.]*$$' | \
		sort -t . -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | \
		tail -n1 | \
		sed 's/^/v/'` 'https://github.com/troydhanson/uthash.git' \
		vendor/uthash
	touch vendor/uthash/.success_fetching_source
$(COMPLETED)/uthash: vendor/uthash/.success_fetching_source $(COMPLETED)/builddir
	rm -rf $(VENDOR)/uthash
	cp -r vendor/uthash/ $(VENDOR)
	cp -r $(VENDOR)/uthash/src/*.h $(SUPPORT)/include/
	touch $(COMPLETED)/uthash
uthash: $(COMPLETED)/uthash

vendor/libaio/.success_retrieving_source:
	rm -rf vendor/libaio/
	mkdir -p vendor/libaio
	git clone --depth=1 \
		-b `git ls-remote --tags 'https://pagure.io/libaio.git' | \
		awk -F/ '{print $$NF}' | \
		sed 's/^libaio-//g' | \
		grep '^[0-9.]*$$' | \
		sort -t . -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | \
		tail -n1 | \
		sed 's/^/libaio-/'` 'https://pagure.io/libaio.git' \
		vendor/libaio
	touch vendor/libaio/.success_retrieving_source
$(COMPLETED)/libaio: vendor/libaio/.success_retrieving_source $(COMPLETED)/builddir $(COMPLETED)/musl
	rm -rf $(VENDOR)/libaio
	cp -r vendor/libaio $(VENDOR)
	cp $(VENDOR)/libaio/src/libaio.h $(SUPPORT)/include
	cd $(VENDOR)/libaio && $(MAKE) CC=$(MUSLCC)
	cp $(VENDOR)/libaio/src/libaio.a $(SUPPORT)/lib
	cp $(VENDOR)/libaio/src/libaio.so.1.0.1 $(SUPPORT)/lib/libaio.so
	touch $(COMPLETED)/libaio
libaio: $(COMPLETED)/libaio

vendor/util-linux/.success_fetching_source:
	rm -rf vendor/util-linux
	mkdir -p vendor/util-linux
	git clone --depth=1 \
		-b `git ls-remote --tags 'https://git.kernel.org/pub/scm/utils/util-linux/util-linux.git' | \
		awk -F/ '{print $$NF}' | \
		sed 's/^v//g' | \
		grep '^[0-9.]*$$' | \
		sort -t . -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | \
		tail -n1 | \
		sed 's/^/v/'` 'https://git.kernel.org/pub/scm/utils/util-linux/util-linux.git' \
		vendor/util-linux
	touch vendor/util-linux/.success_fetching_source
$(COMPLETED)/util-linux: vendor/util-linux/.success_fetching_source $(COMPLETED)/builddir $(COMPLETED)/musl
	rm -rf $(VENDOR)/util-linux
	cp -r vendor/util-linux $(VENDOR)
	cd $(VENDOR)/util-linux && ./autogen.sh && \
		CC=$(MUSLCC) CFLAGS="-I$(SUPPORT)/include -L$(SUPPORT)/lib" ./configure --enable-static=yes --disable-all-programs --enable-libblkid --enable-libuuid && \
		$(MAKE) CC=$(MUSLCC) CFLAGS="-I$(SUPPORT)/include -L$(SUPPORT)/lib"
	cp $(VENDOR)/util-linux/.libs/libblkid.* $(SUPPORT)/lib
	cp $(VENDOR)/util-linux/.libs/libuuid.* $(SUPPORT)/lib
	touch $(COMPLETED)/util-linux
util-linux: $(COMPLETED)/util-linux

#
# Compiled binaries which will go into the output script.  Populates $(SLASHBR)
#

vendor/busybox/.success_retrieving_source:
	rm -rf vendor/busybox
	mkdir -p vendor/busybox
	git clone --depth=1 \
		-b `git ls-remote --heads 'git://git.busybox.net/busybox' | \
		awk -F/ '$$NF ~ /stable$$/ {print $$NF}' | \
		sort -t _ -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | \
		tail -n1` 'git://git.busybox.net/busybox' \
		vendor/busybox
	touch vendor/busybox/.success_retrieving_source
build/all/busybox/bedrock-config: vendor/busybox/.success_retrieving_source
	rm -rf build/all/busybox
	mkdir -p build/all
	cp -r vendor/busybox/ build/all/busybox
	# create busybox config helper
	cd build/all/busybox && \
		echo '#!/bin/sh' > set_bb_option && \
		echo 'if grep -q "^$$1=" .config; then' >> set_bb_option && \
		echo '	sed "s,^$$1=.*,$$1=$$2," .config > .config-new' >> set_bb_option && \
		echo '	mv .config-new .config' >> set_bb_option && \
		echo 'elif grep -q "^# $$1 is not set" .config; then' >> set_bb_option && \
		echo '	sed "s,^# $$1 is not set,$$1=$$2," .config > .config-new' >> set_bb_option && \
		echo '	mv .config-new .config' >> set_bb_option && \
		echo 'else' >> set_bb_option && \
		echo '	echo "$$1=$$2" >> .config' >> set_bb_option && \
		echo 'fi' >> set_bb_option && \
		chmod u+x set_bb_option
	# start with default config
	rm -f build/all/busybox/.config
	cd build/all/busybox && \
		$(MAKE) defconfig
	# disable unused applets
	cd build/all/busybox && \
		for applet in $$(grep "^CONFIG_.*=y$$" .config | grep -v "FEATURE" | sed -e 's/^CONFIG_//' -e 's/=.*$$//' | tr '[A-Z_]' '[a-z-]' ); do \
			if ! grep -rq "\<$$applet\>" $(ROOT)/src/slash-bedrock/ $(ROOT)/src/installer/installer.sh $(ROOT)/src/init/init; then \
				echo "DISABLING $$applet"; \
				./set_bb_option "CONFIG_$$(echo "$$applet" | tr '[a-z-]' '[A-Z_]')" "n"; \
			fi; \
		done
	# explicitly enable known desired and explicitly undesired features
	cd build/all/busybox && \
		./set_bb_option "CONFIG_AR" "y" && \
		./set_bb_option "CONFIG_ASH_BASH_COMPAT" "y" && \
		./set_bb_option "CONFIG_ASH_CMDCMD" "y" && \
		./set_bb_option "CONFIG_ASH_TEST" "y" && \
		./set_bb_option "CONFIG_BUSYBOX_EXEC_PATH" '"/bedrock/libexec/busybox"' && \
		./set_bb_option "CONFIG_DATE" "y" && \
		./set_bb_option "CONFIG_DEPMOD" "y" && \
		./set_bb_option "CONFIG_DESKTOP" "y" && \
		./set_bb_option "CONFIG_FEATURE_AR_CREATE" "y" && \
		./set_bb_option "CONFIG_FEATURE_AR_LONG_FILENAMES" "y" && \
		./set_bb_option "CONFIG_FEATURE_CHECK_TAINTED_MODULE" "y" && \
		./set_bb_option "CONFIG_FEATURE_FIND_MMIN" "y" && \
		./set_bb_option "CONFIG_FEATURE_FIND_XDEV" "y" && \
		./set_bb_option "CONFIG_FEATURE_MODPROBE_BLACKLIST" "y" && \
		./set_bb_option "CONFIG_FEATURE_MODUTILS_ALIAS" "y" && \
		./set_bb_option "CONFIG_FEATURE_MODUTILS_SYMBOLS" "y" && \
		./set_bb_option "CONFIG_FEATURE_PREFER_APPLETS" "y" && \
		./set_bb_option "CONFIG_FEATURE_SEAMLESS_BZ2" "y" && \
		./set_bb_option "CONFIG_FEATURE_SEAMLESS_GZ" "y" && \
		./set_bb_option "CONFIG_FEATURE_SEAMLESS_LZMA" "y" && \
		./set_bb_option "CONFIG_FEATURE_SEAMLESS_XZ" "y" && \
		./set_bb_option "CONFIG_FEATURE_SEAMLESS_Z" "y" && \
		./set_bb_option "CONFIG_FEATURE_SH_STANDALONE" "y" && \
		./set_bb_option "CONFIG_INIT" "n" && \
		./set_bb_option "CONFIG_INSMOD" "y" && \
		./set_bb_option "CONFIG_KILLALL" "y" && \
		./set_bb_option "CONFIG_LAST_ID" "65535" && \
		./set_bb_option "CONFIG_LAST_SYSTEM_ID" "65535" && \
		./set_bb_option "CONFIG_LFS" "y" && \
		./set_bb_option "CONFIG_LSMOD" "y" && \
		./set_bb_option "CONFIG_MODPROBE" "y" && \
		./set_bb_option "CONFIG_PIVOT_ROOT" "y" && \
		./set_bb_option "CONFIG_RMMOD" "y" && \
		./set_bb_option "CONFIG_STATIC" "y" && \
		./set_bb_option "CONFIG_SYSROOT" "\"\"" && \
		./set_bb_option "CONFIG_TEST" "y" && \
		./set_bb_option "CONFIG_TEST1" "y" && \
		./set_bb_option "CONFIG_VI" "y"
	cd build/all/busybox && \
		cp .config bedrock-config
$(SLASHBR)/libexec/busybox: vendor/busybox/.success_retrieving_source build/all/busybox/bedrock-config $(COMPLETED)/builddir $(COMPLETED)/musl
	rm -rf $(VENDOR)/busybox
	cp -r vendor/busybox/ $(VENDOR)/busybox
	cp build/all/busybox/bedrock-config $(VENDOR)/busybox/.config
	# fix various busybox-linux-musl issues
	cd $(SUPPORT)/include/netinet/ && \
		awk '{p=1}/^struct ethhdr/,/^}/{print "//"$$0; p=0}p==1' if_ether.h > if_ether.h.new && \
		mv if_ether.h.new if_ether.h
	cd $(SUPPORT)/include/linux/ && \
		echo '' > in.h
	cd $(SUPPORT)/include/linux/ && \
		echo '' > in6.h
	cp $(SUPPORT)/include/linux/if_slip.h $(SUPPORT)/include/net/
	cd $(VENDOR)/busybox && \
		$(MAKE) CC=$(MUSLCC) && \
		cp busybox $(SLASHBR)/libexec/busybox
busybox: $(SLASHBR)/libexec/busybox

vendor/libattr/.success_retrieving_source:
	git clone --depth=1 \
		-b `git ls-remote --tags 'https://git.savannah.nongnu.org/git/attr.git' | \
		awk -F/ '{print $$NF}' | \
		sed 's/^v//g' | \
		grep '^[0-9.]*$$' | \
		sort -t . -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | \
		tail -n1 | \
		sed 's/^/v/'` 'https://git.savannah.nongnu.org/git/attr.git' \
		vendor/libattr
	touch vendor/libattr/.success_retrieving_source
$(COMPLETED)/libattr: vendor/libattr/.success_retrieving_source $(COMPLETED)/builddir $(COMPLETED)/musl
	rm -rf $(VENDOR)/libattr
	cp -r vendor/libattr/ $(VENDOR)
	# Sometimes autogen does not take the first time despite returning 0.  Thus, try a few times.
	cd $(VENDOR)/libattr && \
		./autogen.sh && \
		CC=$(MUSLCC) ./configure --enable-static --disable-shared ; \
		make clean && \
		make CC=$(MUSLCC) getfattr setfattr && \
		cp getfattr $(SLASHBR)/libexec/getfattr && \
		cp setfattr $(SLASHBR)/libexec/setfattr
	touch $(COMPLETED)/libattr
$(SLASHBR)/libexec/getfattr: $(COMPLETED)/libattr
$(SLASHBR)/libexec/setfattr: $(COMPLETED)/libattr
getfattr: $(COMPLETED)/libattr
setfattr: $(COMPLETED)/libattr

$(SLASHBR)/libexec/setcap: $(COMPLETED)/libcap
	cp $(SUPPORT)/sbin/setcap $(SLASHBR)/libexec/setcap
setcap: $(SLASHBR)/libexec/setcap

vendor/netselect/.success_retrieving_source:
	mkdir -p vendor/netselect
	git clone --depth=1 'https://github.com/apenwarr/netselect.git' vendor/netselect
	touch vendor/netselect/.success_retrieving_source
$(SLASHBR)/libexec/netselect: vendor/netselect/.success_retrieving_source $(COMPLETED)/builddir $(COMPLETED)/musl
	rm -rf $(VENDOR)/netselect
	cp -r vendor/netselect/ $(VENDOR)
	# netselect uses non-standard types which musl does not recognize.
	if ! grep -q '^#include "fix_types.h"' $(VENDOR)/netselect/netselect.c; then \
		echo '#define u_char unsigned char' > $(VENDOR)/netselect/fix_types.h && \
		echo '#define u_short unsigned short' >> $(VENDOR)/netselect/fix_types.h && \
		echo '#define u_long unsigned long' >> $(VENDOR)/netselect/fix_types.h && \
		echo '#include "fix_types.h"' > $(VENDOR)/netselect/netselect_fixed.c && \
		cat $(VENDOR)/netselect/netselect.c >> $(VENDOR)/netselect/netselect_fixed.c && \
		mv $(VENDOR)/netselect/netselect_fixed.c $(VENDOR)/netselect/netselect.c; fi
	# patch netselect to avoid dropping domain in output
	# users may prefer the domain to a raw IP, and some services (e.g.
	# cloudflare) refuse to operate when contacted with raw IP.
	if grep -q '^\s*if\s*(result.multi)$$' $(VENDOR)/netselect/netselect.c; then \
		sed 's/^\s*if\s*(result.multi)$$/if(0)/' \
			$(VENDOR)/netselect/netselect.c > $(VENDOR)/netselect/netselect_fixed.c && \
		mv $(VENDOR)/netselect/netselect_fixed.c $(VENDOR)/netselect/netselect.c; fi
	cd $(VENDOR)/netselect/ && \
		make CC=$(MUSLCC) LDFLAGS='-static' && \
		cp netselect $(SLASHBR)/libexec/netselect
netselect: $(SLASHBR)/libexec/netselect

vendor/lvm2/.success_retrieving_source:
	rm -rf vendor/lvm2/
	mkdir -p vendor/lvm2
	# no `--depth 1` because this repo does not support it
	git clone \
		-b `git ls-remote --tags 'https://sourceware.org/git/lvm2.git' | \
		awk -F/ '{print $$NF}' | \
		sed -e 's/^v//g' -e 's/_/./g' | \
		grep '^[0-9.]*$$' | \
		sort -t . -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | \
		tail -n1 | \
		sed -e 's/^/v/' -e 's/[.]/_/g'` 'https://sourceware.org/git/lvm2.git' \
		vendor/lvm2
	wget -O vendor/lvm2/mallinfo.patch https://git.alpinelinux.org/aports/plain/main/lvm2/mallinfo.patch
	wget -O vendor/lvm2/fix-stdio.patch https://git.alpinelinux.org/aports/plain/main/lvm2/fix-stdio-usage.patch
	cd vendor/lvm2 && patch -p0 -i mallinfo.patch
	cd vendor/lvm2 && patch -p0 -i fix-stdio.patch
	touch vendor/lvm2/.success_retrieving_source
$(COMPLETED)/lvm2: vendor/lvm2/.success_retrieving_source $(COMPLETED)/musl $(COMPLETED)/libaio $(COMPLETED)/util-linux
	rm -rf $(VENDOR)/lvm2
	cp -r vendor/lvm2 $(VENDOR)
	cd $(VENDOR)/lvm2 && \
		CC=$(MUSLCC) CFLAGS="-I$(SUPPORT)/include -L$(SUPPORT)/lib -fPIC" ./configure --disable-udev-systemd-background-jobs --disable-selinux --enable-static_link && \
		$(MAKE) tools CC=$(MUSLCC) CFLAGS="-I$(SUPPORT)/include -L$(SUPPORT)/lib -L$(VENDOR)/lvm2/libdm/ioctl -fPIC" interfacebuilddir=$(VENDOR)/lvm2/libdm/ioctl
	cp $(VENDOR)/lvm2/tools/lvm.static $(SLASHBR)/libexec/lvm
	cp $(VENDOR)/lvm2/libdm/dm-tools/dmsetup.static $(SLASHBR)/libexec/dmsetup
	touch $(COMPLETED)/lvm2
$(SLASHBR)/libexec/lvm: $(COMPLETED)/lvm2
$(SLASHBR)/libexec/dmsetup: $(COMPLETED)/lvm2
lvm2: $(SLASHBR)/libexec/dmsetup $(SLASHBR)/libexec/lvm

vendor/zstd/.success_retrieving_source:
	rm -rf vendor/zstd/
	mkdir -p vendor/zstd
	git clone --depth 1 \
		-b `git ls-remote --tags 'https://github.com/facebook/zstd.git' | \
		awk -F/ '{print $$NF}' | \
		sed -e 's/^v//g' | \
		grep '^[0-9.]*$$' | \
		sort -t . -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | \
		tail -n1 | \
		sed -e 's/^/v/'` 'https://github.com/facebook/zstd.git' \
		vendor/zstd
	touch vendor/zstd/.success_retrieving_source
$(SLASHBR)/libexec/zstd: vendor/zstd/.success_retrieving_source $(COMPLETED)/musl
	rm -rf $(VENDOR)/zstd
	cp -r vendor/zstd $(VENDOR)
	cd $(VENDOR)/zstd && \
		make CC=$(MUSLCC) && \
		cp zstd $(SLASHBR)/libexec/zstd
zstd: $(SLASHBR)/libexec/zstd

$(SLASHBR)/bin/strat: $(COMPLETED)/builddir $(COMPLETED)/musl $(COMPLETED)/libcap
	rm -rf $(SRC)/strat
	cp -r src/strat/ $(SRC)
	cd $(SRC)/strat && \
		$(MAKE) CC=$(MUSLCC) && \
		cp ./strat $(SLASHBR)/bin/strat
strat: $(SLASHBR)/bin/strat

$(SLASHBR)/libexec/manage_tty_lock: $(COMPLETED)/builddir $(COMPLETED)/musl
	rm -rf $(SRC)/manage_tty_lock
	cp -r src/manage_tty_lock/ $(SRC)
	cd $(SRC)/manage_tty_lock && \
		$(MAKE) CC=$(MUSLCC) && \
		cp manage_tty_lock $(SLASHBR)/libexec/manage_tty_lock
manage_tty_lock: $(SLASHBR)/libexec/manage_tty_lock

$(SLASHBR)/libexec/keyboard_is_present: $(COMPLETED)/builddir $(COMPLETED)/musl
	rm -rf $(SRC)/keyboard_is_present
	cp -r src/keyboard_is_present/ $(SRC)
	cd $(SRC)/keyboard_is_present && \
		$(MAKE) CC=$(MUSLCC) && \
		cp keyboard_is_present $(SLASHBR)/libexec/keyboard_is_present
keyboard_is_present: $(SLASHBR)/libexec/keyboard_is_present

$(SLASHBR)/libexec/bouncer: $(COMPLETED)/builddir $(COMPLETED)/musl
	rm -rf $(SRC)/bouncer
	cp -r src/bouncer/ $(SRC)
	cd $(SRC)/bouncer && \
		$(MAKE) CC=$(MUSLCC) && \
		cp ./bouncer $(SLASHBR)/libexec/bouncer
bouncer: $(SLASHBR)/libexec/bouncer

$(SLASHBR)/libexec/etcfs: $(COMPLETED)/builddir \
	$(COMPLETED)/musl \
	$(COMPLETED)/libfuse
	rm -rf $(SRC)/etcfs
	cp -r src/etcfs/ $(SRC)
	cd $(SRC)/etcfs && \
		make CC=$(MUSLCC) CFLAGS="$(CFLAGS)" && \
		cp ./etcfs $(SLASHBR)/libexec/etcfs
etcfs: $(SLASHBR)/libexec/etcfs

$(SLASHBR)/libexec/crossfs: $(COMPLETED)/builddir \
	$(COMPLETED)/musl \
	$(COMPLETED)/libfuse \
	$(COMPLETED)/uthash
	rm -rf $(SRC)/crossfs
	cp -r src/crossfs/ $(SRC)
	cd $(SRC)/crossfs && \
		make CC=$(MUSLCC) CFLAGS="$(CFLAGS)" && \
		cp ./crossfs $(SLASHBR)/libexec/crossfs
crossfs: $(SLASHBR)/libexec/crossfs

#
# Use populated $(SLASHBR) to create the installer/updater script
#

$(BUILD)/userland.tar: \
	$(COMPLETED)/builddir \
	$(SLASHBR)/bin/strat \
	$(SLASHBR)/libexec/bouncer \
	$(SLASHBR)/libexec/busybox \
	$(SLASHBR)/libexec/crossfs \
	$(SLASHBR)/libexec/dmsetup \
	$(SLASHBR)/libexec/etcfs \
	$(SLASHBR)/libexec/getfattr \
	$(SLASHBR)/libexec/keyboard_is_present \
	$(SLASHBR)/libexec/lvm \
	$(SLASHBR)/libexec/manage_tty_lock \
	$(SLASHBR)/libexec/netselect \
	$(SLASHBR)/libexec/setcap \
	$(SLASHBR)/libexec/setfattr \
	$(SLASHBR)/libexec/zstd
	# remove symlinks which may have been created in a previous interrupted run
	rm -f $(SLASHBR)/libexec/brl-strat
	rm -f $(SLASHBR)/strata/init
	rm -f $(SLASHBR)/strata/local
	# ensure static
	for bin in $(SLASHBR)/bin/* $(SLASHBR)/libexec/*; do \
		if ldd "$$bin" >/dev/null 2>&1; then \
			echo "error: $$bin is dynamically linked"; exit 1; \
		fi; \
	done
	# ensure correct binary format
	for bin in $(SLASHBR)/bin/* $(SLASHBR)/libexec/*; do \
		if file "$$bin" | grep -q "sh script"; then \
			continue ; \
		elif file "$$bin" | grep -qi "$(FILE_ARCH_NAME)"; then \
			continue ; \
		fi; \
		echo "ERROR: \`file $$bin\` does not contain $(FILE_ARCH_NAME)"; \
		exit 1; \
	done
	# strip binaries
	for bin in $(SLASHBR)/bin/* $(SLASHBR)/libexec/*; do \
		if [ -r "$$bin" ] && ! [ -h "$$bin" ] && head -c4 "$$bin" | grep -q "ELF"; then \
			strip "$$bin"; \
		fi \
	done
	# ensure permissions
	find $(SLASHBR) -exec chmod a-s {} \;
	find $(SLASHBR) -type d -exec chmod 0755 {} \;
	find $(SLASHBR) -type f -exec chmod 0644 {} \;
	find $(SLASHBR)/bin/ -type f -exec chmod 0755 {} \;
	find $(SLASHBR)/libexec/ -type f -exec chmod 0755 {} \;
	chmod 700 $(SLASHBR)/gnupg-keys
	chmod 600 $(SLASHBR)/gnupg-keys/*
	chmod 755 $(SLASHBR)/share/resolvconf/00bedrock
	chmod 755 $(BUILD)/sbin/init
	# create symlinks
	ln -s ../bin/strat $(SLASHBR)/libexec/brl-strat
	ln -s /bedrock/run/init-alias $(SLASHBR)/strata/init
	ln -s ../cross/.local-alias $(SLASHBR)/strata/local
	# create a tarball
	cd $(BUILD) && fakeroot tar cf userland.tar-new bedrock/ sbin/init
	cd $(BUILD) && mv userland.tar-new userland.tar
tarball: $(BUILD)/userland.tar

$(BUILD)/unsigned-installer.sh: $(BUILD)/userland.tar src/installer/installer.sh src/slash-bedrock/share/common-code
	( \
		cat src/installer/installer.sh | awk '/^[.] \/bedrock\/share\/common-code/{exit}1'; \
		cat src/slash-bedrock/share/common-code | sed 's/BEDROCK-RELEASE/$(RELEASE)/' | grep -v 'pipefail'; \
		cat src/installer/installer.sh | awk 'x{print}/^[.] \/bedrock\/share\/common-code/{x=1}' | sed \
			-e 's/^ARCHITECTURE=.*/ARCHITECTURE="$(ARCHITECTURE)"/' \
			-e 's/^TARBALL_SHA1SUM=.*/TARBALL_SHA1SUM="$(shell cat $(BUILD)/userland.tar | sha1sum - | cut -d' ' -f1)"/' \
			; \
		echo "-----BEGIN TARBALL-----"; \
		cat $(BUILD)/userland.tar | gzip; \
		echo ""; \
		echo "-----END TARBALL-----"; \
	) > $(BUILD)/unsigned-installer.sh-new
	mv $(BUILD)/unsigned-installer.sh-new $(BUILD)/unsigned-installer.sh

$(INSTALLER): $(BUILD)/unsigned-installer.sh
	if [ "$(SKIPSIGN)" = true ]; then \
		cp $(BUILD)/unsigned-installer.sh $(INSTALLER)-new; \
		mv $(INSTALLER)-new $(INSTALLER); \
	elif [ -z "$(GPGID)" ]; then \
		echo 'Either SKIPSIGN or GPGID must be set.'; \
		echo 'To create an unsigned script, run:'; \
		echo '    make SKIPSIGN=true'; \
		echo 'Or to create a script with an embedded signature, run:'; \
		echo '    make GPGID=<gpg-id-with-which-to-sign>'; \
		exit 1; \
	elif ! gpg --version >/dev/null 2>&1; then \
		echo 'gpg not found in $$PATH, but required to sign build.'; \
		echo 'Use `make SKIPSIGN=true` to opt out of signing'; \
		exit 1; \
	else \
		rm -f $(BUILD)/signed-installer.sh; \
		cp $(BUILD)/unsigned-installer.sh $(BUILD)/signed-installer.sh; \
		gpg --output - --armor --detach-sign $(BUILD)/unsigned-installer.sh >> $(BUILD)/signed-installer.sh; \
		mv $(BUILD)/signed-installer.sh $(INSTALLER); \
	fi
	chmod +x $(INSTALLER)
	@ printf "\e[32m\n"
	@ echo "=== Completed creating $(INSTALLER) ===" | sed 's/./=/g'
	@ echo "=== Completed creating $(INSTALLER) ==="
	@ echo "=== Completed creating $(INSTALLER) ===" | sed 's/./=/g'
	@ printf "\e[39m\n"
#
# Code quality enforcement
#

format:
	# Standardizes code formatting
	#
	# requires:
	#
	# - shfmt (https://github.com/mvdan/sh)
	# - indent (GNU)
	#
	# style shell scripts
	for file in $$(find src/ -type f); do \
		if head -n1 "$$file" | grep -q '^#!.*busybox sh$$'; then \
			shfmt -p -w "$$file"; \
		fi; \
		if head -n1 "$$file" | grep -q '^#!.*bash$$'; then \
			shfmt -ln bash -w "$$file"; \
		fi; \
		if head -n1 "$$file" | grep -q -e '^#!.*zsh$$' -e '^#compdef' "$$file"; then \
			shfmt -ln bash -w "$$file"; \
		fi; \
	done
	# style C code
	for file in $$(find src/ -type f -name "*.[ch]"); do \
		indent $(INDENT_FLAGS) "$$file" || exit 1; \
		rm -f "$$file~"; \
	done
	@ printf "\e[32m\n"
	@ echo "======================================"
	@ echo "=== Completed formatting code base ==="
	@ echo "======================================"
	@ printf "\e[39m\n"

check:
	# Run various static checkers against the codebase.
	#
	# Generally, one should strive to get these all to pass submit
	# something to Bedrock Linux.  However, the code base is not expected
	# to pass all of these at all times, as as different versions of the
	# static checkers may cover different things.  Don't fret if this
	# returns some warnings.
	#
	# Unlike the rest of the build system, this links dynamically against
	# the system libraries rather than statically against custom-built
	# ones.  This removes the need to do things like teach static analysis
	# tools about musl-gcc.  It comes at the cost of non-portable resulting
	# binaries, but we don't care about the resulting binaries themselves,
	# just the code being analyzed.
	#
	# Libraries you'll need to install:
	#
	# - uthash
	# - libfuse3
	# - libcap
	# - libattr
	#
	# Static analysis tools which need to be installed:
	#
	# - shellcheck
	# - cppcheck
	# - clang
	# - gcc
	# - scan-build (usually distributed with clang)
	# - shfmt (https://github.com/mvdan/sh)
	# - indent (GNU)
	#
	# check against shellcheck
	#
	# - SC1008: unrecognized shebang, because shellcheck does not know about
	#   `#!/bedrock/libexec/busybox sh`
	# - SC2059: don't use variables in printf format string.  Following
	#   this recommendation with ANSI color variables did not work for some
	#   reason.  Excluding the check for the time being.
	# - SC2039: `[ \< ]` and `[ \> ]` are non-POSIX.  However, they do work
	#   with busybox.
	# - SC1090: Can't follow dynamic sources.  That's fine, we know where
	#   they are and are including them in the list to be checked.
	for file in $$(find src/ -type f); do \
		if head -n1 "$$file" | grep -q '^#!.*busybox sh$$'; then \
			echo "checking shell file $$file"; \
			shellcheck -x -s sh --exclude="SC1008,SC2059,SC2039,SC1090" "$$file" || exit 1; \
			! cat "$$file" | shfmt -p -d | grep '.' || exit 1; \
		elif head -n1 "$$file" | grep -q '^#!.*bash$$'; then \
			echo "checking bash file $$file"; \
			shellcheck -x -s bash --exclude="SC1008,SC2059,SC2039,SC1090" "$$file" || exit 1; \
			! cat "$$file" | shfmt -ln bash -d | grep '.' || exit 1; \
		elif head -n1 "$$file" | grep -q -e '^#!.*zsh$$' -e '^#compdef' "$$file"; then \
			echo "checking zsh file $$file"; \
			shellcheck -x -s bash --exclude="SC1008,SC2059,SC2039,SC1090" "$$file" || exit 1; \
			! cat "$$file" | shfmt -ln bash -d | grep '.' || exit 1; \
		fi; \
	done
	# check against cppcheck
	for file in $$(find src/ -type f -name "*.[ch]"); do \
		cppcheck --error-exitcode=1 "$$file" || exit 1; \
	done
	# check against various compiler warnings
	for compiler in clang gcc; do \
		for dir in src/*/Makefile; do \
			$(MAKE) -C "$${dir%Makefile}" clean || exit 1; \
			$(MAKE) -C "$${dir%Makefile}" CC=$$compiler CFLAGS="$(WERROR_FLAGS)" || exit 1; \
			$(MAKE) -C "$${dir%Makefile}" clean || exit 1; \
		done \
	done
	# check C code formatting
	for file in $$(find src/ -type f -name "*.[ch]"); do \
		echo "checking formatting of $$file"; \
		! cat "$$file" | indent $(INDENT_FLAGS) | diff -- "$$file" - | grep '.' || exit 1; \
	done
	@ echo "======================================="
	@ echo "=== All static analysis checks pass ==="
	@ echo "======================================="

#
# Release build environment setup
#

release-build-environment:
	# This build system handles non-native CPU ISAs builds by leveraging
	# qemu to run build scripts and makefiles that may not be cross-compile
	# friendly while running performance sensitive components such as the
	# compiler with the native ISA configured to cross compile.
	#
	# This recipe fetches and sets up one stratum per ISA to run the scripts and
	# makefiles (brl-build-<arch>), one stratum to provide most of the
	# cross-compile tools (brl-build-cross), and one stratum to special
	# case ppc64le cross-compile tools (brl-build-cross-ppc).
	#
	# These strata are hidden from everything but boot-time-enable to avoid
	# polluting the PATH.
	#
	# Fetching strata and installing packages requires root.
	[ $$(id -u) = 0 ]
	# Fetch and setup cross compile tool stratum.  It requires
	# cross-compile tools for every supported architecture except ppc64le,
	# which needs to be special cased, and the x86/x86_64 family, due to
	# the expectation that the build machine will support them natively.
	if ! /bedrock/libexec/getfattr -d /bedrock/strata/brl-build-cross 2>/dev/null | grep -q user.bedrock.show_boot; then \
		brl remove -d brl-build-cross 2>/dev/null || true; \
		brl fetch -s -n brl-build-cross debian; \
		brl show -b brl-build-cross; \
	fi
	strat -r brl-build-cross apt -y install \
			gcc-aarch64-linux-gnu \
			binutils-aarch64-linux-gnu \
			gcc-arm-linux-gnueabihf \
			binutils-arm-linux-gnueabihf \
			gcc-arm-linux-gnueabi \
			binutils-arm-linux-gnueabi \
			gcc-mips-linux-gnu \
			binutils-mips-linux-gnu \
			gcc-mipsel-linux-gnu \
			binutils-mipsel-linux-gnu \
			gcc-mips64el-linux-gnuabi64 \
			binutils-mips64el-linux-gnuabi64 \
			gcc-s390x-linux-gnu \
			binutils-s390x-linux-gnu
	for target in aarch64-linux-gnu \
			arm-linux-gnueabihf \
			arm-linux-gnueabi \
			mips-linux-gnu \
			mipsel-linux-gnu \
			mips64el-linux-gnuabi64 \
			s390x-linux-gnu; do \
		if ! [ -x "/bedrock/strata/brl-build-cross/usr/local/bin/brl-$${target}-gcc" ] && [ -x /bedrock/strata/brl-build-cross/usr/bin/$${target}-gcc ]; then \
			printf '#!/bedrock/libexec/busybox sh\nexec /bedrock/bin/strat -r brl-build-cross /usr/bin/'"$${target}"'-gcc "$${@}"\n' > \
				"/bedrock/strata/brl-build-cross/usr/local/bin/brl-$${target}-gcc"; \
			chmod a+rx "/bedrock/strata/brl-build-cross/usr/local/bin/brl-$${target}-gcc"; \
		fi; \
		if ! [ -x "/bedrock/strata/brl-build-cross/usr/local/bin/brl-$${target}-ld" ] && [ -x /bedrock/strata/brl-build-cross/usr/bin/$${target}-ld ]; then \
			printf '#!/bedrock/libexec/busybox sh\nexec /bedrock/bin/strat -r brl-build-cross /usr/bin/'"$${target}"'-ld "$${@}"\n' > \
				"/bedrock/strata/brl-build-cross/usr/local/bin/brl-$${target}-ld"; \
			chmod a+rx "/bedrock/strata/brl-build-cross/usr/local/bin/brl-$${target}-ld"; \
		fi; \
		if ! [ -x "/bedrock/strata/brl-build-cross/usr/local/bin/brl-$${target}-ar" ] && [ -x /bedrock/strata/brl-build-cross/usr/bin/$${target}-ar ]; then \
			printf '#!/bedrock/libexec/busybox sh\nexec /bedrock/bin/strat -r brl-build-cross /usr/bin/'"$${target}"'-ar "$${@}"\n' > \
				"/bedrock/strata/brl-build-cross/usr/local/bin/brl-$${target}-ar"; \
			chmod a+rx "/bedrock/strata/brl-build-cross/usr/local/bin/brl-$${target}-ar"; \
		fi; \
	done
	# ppc64le does not use IEEE long double floating point, and musl is
	# fastidious towards following proper standards.  To get the two to
	# play long, build a ppc64le targeted gcc which restricts long double
	# float accuracy to something that makes both ppc64le and musl happy.
	if ! /bedrock/libexec/getfattr -d /bedrock/strata/brl-build-cross-ppc 2>/dev/null | grep -q user.bedrock.show_boot; then \
		brl remove -d brl-build-cross-ppc 2>/dev/null || true; \
		brl fetch -n brl-build-cross-ppc -s gentoo; \
		brl show -b brl-build-cross-ppc; \
	fi
	if ! grep -q "sys-devel/crossdev" /bedrock/strata/brl-build-cross-ppc/var/lib/portage/world; then \
		strat -r brl-build-cross-ppc emerge "sys-devel/crossdev"; \
	fi
	if ! [ -d /bedrock/strata/brl-build-cross-ppc/usr/local/portage-crossdev-powerpc64le-linux-gnu/profiles ]; then \
		mkdir -p /bedrock/strata/brl-build-cross-ppc/usr/local/portage-crossdev-powerpc64le-linux-gnu/profiles; \
	fi
	if ! [ -d /bedrock/strata/brl-build-cross-ppc/usr/local/portage-crossdev-powerpc64le-linux-gnu/metadata ]; then \
		mkdir -p /bedrock/strata/brl-build-cross-ppc/usr/local/portage-crossdev-powerpc64le-linux-gnu/metadata; \
	fi
	if ! [ -e /bedrock/strata/brl-build-cross-ppc/usr/local/portage-crossdev-powerpc64le-linux-gnu/metadata/layout.conf ]; then \
		touch /bedrock/strata/brl-build-cross-ppc/usr/local/portage-crossdev-powerpc64le-linux-gnu/metadata/layout.conf; \
	fi
	if ! grep -q "masters = gentoo" /bedrock/strata/brl-build-cross-ppc/usr/local/portage-crossdev-powerpc64le-linux-gnu/metadata/layout.conf; then \
		echo 'masters = gentoo' >> /bedrock/strata/brl-build-cross-ppc/usr/local/portage-crossdev-powerpc64le-linux-gnu/metadata/layout.conf; \
	fi
	if ! [ -e /bedrock/strata/brl-build-cross-ppc/etc/portage/make.conf ]; then \
		touch /bedrock/strata/brl-build-cross-ppc/etc/portage/make.conf; \
	fi
	if ! grep -q "PORTDIR_OVERLAY=.*/usr/local/portage-crossdev-powerpc64le-linux-gnu" "/bedrock/strata/brl-build-cross-ppc/etc/portage/make.conf"; then \
		echo "PORTDIR_OVERLAY=\"\$${PORTDIR_OVERLAY} /usr/local/portage-crossdev-powerpc64le-linux-gnu\"" >> "/bedrock/strata/brl-build-cross-ppc/etc/portage/make.conf"; \
	fi
	if ! [ -e /bedrock/strata/brl-build-cross-ppc/usr/local/portage-crossdev-powerpc64le-linux-gnu/.set-permissions ]; then \
		chown -R portage:portage /bedrock/strata/brl-build-cross-ppc/usr/local/portage-crossdev-powerpc64le-linux-gnu; \
		touch /bedrock/strata/brl-build-cross-ppc/usr/local/portage-crossdev-powerpc64le-linux-gnu/.set-permissions; \
	fi
	strat -r brl-build-cross-ppc crossdev --stable --target "powerpc64le-linux-gnu" --genv 'EXTRA_ECONF="--without-long-double-128 --with-long-double-64"' --ov-output /usr/local/portage-crossdev-powerpc64le-linux-gnu; \
	if ! grep -q 'CFLAGS=.*-mlong-double-64"' "/bedrock/strata/brl-build-cross-ppc/usr/powerpc64le-linux-gnu/etc/portage/make.conf"; then \
		echo 'CFLAGS="$${CFLAGS} -mlong-double-64"' >> "/bedrock/strata/brl-build-cross-ppc/usr/powerpc64le-linux-gnu/etc/portage/make.conf"; \
	fi
	if ! grep -q 'CXXFLAGS=.*-mlong-double-64"' "/bedrock/strata/brl-build-cross-ppc/usr/powerpc64le-linux-gnu/etc/portage/make.conf"; then \
		echo 'CXXFLAGS="$${CXXFLAGS} -mlong-double-64"' >> "/bedrock/strata/brl-build-cross-ppc/usr/powerpc64le-linux-gnu/etc/portage/make.conf"; \
	fi
	if ! grep -q "EXTRA_ECONF=.*long-double-64" "/bedrock/strata/brl-build-cross-ppc/usr/powerpc64le-linux-gnu/etc/portage/bashrc"; then \
		echo 'EXTRA_ECONF="$${EXTRA_ECONF} --without-long-double-128 --with-long-double-64"' >> /bedrock/strata/brl-build-cross-ppc/usr/powerpc64le-linux-gnu/etc/portage/bashrc; \
	fi
	if ! [ -x "/bedrock/strata/brl-build-cross-ppc/usr/local/bin/brl-powerpc64le-linux-gnu-gcc" ] && [ -h /bedrock/strata/brl-build-cross-ppc/usr/bin/powerpc64le-linux-gnu-gcc ]; then \
		printf '#!/bedrock/libexec/busybox sh\nexec /bedrock/bin/strat -r brl-build-cross-ppc /usr/bin/powerpc64le-linux-gnu-gcc "$${@}"\n' > \
			"/bedrock/strata/brl-build-cross-ppc/usr/local/bin/brl-powerpc64le-linux-gnu-gcc"; \
		chmod a+rx "/bedrock/strata/brl-build-cross-ppc/usr/local/bin/brl-powerpc64le-linux-gnu-gcc"; \
	fi
	if ! [ -x "/bedrock/strata/brl-build-cross-ppc/usr/local/bin/brl-powerpc64le-linux-gnu-ld" ] && [ -h /bedrock/strata/brl-build-cross-ppc/usr/bin/powerpc64le-linux-gnu-ld ]; then \
		printf '#!/bedrock/libexec/busybox sh\nexec /bedrock/bin/strat -r brl-build-cross-ppc /usr/bin/powerpc64le-linux-gnu-ld "$${@}"\n' > \
			"/bedrock/strata/brl-build-cross-ppc/usr/local/bin/brl-powerpc64le-linux-gnu-ld"; \
		chmod a+rx "/bedrock/strata/brl-build-cross-ppc/usr/local/bin/brl-powerpc64le-linux-gnu-ld"; \
	fi
	if ! [ -x "/bedrock/strata/brl-build-cross-ppc/usr/local/bin/brl-powerpc64le-linux-gnu-ar" ] && [ -h /bedrock/strata/brl-build-cross-ppc/usr/bin/powerpc64le-linux-gnu-ar ]; then \
		printf '#!/bedrock/libexec/busybox sh\nexec /bedrock/bin/strat -r brl-build-cross-ppc /usr/bin/powerpc64le-linux-gnu-ar "$${@}"\n' > \
			"/bedrock/strata/brl-build-cross-ppc/usr/local/bin/brl-powerpc64le-linux-gnu-ar"; \
		chmod a+rx "/bedrock/strata/brl-build-cross-ppc/usr/local/bin/brl-powerpc64le-linux-gnu-ar"; \
	fi
	# Fetch and setup Debian per-arch strata.
	for arch in aarch64 armv7hl armv7l i686 mips mipsel mips64el ppc64le s390x x86_64; do \
		if ! /bedrock/libexec/getfattr -d /bedrock/strata/brl-build-$${arch} 2>/dev/null | grep -q user.bedrock.show_boot; then \
			brl remove -d "brl-build-$${arch}" 2>/dev/null || true; \
			brl fetch -n "brl-build-$${arch}" -a "$${arch}" -s debian; \
			brl show -b "brl-build-$${arch}"; \
		fi; \
		strat -r "brl-build-$${arch}" apt -y install autoconf autopoint bison build-essential fakeroot gpg libtool meson ninja-build pkg-config rsync udev; \
	done
	# Debian does not offer i386, i486, or i586.  Gentoo does, either directly or by re-compiling.
	for arch in i386 i486 i586; do \
		if ! /bedrock/libexec/getfattr -d /bedrock/strata/brl-build-$${arch} 2>/dev/null | grep -q user.bedrock.show_boot; then \
			brl remove -d "brl-build-$${arch}" 2>/dev/null || true; \
			brl fetch -n "brl-build-$${arch}" -a "i486" -s gentoo; \
			brl show -b "brl-build-$${arch}"; \
		fi; \
		for pkg in dev-util/meson dev-util/ninja fakeroot; do \
			if ! grep -q "$${pkg}" /bedrock/strata/brl-build-$${arch}/var/lib/portage/world; then \
				strat -r brl-build-$${arch} emerge "$${pkg}"; \
			fi; \
		done; \
		if [ "$${arch}" = i486 ]; then \
			continue; \
		fi; \
		if grep -q "i486" /bedrock/strata/brl-build-$${arch}/etc/portage/make.conf; then \
			sed "s/i486/$${arch}/g" /bedrock/strata/brl-build-$${arch}/etc/portage/make.conf > /bedrock/strata/brl-build-$${arch}/etc/portage/make.conf-new; \
			mv /bedrock/strata/brl-build-$${arch}/etc/portage/make.conf-new /bedrock/strata/brl-build-$${arch}/etc/portage/make.conf; \
		fi; \
		if ! grep -q 'CHOST_x86="$${arch}-pc-linux-gnu"' /bedrock/strata/brl-build-$${arch}/etc/portage/make.conf; then \
			sed 's/^CHOST_x86=.*//g' /bedrock/strata/brl-build-$${arch}/etc/portage/make.conf > /bedrock/strata/brl-build-$${arch}/etc/portage/make.conf-new; \
			echo "CHOST_x86=\"$${arch}-pc-linux-gnu"\" >> /bedrock/strata/brl-build-$${arch}/etc/portage/make.conf-new; \
			mv /bedrock/strata/brl-build-$${arch}/etc/portage/make.conf-new /bedrock/strata/brl-build-$${arch}/etc/portage/make.conf; \
		fi; \
		if ! strat -r brl-build-$${arch} binutils-config -c | grep -q "^$${arch}-"; then \
			strat -r brl-build-$${arch} emerge --oneshot sys-devel/binutils; \
		fi; \
		if ! strat -r brl-build-$${arch} gcc-config -c | grep -q "^$${arch}-"; then \
			strat -r brl-build-$${arch} emerge --oneshot sys-devel/gcc; \
		fi; \
		if ! [ -e /bedrock/strata/brl-build-$${arch}/.brl-build-glibc ]; then \
			strat -r brl-build-$${arch} emerge --oneshot sys-libs/glibc; \
			touch /bedrock/strata/brl-build-$${arch}/.brl-build-glibc; \
		fi; \
		if ! [ -e /bedrock/strata/brl-build-$${arch}/.brl-build-libtool ]; then \
			strat -r brl-build-$${arch} emerge --oneshot libtool; \
			strat -r brl-build-$${arch} /usr/share/gcc-data/$${arch}-pc-linux-gnu/*/fix_libtool_files.sh \
				"$$(ls -l /bedrock/strata/brl-build-$${arch}/usr/share/gcc-data/$${arch}-pc-linux-gnu)" --oldarch i486-pc-linux-gnu; \
			touch /bedrock/strata/brl-build-$${arch}/.brl-build-libtool; \
		fi; \
		if ! [ -e /bedrock/strata/brl-build-$${arch}/.brl-build-world ]; then \
			strat -r brl-build-$${arch} emerge --emptytree @world; \
			touch /bedrock/strata/brl-build-$${arch}/.brl-build-world; \
		fi; \
	done
	@ printf "\e[32m\n"
	@ echo "===================================="
	@ echo "=== Completed Build Strata Setup ==="
	@ echo "===================================="
	@ printf "\e[39m\n"

# Make job coordination gets confused across `strat`, and thus a job count must
# be explicitly set for each item here.  This limits parallelization
# opportunities.  If your system has more cores than then number of installers
# being built, set SUBJOBS to the per-ISA invocation of make its own job count.
# For example, if you have a 24 thread CPU, you can run:
#
#     make -j8 SUBJOBS=3 GPGID=... release
#
# to make eight installers at a time with a max of three jobs for each.
#
# Some resources are arch-agnostic and shared across implementations.  Make
# everything dependent on those so they only run once.
SUBJOBS=1
release-aarch64: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-aarch64 make -j$(SUBJOBS) CFLAGS='$(CFLAGS) $(RELEASE_CFLAGS)' GPGID='$(GPGID)' \
		AR='/bedrock/strata/brl-build-cross/usr/local/bin/brl-aarch64-linux-gnu-ar' \
		CC='/bedrock/strata/brl-build-cross/usr/local/bin/brl-aarch64-linux-gnu-gcc' \
		LD='/bedrock/strata/brl-build-cross/usr/local/bin/brl-aarch64-linux-gnu-ld' \
		bedrock-linux-$(BEDROCK_VERSION)-aarch64.sh
release-armv7hl: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-armv7hl make -j$(SUBJOBS) CFLAGS='$(CFLAGS) $(RELEASE_CFLAGS)' GPGID='$(GPGID)' \
		AR='/bedrock/strata/brl-build-cross/usr/local/bin/brl-arm-linux-gnueabihf-ar' \
		CC='/bedrock/strata/brl-build-cross/usr/local/bin/brl-arm-linux-gnueabihf-gcc' \
		LD='/bedrock/strata/brl-build-cross/usr/local/bin/brl-arm-linux-gnueabihf-ld' \
		bedrock-linux-$(BEDROCK_VERSION)-armv7hl.sh
release-armv7l: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-armv7l make -j$(SUBJOBS) CFLAGS='$(CFLAGS) $(RELEASE_CFLAGS)' GPGID='$(GPGID)' \
		AR='/bedrock/strata/brl-build-cross/usr/local/bin/brl-arm-linux-gnueabi-ar' \
		CC='/bedrock/strata/brl-build-cross/usr/local/bin/brl-arm-linux-gnueabi-gcc' \
		LD='/bedrock/strata/brl-build-cross/usr/local/bin/brl-arm-linux-gnueabi-ld' \
		bedrock-linux-$(BEDROCK_VERSION)-armv7l.sh
release-i386: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-i386 make -j$(SUBJOBS) CFLAGS='$(CFLAGS) $(RELEASE_CFLAGS)' GPGID='$(GPGID)' \
		bedrock-linux-$(BEDROCK_VERSION)-i386.sh
release-i486: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-i486 make -j$(SUBJOBS) CFLAGS='$(CFLAGS) $(RELEASE_CFLAGS)' GPGID='$(GPGID)' \
		bedrock-linux-$(BEDROCK_VERSION)-i486.sh
release-i586: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-i586 make -j$(SUBJOBS) CFLAGS='$(CFLAGS) $(RELEASE_CFLAGS)' GPGID='$(GPGID)' \
		bedrock-linux-$(BEDROCK_VERSION)-i586.sh
release-i686: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-i686 make -j$(SUBJOBS) CFLAGS='$(CFLAGS) $(RELEASE_CFLAGS)' GPGID='$(GPGID)' \
		bedrock-linux-$(BEDROCK_VERSION)-i686.sh
release-mips: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-mips make -j$(SUBJOBS) CFLAGS='$(CFLAGS) $(RELEASE_CFLAGS)' GPGID='$(GPGID)' \
		AR='/bedrock/strata/brl-build-cross/usr/local/bin/brl-mips-linux-gnu-ar' \
		CC='/bedrock/strata/brl-build-cross/usr/local/bin/brl-mips-linux-gnu-gcc' \
		LD='/bedrock/strata/brl-build-cross/usr/local/bin/brl-mips-linux-gnu-ld' \
		bedrock-linux-$(BEDROCK_VERSION)-mips.sh
release-mipsel: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-mipsel make -j$(SUBJOBS) CFLAGS='$(CFLAGS) $(RELEASE_CFLAGS)' GPGID='$(GPGID)' \
		AR='/bedrock/strata/brl-build-cross/usr/local/bin/brl-mipsel-linux-gnu-ar' \
		CC='/bedrock/strata/brl-build-cross/usr/local/bin/brl-mipsel-linux-gnu-gcc' \
		LD='/bedrock/strata/brl-build-cross/usr/local/bin/brl-mipsel-linux-gnu-ld' \
		bedrock-linux-$(BEDROCK_VERSION)-mipsel.sh
release-mips64el: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-mips64el make -j$(SUBJOBS) CFLAGS='$(CFLAGS) $(RELEASE_CFLAGS)' GPGID='$(GPGID)' \
		AR='/bedrock/strata/brl-build-cross/usr/local/bin/brl-mips64el-linux-gnuabi64-ar' \
		CC='/bedrock/strata/brl-build-cross/usr/local/bin/brl-mips64el-linux-gnuabi64-gcc' \
		LD='/bedrock/strata/brl-build-cross/usr/local/bin/brl-mips64el-linux-gnuabi64-ld' \
		bedrock-linux-$(BEDROCK_VERSION)-mips64el.sh
release-ppc64le: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-ppc64le make -j$(SUBJOBS) CFLAGS='$(CFLAGS) $(RELEASE_CFLAGS)' GPGID='$(GPGID)' \
		AR='/bedrock/strata/brl-build-cross-ppc/usr/local/bin/brl-powerpc64le-linux-gnu-ar' \
		CC='/bedrock/strata/brl-build-cross-ppc/usr/local/bin/brl-powerpc64le-linux-gnu-gcc' \
		LD='/bedrock/strata/brl-build-cross-ppc/usr/local/bin/brl-powerpc64le-linux-gnu-ld' \
		bedrock-linux-$(BEDROCK_VERSION)-ppc64le.sh
release-s390x: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-s390x make -j$(SUBJOBS) CFLAGS='$(CFLAGS) $(RELEASE_CFLAGS)' GPGID='$(GPGID)' \
		AR='/bedrock/strata/brl-build-cross/usr/local/bin/brl-s390x-linux-gnu-ar' \
		CC='/bedrock/strata/brl-build-cross/usr/local/bin/brl-s390x-linux-gnu-gcc' \
		LD='/bedrock/strata/brl-build-cross/usr/local/bin/brl-s390x-linux-gnu-ld' \
		bedrock-linux-$(BEDROCK_VERSION)-s390x.sh
release-x86_64: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-x86_64 make -j$(SUBJOBS) CFLAGS='$(CFLAGS) $(RELEASE_CFLAGS)' GPGID='$(GPGID)' \
		bedrock-linux-$(BEDROCK_VERSION)-x86_64.sh
release: \
	release-aarch64 \
	release-armv7hl \
	release-armv7l \
	release-i386 \
	release-i486 \
	release-i586 \
	release-i686 \
	release-mips \
	release-mipsel \
	release-mips64el \
	release-ppc64le \
	release-s390x \
	release-x86_64
	[ -e ./bedrock-linux-$(BEDROCK_VERSION)-aarch64.sh ]
	[ -e ./bedrock-linux-$(BEDROCK_VERSION)-armv7hl.sh ]
	[ -e ./bedrock-linux-$(BEDROCK_VERSION)-armv7l.sh ]
	[ -e ./bedrock-linux-$(BEDROCK_VERSION)-i386.sh ]
	[ -e ./bedrock-linux-$(BEDROCK_VERSION)-i486.sh ]
	[ -e ./bedrock-linux-$(BEDROCK_VERSION)-i586.sh ]
	[ -e ./bedrock-linux-$(BEDROCK_VERSION)-i686.sh ]
	[ -e ./bedrock-linux-$(BEDROCK_VERSION)-mips.sh ]
	[ -e ./bedrock-linux-$(BEDROCK_VERSION)-mips64el.sh ]
	[ -e ./bedrock-linux-$(BEDROCK_VERSION)-mipsel.sh ]
	[ -e ./bedrock-linux-$(BEDROCK_VERSION)-ppc64le.sh ]
	[ -e ./bedrock-linux-$(BEDROCK_VERSION)-s390x.sh ]
	[ -e ./bedrock-linux-$(BEDROCK_VERSION)-x86_64.sh ]
	@ printf "\e[32m\n"
	@ echo "=== Completed Bedrock Linux $(BEDROCK_VERSION) release build ===" | sed 's/./=/g'
	@ echo "=== Completed Bedrock Linux $(BEDROCK_VERSION) release build ==="
	@ echo "=== Completed Bedrock Linux $(BEDROCK_VERSION) release build ===" | sed 's/./=/g'
	@ printf "\e[39m\n"

