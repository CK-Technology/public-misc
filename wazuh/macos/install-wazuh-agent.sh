#!/usr/bin/env bash
#
# install-wazuh-agent.sh
# Purpose : Install and enroll the Wazuh agent on macOS (Intel + Apple silicon).
# Author  : CK Technology LLC
# Requires: root (sudo). Suitable for local run or MDM (Jamf/Addigy/Kandji/Mosyle).
#
# The agent name defaults to the machine hostname. Override any value with an
# environment variable, e.g.:
#
#   sudo WAZUH_AGENT_GROUP="default,ACME" ./install-wazuh-agent.sh
#
# NEVER hardcode a client group or an enrollment password in this public repo.
# Pass WAZUH_REGISTRATION_PASSWORD at runtime only; it is never logged.
#
set -euo pipefail

# --- Configuration (override via environment) --------------------------------
WAZUH_MANAGER="${WAZUH_MANAGER:-wazuh.cktechx.com}"   # raw IP fallback: 69.169.98.99
WAZUH_AGENT_GROUP="${WAZUH_AGENT_GROUP:-default}"
WAZUH_AGENT_NAME="${WAZUH_AGENT_NAME:-$(scutil --get ComputerName 2>/dev/null || hostname)}"
WAZUH_VERSION="${WAZUH_VERSION:-4.14.7-1}"
# WAZUH_REGISTRATION_PASSWORD is read from the environment if set (optional).

LOG_DIR="/Library/Logs/CKTech/Wazuh"
LOG_FILE="${LOG_DIR}/install.log"
CONTROL="/Library/Ossec/bin/wazuh-control"
PLIST="/Library/LaunchDaemons/com.wazuh.agent.plist"
ENVS_FILE="/tmp/wazuh_envs"   # documented mechanism read by the pkg preinstall

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root (sudo)."
mkdir -p "$LOG_DIR"
chmod 0700 "$LOG_DIR"
touch "$LOG_FILE"
chmod 0600 "$LOG_FILE"

log "=== Wazuh agent install (macOS) ==="
log "manager=${WAZUH_MANAGER} group=${WAZUH_AGENT_GROUP} name=${WAZUH_AGENT_NAME} version=${WAZUH_VERSION}"

# --- Architecture ------------------------------------------------------------
case "$(uname -m)" in
    arm64)  SUFFIX="arm64"   ;;
    x86_64) SUFFIX="intel64" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
esac

case "$WAZUH_MANAGER" in
    *[!A-Za-z0-9._-]*|'') die "WAZUH_MANAGER must be a hostname or IPv4 address." ;;
esac
case "$WAZUH_AGENT_GROUP" in
    *[!A-Za-z0-9._,-]*|'') die "WAZUH_AGENT_GROUP contains unsupported characters." ;;
esac
case "$WAZUH_AGENT_NAME" in
    *[!A-Za-z0-9._-]*|'') die "WAZUH_AGENT_NAME contains unsupported characters." ;;
esac
case "$WAZUH_VERSION" in
    *[!0-9.-]*|'') die "WAZUH_VERSION contains unsupported characters." ;;
esac

PKG_URL="https://packages.wazuh.com/4.x/macos/wazuh-agent-${WAZUH_VERSION}.${SUFFIX}.pkg"
SCRATCH_ROOT="/Library/Caches/CKTech/Wazuh"
install -d -o root -g wheel -m 0700 "$SCRATCH_ROOT"
workdir="$(mktemp -d "${SCRATCH_ROOT}/install.XXXXXX")"
pkg="${workdir}/wazuh-agent.pkg"
envs_created=0
cleanup() {
    [ "$envs_created" -eq 0 ] || rm -f "$ENVS_FILE"
    rm -rf "$workdir"
}
trap cleanup EXIT

log "Downloading ${PKG_URL}"
curl -fsSL "$PKG_URL" -o "$pkg" || die "Download failed."

# --- Enrollment env file (secrets kept out of the log) -----------------------
quote_env() {
    printf "'"
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}

if ! (umask 077; set -C; : > "$ENVS_FILE") 2>/dev/null; then
    die "${ENVS_FILE} already exists; inspect and remove it before retrying."
fi
envs_created=1
{
    printf 'WAZUH_MANAGER='; quote_env "$WAZUH_MANAGER"; printf '\n'
    printf 'WAZUH_AGENT_GROUP='; quote_env "$WAZUH_AGENT_GROUP"; printf '\n'
    printf 'WAZUH_AGENT_NAME='; quote_env "$WAZUH_AGENT_NAME"; printf '\n'
    if [ -n "${WAZUH_REGISTRATION_PASSWORD:-}" ]; then
        clean_password="$(printf '%s' "$WAZUH_REGISTRATION_PASSWORD" | tr -d '\r\n')"
        [ "$clean_password" = "$WAZUH_REGISTRATION_PASSWORD" ] ||
            die "WAZUH_REGISTRATION_PASSWORD cannot contain a newline."
        printf 'WAZUH_REGISTRATION_PASSWORD='; quote_env "$WAZUH_REGISTRATION_PASSWORD"; printf '\n'
    fi
} > "$ENVS_FILE"
chmod 600 "$ENVS_FILE"
[ -n "${WAZUH_REGISTRATION_PASSWORD:-}" ] && log "Using an enrollment password from the environment."

# --- Install -----------------------------------------------------------------
log "Installing package."
installer -pkg "$pkg" -target / || die "installer failed."

# --- Start -------------------------------------------------------------------
log "Starting agent."
if [ -f "$PLIST" ]; then
    launchctl bootstrap system "$PLIST" 2>/dev/null || "$CONTROL" start || true
else
    "$CONTROL" start || true
fi

sleep 3

# --- Verify ------------------------------------------------------------------
if "$CONTROL" status 2>/dev/null | grep -qi running; then
    log "Agent processes are running."
else
    die "Agent is not fully running. Check ${CONTROL} status."
fi

log "Recent agent log:"
tail -n 15 /Library/Ossec/logs/ossec.log 2>/dev/null | tee -a "$LOG_FILE" || true

log "Done. Verify enrollment in the manager under Agents."
