# Builds a drop-in libpulse.so.0 replacement from pulse_shim.c.
#
# Requirements (build-time only): gcc, the PulseAudio headers (libpulse-dev
# on Debian/Ubuntu/Raspberry Pi OS). Nothing from the real libpulse is
# linked or needed at run time -- only libc, libpthread and libm.
#
# Usage:
#   make                         # builds ./libpulse.so.0 for the host arch
#   CC=aarch64-linux-gnu-gcc make  # cross-compile for 64-bit Pi
#   CC=arm-linux-gnueabihf-gcc make  # cross-compile for 32-bit Pi
#   make test                    # builds the shim + a self-contained test
#                                 # client (test_client.c, linked against the
#                                 # real pulse headers) and plays a 2s tone
#                                 # through it into /tmp/shim-test.raw --
#                                 # validates the shim end-to-end without
#                                 # needing the real Soloist binary at all.

CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra
LIBS    = -lpthread -lm

all: libpulse.so.0

libpulse.so.0: pulse_shim.c
	$(CC) $(CFLAGS) -fPIC -shared -Wl,-soname,libpulse.so.0 -o $@ $< $(LIBS)

test_client: test_client.c libpulse.so.0
	$(CC) $(CFLAGS) -o $@ test_client.c -L. -l:libpulse.so.0 $(LIBS)

# Plays a 2s tone into /tmp/shim-test.raw (24-bit stereo, 44.1 kHz) and
# prints its size -- should be ~2.0s worth of audio (264600 bytes).
test: test_client
	touch /tmp/shim-test.raw
	LD_LIBRARY_PATH=. SOLOIST_SHIM_OUT=/tmp/shim-test.raw ./test_client 2
	ls -l /tmp/shim-test.raw

clean:
	rm -f libpulse.so.0 test_client

.PHONY: all test clean

