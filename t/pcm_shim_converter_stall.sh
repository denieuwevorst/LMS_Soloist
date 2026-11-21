#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
shim="$root/contrib/experimental-pcm-shim"
tmp="${TMPDIR:-/tmp}/soloist-shim-converter-stall-$$"
fifo="$tmp/audio.fifo"
log="$tmp/client.log"
reader_pid=""
client_pid=""
trap '[ -n "$reader_pid" ] && kill "$reader_pid" 2>/dev/null || true; [ -n "$client_pid" ] && kill "$client_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT INT TERM

mkdir "$tmp"
mkfifo "$fifo"
make -C "$shim" clean marker_client >/dev/null

# Match the bridge guard, then delay the real LMS/converter reader by 120 ms.
# The field trace showed that exact scheduling gap overflowing a 16 KiB FIFO.
exec 9<>"$fifo"
LD_LIBRARY_PATH="$shim" \
SOLOIST_SHIM_OUT="$fifo" \
SOLOIST_SHIM_RATE=44100 \
SOLOIST_SHIM_RING_MS=200 \
SOLOIST_SHIM_LOG=1 \
"$shim/marker_client" 6 >"$log" 2>&1 &
client_pid=$!

for _try in $(seq 1 100); do
	grep -q 'output connected:' "$log" 2>/dev/null && break
	sleep 0.01
done
grep -q 'output connected:' "$log"
sleep 0.12

python3 - "$fifo" <<'PY' &
import os, sys, time

fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NONBLOCK)
received = 0
deadline = time.monotonic() + 6.5
while time.monotonic() < deadline:
    try:
        chunk = os.read(fd, 65536)
    except BlockingIOError:
        time.sleep(0.001)
        continue
    if not chunk:
        time.sleep(0.001)
        continue
    received += len(chunk)
os.close(fd)
minimum = int(5.7 * 44100 * 8)
maximum = 6 * 44100 * 8
if not minimum <= received <= maximum:
    raise SystemExit(
        f"converter-stall capture outside bounded range: {received} "
        f"not in [{minimum}, {maximum}]"
    )
PY
reader_pid=$!

wait "$client_pid"
client_pid=""
wait "$reader_pid"
reader_pid=""
exec 9>&-

grep -q 'runtime summary: mode=live-ring-s32le' "$log"
if grep -Eq 'output pressure|live-edge drop|stream underflow' "$log"; then
	cat "$log" >&2
	echo "120 ms LMS converter startup stall caused pressure, a drop, or an underflow" >&2
	exit 1
fi

python3 - "$log" <<'PY'
import re, sys

text = open(sys.argv[1]).read()
size = re.search(r"FIFO kernel queue: ([0-9]+) bytes", text)
if not size or int(size.group(1)) < 65536:
    raise SystemExit("S32LE FIFO did not provide at least 64 KiB of converter headroom")
ages = [
    float(match.group(1))
    for match in re.finditer(r"oldest_age=([0-9.]+) ms", text)
]
if not ages:
    raise SystemExit("no runtime oldest-age diagnostics found")
if max(ages) > 200.0:
    raise SystemExit(f"oldest queued audio exceeded live-edge budget: {max(ages):.1f} ms")
PY

echo "64 KiB S32LE FIFO absorbed a 120 ms LMS converter startup stall without pressure or drops"
