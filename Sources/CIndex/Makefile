# Standalone Makefile for the DeepFinder C index core (libdfindex)
# Pure C, macOS/arm64, zero external dependencies beyond libSystem.
CC      = cc
CFLAGS  = -O2 -std=c17 -Wall -Wextra -I. -arch arm64
AR      = ar
ARFLAGS = rcs

OBJS = CIndex.o CFileScanner.o CParallelScanner.o CTrigramIndex.o

.PHONY: all lib demo clean

all: lib demo

lib: libdfindex.a

libdfindex.a: $(OBJS)
	$(AR) $(ARFLAGS) $@ $^

demo: examples/demo.c libdfindex.a
	$(CC) $(CFLAGS) -o dfdemo examples/demo.c -L. -ldfindex

$(OBJS): include/CIndex.h include/CTrigramIndex.h

CFileScanner.o: include/CFileScanner.h
CParallelScanner.o: include/CParallelScanner.h
CTrigramIndex.o: include/CTrigramIndex.h

clean:
	rm -f $(OBJS) libdfindex.a dfdemo
