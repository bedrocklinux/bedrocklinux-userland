all: brc.c
	$(CC) -Wall brc.c -o brc -static -lcap -lbedrock

clean:
	rm -f brc

install:
	mkdir -p $(prefix)/bin
	install -m 755 brc $(prefix)/bin/brc

uninstall:
	rm -f $(prefix)/bin/brc
