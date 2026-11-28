#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
pump="$root/Bin/soloist-pcm-pump.pl"
tmp="${TMPDIR:-/tmp}/soloist-pcm-pump-generation-$$"
source_fifo="$tmp/source.fifo"
output_fifo="$tmp/output.fifo"
control="$tmp/control"
shim_ack="$tmp/shim.ack"
pump_ack="$tmp/pump.ack"
pump_pid=""

cleanup() {
	[ -n "$pump_pid" ] && kill "$pump_pid" 2>/dev/null || true
	rm -rf "$tmp"
}
trap cleanup EXIT INT TERM
mkdir "$tmp"
mkfifo "$source_fifo" "$output_fifo"
exec 8<>"$source_fifo"
exec 9<>"$output_fifo"

SOLOIST_PCM_PUMP_SOURCE="$source_fifo" \
SOLOIST_PCM_PUMP_OUTPUT="$output_fifo" \
SOLOIST_PCM_PUMP_CONTROL="$control" \
SOLOIST_PCM_PUMP_SHIM_ACK="$shim_ack" \
SOLOIST_PCM_PUMP_ACK="$pump_ack" \
SOLOIST_PCM_PUMP_BUFFER_MS=800 \
perl "$pump" >"$tmp/stdout" 2>"$tmp/pump.log" &
pump_pid=$!

python3 - "$source_fifo" <<'PY'
import os
import sys

fd = os.open(sys.argv[1], os.O_WRONLY)
os.write(fd, b"OLD!" * 4096)
os.close(fd)
PY
sleep 0.1

printf '1 track\n' > "$control"
sleep 0.05
printf '1 7 track\n' > "$shim_ack"

python3 - "$pump_ack" <<'PY'
import os
import sys
import time

path = sys.argv[1]
deadline = time.monotonic() + 1
while time.monotonic() < deadline:
    if os.path.exists(path) and open(path, encoding="utf-8").read().startswith("1 "):
        break
    time.sleep(0.01)
else:
    raise SystemExit("pump did not acknowledge generation flush")
PY

python3 - "$source_fifo" <<'PY'
import os
import sys

fd = os.open(sys.argv[1], os.O_WRONLY)
os.write(fd, b"NEW!" * 1024)
os.close(fd)
PY

python3 - "$output_fifo" <<'PY'
import os
import sys
import time

fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NONBLOCK)
expected = b"NEW!" * 1024
received = bytearray()
deadline = time.monotonic() + 1
while len(received) < len(expected) and time.monotonic() < deadline:
    try:
        chunk = os.read(fd, len(expected) - len(received))
    except BlockingIOError:
        chunk = b""
    if chunk:
        received.extend(chunk)
    else:
        time.sleep(0.01)
os.close(fd)
if bytes(received) != expected:
    raise SystemExit(
        f"post-flush output retained stale PCM or lost fresh PCM: {len(received)} bytes"
    )
PY

grep -q 'generation flush: request=1' "$tmp/pump.log"
if grep -q 'live-edge drop:' "$tmp/pump.log"; then
	echo "generation flush overflowed the bounded pump" >&2
	cat "$tmp/pump.log" >&2
	exit 1
fi

kill "$pump_pid"
wait "$pump_pid" 2>/dev/null || true
pump_pid=""
rm -f "$pump_ack"
printf '2 track\n' > "$control"
printf '2 8 track\n' > "$shim_ack"

SOLOIST_PCM_PUMP_SOURCE="$source_fifo" \
SOLOIST_PCM_PUMP_OUTPUT="$output_fifo" \
SOLOIST_PCM_PUMP_CONTROL="$control" \
SOLOIST_PCM_PUMP_SHIM_ACK="$shim_ack" \
SOLOIST_PCM_PUMP_ACK="$pump_ack" \
SOLOIST_PCM_PUMP_BUFFER_MS=800 \
SOLOIST_PCM_PUMP_RESTART_ENCODER=1 \
perl "$pump" >"$tmp/restart.stdout" 2>"$tmp/restart.log" &
pump_pid=$!

set +e
wait "$pump_pid"
status=$?
set -e
pump_pid=""
[ "$status" -eq 75 ] || {
	echo "generation restart pump exited with $status instead of 75" >&2
	exit 1
}
[ ! -f "$pump_ack" ] || {
	echo "pump acknowledged before the encoder restart" >&2
	exit 1
}
grep -q 'generation restart: request=2' "$tmp/restart.log"

SOLOIST_PCM_PUMP_SOURCE="$source_fifo" \
SOLOIST_PCM_PUMP_OUTPUT="$output_fifo" \
SOLOIST_PCM_PUMP_CONTROL="$control" \
SOLOIST_PCM_PUMP_SHIM_ACK="$shim_ack" \
SOLOIST_PCM_PUMP_ACK="$pump_ack" \
SOLOIST_PCM_PUMP_BUFFER_MS=800 \
SOLOIST_PCM_PUMP_RESTART_ENCODER=1 \
SOLOIST_PCM_PUMP_ENCODER_FRESH=1 \
perl "$pump" >"$tmp/fresh.stdout" 2>"$tmp/fresh.log" &
pump_pid=$!

python3 - "$pump_ack" <<'PY'
import os
import sys
import time

path = sys.argv[1]
deadline = time.monotonic() + 1
while time.monotonic() < deadline:
    if os.path.exists(path) and open(path, encoding="utf-8").read().startswith("2 "):
        break
    time.sleep(0.01)
else:
    raise SystemExit("fresh encoder pump did not acknowledge generation restart")
PY
grep -q 'generation flush: request=2' "$tmp/fresh.log"

echo "PCM pump generation flush retained fresh PCM and restarts compressed encoder headers"
