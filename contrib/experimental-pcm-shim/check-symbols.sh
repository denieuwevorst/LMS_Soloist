#!/usr/bin/env bash
# Compares the pa_* symbols a binary imports against the ones this shim
# actually exports, so you can tell -- before wiring anything into LMS --
# whether this shim is a safe drop-in for a given Soloist build.
#
# Handles both a normally dynamically-linked binary (symbols read via `nm`)
# and one that dlopen()s libpulse.so.0 at runtime, where there are no
# undefined dynamic symbols to read -- in that case falls back to scanning
# the binary's strings table for pa_* names (works because dlsym() still
# needs the literal symbol name string somewhere in the binary).
#
# Usage:
#   ./check-symbols.sh /usr/bin/soloist [/path/to/libpulse.so.0]
#
# Requires: binutils (nm) and GNU binutils' strings, both standard on
# Debian/Raspberry Pi OS.

set -euo pipefail

BIN="${1:?usage: check-symbols.sh /path/to/soloist [/path/to/libpulse.so.0]}"
SHIM="${2:-$(dirname "$0")/libpulse.so.0}"

for f in "$BIN" "$SHIM"; do
	[ -f "$f" ] || { echo "not found: $f" >&2; exit 2; }
done

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

nm -D --undefined-only "$BIN" 2>/dev/null | awk '{print $NF}' | sed 's/@.*//' | grep '^pa_' | sort -u > "$T/need"
mode="dynamically linked (nm)"
if [ ! -s "$T/need" ]; then
	mode="dlopen (names found via strings)"
	strings -n 6 "$BIN" | grep -E '^pa_[a-z0-9_]+$' | sort -u > "$T/need"
fi

if [ ! -s "$T/need" ]; then
	echo "No pa_* names found in '$BIN' (stripped, packed, or names built at runtime)."
	echo "Fall back to: LD_DEBUG=symbols $BIN 2>&1 | grep -o 'pa_[a-z0-9_]*' | sort -u"
	exit 0
fi

nm -D --defined-only "$SHIM" 2>/dev/null | awk '{print $NF}' | grep '^pa_' | sort -u > "$T/have"
missing=$(comm -23 "$T/need" "$T/have" || true)

echo "mode: $mode"
echo "names needed: $(wc -l < "$T/need")   provided by shim: $(comm -12 "$T/need" "$T/have" | wc -l)"

if [ -z "$missing" ]; then
	echo "OK: every pa_* symbol '$BIN' needs is exported by '$SHIM'."
	echo "(This does not prove runtime behavior is correct -- only that no"
	echo "symbol will be missing at dlopen/link time. Still smoke-test actual"
	echo "playback before relying on this.)"
	exit 0
fi

echo "--- NOT provided by shim (Soloist will fail to start or crash on first use):"
echo "$missing"
exit 1

