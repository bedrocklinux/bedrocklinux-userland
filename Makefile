# Bedrock Linux Makefile
#
#      This program is free software; you can redistribute it and/or
#      modify it under the terms of the GNU General Public License
#      version 2 as published by the Free Software Foundation.
#
# Copyright (c) 2012-2024 Daniel Thau <danthau@bedrocklinux.org>
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

BEDROCK_VERSION=0.7.31
CODENAME=Poki
ARCHITECTURE=$(shell ./detect_arch.sh | head -n1)
FILE_ARCH_NAME=$(shell ./detect_arch.sh | awk 'NR==2')
ARCH_BIT_DEPTH=$(shell ./detect_arch.sh | awk 'NR==3')
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
	--continuation-indentation8 --indent-label0 --case-indentation0 --line-length 120
WERROR_FLAGS=-Werror -Wall -Wextra -std=c99 -pedantic

all: $(INSTALLER)

remove_vendor_source:
	rm -rf ./vendor

fetch_vendor_sources: \
	vendor/busybox/.success_retrieving_source \
	vendor/curl/.success_retrieving_source \
	vendor/kmod/.success_retrieving_source \
	vendor/libaio/.success_retrieving_source \
	vendor/libattr/.success_retrieving_source \
	vendor/libcap/.success_fetching_source \
	vendor/libfuse/.success_fetching_source \
	vendor/linux_headers/.success_fetching_source \
	vendor/lvm2/.success_retrieving_source \
	vendor/musl/.success_fetching_source \
	vendor/netselect/.success_retrieving_source \
	vendor/openssl/.success_retrieving_source \
	vendor/uthash/.success_fetching_source \
	vendor/util-linux/.success_fetching_source \
	vendor/xz/.success_retrieving_source \
	vendor/zlib/.success_retrieving_source \
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
	mkdir -p $(SUPPORT)/include $(SUPPORT)/lib $(SUPPORT)/bin
	# Some dependencies seem to require gtkdocize with no way to opt-out.
	# Make a no-op one to fulfill the need.
	printf '#!/bin/sh\nmkdir -p libkmod/docs\ntouch libkmod/docs/gtk-doc.make' > $(SUPPORT)/bin/gtkdocize
	chmod a+rx $(SUPPORT)/bin/gtkdocize
	# copy /bedrock into build structure
	cp -r src/slash-bedrock/ $(SLASHBR)
	# create bedrock-release
	echo "$(RELEASE)" > $(SLASHBR)/etc/bedrock-release
	# create os-release
	sed -e "s,^VERSION=.*,VERSION=\"$(BEDROCK_VERSION) ($(CODENAME))\"," \
		-e "s,^VERSION_ID=.*,VERSION_ID=\"$(BEDROCK_VERSION)\"," \
		-e "s,^PRETTY_NAME=.*,PRETTY_NAME=\"$(RELEASE)\"," \
		$(SLASHBR)/etc/os-release > $(SLASHBR)/etc/os-release-new
	mv $(SLASHBR)/etc/os-release-new $(SLASHBR)/etc/os-release
	# create release-specific bedrock.conf
	mv $(SLASHBR)/etc/bedrock.conf $(SLASHBR)/etc/bedrock.conf-$(BEDROCK_VERSION)
	# move world file to temporary position so it does not overwrite
	# preexisting one during update
	mv $(SLASHBR)/etc/world $(SLASHBR)/etc/.fresh-world
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
		./configure --prefix=$(SUPPORT) --enable-static --enable-gcc-wrapper --disable-shared && \
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
	#
	# i386 requires -latomic.  If building i386, shove -latomic in here as well.
	if [ "$(ARCHITECTURE)" = "i386" ]; then \
		sed 's/ -specs/ -static -latomic -specs/' $(SUPPORT)/bin/musl-gcc > $(SUPPORT)/bin/musl-gcc-new; \
	else \
		sed 's/ -specs/ -static -specs/' $(SUPPORT)/bin/musl-gcc > $(SUPPORT)/bin/musl-gcc-new; \
	fi
	mv $(SUPPORT)/bin/musl-gcc-new $(SUPPORT)/bin/musl-gcc
	chmod a+rx $(SUPPORT)/bin/musl-gcc
	touch $(COMPLETED)/musl
musl: $(COMPLETED)/musl

vendor/libcap/.success_fetching_source:
	rm -rf vendor/libcap
	mkdir -p vendor/libcap
	git clone --depth=1 \
		-b `git ls-remote --tags 'https://git.kernel.org/pub/scm/libs/libcap/libcap.git/' | \
		awk -F/ '{print $$NF}' | \
		sed 's/^libcap-//g' | \
		grep '^[0-9.]*$$' | \
		grep '[.]' | \
		sort -t . -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | \
		tail -n1 | \
		sed 's/^/libcap-/'` 'https://git.kernel.org/pub/scm/libs/libcap/libcap.git/' \
		vendor/libcap
	touch vendor/libcap/.success_fetching_source
$(COMPLETED)/libcap: vendor/libcap/.success_fetching_source $(COMPLETED)/builddir $(COMPLETED)/musl
	rm -rf $(VENDOR)/libcap
	cp -r vendor/libcap/ $(VENDOR)
	mkdir -p $(SUPPORT)/include/sys
	if ! [ -e $(SUPPORT)/include/sys/capability.h ]; then \
		cp $(SUPPORT)/include/linux/capability.h $(SUPPORT)/include/sys/capability.h; \
	fi
	sed \
		-e 's/^BUILD_GPERF.*/BUILD_GPERF=no/' $(VENDOR)/libcap/Make.Rules \
		-e 's/^SHARED.*/SHARED=no/' $(VENDOR)/libcap/Make.Rules \
		-e 's/^DYNAMIC.*/DYNAMIC=no/' $(VENDOR)/libcap/Make.Rules \
		-e 's/^LIBCSTATIC.*/LIBCSTATIC=yes/' $(VENDOR)/libcap/Make.Rules \
		> $(VENDOR)/libcap/Make.Rules-new
	mv $(VENDOR)/libcap/Make.Rules-new $(VENDOR)/libcap/Make.Rules
	cd $(VENDOR)/libcap/libcap && \
		$(MAKE) BUILD_CC=$(MUSLCC) CC=$(MUSLCC) LD="$(MUSLCC) -Wl,-x -shared" lib=$(SUPPORT)/lib prefix=$(SUPPORT) BUILD_CFLAGS="$(CFLAGS) -static" SHARED=no DYNAMIC=no LIBCSTATIC=yes && \
		$(MAKE) install-static RAISE_SETFCAP=no DESTDIR=$(SUPPORT) prefix=/ lib=lib SHARED=no DYNAMIC=no LIBCSTATIC=yes
	cd $(VENDOR)/libcap/progs && \
		$(MAKE) BUILD_CC=$(MUSLCC) CC=$(MUSLCC) LD="$(MUSLCC) -Wl,-x -shared" lib=$(SUPPORT)/lib prefix=$(SUPPORT) LDFLAGS=-static SHARED=no DYNAMIC=no LIBCSTATIC=yes && \
		$(MAKE) install RAISE_SETFCAP=no DESTDIR=$(SUPPORT) prefix=/ lib=lib SHARED=no DYNAMIC=no LIBCSTATIC=yes
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
	# ln -s $(VENDOR)/libfuse/build/libfuse_config.h $(SUPPORT)/include/
	cd $(VENDOR)/libfuse/build && \
		CC=$(MUSLCC) CFLAGS="$(CFLAGS) -static" meson && \
		meson configure -D buildtype=release && \
		meson configure -D default_library=static && \
		meson configure -D strip=true && \
		meson configure -D prefix=$(SUPPORT) && \
		CC=$(MUSLCC) ninja lib/libfuse3.a
	cp -r $(VENDOR)/libfuse/build/lib/* $(SUPPORT)/lib/
	mkdir -p $(SUPPORT)/include/fuse3/
	cp $(VENDOR)/libfuse/include/*.h $(SUPPORT)/include/fuse3/
	cp $(VENDOR)/libfuse/build/*.h $(SUPPORT)/include/fuse3/
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
	cp $(VENDOR)/libaio/src/libaio.so.1.0.2 $(SUPPORT)/lib/libaio.so
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
	cp $(VENDOR)/util-linux/.libs/libblkid.* $(SUPPORT)/lib || true
	cp $(VENDOR)/util-linux/.libs/libuuid.* $(SUPPORT)/lib || true
	touch $(COMPLETED)/util-linux
util-linux: $(COMPLETED)/util-linux

vendor/openssl/.success_retrieving_source:
	rm -rf vendor/openssl
	mkdir -p vendor/openssl
	git clone --depth=1 \
		-b `git ls-remote --tags 'https://github.com/openssl/openssl.git' | \
		awk -F/ '{print $$NF}' | \
		grep '^OpenSSL_1_1_[0-9a-z]*$$' | \
		sort -t '_' -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | \
		tail -n1` 'https://github.com/openssl/openssl.git' \
		vendor/openssl
	touch vendor/openssl/.success_retrieving_source
$(COMPLETED)/openssl: vendor/openssl/.success_retrieving_source $(COMPLETED)/builddir $(COMPLETED)/musl
	rm -rf $(VENDOR)/openssl
	cp -r vendor/openssl $(VENDOR)
	cd $(VENDOR)/openssl && \
		if [ "$(ARCHITECTURE)" = "mips64el" ]; then \
			CC=$(MUSLCC) linux$(ARCH_BIT_DEPTH) ./Configure --prefix="$(SUPPORT)" no-shared linux64-mips64; \
		elif [ "$(ARCHITECTURE)" = "ppc64" ]; then \
			CC=$(MUSLCC) linux$(ARCH_BIT_DEPTH) ./Configure --prefix="$(SUPPORT)" no-shared linux-ppc64le; \
		elif [ "$(ARCHITECTURE)" = "armv7hl" ]; then \
			CC=$(MUSLCC) linux$(ARCH_BIT_DEPTH) ./Configure --prefix="$(SUPPORT)" no-shared linux-armv4; \
		else \
			CC=$(MUSLCC) linux$(ARCH_BIT_DEPTH) ./config --prefix="$(SUPPORT)" no-shared; \
		fi && \
		$(MAKE) CC=$(MUSLCC) && \
		$(MAKE) install_sw && \
		$(MAKE) clean # openssl tests use quite a lot of disk
	touch $(COMPLETED)/openssl
openssl: $(COMPLETED)/openssl

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
	# patch in "x-" option support
	cd vendor/busybox/ && patch -p1 < ../../src/patches/busybox-x-opt.patch
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
		./set_bb_option "CONFIG_FEATURE_FDISK_ADVANCED" "n" && \
		./set_bb_option "CONFIG_FEATURE_FIND_MMIN" "y" && \
		./set_bb_option "CONFIG_FEATURE_FIND_XDEV" "y" && \
		./set_bb_option "CONFIG_FEATURE_GPT_LABEL" "y" && \
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
		./set_bb_option "CONFIG_PIVOT_ROOT" "y" && \
		./set_bb_option "CONFIG_RMMOD" "y" && \
		./set_bb_option "CONFIG_STATIC" "y" && \
		./set_bb_option "CONFIG_SYSROOT" "\"\"" && \
		./set_bb_option "CONFIG_TEST" "y" && \
		./set_bb_option "CONFIG_TEST1" "y" && \
		./set_bb_option "CONFIG_VI" "y" && \
		./set_bb_option "CONFIG_DEPMOD" "n" && \
		./set_bb_option "CONFIG_INSMOD" "n" && \
		./set_bb_option "CONFIG_LSMOD" "n" && \
		./set_bb_option "CONFIG_MODPROBE" "n" && \
		./set_bb_option "CONFIG_RMMOD" "n" && \
		./set_bb_option "CONFIG_WGET" "n"
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
	# http://git.musl-libc.org/cgit/musl/commit/?id=5a105f19b5aae79dd302899e634b6b18b3dcd0d6
	# This will be needed with musl at or after 1.2.0 and busybox preceding 1.32
	cd $(VENDOR)/busybox && \
		if [ "${ARCH_BIT_DEPTH}" = "32" ]; then \
			for file in libbb/time.c runit/runsv.c coreutils/date.c; do \
				sed -e 's/__NR_clock_gettime\>/__NR_clock_gettime32/g' $${file} > .time-tmp && \
				mv .time-tmp $${file}; \
			done; \
		fi
	cd $(VENDOR)/busybox && \
		$(MAKE) CC=$(MUSLCC) && \
		cp busybox $(SLASHBR)/libexec/busybox
busybox: $(SLASHBR)/libexec/busybox

vendor/curl/.success_retrieving_source:
	rm -rf vendor/curl
	mkdir -p vendor/curl
	git clone --depth=1 \
		-b `git ls-remote --tags 'https://github.com/curl/curl.git' | \
		awk -F/ '{print $$NF}' | \
		grep '^curl-[0-9_]*$$' | \
		sort -t '_' -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | \
		tail -n1` 'https://github.com/curl/curl.git' \
		vendor/curl
	touch vendor/curl/.success_retrieving_source
$(SLASHBR)/libexec/curl: vendor/curl/.success_retrieving_source $(COMPLETED)/builddir $(COMPLETED)/musl $(COMPLETED)/openssl
	rm -rf $(VENDOR)/curl
	cp -r vendor/curl $(VENDOR)
	cd $(VENDOR)/curl && autoreconf -fi && \
		CC=$(MUSLCC) CFLAGS="-I$(SUPPORT)/include -L$(SUPPORT)/lib" ./configure --with-openssl --enable-static --disable-shared --enable-https --enable-ipv6 && \
		$(MAKE) CC=$(MUSLCC) CFLAGS="-I$(SUPPORT)/include -L$(SUPPORT)/lib" && \
		cp src/curl $(SLASHBR)/libexec/curl
curl: $(SLASHBR)/libexec/curl

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
	#
	# Use hard-coded version to avoid breaking patch compatibility
	# git clone \
	# 	-b `git ls-remote --tags 'https://sourceware.org/git/lvm2.git' | \
	# 	awk -F/ '{print $$NF}' | \
	# 	grep '^v[0-9_]*$$' | \
	# 	sed 's/^v//g' | \
	# 	sort -t _ -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | \
	# 	tail -n1 | \
	# 	sed 's/^/v/'` 'https://sourceware.org/git/lvm2.git' \
	# 	vendor/lvm2
	git clone -b v2_03_34 'https://sourceware.org/git/lvm2.git' vendor/lvm2
	cd vendor/lvm2 && patch -p1 -i ../../patches/lvm2/fix-stdio.patch
	# hack to fix bad imports looking for LOCK_EX
	echo '#include <sys/file.h>' >> vendor/lvm2/lib/misc/lib.h
	touch vendor/lvm2/.success_retrieving_source
$(COMPLETED)/lvm2: vendor/lvm2/.success_retrieving_source $(COMPLETED)/musl $(COMPLETED)/libaio $(COMPLETED)/util-linux
	rm -rf $(VENDOR)/lvm2
	cp -r vendor/lvm2 $(VENDOR)
	cd $(VENDOR)/lvm2 && \
		CC=$(MUSLCC) CFLAGS="-I$(SUPPORT)/include -L$(SUPPORT)/lib -fPIC" ./configure --disable-udev-systemd-background-jobs --disable-blkid_wiping --disable-selinux --enable-static_link && \
		$(MAKE) tools SHELL=bash CC=$(MUSLCC) CFLAGS="-I$(SUPPORT)/include -L$(SUPPORT)/lib -L$(VENDOR)/lvm2/libdm/ioctl -fPIC" interfacebuilddir=$(VENDOR)/lvm2/libdm/ioctl
	cd $(VENDOR)/lvm2/libdm/dm-tools && \
		$(MAKE) SHELL=bash CC=$(MUSLCC) CFLAGS="-I$(SUPPORT)/include -L$(SUPPORT)/lib -L$(VENDOR)/lvm2/libdm/ioctl -fPIC" interfacebuilddir=$(VENDOR)/lvm2/libdm/ioctl
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
$(COMPLETED)/zstd: vendor/zstd/.success_retrieving_source $(COMPLETED)/musl
	rm -rf $(VENDOR)/zstd
	cp -r vendor/zstd $(VENDOR)
	cd $(VENDOR)/zstd && \
		$(MAKE) CC=$(MUSLCC) zstd lib prefix=$(SUPPORT) install && \
		cp zstd $(SLASHBR)/libexec/zstd
	touch $(COMPLETED)/zstd
$(SLASHBR)/libexec/zstd: $(COMPLETED)/zstd
zstd: $(COMPLETED)/zstd

vendor/zlib/.success_retrieving_source:
	rm -rf vendor/zlib/
	mkdir -p vendor/zlib
	cd vendor/zlib && wget -O- 'http://zlib.net/zlib-1.3.1.tar.gz' | gunzip | tar xf -
	mv vendor/zlib/*/* vendor/zlib/
	touch vendor/zlib/.success_retrieving_source
$(COMPLETED)/zlib: vendor/zlib/.success_retrieving_source $(COMPLETED)/musl
	rm -rf $(VENDOR)/zlib
	cp -r vendor/zlib $(VENDOR)
	cd $(VENDOR)/zlib && \
		./configure --prefix=$(SUPPORT) --static && \
		$(MAKE) CC=$(MUSLCC) install prefix=$(SUPPORT)
	touch $(COMPLETED)/zlib
zlib: $(COMPLETED)/zlib

# Hard code v5.4.6 until xz CVE is resolved
# https://nvd.nist.gov/vuln/detail/CVE-2024-3094
# https://www.openwall.com/lists/musl/2022/08/23/5
vendor/xz/.success_retrieving_source:
	rm -rf vendor/xz/
	mkdir -p vendor/xz
	git clone \
		-b v5.4.6 \
		'https://git.tukaani.org/xz.git' \
		vendor/xz
	# sanity check branch is expected commit
	cd vendor/xz/ && git show | head -n1 | grep -q 'commit 6e8732c5a317a349986a4078718f1d95b67072c5'
	touch vendor/xz/.success_retrieving_source
$(COMPLETED)/xz: vendor/xz/.success_retrieving_source $(COMPLETED)/musl
	rm -rf $(VENDOR)/xz
	cp -r vendor/xz $(VENDOR)
	cd $(VENDOR)/xz && \
		./autogen.sh --no-po4a --no-doxygen
	cd $(VENDOR)/xz && \
		CFLAGS="-static" LDFLAGS="-static" ./configure --prefix=$(SUPPORT) --enable-static --disable-shared
	cd $(VENDOR)/xz && $(MAKE) CC=$(MUSLCC) install prefix=$(SUPPORT)
	rm $(SUPPORT)/lib/liblzma.la
	touch $(COMPLETED)/xz
xz: $(COMPLETED)/xz

# Build our own kmod suite, rather than using busybox's, for .ko.zst support.
vendor/kmod/.success_retrieving_source:
	rm -rf vendor/kmod/
	mkdir -p vendor/kmod
	git clone --depth 1 \
		-b `git ls-remote --tags 'https://git.kernel.org/pub/scm/utils/kernel/kmod/kmod.git' | \
		awk -F/ '{print $$NF}' | \
		sed -e 's/^v//g' | \
		grep '^[0-9.]*$$' | \
		sort -t . -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | \
		tail -n1 | \
		sed -e 's/^/v/'` 'https://git.kernel.org/pub/scm/utils/kernel/kmod/kmod.git' \
		vendor/kmod
	touch vendor/kmod/.success_retrieving_source
$(SLASHBR)/libexec/kmod: vendor/kmod/.success_retrieving_source $(COMPLETED)/musl $(COMPLETED)/zstd $(COMPLETED)/zlib $(COMPLETED)/xz
	rm -rf $(VENDOR)/kmod
	cp -r vendor/kmod $(VENDOR)
	cd $(VENDOR)/kmod && \
		PATH="$(SUPPORT)/bin:${PATH}" ./autogen.sh --with-xz --with-zlib --with-zstd --disable-manpages --prefix=$(SUPPORT) --includedir=$(SUPPORT)/include --libdir=$(SUPPORT)/lib --bindir=$(SUPPORT)/bin \
			CC=$(MUSLCC) CCLD=$(MUSLCC) LD=$(MUSLCC) PKG_CONFIG_PATH=$(SUPPORT)/lib/pkgconfig && \
		./configure --with-xz --with-zlib --with-zstd --disable-manpages --prefix=$(SUPPORT) --includedir=$(SUPPORT)/include --libdir=$(SUPPORT)/lib --bindir=$(SUPPORT)/bin \
			CC=$(MUSLCC) LDFLAGS="-L$(SUPPORT)/lib" PKG_CONFIG_PATH=$(SUPPORT)/lib/pkgconfig && \
		$(MAKE) CC=$(MUSLCC) LDFLAGS="-L$(SUPPORT)/lib" PKG_CONFIG_PATH=$(SUPPORT)/lib/pkgconfig tools/kmod
	cp $(VENDOR)/kmod/tools/kmod $(SLASHBR)/libexec/kmod
kmod: $(SLASHBR)/libexec/kmod

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

$(SLASHBR)/libexec/plymouth-quit: $(COMPLETED)/builddir $(COMPLETED)/musl
	rm -rf $(SRC)/plymouth-quit
	cp -r src/plymouth-quit/ $(SRC)
	cd $(SRC)/plymouth-quit && \
		$(MAKE) CC=$(MUSLCC) && \
		cp plymouth-quit $(SLASHBR)/libexec/plymouth-quit
plymouth-quit: $(SLASHBR)/libexec/plymouth-quit

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
	$(SLASHBR)/libexec/curl \
	$(SLASHBR)/libexec/dmsetup \
	$(SLASHBR)/libexec/etcfs \
	$(SLASHBR)/libexec/getfattr \
	$(SLASHBR)/libexec/keyboard_is_present \
	$(SLASHBR)/libexec/kmod \
	$(SLASHBR)/libexec/lvm \
	$(SLASHBR)/libexec/manage_tty_lock \
	$(SLASHBR)/libexec/netselect \
	$(SLASHBR)/libexec/plymouth-quit \
	$(SLASHBR)/libexec/setcap \
	$(SLASHBR)/libexec/setfattr \
	$(SLASHBR)/libexec/zstd
	# remove symlinks which may have been created in a previous interrupted run
	rm -f $(SLASHBR)/libexec/brl-strat
	rm -f $(SLASHBR)/strata/init
	rm -f $(SLASHBR)/strata/local
	# ensure static
	if [ -z "$${BEDROCK_SKIP_LDD_CHECK}" ]; then \
		for bin in $(SLASHBR)/bin/* $(SLASHBR)/libexec/*; do \
			if ldd "$$bin" >/dev/null 2>&1 || ! ldd "$$bin" 2>&1 | grep -q "not a dynamic executable" ; then \
				echo "error: $$bin is dynamically linked"; exit 1; \
			fi; \
		done; \
	fi
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
	# qemu does not play nicely with fakeroot.  In case we are using qemu
	# strata to build non-native arches, try to grab native fakeroot.
	cd $(BUILD) && if [ -e /bedrock/cross/bin/fakeroot ]; then \
		/bedrock/cross/bin/fakeroot tar cf userland.tar-new bedrock/ sbin/init; \
	else \
		fakeroot tar cf userland.tar-new bedrock/ sbin/init; \
	fi
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
	@ printf "\e[32m\n%s\n%s\n%s\n\e[39m\n" \
		"$$(echo "=== Completed creating $(INSTALLER) ===" | sed 's/./=/g')" \
		"$$(echo "=== Completed creating $(INSTALLER) ===")" \
		"$$(echo "=== Completed creating $(INSTALLER) ===" | sed 's/./=/g')"

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
	@ printf "\e[32m\n%s\n%s\n%s\n\e[39m\n" \
		"$$(echo "=== Completed formatting code base ===" | sed 's/./=/g')" \
		"$$(echo "=== Completed formatting code base ===")" \
		"$$(echo "=== Completed formatting code base ===" | sed 's/./=/g')"

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
	# - SC2039, SC3012: `[ \< ]` and `[ \> ]` are non-POSIX.  However, they do work
	#   with busybox.
	# - SC3045, SC3040, SC3043: busybox-ism is okay
	# - SC1090: Can't follow dynamic sources.  That's fine, we know where
	#   they are and are including them in the list to be checked.
	export EXCLUDE="SC1008,SC2059,SC2039,SC1090,SC3012,SC3045,SC3040,SC3043"; \
	for file in $$(find src/ -type f); do \
		if head -n1 "$$file" | grep -q '^#!.*busybox sh$$'; then \
			echo "checking shell file $$file"; \
			shellcheck -x -s sh --exclude="$${EXCLUDE}" "$$file" || exit 1; \
			! cat "$$file" | shfmt -p -d | grep '.' || exit 1; \
		elif head -n1 "$$file" | grep -q '^#!.*bash$$'; then \
			echo "checking bash file $$file"; \
			shellcheck -x -s bash --exclude="$${EXCLUDE}" "$$file" || exit 1; \
			! cat "$$file" | shfmt -ln bash -d | grep '.' || exit 1; \
		elif head -n1 "$$file" | grep -q -e '^#!.*zsh$$' -e '^#compdef' "$$file"; then \
			echo "checking zsh file $$file"; \
			shellcheck -x -s bash --exclude="$${EXCLUDE}" "$$file" || exit 1; \
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
	@ printf "\e[32m\n%s\n%s\n%s\n\e[39m\n" \
		"$$(echo "=== All static analysis checks pass ===" | sed 's/./=/g')" \
		"$$(echo "=== All static analysis checks pass ===")" \
		"$$(echo "=== All static analysis checks pass ===" | sed 's/./=/g')"

#
# Release build environment setup
#

release-build-environment-cross-void:
	[ $$(id -u) = 0 ]
	if ! /bedrock/libexec/getfattr -d /bedrock/strata/brl-build-cross-void 2>/dev/null | grep -q user.bedrock.show_boot; then \
		brl remove -d brl-build-cross-void 2>/dev/null || true; \
		brl fetch -s -n brl-build-cross-void void; \
		brl show -b brl-build-cross-void; \
	fi
	strat -r brl-build-cross-void xbps-install -y \
		cross-aarch64-linux-musl \
		cross-mipsel-linux-musl \
		cross-powerpc-linux-musl \
		cross-powerpc64-linux-musl \
		cross-powerpc64le-linux-musl
	for target in \
			aarch64-linux-musl \
			mipsel-linux-musl \
			powerpc-linux-musl \
			powerpc64-linux-musl \
			powerpc64le-linux-musl \
			; do \
		for tool in gcc ld ar; do \
			if ! [ -x "/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-$${target}-$${tool}" ] && \
					[ -x /bedrock/strata/brl-build-cross-void/usr/bin/$${target}-$${tool} ]; then \
				printf '#!/bedrock/libexec/busybox sh\nexec /bedrock/bin/strat -r brl-build-cross-void /usr/bin/'"$${target}-$${tool}"' "$${@}"\n' > \
					"/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-$${target}-$${tool}"; \
				chmod a+rx "/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-$${target}-$${tool}"; \
			fi; \
		done; \
	done

release-build-environment-cross-debian:
	[ $$(id -u) = 0 ]
	if ! /bedrock/libexec/getfattr -d /bedrock/strata/brl-build-cross-debian 2>/dev/null | grep -q user.bedrock.show_boot; then \
		brl remove -d brl-build-cross-debian 2>/dev/null || true; \
		brl fetch -s -n brl-build-cross-debian debian; \
		brl show -b brl-build-cross-debian; \
	fi
	strat -r brl-build-cross-debian apt -y install \
			gcc-arm-linux-gnueabihf binutils-arm-linux-gnueabihf \
			gcc-arm-linux-gnueabi binutils-arm-linux-gnueabi \
			gcc-mips64el-linux-gnuabi64 binutils-mips64el-linux-gnuabi64 \
			gcc-s390x-linux-gnu binutils-s390x-linux-gnu
	for target in arm-linux-gnueabihf \
			arm-linux-gnueabi \
			mips64el-linux-gnuabi64 \
			s390x-linux-gnu \
			; do \
		for tool in gcc ld ar; do \
			if ! [ -x "/bedrock/strata/brl-build-cross-debian/usr/local/bin/brl-$${target}-$${tool}" ] && \
					[ -x /bedrock/strata/brl-build-cross-debian/usr/bin/$${target}-$${tool} ]; then \
				printf '#!/bedrock/libexec/busybox sh\nexec /bedrock/bin/strat -r brl-build-cross-debian /usr/bin/'"$${target}-$${tool}"' "$${@}"\n' > \
					"/bedrock/strata/brl-build-cross-debian/usr/local/bin/brl-$${target}-$${tool}"; \
				chmod a+rx "/bedrock/strata/brl-build-cross-debian/usr/local/bin/brl-$${target}-$${tool}"; \
			fi; \
		done; \
	done

release-build-environment-aarch64 release-build-environment-armv7hl release-build-environment-armv7l release-build-environment-i686 release-build-environment-mipsel  release-build-environment-mips64el release-build-environment-ppc64le release-build-environment-s390x release-build-environment-x86_64:
	[ $$(id -u) = 0 ]
	if ! /bedrock/libexec/getfattr -d /bedrock/strata/brl-build-$(subst release-build-environment-,,$@) 2>/dev/null | grep -q user.bedrock.show_boot; then \
		brl remove -d "brl-build-$(subst release-build-environment-,,$@)" 2>/dev/null || true; \
		brl fetch -n "brl-build-$(subst release-build-environment-,,$@)" -a "$(subst release-build-environment-,,$@)" -s debian; \
		brl show -b "brl-build-$(subst release-build-environment-,,$@)"; \
	fi
	strat -r "brl-build-$(subst release-build-environment-,,$@)" apt -y install autoconf autopoint automake bison build-essential fakeroot flex gpg libtool meson ninja-build pkg-config rsync udev; \

release-build-environment-i486 release-build-environment-ppc release-build-environment-ppc64:
	[ $$(id -u) = 0 ]
	if ! /bedrock/libexec/getfattr -d /bedrock/strata/brl-build-$(subst release-build-environment-,,$@) 2>/dev/null | grep -q user.bedrock.show_boot; then \
		brl remove -d "brl-build-$(subst release-build-environment-,,$@)" 2>/dev/null || true; \
		brl fetch -n "brl-build-$(subst release-build-environment-,,$@)" -a "$(subst release-build-environment-,,$@)" -s gentoo; \
		brl show -b "brl-build-$(subst release-build-environment-,,$@)"; \
	fi
	# qemu does not seem to support various namespace/sandboxing technologies
	# https://bugs.launchpad.net/qemu/+bug/1829459
	if ! grep -q 'FEATURES="-pid-sandbox -network-sandbox -ipc-sandbox"' /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/portage/make.conf; then \
		echo 'FEATURES="-pid-sandbox -network-sandbox -ipc-sandbox"' >> /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/portage/make.conf; \
	fi
	for pkg in meson ninja fakeroot; do \
		if ! grep -q "$${pkg}" /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/var/lib/portage/world; then \
			strat -r brl-build-$(subst release-build-environment-,,$@) sh -c ". /etc/profile && emerge \"$${pkg}\""; \
		fi; \
	done
	strat -r brl-build-$(subst release-build-environment-,,$@) libtool --finish /usr/lib; \
	# i386 and i486 both need -latomic
	# https://stackoverflow.com/questions/35884832/compile-error-undefined-reference-to-atomic-fetch-add-4/47498167#47498167
	if echo $@ | grep -q -e i386 -e i486 && ! grep -q -- "-latomic" /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/portage/make.conf; then \
		sed "s/COMMON_FLAGS=\"/COMMON_FLAGS=\"-latomic /g" /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/portage/make.conf > /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/portage/make.conf-new && \
		mv /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/portage/make.conf-new /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/portage/make.conf; \
	fi

# No supported distro has these natively, but gentoo can be fetched as i486 then have gcc recompiled
release-build-environment-i386 release-build-environment-i586:
	[ $$(id -u) = 0 ]
	if ! /bedrock/libexec/getfattr -d /bedrock/strata/brl-build-$(subst release-build-environment-,,$@) 2>/dev/null | grep -q user.bedrock.show_boot; then \
		brl remove -d "brl-build-$(subst release-build-environment-,,$@)" 2>/dev/null || true; \
		brl fetch -n "brl-build-$(subst release-build-environment-,,$@)" -a "i486" -s gentoo; \
		brl show -b "brl-build-$(subst release-build-environment-,,$@)"; \
	fi
	# qemu does not seem to support various namespace/sandboxing technologies
	# https://bugs.launchpad.net/qemu/+bug/1829459
	if ! grep -q 'FEATURES="-pid-sandbox -network-sandbox -ipc-sandbox"' /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/portage/make.conf; then \
		echo 'FEATURES="-pid-sandbox -network-sandbox -ipc-sandbox"' >> /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/portage/make.conf; \
	fi
	# i386 and i486 both need -latomic
	# https://stackoverflow.com/questions/35884832/compile-error-undefined-reference-to-atomic-fetch-add-4/47498167#47498167
	if echo $@ | grep -q -e i386 -e i486 && ! grep -q -- "-latomic" /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/portage/make.conf; then \
		sed "s/COMMON_FLAGS=\"/COMMON_FLAGS=\"-latomic /g" /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/portage/make.conf > /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/portage/make.conf-new && \
		mv /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/portage/make.conf-new /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/portage/make.conf; \
	fi
	# Recompile to target architecture
	if grep -q "i486" /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/portage/make.conf; then \
		sed "s/i486/$(subst release-build-environment-,,$@)/g" /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/portage/make.conf > /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/portage/make.conf-new && \
		mv /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/portage/make.conf-new /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/portage/make.conf; \
	fi
	if ! grep -q 'CHOST_x86="$(subst release-build-environment-,,$@)-pc-linux-gnu"' /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/portage/make.conf; then \
		sed 's/^CHOST_x86=.*//g' /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/portage/make.conf > /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/portage/make.conf-new && \
		echo "CHOST_x86=\"$(subst release-build-environment-,,$@)-pc-linux-gnu"\" >> /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/portage/make.conf-new && \
		mv /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/portage/make.conf-new /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/portage/make.conf; \
	fi
	if ! strat -r brl-build-$(subst release-build-environment-,,$@) binutils-config -c | grep -q "^$(subst release-build-environment-,,$@)-"; then \
		strat -r brl-build-$(subst release-build-environment-,,$@) sh -c '. /etc/profile && emerge --oneshot sys-devel/binutils'; \
	fi
	if ! strat -r brl-build-$(subst release-build-environment-,,$@) gcc-config -c | grep -q "^$(subst release-build-environment-,,$@)-"; then \
		strat -r brl-build-$(subst release-build-environment-,,$@) sh -c '. /etc/profile && emerge --oneshot sys-devel/gcc'; \
		cp /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/usr/lib/gcc/*/*/libatomic* \
			/bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/usr/lib/; \
	fi
	# Normally next one would recompile glibc, libtool, and @world.
	# However, Gentoo doesn't like this for whatever reason.  Happily,
	# since we are using these tools to build against a self-contained libc
	# stack recompiling things like glibc, libtool, and @world are not
	# necessary.  Instead, just hack in an ld.so.cache update to use this compiler.
	if grep -q "i486-pc-linux-gnu/[0-9.]*/libgcc_s.so.1" /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/ld.so.cache; then \
		sed "s,i486\(-pc-linux-gnu/[0-9.]*/libgcc_s.so.1\),$(subst release-build-environment-,,$@)\\1,g" \
			/bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/ld.so.cache > \
				/bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/ld.so.cache-new && \
			mv /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/ld.so.cache-new \
				/bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/etc/ld.so.cache; \
	fi
	# Install required build tools
	for pkg in meson ninja fakeroot; do \
		if ! grep -q "$${pkg}" /bedrock/strata/brl-build-$(subst release-build-environment-,,$@)/var/lib/portage/world; then \
			strat -r brl-build-$(subst release-build-environment-,,$@) sh -c ". /etc/profile && emerge \"$${pkg}\""; \
		fi; \
	done

release-build-environment: \
	release-build-environment-cross-void \
	release-build-environment-cross-debian \
	release-build-environment-aarch64 \
	release-build-environment-armv7hl \
	release-build-environment-armv7l \
	release-build-environment-i386 \
	release-build-environment-i486 \
	release-build-environment-i586 \
	release-build-environment-i686 \
	release-build-environment-mips64el \
	release-build-environment-mipsel \
	release-build-environment-ppc \
	release-build-environment-ppc64 \
	release-build-environment-ppc64le \
	release-build-environment-s390x \
	release-build-environment-x86_64
	# This build system handles non-native CPU ISAs builds by leveraging
	# qemu to run build scripts and makefiles that may not be cross-compile
	# friendly while running performance sensitive components such as the
	# compiler with the native ISA configured to cross compile.
	#
	# This recipe fetches and sets up one stratum per ISA to run the
	# scripts and makefiles (brl-build-<arch>) and two which provide
	# cross-compile tools (brl-build-cross-debian and
	# brl-build-cross-void).
	#
	# These strata are hidden from everything but boot-time-enable to avoid
	# polluting the PATH.
	#
	@ printf "\e[32m\n%s\n%s\n%s\n\e[39m\n" \
		"$$(echo "=== Completed Build Strata Setup ===" | sed 's/./=/g')" \
		"$$(echo "=== Completed Build Strata Setup ===")" \
		"$$(echo "=== Completed Build Strata Setup ===" | sed 's/./=/g')"

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
# At the time of writing, there are five items which can be compiled natively
# on x86_64 which take a relatively negligible amount of time, and ten items
# that have to be run through qemu and compose the majority of the build time.
# Consider optimizing the job distribution with this in mind.  For example, a
# 24 thread CPU may get better build times if slightly over registered to
#
#     make -j10 SUBJOBS=3 GPGID=... release
#
# than with the more natural 8-by-3 split.
#
# Some resources are arch-agnostic and shared across implementations.  Make
# everything dependent on those so they only run once.
SUBJOBS=1
release-aarch64: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-aarch64 make -j$(SUBJOBS) GPGID='$(GPGID)' BEDROCK_SKIP_LDD_CHECK=1 \
		AR='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-aarch64-linux-musl-ar' \
		CC='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-aarch64-linux-musl-gcc' \
		LD='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-aarch64-linux-musl-ld' \
		musl
	cp /bedrock/strata/brl-build-cross-void/usr/aarch64-linux-musl/usr/lib/libssp_nonshared.a $(ROOT)/build/aarch64/support/lib/
	strat -r brl-build-aarch64 make -j$(SUBJOBS) GPGID='$(GPGID)' BEDROCK_SKIP_LDD_CHECK=1 \
		AR='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-aarch64-linux-musl-ar' \
		CC='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-aarch64-linux-musl-gcc' \
		LD='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-aarch64-linux-musl-ld' \
		bedrock-linux-$(BEDROCK_VERSION)-aarch64.sh
release-armv7hl: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-armv7hl make -j$(SUBJOBS) GPGID='$(GPGID)' \
		AR='/bedrock/strata/brl-build-cross-debian/usr/local/bin/brl-arm-linux-gnueabihf-ar' \
		CC='/bedrock/strata/brl-build-cross-debian/usr/local/bin/brl-arm-linux-gnueabihf-gcc' \
		LD='/bedrock/strata/brl-build-cross-debian/usr/local/bin/brl-arm-linux-gnueabihf-ld' \
		bedrock-linux-$(BEDROCK_VERSION)-armv7hl.sh
release-armv7l: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-armv7l make -j$(SUBJOBS) GPGID='$(GPGID)' \
		AR='/bedrock/strata/brl-build-cross-debian/usr/local/bin/brl-arm-linux-gnueabi-ar' \
		CC='/bedrock/strata/brl-build-cross-debian/usr/local/bin/brl-arm-linux-gnueabi-gcc' \
		LD='/bedrock/strata/brl-build-cross-debian/usr/local/bin/brl-arm-linux-gnueabi-ld' \
		bedrock-linux-$(BEDROCK_VERSION)-armv7l.sh
release-i386: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-i386 make -j$(SUBJOBS) GPGID='$(GPGID)' CFLAGS='$(CFLAGS) -fno-stack-protector' \
		bedrock-linux-$(BEDROCK_VERSION)-i386.sh
release-i486: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-i486 make -j$(SUBJOBS) GPGID='$(GPGID)' CFLAGS='$(CFLAGS) -fno-stack-protector' \
		bedrock-linux-$(BEDROCK_VERSION)-i486.sh
release-i586: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-i586 make -j$(SUBJOBS) GPGID='$(GPGID)' CFLAGS='$(CFLAGS) -fno-stack-protector' \
		bedrock-linux-$(BEDROCK_VERSION)-i586.sh
release-i686: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-i686 make -j$(SUBJOBS) GPGID='$(GPGID)' \
		bedrock-linux-$(BEDROCK_VERSION)-i686.sh
# Void's cross-mipsel-linux-musl-libc currently seems to be broken, confused by `-EL` (little-endian).
# Fall back to slow qemu-based compilation for now.
#release-mipsel: fetch_vendor_sources build/all/busybox/bedrock-config
#	strat -r brl-build-mipsel make -j$(SUBJOBS) GPGID='$(GPGID)' \
#		AR='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-mipsel-linux-musl-ar' \
#		CC='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-mipsel-linux-musl-gcc' \
#		LD='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-mipsel-linux-musl-ld' \
#		musl
#	cp /bedrock/strata/brl-build-cross-void/usr/mipsel-linux-musl/usr/lib/libssp_nonshared.a $(ROOT)/build/mipsel/support/lib/
#	strat -r brl-build-mipsel make -j$(SUBJOBS) GPGID='$(GPGID)' \
#		AR='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-mipsel-linux-musl-ar' \
#		CC='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-mipsel-linux-musl-gcc' \
#		LD='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-mipsel-linux-musl-ld' \
#		bedrock-linux-$(BEDROCK_VERSION)-mipsel.sh
release-mipsel: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-mipsel make -j$(SUBJOBS) GPGID='$(GPGID)' \
		bedrock-linux-$(BEDROCK_VERSION)-mipsel.sh
release-mips64el: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-mips64el make -j$(SUBJOBS) GPGID='$(GPGID)' \
		AR='/bedrock/strata/brl-build-cross-debian/usr/local/bin/brl-mips64el-linux-gnuabi64-ar' \
		CC='/bedrock/strata/brl-build-cross-debian/usr/local/bin/brl-mips64el-linux-gnuabi64-gcc' \
		LD='/bedrock/strata/brl-build-cross-debian/usr/local/bin/brl-mips64el-linux-gnuabi64-ld' \
		bedrock-linux-$(BEDROCK_VERSION)-mips64el.sh
release-ppc: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-ppc make -j$(SUBJOBS) GPGID='$(GPGID)' \
		AR='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-powerpc-linux-musl-ar' \
		CC='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-powerpc-linux-musl-gcc' \
		LD='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-powerpc-linux-musl-gcc' \
		musl
	cp /bedrock/strata/brl-build-cross-void/usr/powerpc-linux-musl/usr/lib/libssp_nonshared.a $(ROOT)/build/ppc/support/lib/
	cp /bedrock/strata/brl-build-cross-void/usr/powerpc-linux-musl/usr/lib/libatomic* $(ROOT)/build/ppc/support/lib/
	strat -r brl-build-ppc make -j$(SUBJOBS) GPGID='$(GPGID)' \
		AR='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-powerpc-linux-musl-ar' \
		CC='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-powerpc-linux-musl-gcc' \
		LD='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-powerpc-linux-musl-gcc' \
		bedrock-linux-$(BEDROCK_VERSION)-ppc.sh
release-ppc64: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-ppc64 make -j$(SUBJOBS) GPGID='$(GPGID)' \
		AR='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-powerpc64-linux-musl-ar' \
		CC='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-powerpc64-linux-musl-gcc' \
		LD='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-powerpc64-linux-musl-gcc' \
		musl
	cp /bedrock/strata/brl-build-cross-void/usr/powerpc64-linux-musl/usr/lib/libssp_nonshared.a $(ROOT)/build/ppc64/support/lib/
	cp /bedrock/strata/brl-build-cross-void/usr/powerpc64-linux-musl/usr/lib/libatomic* $(ROOT)/build/ppc64/support/lib/
	strat -r brl-build-ppc64 make -j$(SUBJOBS) GPGID='$(GPGID)' \
		AR='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-powerpc64-linux-musl-ar' \
		CC='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-powerpc64-linux-musl-gcc' \
		LD='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-powerpc64-linux-musl-gcc' \
		bedrock-linux-$(BEDROCK_VERSION)-ppc64.sh
release-ppc64le: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-ppc64le make -j$(SUBJOBS) GPGID='$(GPGID)' \
		AR='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-powerpc64le-linux-musl-ar' \
		CC='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-powerpc64le-linux-musl-gcc' \
		LD='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-powerpc64le-linux-musl-ld' \
		musl
	cp /bedrock/strata/brl-build-cross-void/usr/powerpc64le-linux-musl/usr/lib/libssp_nonshared.a $(ROOT)/build/ppc64le/support/lib/
	cp /bedrock/strata/brl-build-cross-void/usr/powerpc64le-linux-musl/usr/lib/libatomic* $(ROOT)/build/ppc64le/support/lib/
	strat -r brl-build-ppc64le make -j$(SUBJOBS) GPGID='$(GPGID)' \
		AR='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-powerpc64le-linux-musl-ar' \
		CC='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-powerpc64le-linux-musl-gcc' \
		LD='/bedrock/strata/brl-build-cross-void/usr/local/bin/brl-powerpc64le-linux-musl-ld' \
		bedrock-linux-$(BEDROCK_VERSION)-ppc64le.sh
release-s390x: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-s390x make -j$(SUBJOBS) GPGID='$(GPGID)' \
		AR='/bedrock/strata/brl-build-cross-debian/usr/local/bin/brl-s390x-linux-gnu-ar' \
		CC='/bedrock/strata/brl-build-cross-debian/usr/local/bin/brl-s390x-linux-gnu-gcc' \
		LD='/bedrock/strata/brl-build-cross-debian/usr/local/bin/brl-s390x-linux-gnu-ld' \
		bedrock-linux-$(BEDROCK_VERSION)-s390x.sh
release-x86_64: fetch_vendor_sources build/all/busybox/bedrock-config
	strat -r brl-build-x86_64 make -j$(SUBJOBS) GPGID='$(GPGID)' \
		bedrock-linux-$(BEDROCK_VERSION)-x86_64.sh
release: \
	release-aarch64 \
	release-armv7hl \
	release-armv7l \
	release-i386 \
	release-i486 \
	release-i586 \
	release-i686 \
	release-mips64el \
	release-mipsel \
	release-ppc \
	release-ppc64 \
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
	[ -e ./bedrock-linux-$(BEDROCK_VERSION)-mips64el.sh ]
	[ -e ./bedrock-linux-$(BEDROCK_VERSION)-mipsel.sh ]
	[ -e ./bedrock-linux-$(BEDROCK_VERSION)-ppc.sh ]
	[ -e ./bedrock-linux-$(BEDROCK_VERSION)-ppc64.sh ]
	[ -e ./bedrock-linux-$(BEDROCK_VERSION)-ppc64le.sh ]
	[ -e ./bedrock-linux-$(BEDROCK_VERSION)-s390x.sh ]
	[ -e ./bedrock-linux-$(BEDROCK_VERSION)-x86_64.sh ]
	@ printf "\e[32m\n%s\n%s\n%s\n\e[39m\n" \
		"$$(echo "=== Completed Bedrock Linux $(BEDROCK_VERSION) release build ===" | sed 's/./=/g')" \
		"$$(echo "=== Completed Bedrock Linux $(BEDROCK_VERSION) release build ===")" \
		"$$(echo "=== Completed Bedrock Linux $(BEDROCK_VERSION) release build ===" | sed 's/./=/g')"
