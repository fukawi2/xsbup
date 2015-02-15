all: install

install:
	install -D -m 0755 xsbup.sh $(DESTDIR)/usr/local/sbin/xsbup
