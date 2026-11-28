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
  -> parec S16LE
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
  -> 200 ms paced PCM ring with lossless in-flight retry
  -> direct final FIFO (PCM), or
     bounded source pump -> persistent bridge ffmpeg (FLAC/MP3)
  -> per-player final-format LMS FIFO
  -> soloist:// protocol handler
  -> player
```

PCM writes directly to the bridge-lifetime guarded LMS FIFO and never uses an
encoder. Once the shim accepts a PCM chunk, its writer retries ordinary FIFO
pressure until the reader resumes; only an explicit discontinuous generation
can invalidate that in-flight audio. For FLAC and MP3, an independent bounded
PCM pump continuously drains the Soloist-facing source into one persistent
bridge-side ffmpeg encoder. LMS therefore reads final FLAC/MP3 bytes instead of
asynchronously attaching its own transcoder to the realtime PCM source.

The handler opens the FIFO nonblocking in read/write mode. Keeping one local
writer open prevents a temporary capture-process exit from appearing as EOF to
LMS; the bridge can restart capture and continue through the same stream.
For discontinuous PCM changes, LMS reopens a generation-qualified playback URL
such as `soloist://player-0/soloist.wav?g=4`. The canonical per-player URL stays
stable for metadata and settings, while the token forces LMS to replace the
old handler and flush downstream decoder/player buffers. Expected natural
gapless transitions retain the current URL and handler.

## Requirements

Common requirements:

- Lyrion Music Server 8.0 or newer
- Spotify Soloist and a valid Soloist API key
- `ffmpeg` in the LMS service account's `PATH` for FLAC or MP3 output

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
- **Discontinuous track restart buffer** (default 750 ms, range 0-3000 ms)

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
3. Select **PCM/WAV** for native WAV delivery, or MP3/FLAC for persistent
   bridge-side encoding from the same S16LE source.
4. Save and restart the affected bridges.

The bridge sets `LD_LIBRARY_PATH` only for the Soloist process. PCM points
`SOLOIST_SHIM_OUT` directly at the per-player final FIFO. FLAC/MP3 point it at
a source FIFO drained by the bounded pump into one persistent bridge encoder.
On discontinuous Spotify URI changes or meaningful backward seeks, the plugin
atomically publishes a
flush request to the shim, waits up to one second for its request
acknowledgement, restarts only the compressed encoder for a fresh stream header,
and then plays a new generation-qualified URL so LMS replaces the handler.
Expected natural end-of-track changes preserve the encoder and handler.

Pulse-internal flushes and plugin track-change requests use separate namespaces.
If a request acknowledgement is lost, the plugin retries the same idempotent
request; after timeout it still replaces the LMS handler and keeps the bridge
alive rather than terminating Soloist.

At bridge startup, `bridge.log` must show both:

```text
[soloist-bridge] pcm-shim binary: .../libpulse.so.0 (... bytes sha1=...)
[soloist-shim] loaded build 2026-11-28.2-lossless: mode=live-ring ...
```

The bridge also logs the exact matching `/proc/<soloist-pid>/maps` entry. It
refuses playback if either the binary build marker or mapped library differs,
so a stale package or system Pulse library cannot first surface as a
generation-acknowledgement timeout on track skip. At normal shim log level `1`,
copy 15-20 seconds containing the
startup lines plus `runtime summary`, `output pressure`, `LMS read summary`,
`stream underflow`, `live-edge drop`, generation, or FIFO reconnect messages.
Compare the same Spotify passage first with the checkbox enabled and then
disabled for that player.

Bundled private-glibc launches pass the selected shim through the loader's
`--preload` option; native launches use the exact `LD_PRELOAD` path. The shim
is therefore mapped before Soloist chooses its audio backend instead of merely
being available for a later lazy lookup.

Diagnostic level `1` is now the default. Set `SOLOIST_PCM_SHIM_LOG=2` in the
LMS service environment only when trace-level Pulse API calls are needed.

See `contrib/experimental-pcm-shim/README.md` for build details, supported
environment variables, and limitations.

### Measuring startup delay

Enable **Trace playback startup delay** in the plugin settings and save. This
restarts enabled bridges once so the shim and LMS-side trace use the same
switch. The trace writes one `[delay-trace]` line per milestone and generation;
it never logs PCM payloads. Bridge/shim milestones are written to the player's
`bridge.log`; plugin/protocol/player milestones are written to the LMS
`server.log` and remain visible at the default plugin log level while the switch
is enabled.

Run one controlled test:

1. Start with Spotify paused or idle and the player stopped.
2. Press Play on one track and note the wall-clock second when sound becomes
   audible.
3. Let it play for 10 seconds, then stop.
4. Copy the log lines from `milestone=spotify-playing` through
   `milestone=player-first-status`, plus the audible wall-clock time.

For one player slot, the minimal read-only capture is:

```sh
grep '\[delay-trace\].*canonical=soloist://player-0/' /var/log/squeezeboxserver/server.log
grep '\[delay-trace\]' /var/lib/squeezeboxserver/cache/plugin-spotifysoloist/cache/player_0/bridge.log
```

Replace `player-0` with the configured slot. LMS-side lines also include
`trace_client_id=<player MAC>` so simultaneous players can be separated.

All automated milestones use monotonic seconds and include the stream
generation and canonical `soloist://` URL. Interpret adjacent intervals as:

- `spotify-playing` to `shim-first-pcm-write`: Soloist/source startup.
- `shim-first-pcm-write` to `protocol-first-pcm-read`: FIFO and LMS source
  reader startup.
- `protocol-first-pcm-read` to `lms-strm-requested`: LMS source handoff.
  For FLAC/MP3, `protocol-handler-open conversion=bridge-encoder` identifies
  final encoded bytes from the persistent bridge process.
- `lms-strm-requested` to `player-first-status`: the first playing status after
  the exact requested generation's protocol handler has opened. Status from the
  outgoing handler is ignored, so replacement traces cannot reuse stale elapsed
  time.
- `player-first-status` to the noted audible time: device-side output latency.
- `transition-timing`: one derived summary for the generation. It reports the
  track-to-flush, flush-to-STRM, STRM-to-close, close-to-open, open-to-WAV,
  open-to-PCM, PCM-to-status, and total gaps that are observable through LMS,
  and classifies the largest interval as `pre_flush`, `handler_reopen`,
  `pcm_availability`, or `player_buffer`. The plugin API cannot observe the
  lower-level socket `strm` packet or hardware DAC directly.

Disable the switch after the test and save to return to normal logging.

Soloist marks its host-local stream as remote only for LMS's STRM threshold
selection: LMS ignores protocol-handler thresholds for local streams and would
otherwise request the Touch's full input-buffer prefill. The explicit
`input_buffer_kb` trace field is approximately 200 ms for normal initial
playback. Generation-qualified URLs used by manual/discontinuous changes use
the configurable restart duration instead; `0` preserves the normal threshold.
PCM is calculated from its exact sample layout, MP3 from the selected bitrate,
and variable-rate FLAC from the uncompressed S16 rate as a conservative upper
estimate. LMS's STRM protocol caps the result at 255 KiB. This does not enable
internet-stream buffering in the bridge or audio source, and natural
transitions keep their current handler.

## Stream formats

- **PCM/WAV** - raw 44.1 kHz, stereo, 16-bit PCM at exactly 1,411,200 bps;
  no ffmpeg or compressed pump in this path.
- **FLAC** - 44.1 kHz, stereo, 16-bit lossless audio encoded by the persistent
  bridge ffmpeg process at compression level 0.
  Its live compressed bitrate varies with the audio, so LMS shows
  it as a variable live stream rather than reporting a fabricated fixed value.
- **MP3** - 44.1 kHz stereo audio encoded by the persistent bridge process at the
  configured constant bitrate.

The global format is the default. Each enabled player can override it
independently from the settings page. Lyrion's Now Playing and track-info
surfaces report the selected final output properties, not Spotify's upstream
download quality. If bridge ffmpeg is unavailable, compressed playback fails
explicitly; PCM remains converter-free.

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
