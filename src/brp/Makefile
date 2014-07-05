all: brp.c
	$(CC) -Wall brp.c -o brp -lfuse -lbedrock

clean:
	-rm brp

install:
	mkdir -p $(prefix)/sbin
	install -m 755 brp $(prefix)/sbin/brp

uninstall:
	rm $(prefix)/sbin/brp
