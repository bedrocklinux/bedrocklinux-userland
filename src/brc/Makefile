all: brc.c
	$(CC) -Wall brc.c -o brc -static -lcap -lbedrock

clean:
	-rm brc

install:
	mkdir -p $(prefix)/bin
	install -m 655 brc $(prefix)/bin/brc

uninstall:
	rm $(prefix)/bin/brc
