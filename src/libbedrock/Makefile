all: libbedrock.c libbedrock.h
	$(CC) -c libbedrock.c -o libbedrock.o
	ar rcs libbedrock.a libbedrock.o

clean:
	-rm libbedrock.o
	-rm libbedrock.a

install:
	mkdir -p $(prefix)/lib
	mkdir -p $(prefix)/include
	install -m 644 libbedrock.a $(prefix)/lib/libbedrock.a
	install -m 644 libbedrock.h $(prefix)/include/libbedrock.h

uninstall:
	rm $(prefix)/lib/libbedrock.a
	rm $(prefix)/include/libbedrock.h
