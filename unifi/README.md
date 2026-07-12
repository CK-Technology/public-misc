# UniFi provisioning & adoption notes

Tailored notes for the CK Technology UniFi estate. Target controller:

- **Controller:** `unifi.cktechx.com` (`69.169.98.98`)
- **Platform:** UniFi **OS Server** (self-hosted, current) — **not** the legacy
  self-hosted Network Application, which is end-of-life.
- **API:** HTTPS on port **11443**, `X-API-KEY` auth (Network app →
  Settings → Integrations).
- **Inform port:** `8080` (devices reach the controller at
  `http://<controller>:8080/inform`).

## What lives where

- Device discovery/adoption, status, and diagnostics are built into **ghostctl**
  (`ghostctl unifi ...`). Prefer that over one-off scripts.
- Glenn Rietveld's installers (`unifi-os-server-*.sh`, `unifi-update.sh`,
  `unifi-easy-encrypt.sh`) remain upstream at <https://GlennR.nl>. We do not fork
  or vendor-modify them — they track UniFi releases and are maintained there.
- This folder holds the environment-specific glue the scripts/tool can't infer:
  DHCP Option 43 encodings, DNS discovery, and the CrowdSec whitelist.

## Scripts

Our own standalone helpers (no ghostctl required), tuned to this controller.
See [`scripts/`](scripts/):

| Script | Does |
|--------|------|
| [`option43.sh`](scripts/option43.sh) | Encode DHCP Option 43 hex for any controller IP (FortiGate / Windows / PowerShell forms). |
| [`healthcheck.sh`](scripts/healthcheck.sh) | Probe the UOS Server: control plane `:11443`, API-key auth, inform `:8080`, TLS cert expiry. |
| [`set-inform.sh`](scripts/set-inform.sh) | Discover factory devices and `set-inform` them at the controller (the no-ghostctl fallback for `ghostctl unifi adopt`). |
| [`crowdsec-whitelist.sh`](scripts/crowdsec-whitelist.sh) | Render/apply the CrowdSec whitelist (controller IP + Tailscale CGNAT) and reload. |

```bash
./scripts/option43.sh 69.169.98.98            # -> 010445a96262
UNIFI_API_KEY=... ./scripts/healthcheck.sh    # full health probe
./scripts/set-inform.sh --subnet 192.168.1.0/24 --dry-run
sudo ./scripts/crowdsec-whitelist.sh --apply
```

## Adoption discovery methods (pick one per site)

A factory device must learn the controller URL. Three ways, in order of preference:

1. **DHCP Option 43** — best for managed LANs. See
   [`dhcp-option-43/windows-ad-dhcp.md`](dhcp-option-43/windows-ad-dhcp.md)
   (Windows Server / AD) and
   [`dhcp-option-43/fortigate-dhcp.md`](dhcp-option-43/fortigate-dhcp.md).
2. **DNS record** `unifi` — devices probe `http://unifi:<informport>/inform` by
   default. See [`dhcp-option-43/dns-discovery.md`](dhcp-option-43/dns-discovery.md).
3. **`set-inform`** — direct SSH, for remote/L3 adoption where DHCP/DNS can't
   reach: `ghostctl unifi adopt --subnet <cidr>` (or manual
   `mca-cli-op set-inform http://<controller>:8080/inform`).

## Security

- Use **CrowdSec**, not fail2ban (don't run both against the same logs). The
  bouncer must sit at the reverse proxy in front of the exposed frontend to
  actually enforce. Apply the whitelist so legit device check-ins / Tailscale
  admin traffic are never banned:
  `ghostctl crowdsec unifi-exempt generate --apply`. Reference copy:
  [`crowdsec/unifi-whitelist.yaml`](crowdsec/unifi-whitelist.yaml).
- The frontend is currently internet-exposed; the plan is to move it behind
  Tailscale. Until then the whitelist + bouncer are the guardrail.
