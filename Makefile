# Bedrock Linux Makefile
#
#      This program is free software; you can redistribute it and/or
#      modify it under the terms of the GNU General Public License
#      version 2 as published by the Free Software Foundation.
#
# Copyright (c) 2012-2018 Daniel Thau <danthau@bedrocklinux.org>
#
# This creates a script which can be used to install or update a Bedrock Linux
# system.
#
# First install the necessary build dependencies:
#
# - Standard UNIX utilities: grep, sed, awk, etc.
# - gcc 4.9.1 or newer
# - git 1.8 or newer
# - meson 0.38 or newer
# - ninja-build
# - libtool
# - autoconf
# - pkg-config
# - fakeroot
# - make
# - gzip
# - gpg (optional)
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
# - src/slash-bedrock/ contains files and directories which will populate the
#   eventual install's /bedrock/ directory as-is.  Anything from here is copied
#   over preexisting files in an update, and thus this should not contain
#   configuration the user may change.
# - src/default-configs/ contains default configuration files.  These are files
#   which may be used in a fresh install but should not be applied over existing
#   files in an update.
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
# - build/ (initially absent) will contain intermediate build output which can be
#   safely removed.
# - build/support/ will contain build-time support code and will not directly end
#   up in the resulting install.
# - build/bedrock/ will contain files which eventually end up in the installed
#   system's /bedrock/ directory.  This will be populated by src/slash-bedrock/
#   contents and the various src/ binaries.
# - build/completed/ will contain files which indicate various build steps have
#   been completed.  These are for build steps that may produce many output
#   files as an alternative to verbosely tracking each individual output file.
# - Makefile service as the build system.
# - `*.md` files service as documentation.
#
# Many dependencies have deep paths which may be awkward to type at a command
# line.  For these, shorter aliases are created.
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

VERSION=0.7.4
CODENAME=Poki
ARCH=$(shell uname -m)
RELEASE=Bedrock Linux $(VERSION) $(CODENAME)
INSTALLER=bedrock-linux-$(VERSION)-$(ARCH).sh

SRC=$(shell pwd)/src/
SUPPORT=$(shell pwd)/build/support
SLASHBR=$(shell pwd)/build/bedrock
COMPLETED=$(shell pwd)/build/completed
MUSLCC=$(SUPPORT)/bin/musl-gcc

INDENT_FLAGS=--linux-style --dont-line-up-parentheses \
	--continuation-indentation8 --indent-label0 --case-indentation0
WERROR_FLAGS=-Werror -Wall -Wextra -std=c99 -pedantic

all: $(INSTALLER)

remove_vendor_source:
	rm -rf ./vendor

clean:
	rm -rf ./build/
	rm -f $(INSTALLER)
	if [ -e vendor/ ]; then \
		for dir in vendor/*/Makefile; do \
			$(MAKE) -C "$${dir%Makefile}" clean; \
		done \
	fi
	for dir in src/*/Makefile; do \
		$(MAKE) -C "$${dir%Makefile}" clean; \
	done

#
# The build/ directory structure.  This is a dependency of just about
# everything.
#

$(COMPLETED)/builddir:
	mkdir -p $(SUPPORT)/include $(SUPPORT)/lib
	cp -r src/slash-bedrock/ $(SLASHBR)
	# create bedrock-release
	echo "$(RELEASE)" > $(SLASHBR)/etc/bedrock-release
	# create os-release
	sed -e "s,^VERSION=.*,VERISON=\"$(VERSION) ($(CODENAME))\"," \
		-e "s,^VERSION_ID=.*,VERSION_ID=\"$(VERSION)\"," \
		-e "s,^PRETTY_NAME=.*,PRETTY_NAME=\"$(RELEASE)\"," \
		$(SLASHBR)/etc/os-release > $(SLASHBR)/etc/os-release-new
	mv $(SLASHBR)/etc/os-release-new $(SLASHBR)/etc/os-release
	# create release-specific bedrock.conf
	mv $(SLASHBR)/etc/bedrock.conf $(SLASHBR)/etc/bedrock.conf-$(VERSION)
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
	mkdir -p build/sbin/
	cp src/init/init build/sbin/init
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
	cd vendor/linux_headers/ && \
		$(MAKE) headers_install INSTALL_HDR_PATH=$(SUPPORT)
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
	cd vendor/musl/ && \
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
	mkdir -p $(SUPPORT)/include/sys
	if ! [ -e $(SUPPORT)/include/sys/capability.h ]; then \
		cp $(SUPPORT)/include/linux/capability.h $(SUPPORT)/include/sys/capability.h; \
	fi
	sed 's/^BUILD_GPERF.*/BUILD_GPERF=no/' vendor/libcap/Make.Rules > vendor/libcap/Make.Rules-new
	mv vendor/libcap/Make.Rules-new vendor/libcap/Make.Rules
	cd vendor/libcap/libcap && \
		$(MAKE) BUILD_CC=$(MUSLCC) CC=$(MUSLCC) lib=$(SUPPORT)/lib prefix=$(SUPPORT) BUILD_CFLAGS="$(CFLAGS) -static" && \
		$(MAKE) install RAISE_SETFCAP=no DESTDIR=$(SUPPORT) prefix=/ lib=lib
	cd vendor/libcap/progs && \
		$(MAKE) BUILD_CC=$(MUSLCC) CC=$(MUSLCC) lib=$(SUPPORT)/lib prefix=$(SUPPORT) LDFLAGS=-static && \
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
	rm -rf vendor/libfuse/build
	mkdir -p vendor/libfuse/build
	# meson/ninja sometimes fails with
	#     ninja: error: unknown target 'lib/libfuse3.a'
	# for no apparent reason.  It seems to eventually take after multiple
	# tries.  Thus, retry a few times.
	cd vendor/libfuse/build && \
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
	cp -r vendor/libfuse/build/lib/* $(SUPPORT)/lib/
	mkdir -p $(SUPPORT)/include/fuse3/
	cp vendor/libfuse/include/*.h $(SUPPORT)/include/fuse3/
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
	cp -r vendor/uthash/src/*.h $(SUPPORT)/include/
	touch $(COMPLETED)/uthash
uthash: $(COMPLETED)/uthash

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
$(SLASHBR)/libexec/busybox: vendor/busybox/.success_retrieving_source $(COMPLETED)/builddir $(COMPLETED)/musl
	# create busybox config helper
	cd vendor/busybox && \
		echo '#!/bin/sh' > set_bb_option && \
		echo 'if grep -q "^$$1=" .config; then' >> set_bb_option && \
		echo 'sed "s,^$$1=.*,$$1=$$2," .config > .config-new' >> set_bb_option && \
		echo 'mv .config-new .config' >> set_bb_option && \
		echo 'elif grep -q "^# $$1 is not set" .config; then' >> set_bb_option && \
		echo 'sed "s/^# $$1 is not set/$$1=$$2/" .config > .config-new' >> set_bb_option && \
		echo 'sed "s,^# $$1 is not set,$$1=$$2," .config > .config-new' >> set_bb_option && \
		echo 'mv .config-new .config' >> set_bb_option && \
		echo 'else' >> set_bb_option && \
		echo 'echo "$$1=$$2" >> .config' >> set_bb_option && \
		echo 'fi' >> set_bb_option && \
		chmod u+x set_bb_option
	# start with default config
	rm -f vendor/busybox/.config
	cd vendor/busybox && \
		$(MAKE) defconfig
	# disable unused applets
	cd vendor/busybox && \
		for applet in $$(grep "^CONFIG_.*=y$$" .config | grep -v "FEATURE" | sed -e 's/^CONFIG_//' -e 's/=.*$$//' | tr '[A-Z_]' '[a-z-]' ); do \
			if ! grep -rq "\<$$applet\>" $(SRC)/slash-bedrock/; then \
echo "DISABLING $$applet"; \
				./set_bb_option "CONFIG_$$(echo "$$applet" | tr '[a-z-]' '[A-Z_]')" "n"; \
			fi; \
		done
	# explicitly enable known desired and explicitly undesired features
	cd vendor/busybox && \
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
	# fix various busybox-linux-musl issues
	cd $(SUPPORT)/include/netinet/ && \
		awk '{p=1}/^struct ethhdr/,/^}/{print "//"$$0; p=0}p==1' if_ether.h > if_ether.h.new && \
		mv if_ether.h.new if_ether.h
	cd $(SUPPORT)/include/linux/ && \
		echo '' > in.h
	cd $(SUPPORT)/include/linux/ && \
		echo '' > in6.h
	cp $(SUPPORT)/include/linux/if_slip.h $(SUPPORT)/include/net/
	cd vendor/busybox && \
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
	# Sometimes autogen does not take the first time despite returning 0.  Thus, try a few times.
	cd vendor/libattr && \
		./autogen.sh && \
		CC=$(MUSLCC) ./configure --enable-static --disable-shared ; \
		make clean && \
		make CC=$(MUSLCC) getfattr setfattr && \
		cp getfattr $(SLASHBR)/libexec/getfattr && \
		cp setfattr $(SLASHBR)/libexec/setfattr && \
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
	# netselect uses non-standard types which musl does not recognize.
	if ! grep -q '^#include "fix_types.h"' vendor/netselect/netselect.c; then \
		echo '#define u_char unsigned char' > vendor/netselect/fix_types.h && \
		echo '#define u_short unsigned short' >> vendor/netselect/fix_types.h && \
		echo '#define u_long unsigned long' >> vendor/netselect/fix_types.h && \
		echo '#include "fix_types.h"' > vendor/netselect/netselect_fixed.c && \
		cat vendor/netselect/netselect.c >> vendor/netselect/netselect_fixed.c && \
		mv vendor/netselect/netselect_fixed.c vendor/netselect/netselect.c; fi
	# patch netselect to avoid dropping domain in output
	# users may prefer the domain to a raw IP, and some services (e.g.
	# cloudflare) refuse to operate when contacted with raw IP.
	if grep -q '^\s*if\s*(result.multi)$$' vendor/netselect/netselect.c; then \
		sed 's/^\s*if\s*(result.multi)$$/if(0)/' \
			vendor/netselect/netselect.c > vendor/netselect/netselect_fixed.c && \
		mv vendor/netselect/netselect_fixed.c vendor/netselect/netselect.c; fi
	cd vendor/netselect/ && \
		make CC=$(MUSLCC) LDFLAGS='-static' && \
		cp netselect $(SLASHBR)/libexec/netselect
netselect: $(SLASHBR)/libexec/netselect

$(SLASHBR)/bin/strat: $(COMPLETED)/builddir $(COMPLETED)/musl $(COMPLETED)/libcap
	cd src/strat && \
		$(MAKE) CC=$(MUSLCC) && \
		cp ./strat $(SLASHBR)/bin/strat
strat: $(SLASHBR)/bin/strat

$(SLASHBR)/libexec/manage_tty_lock: $(COMPLETED)/builddir $(COMPLETED)/musl
	cd src/manage_tty_lock && \
		$(MAKE) CC=$(MUSLCC) && \
		cp manage_tty_lock $(SLASHBR)/libexec/manage_tty_lock
manage_tty_lock: $(SLASHBR)/libexec/manage_tty_lock

$(SLASHBR)/libexec/bouncer: $(COMPLETED)/builddir $(COMPLETED)/musl
	cd src/bouncer && \
		$(MAKE) CC=$(MUSLCC) && \
		cp ./bouncer $(SLASHBR)/libexec/bouncer
bouncer: $(SLASHBR)/libexec/bouncer

$(SLASHBR)/libexec/etcfs: $(COMPLETED)/builddir \
	$(COMPLETED)/musl \
	$(COMPLETED)/libfuse
	cd src/etcfs && \
		make CC=$(MUSLCC) CFLAGS="$(CFLAGS)" && \
		cp ./etcfs $(SLASHBR)/libexec/etcfs
etcfs: $(SLASHBR)/libexec/etcfs

$(SLASHBR)/libexec/crossfs: $(COMPLETED)/builddir \
	$(COMPLETED)/musl \
	$(COMPLETED)/libfuse \
	$(COMPLETED)/uthash
	cd src/crossfs && \
		make CC=$(MUSLCC) CFLAGS="$(CFLAGS)" && \
		cp ./crossfs $(SLASHBR)/libexec/crossfs
crossfs: $(SLASHBR)/libexec/crossfs
#
# Use populated $(SLASHBR) to create the script
#

build/userland.tar: \
	$(COMPLETED)/builddir \
	$(SLASHBR)/libexec/busybox \
	$(SLASHBR)/libexec/getfattr \
	$(SLASHBR)/libexec/setfattr \
	$(SLASHBR)/libexec/setcap \
	$(SLASHBR)/libexec/netselect \
	$(SLASHBR)/bin/strat \
	$(SLASHBR)/libexec/manage_tty_lock \
	$(SLASHBR)/libexec/bouncer \
	$(SLASHBR)/libexec/etcfs \
	$(SLASHBR)/libexec/crossfs
	# ensure static
	for bin in $(SLASHBR)/bin/* $(SLASHBR)/libexec/*; do \
		if ldd "$$bin" >/dev/null 2>&1; then \
			echo "error: $$bin is dynamically linked"; exit 1; \
		fi; \
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
	chmod 755 build/sbin/init
	# create symlinks
	ln -s ../bin/strat $(SLASHBR)/libexec/brl-strat
	ln -s /bedrock/run/init-alias $(SLASHBR)/strata/init
	ln -s ../cross/.local-alias $(SLASHBR)/strata/local
	# create a tarball
	cd build/ && fakeroot tar cf userland.tar-new bedrock/ sbin/init
	cd build/ && mv userland.tar-new userland.tar
tarball: build/userland.tar

build/unsigned-installer.sh: build/userland.tar src/installer/installer.sh src/slash-bedrock/share/common-code
	( \
		cat src/installer/installer.sh | awk '/^[.] \/bedrock\/share\/common-code/{exit}1'; \
		cat src/slash-bedrock/share/common-code | sed 's/BEDROCK-RELEASE/$(RELEASE)/' | grep -v 'pipefail'; \
		cat src/installer/installer.sh | awk 'x{print}/^[.] \/bedrock\/share\/common-code/{x=1}'; \
		echo "-----BEGIN TARBALL-----"; \
		cat build/userland.tar | gzip; \
		echo ""; \
		echo "-----END TARBALL-----"; \
	) > build/unsigned-installer.sh-new
	mv build/unsigned-installer.sh-new build/unsigned-installer.sh

$(INSTALLER): build/unsigned-installer.sh
	if [ "$(SKIPSIGN)" = true ]; then \
		cp build/unsigned-installer.sh $(INSTALLER)-new; \
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
		rm -f build/signed-installer.sh; \
		cp build/unsigned-installer.sh build/signed-installer.sh; \
		gpg --output - --armor --detach-sign build/unsigned-installer.sh >> build/signed-installer.sh; \
		mv build/signed-installer.sh $(INSTALLER); \
	fi
	chmod +x $(INSTALLER)
	@ echo "=== Completed creating $(INSTALLER) ===" | sed 's/./=/g'
	@ echo "=== Completed creating $(INSTALLER) ==="
	@ echo "=== Completed creating $(INSTALLER) ===" | sed 's/./=/g'

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
	@ echo "======================================"
	@ echo "=== Completed formatting code base ==="
	@ echo "======================================"

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
