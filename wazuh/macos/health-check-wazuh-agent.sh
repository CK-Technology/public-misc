#!/usr/bin/env bash
#
# health-check-wazuh-agent.sh
# Purpose : Report Wazuh agent health on macOS for MDM/automation.
# Author  : CK Technology LLC
# Requires: root for full detail.
#
# Exit codes:
#   0 = healthy
#   1 = service missing
#   2 = service stopped
#   3 = manager unreachable
#   4 = enrollment failure
#   5 = configuration invalid
#
set -uo pipefail

OSSEC_DIR="/Library/Ossec"
CONTROL="${OSSEC_DIR}/bin/wazuh-control"
CONF="${OSSEC_DIR}/etc/ossec.conf"
AGENT_LOG="${OSSEC_DIR}/logs/ossec.log"
KEYS="${OSSEC_DIR}/etc/client.keys"
ENROLL_PORT="${WAZUH_ENROLL_PORT:-1515}"
REPORT_PORT="${WAZUH_REPORT_PORT:-1514}"

say() { printf '%s\n' "$*"; }

# --- Installed? --------------------------------------------------------------
if [ ! -x "$CONTROL" ]; then
    say "FAIL: Wazuh agent is not installed (${CONTROL} missing)."
    exit 1
fi

if ! "$CONTROL" status 2>/dev/null | grep -qi running; then
    say "FAIL: Wazuh agent is not running."
    exit 2
fi
say "OK: Wazuh agent is running."

# --- Configured manager ------------------------------------------------------
if [ ! -r "$CONF" ]; then
    say "FAIL: cannot read ${CONF}."
    exit 5
fi

manager="$(sed -n 's:.*<address>\(.*\)</address>.*:\1:p' "$CONF" | head -n1)"
if [ -z "$manager" ]; then
    say "FAIL: no <address> found in ${CONF}."
    exit 5
fi
say "OK: configured manager is ${manager}."

if [ ! -s "$KEYS" ]; then
    say "FAIL: enrollment key is missing or empty (${KEYS})."
    exit 4
fi
say "OK: enrollment key is present."

# --- Reachability ------------------------------------------------------------
check_port() { # host port
    /usr/bin/nc -z -G 5 "$1" "$2" >/dev/null 2>&1
}

if ! check_port "$manager" "$REPORT_PORT"; then
    say "FAIL: cannot reach ${manager}:${REPORT_PORT} (reporting)."
    exit 3
fi
say "OK: ${manager}:${REPORT_PORT} reachable."

if ! check_port "$manager" "$ENROLL_PORT"; then
    say "WARN: ${manager}:${ENROLL_PORT} (enrollment) not reachable."
fi

# --- Enrollment / recent errors ----------------------------------------------
if [ -r "$AGENT_LOG" ]; then
    recent_log="$(tail -n 200 "$AGENT_LOG")"
    last_error="$(printf '%s\n' "$recent_log" | grep -niE 'Unable to connect to enrollment|Invalid password|No key received' | tail -n1 | cut -d: -f1)"
    last_success="$(printf '%s\n' "$recent_log" | grep -ni 'Connected to the server' | tail -n1 | cut -d: -f1)"
    if [ -n "$last_error" ] && { [ -z "$last_success" ] || [ "$last_error" -gt "$last_success" ]; }; then
        say "FAIL: enrollment errors in ${AGENT_LOG}."
        exit 4
    fi
    if [ -n "$last_success" ]; then
        say "OK: agent reports it is connected to the server."
    else
        say "WARN: no connection message was found in the last 200 log lines."
    fi
fi

say "HEALTHY."
exit 0
