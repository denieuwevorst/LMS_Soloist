#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
shim="$root/contrib/experimental-pcm-shim"
tmp="${TMPDIR:-/tmp}/soloist-shim-generation-$$"
client_pid=""
trap '[ -n "$client_pid" ] && kill "$client_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT INT TERM

mkdir "$tmp"
make -C "$shim" clean marker_client >/dev/null

run_s32() {
	fifo="$tmp/s32.fifo"
	control="$tmp/s32.control"
	ack="$tmp/s32.ack"
	log="$tmp/s32.log"
	mkfifo "$fifo"
	exec 9<>"$fifo"

	LD_LIBRARY_PATH="$shim" \
	SOLOIST_SHIM_OUT="$fifo" \
	SOLOIST_SHIM_RATE=44100 \
	SOLOIST_SHIM_CONTROL="$control" \
	SOLOIST_SHIM_ACK="$ack" \
	SOLOIST_SHIM_LOG=1 \
	MARKER_PULSE_FLUSH_ON_START=1 \
	"$shim/marker_client" 30 >"$log" 2>&1 &
	client_pid=$!
	original_pid="$client_pid"

	sleep 1
	grep -q 'reason=pulse-flush' "$log"
	for generation in 1 2 3 4 5 6 7 8; do
		printf '%s track\n' "$generation" >"$control.tmp"
		mv "$control.tmp" "$control"
		sleep 0.025
		kill -0 "$original_pid"
	done

	for _try in $(seq 1 100); do
		grep -q '^8 [0-9][0-9]* track' "$ack" 2>/dev/null && break
		sleep 0.01
	done
	grep -q '^8 [0-9][0-9]* track' "$ack"
	# Re-publishing an already processed request must recreate a lost ack
	# without another flush or process restart.
	rm -f "$ack"
	printf '8 track\n' >"$control.tmp"
	mv "$control.tmp" "$control"
	for _try in $(seq 1 100); do
		grep -q '^8 [0-9][0-9]* track' "$ack" 2>/dev/null && break
		sleep 0.01
	done
	grep -q '^8 [0-9][0-9]* track' "$ack"
	kill -0 "$original_pid"
	[ "$client_pid" = "$original_pid" ]

	kill "$client_pid"
	wait "$client_pid" 2>/dev/null || true
	client_pid=""
	grep -q "loaded build 2026-11-18.7-s32le: mode=live-ring-s32le" "$log"
	grep -q 'generation flush: generation=8 reason=track' "$log"
	exec 9>&-
}

run_s32
echo "live-ring S32LE shim process survived repeated rapid track generations"
