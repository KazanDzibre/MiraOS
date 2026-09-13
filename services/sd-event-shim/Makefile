# Mira's sd-event shim.
#
# Installs as libsystemd because that is the name pkg-config discovery looks
# for; it is emphatically not systemd. See sd-event.h for why this exists.

NAME    := libsystemd
SOVER   := 0
SONAME  := $(NAME).so.$(SOVER)

CC      ?= gcc
CFLAGS  ?= -O2
CFLAGS  += -std=gnu11 -Wall -Wextra -fPIC -I.
LDLIBS  += -lpthread

PREFIX  ?= /usr
LIBDIR  ?= $(PREFIX)/lib
INCDIR  ?= $(PREFIX)/include
PCDIR   ?= $(LIBDIR)/pkgconfig

.PHONY: all install test clean

all: $(SONAME) libsystemd.pc

sd-event.o: sd-event.c systemd/sd-event.h
	$(CC) $(CFLAGS) -c -o $@ $<

$(SONAME): sd-event.o
	$(CC) -shared -Wl,-soname,$(SONAME) -o $@ $^ $(LDFLAGS) $(LDLIBS)

libsystemd.pc: libsystemd.pc.in
	sed -e 's|@PREFIX@|$(PREFIX)|g' \
	    -e 's|@LIBDIR@|$(LIBDIR)|g' \
	    -e 's|@INCDIR@|$(INCDIR)|g' $< > $@

install: all
	install -d $(DESTDIR)$(LIBDIR) $(DESTDIR)$(INCDIR)/systemd $(DESTDIR)$(PCDIR)
	install -m 0755 $(SONAME) $(DESTDIR)$(LIBDIR)/$(SONAME)
	ln -sf $(SONAME) $(DESTDIR)$(LIBDIR)/$(NAME).so
	install -m 0644 systemd/sd-event.h $(DESTDIR)$(INCDIR)/systemd/sd-event.h
	install -m 0644 libsystemd.pc $(DESTDIR)$(PCDIR)/libsystemd.pc

# Host-side sanity check. Run it after touching sd-event.c - the ordering and
# refcount rules here are exactly the ones flutter-pi leans on.
test:
	$(CC) -std=gnu11 -Wall -Wextra -O1 -g -fsanitize=address,undefined -I. \
		-o /tmp/mira-sd-event-test sd-event.c test/test-sd-event.c -lpthread
	/tmp/mira-sd-event-test

clean:
	rm -f sd-event.o $(SONAME) libsystemd.pc
