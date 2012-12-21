### Bedrock Linux 1.0alpha3 Bosco
### Makefile

# compile binaries
all:
	gcc -Wall src/brc/brc.c -o src/brc/brc -static -lcap

# install binaries
install:
	# install brc
	cp src/brc/brc bedrock/bin/brc
	chown root bedrock/bin/brc
	chmod a+rx bedrock/bin/brc
	setcap cap_sys_chroot=ep bedrock/bin/brc
	# git doesn't track empty directories, so they might not exist.  create
	# them.
	mkdir -p bedrock/brpath/bin:
	mkdir -p bedrock/brpath/clients:
	mkdir -p bedrock/brpath/sbin:
	mkdir -p bin:
	mkdir -p boot/extlinux:
	mkdir -p dev:
	mkdir -p etc/lib/fi:
	mkdir -p etc/var/chroot:
	mkdir -p home:
	mkdir -p lib/firmware:
	mkdir -p lib/modules:
	mkdir -p proc:
	mkdir -p root:
	mkdir -p sbin:
	mkdir -p sys:
	mkdir -p tmp:
	mkdir -p usr/bin:
	mkdir -p usr/sbin:
	mkdir -p var/lib/urandom:
	# set permissions for the entire userland
	find . -type d -exec chmod 755 {} \;
	find . -type f -exec chmod 644 {} \;
	chmod go-r etc/shadow
	chmod a+rwxt tmp
	find bedrock/bin/ -type f -exec chmod 755 {} \;
	find bedrock/sbin/ -type f -exec chmod 744 {} \;
	find . -exec chown root:root {} \;

# remove unnecessary files which could be left behind from installation
remove-unnecessary:
	-rm bedrock-userland-1.0alpha3.tar.gz 2>/dev/null
	-rm -rf .git 2>/dev/null
	-rm -r src/brc
	-rm README LICENSE Makefile 2>/dev/null

# clean up things which could have been created during development that we
# don't care to package or track with git.
clean:
	-rm src/brc/brc 2>/dev/null
	-rm -rf bin/* 2>/dev/null
	-rm -rf sbin/* 2>/dev/null
	-rm -rf bedrock/brpath/bin/* 2>/dev/null
	-rm -rf bedrock/brpath/sbin/* 2>/dev/null
	-rm -rf bedrock/brpath/clients/* 2>/dev/null

# package the project as a tarball for distribution
package:
	# ensure we're not packaging files created during development
	-rm src/brc/brc 2>/dev/null
	-rm -rf bin/* 2>/dev/null
	-rm -rf sbin/* 2>/dev/null
	-rm -rf bedrock/brpath/bin/* 2>/dev/null
	-rm -rf bedrock/brpath/sbin/* 2>/dev/null
	-rm -rf bedrock/brpath/clients/* 2>/dev/null
	# git doesn't track empty directories, but tarballs do: ensure they're
	# included
	mkdir -p bedrock/brpath/bin:
	mkdir -p bedrock/brpath/clients:
	mkdir -p bedrock/brpath/sbin:
	mkdir -p bin:
	mkdir -p boot/extlinux:
	mkdir -p dev:
	mkdir -p etc/lib/fi:
	mkdir -p etc/var/chroot:
	mkdir -p home:
	mkdir -p lib/firmware:
	mkdir -p lib/modules:
	mkdir -p proc:
	mkdir -p root:
	mkdir -p sbin:
	mkdir -p sys:
	mkdir -p tmp:
	mkdir -p usr/bin:
	mkdir -p usr/sbin:
	mkdir -p var/lib/urandom:
	# remove these two files - they're mostly for the git repo
	-rm README LICENSE 2>/dev/null
	# explicitly set permissions
	find . -type d -exec chmod 755 {} \;
	find . -type f -exec chmod 644 {} \;
	chmod go-r etc/shadow
	chmod a+rwxt tmp
	find bedrock/bin/ -type f -exec chmod 755 {} \;
	find bedrock/sbin/ -type f -exec chmod 744 {} \;
	find . -exec chown root:root {} \;
	# create the tarball
	tar -cvzf bedrock-userland-1.0alpha3.tar.gz *
