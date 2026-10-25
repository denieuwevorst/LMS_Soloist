CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -Werror
LDFLAGS ?=

all: audio-relay

audio-relay: audio_relay.c
	$(CC) $(CFLAGS) -std=c11 $(LDFLAGS) -o $@ $<

clean:
	rm -f audio-relay

test: audio-relay
	python3 test_relay.py ./audio-relay

.PHONY: all clean test
