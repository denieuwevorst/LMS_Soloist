#!/bin/sh

set -eu

tmp="${TMPDIR:-/tmp}/soloist-direct-fifo-$$"
fifo="${tmp}/audio.fifo"
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir "$tmp"
mkfifo "$fifo"

# Match ProtocolHandler.pm's O_RDWR lifetime guard: descriptor 3 owns both
# ends, so separate capture writers can disconnect and reconnect without EOF.
exec 3<>"$fifo"

printf 'first' > "$fifo"
first="$(dd bs=5 count=1 <&3 2>/dev/null)"
[ "$first" = "first" ]

printf 'second' > "$fifo"
second="$(dd bs=6 count=1 <&3 2>/dev/null)"
[ "$second" = "second" ]

exec 3>&-
echo "direct FIFO reconnect behavior OK"
