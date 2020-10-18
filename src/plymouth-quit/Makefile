# plymouth-quit makefile
#
#      This program is free software; you can redistribute it and/or
#      modify it under the terms of the GNU General Public License
#      version 2 as published by the Free Software Foundation.
#
# Copyright (c) 2020 Daniel Thau <danthau@bedrocklinux.org>

all: plymouth-quit

plymouth-quit: plymouth-quit.c
	$(CC) $(CFLAGS) -std=c99 plymouth-quit.c -o plymouth-quit

clean:
	rm -f plymouth-quit

install:
	mkdir -p $(prefix)/sbin
	install -m 755 plymouth-quit $(prefix)/sbin/plymouth-quit

uninstall:
	rm -f $(prefix)/sbin/plymouth-quit
