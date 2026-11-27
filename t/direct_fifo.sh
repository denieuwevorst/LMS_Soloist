#!/bin/sh

set -eu

tmp="${TMPDIR:-/tmp}/soloist-direct-fifo-$$"
source_fifo="${tmp}/source.fifo"
fifo="${tmp}/audio.fifo"
forward_pid=""
trap '[ -n "$forward_pid" ] && kill "$forward_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT INT TERM

mkdir "$tmp"
mkfifo "$source_fifo"
mkfifo "$fifo"

# Match the bridge lifetime guard: descriptor 3 owns both final FIFO ends even
# while LMS closes one ProtocolHandler and opens its replacement.
exec 3<>"$fifo"
exec 5<>"$source_fifo"

# Simulate the pcm-shim `cat source > final` forwarding process. It must not
# inherit either keeper; descriptors 3 and 5 belong to the bridge supervisor.
cat "$source_fifo" > "$fifo" 3>&- 5>&- &
forward_pid=$!

exec 4<"$fifo"
printf 'first' >&5
first="$(dd bs=1 count=5 <&4 2>/dev/null)"
[ "$first" = "first" ]

# A logical Spotify track change replaces the LMS reader without a read gap.
# The forwarding process must stay alive instead of exiting with SIGPIPE.
exec 4<&-
printf 'old!!' >&5
sleep 0.1
kill -0 "$forward_pid"

start="$(date +%s)"
exec 4<"$fifo"
discarded="$(dd bs=1 count=5 <&4 2>/dev/null)"
[ "$discarded" = "old!!" ]

printf 'live' >&5
live="$(dd bs=1 count=4 <&4 2>/dev/null)"
end="$(date +%s)"
[ "$live" = "live" ]
[ $(( end - start )) -lt 2 ]
kill -0 "$forward_pid"

exec 5>&-
wait "$forward_pid"
forward_pid=""
exec 4<&-
exec 3>&-
echo "continuous PCM track transition recovered at live edge without restarting capture"
