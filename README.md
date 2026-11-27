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
  -> parec S32LE capture
  -> per-player FIFO
  -> soloist:// protocol handler
  -> LMS S16LE/FLAC/MP3 conversion
  -> player
```

### Direct PCM shim

```text
Spotify
  -> Soloist
  -> custom libpulse.so.0
  -> 200 ms bounded live-edge PCM ring
  -> per-player bridge source FIFO (S32LE)
  -> persistent bridge ffmpeg conversion
  -> per-player LMS FIFO (S16LE PCM / 16-bit FLAC / MP3)
  -> soloist:// protocol handler
  -> player
```

The shim writes one continuous S32LE source into a bridge-owned FIFO. A
persistent ffmpeg process converts that source once, before LMS: PCM is
triangular-dithered to S16LE, FLAC is explicitly 16-bit, and MP3 uses the
configured fixed bitrate. The protocol handler therefore exposes a native
final stream and LMS does not launch a second realtime converter. This avoids
the recurring roughly 200 ms LMS transcoder input stalls observed in the field.
The shim's 200 ms live-edge ring and 64 KiB S32LE source FIFO remain bounded.

The handler opens the final FIFO nonblocking in read/write mode. Discontinuous
generation flushes preserve the request/ack protocol. Closing the old handler
terminates the final converter writer, and the supervisor starts a clean
converter for the replacement generation while Soloist and the bridge remain
alive. PCM drains only queued raw samples; FLAC/MP3 preserve the fresh encoder
header instead of treating it as stale data.
For discontinuous PCM changes, LMS reopens a generation-qualified playback URL
such as `soloist://player-0/soloist.wav?g=4`. The canonical per-player URL stays
stable for metadata and settings, while the token forces LMS to replace the
old handler and flush downstream decoder/player buffers. Expected natural
gapless transitions retain the current URL and handler.

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
3. Select **PCM/WAV**, **FLAC**, or **MP3** as the LMS output format.
4. Save and restart the affected bridges.

The bridge sets `LD_LIBRARY_PATH` only for the Soloist process and points
`SOLOIST_SHIM_OUT` at the per-player S32LE source FIFO. The bridge converts to
the selected final format and writes the LMS-facing FIFO. On discontinuous
Spotify URI changes or meaningful backward seeks, the plugin atomically
publishes a flush request to the shim. The bridge observes the shim's internal
acknowledgement and only then plays the new generation-qualified URL. The
handler close/open lifecycle restarts the final converter, discards its buffered
old timeline, and supplies a fresh encoded header where required. The handler
leaves a bounded 120 ms reader-free close window so the old writer reliably
observes EPIPE before LMS reopens the FIFO. This orders source-ring flushing
before downstream handler/player replacement without restarting Soloist or the
bridge. Expected natural end-of-track changes retain both converter and handler
for gapless playback.

Pulse-internal flushes and plugin track-change requests use separate namespaces.
If a request acknowledgement is lost, the plugin retries the same idempotent
request; after timeout it still replaces the LMS handler and keeps the bridge
alive rather than terminating Soloist.

At bridge startup, `bridge.log` must show both:

```text
[soloist-bridge] pcm-shim binary: .../libpulse.so.0 (... bytes sha1=...)
[soloist-shim] loaded build 2026-11-22.1-s32le: mode=live-ring-s32le ...
```

The bridge also logs the exact matching `/proc/<soloist-pid>/maps` entry. It
refuses playback if either the binary build marker or mapped library differs,
so a stale package or system Pulse library cannot first surface as a
generation-acknowledgement timeout on track skip. At normal shim log level `1`,
copy 15-20 seconds containing the
startup lines plus `runtime summary`, `output pressure`, `LMS read summary`,
`stream underflow`, `live-edge drop`, generation, or FIFO reconnect messages.
Bundled private-glibc launches pass the selected shim through the loader's
`--preload` option; native launches use the exact `LD_PRELOAD` path. The shim
is therefore mapped before Soloist chooses its audio backend instead of merely
being available for a later lazy lookup.

Diagnostic level `1` is now the default. Set `SOLOIST_PCM_SHIM_LOG=2` in the
LMS service environment only when trace-level Pulse API calls are needed.

See `contrib/experimental-pcm-shim/README.md` for build details, supported
environment variables, and limitations.

## Stream formats

- **PCM/WAV** - the bridge converts the S32LE source to dithered 44.1 kHz
  stereo S16LE at exactly 1,411,200 bps. The Squeezebox Touch therefore
  receives a supported 16-bit PCM stream, never raw S32LE.
- **FLAC** - lossless bridge conversion from the same S32LE source, explicitly
  bounded to 16-bit for hardware-player compatibility.
- **MP3** - bridge conversion from S32LE at the configured fixed bitrate
  (96, 128, 160, 192, 256, or 320 kbps).

All three paths use the same 200 ms live-edge ring and S32LE source FIFO.
The bridge requires `ffmpeg`; when it is unavailable, startup fails explicitly
instead of sending raw S32LE to LMS or the player.

The global format is the default. Each enabled player can override it
independently from the settings page. Lyrion's Now Playing and track-info
surfaces report the selected output properties. The S32LE source contract is
private to the bridge; the protocol handler, track, and `strm` metadata expose
the actual converted output before data reaches the
player.

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
