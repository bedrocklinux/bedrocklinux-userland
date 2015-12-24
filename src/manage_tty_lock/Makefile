all: manage_tty_lock
	$(CC) -Wall manage_tty_lock.c -o manage_tty_lock -static

clean:
	- rm manage_tty_lock

install:
	mkdir -p $(prefix)/sbin
	install -m 755 manage_tty_lock $(prefix)/sbin/manage_tty_lock

uninstall:
	rm $(prefix)/sbin/manage_tty_lock
