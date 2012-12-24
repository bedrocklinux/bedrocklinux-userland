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
	mkdir -p bedrock/brpath/bin
	mkdir -p bedrock/brpath/clients
	mkdir -p bedrock/brpath/sbin
	mkdir -p bin
	mkdir -p boot/extlinux
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
	mkdir -p var/chroot/bedrock
	# set permissions for the entire userland
	find . -type d -exec chmod 755 {} \;
	find . -type f -exec chmod 644 {} \;
	chmod go-r etc/shadow
	chmod a+rwxt tmp
	find etc/init.d/* -type f -exec chmod 744 {} \;
	find bedrock/bin/ -type f -exec chmod 755 {} \;
	find bedrock/sbin/ -type f -exec chmod 744 {} \;
	find . -name ".*" -o -exec chown root:root {} \;

# remove unnecessary files which could be left behind from installation
remove-unnecessary:
	-rm bedrock-userland-1.0alpha3.tar.gz
	-rm -rf .git
	-rm -r src/brc
	-rm README.md LICENSE Makefile
	-rm get-bb-cmds.sh

# clean up things which could have been created during development that we
# don't care to package or track with git.
clean:
	-rm src/brc/brc
	-rm -rf bin/*
	-rm -rf sbin/*
	-rm -rf bedrock/brpath/bin/*
	-rm -rf bedrock/brpath/sbin/*
	-rm -rf bedrock/brpath/clients/*

# package the project as a tarball for distribution
package:
	# ensure we're not packaging files created during development
	-rm src/brc/brc
	-rm -rf bin/*
	-rm -rf sbin/*
	-rm -rf bedrock/brpath/bin/*
	-rm -rf bedrock/brpath/sbin/*
	-rm -rf bedrock/brpath/clients/*
	# git doesn't track empty directories, but tarballs do: ensure they're
	# included
	mkdir -p bedrock/brpath/bin
	mkdir -p bedrock/brpath/clients
	mkdir -p bedrock/brpath/sbin
	mkdir -p bin
	mkdir -p boot/extlinux
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
	mkdir -p var/chroot/bedrock
	# remove these two files - they're for the git repo and development
	-rm README.md LICENSE
	-rm get-bb-cmds.sh
	# explicitly set permissions
	find . -type d -exec chmod 755 {} \;
	find . -type f -exec chmod 644 {} \;
	chmod go-r etc/shadow
	chmod a+rwxt tmp
	find etc/init.d/* -type f -exec chmod 744 {} \;
	find bedrock/bin/ -type f -exec chmod 755 {} \;
	find bedrock/sbin/ -type f -exec chmod 744 {} \;
	# ensure we can run "chown root:root" or error out
	# if this doesn't work, you're not root.  try again as root.
	chown root:root proc
	# chown everything to root
	find . -name ".*" -o -exec chown root:root {} \;
	# create the tarball
	tar -cvzf bedrock-userland-1.0alpha3.tar.gz *
