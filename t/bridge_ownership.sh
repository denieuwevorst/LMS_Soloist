#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
finder="$root/Bin/find-soloist-owner.sh"
tmp="$(mktemp -d)"
pid=""
cleanup() {
	[ -n "$pid" ] && kill "$pid" 2>/dev/null || true
	[ -n "$pid" ] && wait "$pid" 2>/dev/null || true
	rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

data_dir="$tmp/player_3"
other_dir="$tmp/player_4"
mkdir -p "$data_dir" "$other_dir"
cat > "$tmp/fake-soloist" <<'EOF'
#!/bin/sh
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
chmod +x "$tmp/fake-soloist"

"$tmp/fake-soloist" --device-name test --data-dir "$data_dir" --ws 127.0.0.1:9999 &
pid=$!

found=""
tries=0
while [ "$tries" -lt 20 ]; do
	found="$(sh "$finder" "$data_dir" 2>/dev/null || true)"
	[ "$found" = "$pid" ] && break
	tries=$((tries + 1))
	sleep 0.05
done

[ "$found" = "$pid" ] || {
	echo "owner finder returned '${found:-none}', expected $pid" >&2
	exit 1
}
if sh "$finder" "$other_dir" >/dev/null 2>&1; then
	echo "owner finder matched an unrelated data directory" >&2
	exit 1
fi

grep -q 'bridge owner pid .*waiting instead of starting a duplicate' \
	"$root/Bin/soloist-bridge.sh"
grep -q 'adopting existing Soloist pid' "$root/Bin/soloist-bridge.sh"

echo "bridge ownership detection isolates one exact Soloist data directory"
