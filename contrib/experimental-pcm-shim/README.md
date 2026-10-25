# Experimental direct-PCM Pulse shim

This directory contains a small `libpulse.so.0` compatibility library for
Spotify Soloist. Instead of connecting to a PulseAudio or PipeWire server, it
writes decoded PCM to a FIFO or Unix socket selected through environment
variables.

The plugin exposes this as `audioBackend = pcm-shim`. The default
Pulse/PipeWire backend remains available and unchanged.

The direct PCM path has been validated on DietPi/LMS with Soloist
1.3.8.36: Soloist loads the shim, writes PCM to the per-player FIFO, and LMS
plays the WAV stream without ffmpeg.

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
containing that file.

The LMS service account must be able to traverse the directory and read the
library. A directory below `/root` is normally unsuitable.

## Runtime interface

The bridge starts Soloist with this directory prepended to `LD_LIBRARY_PATH`
and sets:

- `SOLOIST_SHIM_OUT` - FIFO path or Unix socket path
- `SOLOIST_SHIM_FORMAT` - `s16` for the plugin integration
- `SOLOIST_SHIM_RATE` - `44100` for the plugin integration
- `SOLOIST_SHIM_LOG` - diagnostic level (`0`, `1`, or `2`)
- `SOLOIST_SHIM_MAX_TLENGTH_MS` - playback buffer clamp; the bridge defaults
  this to `300`

The plugin creates one FIFO per player and configures the shim independently
for each Soloist process.

## Plugin audio path

```text
Soloist
  -> this libpulse.so.0
  -> player_<slot>/pcm-shim.fifo
  -> direct byte forwarding for PCM/WAV
     or ffmpeg encoding for MP3/FLAC
  -> player_<slot>/audio.fifo
  -> audio-relay.py
  -> LMS/player
```

For PCM/WAV, the relay adds a streaming WAV header per HTTP client; it does not
encode or alter the PCM payload.

## Diagnostics

Set `SOLOIST_PCM_SHIM_LOG=1` or `2` in the LMS service environment, restart LMS,
and inspect the player's `bridge.log`. The bridge maps this setting to
`SOLOIST_SHIM_LOG`.

A successfully loaded build logs:

```text
[soloist-shim] loaded build 2026-10-25.2: ...
```

Level `2` also logs Pulse API activity. A constructor/load marker without
subsequent API calls can mean Soloist rejected the library during its initial
symbol probe.

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
- Build and deploy the library separately on each target architecture; no
  prebuilt binary is bundled with the plugin.
- MP3 and FLAC bridge output still require ffmpeg. PCM/WAV does not.

## Clean

```bash
make clean
```
