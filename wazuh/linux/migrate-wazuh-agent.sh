#!/usr/bin/env bash
#
# migrate-wazuh-agent.sh
# Purpose : Move an installed Linux Wazuh agent to a different manager without
#           uninstalling the package.
# Author  : CK Technology LLC
# Requires: root, systemd, and an existing Wazuh agent installation.
#
# Configuration is supplied at runtime. Never hardcode enrollment passwords or
# client-specific groups in this public repository.
#
set -euo pipefail

WAZUH_MANAGER="${WAZUH_MANAGER:-}"
WAZUH_AGENT_GROUP="${WAZUH_AGENT_GROUP:-default}"
WAZUH_AGENT_NAME="${WAZUH_AGENT_NAME:-$(hostname)}"
WAZUH_ENROLL_PORT="${WAZUH_ENROLL_PORT:-1515}"
WAZUH_REPORT_PORT="${WAZUH_REPORT_PORT:-1514}"
WAZUH_DRY_RUN="${WAZUH_DRY_RUN:-0}"
WAZUH_FORCE_REENROLL="${WAZUH_FORCE_REENROLL:-0}"

OSSEC_DIR="/var/ossec"
CONFIG="${OSSEC_DIR}/etc/ossec.conf"
KEYS="${OSSEC_DIR}/etc/client.keys"
AGENT_AUTH="${OSSEC_DIR}/bin/agent-auth"
AGENT_CONTROL="${OSSEC_DIR}/bin/wazuh-agentd"
LOG_DIR="/var/log/cktech/wazuh"
LOG_FILE="${LOG_DIR}/migrate.log"
BACKUP_DIR="/var/backups/wazuh-agent-migration-$(date -u '+%Y%m%dT%H%M%SZ')"
changed=0

usage() {
    cat <<'EOF'
Usage:
  sudo WAZUH_MANAGER=manager.example.com \
    WAZUH_AGENT_NAME=host-01 \
    WAZUH_AGENT_GROUP=default,CLIENT \
    ./migrate-wazuh-agent.sh

Optional environment variables:
  WAZUH_ENROLL_PORT=1515
  WAZUH_REPORT_PORT=1514
  WAZUH_REGISTRATION_PASSWORD=...  # runtime only; never logged
  WAZUH_DRY_RUN=1                  # preflight only; no changes
  WAZUH_FORCE_REENROLL=1           # allow enrollment to same manager

The script preserves the installed package, backs up ossec.conf and
client.keys, enrolls a new key, and automatically restores the backup if a
migration step fails.
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    printf 'ERROR: Run as root (sudo).\n' >&2
    exit 1
fi

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 0600 "$LOG_FILE"

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$LOG_FILE"
}

die() {
    log "ERROR: $*"
    if [ "$changed" -eq 1 ]; then
        rollback
        changed=0
    fi
    exit 1
}

rollback() {
    if [ "$changed" -eq 1 ] && [ -d "$BACKUP_DIR" ]; then
        log "Migration failed; restoring the previous configuration and key."
        cp -a "$BACKUP_DIR/ossec.conf" "$CONFIG"
        cp -a "$BACKUP_DIR/client.keys" "$KEYS"
        systemctl restart wazuh-agent || true
    fi
}

on_error() {
    rc=$?
    rollback
    unset WAZUH_REGISTRATION_PASSWORD
    exit "$rc"
}

trap on_error ERR

command -v systemctl >/dev/null 2>&1 || die "systemd is required."
command -v timeout >/dev/null 2>&1 || die "timeout is required."
[ -x "$AGENT_AUTH" ] || die "Existing Wazuh agent-auth was not found at ${AGENT_AUTH}."
[ -r "$CONFIG" ] || die "Cannot read ${CONFIG}."
[ -e "$KEYS" ] || die "Agent key file does not exist at ${KEYS}."
systemctl is-active --quiet wazuh-agent || die "wazuh-agent must be active before migration."

case "$WAZUH_MANAGER" in
    *[!A-Za-z0-9._-]*|'') die "WAZUH_MANAGER must be a hostname or IPv4 address." ;;
esac
case "$WAZUH_AGENT_NAME" in
    *[!A-Za-z0-9._-]*|'') die "WAZUH_AGENT_NAME contains unsupported characters." ;;
esac
case "$WAZUH_AGENT_GROUP" in
    *[!A-Za-z0-9._,-]*|'') die "WAZUH_AGENT_GROUP contains unsupported characters." ;;
esac
case "$WAZUH_ENROLL_PORT:$WAZUH_REPORT_PORT" in
    *[!0-9:]*) die "Wazuh ports must be numeric." ;;
esac

current_manager="$(sed -n 's:.*<address>\([^<]*\)</address>.*:\1:p' "$CONFIG" | head -1)"
[ -n "$current_manager" ] || die "No manager <address> was found in ${CONFIG}."

if [ "$current_manager" = "$WAZUH_MANAGER" ] && [ "$WAZUH_FORCE_REENROLL" != "1" ]; then
    die "Agent already targets ${WAZUH_MANAGER}; set WAZUH_FORCE_REENROLL=1 only for deliberate key replacement."
fi

log "Preflight: current_manager=${current_manager} new_manager=${WAZUH_MANAGER} name=${WAZUH_AGENT_NAME} groups=${WAZUH_AGENT_GROUP}"

getent ahosts "$WAZUH_MANAGER" >/dev/null 2>&1 || die "Cannot resolve ${WAZUH_MANAGER}."
timeout 5 bash -c "</dev/tcp/${WAZUH_MANAGER}/${WAZUH_ENROLL_PORT}" 2>/dev/null ||
    die "Cannot reach ${WAZUH_MANAGER}:${WAZUH_ENROLL_PORT}."
timeout 5 bash -c "</dev/tcp/${WAZUH_MANAGER}/${WAZUH_REPORT_PORT}" 2>/dev/null ||
    die "Cannot reach ${WAZUH_MANAGER}:${WAZUH_REPORT_PORT}."

if [ "$WAZUH_DRY_RUN" = "1" ]; then
    log "Dry run passed; no files or services were changed."
    exit 0
fi
[ "$WAZUH_DRY_RUN" = "0" ] || die "WAZUH_DRY_RUN must be 0 or 1."

[ ! -e "$BACKUP_DIR" ] || die "Backup path already exists: ${BACKUP_DIR}."
install -d -o root -g root -m 0700 "$BACKUP_DIR"
cp -a "$CONFIG" "$BACKUP_DIR/ossec.conf"
cp -a "$KEYS" "$BACKUP_DIR/client.keys"
log "Rollback backup created at ${BACKUP_DIR}."

systemctl stop wazuh-agent
changed=1

# Replace only the first manager address; additional failover servers remain
# untouched so the operator can review them deliberately.
escaped_manager="${WAZUH_MANAGER//&/\\&}"
sed -i "0,/<address>[^<]*<\\/address>/s//<address>${escaped_manager}<\\/address>/" "$CONFIG"
grep -q "<address>${WAZUH_MANAGER}</address>" "$CONFIG" ||
    die "Manager address replacement failed."

: > "$KEYS"
chown --reference="$BACKUP_DIR/client.keys" "$KEYS"
chmod --reference="$BACKUP_DIR/client.keys" "$KEYS"

auth_args=(
    -m "$WAZUH_MANAGER"
    -p "$WAZUH_ENROLL_PORT"
    -A "$WAZUH_AGENT_NAME"
    -G "$WAZUH_AGENT_GROUP"
)
if [ -n "${WAZUH_REGISTRATION_PASSWORD:-}" ]; then
    auth_args+=( -P "$WAZUH_REGISTRATION_PASSWORD" )
    log "Using an enrollment password supplied at runtime."
fi

"$AGENT_AUTH" "${auth_args[@]}"
unset WAZUH_REGISTRATION_PASSWORD
[ -s "$KEYS" ] || die "Enrollment completed without writing an agent key."

if [ -x "$AGENT_CONTROL" ]; then
    "$AGENT_CONTROL" -t >/dev/null
fi

systemctl restart wazuh-agent
systemctl is-active --quiet wazuh-agent || die "wazuh-agent did not become active."

enrolled_name="$(awk 'NF { print $2; exit }' "$KEYS")"
[ "$enrolled_name" = "$WAZUH_AGENT_NAME" ] ||
    die "Enrolled key name does not match ${WAZUH_AGENT_NAME}."

trap - ERR
changed=0
log "Migration completed successfully. Verify the active agent and event ingestion on the manager."
log "Keep ${BACKUP_DIR} until central verification and the rollback window are complete."
