# Spotify Soloist for Lyrion Music Server

Runs one Spotify Soloist instance per selected Lyrion/Squeezebox player. Each
player appears as its own Spotify Connect device, while the plugin relays audio
into LMS and publishes track metadata and cover art through LMS's native
interfaces.

No Icecast server is required.

## Audio backends

The plugin supports two backends:

1. **Direct PCM shim** (default) - a locally built `libpulse.so.0`
   compatibility library writes Soloist's raw PCM directly to a per-player
   FIFO. This backend does not require a running PulseAudio or PipeWire server.
2. **PulseAudio/PipeWire** - Soloist writes to an isolated null sink per
   player. The bridge captures that sink's monitor.

The former ALSA/apulse loopback backend has been removed. Existing
`audioBackend = alsa` preferences safely migrate to the direct PCM shim.

## Audio path

### PulseAudio/PipeWire

```text
Spotify
  -> Soloist
  -> per-player Pulse/PipeWire null sink
  -> parec (PCM/WAV) or ffmpeg (MP3/FLAC)
  -> per-player FIFO
  -> audio-relay.py
  -> LMS/player
```

### Direct PCM shim

```text
Spotify
  -> Soloist
  -> custom libpulse.so.0
  -> per-player raw-PCM FIFO
  -> direct forwarding (PCM/WAV) or ffmpeg (MP3/FLAC)
  -> audio-relay.py
  -> LMS/player
```

PCM/WAV mode does not run ffmpeg. The relay adds a streaming WAV header for
each HTTP connection and forwards the PCM unchanged. LMS may then use its own
conversion rules when a player cannot consume WAV directly.

## Requirements

Common requirements:

- Lyrion Music Server 8.0 or newer
- Spotify Soloist and a valid Soloist API key
- Python 3
- ffmpeg for MP3 or FLAC bridge output

Pulse backend requirements:

- a running PulseAudio server or PipeWire with PulseAudio compatibility
- `pactl`, `pacat`, and `parec` (normally provided by `pulseaudio-utils`)

Direct PCM shim requirements:

- a Soloist build compatible with the shim's exported Pulse API subset
- x86_64 uses the bundled `Bin/Shim/X86_64/libpulse.so.0`
- other architectures need a C compiler, `make`, and PulseAudio development
  headers to build the shim locally

## Installation

Install the plugin through the LMS repository/feed or copy the plugin directory
to LMS's plugin directory. Restart LMS, then open:

**Settings -> Plugins -> Spotify Soloist**

Configure:

- **Soloist binary path**
- **Soloist API key**
- **Audio backend**
- the players that should receive a Spotify Connect device
- the global or per-player stream format

Each selected player receives stable control and relay ports based on its saved
slot.

## PulseAudio/PipeWire backend

Install the Debian prerequisites:

```bash
sudo apt update
sudo apt install -y pulseaudio pulseaudio-utils ffmpeg python3
```

The plugin creates one null sink per enabled player and keeps it active while
the bridge runs. The configured sink prefix defaults to `soloist_sink`.

`Bin/setup-debian-prereqs.sh` is a convenience helper for this backend. It is
not required by the direct PCM shim backend.

## Direct PCM shim backend

On x86_64, the plugin automatically uses the validated shim bundled at:

```text
Bin/Shim/X86_64/libpulse.so.0
```

No shim-directory configuration is required for the bundled binary. To
override it, or on another architecture, build the source in
`contrib/experimental-pcm-shim/` on the LMS host:

```bash
cd contrib/experimental-pcm-shim
make
```

For a custom build, move or copy its directory to a path readable and
searchable by the LMS service account. Do not place it below `/root`; the
`squeezeboxserver` user normally cannot traverse that directory.

In the plugin settings:

1. Select **Experimental direct-PCM shim**.
2. On x86_64, keep the automatically populated bundled shim directory. For a
   custom build, set **Experimental PCM shim directory** to the directory
   containing the built `libpulse.so.0`.
3. Select **PCM/WAV** for the most direct path, or MP3/FLAC if the bridge
   should encode before LMS receives the stream.
4. Save and restart the affected bridges.

The bridge sets `LD_LIBRARY_PATH` only for the Soloist process, creates a
per-player `pcm-shim.fifo`, and passes its path through `SOLOIST_SHIM_OUT`.

For diagnostic logging, set `SOLOIST_PCM_SHIM_LOG=1` or `2` in the LMS service
environment and restart LMS. The bridge passes that value to the shim as
`SOLOIST_SHIM_LOG`.

See `contrib/experimental-pcm-shim/README.md` for build details, supported
environment variables, and limitations.

## Stream formats

- **PCM/WAV** - raw 44.1 kHz, stereo, 16-bit PCM; no ffmpeg in the bridge.
  LMS can transcode the WAV source through its normal conversion pipeline.
- **FLAC** - encoded by the bridge with ffmpeg.
- **MP3** - encoded by the bridge with ffmpeg at the configured bitrate.

The global format is the default. Each enabled player can override it
independently from the settings page.

## Runtime files and logs

Per-player data is stored below LMS's preferences and cache directories:

```text
<prefs>/plugin-spotifysoloist/data/player_<slot>/
<cache>/plugin-spotifysoloist/cache/player_<slot>/
```

The main bridge log is:

```text
<cache>/plugin-spotifysoloist/cache/player_<slot>/bridge.log
```

Useful successful startup lines include:

```text
[soloist-bridge] soloist ready
[soloist-bridge] relay confirmed ready
[soloist-bridge] stream ready: http://...
```

For the direct PCM shim, shim diagnostics appear in the same bridge log:

```text
[soloist-shim] loaded build ...
```

## Troubleshooting

### Spotify device is missing

- Verify the player is enabled in the plugin settings.
- Check the Soloist binary path and API key.
- Inspect the player's `bridge.log` for Soloist startup or login errors.
- Confirm the per-player WebSocket port is not already in use.

### Pulse backend has no audio

- Run `pactl info` as the same user that runs LMS.
- Confirm `pactl`, `pacat`, and `parec` are installed.
- Check that the per-player null sink and its monitor exist.
- Confirm the LMS service account has a writable home/config directory.

### Direct PCM shim does not load

- Confirm `libpulse.so.0` exists in the configured shim directory.
- Confirm the LMS service account can traverse the directory and read the
  library.
- Rebuild the shim on the target host.
- Enable `SOLOIST_PCM_SHIM_LOG=1` and restart the LMS service.
- If the load marker appears but no Pulse API calls follow, the Soloist build
  may require a Pulse symbol not yet implemented by the shim.

### Playback starts and immediately pauses

Use shim logging level `2` and inspect `bridge.log`. Confirm the current shim
was rebuilt and deployed, and that the bridge reports a `pcm-shim` backend and
the expected per-player FIFO.

## Security and network exposure

Soloist control WebSockets bind to loopback. Audio relays bind to the configured
relay address (default `0.0.0.0`) so network players can reach LMS's source
stream. Restrict access with host firewall rules on untrusted networks.

## License

See the repository license and the notices in `contrib/experimental-pcm-shim/`.
