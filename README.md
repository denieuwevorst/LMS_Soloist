# lms-spotify-soloist

Run [Spotify Soloist](https://developer.spotify.com/documentation/soloist)
as a Spotify Connect target for your [Lyrion Music Server](https://lyrion.org/)
(formerly Logitech Media Server) players — one independent Connect device
per selected Squeezebox player, real Now Playing metadata including cover
art, no Icecast or other separate streaming server required.

Pick "Kitchen (Soloist)" in the Spotify app's device picker, and your
Kitchen Squeezebox starts playing automatically — artist, title, album,
and artwork show up in Lyrion's Now Playing just like a local library
track.

## How it works

Lyrion has no native Spotify Connect support and no way to display
artwork for an arbitrary internet stream. This plugin closes both gaps
using the same technique as the third-party
[ShairTunes2](https://github.com/philippe44/lms-shairtunes2w) AirPlay
bridge: a custom URL scheme (`soloist://`) routed through a dedicated
protocol handler, which lets Lyrion call plugin code for metadata lookups
instead of falling back to generic ICY text parsing.

```
For EACH selected player (its own stable "slot", persisted across restarts):

  Spotify app ──(Connect: "<Player Name> (Soloist)")──▶ soloist
                                                            │
                                             its own PipeWire/PulseAudio
                                             null-sink
                                                            │
                        Bin/soloist-bridge.sh: ffmpeg captures that sink's
                        monitor continuously, writes into its own named
                        pipe (FIFO)
                                                            │
                        Bin/audio-relay.py: small persistent multi-client
                        HTTP server, reads that FIFO, broadcasts to any
                        connected listeners — no Icecast needed
                                                            │
                                                            ▼
                        <player> plays soloist://<host>:<port>/soloist.mp3
                        (NOT plain http://)
                                                            │
              ProtocolHandler.pm rewrites soloist:// → http:// for the
              actual audio fetch, but Lyrion still asks IT for metadata

  Plugin.pm keeps one local state loop per instance, consumes Soloist's
  pushed `soloist ctl trace` events as the primary source of truth, and
  does only an occasional `now --json` snapshot resync as a fallback:
  writes title/artist/album/cover into that player's Lyrion metadata,
  and — the moment Spotify actually starts playing — auto-starts playback
  on that same player.
```

## Features

- One Spotify Connect device per selected Squeezebox player, shown
  separately in the Spotify app.
- Autostart: if LMS starts before all previously selected network players
  have fully re-registered after a reboot, the plugin keeps retrying those
  delayed bridge starts instead of giving up after one early "no such
  player" race.
- Offline players: if a selected player disappears from LMS after its
  bridge is already running, the plugin gives that outage a short grace
  period, then stops the Soloist bridge and keeps retrying until the
  player registers again.
- Auto-tune: the corresponding Lyrion player starts playing automatically
  the moment Spotify actually starts sending audio, then stops and clears
  the Soloist stream when playback is paused in Spotify — no manual "select
  the stream from Radios" step.
- Lyrion controls: while a player is on its own Soloist stream, its play,
  pause, stop, next, and previous controls are forwarded to that Spotify
  Connect session. **Initial Soloist volume** sets the new session's level
  (100% by default), and the plugin reapplies that configured level each
  time the Soloist Connect session becomes active again. Volume thereafter
  remains controlled locally by Lyrion.
  Controls for other Lyrion sources are not forwarded.
- Switching that Squeezebox player to another Lyrion source (radio, local
  files, etc.) immediately disconnects its Soloist session and restarts the
  bridge cleanly, so Spotify does not keep playing in the background.
- Idle disconnect: after 30 seconds paused by default, Soloist disconnects
  from Spotify and clears its cached artwork before restarting the selected
  player's Connect device. Set **Disconnect after pause** to `0` to keep it
  continuously connected. The plugin now preserves each player's
  `--cache-dir` across LMS and bridge restarts instead of wiping it on
  boot/startup, because stale-player display is now handled from
  Soloist's reported active-device state and preserving the cache lets a
  currently playing device recover more cleanly after an LMS restart.
- Spotify metadata is shown only while that player is actively playing its
  own Soloist stream **and** its own Soloist instance reports that it is
  the active Spotify Connect device (`is_active`), not merely because the
  shared Spotify account session reports a `playing` status somewhere
  else. Switching to another source, pausing/stopping, or losing the
  active device handoff clears the plugin's cached title and artwork
  without removing the Soloist account session.
- Real Now Playing metadata: title, artist, album, and cover art, via
  Lyrion's native remote-metadata mechanism (not just an ICY text title).
- Stream details: Lyrion metadata includes the configured format and, for
  MP3, bitrate. The source type is displayed as, for example, `Spotify
  Soloist (MP3 320k)`, `Spotify Soloist (FLAC)`, or `Spotify Soloist
  (WAV)` when the low-latency PCM/WAV relay mode is selected.
- Soloist streams now ask Lyrion for a slightly larger **startup**
  prebuffer than a generic remote stream, scaled by format/bitrate. This
  helps absorb brief starvation around track changes without changing the
  bridge's continuous-stream design. Because Lyrion sees this as one
  long live stream, not separate per-song files, this buffer is applied
  when the Soloist stream starts — not individually at every song
  boundary inside it. The current targets are intentionally very small:
  roughly **200 ms for MP3** (from the configured bitrate), about
  **200 ms for PCM/WAV** (`35 KB` at 44.1 kHz stereo 16-bit PCM), and
  roughly **200 ms for FLAC** (`24 KB`) depending on the encoded
  bitrate.
- No Icecast, no extra system service — a small embedded Python relay
  handles multiple simultaneous listeners per player.
- Works with both real PipeWire and plain PulseAudio-only hosts.

## Prerequisites

- **Lyrion Music Server** (or Logitech Media Server) already installed
  and running. Tested against a Debian `.deb` install; should work
  anywhere Lyrion runs as a systemd service on Linux.
- **A Spotify Soloist binary and API key.** Generate a key from the
  [Spotify for Developers dashboard](https://developer.spotify.com/dashboard/soloist)
  (Premium account required) and download a build for your architecture
  from Soloist's own distribution page. Keep the key private — it's tied
  to your account. Soloist builds expire after about 90 days; this
  plugin does **not** auto-download replacements, but it now warns in its
  settings page and server log once the configured executable file is
  about 80 days old so you can replace it manually before expiry.
- The Debian packages below, and PulseAudio actually running and
  reachable by Lyrion's own service account.
- Optional: if your host's glibc is too old for the prebuilt Soloist
  binary, see [glibc compatibility](#if-your-hosts-glibc-is-too-old) below.

## Debian packages

```bash
sudo apt install -y pulseaudio pulseaudio-utils ffmpeg python3
```

- **`pulseaudio` / `pulseaudio-utils`** — Soloist needs PipeWire or
  PulseAudio for audio output; there's no raw-ALSA fallback. Minimal
  images (DietPi and similar) often have neither installed by default.
  Installing the package alone isn't enough on a headless box — it also
  needs to actually be *running* and reachable by whichever user Lyrion
  runs as (commonly `squeezeboxserver`, not root). See
  [Setting up PulseAudio](#setting-up-pulseaudio-headless-hosts) below for
  the full setup, including a permissions step that's easy to miss.
- **`ffmpeg`** — captures the PulseAudio sink and encodes it for
  streaming to Lyrion.
- **`python3`** — runs the small built-in HTTP relay
  (`Bin/audio-relay.py`) that gets audio to Lyrion; almost always already
  installed (`python3 --version` to check).

Two Perl modules the plugin's code needs are usually already bundled with
Lyrion itself, but if the plugin fails to load with a
`Can't locate .../XS.pm` or `Can't locate Proc/Background.pm` error in
Lyrion's server log, install them directly:

```bash
sudo apt install -y libjson-xs-perl libproc-background-perl
```

## Debian helper script

To install the Debian-side prerequisites and grant the Lyrion service
user the needed audio permissions automatically, run:

```bash
curl -fsSL -o setup-debian-prereqs.sh \
  https://raw.githubusercontent.com/denieuwevorst/LMS_Soloist/main/Bin/setup-debian-prereqs.sh
chmod +x setup-debian-prereqs.sh
sudo ./setup-debian-prereqs.sh
```

What it does:
- installs the required Debian packages for the current
  Pulse/PipeWire-based bridge design
- detects the Lyrion systemd service and its runtime user
- starts a simple system-mode PulseAudio service **only if** no
  Pulse-compatible server is already reachable
- adds the Lyrion user to `pulse-access` (and `audio` if that group
  exists)
- restarts Lyrion so the new group membership takes effect

Use `sudo ./setup-debian-prereqs.sh --lyrion-user <user>` if your Lyrion
service user can't be auto-detected, or `--skip-apt` if you already
installed the packages yourself and only want the permissions/service
setup.

The helper intentionally does **not** download the Soloist binary or set
your API key; those stay manual because they're tied to your architecture
and Spotify developer account.
## Install:
          
   https://raw.githubusercontent.com/denieuwevorst/lms-spotify-soloist/main/repo.xml
   
  1.In Lyrion: **Settings → Plugins → Additional Plugin Repositories**,
   paste that raw URL, click Apply, refresh the plugin list. "Spotify
   Soloist (Connect)" should now appear as an installable third-party
   plugin.


2. Settings → Advanced → Plugins → **Spotify Soloist (Connect)** → open
   its settings page. Fill in the Soloist binary path, ffmpeg path, and
   your API key.
3. Check the box next to each Squeezebox player you want its own
   dedicated Spotify Connect device — takes effect immediately per
   checkbox.
4. Open the Spotify app on the same network. You should see one device
   per checked player (e.g. "Kitchen (Soloist)"). Pick one and hit play —
   one-time pairing per player; the session persists under that player's
   own data directory afterward.

## Setting up PulseAudio (headless hosts)

Minimal images like DietPi often ship with neither PipeWire nor
PulseAudio running. Soloist requires one of them for audio output — there
is no raw-ALSA fallback. On a headless box, run PulseAudio in **system
mode** (there's no desktop login session to auto-spawn a per-user one).
The recommended path is the [Debian helper script](#debian-helper-script)
above. If you want to do it manually instead, this assumes
`pulseaudio`/`pulseaudio-utils` are already installed from the
[Debian packages](#debian-packages) step above:

```bash
sudo tee /etc/systemd/system/pulseaudio.service > /dev/null << 'EOF'
[Unit]
Description=System-wide PulseAudio
After=sound.target

[Service]
Type=simple
ExecStart=/usr/bin/pulseaudio --system --disallow-exit --disable-shm
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now pulseaudio.service
```

**Critical, easy to miss:** whichever user Lyrion actually runs as needs
to be in the `pulse-access` group — not just whichever account you happen
to be testing from over SSH:

```bash
sudo adduser squeezeboxserver pulse-access   # substitute the real user
sudo systemctl restart lyrionmusicserver
```

Group membership only takes effect for newly-spawned processes, hence the
restart. If you skip this, PulseAudio's own log
(`journalctl -u pulseaudio`) will show
`Denied access to client with invalid authentication data` at exactly the
timestamps the plugin tries to connect — that message is the signature of
this specific problem.

You don't need real audio hardware working on this box — the null-sinks
this plugin creates are purely virtual (Soloist writes into one, ffmpeg
reads it back out); the actual listening destination is Lyrion elsewhere
on your network.

## If your host's glibc is too old

Soloist builds are compiled against a specific glibc version. On an older
host, you'll see something like `version GLIBC_2.3x not found` when
running it directly. Point the plugin's "Soloist binary path" setting at
a wrapper script instead of the raw binary — running Soloist inside a
container with a newer glibc via [distrobox](https://github.com/89luca89/distrobox)
is the least disruptive fix:

```bash
distrobox create --name soloist-box --image debian:trixie
distrobox enter soloist-box    # install soloist inside here
```

```bash
#!/usr/bin/env bash
# /usr/local/bin/soloist-wrapper
exec distrobox enter soloist-box -- soloist "$@"
```

`chmod +x` that wrapper and point the plugin at it. Distrobox forwards the
PipeWire/PulseAudio socket automatically — nothing else needs to change.

## Format: mp3, flac, or PCM/WAV

The `flac` option sends a native, continuous FLAC stream (`audio/flac`),
not Ogg-FLAC. It uses fast, low-buffer encoder settings for live playback;
select it only for players with FLAC decoding support.

The `pcm` option sends uncompressed 44.1 kHz, stereo, signed 16-bit PCM
inside a continuous WAV stream (`audio/wav`). It avoids encoder latency and
is intended for diagnosing or minimizing startup delay on players with
WAV/PCM support. It uses approximately 1.4 Mbit/s, so use MP3 or FLAC when
bandwidth matters.

| Format | Compatible players | Tradeoff |
|---|---|---|
| `mp3` | All Squeezebox generations | Lowest bandwidth |
| `flac` | Players with FLAC support | Lossless bridge encoding |
| `pcm` | Players with WAV/PCM support | Lowest encoder latency; highest bandwidth |

Changing the format setting does not take effect on an already-running
instance. Toggle that player checkbox off and back on (or restart Lyrion)
after changing it.

## Known limitations

- **Elapsed time counts up indefinitely, no progress bar.** This is one
  continuous audio connection, not discrete per-track files — Lyrion has
  no transport-level way to detect that a new song started inside the
  byte stream, only that the *metadata* changed. This is identical to how
  Lyrion displays any live internet radio station. Track duration is
  intentionally **not** published for the continuous relay stream,
  because giving Lyrion a finite song length caused it to stop playback
  at song boundaries.
- A few seconds of latency are inherent to any capture → encode → stream
  bridge, not specific to this design.
- Each per-player relay has no authentication — fine on a trusted home
  LAN.
- Soloist builds expire 90 days after their build date (exit code 10) —
  each instance's log notes this explicitly when it happens; install a
  newer build. This plugin also raises an earlier warning in its
  settings page and server log once the configured executable file is
  about 80 days old. If your configured `soloistBin` path is a wrapper
  script, that age check only reflects the wrapper file itself, not the
  real Soloist binary behind it.
- Disabling the whole plugin from Lyrion's UI doesn't stop running bridge
  processes — uncheck each player first, or restart Lyrion.
- Auto-tune fires once per transition into "playing" for that player's
  instance. Pausing Spotify stops and clears that player's Soloist stream;
  if the player is manually stopped afterward, it won't re-tune until
  Spotify-side playback stops and restarts.
- Player slot numbers (and their ports/sink names) are assigned once and
  persist even after a player is later unchecked, so re-checking it later
  doesn't disturb any other player's assignment — but slot numbers only
  grow over time, never get reused.
- Resource usage scales with player count: each checked player runs its
  own `soloist` + `ffmpeg` + relay process trio. Fine for a handful of
  rooms; think twice before checking a dozen players on a small Pi.

## Troubleshooting

Symptoms are listed in the order they tend to actually occur when setting
this up.

**`pactl not found` / `pactl found but can't reach a running server`**
No PulseAudio/PipeWire-pulse server is reachable. See
[Setting up PulseAudio](#setting-up-pulseaudio-headless-hosts) above.

**Bridge starts, but the device never shows up in the Spotify app**
- Check that player's status in the plugin's settings page — "running" or
  "stopped"? If stopped, check `Bin/soloist-bridge.sh`'s per-instance log
  file (see below) for the actual startup error.
- If it shows running, this is a network-discovery problem, not a bridge
  problem: check for a VPN active on your phone (extremely common cause —
  breaks LAN-only mDNS discovery entirely), Wi-Fi client/AP isolation
  between the Lyrion host and your phone, and firewall rules blocking
  local device discovery.

**Where's the log for a specific player's instance?**
```
<Lyrion cache dir>/plugin-spotifysoloist/cache/player_<N>/bridge.log
```
`<N>` is that player's slot number, assigned in the order players were
first selected (first player = 0, second = 1, ...). If the directory
doesn't exist at all, the bridge process likely never launched — check
Lyrion's own server log for `plugin.spotifysoloist` errors around the
time you toggled that player's checkbox. This cache directory now
persists across LMS and bridge restarts, so old `bridge.log` content can
still be there from earlier runs; the persistent Soloist login/session
data lives in a separate `data` directory and is never
touched.

**Connects, logs in, shows correct status/metadata, but there's no
sound** — work through these in order:
1. Confirm you're not hitting the [format/hardware mismatch](#format-mp3-flac-or-pcmwav)
   above (classic hardware + flac).
2. Check whether real audio is actually reaching the relay:
   ```bash
   curl -s http://127.0.0.1:<relay-port>/soloist.mp3 --max-time 5 -o /tmp/test.mp3
   ffmpeg -i /tmp/test.mp3 -af volumedetect -f null - 2>&1 | grep -i "mean_volume\|max_volume"
   ```
   A result near **-90dB is silence** — real audio isn't reaching the
   sink at all. Anything in the **-20dB to -5dB range is normal** — audio
   is flowing correctly, and the remaining problem is specific to how
   Lyrion hands the stream to that particular player.
3. If it's silence: check whether Soloist's actual PulseAudio stream is
   attached to the right sink —
   ```bash
   pactl list sink-inputs   # look for application.process.binary = "soloist"
   pactl list short sinks
   ```
   If it's attached to your real hardware output instead of
   `soloist_sink_<N>`, something has gone wrong with the routing this
   plugin normally handles automatically and continuously in the
   background — check that player's `bridge.log` for a
   `routing soloist's PulseAudio stream ...` line; its absence, well after
   you've hit play in the Spotify app, points at a deeper problem worth
   filing an issue for.
4. Also check for `Failed to create secure directory (.../.config/pulse)`
   / `Failed to load cookie file` in that same log — this means the
   service account's `$HOME` isn't writable, preventing Soloist from
   completing PulseAudio's cookie-based authentication. The bridge script
   already gives each instance its own writable `HOME`
   (`SOLOIST_DATA_DIR`) specifically to avoid this; seeing these errors
   despite that suggests something is overriding it in your environment.

## Acknowledgments

Based on how [ShairTunes2](https://github.com/philippe44/lms-shairtunes2w)
gets metadata and artwork into Lyrion's UI. No code from that project is
reused — this is an independent implementation for Spotify Connect rather
than AirPlay.

## License

MIT — see [LICENSE](LICENSE).
