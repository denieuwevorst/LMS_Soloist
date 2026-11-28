#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
shim="$root/contrib/experimental-pcm-shim"
tmp="${TMPDIR:-/tmp}/soloist-s16-conversion-$$"
ffmpeg_pid=""
feeder_pid=""
cleanup() {
	[ -n "$feeder_pid" ] && kill "$feeder_pid" 2>/dev/null || true
	[ -n "$ffmpeg_pid" ] && kill "$ffmpeg_pid" 2>/dev/null || true
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

run_conversion() {
	format="$1"
	raw_fifo="$tmp/$format.raw.fifo"
	wav_fifo="$tmp/$format.wav.fifo"
	output="$tmp/output.$format"
	log="$tmp/$format.log"
	mkfifo "$raw_fifo" "$wav_fifo"
	exec 9<>"$raw_fifo"

	if [ "$format" = "flac" ]; then
		ffmpeg -y -nostdin -hide_banner -loglevel error \
			-probesize 64 -analyzeduration 0 -i "$wav_fifo" \
			-map 0:a:0 -c:a flac -sample_fmt s16 -compression_level 0 \
			-flush_packets 1 -f flac "$output" &
	else
		ffmpeg -y -nostdin -hide_banner -loglevel error \
			-probesize 64 -analyzeduration 0 -i "$wav_fifo" \
			-map 0:a:0 -c:a libmp3lame -b:a 320k \
			-flush_packets 1 -f mp3 "$output" &
	fi
	ffmpeg_pid=$!

	python3 - "$raw_fifo" "$wav_fifo" <<'PY' &
import os
import struct
import sys
import time

raw_fifo, wav_fifo = sys.argv[1:]
target = 4 * 44100 * 4
pause_every = 44100 * 4 // 2
raw = os.open(raw_fifo, os.O_RDONLY)
wav = os.open(wav_fifo, os.O_WRONLY)
time.sleep(0.60)
header = (
    b"RIFF" + struct.pack("<I", 0xffffffff) + b"WAVEfmt "
    + struct.pack("<IHHIIHH", 16, 1, 2, 44100, 44100 * 4, 4, 16)
    + b"data" + struct.pack("<I", 0xffffffff)
)
os.write(wav, header)
total = 0
since_pause = 0
while total < target:
    chunk = os.read(raw, min(4096, target - total))
    if not chunk:
        time.sleep(0.001)
        continue
    view = memoryview(chunk)
    while view:
        written = os.write(wav, view)
        view = view[written:]
    total += len(chunk)
    since_pause += len(chunk)
    if since_pause >= pause_every and total < target:
        time.sleep(0.205)
        since_pause = 0
os.close(wav)
os.close(raw)
PY
	feeder_pid=$!

	LD_LIBRARY_PATH="$shim" \
	SOLOIST_SHIM_OUT="$raw_fifo" \
	SOLOIST_SHIM_FORMAT=s16 \
	SOLOIST_SHIM_RATE=44100 \
	SOLOIST_SHIM_RING_MS=750 \
	SOLOIST_SHIM_LOG=1 \
	"$shim/marker_client" 4 >"$tmp/$format.client.log" 2>"$log"

	wait "$feeder_pid"
	feeder_pid=""
	wait "$ffmpeg_pid"
	ffmpeg_pid=""
	exec 9>&-

	grep -q 'output pressure:' "$log"
	if grep -Eq 'output live-edge drop|ring live-edge drop|stream underflow' "$log"; then
		echo "$format source dropped audio under LMS converter cadence" >&2
		cat "$log" >&2
		exit 1
	fi
	python3 - "$log" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
waits = [
    float(value)
    for value in re.findall(r"output pressure: .*?max_wait=([0-9.]+) ms", text)
]
if not waits or max(waits) < 200.0:
    raise SystemExit("test did not reproduce a 200 ms LMS source-reader gap")
if max(waits) >= 750.0:
    raise SystemExit(f"converter source wait exceeded live-edge budget: {max(waits):.1f} ms")
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

echo "LMS FLAC/MP3 commands survived 600 ms startup and recurring 205 ms source-read gaps without drops"
