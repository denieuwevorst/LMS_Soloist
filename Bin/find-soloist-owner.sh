#!/bin/sh

set -u

target_data_dir="${1:?data directory is required}"

for proc_dir in /proc/[0-9]*; do
	[ -r "${proc_dir}/cmdline" ] || continue
	if tr '\000' '\n' < "${proc_dir}/cmdline" 2>/dev/null | awk \
		-v target="$target_data_dir" '
			previous == "--data-dir" && $0 == target { found = 1 }
			{ previous = $0 }
			END { exit found ? 0 : 1 }
		'
	then
		basename "$proc_dir"
		exit 0
	fi
done

exit 1
