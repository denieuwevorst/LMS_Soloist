#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
shim="$root/contrib/experimental-pcm-shim"
pump="$root/Bin/soloist-pcm-pump.pl"
tmp="${TMPDIR:-/tmp}/soloist-s16-conversion-$$"
pump_pid=""
ffmpeg_pid=""
feeder_pid=""
client_pid=""

cleanup() {
	[ -n "$client_pid" ] && kill "$client_pid" 2>/dev/null || true
	[ -n "$feeder_pid" ] && kill "$feeder_pid" 2>/dev/null || true
	[ -n "$ffmpeg_pid" ] && kill "$ffmpeg_pid" 2>/dev/null || true
	[ -n "$pump_pid" ] && kill "$pump_pid" 2>/dev/null || true
	rm -rf "$tmp"
}
trap cleanup EXIT INT TERM
mkdir "$tmp"

command -v ffmpeg >/dev/null 2>&1 || {
	echo "ffmpeg is required to exercise LMS conversion commands" >&2
	exit 1
}
command -v ffprobe >/dev/null 2>&1 || {
	echo "ffprobe is required to validate LMS conversion output" >&2
	exit 1
}

make -C "$shim" clean marker_client >/dev/null
perl -c "$pump" >/dev/null

run_conversion() {
	format="$1"
	source_fifo="$tmp/$format.source.fifo"
	final_fifo="$tmp/$format.final.fifo"
	wav_fifo="$tmp/$format.wav.fifo"
	output="$tmp/output.$format"
	shim_log="$tmp/$format.shim.log"
	pump_log="$tmp/$format.pump.log"
	mkfifo "$source_fifo" "$final_fifo" "$wav_fifo"
	exec 8<>"$source_fifo"
	exec 9<>"$final_fifo"

	SOLOIST_PCM_PUMP_SOURCE="$source_fifo" \
	SOLOIST_PCM_PUMP_OUTPUT="$final_fifo" \
	SOLOIST_PCM_PUMP_BUFFER_MS=800 \
	perl "$pump" 8>&- 9>&- >"$tmp/$format.pump.stdout" 2>"$pump_log" &
	pump_pid=$!

	if [ "$format" = "flac" ]; then
		ffmpeg -y -nostdin -hide_banner -loglevel error \
			-probesize 64 -analyzeduration 0 -i "$wav_fifo" \
			-map 0:a:0 -c:a flac -sample_fmt s16 -compression_level 0 \
			-flush_packets 1 -f flac "$output" 8>&- 9>&- &
	else
		ffmpeg -y -nostdin -hide_banner -loglevel error \
			-probesize 64 -analyzeduration 0 -i "$wav_fifo" \
			-map 0:a:0 -c:a libmp3lame -b:a 320k \
			-flush_packets 1 -f mp3 "$output" 8>&- 9>&- &
	fi
	ffmpeg_pid=$!

	python3 - "$final_fifo" "$wav_fifo" 8>&- 9>&- <<'PY' &
import os
import struct
import sys
import time

final_fifo, wav_fifo = sys.argv[1:]
pause_every = 44100 * 4 // 2
source = os.open(final_fifo, os.O_RDONLY)
wav = os.open(wav_fifo, os.O_WRONLY)
header = (
    b"RIFF" + struct.pack("<I", 0xffffffff) + b"WAVEfmt "
    + struct.pack("<IHHIIHH", 16, 1, 2, 44100, 44100 * 4, 4, 16)
    + b"data" + struct.pack("<I", 0xffffffff)
)
os.write(wav, header)
time.sleep(0.70)
total = 0
since_pause = 0
while True:
    chunk = os.read(source, 4096)
    if not chunk:
        break
    view = memoryview(chunk)
    while view:
        written = os.write(wav, view)
        view = view[written:]
    total += len(chunk)
    since_pause += len(chunk)
    if since_pause >= pause_every:
        time.sleep(0.40)
        since_pause = 0
os.close(wav)
os.close(source)
PY
	feeder_pid=$!

	started_at="$(python3 -c 'import time; print(time.monotonic())')"
	LD_LIBRARY_PATH="$shim" \
	SOLOIST_SHIM_OUT="$source_fifo" \
	SOLOIST_SHIM_FORMAT=s16 \
	SOLOIST_SHIM_RATE=44100 \
	SOLOIST_SHIM_RING_MS=200 \
	SOLOIST_SHIM_LOG=1 \
	"$shim/marker_client" 5 8>&- 9>&- >"$tmp/$format.client.log" 2>"$shim_log" &
	client_pid=$!

	python3 - "$output" "$started_at" <<'PY'
import os
import sys
import time

output, started = sys.argv[1], float(sys.argv[2])
deadline = started + 1.25
while time.monotonic() < deadline:
    if os.path.exists(output) and os.path.getsize(output) > 0:
        elapsed = time.monotonic() - started
        print(f"first encoded bytes after {elapsed * 1000:.0f} ms")
        break
    time.sleep(0.01)
else:
    raise SystemExit("converter did not produce first output within 1.25 seconds")
PY

	wait "$client_pid"
	client_pid=""
	sleep 2
	kill "$pump_pid"
	wait "$pump_pid" 2>/dev/null || true
	pump_pid=""
	exec 8>&-
	exec 9>&-
	wait "$feeder_pid"
	feeder_pid=""
	wait "$ffmpeg_pid"
	ffmpeg_pid=""

	if grep -Eq 'output live-edge drop|ring live-edge drop|stream underflow|underflows=[1-9]|drops=[1-9]' "$shim_log"; then
		echo "$format source shim lost audio despite the decoupled pump" >&2
		cat "$shim_log" >&2
		exit 1
	fi
	if grep -q 'live-edge drop:' "$pump_log"; then
		echo "$format converter-side pump exceeded its bounded queue" >&2
		cat "$pump_log" >&2
		exit 1
	fi
	grep -q 'runtime summary:' "$pump_log"
	python3 - "$pump_log" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
queues = [
    float(value)
    for value in re.findall(r"max_queued=([0-9.]+) ms", text)
]
if not queues or max(queues) < 300.0:
    raise SystemExit("test did not reproduce sustained converter backpressure")
if max(queues) >= 800.0:
    raise SystemExit(f"converter queue exceeded budget: {max(queues):.1f} ms")
PY
}

run_conversion flac
run_conversion mp3

bits="$(ffprobe -v error -select_streams a:0 \
	-show_entries stream=bits_per_raw_sample \
	-of default=noprint_wrappers=1:nokey=1 "$tmp/output.flac")"
[ "$bits" = "16" ] || {
	echo "FLAC output bit depth mismatch: $bits" >&2
	exit 1
}

rate="$(ffprobe -v error -select_streams a:0 \
	-show_entries stream=sample_rate \
	-of default=noprint_wrappers=1:nokey=1 "$tmp/output.mp3")"
[ "$rate" = "44100" ] || {
	echo "MP3 sample rate mismatch: $rate" >&2
	exit 1
}

echo "decoupled LMS FLAC/MP3 input survived 700 ms startup and recurring 400 ms no-read windows without source loss"
