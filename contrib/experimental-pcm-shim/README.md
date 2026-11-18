# Experimental direct-PCM Pulse shim

This directory contains a small `libpulse.so.0` compatibility library for
Spotify Soloist. Instead of connecting to a PulseAudio or PipeWire server, it
writes decoded PCM to a FIFO or Unix socket selected through environment
variables.

The plugin exposes this as the default `audioBackend = pcm-shim`.
The Pulse/PipeWire backend remains available as an alternative.

The direct PCM path has been validated on DietPi/LMS with Soloist
1.3.8.36: Soloist loads the shim, writes PCM to the per-player FIFO, and LMS
plays the WAV stream without ffmpeg.

Validated builds are bundled at `Bin/X86_64`, `Bin/ARMv7`, and
`Bin/ARMv8_Arch64`. Build from this directory when targeting another
architecture or testing source changes.

## Build

Build on the LMS host:

```bash
sudo apt install -y build-essential libpulse-dev
make
```

The output is:

```text
libpulse.so.0
```

Point the plugin's **Experimental PCM shim directory** setting at the directory
containing that file. The plugin automatically selects a bundled build for
x86_64, ARMv7, and ARMv8/AArch64.

The LMS service account must be able to traverse the directory and read the
library. A directory below `/root` is normally unsuitable.

## Runtime interface

The bridge starts Soloist with this directory prepended to `LD_LIBRARY_PATH`
and sets:

- `SOLOIST_SHIM_OUT` - FIFO path or Unix socket path
- `SOLOIST_SHIM_FORMAT` - `s16` for the plugin integration
- `SOLOIST_SHIM_RATE` - `44100` for the plugin integration
- `SOLOIST_SHIM_LOG` - diagnostic level (`0`, `1`, or `2`)
- `SOLOIST_SHIM_RING_MS` - bounded live-edge ring depth; the bridge uses `200`
- `SOLOIST_SHIM_MODE` - `live-ring` (default) or `compat`; compatibility mode
  restores the pre-ring Pulse buffer growth and sink-wait behavior for A/B tests
- `SOLOIST_SHIM_CONTROL` - optional atomic generation command file
- `SOLOIST_SHIM_ACK` - optional generation acknowledgement file
- `SOLOIST_SHIM_MAX_TLENGTH_MS` - playback buffer clamp; the bridge defaults
  this to `300`

The plugin creates one FIFO per player and configures the shim independently
for each Soloist process.

## Plugin audio path

```text
Soloist
  -> this libpulse.so.0
  -> bounded live-edge ring (200 ms by default)
  -> player_<slot>/audio.fifo for PCM/WAV
     or player_<slot>/pcm-shim.fifo -> ffmpeg for MP3/FLAC
  -> player_<slot>/audio.fifo
  -> soloist:// protocol handler
  -> LMS/player
```

For PCM/WAV, the protocol handler adds a streaming WAV header when LMS opens
the FIFO; it does not encode or alter the PCM payload.

`pa_stream_write` only copies complete frames into the bounded ring. The writer
thread transmits available frames immediately with nonblocking FIFO writes.
Temporary FIFO `EAGAIN` is retried while the ring's configured time budget has
not been superseded, allowing ordinary scheduler and network-player read jitter
without gaps. If the reader remains slow beyond that budget, the in-flight
oldest complete frames are discarded, keeping playback near the live edge and
bounding total PCM buffering to approximately 300 ms with the bridge's FIFO.

Generation command files contain `<generation> <reason>`. When the plugin
atomically replaces the file, the writer clears queued old-generation frames,
resets resampling state, and atomically writes the same generation to the
acknowledgement file. The plugin waits for that acknowledgement before replacing
the LMS protocol handler. Pulse `flush` requests clear the ring through the same
internal generation path.

## Diagnostics

Set `SOLOIST_PCM_SHIM_LOG=1` or `2` in the LMS service environment, restart LMS,
and inspect the player's `bridge.log`. The bridge maps this setting to
`SOLOIST_SHIM_LOG`.

A successfully loaded build logs its configured ring depth and control path:

```text
[soloist-shim] loaded build 2026-11-18.3-loadcheck: mode=live-ring ... ring_ms=200 ...
```

Level `2` also logs Pulse API activity. A constructor/load marker without
subsequent API calls can mean Soloist rejected the library during its initial
symbol probe.

Level `1` rate-limits output-pressure summaries containing the number of
`EAGAIN` and partial writes plus maximum sink wait and queued milliseconds.
Normal backpressure may produce pressure summaries, but uninterrupted playback
should not produce `live-edge drop` or `stream underflow`.

Every five seconds the shim also logs a `runtime summary` with queued audio,
oldest scheduled audio age,
producer writes/callbacks, underflows, dropped milliseconds, maximum writer
scheduling gap, and requested writable time. These counters distinguish
producer starvation or bursty Pulse timing from downstream FIFO pressure.

Soloist currently requires compatibility exports including:

- `pa_context_get_sink_input_info`
- `pa_gettimeofday`
- `pa_timeval_diff`

## Limitations

- This is a focused compatibility implementation, not a complete PulseAudio
  client library.
- A future Soloist release may require additional Pulse symbols or semantics.
- The plugin integration currently assumes stereo, 44.1 kHz, signed 16-bit
  little-endian PCM.
- Bundled binaries support x86_64, ARMv7 hard-float, and ARMv8/AArch64.
  Build and deploy the library separately on every other target architecture.
- MP3 and FLAC bridge output still require ffmpeg. PCM/WAV does not.

## Clean

```bash
make clean
```
