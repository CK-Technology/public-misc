#!/usr/bin/env bash
#
# remove-wazuh-agent.sh
# Purpose : Cleanly remove the Wazuh agent on Linux, preserving a backup of
#           /var/ossec so enrollment material can be recovered if needed.
# Author  : CK Technology LLC
# Requires: root (sudo).
#
set -euo pipefail

LOG_DIR="/var/log/cktech/wazuh"
LOG_FILE="${LOG_DIR}/remove.log"
TS="$(date '+%Y%m%d-%H%M%S')"
BACKUP="/var/ossec.removed-${TS}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$LOG_FILE"; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)."; exit 1; }
mkdir -p "$LOG_DIR"

log "=== Wazuh agent removal ==="

log "Stopping and disabling service."
systemctl stop wazuh-agent 2>/dev/null || true
systemctl disable wazuh-agent 2>/dev/null || true

log "Removing package."
if command -v apt-get >/dev/null 2>&1; then
    apt-get remove --purge -y wazuh-agent || true
elif command -v dnf >/dev/null 2>&1; then
    dnf remove -y wazuh-agent || true
elif command -v yum >/dev/null 2>&1; then
    yum remove -y wazuh-agent || true
elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive remove wazuh-agent || true
else
    log "WARNING: no known package manager; leaving package files in place."
fi

if [ -d /var/ossec ]; then
    log "Preserving /var/ossec to ${BACKUP}."
    mv /var/ossec "$BACKUP"
fi

systemctl daemon-reload 2>/dev/null || true

if systemctl list-unit-files 2>/dev/null | grep -q '^wazuh-agent'; then
    log "WARNING: a wazuh-agent unit still remains."
else
    log "Service unit removed."
fi

log "Done. Backup preserved at ${BACKUP} (delete manually once confirmed)."
