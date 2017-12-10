all: bru.c
	$(CC) -Wall -static bru.c -o bru -lfuse

clean:
	- rm -f bru

install:
	mkdir -p $(prefix)/sbin
	install -m 755 bru $(prefix)/sbin/bru

uninstall:
	- rm -f $(prefix)/sbin/bru
