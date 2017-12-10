BUILD=$(shell pwd)/build
MUSLGCC=$(shell pwd)/build/bin/musl-gcc

all: tarball

clean:
	rm -rf ./build
	rm -f ./bedrock_linux_1.0beta2_nyla.tar
	for dir in src/*/Makefile; do make -C "$${dir%Makefile}" clean; done

clean_source_all:
	rm -rf src/busybox
	rm -rf src/fuse
	rm -rf src/libattr
	rm -rf src/libcap
	rm -rf src/linux_headers
	rm -rf src/musl

#
# Most of the items below will groups of two or three recipes:
# - If needed, a recipe to grab upstream source.
# - A recipe to build the component
# - A recipe with a convenient name which is only dependent on the recipe to
#   build the component.
#
# Recipes which grab source should touch a file called
# ".success_retreiving_source" in the source directory, and anything dependent
# on the source should check for this file.  This is cleaner than trying to
# track each individual file in the given project's source.  This is placed in
# the project's source so that, if the source is removed, the file goes with
# it.
#
# Recipes which build multiple files should touch a file called
# ".success_build_*", replacing * as appropriate, in the local build directory.
# This is again easier than tracking each of their outputs separately.
#

src/linux_headers/.success_retreiving_source:
	mkdir -p src/linux_headers
	# get latest stable version
	git clone --depth=1 'git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git' \
		src/linux_headers
	touch src/linux_headers/.success_retreiving_source
build/.success_build_linux_headers: src/linux_headers/.success_retreiving_source
	mkdir -p build/include
	cd src/linux_headers/ && \
		make headers_install INSTALL_HDR_PATH=$(BUILD)
	touch $(BUILD)/.success_build_linux_headers
linux_headers: build/.success_build_linux_headers

src/musl/.success_retreiving_source:
	mkdir -p src/musl
	# at time of writing, 1.1.X branch is stable branch
	git clone --depth=1 \
		-b `git ls-remote --tags 'git://git.musl-libc.org/musl' | \
		awk -F/ '{print $$NF}' | \
		sed 's/^v//g' | \
		grep '^1\.1\..' | \
		sort -t . -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | \
		tail -n1 | \
		sed 's/^/v/'` 'git://git.musl-libc.org/musl' \
		src/musl
	touch src/musl/.success_retreiving_source
build/.success_build_musl: src/musl/.success_retreiving_source build/.success_build_linux_headers
	mkdir -p build
	cd src/musl/ && \
		./configure --prefix=$(BUILD) --enable-static --enable-gcc-wrapper && \
		make && \
		make install
	if ! [ -e $(BUILD)/lib64 ]; then \
		ln -fs lib $(BUILD)/lib64; fi
	if ! [ -e $(BUILD)/sbin ]; then \
		ln -fs bin $(BUILD)/sbin; fi
	touch $(BUILD)/.success_build_musl
musl: build/.success_build_musl

src/fuse/.success_retreiving_source:
	mkdir -p src/fuse
	# at time of writing, 2.9.X is stable branch
	git clone --depth=1 \
		-b fuse_2_9_bugfix \
		'git://github.com/libfuse/libfuse.git' \
		src/fuse
	touch src/fuse/.success_retreiving_source
build/.success_build_fuse: src/fuse/.success_retreiving_source build/.success_build_musl
	cd src/fuse/ && \
		./makeconf.sh && \
		./configure --prefix=$(BUILD) --disable-shared --enable-static --disable-util --disable-example && \
		make CC=$(MUSLGCC) && \
		make install
	touch $(BUILD)/.success_build_fuse
fuse: build/.success_build_fuse

src/libattr/.success_retreiving_source:
	mkdir -p src/libattr
	#
	# Hard coding v2.4.47 here because v2.4.48 triggers this issue with gcc:
	#
	#     https://gcc.gnu.org/bugzilla/show_bug.cgi?id=81523
	#
	# when building statically across gcc 5.x, 6.x, and 7.x
	#
	# Debian does not appear to have backported any security updates to
	# v2.4.47, so as far as I can tell the v2.4.48 bump was not for
	# security purposes.
	#
	git clone --depth=1 -b v2.4.47 'git://git.savannah.nongnu.org/attr.git' src/libattr
	sed -e 's/__BEGIN_DECLS//g' -e 's/__END_DECLS//g' -e 's/__THROW//g' src/libattr/include/xattr.h > src/libattr/include/xattr.h-fixed
	mv src/libattr/include/xattr.h-fixed src/libattr/include/xattr.h
	touch src/libattr/.success_retreiving_source
build/.success_build_libattr: src/libattr/.success_retreiving_source build/.success_build_musl
	cd src/libattr/ && \
		make configure && \
		./configure --prefix=$(BUILD) && \
		make CC=$(MUSLGCC) libattr && \
		make install-lib
	if ! [ -e $(BUILD)/lib/libattr.so ]; then \
		ln -fs libattr.so.1 $(BUILD)/lib/libattr.so; fi
	touch $(BUILD)/.success_build_libattr
libattr: build/.success_build_libattr

src/libcap/.success_retreiving_source:
	mkdir -p src/libcap
	git clone --depth=1 \
		-b `git ls-remote --tags 'git://git.kernel.org/pub/scm/linux/kernel/git/morgan/libcap.git' | \
		awk -F/ '{print $$NF}' | \
		sed 's/^libcap-//g' | \
		grep '^[0-9]' | \
		grep '[.]' | \
		grep -v '{}' | \
		sort -t . -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | \
		tail -n1 | \
		sed 's/^/libcap-/'` 'git://git.kernel.org/pub/scm/linux/kernel/git/morgan/libcap.git' \
		src/libcap
	touch src/libcap/.success_retreiving_source
build/.success_build_libcap: src/libcap/.success_retreiving_source build/.success_build_libattr
	if ! [ -e $(BUILD)/include/sys/capability.h ]; then \
		cp $(BUILD)/include/linux/capability.h $(BUILD)/include/sys/capability.h; fi
	sed 's/^BUILD_GPERF.*/BUILD_GPERF=no/' src/libcap/Make.Rules > src/libcap/Make.Rules-new && mv src/libcap/Make.Rules-new src/libcap/Make.Rules
	cd src/libcap/libcap && \
		make BUILD_CC=$(MUSLGCC) CC=$(MUSLGCC) lib=$(BUILD)/lib prefix=$(BUILD) BUILD_CFLAGS=-static && \
		make install RAISE_SETFCAP=no DESTDIR=$(BUILD) prefix=/ lib=lib
	cd src/libcap/progs && \
		make BUILD_CC=$(MUSLGCC) CC=$(MUSLGCC) lib=$(BUILD)/lib prefix=$(BUILD) LDFLAGS=-static && \
		make install RAISE_SETFCAP=no DESTDIR=$(BUILD) prefix=/ lib=lib
	touch $(BUILD)/.success_build_libcap
libcap: build/.success_build_libcap

build/.success_build_libbedrock: build/.success_build_musl
	cd src/libbedrock && \
		make CC=$(MUSLGCC) && \
		make install prefix=$(BUILD)
	touch $(BUILD)/.success_build_libbedrock
libbedrock: build/.success_build_libbedrock

build/sbin/manage_tty_lock: build/.success_build_musl
	cd src/manage_tty_lock && \
		make CC=$(MUSLGCC) && \
		make install prefix=$(BUILD)
manage_tty_lock: build/sbin/manage_tty_lock

build/bin/brc: build/.success_build_musl build/.success_build_libcap build/.success_build_libbedrock
	mkdir -p $(BUILD)
	cd src/brc && \
		make CC=$(MUSLGCC) && \
		make install prefix=$(BUILD)
brc: build/bin/brc


build/bin/brp: build/.success_build_musl build/.success_build_libbedrock build/.success_build_fuse
	mkdir -p $(BUILD)
	cd src/brp && \
		make CC="$(MUSLGCC) -D_FILE_OFFSET_BITS=64" && \
		make install prefix=$(BUILD)
brp: libbedrock build/bin/brp


build/bin/bru: build/.success_build_musl build/.success_build_libbedrock build/.success_build_fuse
	mkdir -p $(BUILD)
	cd src/bru && \
		make CC="$(MUSLGCC) -D_FILE_OFFSET_BITS=64" && \
		make install prefix=$(BUILD)
bru: build/bin/bru

src/busybox/.success_retreiving_source:
	mkdir -p src/busybox
	# get latest stable version
	git clone --depth=1 \
		-b `git ls-remote --heads 'git://git.busybox.net/busybox' | \
		awk -F/ '$$NF ~ /stable$$/ {print $$NF}' | \
		sort -t _ -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | \
		tail -n1` 'git://git.busybox.net/busybox' \
		src/busybox
	touch src/busybox/.success_retreiving_source
build/bin/busybox: src/busybox/.success_retreiving_source build/.success_build_musl
	mkdir -p $(BUILD)
	cd src/busybox && \
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
		chmod u+x set_bb_option && \
		make defconfig && \
		./set_bb_option "CONFIG_STATIC" "y" && \
		./set_bb_option "CONFIG_MODPROBE_SMALL" "n" && \
		./set_bb_option "CONFIG_FEATURE_MODPROBE_SMALL_OPTIONS_ON_CMDLINE" "n" && \
		./set_bb_option "CONFIG_FEATURE_MODPROBE_SMALL_CHECK_ALREADY_LOADED" "n" && \
		./set_bb_option "CONFIG_INSMOD" "y" && \
		./set_bb_option "CONFIG_RMMOD" "y" && \
		./set_bb_option "CONFIG_LSMOD" "y" && \
		./set_bb_option "CONFIG_FEATURE_LSMOD_PRETTY_2_6_OUTPUT" "y" && \
		./set_bb_option "CONFIG_MODPROBE" "y" && \
		./set_bb_option "CONFIG_FEATURE_MODPROBE_BLACKLIST" "y" && \
		./set_bb_option "CONFIG_DEPMOD" "y" && \
		./set_bb_option "CONFIG_FEATURE_CHECK_TAINTED_MODULE" "y" && \
		./set_bb_option "CONFIG_FEATURE_MODUTILS_ALIAS" "y" && \
		./set_bb_option "CONFIG_FEATURE_MODUTILS_SYMBOLS" "y" && \
		./set_bb_option "CONFIG_UDHCPC6" "y" && \
		./set_bb_option "CONFIG_INETD" "n" && \
		./set_bb_option "CONFIG_BRCTL" "n" && \
		./set_bb_option "CONFIG_FEATURE_WTMP" "n" && \
		./set_bb_option "CONFIG_FEATURE_UTMP" "n" && \
		./set_bb_option "CONFIG_FEATURE_PREFER_APPLETS" "y" && \
		./set_bb_option "CONFIG_FEATURE_SH_STANDALONE" "y" && \
		./set_bb_option "CONFIG_BUSYBOX_EXEC_PATH" '"/bedrock/libexec/busybox"'
	# fix various busybox-linux-musl issues
	cd $(BUILD)/include/netinet/ && \
		awk '{p=1}/^struct ethhdr/,/^}/{print "//"$$0; p=0}p==1' if_ether.h > if_ether.h.new && \
		mv if_ether.h.new if_ether.h
	cd $(BUILD)/include/linux/ && \
		echo '' > in.h
	cd $(BUILD)/include/linux/ && \
		echo '' > in6.h
	cp $(BUILD)/include/linux/if_slip.h $(BUILD)/include/net/
	cd src/busybox && \
		make CC=$(MUSLGCC) && \
		cp busybox_unstripped $(BUILD)/bin/busybox
busybox: build/bin/busybox

bedrock_linux_1.0beta2_nyla.tar: build/.success_build_libcap build/sbin/manage_tty_lock build/bin/brc build/bin/brp build/bin/bru build/bin/busybox
	# ensure fresh start
	rm -rf build/bedrock
	# make directory structure
	mkdir -p build/bedrock
	mkdir -p build/bedrock/bin
	mkdir -p build/bedrock/brpath
	mkdir -p build/bedrock/etc
	mkdir -p build/bedrock/etc/aliases.d
	mkdir -p build/bedrock/etc/frameworks.d
	mkdir -p build/bedrock/etc/strata.d
	mkdir -p build/bedrock/libexec
	mkdir -p build/bedrock/run
	mkdir -p build/bedrock/sbin
	mkdir -p build/bedrock/share
	mkdir -p build/bedrock/share/brs
	mkdir -p build/bedrock/share/systemd
	mkdir -p build/bedrock/strata
	mkdir -p build/bedrock/strata/fallback
	mkdir -p build/bedrock/strata/fallback/bin
	mkdir -p build/bedrock/strata/fallback/dev
	mkdir -p build/bedrock/strata/fallback/etc
	mkdir -p build/bedrock/strata/fallback/etc/init.d/
	mkdir -p build/bedrock/strata/fallback/home
	mkdir -p build/bedrock/strata/fallback/lib
	mkdir -p build/bedrock/strata/fallback/lib/modules
	mkdir -p build/bedrock/strata/fallback/media
	mkdir -p build/bedrock/strata/fallback/mnt
	mkdir -p build/bedrock/strata/fallback/proc
	mkdir -p build/bedrock/strata/fallback/root
	mkdir -p build/bedrock/strata/fallback/run
	mkdir -p build/bedrock/strata/fallback/sbin
	mkdir -p build/bedrock/strata/fallback/sys
	mkdir -p build/bedrock/strata/fallback/tmp
	mkdir -p build/bedrock/strata/fallback/usr
	mkdir -p build/bedrock/strata/fallback/usr/bin
	mkdir -p build/bedrock/strata/fallback/usr/sbin
	mkdir -p build/bedrock/strata/fallback/var
	mkdir -p build/bedrock/strata/fallback/var/lib
	mkdir -p build/bedrock/strata/fallback/run
	mkdir -p build/bedrock/strata/fallback/systemd
	mkdir -p build/bedrock/strata/fallback/systemd/system
	mkdir -p build/bedrock/strata/fallback/systemd/system/multi-user.target.wants
	mkdir -p build/bedrock/global-files
	mkdir -p build/bedrock/global-files/etc/
	mkdir -p build/bedrock/global-files/etc/systemd
	mkdir -p build/bedrock/global-files/etc/systemd/system
	mkdir -p build/bedrock/global-files/etc/systemd/system/multi-user.target.wants
	mkdir -p build/bedrock/global-files/etc/X11
	mkdir -p build/bedrock/global-files/etc/X11/Xsession.d
	# set directory permissions
	chmod 0755 build/bedrock
	chmod 0755 build/bedrock/bin
	chmod 0755 build/bedrock/brpath
	chmod 0755 build/bedrock/etc
	chmod 0755 build/bedrock/etc/aliases.d
	chmod 0755 build/bedrock/etc/frameworks.d
	chmod 0755 build/bedrock/etc/strata.d
	chmod 0755 build/bedrock/libexec
	chmod 0755 build/bedrock/run
	chmod 0755 build/bedrock/sbin
	chmod 0755 build/bedrock/share
	chmod 0755 build/bedrock/share/brs
	chmod 0755 build/bedrock/share/systemd
	chmod 0755 build/bedrock/strata
	chmod 0755 build/bedrock/strata/fallback
	chmod 0755 build/bedrock/strata/fallback/bin
	chmod 0755 build/bedrock/strata/fallback/dev
	chmod 0755 build/bedrock/strata/fallback/etc
	chmod 0755 build/bedrock/strata/fallback/etc/init.d
	chmod 0755 build/bedrock/strata/fallback/home
	chmod 0755 build/bedrock/strata/fallback/lib
	chmod 0755 build/bedrock/strata/fallback/lib/modules
	chmod 0755 build/bedrock/strata/fallback/media
	chmod 0755 build/bedrock/strata/fallback/mnt
	chmod 0755 build/bedrock/strata/fallback/proc
	chmod 0755 build/bedrock/strata/fallback/root
	chmod 0755 build/bedrock/strata/fallback/run
	chmod 0755 build/bedrock/strata/fallback/sbin
	chmod 0755 build/bedrock/strata/fallback/sys
	chmod 1755 build/bedrock/strata/fallback/tmp
	chmod 0755 build/bedrock/strata/fallback/usr
	chmod 0755 build/bedrock/strata/fallback/usr/bin
	chmod 0755 build/bedrock/strata/fallback/usr/sbin
	chmod 0755 build/bedrock/strata/fallback/var
	chmod 0755 build/bedrock/strata/fallback/var/lib
	chmod 0755 build/bedrock/strata/fallback/run
	chmod 0755 build/bedrock/strata/fallback/systemd
	chmod 0755 build/bedrock/strata/fallback/systemd/system
	chmod 0755 build/bedrock/strata/fallback/systemd/system/multi-user.target.wants
	chmod 0755 build/bedrock/global-files
	chmod 0755 build/bedrock/global-files/etc
	chmod 0755 build/bedrock/global-files/etc/systemd
	chmod 0755 build/bedrock/global-files/etc/systemd/system
	chmod 0755 build/bedrock/global-files/etc/systemd/system/multi-user.target.wants
	chmod 0755 build/bedrock/global-files/etc/X11
	chmod 0755 build/bedrock/global-files/etc/X11/Xsession.d
	# files
	cp -d build/bin/brc                              build/bedrock/bin/
	cp -d src/slash-bedrock/bin/bri                  build/bedrock/bin/
	cp -d src/slash-bedrock/bin/brl                  build/bedrock/bin/
	cp -d src/slash-bedrock/bin/brr                  build/bedrock/bin/
	cp -d src/slash-bedrock/bin/brsh                 build/bedrock/bin/
	cp -d src/slash-bedrock/bin/brw                  build/bedrock/bin/
	cp -d build/bin/brp                              build/bedrock/sbin/
	cp -d build/bin/bru                              build/bedrock/sbin/
	cp -d src/slash-bedrock/sbin/brs                 build/bedrock/sbin/
	cp -d src/slash-bedrock/sbin/brn                 build/bedrock/sbin/
	cp -d build/bin/busybox                          build/bedrock/libexec/
	cp -d build/bin/setcap                           build/bedrock/libexec/
	cp -d build/sbin/manage_tty_lock                 build/bedrock/libexec/
	cp -d src/slash-bedrock/share/brs/force-symlinks build/bedrock/share/brs/
	cp -d src/slash-bedrock/share/brs/setup-etc      build/bedrock/share/brs/
	cp -d src/slash-bedrock/share/brs/run-lock       build/bedrock/share/brs/
	cp -d src/slash-bedrock/share/systemd/bedrock-killfuse.service     build/bedrock/share/systemd/
	cp -d src/slash-bedrock/share/systemd/bedrock-privatemount.service build/bedrock/share/systemd/
	cp -d src/slash-bedrock/etc/aliases.conf         build/bedrock/etc/
	cp -d src/slash-bedrock/etc/brn.conf             build/bedrock/etc/
	cp -d src/slash-bedrock/etc/brp.conf             build/bedrock/etc/
	cp -d src/slash-bedrock/etc/frameworks.d/default build/bedrock/etc/frameworks.d/
	cp -d src/slash-bedrock/etc/frameworks.d/global  build/bedrock/etc/frameworks.d/
	cp -d src/slash-bedrock/etc/rc.conf              build/bedrock/etc/
	cp -d src/slash-bedrock/etc/strata.conf          build/bedrock/etc/
	cp -d src/slash-bedrock/etc/fstab                build/bedrock/etc/
	cp -d src/slash-bedrock/strata/fallback/rcK      build/bedrock/strata/fallback/
	cp -d src/slash-bedrock/strata/fallback/rcK.strata            build/bedrock/strata/fallback/
	cp -d src/slash-bedrock/strata/fallback/etc/inittab           build/bedrock/strata/fallback/etc
	cp -d src/slash-bedrock/strata/fallback/etc/init.d/rcS        build/bedrock/strata/fallback/etc/init.d/
	cp -d src/slash-bedrock/strata/fallback/etc/init.d/rcS.strata build/bedrock/strata/fallback/etc/init.d/
	cp -d src/slash-bedrock/strata/fallback/etc/init.d/rcS.udev   build/bedrock/strata/fallback/etc/init.d/
	cp -d build/bin/busybox                          build/bedrock/strata/fallback/bin/
	cp -d src/global-files/etc/hostname              build/bedrock/global-files/etc/
	cp -d src/global-files/etc/hosts                 build/bedrock/global-files/etc/
	cp -d src/global-files/etc/issue                 build/bedrock/global-files/etc/
	cp -d src/global-files/etc/motd                  build/bedrock/global-files/etc/
	cp -d src/global-files/etc/profile               build/bedrock/global-files/etc/
	cp -d src/global-files/etc/rc.local              build/bedrock/global-files/etc/
	cp -d src/global-files/etc/shells                build/bedrock/global-files/etc/
	cp -d src/global-files/etc/X11/Xsession.d/41bedrock_env build/bedrock/global-files/etc/X11/Xsession.d
	# set file permissions
	chmod 0755 build/bedrock/bin/brc
	chmod 0755 build/bedrock/bin/bri
	chmod 0755 build/bedrock/bin/brl
	chmod 0755 build/bedrock/bin/brr
	chmod 0755 build/bedrock/bin/brsh
	chmod 0755 build/bedrock/bin/brw
	chmod 0755 build/bedrock/sbin/brp
	chmod 0755 build/bedrock/sbin/bru
	chmod 0755 build/bedrock/sbin/brs
	chmod 0755 build/bedrock/sbin/brn
	chmod 0755 build/bedrock/libexec/busybox
	chmod 0755 build/bedrock/libexec/setcap
	chmod 0755 build/bedrock/libexec/manage_tty_lock
	chmod 0755 build/bedrock/share/brs/force-symlinks
	chmod 0755 build/bedrock/share/brs/setup-etc
	chmod 0755 build/bedrock/share/brs/run-lock
	chmod 0644 build/bedrock/share/systemd/bedrock-killfuse.service
	chmod 0644 build/bedrock/share/systemd/bedrock-privatemount.service
	chmod 0644 build/bedrock/etc/aliases.conf
	chmod 0644 build/bedrock/etc/brn.conf
	chmod 0644 build/bedrock/etc/brp.conf
	chmod 0644 build/bedrock/etc/frameworks.d/default
	chmod 0644 build/bedrock/etc/frameworks.d/global
	chmod 0644 build/bedrock/etc/rc.conf
	chmod 0644 build/bedrock/etc/strata.conf
	chmod 0644 build/bedrock/etc/fstab
	chmod 0755 build/bedrock/strata/fallback/bin/busybox
	chmod 0644 build/bedrock/global-files/etc/hostname
	chmod 0644 build/bedrock/global-files/etc/hosts
	chmod 0644 build/bedrock/global-files/etc/issue
	chmod 0644 build/bedrock/global-files/etc/motd
	chmod 0644 build/bedrock/global-files/etc/profile
	chmod 0755 build/bedrock/global-files/etc/rc.local
	chmod 0644 build/bedrock/global-files/etc/shells
	chmod 0644 build/bedrock/global-files/etc/X11/Xsession.d/41bedrock_env
	# create symlinks
	ln -s /bedrock/run/init/alias       build/bedrock/etc/aliases.d/init
	ln -s /bedrock/run/init/framework   build/bedrock/etc/frameworks.d/init
	ln -s /bedrock/run/init/init_root   build/bedrock/etc/strata.d/init_root
	ln -s /bedrock/run/init/rootfs_root build/bedrock/etc/strata.d/rootfs_root
	ln -s /bedrock/run/init/root        build/bedrock/strata/init
	ln -s /                             build/bedrock/strata/local
	for util in `build/bedrock/strata/fallback/bin/busybox --list-utils`; do ln -s /bin/busybox build/bedrock/strata/fallback/$$util; done
	ln -s /rcK                          build/bedrock/strata/fallback/etc/init.d/rcK
	ln -s /rcK.strata                   build/bedrock/strata/fallback/etc/init.d/rcK.strata
	ln -s /bedrock/share/systemd/bedrock-killfuse.service build/bedrock/global-files/etc/systemd/system/multi-user.target.wants/
	ln -s /bedrock/share/systemd/bedrock-privatemount.service build/bedrock/global-files/etc/systemd/system/multi-user.target.wants/
	# build tarball
	cd build/ && fakeroot tar cvf ../bedrock_linux_1.0beta2_nyla.tar bedrock
tarball: bedrock_linux_1.0beta2_nyla.tar
	@echo
	@echo "Successfully built Bedrock Linux tarball"
	@echo
