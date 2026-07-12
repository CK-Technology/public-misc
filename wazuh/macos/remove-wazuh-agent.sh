#!/usr/bin/env bash
#
# remove-wazuh-agent.sh
# Purpose : Cleanly remove the Wazuh agent on macOS, preserving a backup of
#           /Library/Ossec.
# Author  : CK Technology LLC
# Requires: root (sudo).
#
set -euo pipefail

OSSEC_DIR="/Library/Ossec"
CONTROL="${OSSEC_DIR}/bin/wazuh-control"
PLIST="/Library/LaunchDaemons/com.wazuh.agent.plist"
LOG_DIR="/Library/Logs/CKTech/Wazuh"
LOG_FILE="${LOG_DIR}/remove.log"
TS="$(date '+%Y%m%d-%H%M%S')"
BACKUP="/Library/Ossec.removed-${TS}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$LOG_FILE"; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)."; exit 1; }
mkdir -p "$LOG_DIR"

log "=== Wazuh agent removal (macOS) ==="

if [ -x "$CONTROL" ]; then
    log "Stopping agent."
    "$CONTROL" stop || true
fi

if [ -f "$PLIST" ]; then
    log "Unloading launch daemon."
    launchctl bootout system "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
fi

# Forget the package receipts so a future install is clean.
for rcpt in $(pkgutil --pkgs 2>/dev/null | grep -i wazuh || true); do
    log "Forgetting receipt ${rcpt}."
    pkgutil --forget "$rcpt" || true
done

if [ -d "$OSSEC_DIR" ]; then
    log "Preserving ${OSSEC_DIR} to ${BACKUP}."
    mv "$OSSEC_DIR" "$BACKUP"
fi

log "Done. Backup preserved at ${BACKUP} (delete manually once confirmed)."
