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
                                       backend-selected audio target
                           (Pulse/PipeWire null-sink OR ALSA/apulse loopback)
                                                            │
                    Bin/soloist-bridge.sh: ffmpeg captures that backend's
                    per-player monitor/input continuously, writes into its
                    own named pipe (FIFO)
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
- Autoplay now also waits briefly for the relay to see real audio bytes
  before issuing `playlist play`, with a short timeout fallback so the
  first track does not have to depend on a blind fixed delay.
- No Icecast, no extra system service — a small embedded Python relay
  handles multiple simultaneous listeners per player.
- Default backend preserves the current Pulse/PipeWire null-sink bridge.
- Optional ALSA/apulse backend removes the hard requirement for a running
  PulseAudio/PipeWire stack on the host, as long as you provide an
  apulse-style Soloist wrapper and matching ALSA loopback devices.
- Optional experimental direct-PCM shim backend goes further: no Pulse
  server *and* no ALSA loopback card, at the cost of being newer and
  less validated (see [Backend choices](#backend-choices)).

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
- `ffmpeg` and `python3`, plus one of these audio backend setups:
  - **Default:** a reachable PulseAudio/PipeWire stack for the current
    null-sink backend.
  - **Optional no-Pulse path:** on x86_64, the bundled Soloist pulse shim;
    on other architectures, an apulse-style wrapper around Soloist; in both
    cases, an ALSA loopback device layout the plugin can map per player.
- Optional: if your host's glibc is too old for the prebuilt Soloist
  binary, see [glibc compatibility](#if-your-hosts-glibc-is-too-old) below.

## Backend choices

### 1. PipeWire/PulseAudio backend (default)

This is the existing bridge design. Each selected player gets its own
virtual null-sink; Soloist plays into that sink and ffmpeg captures the
matching monitor.

Required packages:

```bash
sudo apt install -y pulseaudio pulseaudio-utils ffmpeg python3
```

- **`pulseaudio` / `pulseaudio-utils`** — Soloist needs PipeWire or
  PulseAudio for this backend's virtual sinks and capture path. Minimal
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

### 2. ALSA/apulse backend (optional, no Pulse server required)

Use this only if you specifically want to run without a host PulseAudio or
PipeWire daemon. Soloist still does **not** have native ALSA output, so
the plugin needs a Pulse-compatible shim path into ALSA instead.

On **x86_64**, this branch now ships a bundled `libpulse.so.0` shim under
`alsa-lib/amd64/` and loads it automatically on the ALSA backend, so your
configured **Soloist binary path** can be the raw `soloist` binary.

Note: that bundled shim is **not** apulse. It's a purpose-built
`libpulse.so.0` replacement that genuinely honors
`APULSE_PLAYBACK_DEVICE` and opens it directly via ALSA's
`snd_pcm_open()`. The bridge automatically upgrades a plain `hw:` device
to `plughw:` for this shim specifically, because on at least some
hosts the raw `hw:` PCM type fails to open for **playback** even though
the paired `plughw:` capture device opens fine on the very same card
(confirmed via the shim's own diagnostic logging). You don't need to do
anything for this; it happens automatically whenever the bundled shim
is active. If you instead supply your own wrapper/launcher (see below),
that wrapper's own Pulse-to-ALSA shim is expected to honor
`APULSE_PLAYBACK_DEVICE` in the normal apulse way, and you're free to
configure whatever device string it needs directly via **ALSA loopback
device prefix**.

On other architectures, the plugin still expects your configured
**Soloist binary path** to be an apulse-style wrapper (or equivalent
launcher) that makes Soloist's Pulse client API calls land on ALSA
instead.

There's also a separate **experimental direct-PCM shim backend** (see
section 3 below) that avoids the ALSA loopback card entirely and fixes
this backend's known end-of-track stall -- consider it if you hit that
issue.

Required packages:

```bash
sudo apt install -y alsa-utils ffmpeg python3
```

Typical setup:

1. Load the ALSA loopback module **and make it persist across reboots** --
   a plain `modprobe` only loads it for the current boot, and if it's
   missing after a reboot the ALSA backend will silently have no device to
   use (Soloist "plays" with no audible output, and `arecord`/apulse will
   fail to find it):
   ```bash
   sudo modprobe snd-aloop
   echo snd-aloop | sudo tee /etc/modules-load.d/snd-aloop.conf
   ```
   Confirm it's actually present with `cat /proc/asound/cards` -- you
   should see a card literally named `Loopback`. The
   [ALSA helper script](#debian-helper-script-alsaapulse-backend-only)
   below does all of this for you, including picking a substream count
   for multiple players.
2. Point the plugin's **Audio backend** setting at **ALSA/apulse
   loopback**.
3. On **x86_64**, point **Soloist binary path** at the raw `soloist`
   binary. On other architectures, point it at a wrapper that launches
   Soloist under `apulse` (or an equivalent shim).
4. Leave **ALSA loopback device prefix** at `hw:Loopback` unless your
   loopback card uses a different name. The plugin will keep Soloist
   playback on `hw:` and automatically prefer `plughw:` on the capture
   side when the prefix starts with `hw:`. On the ALSA backend the bridge
   captures with `arecord` first and only then feeds ffmpeg, so hosts where
   ffmpeg's direct ALSA device parsing is picky can still work reliably.

With the default prefix, player slot `N` maps to:

- Soloist playback: `hw:Loopback,0,N`
- arecord capture: `plughw:Loopback,1,N`

That means your ALSA loopback setup must provide enough substreams for the
number of selected players you plan to run in parallel.

Two Perl modules the plugin's code needs are usually already bundled with
Lyrion itself, but if the plugin fails to load with a
`Can't locate .../XS.pm` or `Can't locate Proc/Background.pm` error in
Lyrion's server log, install them directly:

```bash
sudo apt install -y libjson-xs-perl libproc-background-perl
```

### 3. Experimental direct-PCM shim backend (optional, no Pulse server, no ALSA loopback)

This is a newer, simpler alternative to the ALSA/apulse backend above. It
uses a different, purpose-built `libpulse.so.0` replacement -- shipped
unbuilt under `contrib/experimental-pcm-shim/` -- that writes Soloist's
raw PCM straight to a FIFO instead of trying to open a real ALSA device.
The bridge reads that FIFO directly: WAV/PCM mode forwards it without
ffmpeg, while FLAC/MP3 mode still uses ffmpeg only for encoding. That
means:

- No PulseAudio/PipeWire server.
- No ALSA loopback (`snd-aloop`) card, so no `modprobe`/persistence step
  and no loopback substream-count planning.
- It paces playback on a real clock and reports position from bytes it
  has actually written out, rather than bytes merely handed to it --
  which is why it also fixes the ALSA/apulse backend's known
  end-of-track stall (see Troubleshooting below): a manual test against
  the real `soloist` binary on real hardware played a full track to the
  end and auto-advanced to the next one without stalling.

It is still **experimental**, but the full plugin path is now confirmed
on real DietPi/LMS hardware: Soloist loads the custom shim, PCM reaches
the per-player FIFO, and LMS plays the bridge's WAV stream without
ffmpeg. Extended and multi-player use remain less tested than the Pulse
backend. The shim is not prebuilt or bundled -- you build it yourself,
once, on the target device.

Setup:

1. Build the shim on your device:
   ```bash
   cd contrib/experimental-pcm-shim
   make
   ```
   See that directory's own `README.md` for build prerequisites and
   troubleshooting.
2. Point the plugin's **Audio backend** setting at **Experimental
   direct-PCM shim**.
3. Set **Experimental PCM shim directory** to the directory containing
   the `libpulse.so.0` you just built (e.g. the
   `contrib/experimental-pcm-shim` path itself).
   This path must be readable/searchable by the user running LMS
   (`squeezeboxserver` on most installs): **do not point it at `/root/...`**
   unless you have explicitly opened those directory permissions up for the
   service user.
4. Leave **Soloist binary path** at the raw `soloist` binary, same as on
   x86_64 for the ALSA backend.
5. The bridge clamps the shim's requested playback buffer to `300ms` by
   default (`SOLOIST_SHIM_MAX_TLENGTH_MS`). This keeps Soloist's own
   playback clock close to audio that has actually drained through the
   shim and avoids immediate pause/track-end timing glitches seen with
   larger Pulse-style buffers.

No ALSA loopback device prefix is needed or used for this backend; each
player gets its own PCM FIFO automatically.

## Debian helper script (Pulse backend only)

To install the Debian-side prerequisites for the **default
PipeWire/PulseAudio backend** and grant the Lyrion service user the needed
audio permissions automatically, run:

```bash
curl -fsSL -o setup-debian-prereqs.sh \
  https://raw.githubusercontent.com/denieuwevorst/LMS_Soloist/main/Bin/setup-debian-prereqs.sh
chmod +x setup-debian-prereqs.sh
sudo ./setup-debian-prereqs.sh
```

What it does:
- installs the required Debian packages for the Pulse/PipeWire backend
- detects the Lyrion systemd service and its runtime user
- starts a simple system-mode PulseAudio service **only if** no
  Pulse-compatible server is already reachable
- adds the Lyrion user to `pulse-access` (and `audio` if that group
  exists)
- restarts Lyrion so the new group membership takes effect

Use `sudo ./setup-debian-prereqs.sh --lyrion-user <user>` if your Lyrion
service user can't be auto-detected, or `--skip-apt` if you already
installed the packages yourself and only want the permissions/service
setup. If you plan to use the ALSA/apulse backend instead, skip this
helper entirely unless you still want it for some other Pulse-based host
audio setup.

The helper intentionally does **not** download the Soloist binary or set
your API key; those stay manual because they're tied to your architecture
and Spotify developer account.

## Debian helper script (ALSA/apulse backend only)

To install the Debian-side prerequisites for the **optional ALSA/apulse
backend** and make the ALSA loopback module persist across reboots
(skipping this step is the single most common cause of "Soloist plays but
there's no sound" on this backend), run:

```bash
curl -fsSL -o setup-alsa-prereqs.sh \
  https://raw.githubusercontent.com/denieuwevorst/LMS_Soloist/main/Bin/setup-alsa-prereqs.sh
chmod +x setup-alsa-prereqs.sh
sudo ./setup-alsa-prereqs.sh
```

What it does:
- installs the required Debian packages for the ALSA/apulse backend
- loads `snd-aloop` now with enough substreams for the players you plan to
  run (`--substreams N`, default 8), and persists both the module load
  (`/etc/modules-load.d/snd-aloop.conf`) and its substream count
  (`/etc/modprobe.d/snd-aloop-soloist.conf`) so a reboot doesn't silently
  remove your loopback device
- verifies a `Loopback` card actually shows up in `/proc/asound/cards`
  afterward
- detects the Lyrion systemd service and its runtime user, adds that user
  to the `audio` group if it exists, and restarts Lyrion

Use `sudo ./setup-alsa-prereqs.sh --lyrion-user <user>` if your Lyrion
service user can't be auto-detected, or `--skip-apt` if you already
installed the packages yourself and only want the loopback/service setup.
If you plan to use the default Pulse/PipeWire backend instead, use
`setup-debian-prereqs.sh` above instead of this one.

## Install

https://raw.githubusercontent.com/denieuwevorst/lms-spotify-soloist/main/repo.xml

1. In Lyrion: **Settings → Plugins → Additional Plugin Repositories**,
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
PulseAudio running. If you stay on the default backend, run PulseAudio in
**system mode** (there's no desktop login session to auto-spawn a per-user
one). The recommended path is the
[Debian helper script](#debian-helper-script-pulse-backend-only) above. If
you want to do it manually instead, this assumes
`pulseaudio`/`pulseaudio-utils` are already installed from the
PipeWire/PulseAudio backend package step above:

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
PipeWire/PulseAudio socket automatically — nothing else needs to change if
you're staying on the default backend.

## ALSA/apulse wrapper example

If you want the no-Pulse backend on a non-x86_64 host, the configured
Soloist path should usually be a wrapper rather than the raw `soloist`
binary itself. The plugin sets `APULSE_PLAYBACK_DEVICE` per player
instance, so the wrapper can stay generic:

```bash
#!/usr/bin/env bash
exec apulse /usr/local/bin/soloist "$@"
```

Point **Soloist binary path** at that wrapper, switch **Audio backend** to
**ALSA/apulse loopback**, and keep the default `hw:Loopback` device prefix
unless your loopback card is named differently.

## Format: mp3, flac, or PCM/WAV

The settings page offers a default format plus an override for each
player. Existing installations continue to use the default until an
override is selected. Changing one override restarts only that player's
bridge.

The `flac` option sends a native, continuous FLAC stream (`audio/flac`),
not Ogg-FLAC. It uses fast, low-buffer encoder settings for live playback;
select it only for players with FLAC decoding support.

The `pcm` option sends uncompressed 44.1 kHz, stereo, signed 16-bit PCM
inside a continuous WAV stream (`audio/wav`). It avoids encoder latency and
is intended for diagnosing or minimizing startup delay on players with
WAV/PCM support. It uses approximately 1.4 Mbit/s, so use MP3 or FLAC when
bandwidth matters. PCM/WAV skips ffmpeg entirely: the bridge captures raw
PCM directly (`parec` on the Pulse backend, `arecord` on the ALSA backend,
or the custom FIFO on the direct-PCM shim backend) and the built-in relay
serves it as a streaming WAV response. LMS can apply its normal conversion
pipeline if the selected player cannot accept WAV directly; it otherwise
sends WAV unchanged. To add headroom without starving LMS when the relay
queue runs dry, the PCM path now uses a real **300 ms capture buffer** on
the input side instead (`parec --latency-msec=300` on Pulse/PipeWire or an
equivalent `arecord` buffer on ALSA). On this branch, PCM/WAV also
**flushes queued relay audio at track changes** so you can see whether the
remaining latency growth is mostly queued backlog rather than capture-side
stalling.

| Format | Compatible players | Tradeoff |
|---|---|---|
| `mp3` | All Squeezebox generations | Lowest bandwidth |
| `flac` | Players with FLAC support | Lossless bridge encoding |
| `pcm` | Players with WAV/PCM support | Lowest encoder latency; highest bandwidth |

The **Default stream format** applies to players whose table entry is
**Default**. Each player can override it independently; saving restarts
only enabled bridges whose effective format changed. MP3 and FLAC are
encoded in the bridge with ffmpeg. PCM/WAV avoids bridge encoding and lets
LMS decide whether that player needs its normal server-side transcoding.

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
- Player slot numbers (and their ports/backend device names) are assigned
  once and persist even after a player is later unchecked, so re-checking
  it later doesn't disturb any other player's assignment — but slot
  numbers only grow over time, never get reused.
- Resource usage scales with player count: each checked player runs its
  own `soloist` + `ffmpeg` + relay process trio. Fine for a handful of
  rooms; think twice before checking a dozen players on a small Pi.

## Troubleshooting

Symptoms are listed in the order they tend to actually occur when setting
this up.

**`pactl not found` / `pactl found but can't reach a running server`**
No PulseAudio/PipeWire-pulse server is reachable **for the default
backend**. Either switch to the ALSA/apulse backend or see
[Setting up PulseAudio](#setting-up-pulseaudio-headless-hosts) above.

**ALSA/apulse backend starts but never produces audio**
- Confirm your configured **Soloist binary path** is actually a wrapper
  that launches under `apulse` (or an equivalent Pulse-on-ALSA shim), not
  the raw Soloist binary.
- Confirm the ALSA loopback module is loaded and that the mapped devices
  exist for the affected player slot:
  ```bash
  aplay -L | grep -i Loopback
  arecord -L | grep -i Loopback
  ```
- Check that player's `bridge.log` for the exact playback/capture devices
  it tried to use. The ALSA backend logs both `APULSE_PLAYBACK_DEVICE` and
  the ffmpeg capture device at startup.
- If `arecord`/apulse fail with `ALSA lib confmisc.c:... Cannot get card
  index for Loopback` (or audio opens but is silent with no error at all),
  check `bridge.log` for the resolver's own `WARNING` line, which tells
  you exactly which case you're in:
  - `no ALSA card named 'Loopback' found ... (known cards: 0='PCH')` (or
    similar, with **no** `Loopback` in the list) means the loopback kernel
    module **simply isn't loaded right now** -- most likely it was loaded
    manually once (e.g. for testing) but never made to persist across a
    reboot. Fix: `sudo modprobe snd-aloop` and persist it with
    `echo snd-aloop | sudo tee /etc/modules-load.d/snd-aloop.conf`, then
    restart that player.
  - `N ALSA cards are named 'Loopback' (indices: ...)` means you have
    **more than one** loopback card with the same name (e.g. `snd-aloop`
    loaded more than once without unique `id=` values), which makes
    ALSA's name-based lookup ambiguous and can silently fail to open
    either side of the pipe. The bridge resolves this to the first
    matching numeric index automatically, but to remove the ambiguity
    for good, unload the extra instances or give each one a unique
    `id=` when loading `snd-aloop`.

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
3. If it's silence on the **Pulse/PipeWire backend**: check whether
   Soloist's actual PulseAudio stream is attached to the right sink —
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
4. If it's silence on the **ALSA/apulse backend**: confirm the mapped
   capture device for that slot is actually receiving audio:
   ```bash
   ffmpeg -f alsa -i hw:Loopback,1,<slot> -t 5 -af volumedetect -f null - 2>&1 | grep -i "mean_volume\|max_volume"
   ```
   Substitute your configured device prefix if you changed it from
   `hw:Loopback`. If this is **also** silent (no audio reaching the
   capture side at all) while using the **bundled x86_64 shim**, verify
   the loopback hardware pairing itself works independent of Soloist:
   ```bash
   speaker-test -D hw:Loopback,0,<slot> -c2 -r44100 -twav &
   SPID=$!; sleep 1
   arecord -D plughw:Loopback,1,<slot> -c2 -f S16_LE -r44100 -d3 /tmp/looptest.wav
   kill $SPID 2>/dev/null
   ffmpeg -y -i /tmp/looptest.wav -af volumedetect -f null - 2>&1 | grep -i "mean_volume\|max_volume"
   ```
   If that still shows real levels but regular playback doesn't, check
   `bridge.log` for a `pcm open ... failed` line from `soloist-shim:`
   right after the `cork 0` that starts playback. The bundled shim opens
   the exact device string in `APULSE_PLAYBACK_DEVICE` via
   `snd_pcm_open()`; the bridge already upgrades a plain `hw:` device to
   `plughw:` for this shim (raw `hw:` playback opens have been observed
   to fail outright on some hosts even when the paired `plughw:` capture
   device on the same card works fine), but if you still see a `pcm
   open ... failed` line, temporarily set `SOLOIST_SHIM_DIAG=1` in the
   bridge's environment for one run to get verbose per-call shim logging
   (`APULSE_DIAG`) plus a raw audio dump at
   `<cache-dir>/player_<N>/shim-alsa-yield.raw` (`APULSE_YIELD_PATH`) to
   see exactly what's failing and whether real audio is reaching the
   shim at all. Leave this off for normal use -- the per-call logging
   runs on the shim's real-time audio thread and can itself cause
   glitches/dropouts if left on.
5. If playback plays correctly but **cuts off a few hundred
   milliseconds to a few seconds before the real end of a track and
   LMS never advances to the next one** (specific to the ALSA/apulse
   backend -- the Pulse/PipeWire backend doesn't have this issue): the
   bundled shim negotiates a playback buffer several seconds deep by
   default, and Soloist's own position tracking is based on how much
   audio it has *handed to* the stream, not how much has actually
   reached the speaker. With a deep buffer, Soloist's own clock can
   think a track has finished seconds before the real, still-queued
   audio has drained, and then cork/flush the stream for the next
   track -- discarding that last bit of real audio instead of playing
   it out. The bridge clamps this via the shim's undocumented
   `APULSE_MAX_TLENGTH_MS` to 300ms by default (matching the ALSA
   capture side's own `--buffer-time=300000`), so Soloist's clock can
   only race a few hundred ms ahead of real output instead of several
   seconds. Override with `SOLOIST_SHIM_MAX_TLENGTH_MS=<ms>` in the
   bridge's environment if you need a different value (e.g. raise it if
   you hear underruns/glitches on very constrained hardware, at the
   cost of reintroducing some of this end-of-track mismatch). **Note:**
   on real hardware this buffer clamp alone was not always enough to
   stop the freeze from recurring -- as a backstop, the plugin also
   runs a watchdog (ALSA backend only) that force-skips a track if
   Soloist still reports `"playing"` with an unchanged position for 8
   seconds, so LMS doesn't hang indefinitely even if the freeze
   happens. If you see frequent forced skips in the Lyrion log
   (`Soloist playback position appears stuck ... forcing a track
   skip`), the underlying freeze is still occurring and the last bit of
   that track's audio is being lost; please report this with
   `bridge.log` from around the skip.

   If this keeps recurring, consider trying the **experimental
   direct-PCM shim backend** instead (see [Backend choices](#backend-choices)
   section 3): it tracks position from bytes it has actually written
   out rather than bytes merely handed to it, which avoids this whole
   class of bug -- confirmed on real hardware with a full, unassisted
   automatic track transition that stalled under the ALSA/apulse
   backend.
6. Also check for `Failed to create secure directory (.../.config/pulse)`
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
