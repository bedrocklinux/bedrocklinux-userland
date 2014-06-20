all: bru.c
	$(CC) -Wall bru.c -o bru -lfuse

clean:
	-rm bru

install:
	mkdir -p $(prefix)/sbin
	install -m 655 bru $(prefix)/sbin/bru

uninstall:
	rm $(prefix)/sbin/bru
