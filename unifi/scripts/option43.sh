#!/usr/bin/env bash
# option43.sh — encode DHCP Option 43 for UniFi controller discovery.
#
# UniFi packs the controller IP into Option 43 sub-option 01, length 04, then
# the controller IPv4 as four hex bytes. Feed the output into a FortiGate DHCP
# server, Windows Server DHCP scope, or any dnsmasq/ISC config.
#
# Usage:  ./option43.sh [controller-ip]
# Default controller IP: 69.169.98.98 (unifi.cktechx.com)
set -euo pipefail

usage() {
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

ip="${1:-69.169.98.98}"

IFS='.' read -r a b c d rest <<<"$ip"
if [[ -n "${rest:-}" || -z "${d:-}" ]]; then
  echo "error: '$ip' is not a dotted-quad IPv4 address" >&2
  exit 1
fi
for octet in "$a" "$b" "$c" "$d"; do
  if ! [[ "$octet" =~ ^[0-9]+$ ]] || ((octet < 0 || octet > 255)); then
    echo "error: '$ip' has an out-of-range octet ('$octet')" >&2
    exit 1
  fi
done

hex=$(printf '%02x%02x%02x%02x' "$a" "$b" "$c" "$d")
value="0104${hex}"

echo "Controller  : $ip"
echo "Encoding    : sub-option 01, length 04, then the IP as 4 hex bytes"
echo
echo "FortiGate (set type hex, set value): ${value}"
echo "Windows DHCP (043, binary column)  : 01 04 ${hex:0:2} ${hex:2:2} ${hex:4:2} ${hex:6:2}"
echo "PowerShell (-Value)                : 0x01,0x04,0x${hex:0:2},0x${hex:2:2},0x${hex:4:2},0x${hex:6:2}"
