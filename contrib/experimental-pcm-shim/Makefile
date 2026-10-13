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

CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra -fPIC -pthread
LDFLAGS ?= -shared -Wl,-soname,libpulse.so.0 -lpthread -lm

libpulse.so.0: pulse_shim.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

clean:
	rm -f libpulse.so.0

.PHONY: clean
