#!/bin/sh
#
# soloist-bridge.sh -- direct LMS audio pipeline. Launched (and
# supervised) by Plugin.pm via Proc::Background, configured entirely
# through environment variables it sets.
#
# Audio path:
#   - Pulse backend: PipeWire/PulseAudio null-sink -> parec S16LE capture ->
#     direct LMS FIFO (PCM) or bounded PCM source pump (FLAC/MP3)
#   - pcm-shim backend: contrib/experimental-pcm-shim's libpulse.so.0
#     replacement writes S16LE to the direct FIFO or compressed-format source
#     pump. No Pulse/PipeWire server needed -- only the shim's own build-time
#     dependency on libpulse-dev headers (see
#     contrib/experimental-pcm-shim/README.md).
#     Opt-in and still less validated than the Pulse/PipeWire backend.
# ProtocolHandler.pm opens the final FIFO directly. A bridge-lifetime guard
# keeps it alive while capture restarts, without an HTTP listener or encoder.
#
# Metadata is NOT handled here -- Plugin.pm consumes Soloist's pushed
# `ctl trace` event stream (with an occasional snapshot resync fallback)
# and writes into Lyrion's native metadata mechanism.
#
# Required env vars: SOLOIST_BIN DEVICE_NAME SOLOIST_API_KEY
# Optional (defaulted below): FORMAT WS_PORT SOLOIST_DATA_DIR
#                     SOLOIST_CACHE_DIR FIFO_PATH
#                     SOLOIST_AUDIO_BACKEND PIPEWIRE_SINK
#                     SOLOIST_PCM_SHIM_DIR
#                     SOLOIST_PCM_SHIM_LOG
#                     SOLOIST_PCM_SHIM_RING_MS SOLOIST_PCM_SHIM_CONTROL
#                     SOLOIST_PCM_SHIM_ACK
#                     SOLOIST_RUNTIME_LIB_DIR SOLOIST_RUNTIME_LOADER

set -u

: "${SOLOIST_BIN:?SOLOIST_BIN is required}"
: "${DEVICE_NAME:?DEVICE_NAME is required}"
: "${SOLOIST_API_KEY:?SOLOIST_API_KEY is required (plugin settings -> Soloist API key)}"

FORMAT="${FORMAT:-mp3}"
SOLOIST_AUDIO_BACKEND="${SOLOIST_AUDIO_BACKEND:-pcm-shim}"
PIPEWIRE_SINK="${PIPEWIRE_SINK:-}"
SOLOIST_INITIAL_VOLUME="${SOLOIST_INITIAL_VOLUME:-100}"
WS_PORT="${WS_PORT:-9091}"
SOLOIST_DATA_DIR="${SOLOIST_DATA_DIR:-$HOME/.local/share/soloist-lyrion}"
SOLOIST_CACHE_DIR="${SOLOIST_CACHE_DIR:-$HOME/.cache/soloist-lyrion}"
FIFO_PATH="${FIFO_PATH:-/tmp/soloist-audio.fifo}"
PCM_SOURCE_FIFO_PATH="${PCM_SOURCE_FIFO_PATH:-${SOLOIST_CACHE_DIR}/pcm-source.fifo}"
SOLOIST_PCM_SHIM_DIR="${SOLOIST_PCM_SHIM_DIR:-}"
SOLOIST_PCM_SHIM_LOG="${SOLOIST_PCM_SHIM_LOG:-1}"
SOLOIST_DELAY_DIAGNOSTICS="${SOLOIST_DELAY_DIAGNOSTICS:-0}"
SOLOIST_PCM_SHIM_RING_MS="${SOLOIST_PCM_SHIM_RING_MS:-200}"
SOLOIST_PCM_SHIM_CONTROL="${SOLOIST_PCM_SHIM_CONTROL:-${SOLOIST_CACHE_DIR}/pcm-shim.control}"
SOLOIST_PCM_SHIM_ACK="${SOLOIST_PCM_SHIM_ACK:-${SOLOIST_CACHE_DIR}/pcm-shim.ack}"
SOLOIST_PCM_PUMP_ACK="${SOLOIST_PCM_PUMP_ACK:-${SOLOIST_CACHE_DIR}/pcm-pump.ack}"
SOLOIST_PCM_PUMP_PERL="${SOLOIST_PCM_PUMP_PERL:-perl}"
SOLOIST_PCM_PUMP_SCRIPT="${SOLOIST_PCM_PUMP_SCRIPT:-}"
SOLOIST_PCM_PUMP_BUFFER_MS="${SOLOIST_PCM_PUMP_BUFFER_MS:-800}"
SOLOIST_PCM_SHIM_BUILD="${SOLOIST_PCM_SHIM_BUILD:-2026-11-28.1-fifo64}"
SOLOIST_RUNTIME_LIB_DIR="${SOLOIST_RUNTIME_LIB_DIR:-}"
SOLOIST_RUNTIME_LOADER="${SOLOIST_RUNTIME_LOADER:-}"
WS_ENDPOINT="127.0.0.1:${WS_PORT}"

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

# Everything this script and its children
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
echo "=== bridge starting $(date '+%Y-%m-%dT%H:%M:%S%z') (log: $LOG_FILE) ==="
echo "HOME=${HOME} XDG_CONFIG_HOME=${XDG_CONFIG_HOME}"
# Self-identify the script actually being executed, so a pasted log can
# always answer "is this really the file I think was deployed?" without a
# separate SSH round-trip to grep/diff/sha1sum it by hand.
_SELF_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
echo "[soloist-bridge] running script: ${_SELF_PATH} (size=$(wc -c < "${_SELF_PATH}" 2>/dev/null || echo unknown) bytes, lines=$(wc -l < "${_SELF_PATH}" 2>/dev/null || echo unknown))"
echo "[soloist-bridge] bridge process: pid=$$ parent=${PPID:-unknown}"

SOLOIST_PID=""
SILENCE_PID=""
CAPTURE_PID=""
SINK_ROUTER_PID=""
PCM_PUMP_PID=""
BRIDGE_OWNER_DIR="${SOLOIST_CACHE_DIR}/bridge-owner"
BRIDGE_OWNER_PID_FILE="${BRIDGE_OWNER_DIR}/pid"
OWNS_BRIDGE_LOCK=0
ADOPTED_SOLOIST=0

cleanup() {
	reason="${1:-unspecified cleanup}"
	status="${2:-0}"
	trap - EXIT TERM INT
	echo "[soloist-bridge] cleanup reason: ${reason} (bridge_pid=$$ soloist_pid=${SOLOIST_PID:-none})" >&2
	[ -n "$SINK_ROUTER_PID" ] && kill "$SINK_ROUTER_PID" 2>/dev/null
	[ -n "$CAPTURE_PID" ]    && kill "$CAPTURE_PID"    2>/dev/null
	[ -n "$PCM_PUMP_PID" ]   && kill "$PCM_PUMP_PID"   2>/dev/null
	[ -n "$SILENCE_PID" ]    && kill "$SILENCE_PID"    2>/dev/null
	[ -n "$SOLOIST_PID" ]    && kill "$SOLOIST_PID"    2>/dev/null
	wait 2>/dev/null
	if [ "$OWNS_BRIDGE_LOCK" = "1" ]; then
		owner_pid="$(cat "$BRIDGE_OWNER_PID_FILE" 2>/dev/null || true)"
		if [ "$owner_pid" = "$$" ]; then
			rm -f "$BRIDGE_OWNER_PID_FILE"
			rmdir "$BRIDGE_OWNER_DIR" 2>/dev/null || true
		fi
	fi
	exit "$status"
}
trap 'status=$?; cleanup "shell EXIT status $status" "$status"' EXIT
trap 'cleanup "received TERM" 143' TERM
trap 'cleanup "received INT" 130' INT

log() { echo "[soloist-bridge] $*" >&2; }

acquire_bridge_owner() {
	while :; do
		if mkdir "$BRIDGE_OWNER_DIR" 2>/dev/null; then
			printf '%s\n' "$$" > "$BRIDGE_OWNER_PID_FILE"
			OWNS_BRIDGE_LOCK=1
			log "acquired bridge ownership for data directory '$SOLOIST_DATA_DIR' (pid $$)"
			return
		fi

		owner_pid="$(cat "$BRIDGE_OWNER_PID_FILE" 2>/dev/null || true)"
		if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
			log "bridge owner pid $owner_pid is already supervising '$SOLOIST_DATA_DIR'; waiting instead of starting a duplicate"
			while kill -0 "$owner_pid" 2>/dev/null; do
				sleep 1
			done
			log "previous bridge owner pid $owner_pid exited; taking ownership"
		else
			log "removing stale bridge ownership for '$SOLOIST_DATA_DIR' (recorded pid ${owner_pid:-unknown})"
		fi
		rm -f "$BRIDGE_OWNER_PID_FILE"
		rmdir "$BRIDGE_OWNER_DIR" 2>/dev/null || true
	done
}

acquire_bridge_owner

OWNER_FINDER="$(dirname "$_SELF_PATH")/find-soloist-owner.sh"
EXISTING_SOLOIST_PID=""
if [ -f "$OWNER_FINDER" ]; then
	EXISTING_SOLOIST_PID="$(sh "$OWNER_FINDER" "$SOLOIST_DATA_DIR" 2>/dev/null || true)"
fi
if [ -n "$EXISTING_SOLOIST_PID" ] && kill -0 "$EXISTING_SOLOIST_PID" 2>/dev/null; then
	ADOPTED_SOLOIST=1
	log "adopting existing Soloist pid $EXISTING_SOLOIST_PID for data directory '$SOLOIST_DATA_DIR'; no duplicate process will be started"
fi

case "$SOLOIST_AUDIO_BACKEND" in
	pulse)
		: "${PIPEWIRE_SINK:?PIPEWIRE_SINK is required when SOLOIST_AUDIO_BACKEND=pulse}"
		;;
	pcm-shim)
		: "${SOLOIST_PCM_SHIM_DIR:?SOLOIST_PCM_SHIM_DIR is required when SOLOIST_AUDIO_BACKEND=pcm-shim (directory containing the built libpulse.so.0 from contrib/experimental-pcm-shim)}"
		SOLOIST_PCM_SHIM_LIB="${SOLOIST_PCM_SHIM_DIR}/libpulse.so.0"
		if [ ! -d "$SOLOIST_PCM_SHIM_DIR" ]; then
			log "ERROR: shim directory '$SOLOIST_PCM_SHIM_DIR' does not exist or is not accessible to the LMS service user"
			exit 1
		fi
		if [ ! -x "$SOLOIST_PCM_SHIM_DIR" ]; then
			log "ERROR: shim directory '$SOLOIST_PCM_SHIM_DIR' exists but is not searchable/executable by the LMS service user; avoid /root and use a world-readable path"
			exit 1
		fi
		if [ ! -e "$SOLOIST_PCM_SHIM_LIB" ]; then
			log "ERROR: '$SOLOIST_PCM_SHIM_LIB' not found -- build it first: cd contrib/experimental-pcm-shim && make"
			exit 1
		fi
		if [ ! -f "$SOLOIST_PCM_SHIM_LIB" ]; then
			log "ERROR: '$SOLOIST_PCM_SHIM_LIB' exists but is not a regular file"
			exit 1
		fi
		if [ ! -r "$SOLOIST_PCM_SHIM_LIB" ]; then
			log "ERROR: '$SOLOIST_PCM_SHIM_LIB' exists but is not readable by the LMS service user; avoid /root and fix permissions"
			exit 1
		fi
		;;
	*)
		log "ERROR: unsupported SOLOIST_AUDIO_BACKEND '$SOLOIST_AUDIO_BACKEND' (expected pulse or pcm-shim)"
		exit 1
		;;
esac

if [ "$SOLOIST_AUDIO_BACKEND" = "pcm-shim" ] && [ "$ADOPTED_SOLOIST" != "1" ]; then
	rm -f "$SOLOIST_PCM_SHIM_CONTROL" "$SOLOIST_PCM_SHIM_ACK" "$SOLOIST_PCM_PUMP_ACK"
fi

# ---------------------------------------------------------------------------
# 1. Backend-specific audio setup
# ---------------------------------------------------------------------------
SOLOIST_AUDIO_TARGET_DESC=""
CAPTURE_MODE="s16le-direct"
CAPTURE_OUTPUT_PATH="$FIFO_PATH"

[ -p "$FIFO_PATH" ] || { rm -f "$FIFO_PATH"; mkfifo "$FIFO_PATH"; }
exec 3<> "$FIFO_PATH"
log "holding final LMS FIFO read/write guard on fd 3 for bridge lifetime"

if [ "$FORMAT" != "pcm" ]; then
	[ -p "$PCM_SOURCE_FIFO_PATH" ] || {
		rm -f "$PCM_SOURCE_FIFO_PATH"
		mkfifo "$PCM_SOURCE_FIFO_PATH"
	}
	exec 4<> "$PCM_SOURCE_FIFO_PATH"
	CAPTURE_OUTPUT_PATH="$PCM_SOURCE_FIFO_PATH"
	if [ -z "$SOLOIST_PCM_PUMP_SCRIPT" ] || [ ! -f "$SOLOIST_PCM_PUMP_SCRIPT" ]; then
		log "ERROR: compressed output requires the PCM pump at '${SOLOIST_PCM_PUMP_SCRIPT:-unset}'"
		exit 1
	fi
	if ! command -v "$SOLOIST_PCM_PUMP_PERL" >/dev/null 2>&1 && [ ! -x "$SOLOIST_PCM_PUMP_PERL" ]; then
		log "ERROR: compressed output requires Perl at '$SOLOIST_PCM_PUMP_PERL'"
		exit 1
	fi
	rm -f "$SOLOIST_PCM_PUMP_ACK"
	pcm_pump_supervisor() {
		CUR_PUMP_PID=""
		trap '[ -n "$CUR_PUMP_PID" ] && kill "$CUR_PUMP_PID" 2>/dev/null; exit 0' TERM INT
		while :; do
			log "starting bounded S16LE pump ${PCM_SOURCE_FIFO_PATH} > ${FIFO_PATH}"
			env \
				SOLOIST_PCM_PUMP_SOURCE="$PCM_SOURCE_FIFO_PATH" \
				SOLOIST_PCM_PUMP_OUTPUT="$FIFO_PATH" \
				SOLOIST_PCM_PUMP_CONTROL="$SOLOIST_PCM_SHIM_CONTROL" \
				SOLOIST_PCM_PUMP_SHIM_ACK="$SOLOIST_PCM_SHIM_ACK" \
				SOLOIST_PCM_PUMP_ACK="$SOLOIST_PCM_PUMP_ACK" \
				SOLOIST_PCM_PUMP_BUFFER_MS="$SOLOIST_PCM_PUMP_BUFFER_MS" \
				"$SOLOIST_PCM_PUMP_PERL" "$SOLOIST_PCM_PUMP_SCRIPT" 3>&- 4>&- &
			CUR_PUMP_PID=$!
			wait "$CUR_PUMP_PID"
			PUMP_STATUS=$?
			CUR_PUMP_PID=""
			log "PCM pump exited with status $PUMP_STATUS -- restarting in 0.2s"
			sleep 0.2
		done
	}
	pcm_pump_supervisor &
	PCM_PUMP_PID=$!
	log "holding raw S16LE source FIFO guard on fd 4; pump supervisor pid $PCM_PUMP_PID"
fi

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

	if ! pactl list short sinks 2>/dev/null | awk -v name="$PIPEWIRE_SINK" '$2 == name { found=1 } END { exit !found }'; then
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

	SOLOIST_AUDIO_TARGET_DESC="Pulse/PipeWire sink ${PIPEWIRE_SINK}"
elif [ "$SOLOIST_AUDIO_BACKEND" = "pcm-shim" ]; then
	# The shim writes S16LE to the direct PCM FIFO or compressed-format source
	# pump. See
	# contrib/experimental-pcm-shim/README.md for the shim's status.
	#
	# SOLOIST_LD_LIBRARY_PATH is intentionally NOT `export`ed here, for the
	# same reason as the Pulse setup above: it must only affect Soloist's
	# own process (below), not every later command in this
	# script.
	SOLOIST_LD_LIBRARY_PATH="${SOLOIST_PCM_SHIM_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
	SOLOIST_SHIM_OUTPUT="$CAPTURE_OUTPUT_PATH"
	CAPTURE_MODE="pcm-shim-s16le-direct"
	SOLOIST_AUDIO_TARGET_DESC="pcm-shim S16LE FIFO ${CAPTURE_OUTPUT_PATH}"
	log "using experimental pcm-shim backend from '${SOLOIST_PCM_SHIM_DIR}', raw PCM output=${SOLOIST_SHIM_OUTPUT}"
	if command -v sha1sum >/dev/null 2>&1; then
		SHIM_FINGERPRINT="$(wc -c < "$SOLOIST_PCM_SHIM_LIB") bytes sha1=$(sha1sum "$SOLOIST_PCM_SHIM_LIB" | awk '{print $1}')"
	else
		SHIM_FINGERPRINT="$(wc -c < "$SOLOIST_PCM_SHIM_LIB") bytes"
	fi
	log "pcm-shim binary: ${SOLOIST_PCM_SHIM_LIB} (${SHIM_FINGERPRINT})"
	if ! LC_ALL=C grep -F "$SOLOIST_PCM_SHIM_BUILD" "$SOLOIST_PCM_SHIM_LIB" >/dev/null 2>&1; then
		log "ERROR: pcm-shim binary does not contain expected build marker '${SOLOIST_PCM_SHIM_BUILD}'; refusing stale or mismatched deployment"
		exit 1
	fi
	log "pcm-shim build marker verified in binary: ${SOLOIST_PCM_SHIM_BUILD}"
	log "pcm-shim settings: mode=live-ring-s16le ring=${SOLOIST_PCM_SHIM_RING_MS}ms control=${SOLOIST_PCM_SHIM_CONTROL} ack=${SOLOIST_PCM_SHIM_ACK} log=${SOLOIST_PCM_SHIM_LOG} max_tlength=${SOLOIST_SHIM_MAX_TLENGTH_MS:-0}ms"
fi

# ---------------------------------------------------------------------------
# 2. Launch Soloist
# ---------------------------------------------------------------------------
log "starting soloist: device='${DEVICE_NAME}' backend=${SOLOIST_AUDIO_BACKEND} target='${SOLOIST_AUDIO_TARGET_DESC}' ws=${WS_ENDPOINT} data-dir=${SOLOIST_DATA_DIR}"
if [ "$ADOPTED_SOLOIST" = "1" ]; then
	SOLOIST_PID="$EXISTING_SOLOIST_PID"
else
	if [ -n "$SOLOIST_RUNTIME_LOADER" ]; then
		if [ ! -f "$SOLOIST_RUNTIME_LOADER" ] || [ ! -x "$SOLOIST_RUNTIME_LOADER" ]; then
			log "ERROR: bundled Soloist runtime loader is unavailable at '$SOLOIST_RUNTIME_LOADER'"
			exit 1
		fi
		if [ ! -d "$SOLOIST_RUNTIME_LIB_DIR" ]; then
			log "ERROR: bundled Soloist runtime directory is unavailable at '$SOLOIST_RUNTIME_LIB_DIR'"
			exit 1
		fi
		if [ "$SOLOIST_AUDIO_BACKEND" = "pcm-shim" ]; then
			SOLOIST_LIBRARY_PATH="${SOLOIST_PCM_SHIM_DIR}:${SOLOIST_RUNTIME_LIB_DIR}"
			set -- "$SOLOIST_RUNTIME_LOADER" \
				--preload "$SOLOIST_PCM_SHIM_LIB" \
				--library-path "$SOLOIST_LIBRARY_PATH" \
				"$SOLOIST_BIN"
		else
			SOLOIST_LIBRARY_PATH="$SOLOIST_RUNTIME_LIB_DIR"
			set -- "$SOLOIST_RUNTIME_LOADER" --library-path "$SOLOIST_LIBRARY_PATH" "$SOLOIST_BIN"
		fi
	else
		set -- "$SOLOIST_BIN"
	fi

	if [ "$SOLOIST_AUDIO_BACKEND" = "pcm-shim" ]; then
		SOLOIST_SHIM_MAX_TLENGTH_MS="${SOLOIST_SHIM_MAX_TLENGTH_MS:-0}"
		if [ -n "$SOLOIST_RUNTIME_LOADER" ]; then
			SOLOIST_LD_PRELOAD=""
		else
			SOLOIST_LD_PRELOAD="$SOLOIST_PCM_SHIM_LIB${LD_PRELOAD:+:${LD_PRELOAD}}"
		fi
		env \
			LD_LIBRARY_PATH="$SOLOIST_LD_LIBRARY_PATH" \
			LD_PRELOAD="$SOLOIST_LD_PRELOAD" \
			SOLOIST_SHIM_OUT="$SOLOIST_SHIM_OUTPUT" \
			SOLOIST_SHIM_FORMAT=s16 \
			SOLOIST_SHIM_RATE=44100 \
			SOLOIST_SHIM_LOG="$SOLOIST_PCM_SHIM_LOG" \
			SOLOIST_SHIM_DELAY_TRACE="$SOLOIST_DELAY_DIAGNOSTICS" \
			SOLOIST_SHIM_RING_MS="$SOLOIST_PCM_SHIM_RING_MS" \
			SOLOIST_SHIM_CONTROL="$SOLOIST_PCM_SHIM_CONTROL" \
			SOLOIST_SHIM_ACK="$SOLOIST_PCM_SHIM_ACK" \
			SOLOIST_SHIM_MAX_TLENGTH_MS="$SOLOIST_SHIM_MAX_TLENGTH_MS" \
			"$@" \
			--device-name "$DEVICE_NAME" \
			--api-key "$SOLOIST_API_KEY" \
			--data-dir "$SOLOIST_DATA_DIR" \
			--cache-dir "$SOLOIST_CACHE_DIR" \
			--ws "$WS_ENDPOINT" &
	else
		"$@" \
		--device-name "$DEVICE_NAME" \
		--api-key "$SOLOIST_API_KEY" \
		--data-dir "$SOLOIST_DATA_DIR" \
		--cache-dir "$SOLOIST_CACHE_DIR" \
		--ws "$WS_ENDPOINT" \
		--pipewire-device "$PIPEWIRE_SINK" &
	fi
	SOLOIST_PID=$!
fi

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

if [ "$SOLOIST_AUDIO_BACKEND" = "pcm-shim" ] && [ "$READY" = "1" ]; then
	SHIM_REAL_PATH="$(readlink -f "$SOLOIST_PCM_SHIM_LIB" 2>/dev/null || echo "$SOLOIST_PCM_SHIM_LIB")"
	if [ ! -r "/proc/${SOLOIST_PID}/maps" ]; then
		log "ERROR: cannot inspect /proc/${SOLOIST_PID}/maps to verify the loaded PCM shim"
		cleanup "PCM shim load verification unavailable" 1
	fi
	SHIM_MAP="$(grep -F "$SHIM_REAL_PATH" "/proc/${SOLOIST_PID}/maps" 2>/dev/null | head -n 1 || true)"
	if [ -z "$SHIM_MAP" ]; then
		log "ERROR: Soloist pid ${SOLOIST_PID} did not map expected pcm-shim '${SHIM_REAL_PATH}'"
		log "loaded libpulse mappings: $(grep 'libpulse[^/]*\.so' "/proc/${SOLOIST_PID}/maps" 2>/dev/null | awk '{print $NF}' | sort -u | tr '\n' ' ' || true)"
		cleanup "expected PCM shim was not loaded" 1
	fi
	log "pcm-shim mapped by Soloist pid ${SOLOIST_PID}: ${SHIM_MAP}"
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
		target_index=""
		while kill -0 "$SOLOIST_PID" 2>/dev/null; do
			listing="$(pactl list sink-inputs 2>/dev/null)"

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
# 3. Complete capture setup.
# ---------------------------------------------------------------------------
if [ "$SOLOIST_AUDIO_BACKEND" = "pulse" ]; then
	if ! command -v parec >/dev/null 2>&1; then
		log "ERROR: parec not found -- the Pulse backend needs PulseAudio utilities"
		exit 1
	fi
fi

log "direct LMS stream FIFO ready at ${FIFO_PATH}; preparing capture pipeline (mode=${CAPTURE_MODE}, backend=${SOLOIST_AUDIO_BACKEND})"

# ---------------------------------------------------------------------------
# 4. Capture one continuous 44.1 kHz stereo S16LE stream. ProtocolHandler.pm
#    prepends a truthful WAV header and LMS performs any final conversion.
# ---------------------------------------------------------------------------
capture_supervisor() {
	CUR_CAPTURE_PID=""
	trap '[ -n "$CUR_CAPTURE_PID" ] && kill "$CUR_CAPTURE_PID" 2>/dev/null; exit 0' TERM INT

	while kill -0 "$SOLOIST_PID" 2>/dev/null; do
		log "starting S16LE capture from ${PIPEWIRE_SINK}.monitor > ${CAPTURE_OUTPUT_PATH}"
		parec --raw --rate=44100 --channels=2 --format=s16le \
			--latency-msec=300 --process-time-msec=50 \
			-d "${PIPEWIRE_SINK}.monitor" > "$CAPTURE_OUTPUT_PATH" 3>&- 4>&- &
		CUR_CAPTURE_PID=$!
		wait "$CUR_CAPTURE_PID"
		CAPTURE_STATUS=$?
		CUR_CAPTURE_PID=""

		if kill -0 "$SOLOIST_PID" 2>/dev/null; then
			log "${CAPTURE_MODE} capture exited with status ${CAPTURE_STATUS} -- restarting in 2s (LMS FIFO remains open)"
			sleep 2
		fi
	done
}

log "direct LMS S16LE stream ready: ${FIFO_PATH} (source=${CAPTURE_OUTPUT_PATH}, requested output=${FORMAT}, conversion owned by LMS)"
if [ "$SOLOIST_AUDIO_BACKEND" = "pcm-shim" ]; then
	log "pcm-shim writes S16LE to ${CAPTURE_OUTPUT_PATH}; monitoring Soloist process"
	if [ "$ADOPTED_SOLOIST" = "1" ]; then
		while kill -0 "$SOLOIST_PID" 2>/dev/null; do
			sleep 1
		done
		code=0
	else
		wait "$SOLOIST_PID" 2>/dev/null
		code=$?
	fi
else
	capture_supervisor
	if [ "$ADOPTED_SOLOIST" = "1" ]; then
		code=0
	else
		wait "$SOLOIST_PID" 2>/dev/null
		code=$?
	fi
fi
if [ "$ADOPTED_SOLOIST" = "1" ]; then
	log "adopted soloist pid $SOLOIST_PID exited"
elif [ "$code" = "10" ]; then
	log "soloist build expired (exit code 10) -- install a newer build"
else
	log "soloist exited (code $code)"
fi

log "shutting down bridge"
cleanup "Soloist process exited with code $code" 0
