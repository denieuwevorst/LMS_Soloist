#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
shim="$root/contrib/experimental-pcm-shim"
tmp="${TMPDIR:-/tmp}/soloist-shim-generation-$$"
client_pid=""
trap '[ -n "$client_pid" ] && kill "$client_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT INT TERM

mkdir "$tmp"
make -C "$shim" clean marker_client >/dev/null

run_mode() {
	mode="$1"
	fifo="$tmp/$mode.fifo"
	control="$tmp/$mode.control"
	ack="$tmp/$mode.ack"
	log="$tmp/$mode.log"
	mkfifo "$fifo"
	exec 9<>"$fifo"

	LD_LIBRARY_PATH="$shim" \
	SOLOIST_SHIM_OUT="$fifo" \
	SOLOIST_SHIM_FORMAT=s16 \
	SOLOIST_SHIM_RATE=44100 \
	SOLOIST_SHIM_MODE="$mode" \
	SOLOIST_SHIM_CONTROL="$control" \
	SOLOIST_SHIM_ACK="$ack" \
	SOLOIST_SHIM_LOG=1 \
	"$shim/marker_client" 30 >"$log" 2>&1 &
	client_pid=$!
	original_pid="$client_pid"

	sleep 1
	for generation in 1 2 3 4 5 6 7 8; do
		printf '%s track\n' "$generation" >"$control.tmp"
		mv "$control.tmp" "$control"
		sleep 0.025
		kill -0 "$original_pid"
	done

	for _try in $(seq 1 100); do
		grep -q '^8 track' "$ack" 2>/dev/null && break
		sleep 0.01
	done
	grep -q '^8 track' "$ack"
	kill -0 "$original_pid"
	[ "$client_pid" = "$original_pid" ]

	kill "$client_pid"
	wait "$client_pid" 2>/dev/null || true
	client_pid=""
	grep -q "loaded build 2026-11-18.3-loadcheck: mode=$mode" "$log"
	grep -q 'generation flush: generation=8 reason=track' "$log"
	exec 9>&-
}

run_mode live-ring
run_mode compat
echo "live-ring and compatibility shim processes survived repeated rapid track generations"
