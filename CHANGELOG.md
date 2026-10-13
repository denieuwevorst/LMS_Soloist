# Changelog

## Unreleased

- Add `contrib/experimental-pcm-shim/`: an alternative `libpulse.so.0`
  replacement proposed as a possible fix for the ALSA/apulse backend's
  end-of-track stall (it paces playback on a real clock and reports
  position from actual drained bytes, rather than bytes handed to it).
  Confirmed to build cleanly (after fixing 6 const-qualifier mismatches
  vs. the real `libpulse-dev` headers, plus a `sun_path`
  null-termination fix) and to play correct-pitch, correct-length audio
  via a self-contained test client (`test_client.c`, `make test`) that
  doesn't require the real Soloist binary. **Still not wired into the
  plugin or bridge, and still unvalidated against the real Soloist
  binary** -- integrating it would need a new direct-PCM-FIFO capture
  path (a different audio path than the ALSA loopback capture both
  existing backends use). Ships with a `Makefile`, `test_client.c` and
  a `check-symbols.sh` (now dlopen/strings-aware, since Soloist likely
  dlopens libpulse rather than linking it) so it can be evaluated
  independently; see that directory's README for full status and
  required next steps.
- ALSA/apulse backend: add a watchdog that force-skips a track when
  Soloist's own reported playback position freezes (`status` stays
  `"playing"` but `position` stops advancing) instead of letting LMS
  hang on that track indefinitely. This is a mitigation, not a root-cause
  fix: a prior attempt to prevent the freeze by clamping the shim's
  playback buffer (`APULSE_MAX_TLENGTH_MS`, see entry below) was tested
  on real hardware and did **not** stop the freeze from recurring, so
  the true cause inside the closed-source shim/Soloist interaction is
  still unidentified. The watchdog (in `Plugin.pm`, ALSA backend only)
  waits 8 seconds of unchanged position while actively playing, then
  issues the existing `ctl next` command to force a track skip and
  resume playback -- at the cost of losing the tail of the stuck track.
  **Unverified on real hardware as of this commit.**
- ALSA/apulse backend: attempted fix (confirmed **insufficient** by a
  real-hardware retest) for tracks cutting off a few seconds before the
  real end and failing to advance to the next one. Root cause theory:
  bundled shim negotiates a multi-second playback buffer by default
  (observed via its own connect log: `tlength=705600` bytes at
  44.1kHz/16-bit/stereo = exactly 4.0s), and Soloist tracks playback
  *position* by how much audio it has handed to the stream, not by
  what has actually reached the speaker. With that much buffered,
  Soloist's own clock can consider a track "finished" several seconds
  before the real, still-queued audio has drained; when it then
  corks/flushes the stream for the transition, that last stretch of
  real audio is discarded instead of played out. Confirmed via a direct
  A/B: the same track transitioned cleanly on the Pulse/PipeWire
  backend (which correctly drains on cork/flush) but stalled
  indefinitely at the end of the track on the ALSA/apulse backend.
  Mitigation attempted: clamp the shim's buffer via its undocumented
  `APULSE_MAX_TLENGTH_MS` (found via binary string inspection,
  alongside `APULSE_PLAYBACK_DEVICE`/`APULSE_DIAG`/`APULSE_YIELD_PATH`)
  to 300ms by default, matching the ALSA capture side's existing
  `--buffer-time=300000`. Override with
  `SOLOIST_SHIM_MAX_TLENGTH_MS=<ms>` if a different value is needed.
  Left in place (it's a reasonable change regardless, and may still
  help on some hardware), but a real-hardware retest showed the exact
  same freeze pattern recurring afterwards, so it is **not** sufficient
  on its own -- see the watchdog entry above for the current mitigation.
  (This supersedes the "stops after one track" entry below: that fix
  -- gating the shim's diagnostics off by default -- was real and
  worth keeping, but turned out not to be the actual root cause of
  end-of-track stalls.)
- ALSA/apulse backend: confirmed working end-to-end on real hardware
  (DietPi + `snd-aloop` + bundled x86_64 shim) across multiple
  consecutive tracks and automatic track transitions, with continuous
  audible playback, no capture restarts, and no shim/ALSA errors. This
  closes out the "stops after one track" symptom reported against an
  earlier commit in this series -- it was caused by the shim's
  `APULSE_DIAG` debug logging (see below) being left enabled
  unconditionally, and was resolved simply by gating that logging back
  behind the `SOLOIST_SHIM_DIAG=1` opt-in (default off).
- ALSA/apulse backend: fix the real silent-playback bug with the bundled
  x86_64 shim. The shim's own `APULSE_DIAG` debug log (temporarily
  enabled while investigating, see below) pinpointed the exact failure:
  `pcm open hw:1,0,0 failed: No such file or directory` -- Soloist
  genuinely produced real audio and the shim buffered it correctly
  (confirmed via its own write-queue log growing across repeated
  writes), but opening the raw `hw:` ALSA device for **playback** failed
  outright on this host, even though the very same loopback card's
  paired **capture** device opened fine via `plughw:`. Fix: when the
  bundled shim is active, upgrade its playback device from `hw:...` to
  `plughw:...` before launching Soloist, mirroring the upgrade already
  applied on the capture side. Confirmed fixed: audio now reaches real
  hardware and is audible.
  (An earlier commit in this series incorrectly assumed the shim
  hardcoded its output to a PCM literally named `volumio`
  (`plug:volumio`) and ignored `APULSE_PLAYBACK_DEVICE` entirely, and
  added a `~/.asoundrc` alias to work around that. Binary string
  analysis of the shim showed it does read `APULSE_PLAYBACK_DEVICE`
  directly; that workaround was dead code and has been removed.)
- ALSA/apulse backend: the shim also exposes two built-in debug hooks
  used to diagnose the above (`APULSE_DIAG` for verbose per-call
  logging, `APULSE_YIELD_PATH` for a raw-PCM dump of what Soloist
  actually sends it) -- gated behind `SOLOIST_SHIM_DIAG=1` (off by
  default). Per-call logging runs on the shim's real-time audio thread,
  so leaving it on by default risked introducing its own audible
  glitches/dropouts on constrained hardware.
- ALSA/apulse backend: stop `export`ing the bundled Soloist pulse shim's
  `LD_LIBRARY_PATH` globally. It was only meant to affect Soloist's own
  playback process, but a global `export` leaked it into every later
  command in the script too -- including the `arecord` capture process,
  which has nothing to do with Pulse at all. With the shim directory
  ahead of the system path, the dynamic linker resolved the shim's
  bundled (stub) `libpulse.so.0` instead of the real system one whenever
  ALSA's config layer tried to dlopen its own "pulse" conf-hook plugin,
  which needs the *real* libpulse symbols (e.g. `pa_mainloop_new`) --
  breaking with "undefined symbol" and cascading into "Unknown PCM
  <device>" for `arecord`, which is what actually caused audio capture to
  fail every single time on the ALSA backend. Scope the shim's
  `LD_LIBRARY_PATH` to just the Soloist invocation instead.
- Fix a bug where the bridge's own stderr got permanently redirected to
  `/dev/null` the first time the relay-readiness probe succeeded, because
  its fd-3 cleanup used a bare `exec ... 2>/dev/null` (which changes the
  current shell's fds for good, not just for that statement) instead of a
  scoped `{ ... } 2>/dev/null` group. This silently swallowed every
  bridge log line from that point on -- including every capture-start and
  capture-exit-status line -- and, worse, the real stderr output from
  every `arecord`/`ffmpeg` capture child launched afterwards, very likely
  hiding the actual no-sound root cause behind a misleadingly "quiet" log.
- Stop piping the bridge's own log output through `tee`. GNU `tee` fully
  buffers its writes whenever its stdout isn't a TTY (always true here),
  which can delay recently-logged lines -- including ones on a working,
  always-executed code path -- from ever reaching `bridge.log` while the
  process is still running normally. Write directly to the log file
  instead (`exec >> "$LOG_FILE" 2>&1`), with no buffering process in the
  middle, so every log line lands immediately.
- ALSA/apulse backend: stop sharing one device string between playback and
  capture. The bridge now keeps Soloist playback on the raw loopback
  playback side while preferring the plug-converted loopback capture side,
  which matches hosts where the loopback monitor only exposes FLOAT_LE on
  the raw capture node.
- ALSA/apulse backend: when the backend uses ffmpeg for FLAC/MP3 output,
  capture from ALSA with `arecord` first and feed raw PCM into ffmpeg via
  stdin instead of relying on ffmpeg to open the ALSA device directly.
  This avoids host-specific ffmpeg/ALSA device parsing failures while
  keeping the existing encoding/relay path intact.
- ALSA/apulse backend: resolve the configured loopback card *name* (e.g.
  `Loopback`) to its numeric ALSA card index before launching Soloist or
  `arecord`. When two or more cards share the same name -- which happens
  if `snd-aloop` was loaded more than once without unique `id=` values --
  ALSA's name-based lookup is ambiguous and can fail to open the device
  with no audible error (`Cannot get card index for Loopback`), which
  looked like "Soloist plays but there's no sound". The bridge now logs a
  `WARNING` naming every matching card index in that case and picks the
  first one so playback still works instead of failing open. If no card
  matches the configured name at all, it falls back to a case-insensitive
  substring match and logs every ALSA card id it actually sees in
  `/proc/asound/cards`, so the real card names are visible in `bridge.log`
  without needing a separate shell session.
- Run the ALSA/apulse capture supervisor loop in the foreground (it already
  polls Soloist's own liveness internally) instead of backgrounding it
  behind a duplicate supervisory loop, and log the exact capture command
  plus its exit status on every restart, to make capture-pipeline failures
  visible in `bridge.log` instead of silent.
- Add `Bin/setup-alsa-prereqs.sh`, a companion to the existing
  Pulse-backend helper script, that installs the ALSA/apulse backend's
  Debian packages and -- the actual root cause found while debugging a
  real "no sound" report -- loads `snd-aloop` and persists both the
  module load and its substream count across reboots, since a plain
  `modprobe snd-aloop` only lasts until the next reboot and its absence
  is otherwise silent (Soloist "plays" normally with no audible output).

## 0.3.49

- Stop using the Soloist executable file timestamp to estimate expiry age.
  The plugin now parses the build timestamp reported by `soloist --version`,
  which matches Spotify's documented 90-day expiry rule even when the file
  mtime is pinned to an old fixed date.
- Remove the per-player stream-format override again for now and go back to
  one global stream-format choice for all selected players.
- Prune dead bridge processes from the in-memory bridge table so the
  settings page no longer keeps showing `running` after a bridge has
  already stopped.
- Special-case PCM/WAV transport so it no longer goes through ffmpeg:
  the bridge now captures raw PCM directly (`parec` on Pulse/PipeWire,
  `arecord` on ALSA) and the embedded relay adds the streaming WAV header.
- Bundle the Soloist Pulse shim for **x86_64** and load it automatically on
  the ALSA backend, so that architecture no longer needs a separate
  apulse-style wrapper just to map Soloist into ALSA loopback.
- Move the PCM/WAV headroom to the capture side as a real **300 ms input
  buffer** instead of delaying relay output, so short capture stalls are
  absorbed without making LMS see a dry HTTP stream.
- On the PCM/WAV path, flush queued relay audio at track changes so it is
  easier to see whether delay growth is coming from relay backlog versus
  upstream capture stalling.

## 0.3.48

- Add an opt-in **ALSA/apulse** backend so the plugin no longer requires a
  host PulseAudio/PipeWire stack just to be usable in LMS. The default
  backend remains the existing per-player Pulse/PipeWire null-sink bridge;
  the new backend is explicitly for wrapper/loopback setups where Soloist
  is launched under an apulse-style shim and ffmpeg captures from
  per-player ALSA loopback devices.
- Gate Soloist autoplay on actual relay byte flow, with a short fallback
  timeout, so the first song is less likely to start before ffmpeg and the
  embedded relay are really producing stream data.

## 0.3.47

- If LMS autostart runs before all previously selected players have fully
  registered after a reboot, keep retrying those missing-player bridge
  starts instead of logging "no such player" once and giving up.
- If a selected player goes offline after its Soloist bridge already
  started, stop that bridge after a short grace period and keep retrying
  until the player comes back.

## 0.3.46

- Reapply the configured Initial Soloist volume whenever a Soloist Connect
  session becomes active again, not only when its bridge first starts. That
  keeps reconnects from inheriting an old Spotify-side session volume.
- If a player leaves its own Soloist stream for another Lyrion source,
  disconnect and restart that Soloist bridge immediately so Spotify does
  not continue playing in the background on a no-longer-selected source.

## 0.3.45

- Stop forcing the long-running PulseAudio monitor capture onto system
  wallclock timing in ffmpeg. The bridge now keeps generated timestamps
  anchored to PulseAudio's own source clock instead of combining
  wallclock retimestamping with continuous async resampling, which was a
  plausible cause of playback gradually drifting further behind
  Spotify's own app timeline during very long sessions.

## 0.3.44

- Stop asking Soloist for a fresh `now --json` snapshot twice a second.
  The plugin now consumes each bridge's pushed `soloist ctl trace` event
  stream as the primary state source, with an occasional snapshot resync
  fallback so state can recover cleanly after observer reconnects or a
  missed event.
- Replace fixed bridge-script sleeps with readiness checks: wait for
  Soloist's `ws.port` file instead of always sleeping 2 seconds after
  launch, verify the relay by a real local TCP connect instead of a
  blind 1-second sleep, and tighten sink-routing checks from 2 seconds
  to 0.3 seconds so real audio reaches the correct monitored sink
  sooner on plain PulseAudio hosts.

## 0.3.43

- Stop tracking packaged `SpotifySoloist-*.zip` artifacts in the Git
  tree. The plugin repository feed now points at a GitHub release asset
  instead, which keeps future checkouts smaller and avoids growing the
  working tree with one committed ZIP per release.

## 0.3.42

- Refactor format handling behind one shared format table so the relay URL
  extension, displayed format label, and startup prebuffer all come from
  the same definition instead of separate `mp3`/`flac`/`pcm` branches.
- Split the metadata poll loop into explicit helpers for playback-state
  derivation, transition handling, idle-disconnect evaluation, and
  metadata publication.
- Unify bridge start/stop/restart/reconcile behind a single desired-state
  flow, while preserving the current per-player bridge behavior.

## 0.3.41

- Add a short same-device playback-transition grace window before
  stopping/clearing a Soloist stream. This avoids brief track-boundary
  status blips from looking like a full disconnect/reconnect when the
  same Soloist device is still active, while still stopping immediately
  on a real active-device handoff.

## 0.3.40

- Label the low-latency PCM relay as `WAV` in published metadata so the
  browser/UI shows the actual stream container users see on the wire.
- Clarify in the README that finite per-track duration is intentionally
  not published for the continuous Soloist relay stream, because doing so
  made Lyrion stop playback at track boundaries.

## 0.3.39

- Add a safer Soloist build-expiry warning path instead of any automatic
  binary downloader/updater. The plugin now checks the configured
  `soloistBin` file's age, warns in the settings page and LMS log once it
  is about 80 days old, and points users to Spotify's official
  "Downloads and updates" page so they can replace the binary manually
  before Soloist's own roughly 90-day build expiry is reached.

## 0.3.38

- Stop wiping the Soloist cache tree automatically on LMS/plugin boot
  and on every per-player bridge start/restart. That cache wipe was
  originally added to suppress stale-player state, but stale metadata
  display is now handled via Soloist's `is_active` flag instead. Keeping
  the cache avoids tearing down bridge-local files after an ungraceful
  LMS shutdown and improves recovery when LMS restarts while a player is
  already actively playing through Soloist.

## 0.3.37

- Reduce the Soloist startup prebuffer again, per request, to about
  **200 ms for all formats**. `ProtocolHandler.pm` now asks LMS for
  roughly 200 ms of MP3 data from the configured bitrate (bounded to
  3..35 KB), `24 KB` for FLAC, and `35 KB` for PCM/WAV. This keeps the
  same protocol-level buffering hook while minimizing added startup
  delay as much as practical.

## 0.3.36

- Reduce the new Soloist startup prebuffer added in 0.3.35. The first
  pass proved too large in practice. `ProtocolHandler.pm` now asks LMS
  for a much smaller format-aware startup cushion: MP3 targets roughly
  750 ms from the configured bitrate (bounded to 24..128 KB), FLAC uses
  96 KB, and PCM/WAV uses 128 KB. This keeps some underrun protection
  while pulling startup latency back down substantially.

## 0.3.35

- Add a format-aware `bufferThreshold` to `ProtocolHandler.pm` so
  Lyrion prebuffers more of the Soloist stream before starting playback:
  MP3 now buffers roughly 2 seconds based on the configured bitrate
  (bounded to 32..255 KB), FLAC uses 192 KB, and PCM/WAV uses the LMS
  maximum of 255 KB. This doesn't create true per-song buffering — the
  Soloist bridge is one continuous live stream — but it gives the player
  a larger startup cushion, which can help mask brief starvation around
  track transitions.

## 0.3.34

- Add `Bin/setup-debian-prereqs.sh`, an idempotent Debian helper that
  installs the packages this plugin needs for its current
  Pulse/PipeWire-compatible bridge design, detects the Lyrion runtime
  user, starts a simple system-mode PulseAudio service only when no
  Pulse-compatible server is already reachable, grants the Lyrion user
  `pulse-access` (and `audio` if present), and restarts Lyrion so the
  new permissions take effect. Update the README to prefer that helper
  over the long manual headless-PulseAudio setup steps.

## 0.3.33

- Use Soloist's `is_active` flag together with `status` when deciding
  whether a per-player Soloist instance is truly playing here. `status`
  alone reflects the Spotify account's current session, so every running
  instance on the same account can report `playing` at once even when
  only one device is actually outputting audio. The metadata/autotune
  poller now treats a player as active only when `status` is `playing`
  **and** that specific instance reports `is_active`, which stops stale
  cover art / Now Playing state from being pushed to players that are no
  longer the real output device, while avoiding the playback regressions
  from the reverted 0.3.28-0.3.32 force-disconnect attempts.

## 0.3.32

- Revert the entire "force-disconnect the losing player on device
  handoff" feature added in 0.3.28 (and its follow-up attempts in
  0.3.29-0.3.31). Each attempt at a safe eviction mechanism regressed
  actual playback in a new way: 0.3.28 caused a stop/restart ping-pong
  between players, 0.3.29's fix caused a newly selected player to
  connect but never start playing, and 0.3.30/0.3.31's follow-ups still
  ended with a player connecting and showing progress but producing no
  sound. Rather than attempt yet another variant blind (this environment
  can't run or reproduce the actual Spotify Connect/audio pipeline),
  `Plugin.pm`, `Bin/soloist-bridge.sh`, and `README.md` are reverted to
  their last confirmed-working state from 0.3.27: playback works, only
  the (cosmetic) stale-coverart/still-playing-when-not-active-anymore
  behavior on a previously selected player returns until a better,
  properly-tested fix is available.

## 0.3.31

- Diagnostics only, no behavior change: `soloist-bridge.sh`'s
  `sink_router` (which routes Soloist's own PulseAudio playback stream
  into the per-player null-sink ffmpeg captures) previously looped
  silently forever if it never found that stream. If Soloist's audio
  never reaches the sink, ffmpeg only ever captures the sink's warm-up
  silence, producing exactly "connects, progress moves in the Spotify
  app, but no sound" -- with nothing in the log to point at why. Added:
  a one-time confirmation log line once the stream is found (whether it
  needed moving or was already on the right sink), and a clear warning
  after ~30s if it's never found at all while a player is presumably
  active, so this failure mode is immediately diagnosable from
  bridge.log next time it happens.

## 0.3.30

- Fix a "connects but doesn't play" regression from 0.3.29: releasing the
  previous player ran a blocking external `soloist ctl ... pause` call
  *before* starting playback on the player that just took over the
  Spotify Connect session. A slow or unresponsive `ctl` call could stall
  that poll cycle, so the new player would show as connected on
  Spotify's side but never actually start playing in Lyrion. Playback on
  the new player now starts immediately/unconditionally, and releasing
  the previous player is deferred to its own timer tick so it can never
  block or delay it.

## 0.3.29

- Fix a device-handoff regression from 0.3.28: forcibly killing and
  immediately restarting the losing player's bridge could have its fresh
  Soloist instance briefly re-report a 'playing' status, which looked
  like a new device switch and evicted the player that had just taken
  over -- an endless back-and-forth ("connects, then goes down again").
  The losing player is now released via its own Soloist `ctl pause`
  command instead of a process kill, with a short cooldown guarding
  against that same stale-status race, while the existing idle-disconnect
  timer still performs the full stop + cache wipe + restart afterward.

## 0.3.28

- When Spotify Connect hands the single active session to a DIFFERENT
  player, the player that lost it is now fully disconnected -- Lyrion
  playback stopped, cached metadata cleared, its bridge/Soloist process
  killed, its cache wiped, and restarted fresh -- instead of only being
  told to stop its Lyrion playlist while its underlying Soloist session
  stayed alive. It comes back exactly like a newly selected player.

## 0.3.27

- Treat any Soloist status other than `playing` (not just the literal
  `paused` value) as "this player must stop": when Spotify Connect hands
  playback to a different device, the losing player's status may not be
  reported as `paused`, so it previously never got told to stop and kept
  showing/playing its stale stream.

## 0.3.26

- Clear a player's cache directory every time its Soloist bridge starts,
  including idle-restarts, not just once at server boot -- so a lingering
  Spotify Connect device identity or cached state can't keep causing a
  restarted instance to report status for whichever player was previously
  selected on that slot.

## 0.3.25

- Only push Now Playing metadata to a player while it is actually playing its
  own Soloist stream; a player that is merely parked on the stream URL while
  paused or stopped no longer keeps stale metadata.
- Clear each plugin's on-disk cache directory (bridge logs, FIFOs, and
  Soloist's own cache) at server boot, leaving persisted Soloist login/session
  data untouched.

## 0.3.24

- Clear cached Spotify metadata as soon as a player is switched away from its
  Soloist stream, without deleting its persisted Soloist account data.

## 0.3.23

- Use the `.wav` URL extension for PCM/WAV streams so Lyrion selects the WAV
  decoder that matches the relay's `audio/wav` content type.

## 0.3.22

- Add a PCM/WAV stream format for players that support uncompressed WAV. It
  avoids FLAC encoder latency by relaying 44.1 kHz stereo signed 16-bit PCM,
  at approximately 1.4 Mbit/s.

## 0.3.21

- Add an Initial Soloist volume setting (0-100%, default 100%) applied once
  when a bridge starts; later Lyrion volume adjustments remain local.

## 0.3.20

- Set each newly started Soloist Connect session to 100% volume once, while
  continuing to keep all later Lyrion volume adjustments local.

## 0.3.19

- Reduce FLAC-only startup latency by using FFmpeg's fastest FLAC compression
  level and flushing each encoded packet to the live relay immediately.

## 0.3.18

- Package all plugin text files with LF line endings. Previous Windows-built
  archives used CRLF, which prevents the Bash bridge from starting on Linux.

## 0.3.17

- Restore the complete known-working 0.3.14 audio pipeline after the
  low-latency PulseAudio and FFmpeg options in 0.3.15 prevented Soloist
  from becoming available on some systems.

## 0.3.16

- Restore Soloist's established two-second startup readiness window and
  PulseAudio routing cadence, avoiding aggressive startup-time audio-server
  polling that could prevent the Connect device from becoming available.

## 0.3.15

- Attempted a low-latency audio-pipeline tuning. This was reverted in 0.3.17
  because the added PulseAudio and FFmpeg options are not compatible with all
  supported systems.

## 0.3.14

- Keep volume control local to Lyrion instead of forwarding it to Soloist.

## 0.3.13

- Publish configured stream format and MP3 bitrate in Lyrion metadata.

## 0.3.12

- Send native FLAC rather than Ogg-FLAC for the FLAC stream option, avoiding
  Ogg container decoder incompatibilities.

## 0.3.11

- Intercept matching Lyrion transport commands before the native live-stream
  handler runs, preventing control actions from resetting the relay stream.

## 0.3.10

- Forward Lyrion player-button events to Soloist, including next and
  previous, and log forwarded or ignored control events at debug level.

## 0.3.9

- Forward Lyrion play, pause, stop, and volume controls to the matching
  Soloist session while that player is using its Soloist stream.

## 0.3.8

- Schedule the paused-idle bridge restart with a closure that retains the
  selected player ID, and log restart scheduling and execution.

## 0.3.7

- Store helper and template paths in the release ZIP with forward slashes
  so Lyrion extracts `Bin/` and `HTML/` directories on Linux.

## 0.3.6

- Sanitize persisted player-slot values before using them in cache paths,
  preventing malformed values from creating directories with CR characters.

## 0.3.5

- Launch the Bash-based bridge script through `/bin/bash` rather than
  `/bin/sh`, which is Dash on Debian and exits before bridge logging.

## 0.3.4

- Resolve the bridge script relative to the loaded plugin module so the
  installed package is used reliably, and log a clear error if it is absent.

## 0.3.3

- Start bridge scripts through `/bin/sh` so downloaded plugin archives do
  not depend on executable permission bits.
- Normalize localization strings to UTF-8 without a BOM and LF line endings
  so Lyrion can parse each plugin string.

## 0.3.2

- Reduced auto-tune detection latency by polling playback state every
  500 ms.
- Stop and clear Lyrion's Soloist stream when Spotify playback pauses.
- Restart paused-idle Soloist bridges after clearing cached metadata, so
  the Connect device remains available without retaining stale artwork.
- Do not publish a finite track duration for the continuous relay stream,
  preventing Lyrion from stopping it at a song-duration boundary.

## 0.3.0

- **Per-player architecture**: one independent Soloist instance per
  selected Squeezebox player, each its own Spotify Connect device name,
  instead of one shared source any player could tune into. Settings page
  now lists players with checkboxes; toggling one starts/stops just that
  instance immediately.
- Auto-tune: the corresponding player starts playing automatically when
  Spotify actually starts sending audio to that instance.
- Replaced Icecast with a small embedded Python HTTP relay
  (`Bin/audio-relay.py`), fed by ffmpeg through a named pipe so ffmpeg
  restarts don't disturb already-connected listeners or require a
  separate service to install.
- Fixed a concurrency bug: routing Soloist's PulseAudio stream to the
  right sink now runs as a continuous background watcher per instance,
  matching by process ID via `pactl list sink-inputs`, instead of a
  racy "set the global default sink" approach that only worked safely
  for a single instance.
- Fixed a startup crash (`Can't locate object method "OPEN" via package
  "Slim::Utils::Log::Trapper"`) caused by reopening Lyrion's tied
  STDERR directly in a forked child; now uses `POSIX::dup2` to redirect
  at the file-descriptor level instead.
- Fixed PulseAudio cookie-authentication failures
  (`Failed to create secure directory .../.config/pulse`) by giving each
  instance its own writable `HOME`, instead of inheriting the Lyrion
  service account's often-unwritable one.
- Fixed a URL/content-type mismatch where `flac` format streams were
  served as Ogg-contained audio at a URL claiming `.flac`.
- Added per-instance log files (`bridge.log`) for actual visibility into
  what Soloist/ffmpeg/the relay are doing, instead of output vanishing
  into wherever Lyrion's own process output happens to go.
- Documented that classic fixed-firmware Squeezebox hardware
  (Boom/Classic/Receiver) cannot decode the Ogg container the `flac`
  option uses — `mp3` is required for that class of player.

## 0.2.0

- Registered a custom `soloist://` URL scheme with a dedicated protocol
  handler (`ProtocolHandler.pm`), modeled on ShairTunes2's `AIRPLAY.pm`,
  to get real Now Playing metadata — including cover art — into Lyrion.
  A plain `http://` Favorite URL only ever gets generic ICY text
  metadata at best.
- Metadata now comes directly from polling Soloist's own
  `ctl ... now --json` and writing into
  `$client->master->pluginData('metadata')`, rather than an intermediate
  JSON state file and ICY-tag injection into the stream.

## 0.1.0

- Initial version: Lyrion plugin wrapping Spotify Soloist as a single,
  shared Spotify Connect source, bridged to Lyrion via Icecast, with a
  JSON-state-file/ICY-metadata approach for track titles.
