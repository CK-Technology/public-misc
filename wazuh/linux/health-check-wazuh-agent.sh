#!/usr/bin/env bash
#
# health-check-wazuh-agent.sh
# Purpose : Report Wazuh agent health on Linux for RMM/GPO-style automation.
# Author  : CK Technology LLC
# Requires: read access to /var/ossec (run as root for full detail).
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

OSSEC_DIR="/var/ossec"
CONF="${OSSEC_DIR}/etc/ossec.conf"
AGENT_LOG="${OSSEC_DIR}/logs/ossec.log"
ENROLL_PORT="${WAZUH_ENROLL_PORT:-1515}"
REPORT_PORT="${WAZUH_REPORT_PORT:-1514}"

say() { printf '%s\n' "$*"; }

# --- Service present? --------------------------------------------------------
if ! systemctl list-unit-files 2>/dev/null | grep -q '^wazuh-agent'; then
    say "FAIL: wazuh-agent service is not installed."
    exit 1
fi

if ! systemctl is-active --quiet wazuh-agent; then
    say "FAIL: wazuh-agent service is not running."
    exit 2
fi
say "OK: wazuh-agent service is running."

# --- Configured manager ------------------------------------------------------
if [ ! -r "$CONF" ]; then
    say "FAIL: cannot read ${CONF}."
    exit 5
fi

manager="$(grep -oP '(?<=<address>)[^<]+' "$CONF" | head -n1)"
if [ -z "$manager" ]; then
    say "FAIL: no <address> found in ${CONF}."
    exit 5
fi
say "OK: configured manager is ${manager}."

# --- Reachability ------------------------------------------------------------
check_port() { # host port
    timeout 5 bash -c "echo > /dev/tcp/$1/$2" >/dev/null 2>&1
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
    if tail -n 200 "$AGENT_LOG" | grep -qiE 'Unable to connect to enrollment|Invalid password|No key received'; then
        say "FAIL: enrollment errors in ${AGENT_LOG}."
        exit 4
    fi
    if tail -n 50 "$AGENT_LOG" | grep -qi "Connected to the server"; then
        say "OK: agent reports it is connected to the server."
    fi
fi

say "HEALTHY."
exit 0
