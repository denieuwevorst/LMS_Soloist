#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
pump="$root/Bin/soloist-pcm-pump.pl"
tmp="${TMPDIR:-/tmp}/soloist-s16-conversion-$$"
pump_pid=""
ffmpeg_pid=""
reader_pid=""
producer_pid=""

cleanup() {
	[ -n "$producer_pid" ] && kill "$producer_pid" 2>/dev/null || true
	[ -n "$reader_pid" ] && kill "$reader_pid" 2>/dev/null || true
	[ -n "$ffmpeg_pid" ] && kill "$ffmpeg_pid" 2>/dev/null || true
	[ -n "$pump_pid" ] && kill "$pump_pid" 2>/dev/null || true
	rm -rf "$tmp"
}
trap cleanup EXIT INT TERM
mkdir "$tmp"

command -v ffmpeg >/dev/null 2>&1 || {
	echo "ffmpeg is required to exercise bridge conversion" >&2
	exit 1
}
command -v ffprobe >/dev/null 2>&1 || {
	echo "ffprobe is required to validate bridge conversion output" >&2
	exit 1
}

perl -c "$pump" >/dev/null

run_conversion() {
	format="$1"
	bitrate="$2"
	source_fifo="$tmp/$format.source.fifo"
	encoder_fifo="$tmp/$format.encoder.fifo"
	final_fifo="$tmp/$format.final.fifo"
	output="$tmp/output.$format"
	decoded="$tmp/$format.decoded.s16"
	pump_log="$tmp/$format.pump.log"
	mkfifo "$source_fifo" "$encoder_fifo" "$final_fifo"

	python3 - "$final_fifo" "$output" <<'PY' &
import fcntl
import os
import sys
import time

fifo, output = sys.argv[1:]
fd = os.open(fifo, os.O_RDONLY)
try:
    fcntl.fcntl(fd, 1031, 65536)
except OSError:
    pass
started = time.monotonic()
next_pause = started + 1.0
with open(output, "wb") as target:
    while True:
        now = time.monotonic()
        if now >= next_pause:
            time.sleep(0.40)
            next_pause += 1.0
        chunk = os.read(fd, 4096)
        if not chunk:
            break
        target.write(chunk)
os.close(fd)
PY
	reader_pid=$!

	if [ "$format" = "flac" ]; then
		ffmpeg -y -nostdin -hide_banner -loglevel error \
			-f s16le -ar 44100 -ac 2 -blocksize 4096 \
			-i "$encoder_fifo" -map 0:a:0 \
			-c:a flac -sample_fmt s16 -compression_level 0 \
			-flush_packets 1 -f flac "$final_fifo" &
	else
		ffmpeg -y -nostdin -hide_banner -loglevel error \
			-f s16le -ar 44100 -ac 2 -blocksize 4096 \
			-i "$encoder_fifo" -map 0:a:0 \
			-c:a libmp3lame -b:a "$bitrate" \
			-flush_packets 1 -f mp3 "$final_fifo" &
	fi
	ffmpeg_pid=$!
	encoder_pid="$ffmpeg_pid"

	SOLOIST_PCM_PUMP_SOURCE="$source_fifo" \
	SOLOIST_PCM_PUMP_OUTPUT="$encoder_fifo" \
	SOLOIST_PCM_PUMP_BUFFER_MS=800 \
	SOLOIST_PCM_PUMP_FATAL_OUTPUT=1 \
	perl "$pump" >"$tmp/$format.pump.stdout" 2>"$pump_log" &
	pump_pid=$!

	started_at="$(python3 -c 'import time; print(time.monotonic())')"
	python3 - "$source_fifo" <<'PY' &
import os
import struct
import sys
import time

fd = os.open(sys.argv[1], os.O_WRONLY)
frames_per_chunk = 44100 // 50
started = time.monotonic()
state = 0x12345678
for index in range(500):
    samples = bytearray()
    for _ in range(frames_per_chunk):
        state = (1664525 * state + 1013904223) & 0xffffffff
        left = ((state >> 8) & 0xffff) - 32768
        state = (1664525 * state + 1013904223) & 0xffffffff
        right = ((state >> 8) & 0xffff) - 32768
        samples += struct.pack("<hh", left, right)
    view = memoryview(samples)
    while view:
        written = os.write(fd, view)
        view = view[written:]
    deadline = started + (index + 1) / 50
    remaining = deadline - time.monotonic()
    if remaining > 0:
        time.sleep(remaining)
os.close(fd)
PY
	producer_pid=$!

	sleep 5
	kill -0 "$encoder_pid" 2>/dev/null || {
		echo "$format bridge encoder did not remain stable for five seconds" >&2
		exit 1
	}

	wait "$producer_pid"
	producer_pid=""
	produced_at="$(python3 -c 'import time; print(time.monotonic())')"
	sleep 1
	kill "$pump_pid"
	wait "$pump_pid" 2>/dev/null || true
	pump_pid=""
	wait "$ffmpeg_pid"
	ffmpeg_pid=""
	wait "$reader_pid"
	reader_pid=""
	finished_at="$(python3 -c 'import time; print(time.monotonic())')"

	if grep -Eq 'live-edge drop:|ring live-edge drop:|output live-edge drop:' "$pump_log"; then
		echo "$format bridge pipeline dropped PCM" >&2
		cat "$pump_log" >&2
		exit 1
	fi
	grep -q 'drops=0.0 ms' "$pump_log"

	ffmpeg -y -nostdin -hide_banner -loglevel error \
		-i "$output" -f s16le -acodec pcm_s16le "$decoded"
	python3 - "$format" "$decoded" "$started_at" "$produced_at" "$finished_at" <<'PY'
import os
import sys

fmt, decoded, started, produced, finished = sys.argv[1:]
frames = os.path.getsize(decoded) // 4
producer_elapsed = float(produced) - float(started)
pipeline_elapsed = float(finished) - float(started)
if not 9.8 <= producer_elapsed <= 10.5:
    raise SystemExit(f"{fmt} source pacing drifted: {producer_elapsed:.3f}s")
if fmt == "flac":
    if frames != 441000:
        raise SystemExit(f"FLAC decoded {frames} frames instead of 441000")
elif not 441000 <= frames <= 443304:
    raise SystemExit(f"MP3 decoded unexpected frame count: {frames}")
if pipeline_elapsed > 12.5:
    raise SystemExit(f"{fmt} pipeline failed realtime throughput: {pipeline_elapsed:.3f}s")
print(
    f"{fmt}: decoded_frames={frames} producer={producer_elapsed:.3f}s "
    f"pipeline={pipeline_elapsed:.3f}s"
)
PY
}

run_conversion flac 320k
run_conversion mp3 320k

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

echo "persistent bridge FLAC/MP3 encoders survived recurring 400 ms LMS reader stalls without PCM loss"
