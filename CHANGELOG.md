# Changelog

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
