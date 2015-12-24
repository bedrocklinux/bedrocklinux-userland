BUILD=$(CURDIR)/build
MUSLGCC=$(CURDIR)/build/bin/musl-gcc

.PHONY: all

all: tarball

#############################
# Manage third party source #
#############################

.PHONY: clean_source_all clean_source_busybox clean_source_linux_headers clean_source_musl clean_source_fuse clean_source_libcap clean_source_libattr
.PHONY: source_all source_busybox source_linux_headers source_musl source_fuse source_libcap source_libattr

source_all: source_busybox source_linux_headers source_musl source_fuse source_libcap source_libattr

clean_source_all: clean_source_busybox clean_source_linux_headers clean_source_musl clean_source_fuse clean_source_libcap clean_source_libattr


source_busybox: src/busybox/.success_retreiving_source

clean_source_busybox:
	- rm -rf src/busybox

src/busybox/.success_retreiving_source:
	mkdir -p src/busybox
	# get latest stable version
	git clone --depth=1 \
		-b `git ls-remote --heads 'git://git.busybox.net/busybox' | \
		awk -F/ '$$NF ~ /stable$$/ {print $$NF}' | \
		sort -t _ -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | \
		tail -n1` 'git://git.busybox.net/busybox' \
		src/busybox && \
		touch src/busybox/.success_retreiving_source


source_linux_headers: src/linux_headers/.success_retreiving_source

clean_source_linux_headers:
	- rm -rf src/linux_headers

src/linux_headers/.success_retreiving_source:
	mkdir -p src/linux_headers
	# get latest stable version
	git clone --depth=1 'git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git' \
		src/linux_headers
	touch src/linux_headers/.success_retreiving_source


source_musl: src/musl/.success_retreiving_source

clean_source_musl:
	- rm -rf src/musl

src/musl/.success_retreiving_source:
	mkdir -p src/musl
	# at time of writing, 1.0.X branch is stable branch
	git clone --depth=1 \
		-b `git ls-remote --tags 'git://git.musl-libc.org/musl' | \
		awk -F/ '{print $$NF}' | \
		sed 's/^v//g' | \
		grep '^1\.0\..' | \
		sort -t . -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | \
		tail -n1 | \
		sed 's/^/v/'` 'git://git.musl-libc.org/musl' \
		src/musl
	touch src/musl/.success_retreiving_source


source_fuse: src/fuse/.success_retreiving_source

clean_source_fuse:
	- rm -rf src/fuse

src/fuse/.success_retreiving_source:
	mkdir -p src/fuse
	# at time of writing, 2.9.X is stable branch
	git clone --depth=1 \
		-b fuse_2_9_bugfix \
		'git://github.com/libfuse/libfuse.git' \
		src/fuse
	touch src/fuse/.success_retreiving_source


source_libcap: src/libcap/.success_retreiving_source

clean_source_libcap:
	- rm -rf src/libcap

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


source_libattr: src/libattr/.success_retreiving_source

clean_source_libattr:
	- rm -rf src/libattr

src/libattr/.success_retreiving_source:
	mkdir -p src/libattr
	# this will touch up a problematic "xattr.h" file
	git clone --depth=1 \
		-b `git ls-remote --tags 'git://git.savannah.nongnu.org/attr.git' | \
		awk -F/ '{print $$NF}' | \
		sed 's/^v//g' | \
		grep '^[0-9]' | \
		grep '[.]' | \
		grep -v '{}' | \
		sort -t . -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | \
		tail -n1 | \
		sed 's/^/v/'` 'git://git.savannah.nongnu.org/attr.git' \
		src/libattr && \
		sed -e 's/__BEGIN_DECLS//g' -e 's/__END_DECLS//g' -e 's/__THROW//g' src/libattr/include/xattr.h > src/libattr/include/xattr.h-fixed && \
		mv src/libattr/include/xattr.h-fixed src/libattr/include/xattr.h
	touch src/libattr/.success_retreiving_source

###########
# Compile #
###########

.PHONY: clean clean_linux_headers clean_musl clean_fuse clean_libattr clean_libcap clean_libbedrock clean_brc clean_brp clean_bru clean_busybox clean_tarball
.PHONY: linux_headers musl fuse libattr libcap libbedrock brc brp bru busybox

clean: clean_linux_headers clean_musl clean_fuse clean_libattr clean_libcap clean_libbedrock clean_brc clean_brp clean_bru clean_busybox clean_tarball

linux_headers: source_linux_headers build/.success_build_linux_headers

build/.success_build_linux_headers:
	mkdir -p build/include
	cd src/linux_headers/ && \
		make headers_install INSTALL_HDR_PATH=$(BUILD)

clean_linux_headers:
	- rm -r $(BUILD)/include
	- cd src/linux_headers && \
		make mrproper


musl: source_musl linux_headers build/.success_build_musl

build/.success_build_musl:
	mkdir -p $(BUILD)
	cd src/musl/ && \
		./configure --prefix=$(BUILD) --enable-static --enable-gcc-wrapper && \
		make && \
		make install
	if ! [ -e $(BUILD)/lib64 ]; then \
		ln -fs lib $(BUILD)/lib64; fi
	if ! [ -e $(BUILD)/sbin ]; then \
		ln -fs bin $(BUILD)/sbin; fi
	touch $(BUILD)/.success_build_musl

clean_musl:
	- rm -r build
	- cd src/musl && \
		make clean


fuse: source_fuse musl build/lib/libfuse.a build/include/fuse.h

build/lib/libfuse.a build/include/fuse.h:
	mkdir -p $(BUILD)
	cd src/fuse/ && \
		./makeconf.sh && \
		./configure --prefix=$(BUILD) --disable-shared --enable-static --disable-util --disable-example && \
		make CC=$(MUSLGCC) && \
		make install

clean_fuse:
	- rm -r build
	- cd src/fuse && \
		make clean


libattr: source_libattr musl build/lib/libattr.so

build/lib/libattr.so:
	mkdir -p $(BUILD)
	cd src/libattr/ && \
		make configure && \
		./configure --prefix=$(BUILD) && \
		make CC=$(MUSLGCC) libattr && \
		make install-lib
	if ! [ -e $(BUILD)/lib/libattr.so ]; then \
		ln -fs libattr.so.1 $(BUILD)/lib/libattr.so; fi

clean_libattr:
	- cd src/libattr && \
		make clean


libcap: source_libcap musl libattr build/bin/setcap build/lib/libcap.a

build/bin/setcap build/lib/libcap.a:
	mkdir -p $(BUILD)
	if ! [ -e $(BUILD)/include/sys/capability.h ]; then \
		cp $(BUILD)/include/linux/capability.h $(BUILD)/include/sys/capability.h; fi
	cd src/libcap/libcap && \
		make BUILD_CC=$(MUSLGCC) CC=$(MUSLGCC) lib=$(BUILD)/lib prefix=$(BUILD) BUILD_CFLAGS=-static && \
		make install RAISE_SETFCAP=no DESTDIR=$(BUILD) prefix=/ lib=lib
	cd src/libcap/progs && \
		make BUILD_CC=$(MUSLGCC) CC=$(MUSLGCC) lib=$(BUILD)/lib prefix=$(BUILD) LDFLAGS=-static && \
		make install RAISE_SETFCAP=no DESTDIR=$(BUILD) prefix=/ lib=lib

clean_libcap:
	- cd src/libcap && \
		make clean


libbedrock: musl build/lib/libbedrock.a build/include/libbedrock.h

build/lib/libbedrock.a build/include/libbedrock.h:
	mkdir -p $(BUILD)
	cd src/libbedrock && \
		make CC=$(MUSLGCC) && \
		make install prefix=$(BUILD)

clean_libbedrock:
	- cd src/libbedrock && \
		make clean


brc: musl libcap libbedrock build/bin/brc

build/bin/brc:
	mkdir -p $(BUILD)
	cd src/brc && \
		make CC=$(MUSLGCC) && \
		make install prefix=$(BUILD)

clean_brc:
	- cd src/brc && \
		make clean


brp: musl fuse libbedrock build/bin/brp

build/bin/brp:
	mkdir -p $(BUILD)
	cd src/brp && \
		make CC="$(MUSLGCC) -D_FILE_OFFSET_BITS=64" && \
		make install prefix=$(BUILD)

clean_brp:
	- cd src/brp && \
		make clean


bru: musl fuse libbedrock build/bin/bru

build/bin/bru:
	mkdir -p $(BUILD)
	cd src/bru && \
		make CC="$(MUSLGCC) -D_FILE_OFFSET_BITS=64" && \
		make install prefix=$(BUILD)

clean_bru:
	- cd src/bru && \
		make clean


busybox: source_busybox musl build/bin/busybox

build/bin/busybox:
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

clean_busybox:
	- rm src/busybox/set_bb_option
	- cd src/busybox && make clean

###########
# tarball #
###########

.PHONY: tarball gzip_tarball

tarball: libcap brc brp bru busybox bedrock_linux_1.0beta2_nyla.tar
	@echo
	@echo "Successfully built Bedrock Linux tarball"
	@echo

bedrock_linux_1.0beta2_nyla.tar:
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
	# files
	cp -d build/bin/brc                              build/bedrock/bin/
	cp -d src/slash-bedrock/bin/bri                  build/bedrock/bin/
	cp -d src/slash-bedrock/bin/brl                  build/bedrock/bin/
	cp -d src/slash-bedrock/bin/brsh                 build/bedrock/bin/
	cp -d src/slash-bedrock/bin/brw                  build/bedrock/bin/
	cp -d build/bin/brp                              build/bedrock/sbin/
	cp -d build/bin/bru                              build/bedrock/sbin/
	cp -d src/slash-bedrock/sbin/brs                 build/bedrock/sbin/
	cp -d src/slash-bedrock/sbin/brn                 build/bedrock/sbin/
	cp -d build/bin/busybox                          build/bedrock/libexec/
	cp -d build/bin/setcap                           build/bedrock/libexec/
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
	cp -d src/global-files/etc/lsb-release           build/bedrock/global-files/etc/
	cp -d src/global-files/etc/motd                  build/bedrock/global-files/etc/
	cp -d src/global-files/etc/os-release            build/bedrock/global-files/etc/
	cp -d src/global-files/etc/profile               build/bedrock/global-files/etc/
	cp -d src/global-files/etc/rc.local              build/bedrock/global-files/etc/
	cp -d src/global-files/etc/shells                build/bedrock/global-files/etc/
	# set file permissions
	chmod 0755 build/bedrock/bin/brc
	chmod 0755 build/bedrock/bin/bri
	chmod 0755 build/bedrock/bin/brl
	chmod 0755 build/bedrock/bin/brsh
	chmod 0755 build/bedrock/bin/brw
	chmod 0755 build/bedrock/sbin/brp
	chmod 0755 build/bedrock/sbin/bru
	chmod 0755 build/bedrock/sbin/brs
	chmod 0755 build/bedrock/sbin/brn
	chmod 0755 build/bedrock/libexec/busybox
	chmod 0755 build/bedrock/libexec/setcap
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
	chmod 0755 build/bedrock/strata/fallback/bin/busybox
	chmod 0644 build/bedrock/global-files/etc/hostname
	chmod 0644 build/bedrock/global-files/etc/hosts
	chmod 0644 build/bedrock/global-files/etc/issue
	chmod 0644 build/bedrock/global-files/etc/lsb-release
	chmod 0644 build/bedrock/global-files/etc/motd
	chmod 0644 build/bedrock/global-files/etc/os-release
	chmod 0644 build/bedrock/global-files/etc/profile
	chmod 0644 build/bedrock/global-files/etc/rc.local
	chmod 0644 build/bedrock/global-files/etc/shells
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

clean_tarball:
	- rm bedrock_linux_1.0beta2_nyla.tar
