CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -pthread
LDFLAGS ?= -pthread

BINS = fakellm llmbench

all: $(BINS)

fakellm: fakellm.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

llmbench: llmbench.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(BINS)

.PHONY: all clean
