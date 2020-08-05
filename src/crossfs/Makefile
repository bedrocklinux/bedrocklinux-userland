# crossfs makefile
#
#      This program is free software; you can redistribute it and/or
#      modify it under the terms of the GNU General Public License
#      version 2 as published by the Free Software Foundation.
#
# Copyright (c) 2014-2018 Daniel Thau <danthau@bedrocklinux.org>

all: crossfs

crossfs: crossfs.c definitions.h service_generation.h
	$(CC) $(CFLAGS) -std=c99 -D_FILE_OFFSET_BITS=64 crossfs.c -o crossfs -lfuse3 -lpthread

clean:
	rm -f crossfs

install:
	mkdir -p $(prefix)/sbin
	install -m 755 crossfs $(prefix)/sbin/crossfs

uninstall:
	rm -f $(prefix)/sbin/crossfs
