#!/usr/bin/env bash
# set-inform.sh — standalone remote adoption for factory UniFi devices.
#
# Discovers factory devices on a subnet (UDP/10001) and points each at the
# controller via `mca-cli-op set-inform`. This is the no-ghostctl fallback;
# `ghostctl unifi adopt --subnet <cidr>` does the same thing natively.
#
# Run from a host that can reach the device subnet on tcp/22, where the devices
# can reach the controller on the inform port. Requires nmap + ssh (sshpass only
# for password auth).
#
# Usage:
#   ./set-inform.sh --subnet 192.168.1.0/24 [--controller HOST] [--inform-port 8080]
#                   [--user ui] [--dry-run]
#
# Env:
#   UNIFI_CONTROLLER        default controller host (default: unifi.cktechx.com)
#   UNIFI_INFORM_PORT       default inform port     (default: 8080)
#   UNIFI_ADOPT_PASSWORD    SSH password (used via SSHPASS env, never argv)
set -euo pipefail

controller="${UNIFI_CONTROLLER:-unifi.cktechx.com}"
inform_port="${UNIFI_INFORM_PORT:-8080}"
subnet=""
users=(ui ubnt)
user_override=""
dry_run=0

die() {
  echo "error: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subnet) subnet="${2:?}"; shift 2 ;;
    --controller) controller="${2:?}"; shift 2 ;;
    --inform-port) inform_port="${2:?}"; shift 2 ;;
    --user) user_override="${2:?}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h | --help)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown arg: $1" ;;
  esac
done

[[ -n "$subnet" ]] || die "--subnet is required (e.g. 192.168.1.0/24)"
command -v nmap >/dev/null || die "nmap not found"
command -v ssh >/dev/null || die "ssh not found"

password="${UNIFI_ADOPT_PASSWORD:-}"
if [[ -n "$password" ]]; then
  command -v sshpass >/dev/null || die "UNIFI_ADOPT_PASSWORD set but sshpass not found"
fi
[[ -n "$user_override" ]] && users=("$user_override")

inform_url="http://${controller}:${inform_port}/inform"
echo "Controller inform URL: $inform_url"
echo "Scanning $subnet for factory devices (udp/10001)..."

# nmap needs root for -sU; escalate if we aren't already.
nmap_cmd=(nmap -n -sU -p10001,22 "$subnet" -oG -)
[[ $EUID -ne 0 ]] && nmap_cmd=(sudo "${nmap_cmd[@]}")

mapfile -t hosts < <("${nmap_cmd[@]}" 2>/dev/null |
  awk '/10001\/open/ {print $2}' | sort -u)

if ((${#hosts[@]} == 0)); then
  echo "No factory devices found (no host with 10001/open)."
  exit 0
fi

echo "Found ${#hosts[@]} candidate device(s): ${hosts[*]}"
echo

ssh_base=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=5 -o PubkeyAuthentication=yes)

ok=0
failed=0
for host in "${hosts[@]}"; do
  remote_cmd="mca-cli-op set-inform ${inform_url}"
  if ((dry_run)); then
    echo "DRY-RUN $host: ssh <user>@$host '$remote_cmd'"
    continue
  fi

  adopted=0
  for u in "${users[@]}"; do
    echo "-> $host as $u"
    if [[ -n "$password" ]]; then
      if SSHPASS="$password" sshpass -e ssh "${ssh_base[@]}" "${u}@${host}" "$remote_cmd"; then
        adopted=1
        break
      fi
    else
      if ssh -o BatchMode=yes "${ssh_base[@]}" "${u}@${host}" "$remote_cmd"; then
        adopted=1
        break
      fi
    fi
  done

  if ((adopted)); then
    echo "   ok: pointed $host at controller"
    ok=$((ok + 1))
  else
    echo "   FAIL: could not set-inform on $host"
    failed=$((failed + 1))
  fi
done

echo
echo "Summary: ${ok} adopted, ${failed} failed, ${#hosts[@]} total."
((failed == 0))
