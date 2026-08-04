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
die() { log "ERROR: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)."; exit 1; }
mkdir -p "$LOG_DIR"
chmod 0700 "$LOG_DIR"
touch "$LOG_FILE"
chmod 0600 "$LOG_FILE"

log "=== Wazuh agent removal ==="

log "Stopping and disabling service."
if systemctl list-unit-files 2>/dev/null | grep -q '^wazuh-agent'; then
    systemctl stop wazuh-agent || die "Could not stop wazuh-agent."
    systemctl disable wazuh-agent || die "Could not disable wazuh-agent."
fi

log "Removing package."
if command -v dpkg-query >/dev/null 2>&1 &&
   dpkg-query -W -f='${db:Status-Abbrev}' wazuh-agent 2>/dev/null | grep -q '^ii'; then
    apt-get remove --purge -y wazuh-agent || die "apt failed to remove wazuh-agent."
elif command -v rpm >/dev/null 2>&1 && rpm -q wazuh-agent >/dev/null 2>&1; then
    if command -v dnf >/dev/null 2>&1; then
        dnf remove -y wazuh-agent || die "dnf failed to remove wazuh-agent."
    elif command -v yum >/dev/null 2>&1; then
        yum remove -y wazuh-agent || die "yum failed to remove wazuh-agent."
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive remove wazuh-agent || die "zypper failed to remove wazuh-agent."
    else
        die "The RPM is installed but no supported package manager is available."
    fi
else
    log "Wazuh package registration is already absent."
fi

if [ -d /var/ossec ]; then
    log "Preserving /var/ossec to ${BACKUP}."
    mv /var/ossec "$BACKUP"
fi

systemctl daemon-reload 2>/dev/null || true

if systemctl list-unit-files 2>/dev/null | grep -q '^wazuh-agent'; then
    die "A wazuh-agent unit still remains."
else
    log "Service unit removed."
fi

log "Done. Backup preserved at ${BACKUP} (delete manually once confirmed)."
