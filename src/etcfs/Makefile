# etcfs makefile
#
#      This program is free software; you can redistribute it and/or
#      modify it under the terms of the GNU General Public License
#      version 2 as published by the Free Software Foundation.
#
# Copyright (c) 2013-2018 Daniel Thau <danthau@bedrocklinux.org>

all: etcfs

etcfs: etcfs.c
	$(CC) $(CFLAGS) -std=c99 -D_FILE_OFFSET_BITS=64 etcfs.c -o etcfs -lfuse3 -lpthread

clean:
	rm -f etcfs

install:
	mkdir -p $(prefix)/sbin
	install -m 755 etcfs $(prefix)/sbin/etcfs

uninstall:
	rm -f $(prefix)/sbin/etcfs
