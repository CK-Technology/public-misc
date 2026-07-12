#!/usr/bin/env bash
# healthcheck.sh — quick health probe for a self-hosted UniFi OS Server.
#
# Checks, in order:
#   1. HTTPS control plane reachable on :11443
#   2. API key authenticates against the Network integration API (if UNIFI_API_KEY set)
#   3. Device inform port reachable on :8080
#   4. TLS certificate expiry
#
# Env (all optional; defaults tuned for unifi.cktechx.com):
#   UNIFI_CONTROLLER   host           (default: unifi.cktechx.com)
#   UNIFI_HTTPS_PORT   control port   (default: 11443)
#   UNIFI_INFORM_PORT  inform port    (default: 8080)
#   UNIFI_SITE         site name      (default: default)
#   UNIFI_API_KEY      integration API key (skips auth check if unset)
#
# Exit code is non-zero if any hard check fails.
set -euo pipefail

controller="${UNIFI_CONTROLLER:-unifi.cktechx.com}"
https_port="${UNIFI_HTTPS_PORT:-11443}"
inform_port="${UNIFI_INFORM_PORT:-8080}"
site="${UNIFI_SITE:-default}"
api_key="${UNIFI_API_KEY:-}"

fail=0
pass() { printf '  [ ok ] %s\n' "$1"; }
warn() { printf '  [warn] %s\n' "$1"; }
bad() {
  printf '  [FAIL] %s\n' "$1"
  fail=1
}

port_open() { # host port
  timeout 5 bash -c ">/dev/tcp/$1/$2" 2>/dev/null
}

echo "UniFi OS Server health: $controller"

# 1. control plane
if curl -skf --max-time 8 "https://${controller}:${https_port}/" -o /dev/null; then
  pass "control plane reachable on :${https_port}"
else
  # a UOS login page returns 200/302 on / but curl -f trips on some redirects;
  # fall back to a bare TCP check so we distinguish "down" from "odd status".
  if port_open "$controller" "$https_port"; then
    warn "control plane TCP open but HTTP check non-2xx on :${https_port}"
  else
    bad "control plane unreachable on :${https_port}"
  fi
fi

# 2. API auth
if [[ -n "$api_key" ]]; then
  code=$(curl -sk --max-time 8 -o /dev/null -w '%{http_code}' \
    -H "X-API-KEY: ${api_key}" \
    "https://${controller}:${https_port}/proxy/network/integration/v1/sites" || echo 000)
  case "$code" in
    200) pass "API key authenticates (integration /sites 200)" ;;
    401 | 403) bad "API key rejected (HTTP ${code}) — check key/scope" ;;
    000) bad "API auth request failed (no response)" ;;
    *) warn "API /sites returned HTTP ${code} (site '${site}')" ;;
  esac
else
  warn "UNIFI_API_KEY unset — skipping auth check"
fi

# 3. inform port
if port_open "$controller" "$inform_port"; then
  pass "inform port reachable on :${inform_port}"
else
  bad "inform port unreachable on :${inform_port} (devices can't check in)"
fi

# 4. cert expiry
if command -v openssl >/dev/null 2>&1; then
  end=$(echo | timeout 8 openssl s_client -connect "${controller}:${https_port}" 2>/dev/null |
    openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)
  if [[ -n "$end" ]]; then
    end_epoch=$(date -d "$end" +%s 2>/dev/null || echo 0)
    now=$(date +%s)
    days=$(((end_epoch - now) / 86400))
    if ((end_epoch == 0)); then
      warn "could not parse cert expiry"
    elif ((days < 0)); then
      bad "TLS cert EXPIRED ($end)"
    elif ((days < 14)); then
      warn "TLS cert expires in ${days}d ($end)"
    else
      pass "TLS cert valid ${days}d ($end)"
    fi
  else
    warn "could not read TLS cert"
  fi
else
  warn "openssl not found — skipping cert check"
fi

echo
if ((fail)); then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: ok"
