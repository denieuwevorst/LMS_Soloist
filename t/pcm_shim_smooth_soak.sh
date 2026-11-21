#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
shim="$root/contrib/experimental-pcm-shim"
tmp="${TMPDIR:-/tmp}/soloist-shim-soak-$$"
fifo="$tmp/audio.fifo"
raw="$tmp/audio.raw"
client_pid=""
reader_pid=""
trap '[ -n "$client_pid" ] && kill "$client_pid" 2>/dev/null || true; [ -n "$reader_pid" ] && kill "$reader_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT INT TERM

mkdir "$tmp"
mkfifo "$fifo"
make -C "$shim" clean marker_client >/dev/null

# Match the bridge guard, then consume faster than real time in bursts with
# deliberate 120 ms scheduler gaps. Those gaps exceed the 16 KiB FIFO alone,
# but remain inside the 200 ms userspace live-edge budget.
exec 9<>"$fifo"
python3 - "$fifo" "$raw" <<'PY' &
import os, sys, time
fifo, output = sys.argv[1:]
target = 5 * 44100 * 8
fd = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
data = bytearray()
next_pause = 44100 * 8 // 4
deadline = time.monotonic() + 8
while len(data) < target and time.monotonic() < deadline:
    try:
        chunk = os.read(fd, min(16384, target - len(data)))
    except BlockingIOError:
        time.sleep(0.001)
        continue
    if not chunk:
        time.sleep(0.001)
        continue
    data.extend(chunk)
    if len(data) >= next_pause:
        time.sleep(0.120)
        next_pause += 44100 * 8 // 4
os.close(fd)
with open(output, "wb") as handle:
    handle.write(data)
if len(data) != target:
    raise SystemExit(f"short steady-state PCM capture: {len(data)} != {target}")
PY
reader_pid=$!

LD_LIBRARY_PATH="$shim" \
SOLOIST_SHIM_OUT="$fifo" \
SOLOIST_SHIM_RATE=44100 \
SOLOIST_SHIM_RING_MS=200 \
SOLOIST_SHIM_LOG=1 \
"$shim/marker_client" 5 >"$tmp/client.log" 2>&1 &
client_pid=$!

wait "$client_pid"
client_pid=""
wait "$reader_pid"
reader_pid=""

[ "$(wc -c < "$raw")" -eq 1764000 ]
if grep -Eq 'live-edge drop|stream underflow' "$tmp/client.log"; then
	cat "$tmp/client.log" >&2
	echo "steady-state soak dropped or underflowed audio" >&2
	exit 1
fi
grep -q 'output pressure: eagain=' "$tmp/client.log"

python3 - "$raw" "$tmp/client.log" <<'PY'
import re, struct, sys
raw = open(sys.argv[1], "rb").read()
frames = struct.iter_unpack("<ii", raw)
last = -1
for left, right in frames:
    if left != right:
        raise SystemExit("stereo frame alignment was lost")
    left >>= 16
    right >>= 16
    if left < last:
        raise SystemExit(f"PCM marker moved backward: {left} < {last}")
    if left > last + 1 and last >= 0:
        raise SystemExit(f"steady-state PCM frames were dropped: {last} -> {left}")
    last = left
log = open(sys.argv[2], encoding="utf-8").read()
pressure = re.findall(
    r"output pressure: eagain=(\d+) partial=(\d+) "
    r"max_wait=([0-9.]+) ms max_queued=([0-9.]+) ms",
    log,
)
if not pressure:
    raise SystemExit("reader jitter did not exercise FIFO backpressure")
max_wait = max(float(row[2]) for row in pressure)
max_queued = max(float(row[3]) for row in pressure)
if max_wait > 200.0:
    raise SystemExit(f"sink wait exceeded ring budget: {max_wait} ms")
ages = [
    float(value)
    for value in re.findall(r"runtime summary: .*?oldest_age=([0-9.]+) ms", log)
]
if not ages:
    raise SystemExit("runtime summaries did not report oldest audio age")
max_age = max(ages)
if max_age > 220.0:
    raise SystemExit(f"oldest audio exceeded live-edge age budget: {max_age} ms")
print(
    f"steady-state pressure stayed bounded: "
    f"max_wait={max_wait:.1f} ms producer_queue={max_queued:.1f} ms "
    f"oldest_age={max_age:.1f} ms"
)
PY

echo "five-second intermittent-reader PCM soak completed with zero drops and zero underruns"
