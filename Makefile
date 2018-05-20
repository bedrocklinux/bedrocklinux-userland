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
# - ninja
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
#   which may be used in a fresh install but should not be applied over
#   existing files in an update.
# - src/installer/ contains the actual installer script.  The build system will
#   embed the eventual system files into the installation script.
# - Other src/ directories correspond to source for binary executables.  These
#   binaries will be included in the slash-bedrock structure embedded within
#   the installation script.
# - vendor/ (initially absent) will contain upstream build dependencies.  The
#   build system will automatically fetch these and populate vendor/
#   accordingly.  The build system will attempt to automatically get the latest
#   stable version and may occasionally fail if an upstream component changes
#   too drastically.  This is purposeful, as it will service as a canary
#   indicating developer attention is required and preferable to distributing
#   outdated upstream components which may contain security vulnerabilities.
# - vendor/*/.success_fetching_source files indicate that the given vendor
#   component's files have been successfully acquired.  This is used to
#   properly handle interrupted downloads.
# - build/ (initially absent) will contain intermediate build output which can
#   be safely removed.
# - build/support/ will contain build-time support code and will not directly
#   end up in the resulting install.
# - build/bedrock/ will contain files which eventually end up in the installed
#   system's /bedrock/ directory.  This will be populated by src/slash-bedrock/
#   contents and the various src/ binaries.
# - build/completed/ will contain files which indicate various build steps have
#   been completed.  These are for build steps that may produce many output
#   files as an alternative to verbosely tracking each individual output file.
# - Makefile services as the build system.
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
# - tcc
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

VERSION=0.7.0
CODENAME=Poki
ARCH=$(shell uname -m)
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

remove_vendor_source:
	rm -rf ./vendor

#
# The build/ directory structure.  This is a dependency of just about
# everything.
#

$(COMPLETED)/builddir:
	mkdir -p $(SUPPORT)
	mkdir -p $(SUPPORT)/include $(SUPPORT)/lib
	cp -r src/slash-bedrock/ $(SLASHBR)
	mkdir -p $(SLASHBR)/bin $(SLASHBR)/etc $(SLASHBR)/libexec
	mkdir -p $(COMPLETED)
	touch $(COMPLETED)/builddir
builddir: $(COMPLETED)/builddir

#
# Support libraries and tools.  Populates $(SUPPORT)
#

# TODO

#
# Compiled binaries which will go into the output script.  Populates $(SLASHBR)
#

# TODO

#
# Use populated $(SLASHBR) to create the script
#

build/slashbr.tar.gz: $(COMPLETED)/builddir
	# ensure permissions
	find $(SLASHBR) -exec chmod a-s {} \;
	find $(SLASHBR) -type f -exec chmod 0644 {} \;
	find $(SLASHBR) -type d -exec chmod 0755 {} \;
	find $(SLASHBR)/bin/ -type f -exec chmod 0755 {} \;
	find $(SLASHBR)/libexec/ -type f -exec chmod 0755 {} \;
	# ensure static
	for bin in $(SLASHBR)/bin/* $(SLASHBR)/libexec/*; do \
		if ldd "$$bin" >/dev/null 2>&1; then \
			echo "error: $$bin is dynamically linked"; exit 1; \
		fi; \
	done
	# strip binaries
	for bin in $(SLASHBR)/bin/* $(SLASHBR)/libexec/*; do \
		strip "$$bin"; \
	done
	# create a tarball
	rm -f build/slashbr.tar
	cd build/ && fakeroot tar cf slashbr.tar bedrock/
	gzip -c build/slashbr.tar > build/slashbr.tar.gz-new
	mv build/slashbr.tar.gz-new build/slashbr.tar.gz
gziped-tarball: build/slashbr.tar.gz

build/unsigned-installer.sh: build/slashbr.tar.gz src/installer/installer.sh
	cp src/installer/installer.sh build/unsigned-installer.sh-new
	echo "-----BEGIN bedrock.conf-----" >> build/unsigned-installer.sh-new
	cat src/default-configs/bedrock.conf >> build/unsigned-installer.sh-new
	echo "-----END bedrock.conf-----" >> build/unsigned-installer.sh-new
	echo "-----BEGIN EMBEDDED TARBALL-----" >> build/unsigned-installer.sh-new
	cat build/slashbr.tar.gz >> build/unsigned-installer.sh-new
	echo "" >> build/unsigned-installer.sh-new
	echo "-----END EMBEDDED TARBALL-----" >> build/unsigned-installer.sh-new
	mv build/unsigned-installer.sh-new build/unsigned-installer.sh

$(INSTALLER): build/unsigned-installer.sh
	if [ "$(SKIPSIGN)" = true ]; then \
		cp build/unsigned-installer.sh $(INSTALLER); \
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
	@ echo "=== Completed creating $(INSTALLER) ===" | sed 's/./=/g'
	@ echo "=== Completed creating $(INSTALLER) ==="
	@ echo "=== Completed creating $(INSTALLER) ===" | sed 's/./=/g'

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
		if grep -q '^#!.*sh$$' "$$file"; then \
			shfmt -p -w "$$file"; \
		fi \
	done
	# style C code
	for file in $$(find src/ -type f -name "*.[ch]"); do \
		indent $(INDENT_FLAGS) "$$file"; \
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
	# - tcc
	# - scan-build (usually distributed with clang)
	# - shfmt (https://github.com/mvdan/sh)
	# - indent (GNU)
	#
	# check against shellcheck
	for file in $$(find src/ -type f); do \
		if grep -q '^#!.*sh$$' "$$file"; then \
			echo "checking $$file"; \
			shellcheck -s sh --exclude=SC1008 "$$file" || exit 1; \
		fi \
	done
	# check against cppcheck
	for file in $$(find src/ -type f -name "*.[ch]"); do \
		cppcheck --error-exitcode=1 "$$file"; \
	done
	# check against various compiler warnings
	for compiler in clang gcc tcc; do \
		for dir in src/*/Makefile; do \
			$(MAKE) -C "$${dir%Makefile}" clean || exit 1; \
			$(MAKE) -C "$${dir%Makefile}" CC=$$compiler CFLAGS="$(WERROR_FLAGS)" || exit 1; \
		done \
	done
	# check shell scripts formatting
	for file in $$(find src/ -type f); do \
		if grep -q '^#!.*sh$$' "$$file"; then \
			echo "checking formatting of $$file"; \
			! cat "$$file" | shfmt -p -d | grep '.' || exit 1; \
		fi \
	done
	# check C code formatting
	for file in $$(find src/ -type f -name "*.[ch]"); do \
		echo "checking formatting of $$file"; \
		! cat "$$file" | indent $(INDENT_FLAGS) | diff -- "$$file" - | grep '.' || exit 1; \
	done
	@ echo "======================================="
	@ echo "=== All static analysis checks pass ==="
	@ echo "======================================="
