# strat makefile
#
#      This program is free software; you can redistribute it and/or
#      modify it under the terms of the GNU General Public License
#      version 2 as published by the Free Software Foundation.
#
# Copyright (c) 2012-2018 Daniel Thau <danthau@bedrocklinux.org>

all: strat

strat: strat.c
	$(CC) $(CFLAGS) -std=c99 strat.c -o strat -lcap

clean:
	rm -f strat

install:
	mkdir -p $(prefix)/bin
	install -m 755 strat $(prefix)/bin/strat

uninstall:
	rm -f $(prefix)/bin/strat
