all: bru.c
	$(CC) -Wall -static bru.c -o bru -lfuse

clean:
	-rm bru

install:
	mkdir -p $(prefix)/sbin
	install -m 755 bru $(prefix)/sbin/bru

uninstall:
	rm $(prefix)/sbin/bru
