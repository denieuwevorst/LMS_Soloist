#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
shim="$root/contrib/experimental-pcm-shim"
tmp="${TMPDIR:-/tmp}/soloist-shim-ring-$$"
fifo="$tmp/audio.fifo"
control="$tmp/control"
ack="$tmp/ack"
client_pid=""
reader_pid=""
trap '[ -n "$client_pid" ] && kill "$client_pid" 2>/dev/null || true; [ -n "$reader_pid" ] && kill "$reader_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT INT TERM

mkdir "$tmp"
mkfifo "$fifo"
make -C "$shim" clean marker_client >/dev/null

# Match the bridge lifetime FIFO guard. The shim must retain accepted PCM even
# though no LMS reader exists initially and the kernel FIFO becomes full.
exec 9<>"$fifo"
LD_LIBRARY_PATH="$shim" \
SOLOIST_SHIM_OUT="$fifo" \
SOLOIST_SHIM_FORMAT=s16 \
SOLOIST_SHIM_RATE=44100 \
SOLOIST_SHIM_RING_MS=100 \
SOLOIST_SHIM_CONTROL="$control" \
SOLOIST_SHIM_ACK="$ack" \
SOLOIST_SHIM_LOG=1 \
"$shim/marker_client" 3 >"$tmp/client.log" 2>&1 &
client_pid=$!

sleep 1
kill -0 "$client_pid"

# Read the first frame after the one-second reader absence. Marker zero proves
# ordinary reader pressure did not discard already accepted PCM.
marker="$(python3 - "$fifo" <<'PY'
import errno, os, struct, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NONBLOCK)
deadline = time.monotonic() + 1
data = b""
while len(data) < 4 and time.monotonic() < deadline:
    try:
        data += os.read(fd, 4 - len(data))
    except BlockingIOError:
        time.sleep(0.005)
os.close(fd)
if len(data) != 4:
    raise SystemExit("no live PCM frame after draining")
left, right = struct.unpack("<hh", data)
if left != right:
    raise SystemExit("stereo frame alignment was lost")
print(left)
PY
)"
[ "$marker" -le 2 ]

cat "$fifo" >/dev/null &
reader_pid=$!

# A generation command must atomically flush the queued generation and be
# acknowledged without restarting the capture process.
printf '1 track\n' >"$control.tmp"
mv "$control.tmp" "$control"
for _try in $(seq 1 50); do
	[ -f "$ack" ] && grep -q '^1 [0-9][0-9]* track' "$ack" && break
	sleep 0.01
done
grep -q '^1 [0-9][0-9]* track' "$ack"
kill -0 "$client_pid"

# Rapid skips supersede older generations; the latest generation must win.
printf '2 track\n' >"$control.tmp"
mv "$control.tmp" "$control"
printf '3 backward-seek\n' >"$control.tmp"
mv "$control.tmp" "$control"
for _try in $(seq 1 50); do
	grep -q '^3 [0-9][0-9]* backward-seek' "$ack" 2>/dev/null && break
	sleep 0.01
done
grep -q '^3 [0-9][0-9]* backward-seek' "$ack"
kill -0 "$client_pid"

# Replacing the LMS reader leaves the same shim/Soloist capture process alive.
kill "$reader_pid" 2>/dev/null || true
wait "$reader_pid" 2>/dev/null || true
reader_pid=""
exec 8<"$fifo"
dd bs=4 count=1 <&8 >/dev/null 2>&1
exec 8<&-
sleep 0.05
exec 8<"$fifo"
dd bs=4 count=1 <&8 >/dev/null 2>&1
kill -0 "$client_pid"
exec 8<&-
cat "$fifo" >/dev/null &
reader_pid=$!

wait "$client_pid"
client_pid=""
kill "$reader_pid" 2>/dev/null || true
wait "$reader_pid" 2>/dev/null || true
reader_pid=""
grep -Eq 'generation flush: generation=[0-9]+ reason=track' "$tmp/client.log"
grep -Eq 'generation flush: generation=[0-9]+ reason=backward-seek' "$tmp/client.log"
if grep -Eq 'live-edge drop|stream underflow' "$tmp/client.log"; then
	cat "$tmp/client.log" >&2
	exit 1
fi
echo "PCM shim preserved accepted frames across slow readers, generations, and reader replacement"
