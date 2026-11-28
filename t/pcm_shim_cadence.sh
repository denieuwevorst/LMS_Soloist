#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
shim="$root/contrib/experimental-pcm-shim"
tmp="${TMPDIR:-/tmp}/soloist-shim-cadence-$$"
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir "$tmp"
make -C "$shim" clean marker_client >/dev/null

run_mode() {
	mode="$1"
	fifo="$tmp/$mode.fifo"
	raw="$tmp/$mode.raw"
	times="$tmp/$mode.times"
	log="$tmp/$mode.log"
	mkfifo "$fifo"
	exec 9<>"$fifo"

	python3 - "$fifo" "$raw" "$times" <<'PY' &
import os, sys, time
fifo, output, timings = sys.argv[1:]
target = 6 * 44100 * 4
fd = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
data = bytearray()
events = []
deadline = time.monotonic() + 9
while len(data) < target and time.monotonic() < deadline:
    try:
        chunk = os.read(fd, min(16384, target - len(data)))
    except BlockingIOError:
        time.sleep(0.001)
        continue
    if not chunk:
        time.sleep(0.001)
        continue
    events.append(time.monotonic())
    data.extend(chunk)
os.close(fd)
open(output, "wb").write(data)
open(timings, "w").write("\n".join(map(str, events)))
if len(data) != target:
    raise SystemExit(f"short cadence capture: {len(data)} != {target}")
PY
	reader=$!

	LD_LIBRARY_PATH="$shim" \
	SOLOIST_SHIM_OUT="$fifo" \
	SOLOIST_SHIM_FORMAT=s16 \
	SOLOIST_SHIM_RATE=44100 \
	SOLOIST_SHIM_RING_MS=200 \
	SOLOIST_SHIM_MODE="$mode" \
	SOLOIST_SHIM_LOG=1 \
	SOLOIST_SHIM_DELAY_TRACE=1 \
	"$shim/marker_client" 6 >"$log" 2>&1
	wait "$reader"
	exec 9>&-

	python3 - "$times" "$mode" <<'PY'
import sys
events = [float(line) for line in open(sys.argv[1]) if line.strip()]
if len(events) < 20:
    raise SystemExit(f"{sys.argv[2]} produced too few output events: {len(events)}")
gaps = [b - a for a, b in zip(events, events[1:])]
maximum = max(gaps, default=0)
if maximum > 0.080:
    raise SystemExit(f"{sys.argv[2]} wall-clock PCM gap was {maximum * 1000:.1f} ms")
print(f"{sys.argv[2]} wall-clock output max gap={maximum * 1000:.1f} ms")
PY
	grep -q "loaded build 2026-11-28.1-fifo64: mode=$mode" "$log"
	[ "$(grep -c 'milestone=shim-first-pcm-write' "$log")" -eq 1 ]
	grep -q "runtime summary: mode=$mode" "$log"
	if grep -Eq 'live-edge drop|stream underflow' "$log"; then
		cat "$log" >&2
		echo "$mode cadence run dropped or underflowed audio" >&2
		exit 1
	fi
}

run_mode live-ring
run_mode compat
live_contract="$(grep 'connect_playback:' "$tmp/live-ring.log" | sed -e 's/mode=live-ring/mode=MODE/' -e 's#out=[^ ]*#out=OUTPUT#')"
compat_contract="$(grep 'connect_playback:' "$tmp/compat.log" | sed -e 's/mode=compat/mode=MODE/' -e 's#out=[^ ]*#out=OUTPUT#')"
[ "$live_contract" = "$compat_contract" ] || {
	echo "live-ring changed the Pulse producer contract:" >&2
	printf '%s\n%s\n' "$live_contract" "$compat_contract" >&2
	exit 1
}
echo "live-ring and compatibility modes maintained continuous wall-clock PCM cadence"
