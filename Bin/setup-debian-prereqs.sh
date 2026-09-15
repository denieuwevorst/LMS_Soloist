#!/usr/bin/env bash
#
# Installs the Debian-side prerequisites for LMS_Soloist's current
# Pulse/PipeWire-compatible bridge design and grants the Lyrion service
# account access to that audio server.
#
# What it does:
#   - installs required Debian packages
#   - detects the Lyrion service + runtime user (or accepts --lyrion-user)
#   - if no Pulse-compatible server is reachable yet, creates/starts a
#     simple system-mode PulseAudio service
#   - adds the Lyrion user to pulse-access (and audio if that group exists)
#   - restarts Lyrion so new group membership takes effect
#
# What it does NOT do:
#   - download/install the Spotify Soloist binary
#   - set your Soloist API key in the plugin
#   - switch the plugin to an ALSA/apulse backend (it still uses the
#     per-player Pulse/PipeWire null-sink design)

set -euo pipefail

PULSEAUDIO_SERVICE_PATH="/etc/systemd/system/pulseaudio.service"
SCRIPT_NAME="$(basename "$0")"
LYRION_USER=""
SKIP_APT=0

usage() {
	cat <<EOF
Usage:
  sudo ./${SCRIPT_NAME} [--lyrion-user USER] [--skip-apt]

Options:
  --lyrion-user USER  Override auto-detection of the Lyrion service user.
  --skip-apt          Skip apt install/update (still configures service/groups).
  -h, --help          Show this help.
EOF
}

log() {
	echo "[setup-debian-prereqs] $*"
}

die() {
	echo "[setup-debian-prereqs] ERROR: $*" >&2
	exit 1
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--lyrion-user)
			shift
			[ "$#" -gt 0 ] || die "--lyrion-user needs a value"
			LYRION_USER="$1"
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
command -v runuser >/dev/null 2>&1 || die "runuser not found"

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
		pulseaudio \
		pulseaudio-utils \
		ffmpeg \
		python3 \
		libjson-xs-perl \
		libproc-background-perl
}

pulse_server_reachable() {
	local user="$1"
	command -v pactl >/dev/null 2>&1 || return 1
	runuser -u "$user" -- pactl info >/dev/null 2>&1
}

write_pulseaudio_service() {
	log "writing ${PULSEAUDIO_SERVICE_PATH}"
	cat > "${PULSEAUDIO_SERVICE_PATH}" <<'EOF'
[Unit]
Description=System-wide PulseAudio for LMS_Soloist
After=sound.target network.target

[Service]
Type=simple
ExecStart=/usr/bin/pulseaudio --system --disallow-exit --disable-shm
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
}

ensure_pulseaudio_service() {
	local user="$1"

	if pulse_server_reachable "$user"; then
		log "a Pulse-compatible server is already reachable for user '$user'; leaving the existing audio server in place"
		return
	fi

	write_pulseaudio_service

	log "enabling and starting pulseaudio.service"
	systemctl daemon-reload
	systemctl enable --now pulseaudio.service
	sleep 2

	pulse_server_reachable "$user" || die "PulseAudio still isn't reachable for user '$user' after starting pulseaudio.service"
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

ensure_pulseaudio_service "$LYRION_USER"
ensure_group_membership "$LYRION_USER" pulse-access
ensure_group_membership "$LYRION_USER" audio

if [ -n "$LYRION_SERVICE" ]; then
	log "restarting ${LYRION_SERVICE}.service so new group membership takes effect"
	systemctl restart "${LYRION_SERVICE}.service"
fi

log "done"
log "next steps:"
log "  1. Put the Soloist binary somewhere stable (for example /usr/local/bin/soloist)"
log "  2. Paste your Soloist API key into the plugin settings in Lyrion"
log "  3. Toggle the desired players on in the plugin settings page"
