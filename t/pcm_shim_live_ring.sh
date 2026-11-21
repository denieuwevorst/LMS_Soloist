#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
shim="$root/contrib/experimental-pcm-shim"
tmp="${TMPDIR:-/tmp}/soloist-shim-ring-$$"
fifo="$tmp/audio.fifo"
control="$tmp/control"
ack="$tmp/ack"
client_pid=""
trap '[ -n "$client_pid" ] && kill "$client_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT INT TERM

mkdir "$tmp"
mkfifo "$fifo"
make -C "$shim" clean marker_client >/dev/null

# Match the bridge lifetime FIFO guard. The shim must never block even though
# no LMS reader exists initially and the kernel FIFO becomes full.
exec 9<>"$fifo"
LD_LIBRARY_PATH="$shim" \
SOLOIST_SHIM_OUT="$fifo" \
SOLOIST_SHIM_RATE=44100 \
SOLOIST_SHIM_RING_MS=100 \
SOLOIST_SHIM_CONTROL="$control" \
SOLOIST_SHIM_ACK="$ack" \
SOLOIST_SHIM_LOG=1 \
"$shim/marker_client" 3 >"$tmp/client.log" 2>&1 &
client_pid=$!

sleep 1
kill -0 "$client_pid"

# Drain the stale kernel FIFO and read the next frame. Its centisecond marker
# must be close to the current live edge, proving old frames were discarded.
marker="$(python3 - "$fifo" <<'PY'
import errno, os, struct, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NONBLOCK)
while True:
    try:
        if not os.read(fd, 65536):
            break
    except BlockingIOError:
        break
deadline = time.monotonic() + 1
data = b""
while len(data) < 8 and time.monotonic() < deadline:
    try:
        data += os.read(fd, 8 - len(data))
    except BlockingIOError:
        time.sleep(0.005)
os.close(fd)
if len(data) != 8:
    raise SystemExit("no live PCM frame after draining")
left, right = struct.unpack("<ii", data)
if left != right:
    raise SystemExit("stereo frame alignment was lost")
print(left >> 16)
PY
)"
[ "$marker" -ge 60 ]

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
exec 8<"$fifo"
dd bs=8 count=1 <&8 >/dev/null 2>&1
exec 8<&-
sleep 0.05
exec 8<"$fifo"
dd bs=8 count=1 <&8 >/dev/null 2>&1
kill -0 "$client_pid"
exec 8<&-

wait "$client_pid"
client_pid=""
grep -Eq 'generation flush: generation=[0-9]+ reason=track' "$tmp/client.log"
grep -Eq 'generation flush: generation=[0-9]+ reason=backward-seek' "$tmp/client.log"
echo "bounded PCM shim ring kept the live edge across slow readers, generations, and reader replacement"
