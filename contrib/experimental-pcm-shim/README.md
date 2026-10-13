# Experimental direct-PCM pulse shim (NOT wired into the plugin)

> **Status: experimental, unvalidated, not used by the bridge/plugin yet.**
> This directory holds an alternative `libpulse.so.0` replacement
> (`pulse_shim.c`) that was proposed as a possible successor to the
> bundled apulse-based shim in `alsa-lib/`. It has **not** been compiled
> or run against the real Soloist binary in this repository's history --
> only build/run instructions and a symbol-coverage check are provided
> here. Treat it as a candidate to evaluate, not a supported backend.

## Why this exists

The ALSA/apulse backend (the bundled shim in `alsa-lib/`, see the main
`README.md`) works, but has an outstanding bug: tracks can stop advancing
near their natural end (position reporting can race ahead of real ALSA
output through that shim's own playback buffer). `Bin/soloist-bridge.sh`
currently works around this with a buffer-size clamp
(`APULSE_MAX_TLENGTH_MS`) plus a watchdog in `Plugin.pm` that force-skips
a track if its reported position freezes -- see `CHANGELOG.md` for the
full history. Neither is a confirmed root-cause fix.

This shim takes a different approach: it paces playback on a real
monotonic clock inside its own writer thread and reports
`pa_stream_get_time()` / `pa_stream_get_timing_info()` based on bytes
**actually drained from its internal ring buffer**, not bytes the
application merely handed to `pa_stream_write()`. If Soloist relies on
either call for its own "now playing" position, that architecture should
by construction avoid the position-races-ahead-of-output class of bug --
but this has not been confirmed against the real binary.

It also writes raw PCM straight to a FIFO/socket/file instead of going
through a PipeWire/Pulse null sink or an ALSA loopback card
(`snd-aloop`), which would let a future bridge read audio directly off
that FIFO -- removing the `arecord`/`hw:`/`plughw:` device-string
plumbing in `Bin/soloist-bridge.sh` entirely. That is a materially
different audio path from both existing backends, which is why
integrating it is a separate, larger change from just swapping a shim
binary.

## What's in this directory

- `pulse_shim.c` -- the shim source, as proposed. Implements both
  `pa_mainloop` and `pa_threaded_mainloop`, sample conversion from
  U8/S16LE/S24LE/S24_32LE/S32LE/FLOAT32LE to a fixed output format,
  real-time pacing, FIFO/unix-socket/file output, and the handful of
  `pa_context_*`/`pa_stream_*` calls a simple playback-only client needs.
  It does **not** implement the raw `pa_mainloop_api` event sources
  (`io_new`/`time_new`/`defer_new`) -- a client that drives the mainloop
  through those directly (rather than through
  `pa_threaded_mainloop_{lock,wait,signal}`) will not work with it. It
  also does not support recording (playback-only, one stream type).
- `Makefile` -- builds `libpulse.so.0` from `pulse_shim.c`. Needs `gcc`
  and the PulseAudio headers (`libpulse-dev`) at build time only;
  nothing from the real libpulse is linked at run time. Cross-compile
  for a Pi with `CC=aarch64-linux-gnu-gcc` (64-bit) or
  `CC=arm-linux-gnueabihf-gcc` (32-bit) plus the matching headers.
- `check-symbols.sh` -- compares the `pa_*` symbols a binary (e.g. the
  real `soloist` binary) imports against the ones this shim exports, so
  you can tell whether it's a safe drop-in **before** trying it for real.

## How to evaluate this on your own device (required before any integration)

```sh
cd contrib/experimental-pcm-shim
make                                   # -> ./libpulse.so.0
./check-symbols.sh /usr/local/bin/soloist ./libpulse.so.0
```

If `check-symbols.sh` reports missing symbols, Soloist will fail to
start (or crash on first use of one of them) under this shim -- those
calls would need to be added before it's usable at all.

If symbols check out, smoke-test real playback manually, independent of
the plugin, before considering integration:

```sh
mkfifo /tmp/soloist-pcm.fifo
SOLOIST_SHIM_OUT=/tmp/soloist-pcm.fifo \
SOLOIST_SHIM_FORMAT=s16 \
SOLOIST_SHIM_RATE=44100 \
SOLOIST_SHIM_LOG=1 \
LD_LIBRARY_PATH=/path/to/contrib/experimental-pcm-shim \
  /usr/local/bin/soloist -n "test" -k "$SOLOIST_API_KEY" &

# In another shell, once a reader is attached the shim will start
# writing to it:
aplay -t raw -f S16_LE -r 44100 -c 2 /tmp/soloist-pcm.fifo
```

Watch specifically for: does Soloist start and log in normally; does
audio play at the correct pitch/speed; and -- the actual bug this is
meant to fix -- **do multiple tracks transition automatically without
stalling near the end of a track.** Also check `SOLOIST_SHIM_LOG=1`
output for repeated `ring overflow: dropped N bytes` (means Soloist is
writing faster than real-time and this shim's buffer is too small for
the `SOLOIST_SHIM_RATE`/format chosen) or crashes.

## Environment variables (as implemented in `pulse_shim.c`)

| Variable | Meaning | Default |
|---|---|---|
| `SOLOIST_SHIM_OUT` | Output path: FIFO, unix socket, or plain file. | `/tmp/soloist-pcm.fifo` |
| `SOLOIST_SHIM_FORMAT` | Output sample width: `s16`, `s24` (packed 3-byte), or `s32`. | `s24` |
| `SOLOIST_SHIM_RATE` | Output rate in Hz, `0` passes the stream's own rate through unchanged. | `44100` |
| `SOLOIST_SHIM_LOG` | `0` quiet, `1` info (connects/disconnects, overflows), `2` also traces API calls. | `0` |

(An earlier reference document attached alongside this source used a
different variable naming scheme, `SOLOIST_PCM_*`, for what appears to
be a related but not identical project. The table above matches what
`pulse_shim.c` in this directory actually reads -- use these names.)

## Known limitations (from reading the source)

- Playback only; no recording support, no `pa_stream_peek`/`pa_stream_drop`.
- One stream plays after another in creation order (no mixing).
- Raw (non-threaded) `pa_mainloop_api` event-source registration
  (`io_new`/`time_new`/`defer_new`) is not implemented -- a client using
  those directly instead of a threaded mainloop's lock/wait/signal
  pattern will not function correctly.
- Little-endian PCM output only.
- Volume/mute calls are accepted but ignored (volume is expected to be
  handled by LMS/the player, same assumption the apulse backend makes).
- If the FIFO has no reader, audio is silently discarded at the pacing
  rate rather than buffered indefinitely -- a reader must be attached
  before (or very soon after) playback starts to avoid losing the start
  of a track.
- Soloist reportedly prefers PipeWire and only falls back to PulseAudio
  if PipeWire is unavailable to it; exactly how it probes for PipeWire
  is untested, so PipeWire must genuinely be absent/unreachable for this
  shim to be used at all (same constraint the apulse backend already
  has).

## What integrating this into the plugin would require (not done here)

This is intentionally **not** wired into `Plugin.pm` or
`Bin/soloist-bridge.sh`. Doing so safely would need, at minimum:

1. Symbol-coverage and real-playback validation per above, on real
   hardware, against the actual `soloist` binary.
2. A new, distinct bridge capture path: reading raw PCM directly from
   `SOLOIST_SHIM_OUT`'s FIFO (format/rate from `SOLOIST_SHIM_FORMAT` /
   `SOLOIST_SHIM_RATE`) instead of running `arecord` against an ALSA
   loopback device -- this is a different code path from both the
   existing Pulse and ALSA/apulse backends, not a drop-in shim swap.
3. A new `SOLOIST_AUDIO_BACKEND` value (e.g. `shim`) in `Plugin.pm` /
   `Bin/soloist-bridge.sh`, kept opt-in and off by default, with the
   existing Pulse and ALSA/apulse backends left untouched.
4. Prebuilt binaries for the architectures the plugin bundles shims for
   today (`alsa-lib/amd64`, `arm64`, `armhf`), with a reproducible build
   process, if this is to be bundled rather than built by the user.

## Licensing note

Per the source header, this is intended as original code, compiled
against the PulseAudio public headers (LGPL-2.1+) but not linking
anything from the real libpulse at run time. The Soloist binary itself
is not part of this and must be downloaded separately by each user per
Spotify's developer terms, same as for the existing bundled shim --
check those terms before distributing a built shim alongside the
plugin.
