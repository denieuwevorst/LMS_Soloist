#!/bin/sh

set -eu

tmp="${TMPDIR:-/tmp}/soloist-direct-fifo-$$"
source_fifo="${tmp}/source.fifo"
fifo="${tmp}/audio.fifo"
converter_pid=""
trap '[ -n "$converter_pid" ] && kill "$converter_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT INT TERM

mkdir "$tmp"
mkfifo "$source_fifo"
mkfifo "$fifo"

# The bridge owns both source ends so converter replacement cannot disconnect
# the shim. The final FIFO intentionally has no lifetime guard: closing a
# discontinuous handler must terminate the old converter.
exec 5<>"$source_fifo"
exec 4<>"$fifo"
cat "$source_fifo" > "$fifo" 5>&- &
converter_pid=$!

printf 'first' >&5
first="$(dd bs=1 count=5 <&4 2>/dev/null)"
[ "$first" = "first" ]

# Replacing the protocol handler closes the only reader. The next old-timeline
# write terminates the converter instead of leaking buffered data forward.
exec 4<&-
printf 'old!!' >&5
for _try in $(seq 1 100); do
	kill -0 "$converter_pid" 2>/dev/null || break
	sleep 0.01
done
if kill -0 "$converter_pid" 2>/dev/null; then
	echo "old converter survived final FIFO reader replacement" >&2
	exit 1
fi
wait "$converter_pid" 2>/dev/null || true
converter_pid=""

# The supervisor starts a clean writer for the replacement handler while the
# source FIFO and producer stay alive.
exec 4<>"$fifo"
cat "$source_fifo" > "$fifo" 5>&- &
converter_pid=$!
printf 'live' >&5
live="$(dd bs=1 count=4 <&4 2>/dev/null)"
[ "$live" = "live" ]
kill -0 "$converter_pid"

exec 5>&-
exec 4<&-
wait "$converter_pid" 2>/dev/null || true
converter_pid=""
echo "converter restarted at a discontinuity while the S32 source stayed connected"
