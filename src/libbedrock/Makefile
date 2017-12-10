all: libbedrock.c libbedrock.h
	$(CC) -c libbedrock.c -o libbedrock.o
	ar rcs libbedrock.a libbedrock.o

clean:
	- rm -f libbedrock.o
	- rm -f libbedrock.a

install:
	mkdir -p $(prefix)/lib
	mkdir -p $(prefix)/include
	install -m 644 libbedrock.a $(prefix)/lib/libbedrock.a
	install -m 644 libbedrock.h $(prefix)/include/libbedrock.h

uninstall:
	- rm -f $(prefix)/lib/libbedrock.a
	- rm -f $(prefix)/include/libbedrock.h
