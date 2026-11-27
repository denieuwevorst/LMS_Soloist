#!/bin/sh

set -eu

tmp="${TMPDIR:-/tmp}/soloist-s16-conversion-$$"
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir "$tmp"

command -v ffmpeg >/dev/null 2>&1 || {
	echo "ffmpeg is required to exercise LMS conversion commands" >&2
	exit 1
}

python3 - "$tmp/source.wav" <<'PY'
import math, struct, sys

frames = 44100
samples = []
for index in range(frames):
    value = int(12000 * math.sin(2 * math.pi * 440 * index / 44100))
    samples.extend((value, value))
payload = struct.pack("<" + "h" * len(samples), *samples)
header = (
    b"RIFF" + struct.pack("<I", 0xffffffff) + b"WAVEfmt "
    + struct.pack("<IHHIIHH", 16, 1, 2, 44100, 44100 * 4, 4, 16)
    + b"data" + struct.pack("<I", 0xffffffff)
)
open(sys.argv[1], "wb").write(header + payload)
PY

ffmpeg -nostdin -hide_banner -loglevel error -probesize 64 -analyzeduration 0 \
	-i "$tmp/source.wav" -map 0:a:0 -c:a flac -sample_fmt s16 \
	-compression_level 0 -flush_packets 1 -f flac "$tmp/output.flac"
ffmpeg -nostdin -hide_banner -loglevel error -probesize 64 -analyzeduration 0 \
	-i "$tmp/source.wav" -map 0:a:0 -c:a libmp3lame -b:a 320k \
	-flush_packets 1 -f mp3 "$tmp/output.mp3"

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

echo "LMS commands converted the S16LE WAV source to 16-bit FLAC and 320k MP3"
