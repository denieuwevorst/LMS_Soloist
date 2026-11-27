#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
shim="$root/contrib/experimental-pcm-shim"
loader="$root/Bin/X86_64/glibc/ld-linux-x86-64.so.2"
tmp="${TMPDIR:-/tmp}/soloist-loader-preload-$$"
client_pid=""
trap '[ -n "$client_pid" ] && kill "$client_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT INT TERM

mkdir "$tmp"
mkfifo "$tmp/audio.fifo"
exec 9<>"$tmp/audio.fifo"
make -C "$shim" clean marker_client >/dev/null

SOLOIST_SHIM_OUT="$tmp/audio.fifo" \
SOLOIST_SHIM_FORMAT=s16 \
SOLOIST_SHIM_RATE=44100 \
SOLOIST_SHIM_LOG=1 \
"$loader" \
	--preload "$shim/libpulse.so.0" \
	--library-path "$shim:$root/Bin/X86_64/glibc" \
	"$shim/marker_client" 30 >"$tmp/client.log" 2>&1 &
client_pid=$!

for _try in $(seq 1 100); do
	grep -q 'loaded build 2026-11-27.2-delaytrace' "$tmp/client.log" 2>/dev/null &&
		grep -F "$(readlink -f "$shim/libpulse.so.0")" "/proc/$client_pid/maps" >/dev/null 2>&1 &&
		break
	sleep 0.01
done

grep -q 'loaded build 2026-11-27.2-delaytrace' "$tmp/client.log"
grep -F "$(readlink -f "$shim/libpulse.so.0")" "/proc/$client_pid/maps" >/dev/null
kill -0 "$client_pid"
kill "$client_pid"
wait "$client_pid" 2>/dev/null || true
client_pid=""
exec 9>&-

echo "private glibc loader explicitly preloaded and mapped the selected PCM shim"
