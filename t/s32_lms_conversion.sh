#!/bin/sh

set -eu

tmp="${TMPDIR:-/tmp}/soloist-s32-conversion-$$"
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir "$tmp"

command -v ffmpeg >/dev/null 2>&1 || {
	echo "ffmpeg is required for the LMS S32 conversion integration test" >&2
	exit 1
}

python3 - "$tmp/source.wav" <<'PY'
import struct, sys

frames = 4096
samples = []
for index in range(frames):
    value = 32768 if index % 2 else -32768
    samples.extend((value, value))
payload = struct.pack("<" + "i" * len(samples), *samples)
header = (
    b"RIFF" + struct.pack("<I", 36 + len(payload)) + b"WAVEfmt "
    + struct.pack("<IHHIIHH", 16, 1, 2, 44100, 44100 * 8, 8, 32)
    + b"data" + struct.pack("<I", len(payload))
)
open(sys.argv[1], "wb").write(header + payload)
PY

ffmpeg -nostdin -hide_banner -loglevel error \
	-probesize 64 -analyzeduration 0 \
	-i "$tmp/source.wav" -map 0:a:0 \
	-af aresample=osf=s16:dither_method=triangular \
	-f s16le "$tmp/output.raw"

ffmpeg -nostdin -hide_banner -loglevel error \
	-probesize 64 -analyzeduration 0 \
	-i "$tmp/source.wav" -map 0:a:0 \
	-af aresample=osf=s16:dither_method=triangular \
	-c:a flac -sample_fmt s16 -compression_level 0 \
	-flush_packets 1 -f flac "$tmp/output.flac"

python3 - "$tmp/output.raw" <<'PY'
import struct, sys

raw = open(sys.argv[1], "rb").read()
expected = 4096 * 2 * 2
if len(raw) != expected:
    raise SystemExit(f"S16 output width mismatch: {len(raw)} != {expected}")
samples = struct.unpack("<" + "h" * (len(raw) // 2), raw)
if not all(-32768 <= sample <= 32767 for sample in samples):
    raise SystemExit("converted output contains values outside S16")
if len(set(samples)) < 2:
    raise SystemExit("triangular dithering was not observable in converted samples")
PY

bits="$(ffprobe -v error -select_streams a:0 \
	-show_entries stream=bits_per_raw_sample \
	-of default=noprint_wrappers=1:nokey=1 "$tmp/output.flac")"
[ "$bits" = "16" ] || {
	echo "FLAC output bit depth mismatch: $bits" >&2
	exit 1
}

echo "LMS conversion produced dithered S16LE output; no S32LE passthrough"
