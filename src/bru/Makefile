all: bru.c
	$(CC) -Wall bru.c -o bru -lfuse3

clean:
	-rm bru

install:
	mkdir -p $(prefix)/sbin
	install -m 655 brc $(prefix)/sbin/bru

uninstall:
	rm $(prefix)/sbin/bru
