all: manage_tty_lock

manage_tty_lock:
	$(CC) -Wall manage_tty_lock.c -o manage_tty_lock -static

clean:
	- rm -f manage_tty_lock

install:
	mkdir -p $(prefix)/sbin
	install -m 755 manage_tty_lock $(prefix)/sbin/manage_tty_lock

uninstall:
	- rm -f $(prefix)/sbin/manage_tty_lock
