# keyboard_is_present makefile
#
#      This program is free software; you can redistribute it and/or
#      modify it under the terms of the GNU General Public License
#      version 2 as published by the Free Software Foundation.
#
# Copyright (c) 2019 Daniel Thau <danthau@bedrocklinux.org>

all: keyboard_is_present

keyboard_is_present: keyboard_is_present.c
	$(CC) $(CFLAGS) -std=c99 keyboard_is_present.c -o keyboard_is_present

clean:
	rm -f keyboard_is_present

install:
	mkdir -p $(prefix)/sbin
	install -m 755 keyboard_is_present $(prefix)/sbin/keyboard_is_present

uninstall:
	rm -f $(prefix)/sbin/keyboard_is_present
