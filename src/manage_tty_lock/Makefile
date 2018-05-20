# manage_tty_lock makefile
#
#      This program is free software; you can redistribute it and/or
#      modify it under the terms of the GNU General Public License
#      version 2 as published by the Free Software Foundation.
#
# Copyright (c) 2015-2018 Daniel Thau <danthau@bedrocklinux.org>

all: manage_tty_lock

manage_tty_lock:
	$(CC) $(CFLAGS) -std=c99 manage_tty_lock.c -o manage_tty_lock

clean:
	rm -f manage_tty_lock

install:
	mkdir -p $(prefix)/sbin
	install -m 755 manage_tty_lock $(prefix)/sbin/manage_tty_lock

uninstall:
	rm -f $(prefix)/sbin/manage_tty_lock
