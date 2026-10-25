# Bundled C audio relay

`audio_relay.c` replaces the former Python relay used between each bridge
FIFO and LMS. It has no runtime dependencies beyond the Linux kernel and is
bundled as a static executable for:

- `Bin/X86_64/audio-relay`
- `Bin/ARMv7/audio-relay`
- `Bin/ARMv8_Arch64/audio-relay`

The plugin selects the relay from the host architecture. Shim selection is
separate and follows the configured Soloist executable's ELF architecture,
which matters when a 64-bit ARM host runs a 32-bit Soloist binary.

## Native build

```bash
make
make test
```

The behavioral test requires Python only as a development-time test driver.
Python is not used by the plugin at runtime.

## Static cross-build with Zig

```bash
zig cc -target x86_64-linux-musl -O2 -s -static -std=c11 \
  -Wall -Wextra -Werror -o ../../Bin/X86_64/audio-relay audio_relay.c

zig cc -target arm-linux-musleabihf -O2 -s -static -std=c11 \
  -Wall -Wextra -Werror -o ../../Bin/ARMv7/audio-relay audio_relay.c

zig cc -target aarch64-linux-musl -O2 -s -static -std=c11 \
  -Wall -Wextra -Werror -o ../../Bin/ARMv8_Arch64/audio-relay audio_relay.c
```

## Preserved behavior

- FIFO reopen when the capture writer restarts
- multiple simultaneous HTTP listeners
- bounded one-megabyte queue per client
- slow-client isolation by dropping the oldest queued audio
- per-connection streaming WAV headers
- `relay.ready` timestamp updates while audio flows
- `relay.flush` queue clearing at PCM track boundaries
- clean handling of client disconnects and termination signals
