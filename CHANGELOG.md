# Changelog

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
