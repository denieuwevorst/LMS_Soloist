# Spotify Soloist for Lyrion Music Server

Runs one Spotify Soloist instance per selected Lyrion/Squeezebox player. Each
player appears as its own Spotify Connect device, while the plugin injects audio
directly into LMS and publishes track metadata and cover art through LMS's native
interfaces.

No Icecast server, HTTP audio relay, or network audio port is required.

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
  -> soloist:// protocol handler
  -> LMS conversion/streaming pipeline
  -> player
```

### Direct PCM shim

```text
Spotify
  -> Soloist
  -> custom libpulse.so.0
  -> per-player raw-PCM FIFO
  -> direct forwarding (PCM/WAV) or ffmpeg (MP3/FLAC)
  -> soloist:// protocol handler
  -> LMS conversion/streaming pipeline
  -> player
```

PCM/WAV mode does not run ffmpeg. The protocol handler adds a streaming WAV
header when LMS opens the FIFO and forwards the PCM unchanged. LMS may then use
its own conversion rules when a player cannot consume WAV directly.

The handler opens the FIFO nonblocking in read/write mode. Keeping one local
writer open prevents a temporary capture-process exit from appearing as EOF to
LMS; the bridge can restart capture and continue through the same stream.

## Requirements

Common requirements:

- Lyrion Music Server 8.0 or newer
- Spotify Soloist and a valid Soloist API key
- ffmpeg for MP3 or FLAC bridge output

Pulse backend requirements:

- a running PulseAudio server or PipeWire with PulseAudio compatibility
- `pactl`, `pacat`, and `parec` (normally provided by `pulseaudio-utils`)

Direct PCM shim requirements:

- a Soloist build compatible with the shim's exported Pulse API subset
- a bundled shim matching the Soloist executable: x86_64, ARMv7 hard-float,
  or ARMv8/AArch64

## Installation

Install the plugin through the LMS repository/feed or copy the plugin directory
to LMS's plugin directory. Restart LMS, then open:

**Settings -> Plugins -> Spotify Soloist**

Configure:

- **Managed Soloist updates** (recommended), or a manually installed
  **Soloist binary path**
- **Soloist API key**
- **Audio backend**
- the players that should receive a Spotify Connect device
- the global or per-player stream format

Each selected player receives a stable control port and FIFO based on its saved
slot.

### Managed Soloist updates

Spotify Soloist builds expire 90 days after their build timestamp. Managed
updates are opt-in. When enabled, the plugin:

- downloads the selected Linux architecture directly from Spotify's official
  CDN (the binary is never redistributed with this plugin)
- keeps the configured manual binary path unchanged as a fallback
- installs the managed executable under the plugin's persistent data directory
- validates the archive entry, ELF architecture, executable mode, and
  `soloist --version` build timestamp before an atomic replacement
- retains the previous managed executable for rollback

Current Spotify builds require glibc 2.38 or newer. The plugin includes a
private architecture-matched glibc runtime for Soloist so older hosts such as
piCorePlayer can run it without replacing their system libraries. LMS and all other processes continue using the host runtime. Runtime
provenance and license information is documented in `Bin/GLIBC-RUNTIME.md`.
- checks daily and refreshes builds after 75 days, then restarts selected
  bridges only after a successful update

Use the architecture override only when a 64-bit ARM host intentionally runs
the 32-bit ARM Soloist build. Failed downloads or validation leave the current
binary running and are reported on the plugin settings page.

## PulseAudio/PipeWire backend

Install the Debian prerequisites:

```bash
sudo apt update
sudo apt install -y pulseaudio pulseaudio-utils ffmpeg
```

The plugin creates one null sink per enabled player and keeps it active while
the bridge runs. The configured sink prefix defaults to `soloist_sink`.

`Bin/setup-debian-prereqs.sh` is a convenience helper for this backend. It is
not required by the direct PCM shim backend.

## Direct PCM shim backend

The plugin reads the configured Soloist executable's ELF architecture and
automatically selects one of:

```text
Bin/X86_64/libpulse.so.0
Bin/ARMv7/libpulse.so.0
Bin/ARMv8_Arch64/libpulse.so.0
```

If the configured Soloist path is a wrapper script, the plugin falls back to
the host architecture reported by `uname`. No shim-directory configuration is
required for these bundled architectures. To override the selected binary or
support another architecture, build the source in
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
2. Keep the automatically populated architecture-specific shim directory. For
   a custom build, set **Experimental PCM shim directory** to the directory
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

- **PCM/WAV** - raw 44.1 kHz, stereo, 16-bit PCM at exactly 1,411,200 bps;
  no ffmpeg in the bridge. LMS can transcode the WAV source through its normal
  conversion pipeline.
- **FLAC** - 44.1 kHz, stereo, 16-bit lossless audio encoded by the bridge
  with ffmpeg. Its live compressed bitrate varies with the audio, so LMS shows
  it as a variable live stream rather than reporting a fabricated fixed value.
- **MP3** - 44.1 kHz stereo audio encoded by the bridge with ffmpeg at the
  configured constant bitrate.

The global format is the default. Each enabled player can override it
independently from the settings page. Lyrion's Now Playing and track-info
surfaces report these final bridge/FIFO properties, not Spotify's upstream
download quality.

## Volume normalization

The two normalization stages are separate:

- Lyrion's remote/internet-radio replay-gain fallback is bypassed for
  `soloist://` streams. Soloist supplies already-rendered audio, so LMS keeps
  the stream at unity gain rather than applying the player's radio correction.
- Spotify Soloist's own loudness normalization is configurable per player.
  Soloist reads `audio.normalize_v2` from its classic prefs stores only at
  startup, so the plugin atomically updates the player's global prefs and all
  existing per-user prefs before each daemon spawn. Changing the checkbox
  restarts only that player's bridge. Existing installs default to enabled,
  preserving Soloist's previous behavior.

## Track timing and DSTM

Soloist's current item duration and position are mapped into LMS's active Song
object and remote metadata. This gives the logical Spotify track a total time
and accurate progress display even though the underlying `soloist://`
transport remains continuous and non-seekable.

The protocol handler identifies that transport as a repeating stream, and the
plugin implements LMS's DSTM conflict hook. Don't Stop The Music is suppressed
only while a player is using its Soloist stream; switching to another source
restores that player's normal DSTM behavior.

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
[soloist-bridge] direct LMS stream FIFO ready
[soloist-bridge] direct LMS stream ready
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

Soloist control WebSockets bind to loopback. Audio remains local between the
bridge FIFO and LMS; only LMS's normal player-facing connections are exposed.

## License

See the repository license and the notices in `contrib/experimental-pcm-shim/`.
