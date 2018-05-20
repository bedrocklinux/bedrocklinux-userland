# bouncer makefile
#
#      This program is free software; you can redistribute it and/or
#      modify it under the terms of the GNU General Public License
#      version 2 as published by the Free Software Foundation.
#
# Copyright (c) 2017-2018 Daniel Thau <danthau@bedrocklinux.org>

all: bouncer

strat:
	$(CC) $(CFLAGS) -std=c99 bouncer.c -o bouncer

clean:
	rm -f bouncer

install:
	mkdir -p $(prefix)/bin
	install -m 755 strat $(prefix)/bin/bouncer

uninstall:
	rm -f $(prefix)/bin/bouncer
