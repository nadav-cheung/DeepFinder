# Standalone Makefile for libdfindex — the DeepFinder C index core.
# Pure C (C17), macOS/arm64, zero external dependencies beyond libSystem.
#
#   make            build the static lib + demo
#   make lib        build libdfindex.a only
#   make demo       build dfdemo only
#   make test       build + run the C test suite
#   make install    install headers + lib to PREFIX (default: /usr/local)
#   make clean      remove build artifacts

CC       ?= cc
CFLAGS   ?= -O2 -std=c17 -Wall -Wextra -arch arm64
CFLAGS   += -Iinclude
AR       ?= ar
ARFLAGS  := rcs

PREFIX   ?= /usr/local
SRCDIR   := src
INCDIR   := include

OBJS = $(SRCDIR)/CIndex.o $(SRCDIR)/CFileScanner.o $(SRCDIR)/CParallelScanner.o $(SRCDIR)/CTrigramIndex.o
HEADERS = $(INCDIR)/CIndex.h $(INCDIR)/CTrigramIndex.h $(INCDIR)/CFileScanner.h $(INCDIR)/CParallelScanner.h $(INCDIR)/dfindex.h

.PHONY: all lib demo test install clean

all: lib demo

lib: libdfindex.a

libdfindex.a: $(OBJS)
	$(AR) $(ARFLAGS) $@ $^

demo: dfdemo

dfdemo: examples/demo.c libdfindex.a
	$(CC) $(CFLAGS) -o $@ examples/demo.c -L. -ldfindex

# C test suite: compiles tests/test_core.c against the static lib.
test: dfdemo tests/test_core.c libdfindex.a
	$(CC) $(CFLAGS) -o tests/dftest tests/test_core.c -L. -ldfindex
	./tests/dftest

# Install headers + static lib (no demo) for use as a system C library.
install: libdfindex.a
	install -d $(PREFIX)/include/dfindex
	install -m 0644 $(HEADERS) $(PREFIX)/include/dfindex/
	install -d $(PREFIX)/lib
	install -m 0644 libdfindex.a $(PREFIX)/lib/

$(SRCDIR)/%.o: $(SRCDIR)/%.c $(HEADERS)
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJS) libdfindex.a dfdemo tests/dftest
