all: brp.c
	$(CC) -Wall -static brp.c -o brp -lfuse -lbedrock

clean:
	- rm -f brp

install:
	mkdir -p $(prefix)/sbin
	install -m 755 brp $(prefix)/sbin/brp

uninstall:
	- rm -f $(prefix)/sbin/brp
