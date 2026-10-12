#!/usr/bin/env bash
#
# soloist-bridge.sh -- pure audio pipeline, no Icecast. Launched (and
# supervised) by Plugin.pm via Proc::Background, configured entirely
# through environment variables it sets.
#
# Audio path:
#   - Pulse backend: PipeWire/PulseAudio null-sink -> ffmpeg capture of that
#     sink's monitor -> named pipe -> audio-relay.py
#   - ALSA backend: bundled shim or wrapper -> ALSA playback device ->
#     bridge capture from the matching ALSA loopback device -> named pipe
#     -> audio-relay.py
# The relay role is identical either way and replaces Icecast; see
# Bin/audio-relay.py for why the relay reads from a FIFO.
#
# Metadata is NOT handled here -- Plugin.pm consumes Soloist's pushed
# `ctl trace` event stream (with an occasional snapshot resync fallback)
# and writes into Lyrion's native metadata mechanism.
#
# Required env vars: SOLOIST_BIN DEVICE_NAME SOLOIST_API_KEY
# Optional (defaulted below): FORMAT BITRATE WS_PORT SOLOIST_DATA_DIR
#                     SOLOIST_CACHE_DIR RELAY_PORT RELAY_BIND FIFO_PATH
#                     PYTHON_BIN SOLOIST_AUDIO_BACKEND PIPEWIRE_SINK
#                     ALSA_PLAYBACK_DEVICE ALSA_CAPTURE_DEVICE
#                     RELAY_READY_FILE RELAY_FLUSH_FILE FFMPEG_BIN
#                     SOLOIST_SHIM_DIR

set -u
set -o pipefail

: "${SOLOIST_BIN:?SOLOIST_BIN is required}"
: "${DEVICE_NAME:?DEVICE_NAME is required}"
: "${SOLOIST_API_KEY:?SOLOIST_API_KEY is required (plugin settings -> Soloist API key)}"

FORMAT="${FORMAT:-mp3}"
BITRATE="${BITRATE:-320k}"
SOLOIST_AUDIO_BACKEND="${SOLOIST_AUDIO_BACKEND:-pulse}"
PIPEWIRE_SINK="${PIPEWIRE_SINK:-}"
ALSA_PLAYBACK_DEVICE="${ALSA_PLAYBACK_DEVICE:-}"
ALSA_CAPTURE_DEVICE="${ALSA_CAPTURE_DEVICE:-}"
SOLOIST_INITIAL_VOLUME="${SOLOIST_INITIAL_VOLUME:-100}"
WS_PORT="${WS_PORT:-9091}"
SOLOIST_DATA_DIR="${SOLOIST_DATA_DIR:-$HOME/.local/share/soloist-lyrion}"
SOLOIST_CACHE_DIR="${SOLOIST_CACHE_DIR:-$HOME/.cache/soloist-lyrion}"
RELAY_PORT="${RELAY_PORT:-9077}"
RELAY_BIND="${RELAY_BIND:-0.0.0.0}"
FIFO_PATH="${FIFO_PATH:-/tmp/soloist-audio.fifo}"
RELAY_READY_FILE="${RELAY_READY_FILE:-${SOLOIST_CACHE_DIR}/relay.ready}"
RELAY_FLUSH_FILE="${RELAY_FLUSH_FILE:-${SOLOIST_CACHE_DIR}/relay.flush}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
SOLOIST_SHIM_DIR="${SOLOIST_SHIM_DIR:-}"
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
# print goes to a dedicated per-player log file from here on. This is the
# file to check when a specific player's device doesn't show up in
# Spotify: Soloist's own "ready" / "waiting for login" / error lines land
# here directly.
#
# Deliberately NOT `exec > >(tee -a "$LOG_FILE") 2>&1`: GNU tee fully
# buffers its output (typically ~4KB) whenever its stdout isn't a TTY,
# which is always true here since nothing reads this script's own
# stdout/stderr. That silently delays recent log lines -- including ones
# that always print on a working code path -- from ever reaching the file
# while the process is still alive and otherwise working fine, which made
# earlier debugging sessions look like code wasn't running when it was.
# A plain append redirection writes directly, with no buffering process
# in between, so every log line lands immediately.
LOG_FILE="${LOG_FILE:-${SOLOIST_CACHE_DIR}/bridge.log}"
exec >> "$LOG_FILE" 2>&1
echo "=== bridge starting $(date -Iseconds) (log: $LOG_FILE) ==="
echo "HOME=${HOME} XDG_CONFIG_HOME=${XDG_CONFIG_HOME}"
# Self-identify the script actually being executed, so a pasted log can
# always answer "is this really the file I think was deployed?" without a
# separate SSH round-trip to grep/diff/sha1sum it by hand.
_SELF_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
echo "[soloist-bridge] running script: ${_SELF_PATH} (mtime=$(date -r "${_SELF_PATH}" -Iseconds 2>/dev/null || echo unknown), size=$(wc -c < "${_SELF_PATH}" 2>/dev/null || echo unknown) bytes, lines=$(wc -l < "${_SELF_PATH}" 2>/dev/null || echo unknown))"

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

# Resolve a bare ALSA card *name* (e.g. "Loopback" in "hw:Loopback,0,0") to
# its numeric card index from /proc/asound/cards. ALSA's own name-based
# lookup (snd_config_get_card) fails -- silently, from apulse's point of
# view -- when two or more cards share the same name ("Cannot get card
# index for Loopback"), which can happen if snd-aloop was loaded more than
# once without unique id= values. Resolving to the numeric index here makes
# the device string unambiguous and avoids that silent playback/capture
# failure. Already-numeric prefixes (e.g. "hw:1,0,0") pass through unchanged.
_alsa_resolve_card_name() {
	local dev="$1"
	local prefix="${dev%%:*}"
	local rest="${dev#*:}"
	local card="${rest%%,*}"
	local remainder=""
	if [ "$rest" != "$card" ]; then
		remainder="${rest#*,}"
	fi

	case "$card" in
		''|*[!0-9]*) ;;
		*) printf '%s\n' "$dev"; return 0 ;;
	esac

	if [ ! -r /proc/asound/cards ]; then
		printf '%s\n' "$dev"
		return 0
	fi

	local all_ids=() all_idxs=() matches=() line idx id
	while IFS= read -r line; do
		if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]\[([^]]*)\]: ]]; then
			idx="${BASH_REMATCH[1]}"
			id="${BASH_REMATCH[2]}"
			id="${id%"${id##*[![:space:]]}"}"
			id="${id#"${id%%[![:space:]]*}"}"
			all_idxs+=("$idx")
			all_ids+=("$id")
			if [ "$id" = "$card" ]; then
				matches+=("$idx")
			fi
		fi
	done < /proc/asound/cards

	# No exact match -- fall back to a case-insensitive substring match
	# (e.g. the card is really named "Loopback 1" or "snd_aloop") before
	# giving up, since the exact driver-assigned id can vary by kernel/host.
	local fuzzy=0
	if [ "${#matches[@]}" -eq 0 ] && [ "${#all_ids[@]}" -gt 0 ]; then
		local lower_card i
		lower_card="${card,,}"
		for i in "${!all_ids[@]}"; do
			if [[ "${all_ids[$i],,}" == *"${lower_card}"* ]]; then
				matches+=("${all_idxs[$i]}")
				fuzzy=1
			fi
		done
	fi

	if [ "${#matches[@]}" -eq 0 ]; then
		local known="(none)"
		if [ "${#all_ids[@]}" -gt 0 ]; then
			known=""
			for i in "${!all_ids[@]}"; do
				known="${known}${known:+, }${all_idxs[$i]}='${all_ids[$i]}'"
			done
		fi
		log "WARNING: no ALSA card named '${card}' found in /proc/asound/cards (known cards: ${known}) -- leaving '${dev}' as-is; arecord/apulse may fail to open it"
		printf '%s\n' "$dev"
		return 0
	fi

	if [ "$fuzzy" -eq 1 ]; then
		log "WARNING: no ALSA card exactly named '${card}'; using substring match (indices: ${matches[*]}) instead -- check 'cat /proc/asound/cards' if this picks the wrong device"
	elif [ "${#matches[@]}" -gt 1 ]; then
		log "WARNING: ${#matches[@]} ALSA cards are named '${card}' (indices: ${matches[*]}) -- ALSA's name lookup is ambiguous for duplicate card names and can silently fail to open devices (e.g. 'Cannot get card index for ${card}'). Using the first match (index ${matches[0]}); rename the extra loopback instances (e.g. modprobe snd-aloop id=...) or configure a numeric device prefix to remove this ambiguity."
	fi

	if [ -n "$remainder" ]; then
		printf '%s:%s,%s\n' "$prefix" "${matches[0]}" "$remainder"
	else
		printf '%s:%s\n' "$prefix" "${matches[0]}"
	fi
}

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
	log "ERROR: $PYTHON_BIN not found -- the relay needs Python 3"
	exit 1
fi

case "$SOLOIST_AUDIO_BACKEND" in
	pulse)
		: "${PIPEWIRE_SINK:?PIPEWIRE_SINK is required when SOLOIST_AUDIO_BACKEND=pulse}"
		;;
	alsa)
		: "${ALSA_PLAYBACK_DEVICE:?ALSA_PLAYBACK_DEVICE is required when SOLOIST_AUDIO_BACKEND=alsa}"
		: "${ALSA_CAPTURE_DEVICE:?ALSA_CAPTURE_DEVICE is required when SOLOIST_AUDIO_BACKEND=alsa}"
		;;
	*)
		log "ERROR: unsupported SOLOIST_AUDIO_BACKEND '$SOLOIST_AUDIO_BACKEND' (expected pulse or alsa)"
		exit 1
		;;
esac

# ---------------------------------------------------------------------------
# 1. Backend-specific audio setup
# ---------------------------------------------------------------------------
CAPTURE_INPUT_ARGS=()
SOLOIST_AUDIO_TARGET_DESC=""
PCM_CAPTURE_ARGS=()
ARECORD_INPUT_ARGS=()
CAPTURE_MODE="ffmpeg"
RELAY_EXTRA_ARGS=()

if [ "$SOLOIST_AUDIO_BACKEND" = "pulse" ]; then
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

	CAPTURE_INPUT_ARGS=(-f pulse -i "${PIPEWIRE_SINK}.monitor")
	SOLOIST_AUDIO_TARGET_DESC="Pulse/PipeWire sink ${PIPEWIRE_SINK}"
else
	# The ALSA path is intentionally opt-in: Soloist still has no native ALSA
	# flag, so this mode uses either the bundled x86_64 libpulse shim or a
	# caller-provided wrapper/equivalent launcher that honors
	# APULSE_PLAYBACK_DEVICE.
	#
	# SOLOIST_LD_LIBRARY_PATH is intentionally NOT `export`ed here: it must
	# only affect Soloist's own process (below), not every later command in
	# this script. An `export` would leak into arecord/ffmpeg too, and the
	# shim's bundled libpulse.so.0 stub can shadow the *system* libpulse via
	# the dynamic linker for any later command, breaking unrelated ALSA
	# config hooks that dlopen the real libpulse (symptom: arecord failing
	# with "undefined symbol: pa_mainloop_new" and "Unknown PCM ...").
	SOLOIST_LD_LIBRARY_PATH=""
	SOLOIST_SHIM_ACTIVE=0
	if [ -n "$SOLOIST_SHIM_DIR" ] && [ -f "${SOLOIST_SHIM_DIR}/libpulse.so.0" ]; then
		SOLOIST_LD_LIBRARY_PATH="${SOLOIST_SHIM_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
		SOLOIST_SHIM_ACTIVE=1
		log "using bundled Soloist pulse shim from '${SOLOIST_SHIM_DIR}'"
	else
		log "no bundled Soloist pulse shim active; ALSA backend expects the configured soloist path to handle Pulse->ALSA itself"
	fi
	ALSA_PLAYBACK_DEVICE="$(_alsa_resolve_card_name "$ALSA_PLAYBACK_DEVICE")"
	ALSA_CAPTURE_DEVICE="$(_alsa_resolve_card_name "$ALSA_CAPTURE_DEVICE")"
	export APULSE_PLAYBACK_DEVICE="$(_alsa_resolve_card_name "${APULSE_PLAYBACK_DEVICE:-$ALSA_PLAYBACK_DEVICE}")"
	if ! command -v arecord >/dev/null 2>&1; then
		log "ERROR: arecord not found -- ALSA backend capture needs alsa-utils"
		exit 1
	fi
	if [ "$SOLOIST_SHIM_ACTIVE" = "1" ]; then
		# The bundled shim calls snd_pcm_open() directly on whatever string
		# is in APULSE_PLAYBACK_DEVICE (confirmed via its own APULSE_DIAG
		# log: "pcm open hw:1,0,0 failed: No such file or directory"), so
		# there is no "volumio" fallback name to work around -- it genuinely
		# opens our configured device string as-is. The capture side of this
		# very same loopback card already opens fine via "plughw:1,1,0", but
		# the raw "hw:1,0,0" (no plug layer) fails outright for playback on
		# at least some hosts/kernel versions of snd-aloop. Upgrade the
		# shim's playback device to plughw to match, which adds ALSA's plug
		# conversion/negotiation layer instead of requiring an exact direct
		# hardware open.
		case "$APULSE_PLAYBACK_DEVICE" in
			hw:*)
				SHIM_PLAYBACK_DEVICE="plughw:${APULSE_PLAYBACK_DEVICE#hw:}"
				log "bundled shim: upgrading playback device '${APULSE_PLAYBACK_DEVICE}' -> '${SHIM_PLAYBACK_DEVICE}' (raw ALSA 'hw:' open fails for this shim on some hosts; 'plughw:' adds the plug layer it needs)"
				export APULSE_PLAYBACK_DEVICE="$SHIM_PLAYBACK_DEVICE"
				;;
		esac

		# Diagnostic-only: the bundled shim supports APULSE_DIAG (verbose
		# pcm-open/connect logging to its own stderr, logged on EVERY
		# single Pulse API call, which lands in this player's bridge.log
		# since Soloist is a child of this script) and APULSE_YIELD_PATH
		# (dumps the raw audio frames it receives from Soloist to a file).
		# This was enabled unconditionally while chasing the original
		# silent-playback bug (now fixed above, confirmed by real audio
		# finally reaching the relay) and is now opt-in only
		# (SOLOIST_SHIM_DIAG=1 in the bridge's environment), off by
		# default: logging on every single API call is real per-callback
		# overhead on a real-time audio thread, which is exactly the kind
		# of thing that can cause audible glitches/dropouts on constrained
		# hardware (e.g. a Pi or low-power x86 box) -- leaving it on
		# unconditionally risked *causing* playback problems rather than
		# just diagnosing them.
		if [ "${SOLOIST_SHIM_DIAG:-0}" = "1" ]; then
			SOLOIST_SHIM_YIELD_PATH="${SOLOIST_CACHE_DIR}/shim-alsa-yield.raw"
			log "SOLOIST_SHIM_DIAG=1: enabling shim diagnostics; raw yield dump -> ${SOLOIST_SHIM_YIELD_PATH} (delete manually when done; adds per-call logging overhead -- leave off for normal use)"
		fi
	fi
	ARECORD_INPUT_ARGS=(arecord -c2 -f S16_LE -r 44100 -t raw --buffer-time=300000 --period-time=50000 -D "${ALSA_CAPTURE_DEVICE}")
	CAPTURE_INPUT_ARGS=(-f s16le -ar 44100 -ac 2 -i pipe:0)
	SOLOIST_AUDIO_TARGET_DESC="ALSA playback ${APULSE_PLAYBACK_DEVICE} / capture ${ALSA_CAPTURE_DEVICE}"
	log "using ALSA/apulse backend with APULSE_PLAYBACK_DEVICE='${APULSE_PLAYBACK_DEVICE}' and capture='${ALSA_CAPTURE_DEVICE}'"
fi

# ---------------------------------------------------------------------------
# 2. Launch Soloist
# ---------------------------------------------------------------------------
SOLOIST_ARGS=(
	--device-name "$DEVICE_NAME"
	--api-key "$SOLOIST_API_KEY"
	--data-dir "$SOLOIST_DATA_DIR"
	--cache-dir "$SOLOIST_CACHE_DIR"
	--ws "$WS_ENDPOINT"
)

if [ "$SOLOIST_AUDIO_BACKEND" = "pulse" ]; then
	SOLOIST_ARGS+=(--pipewire-device "$PIPEWIRE_SINK")
fi

log "starting soloist: device='${DEVICE_NAME}' backend=${SOLOIST_AUDIO_BACKEND} target='${SOLOIST_AUDIO_TARGET_DESC}' ws=${WS_ENDPOINT} data-dir=${SOLOIST_DATA_DIR}"
SOLOIST_ENV_PREFIX=()
if [ -n "${SOLOIST_LD_LIBRARY_PATH:-}" ]; then
	SOLOIST_ENV_PREFIX+=(LD_LIBRARY_PATH="$SOLOIST_LD_LIBRARY_PATH")
fi
if [ "${SOLOIST_SHIM_ACTIVE:-0}" = "1" ] && [ "${SOLOIST_SHIM_DIAG:-0}" = "1" ]; then
	SOLOIST_ENV_PREFIX+=(APULSE_DIAG=1 APULSE_YIELD_PATH="${SOLOIST_SHIM_YIELD_PATH}")
fi
if [ "${#SOLOIST_ENV_PREFIX[@]}" -gt 0 ]; then
	env "${SOLOIST_ENV_PREFIX[@]}" "$SOLOIST_BIN" "${SOLOIST_ARGS[@]}" &
else
	"$SOLOIST_BIN" "${SOLOIST_ARGS[@]}" &
fi
SOLOIST_PID=$!

# Poll for actual readiness instead of blindly sleeping a fixed amount.
# Soloist writes ws.port when its control WebSocket is really listening,
# which is the same discovery file used by `soloist ctl` itself.
READY=0
ELAPSED_MS=0
for _try in $(seq 1 40); do
	if [ -f "${SOLOIST_DATA_DIR}/ws.port" ]; then
		READY=1
		break
	fi
	if ! kill -0 "$SOLOIST_PID" 2>/dev/null; then
		break
	fi
	sleep 0.05
	ELAPSED_MS=$(( _try * 50 ))
done

if [ "$READY" = "1" ]; then
	log "soloist ready after ~${ELAPSED_MS}ms"
else
	log "soloist exited immediately or wasn't ready within 2s -- check API key / binary path / glibc compatibility"
fi

# Set the Connect session's baseline at startup. Plugin.pm also reapplies
# that configured level whenever this Soloist device later becomes active
# again, so reconnects don't inherit an old Spotify-side session volume.
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
#
# Poll at 0.3s so real playback gets moved onto the correct sink quickly
# even on plain PulseAudio hosts where Soloist briefly lands on the
# server's current default sink first.
if [ "$SOLOIST_AUDIO_BACKEND" = "pulse" ]; then
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

			sleep 0.3
		done
	}

	sink_router &
	SINK_ROUTER_PID=$!
fi

# ---------------------------------------------------------------------------
# 3. Set up the FIFO and start the relay (persistent, independent of ffmpeg
#    restarts and of how many/which HTTP clients connect).
# ---------------------------------------------------------------------------
[ -p "$FIFO_PATH" ] || { rm -f "$FIFO_PATH"; mkfifo "$FIFO_PATH"; }
rm -f "$RELAY_READY_FILE"
rm -f "$RELAY_FLUSH_FILE"

case "$FORMAT" in
	flac)
		: "${FFMPEG_BIN:?FFMPEG_BIN is required when FORMAT=flac}"
		# Live FLAC should emit frames promptly rather than favoring archive
		# compression, otherwise Lyrion can wait several seconds for audio.
		ENCODE_ARGS=(-c:a flac -compression_level 0)
		MUX_ARGS=(-flush_packets 1)
		MUX_FORMAT="flac"
		CONTENT_TYPE="audio/flac"
		STREAM_EXTENSION="flac"
		;;
	pcm)
		CAPTURE_MODE="pcm-direct"
		CONTENT_TYPE="audio/wav"
		STREAM_EXTENSION="wav"
		RELAY_EXTRA_ARGS+=(--wav-stream --wav-sample-rate 44100 --wav-channels 2 --wav-bits-per-sample 16)
		if [ "$SOLOIST_AUDIO_BACKEND" = "pulse" ]; then
			if ! command -v parec >/dev/null 2>&1; then
				log "ERROR: parec not found -- PCM direct mode on the Pulse backend needs PulseAudio utilities"
				exit 1
			fi
			PCM_CAPTURE_ARGS=(parec --raw --rate=44100 --channels=2 --format=s16le --latency-msec=300 --process-time-msec=50 -d "${PIPEWIRE_SINK}.monitor")
		else
			if ! command -v arecord >/dev/null 2>&1; then
				log "ERROR: arecord not found -- PCM direct mode on the ALSA backend needs alsa-utils"
				exit 1
			fi
			PCM_CAPTURE_ARGS=(arecord -c2 -f S16_LE -r 44100 -t raw --buffer-time=300000 --period-time=50000 -D "${ALSA_CAPTURE_DEVICE}")
		fi
		;;
	*)
		: "${FFMPEG_BIN:?FFMPEG_BIN is required when FORMAT=mp3}"
		ENCODE_ARGS=(-c:a libmp3lame -b:a "$BITRATE")
		MUX_ARGS=()
		FORMAT="mp3"
		MUX_FORMAT="mp3"
		CONTENT_TYPE="audio/mpeg"
		STREAM_EXTENSION="mp3"
		;;
esac

log "starting relay on ${RELAY_BIND}:${RELAY_PORT} (content-type ${CONTENT_TYPE})"
"$PYTHON_BIN" "$RELAY_SCRIPT" \
	--fifo "$FIFO_PATH" \
	--port "$RELAY_PORT" \
	--bind "$RELAY_BIND" \
	--content-type "$CONTENT_TYPE" \
	"${RELAY_EXTRA_ARGS[@]}" \
	--flush-file "$RELAY_FLUSH_FILE" \
	--ready-file "$RELAY_READY_FILE" &
RELAY_PID=$!

# Confirm that the relay is actually listening instead of sleeping a
# fixed amount and only checking whether the process still exists.
RELAY_READY=0
for _try in $(seq 1 10); do
	if ! kill -0 "$RELAY_PID" 2>/dev/null; then
		break
	fi
	if ( exec 3<>"/dev/tcp/127.0.0.1/${RELAY_PORT}" ) 2>/dev/null; then
		# IMPORTANT: this must stay a braced *group*, not a bare `exec`.
		# A bare top-level `exec 3>&- 3<&- 2>/dev/null` here would permanently
		# redirect this shell's own stderr to /dev/null for the rest of the
		# script (exec without a command changes the current shell's fd
		# table, it doesn't fork), silently swallowing every later log()
		# call (including every "starting ... capture" / "stream ready"
		# line) while already-forked children keep logging fine -- which is
		# exactly the "lines that must print never show up" bug this once
		# was. `{ ... } 2>/dev/null` scopes the stderr redirect to just the
		# fd-3 close, restoring fd 2 immediately afterwards.
		{ exec 3>&- 3<&-; } 2>/dev/null
		RELAY_READY=1
		break
	fi
	sleep 0.1
done

if [ "$RELAY_READY" != "1" ]; then
	log "ERROR: relay failed to start -- check python3 is available and the port isn't in use"
	exit 1
fi

log "relay confirmed ready, preparing capture pipeline (mode=${CAPTURE_MODE}, backend=${SOLOIST_AUDIO_BACKEND})"

# ---------------------------------------------------------------------------
# 4. Capture the backend output ONCE and write continuously into the FIFO.
#    (One persistent capture connection regardless of how many HTTP
#    listeners come and go -- restarting the capture on every
#    listener connect/disconnect is what caused corrupted timestamps in an
#    earlier version of this bridge.) For mp3/flac, ffmpeg still gets its
#    own restart loop for resilience against transient capture/relay hiccups.
#    For PCM/WAV, keep the path simpler and skip ffmpeg entirely: capture
#    raw 44.1 kHz stereo 16-bit PCM directly and let the relay prepend the
#    streaming WAV header for each client.
# ---------------------------------------------------------------------------
capture_supervisor() {
	CUR_CAPTURE_PID=""
	trap '[ -n "$CUR_CAPTURE_PID" ] && kill "$CUR_CAPTURE_PID" 2>/dev/null; exit 0' TERM INT

	while kill -0 "$SOLOIST_PID" 2>/dev/null; do
		if [ "$CAPTURE_MODE" = "pcm-direct" ]; then
			log "starting PCM capture: ${PCM_CAPTURE_ARGS[*]} > ${FIFO_PATH}"
			"${PCM_CAPTURE_ARGS[@]}" > "$FIFO_PATH" &
		elif [ "$SOLOIST_AUDIO_BACKEND" = "alsa" ]; then
			log "starting ALSA capture: ${ARECORD_INPUT_ARGS[*]} | ${FFMPEG_BIN} ... -f ${MUX_FORMAT} ${FIFO_PATH}"
			"${ARECORD_INPUT_ARGS[@]}" | \
				"$FFMPEG_BIN" -nostdin -hide_banner -loglevel warning -y \
					-fflags +genpts \
					"${CAPTURE_INPUT_ARGS[@]}" \
					"${ENCODE_ARGS[@]}" \
					"${MUX_ARGS[@]}" \
					-f "$MUX_FORMAT" \
					"$FIFO_PATH" &
		else
			log "starting ${CAPTURE_MODE} capture: ${FFMPEG_BIN} ... -f ${MUX_FORMAT} ${FIFO_PATH}"
			"$FFMPEG_BIN" -nostdin -hide_banner -loglevel warning -y \
				-fflags +genpts \
				"${CAPTURE_INPUT_ARGS[@]}" \
				"${ENCODE_ARGS[@]}" \
				"${MUX_ARGS[@]}" \
				-f "$MUX_FORMAT" \
				"$FIFO_PATH" &
		fi
		CUR_CAPTURE_PID=$!
		wait "$CUR_CAPTURE_PID"
		CAPTURE_STATUS=$?
		CUR_CAPTURE_PID=""

		if kill -0 "$SOLOIST_PID" 2>/dev/null; then
			log "${CAPTURE_MODE} capture exited with status ${CAPTURE_STATUS} -- restarting in 2s (relay/clients unaffected)"
			sleep 2
		fi
	done
}

log "stream ready: http://$(hostname -I 2>/dev/null | awk '{print $1}'):${RELAY_PORT}/soloist.${STREAM_EXTENSION}"
capture_supervisor

wait "$SOLOIST_PID" 2>/dev/null
code=$?
if [ "$code" = "10" ]; then
	log "soloist build expired (exit code 10) -- install a newer build"
else
	log "soloist exited (code $code)"
fi

log "shutting down bridge"
cleanup
