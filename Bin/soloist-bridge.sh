#!/usr/bin/env bash
#
# soloist-bridge.sh -- pure audio pipeline, no Icecast. Launched (and
# supervised) by Plugin.pm via Proc::Background, configured entirely
# through environment variables it sets.
#
# Audio path: PipeWire/PulseAudio null-sink -> ffmpeg (continuous capture +
# encode) -> named pipe -> audio-relay.py (persistent multi-client HTTP
# broadcaster, plays the same role Icecast played before, embedded instead
# of a separate service -- see Bin/audio-relay.py for why a FIFO).
#
# Metadata is NOT handled here -- Plugin.pm polls `soloist ctl ... now
# --json` directly and writes into Lyrion's native metadata mechanism.
#
# Required env vars: SOLOIST_BIN FFMPEG_BIN PIPEWIRE_SINK DEVICE_NAME
#                     SOLOIST_API_KEY
# Optional (defaulted below): FORMAT BITRATE WS_PORT SOLOIST_DATA_DIR
#                     SOLOIST_CACHE_DIR RELAY_PORT RELAY_BIND FIFO_PATH
#                     PYTHON_BIN

set -u

: "${SOLOIST_BIN:?SOLOIST_BIN is required}"
: "${FFMPEG_BIN:?FFMPEG_BIN is required}"
: "${PIPEWIRE_SINK:?PIPEWIRE_SINK is required}"
: "${DEVICE_NAME:?DEVICE_NAME is required}"
: "${SOLOIST_API_KEY:?SOLOIST_API_KEY is required (plugin settings -> Soloist API key)}"

FORMAT="${FORMAT:-mp3}"
BITRATE="${BITRATE:-320k}"
SOLOIST_INITIAL_VOLUME="${SOLOIST_INITIAL_VOLUME:-100}"
WS_PORT="${WS_PORT:-9091}"
SOLOIST_DATA_DIR="${SOLOIST_DATA_DIR:-$HOME/.local/share/soloist-lyrion}"
SOLOIST_CACHE_DIR="${SOLOIST_CACHE_DIR:-$HOME/.cache/soloist-lyrion}"
RELAY_PORT="${RELAY_PORT:-9077}"
RELAY_BIND="${RELAY_BIND:-0.0.0.0}"
FIFO_PATH="${FIFO_PATH:-/tmp/soloist-audio.fifo}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
WS_ENDPOINT="127.0.0.1:${WS_PORT}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELAY_SCRIPT="${SCRIPT_DIR}/audio-relay.py"

mkdir -p "$SOLOIST_DATA_DIR" "$SOLOIST_CACHE_DIR"

# PulseAudio's client library (which Soloist links against) stores its
# auth cookie at $HOME/.config/pulse/cookie. When Lyrion runs as a
# dedicated service account (e.g. Debian's squeezeboxserver user), that
# account's $HOME is often something like /usr/share/squeezeboxserver --
# the installed application directory, not writable by that user -- so
# the cookie directory can never be created, Soloist can't establish a
# properly authenticated PulseAudio stream, and it silently produces no
# audio at all (while its Spotify-side status reporting, which doesn't
# depend on the audio path, keeps working fine -- misleadingly making
# everything else look healthy). Give it an unambiguously writable HOME
# instead of inheriting whatever the service account's happens to be.
export HOME="$SOLOIST_DATA_DIR"
export XDG_CONFIG_HOME="${SOLOIST_DATA_DIR}/.config"
mkdir -p "${XDG_CONFIG_HOME}/pulse"

# Everything this script and its children (soloist, ffmpeg, the relay)
# print goes to a dedicated per-player log file from here on, in addition
# to wherever this process's stdout/stderr was already headed (which, when
# launched via Proc::Background from inside Lyrion, may not go anywhere
# you can easily see). This is the file to check when a specific player's
# device doesn't show up in Spotify: Soloist's own "ready" / "waiting for
# login" / error lines land here directly.
LOG_FILE="${LOG_FILE:-${SOLOIST_CACHE_DIR}/bridge.log}"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== bridge starting $(date -Iseconds) (log: $LOG_FILE) ==="
echo "HOME=${HOME} XDG_CONFIG_HOME=${XDG_CONFIG_HOME}"

SOLOIST_PID=""
SILENCE_PID=""
FFMPEG_SUP_PID=""
RELAY_PID=""
SINK_ROUTER_PID=""

cleanup() {
	trap - EXIT TERM INT
	[ -n "$SINK_ROUTER_PID" ] && kill "$SINK_ROUTER_PID" 2>/dev/null
	[ -n "$RELAY_PID" ]      && kill "$RELAY_PID"      2>/dev/null
	[ -n "$FFMPEG_SUP_PID" ] && kill "$FFMPEG_SUP_PID" 2>/dev/null
	[ -n "$SILENCE_PID" ]    && kill "$SILENCE_PID"    2>/dev/null
	[ -n "$SOLOIST_PID" ]    && kill "$SOLOIST_PID"    2>/dev/null
	wait 2>/dev/null
	exit 0
}
trap cleanup EXIT TERM INT

log() { echo "[soloist-bridge] $*" >&2; }

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
	log "ERROR: $PYTHON_BIN not found -- the relay needs Python 3"
	exit 1
fi

# ---------------------------------------------------------------------------
# 1. PipeWire/PulseAudio null-sink (idempotent)
# ---------------------------------------------------------------------------
if ! command -v pactl >/dev/null 2>&1; then
	log "ERROR: pactl not found -- no PulseAudio/PipeWire-pulse server available."
	log "Install one, e.g.: sudo apt install -y pulseaudio pulseaudio-utils"
	exit 1
fi

if ! pactl info >/dev/null 2>&1; then
	log "ERROR: pactl found but can't reach a running server."
	exit 1
fi

if ! pactl list short sinks 2>/dev/null | grep -q "\b${PIPEWIRE_SINK}\b"; then
	log "creating null-sink '${PIPEWIRE_SINK}'"
	pactl load-module module-null-sink \
		sink_name="${PIPEWIRE_SINK}" \
		sink_properties=device.description="${PIPEWIRE_SINK}" \
		>/dev/null 2>&1
fi

# On a plain-PulseAudio host (no real PipeWire daemon), Soloist's own docs
# say --pipewire-device is silently ignored and it falls back to whatever
# PulseAudio's default sink is. We can't just set our sink as PulseAudio's
# default here: with multiple per-player instances possibly starting
# concurrently, "default sink" is one global value they'd all race over,
# and whichever instance's bridge script runs last would win for everyone
# else too. Instead, wait for Soloist's own PulseAudio stream to appear
# and move it to our sink explicitly, by matching its process ID.

# Keep the sink continuously "warm" so it never suspends mid-capture.
if command -v pacat >/dev/null 2>&1; then
	pacat --playback -d "${PIPEWIRE_SINK}" --rate=44100 --channels=2 --format=s16le < /dev/zero &
	SILENCE_PID=$!
	log "keeping '${PIPEWIRE_SINK}' warm with silence (pid $SILENCE_PID)"
else
	log "WARNING: pacat not found -- sink may suspend when idle"
fi

# ---------------------------------------------------------------------------
# 2. Launch Soloist
# ---------------------------------------------------------------------------
log "starting soloist: device='${DEVICE_NAME}' sink=${PIPEWIRE_SINK} ws=${WS_ENDPOINT} data-dir=${SOLOIST_DATA_DIR}"
"$SOLOIST_BIN" \
	--device-name "$DEVICE_NAME" \
	--api-key "$SOLOIST_API_KEY" \
	--data-dir "$SOLOIST_DATA_DIR" \
	--cache-dir "$SOLOIST_CACHE_DIR" \
	--pipewire-device "$PIPEWIRE_SINK" \
	--ws "$WS_ENDPOINT" &
SOLOIST_PID=$!

sleep 2

if ! kill -0 "$SOLOIST_PID" 2>/dev/null; then
	log "soloist exited immediately -- check API key / binary path / glibc compatibility"
fi

# Set the Connect session's baseline once at startup. Lyrion's mixer volume
# remains local and is never forwarded after this initial Soloist setting.
if "$SOLOIST_BIN" ctl -w "$WS_ENDPOINT" volume "$SOLOIST_INITIAL_VOLUME" >/dev/null 2>&1; then
	log "set Soloist session volume to ${SOLOIST_INITIAL_VOLUME}%"
else
	log "WARNING: couldn't set initial Soloist session volume on ${WS_ENDPOINT}"
fi

# Explicitly route Soloist's PulseAudio stream to our sink, safe under
# concurrent per-player instances (unlike relying on "default sink" -- see
# comment above). Real PipeWire with --pipewire-device already routes
# correctly on its own; this is a no-op fallback net in that case.
#
# This runs as an ONGOING background watcher for the bridge's whole
# lifetime, not a one-shot check: Soloist doesn't create its actual
# PulseAudio playback stream at process startup, only once real playback
# actually begins -- which can happen an arbitrary amount of time later
# (whenever you hit play in the Spotify app). A one-shot check shortly
# after launch can easily miss it entirely.
sink_router() {
	local target_index=""
	while kill -0 "$SOLOIST_PID" 2>/dev/null; do
		local listing
		listing="$(pactl list sink-inputs 2>/dev/null)"

		local sink_input_id
		sink_input_id="$(echo "$listing" | awk -v pid="$SOLOIST_PID" '
			BEGIN { RS="" }
			$0 ~ "application.process.id = \"" pid "\"" {
				if (match($0, /Sink Input #[0-9]+/)) {
					s = substr($0, RSTART, RLENGTH)
					sub(/Sink Input #/, "", s)
					print s
					exit
				}
			}
		')"

		if [ -n "$sink_input_id" ]; then
			target_index="$(pactl list short sinks 2>/dev/null | awk -v name="$PIPEWIRE_SINK" '$2==name{print $1}')"

			local current_sink
			current_sink="$(echo "$listing" | awk -v want="$sink_input_id" '
				BEGIN { RS="" }
				{
					if (match($0, /Sink Input #[0-9]+/)) {
						idstr = substr($0, RSTART, RLENGTH)
						sub(/Sink Input #/, "", idstr)
						if (idstr+0 == want+0) {
							if (match($0, /\n[ \t]*Sink: [0-9]+/)) {
								s = substr($0, RSTART, RLENGTH)
								sub(/.*Sink: /, "", s)
								print s
							}
						}
					}
				}
			')"

			if [ -n "$target_index" ] && [ "$current_sink" != "$target_index" ]; then
				log "routing soloist's PulseAudio stream (sink-input #${sink_input_id}) to '${PIPEWIRE_SINK}' (was sink #${current_sink:-?})"
				pactl move-sink-input "$sink_input_id" "$PIPEWIRE_SINK" 2>/dev/null
			fi
		fi

		sleep 2
	done
}

sink_router &
SINK_ROUTER_PID=$!

# ---------------------------------------------------------------------------
# 3. Set up the FIFO and start the relay (persistent, independent of ffmpeg
#    restarts and of how many/which HTTP clients connect).
# ---------------------------------------------------------------------------
[ -p "$FIFO_PATH" ] || { rm -f "$FIFO_PATH"; mkfifo "$FIFO_PATH"; }

case "$FORMAT" in
	flac)
		# Live FLAC should emit frames promptly rather than favoring archive
		# compression, otherwise Lyrion can wait several seconds for audio.
		ENCODE_ARGS=(-c:a flac -compression_level 0)
		MUX_ARGS=(-flush_packets 1)
		MUX_FORMAT="flac"
		CONTENT_TYPE="audio/flac"
		;;
	*)
		ENCODE_ARGS=(-c:a libmp3lame -b:a "$BITRATE")
		MUX_ARGS=()
		FORMAT="mp3"
		MUX_FORMAT="mp3"
		CONTENT_TYPE="audio/mpeg"
		;;
esac

log "starting relay on ${RELAY_BIND}:${RELAY_PORT} (content-type ${CONTENT_TYPE})"
"$PYTHON_BIN" "$RELAY_SCRIPT" \
	--fifo "$FIFO_PATH" \
	--port "$RELAY_PORT" \
	--bind "$RELAY_BIND" \
	--content-type "$CONTENT_TYPE" &
RELAY_PID=$!

sleep 1
if ! kill -0 "$RELAY_PID" 2>/dev/null; then
	log "ERROR: relay failed to start -- check python3 is available and the port isn't in use"
	exit 1
fi

# ---------------------------------------------------------------------------
# 4. Capture the sink's monitor ONCE and write continuously into the FIFO.
#    (One persistent capture connection regardless of how many HTTP
#    listeners come and go -- restarting the PulseAudio capture on every
#    listener connect/disconnect is what caused corrupted timestamps in an
#    earlier version of this bridge.) ffmpeg itself still gets its own
#    restart loop for resilience against transient Pulse/relay hiccups --
#    the FIFO means that doesn't disturb already-connected HTTP clients.
# ---------------------------------------------------------------------------
ffmpeg_supervisor() {
	CUR_FFMPEG_PID=""
	trap '[ -n "$CUR_FFMPEG_PID" ] && kill "$CUR_FFMPEG_PID" 2>/dev/null; exit 0' TERM INT

	while kill -0 "$SOLOIST_PID" 2>/dev/null; do
		"$FFMPEG_BIN" -nostdin -hide_banner -loglevel warning -y \
			-fflags +genpts -use_wallclock_as_timestamps 1 \
			-f pulse -i "${PIPEWIRE_SINK}.monitor" \
			-af "aresample=async=1:min_hard_comp=0.100000:first_pts=0" \
			"${ENCODE_ARGS[@]}" \
			"${MUX_ARGS[@]}" \
			-f "$MUX_FORMAT" \
			"$FIFO_PATH" &
		CUR_FFMPEG_PID=$!
		wait "$CUR_FFMPEG_PID"
		CUR_FFMPEG_PID=""

		if kill -0 "$SOLOIST_PID" 2>/dev/null; then
			log "ffmpeg exited -- restarting capture in 2s (relay/clients unaffected)"
			sleep 2
		fi
	done
}

ffmpeg_supervisor &
FFMPEG_SUP_PID=$!

log "stream ready: http://$(hostname -I 2>/dev/null | awk '{print $1}'):${RELAY_PORT}/soloist.${FORMAT}"

# ---------------------------------------------------------------------------
# Supervise: only Soloist dying is fatal for the whole bridge.
# ---------------------------------------------------------------------------
while kill -0 "$SOLOIST_PID" 2>/dev/null; do
	sleep 3
done

wait "$SOLOIST_PID" 2>/dev/null
code=$?
if [ "$code" = "10" ]; then
	log "soloist build expired (exit code 10) -- install a newer build"
else
	log "soloist exited (code $code)"
fi

log "shutting down bridge"
cleanup
