#!/usr/bin/env bash
#
# install-wazuh-agent.sh
# Purpose : Install and enroll the Wazuh agent on Linux servers/workstations.
# Author  : CK Technology LLC
# Supports: Debian/Ubuntu (apt), RHEL/Rocky/Alma/Fedora (dnf/yum), openSUSE (zypper)
#           on x86_64 and aarch64.
# Requires: root (sudo).
#
# The agent name defaults to the machine hostname, which is how Wazuh identifies
# it in the manager. Override any value with an environment variable, e.g.:
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
WAZUH_AGENT_NAME="${WAZUH_AGENT_NAME:-$(hostname)}"
WAZUH_VERSION="${WAZUH_VERSION:-4.14.6-1}"
# WAZUH_REGISTRATION_PASSWORD is read from the environment if set (optional).

LOG_DIR="/var/log/cktech/wazuh"
LOG_FILE="${LOG_DIR}/install.log"

# --- Helpers -----------------------------------------------------------------
log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root (sudo)."
mkdir -p "$LOG_DIR"

log "=== Wazuh agent install ==="
log "manager=${WAZUH_MANAGER} group=${WAZUH_AGENT_GROUP} name=${WAZUH_AGENT_NAME} version=${WAZUH_VERSION}"

# --- Detect architecture -----------------------------------------------------
case "$(uname -m)" in
    x86_64)  DEB_ARCH="amd64"; RPM_ARCH="x86_64"  ;;
    aarch64) DEB_ARCH="arm64"; RPM_ARCH="aarch64" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
esac

# --- Build the enrollment environment (kept out of logs) ---------------------
enroll_env=(
    "WAZUH_MANAGER=${WAZUH_MANAGER}"
    "WAZUH_AGENT_GROUP=${WAZUH_AGENT_GROUP}"
    "WAZUH_AGENT_NAME=${WAZUH_AGENT_NAME}"
)
if [ -n "${WAZUH_REGISTRATION_PASSWORD:-}" ]; then
    enroll_env+=("WAZUH_REGISTRATION_PASSWORD=${WAZUH_REGISTRATION_PASSWORD}")
    log "Using an enrollment password from the environment."
fi

# --- Download + install per package manager ----------------------------------
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

download() { # url dest
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1" -o "$2"
    else
        wget -q "$1" -O "$2"
    fi
}

if command -v apt-get >/dev/null 2>&1; then
    pkg="${workdir}/wazuh-agent.deb"
    url="https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_${WAZUH_VERSION}_${DEB_ARCH}.deb"
    log "Downloading ${url}"
    download "$url" "$pkg" || die "Download failed."
    log "Installing with dpkg."
    env "${enroll_env[@]}" dpkg -i "$pkg" || apt-get -f install -y
elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    pkg="${workdir}/wazuh-agent.rpm"
    url="https://packages.wazuh.com/4.x/yum/wazuh-agent-${WAZUH_VERSION}.${RPM_ARCH}.rpm"
    log "Downloading ${url}"
    download "$url" "$pkg" || die "Download failed."
    log "Installing with rpm."
    env "${enroll_env[@]}" rpm -ivh --replacepkgs "$pkg"
elif command -v zypper >/dev/null 2>&1; then
    pkg="${workdir}/wazuh-agent.rpm"
    url="https://packages.wazuh.com/4.x/yum/wazuh-agent-${WAZUH_VERSION}.${RPM_ARCH}.rpm"
    log "Downloading ${url}"
    download "$url" "$pkg" || die "Download failed."
    log "Installing with rpm."
    env "${enroll_env[@]}" rpm -ivh --replacepkgs "$pkg"
else
    die "No supported package manager found (apt-get, dnf, yum, zypper)."
fi

# --- Enable + start ----------------------------------------------------------
log "Enabling and starting wazuh-agent."
systemctl daemon-reload
systemctl enable wazuh-agent >/dev/null 2>&1 || true
systemctl restart wazuh-agent

sleep 3

# --- Verify ------------------------------------------------------------------
if systemctl is-active --quiet wazuh-agent; then
    log "Service wazuh-agent is active."
else
    log "WARNING: wazuh-agent is not active. Check journalctl -u wazuh-agent."
fi

log "Recent agent log:"
tail -n 15 /var/ossec/logs/ossec.log 2>/dev/null | tee -a "$LOG_FILE" || true

log "Done. Verify enrollment in the manager under Agents."
