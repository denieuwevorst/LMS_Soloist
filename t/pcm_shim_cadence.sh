#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
shim="$root/contrib/experimental-pcm-shim"
tmp="${TMPDIR:-/tmp}/soloist-shim-cadence-$$"
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir "$tmp"
make -C "$shim" clean marker_client >/dev/null

run_s32() {
	fifo="$tmp/s32.fifo"
	raw="$tmp/s32.raw"
	times="$tmp/s32.times"
	log="$tmp/s32.log"
	mkfifo "$fifo"
	exec 9<>"$fifo"

	python3 - "$fifo" "$raw" "$times" <<'PY' &
import os, sys, time
fifo, output, timings = sys.argv[1:]
target = 6 * 44100 * 8
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
	SOLOIST_SHIM_RATE=44100 \
	SOLOIST_SHIM_RING_MS=200 \
	SOLOIST_SHIM_LOG=1 \
	"$shim/marker_client" 6 >"$log" 2>&1
	wait "$reader"
	exec 9>&-

	python3 - "$times" <<'PY'
import sys
events = [float(line) for line in open(sys.argv[1]) if line.strip()]
if len(events) < 20:
    raise SystemExit(f"S32LE produced too few output events: {len(events)}")
gaps = [b - a for a, b in zip(events, events[1:])]
maximum = max(gaps, default=0)
if maximum > 0.080:
    raise SystemExit(f"S32LE wall-clock PCM gap was {maximum * 1000:.1f} ms")
print(f"S32LE wall-clock output max gap={maximum * 1000:.1f} ms")
PY
	grep -q "loaded build 2026-11-22.1-s32le: mode=live-ring-s32le" "$log"
	grep -q "runtime summary: mode=live-ring-s32le" "$log"
	if grep -Eq 'live-edge drop|stream underflow' "$log"; then
		cat "$log" >&2
		echo "S32LE cadence run dropped or underflowed audio" >&2
		exit 1
	fi
}

run_s32
echo "live-ring S32LE maintained continuous wall-clock PCM cadence"
