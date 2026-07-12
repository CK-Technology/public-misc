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
WAZUH_VERSION="${WAZUH_VERSION:-4.14.6-1}"
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

log "=== Wazuh agent install (macOS) ==="
log "manager=${WAZUH_MANAGER} group=${WAZUH_AGENT_GROUP} name=${WAZUH_AGENT_NAME} version=${WAZUH_VERSION}"

# --- Architecture ------------------------------------------------------------
case "$(uname -m)" in
    arm64)  SUFFIX="arm64"   ;;
    x86_64) SUFFIX="intel64" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
esac

PKG_URL="https://packages.wazuh.com/4.x/macos/wazuh-agent-${WAZUH_VERSION}.${SUFFIX}.pkg"
workdir="$(mktemp -d)"
pkg="${workdir}/wazuh-agent.pkg"
cleanup() { rm -f "$ENVS_FILE"; rm -rf "$workdir"; }
trap cleanup EXIT

log "Downloading ${PKG_URL}"
curl -fsSL "$PKG_URL" -o "$pkg" || die "Download failed."

# --- Enrollment env file (secrets kept out of the log) -----------------------
{
    printf "WAZUH_MANAGER='%s'\n" "$WAZUH_MANAGER"
    printf "WAZUH_AGENT_GROUP='%s'\n" "$WAZUH_AGENT_GROUP"
    printf "WAZUH_AGENT_NAME='%s'\n" "$WAZUH_AGENT_NAME"
    if [ -n "${WAZUH_REGISTRATION_PASSWORD:-}" ]; then
        printf "WAZUH_REGISTRATION_PASSWORD='%s'\n" "$WAZUH_REGISTRATION_PASSWORD"
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
    log "WARNING: agent not fully running. Check ${CONTROL} status."
fi

log "Recent agent log:"
tail -n 15 /Library/Ossec/logs/ossec.log 2>/dev/null | tee -a "$LOG_FILE" || true

log "Done. Verify enrollment in the manager under Agents."
