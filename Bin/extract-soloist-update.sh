#!/bin/sh

set -eu
umask 077

ARCHIVE=${1:-}
CANDIDATE=${2:-}

if [ -z "$ARCHIVE" ] || [ -z "$CANDIDATE" ]; then
	echo "usage: $0 ARCHIVE CANDIDATE" >&2
	exit 2
fi
if [ ! -f "$ARCHIVE" ]; then
	echo "archive not found: $ARCHIVE" >&2
	exit 1
fi

TMP="${CANDIDATE}.tmp.$$"
trap 'rm -f "$TMP"' EXIT HUP INT TERM
ulimit -f 131072

ENTRY_COUNT=$(tar -tzf "$ARCHIVE" | grep -Fxc 'soloist' || true)
if [ "$ENTRY_COUNT" -ne 1 ]; then
	echo "archive must contain exactly one top-level soloist entry" >&2
	exit 1
fi

tar -xOzf "$ARCHIVE" soloist > "$TMP"
if [ ! -s "$TMP" ]; then
	echo "archive's soloist entry is empty" >&2
	exit 1
fi

MAGIC=$(od -An -tx1 -N4 "$TMP" | tr -d ' \n')
if [ "$MAGIC" != "7f454c46" ]; then
	echo "archive's soloist entry is not an ELF executable" >&2
	exit 1
fi

chmod 0700 "$TMP"
mv -f "$TMP" "$CANDIDATE"
trap - EXIT HUP INT TERM
