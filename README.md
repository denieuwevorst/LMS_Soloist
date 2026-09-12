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
artwork for an arbitrary internet stream. This plugin closes both gaps by
following the same architecture as the third-party
[ShairTunes2](https://github.com/philippe44/lms-shairtunes2w) AirPlay
bridge: a custom URL scheme (`soloist://` here, `airplay://` for them)
routed through a dedicated protocol handler, which is what lets Lyrion
call plugin code for metadata lookups instead of falling back to generic
ICY text parsing.

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
                        connected listeners — this replaces Icecast
                                                            │
                                                            ▼
                        <player> plays soloist://<host>:<port>/soloist.mp3
                        (NOT plain http://)
                                                            │
              ProtocolHandler.pm rewrites soloist:// → http:// for the
              actual audio fetch, but Lyrion still asks IT for metadata

  Plugin.pm polls that instance's own `soloist ctl ... now --json` every
  3s: writes title/artist/album/cover into that player's Lyrion metadata,
  and — the moment Spotify actually starts playing — auto-starts playback
  on that same player.
```

One thing is genuinely simpler here than in ShairTunes2: AirPlay delivers
artwork as a raw binary blob over its own protocol, so ShairTunes2 has to
run its own embedded HTTP server just to turn that into a fetchable URL.
Soloist's `now --json` already gives a direct `https://i.scdn.co/...`
cover URL — no proxying needed.

**Why one Soloist process per player, not one shared source:** AirPlay
lets ShairTunes2 advertise a distinct virtual target per Squeezebox via
mDNS, so you pick the physical speaker directly in the AirPlay picker.
Spotify Connect has no equivalent — one `soloist` process is one fixed
device with one name. Running a separate process per selected player, each
with its own device name/sink/port/relay, is how this gets the same
practical outcome: N separate, individually selectable entries in the
Spotify app's device picker.

## Features

- One Spotify Connect device per selected Squeezebox player, shown
  separately in the Spotify app.
- Auto-tune: the corresponding Lyrion player starts playing automatically
  the moment Spotify actually starts sending audio — no manual "select
  the stream from Radios" step.
- Real Now Playing metadata: title, artist, album, and cover art, via
  Lyrion's native remote-metadata mechanism (not just an ICY text title).
- No Icecast, no extra system service — a small embedded Python relay
  handles multiple simultaneous listeners per player.
- Works with both real PipeWire and plain PulseAudio-only hosts.

## Prerequisites

- **Lyrion Music Server** (or Logitech Media Server) already installed
  and running. Tested against a Debian `.deb` install; should work
  anywhere Lyrion runs as a systemd service on Linux.
- **PipeWire or PulseAudio**, reachable by whichever user Lyrion actually
  runs as (commonly `squeezeboxserver`, *not* root, on Debian-packaged
  installs — check with `ps -o user= -p $(systemctl show -p MainPID
  --value lyrionmusicserver)`). Minimal/headless images (DietPi and
  similar) often have neither installed by default — see
  [Setting up PulseAudio](#setting-up-pulseaudio-headless-hosts) below.
- **Python 3** (runs the built-in audio relay). Almost always already
  present — `python3 --version` to confirm.
- **ffmpeg**, for audio capture/encoding.
- **A Spotify Soloist binary and API key.** Generate a key from the
  [Spotify for Developers dashboard](https://developer.spotify.com/dashboard/soloist)
  (Premium account required) and download a build for your architecture
  from Soloist's own distribution page. Keep the key private — it's tied
  to your account.
- Optional: if your host's glibc is too old for the prebuilt Soloist
  binary, see [glibc compatibility](#if-your-hosts-glibc-is-too-old) below.

## Distributing via a Lyrion repository (optional)

Instead of `git clone`-ing directly into `Plugins/`, this can be installed
through Lyrion's own **Settings → Plugins** browser, the same way official
and other third-party plugins are — paste a repository URL, tick a box,
done. This repo already includes a ready-to-use `repo.xml` and a correctly
packaged release zip; you just need to host both somewhere.

1. Create a GitHub Release (e.g. `v0.3.0`) and upload
   `SpotifySoloist-0.3.0.zip` (in this repo) as a release asset. Its
   sha1 is `32576c561575b37a5d8ec2c06e78d52181e23797` — matches what's
   already in `repo.xml`, **only if you upload this exact file**.
2. Edit `repo.xml`: replace `REPLACE_WITH_YOUR_NAME`,
   `REPLACE_WITH_YOUR_EMAIL`, and both
   `REPLACE_WITH_YOUR_GITHUB_USER` placeholders with your own details and
   your actual release download URL.
3. Push. `repo.xml` is now fetchable at:
   ```
   https://raw.githubusercontent.com/<you>/lms-spotify-soloist/main/repo.xml
   ```
4. In Lyrion: **Settings → Plugins → Additional Plugin Repositories**,
   paste that raw URL, click Apply, refresh the plugin list. "Spotify
   Soloist (Connect)" should now appear as an installable third-party
   plugin.

**If you ever change the plugin and cut a new version:** rebuild the zip
from the *contents* of the plugin folder (not a wrapping folder — Lyrion's
own docs are explicit that `install.xml` etc. need to be at the zip root),
recompute its sha1, and update both the version number and sha1 in
`repo.xml` — an unmatched sha1 will make Lyrion refuse the download.
```bash
cd lms-spotify-soloist
zip -r ../SpotifySoloist-<new-version>.zip install.xml strings.txt Plugin.pm Settings.pm ProtocolHandler.pm HTML Bin
sha1sum ../SpotifySoloist-<new-version>.zip
```
Lyrion's repository docs specifically warn that the version number must be
in the filename, or it may reuse cached data and silently fail to upgrade
existing installs.

## Install

1. Clone this repo directly into Lyrion's `Plugins` directory, named
   `SpotifySoloist`:
   ```bash
   git clone https://github.com/<you>/lms-spotify-soloist.git \
       /var/lib/squeezeboxserver/cache/InstalledPlugins/Plugins/SpotifySoloist
   ```
   (Adjust the path for your install — common locations are
   `/usr/share/squeezeboxserver/Plugins/` or wherever `Plugins/` lives
   under your Lyrion base directory. Check Settings → Information in the
   web UI, or `find / -iname "Plugin.pm" -path "*Plugins*"`, if unsure.)
2. Make sure the helper scripts kept their executable bit (git preserves
   this from the repo, but double-check after cloning):
   ```bash
   chmod +x Plugins/SpotifySoloist/Bin/soloist-bridge.sh
   chmod +x Plugins/SpotifySoloist/Bin/audio-relay.py
   ```
3. Set up PipeWire/PulseAudio if this host doesn't have it yet — see
   [below](#setting-up-pulseaudio-headless-hosts).
4. Restart Lyrion Music Server.
5. Settings → Advanced → Plugins → **Spotify Soloist (Connect)** → open
   its settings page. Fill in the Soloist binary path, ffmpeg path, and
   your API key.
6. Check the box next to each Squeezebox player you want its own
   dedicated Spotify Connect device — takes effect immediately per
   checkbox.
7. Open the Spotify app on the same network. You should see one device
   per checked player (e.g. "Kitchen (Soloist)"). Pick one and hit play —
   one-time pairing per player; the session persists under that player's
   own data directory afterward.

## Setting up PulseAudio (headless hosts)

Minimal images like DietPi often ship with neither PipeWire nor
PulseAudio running. Soloist requires one of them for audio output — there
is no raw-ALSA fallback. On a headless box, run PulseAudio in **system
mode** (there's no desktop login session to auto-spawn a per-user one):

```bash
sudo apt install -y pulseaudio pulseaudio-utils

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

## Format: mp3 vs flac — read this before picking flac

**Classic, fixed-firmware Squeezebox hardware (Boom, Classic, Receiver)
cannot decode Ogg containers at all.** This plugin's `flac` option wraps
FLAC in an Ogg container, which only squeezelite-based software players
can handle. If you select `flac` for a classic hardware player, it will
connect, log in, show correct metadata and artwork, and simply never make
sound or progress — every part of the pipeline reports success right up
until the actual firmware decoder, which silently can't parse the stream.

| Format | Classic hardware (Boom/Classic/Receiver) | squeezelite-based players |
|---|---|---|
| `mp3` | ✅ Always works | ✅ Always works |
| `flac` (Ogg-FLAC) | ❌ Not supported | ✅ Works |

When in doubt, use `mp3`. Changing the format setting doesn't take effect
on an already-running instance — toggle that player's checkbox off and
back on (or restart Lyrion) after changing it.

## Known limitations

- **Elapsed time counts up indefinitely, no progress bar.** This is one
  continuous audio connection, not discrete per-track files — Lyrion has
  no transport-level way to detect that a new song started inside the
  byte stream, only that the *metadata* changed. This is identical to how
  Lyrion displays any live internet radio station. Track duration is
  passed through where available, which may improve the displayed total
  in some UIs, but doesn't change the underlying elapsed-time behavior.
- A few seconds of latency — inherent to any capture → encode → stream
  bridge, not specific to this design.
- Each per-player relay has no authentication — fine on a trusted home
  LAN.
- Soloist builds expire 90 days after their build date (exit code 10) —
  each instance's log notes this explicitly when it happens; install a
  newer build.
- Disabling the whole plugin from Lyrion's UI doesn't stop running bridge
  processes — uncheck each player first, or restart Lyrion.
- Auto-tune fires once per transition into "playing" for that player's
  instance — if the player is manually stopped afterward, it won't
  re-tune until Spotify-side playback stops and restarts.
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
time you toggled that player's checkbox.

**Connects, logs in, shows correct status/metadata, but there's no
sound** — work through these in order:
1. Confirm you're not hitting the [format/hardware mismatch](#format-mp3-vs-flac--read-this-before-picking-flac)
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

Architecturally modeled on [ShairTunes2](https://github.com/philippe44/lms-shairtunes2w)
(philippe44's fork of disaster123's original ShairTunes2), specifically
its custom-protocol-handler technique for getting real metadata into
Lyrion's UI, and its per-player settings-checkbox pattern. No code from
that project is reused directly — this is an independent implementation
for a structurally different source (Spotify Connect rather than
AirPlay), but the architectural debt is real and worth crediting clearly.

## License

MIT — see [LICENSE](LICENSE).
