#!/usr/bin/env bash
# Compares the pa_* symbols a binary imports against the ones this shim
# actually exports, so you can tell -- before wiring anything into LMS --
# whether this shim is a safe drop-in for a given Soloist build.
#
# Usage:
#   ./check-symbols.sh /usr/bin/soloist [/path/to/libpulse.so.0]
#
# Requires: binutils (nm, comm -- both standard on Debian/Raspberry Pi OS).

set -euo pipefail

BIN="${1:?usage: check-symbols.sh /path/to/soloist [/path/to/libpulse.so.0]}"
SHIM="${2:-$(dirname "$0")/libpulse.so.0}"

for f in "$BIN" "$SHIM"; do
	[ -f "$f" ] || { echo "not found: $f" >&2; exit 2; }
done

needed=$(nm -D --undefined-only "$BIN" 2>/dev/null | awk '{print $NF}' | grep '^pa_' | sort -u)
provided=$(nm -D --defined-only "$SHIM" 2>/dev/null | awk '{print $NF}' | grep '^pa_' | sort -u)

missing=$(comm -23 <(printf '%s\n' "$needed") <(printf '%s\n' "$provided") || true)

if [ -z "$missing" ]; then
	echo "OK: every pa_* symbol '$BIN' imports is exported by '$SHIM'."
	echo "(This does not prove runtime behavior is correct -- only that no"
	echo "symbol will be missing at dlopen/link time. Still smoke-test actual"
	echo "playback before relying on this.)"
	exit 0
fi

echo "MISSING from '$SHIM' -- '$BIN' imports these pa_* symbols but the shim"
echo "does not provide them. Soloist will fail to start (undefined symbol)"
echo "or crash the first time it calls one of these:"
echo "$missing"
exit 1
