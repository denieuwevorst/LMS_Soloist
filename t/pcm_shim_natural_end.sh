#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
shim="$root/contrib/experimental-pcm-shim"
tmp="${TMPDIR:-/tmp}/soloist-shim-natural-end-$$"
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir "$tmp"
make -C "$shim" clean marker_client >/dev/null

run_mode() {
	mode="$1"
	fifo="$tmp/$mode.fifo"
	raw="$tmp/$mode.raw"
	log="$tmp/$mode.log"
	mkfifo "$fifo"
	exec 9<>"$fifo"

	cat "$fifo" >"$raw" &
	reader=$!
	LD_LIBRARY_PATH="$shim" \
	SOLOIST_SHIM_OUT="$fifo" \
	SOLOIST_SHIM_FORMAT=s16 \
	SOLOIST_SHIM_RATE=44100 \
	SOLOIST_SHIM_MODE="$mode" \
	SOLOIST_SHIM_LOG=1 \
	SOLOIST_SHIM_TEST_COUNTER_BASE_FRAMES=1073741000 \
	MARKER_INPUT_FLOAT32=1 \
	MARKER_FLUSH_INTERVAL_FRAMES=22050 \
	MARKER_TRACKS=3 \
	"$shim/marker_client" 2 >"$log" 2>&1
	kill "$reader" 2>/dev/null || true
	wait "$reader" 2>/dev/null || true
	exec 9>&-

	[ "$(grep -c 'stream drain requested:' "$log")" -eq 3 ]
	[ "$(grep -c 'stream drain complete:' "$log")" -eq 3 ]
	[ "$(grep -c 'stream drain complete: .* outstanding=0 ' "$log")" -eq 3 ]
	[ "$(grep -c 'reason=pulse-flush' "$log")" -ge 6 ]
	if grep -q 'drain index mismatch' "$log"; then
		cat "$log" >&2
		echo "$mode exposed inconsistent Pulse input-byte indexes" >&2
		exit 1
	fi
	[ "$(grep -Ec '\[marker-client\] track (1|2|3) drained' "$log")" -eq 3 ]
	if grep -q 'stream underflow:' "$log"; then
		cat "$log" >&2
		echo "$mode emitted a premature underflow across natural track endings" >&2
		exit 1
	fi
	[ "$(wc -c <"$raw")" -eq $((3 * 2 * 44100 * 4)) ]
}

run_mode live-ring
run_mode compat
echo "live-ring and compatibility modes drained and resumed across repeated natural track endings"
