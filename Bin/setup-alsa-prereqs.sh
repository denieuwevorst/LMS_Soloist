#!/usr/bin/env bash
#
# Installs the Debian-side prerequisites for LMS_Soloist's optional
# ALSA/apulse backend (no Pulse/PipeWire server required) and makes the
# ALSA loopback module persist across reboots.
#
# What it does:
#   - installs required Debian packages for the ALSA/apulse backend
#   - loads snd-aloop now, with enough substreams for the number of
#     players you plan to run, and persists both the module load and its
#     options so they survive a reboot
#   - detects the Lyrion service + runtime user (or accepts --lyrion-user)
#   - adds the Lyrion user to the 'audio' group if it exists
#   - restarts Lyrion so new group membership takes effect
#
# What it does NOT do:
#   - download/install the Spotify Soloist binary
#   - set your Soloist API key in the plugin
#   - configure the default Pulse/PipeWire backend (see
#     setup-debian-prereqs.sh for that)
#
# Why this script exists: a plain `sudo modprobe snd-aloop` only loads the
# module for the current boot. If it's missing after a reboot, the ALSA
# backend has no device to use -- Soloist appears to "play" normally with
# no audible output, and arecord/apulse silently fail to find the
# configured device. This script makes that failure mode much less likely
# by persisting the module load and its substream count up front.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
LYRION_USER=""
SKIP_APT=0
SUBSTREAMS=8

usage() {
	cat <<EOF
Usage:
  sudo ./${SCRIPT_NAME} [--lyrion-user USER] [--substreams N] [--skip-apt]

Options:
  --lyrion-user USER  Override auto-detection of the Lyrion service user.
  --substreams N      ALSA loopback substreams to provide (default: 8).
                       Needs to be at least the number of players you plan
                       to run through the ALSA backend at the same time.
  --skip-apt          Skip apt install/update (still configures the
                       loopback module/service).
  -h, --help          Show this help.
EOF
}

log() {
	echo "[setup-alsa-prereqs] $*"
}

die() {
	echo "[setup-alsa-prereqs] ERROR: $*" >&2
	exit 1
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--lyrion-user)
			shift
			[ "$#" -gt 0 ] || die "--lyrion-user needs a value"
			LYRION_USER="$1"
			;;
		--substreams)
			shift
			[ "$#" -gt 0 ] || die "--substreams needs a value"
			case "$1" in
				''|*[!0-9]*) die "--substreams must be a positive integer" ;;
			esac
			SUBSTREAMS="$1"
			;;
		--skip-apt)
			SKIP_APT=1
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "unknown argument: $1"
			;;
	esac
	shift
done

[ "$(id -u)" -eq 0 ] || die "run this script as root (for example: sudo ./${SCRIPT_NAME})"
command -v systemctl >/dev/null 2>&1 || die "systemctl not found"
command -v getent >/dev/null 2>&1 || die "getent not found"

detect_lyrion_service() {
	for service in lyrionmusicserver logitechmediaserver squeezeboxserver; do
		if systemctl list-unit-files "${service}.service" --no-legend 2>/dev/null | grep -q "^${service}\\.service"; then
			echo "$service"
			return 0
		fi
	done

	return 1
}

detect_lyrion_user() {
	local service="$1"
	local user

	user="$(systemctl show -p User --value "${service}.service" 2>/dev/null || true)"
	if [ -n "$user" ] && [ "$user" != "root" ]; then
		echo "$user"
		return 0
	fi

	for candidate in squeezeboxserver lms; do
		if getent passwd "$candidate" >/dev/null 2>&1; then
			echo "$candidate"
			return 0
		fi
	done

	return 1
}

ensure_packages() {
	export DEBIAN_FRONTEND=noninteractive
	log "updating apt package lists"
	apt-get update

	log "installing required Debian packages"
	apt-get install -y \
		alsa-utils \
		ffmpeg \
		python3 \
		libjson-xs-perl \
		libproc-background-perl
}

ensure_loopback_module() {
	log "writing /etc/modprobe.d/snd-aloop-soloist.conf (pcm_substreams=${SUBSTREAMS})"
	cat > /etc/modprobe.d/snd-aloop-soloist.conf <<EOF
options snd-aloop pcm_substreams=${SUBSTREAMS}
EOF

	log "persisting module load via /etc/modules-load.d/snd-aloop.conf"
	echo snd-aloop > /etc/modules-load.d/snd-aloop.conf

	if lsmod | grep -q '^snd_aloop\b'; then
		log "snd-aloop already loaded; removing and reloading so the new pcm_substreams option takes effect"
		modprobe -r snd-aloop 2>/dev/null || log "WARNING: couldn't unload snd-aloop (probably in use) -- its substream count won't change until the next reboot"
	fi

	log "loading snd-aloop"
	modprobe snd-aloop

	if ! grep -q 'Loopback' /proc/asound/cards 2>/dev/null; then
		die "snd-aloop was loaded but no 'Loopback' card shows up in /proc/asound/cards -- check 'dmesg | tail' for details"
	fi

	log "confirmed: a 'Loopback' card is present in /proc/asound/cards"
}

ensure_group_membership() {
	local user="$1"
	local group="$2"

	if ! getent group "$group" >/dev/null 2>&1; then
		log "group '$group' does not exist on this host; skipping"
		return
	fi

	if id -nG "$user" | tr ' ' '\n' | grep -qx "$group"; then
		log "user '$user' is already in group '$group'"
		return
	fi

	log "adding user '$user' to group '$group'"
	adduser "$user" "$group"
}

LYRION_SERVICE="$(detect_lyrion_service || true)"

if [ -z "$LYRION_USER" ]; then
	[ -n "$LYRION_SERVICE" ] || die "could not detect a Lyrion service; rerun with --lyrion-user <user>"
	LYRION_USER="$(detect_lyrion_user "$LYRION_SERVICE" || true)"
fi

[ -n "$LYRION_USER" ] || die "could not detect the Lyrion service user; rerun with --lyrion-user <user>"
getent passwd "$LYRION_USER" >/dev/null 2>&1 || die "no such user: $LYRION_USER"

log "using Lyrion service user: $LYRION_USER"
if [ -n "$LYRION_SERVICE" ]; then
	log "detected Lyrion service: ${LYRION_SERVICE}.service"
else
	log "no known Lyrion systemd unit detected; will skip service restart"
fi

if [ "$SKIP_APT" -eq 0 ]; then
	ensure_packages
else
	log "skipping apt install/update by request"
fi

ensure_loopback_module
ensure_group_membership "$LYRION_USER" audio

if [ -n "$LYRION_SERVICE" ]; then
	log "restarting ${LYRION_SERVICE}.service so new group membership takes effect"
	systemctl restart "${LYRION_SERVICE}.service"
fi

log "done"
log "next steps:"
log "  1. Put the Soloist binary somewhere stable (for example /usr/local/bin/soloist)"
log "  2. Paste your Soloist API key into the plugin settings in Lyrion"
log "  3. Switch the plugin's Audio backend setting to ALSA/apulse loopback"
log "  4. Leave the ALSA loopback device prefix at hw:Loopback unless your card is named differently"
log "  5. Toggle the desired players on in the plugin settings page"
