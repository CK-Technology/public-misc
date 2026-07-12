# Wazuh Agent — Linux

Install, health-check, and removal for Wazuh agents on Debian/Ubuntu, RHEL/Rocky/
Alma/Fedora, and openSUSE, on `x86_64` and `aarch64`.

## Scripts

| Script | Does |
|--------|------|
| [`install-wazuh-agent.sh`](install-wazuh-agent.sh) | Detect package manager + arch, download the pinned package, enroll, enable, start, verify. |
| [`health-check-wazuh-agent.sh`](health-check-wazuh-agent.sh) | Service, configured manager, port `1514`/`1515` reachability, enrollment errors. Exit codes `0–5`. |
| [`remove-wazuh-agent.sh`](remove-wazuh-agent.sh) | Stop, purge the package, preserve `/var/ossec` to a timestamped backup. |

## Quick install

Default group only, agent name = hostname:

```bash
curl -fsSL https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/wazuh/linux/install-wazuh-agent.sh | sudo bash
```

With a client group appended at runtime (not committed to this repo):

```bash
curl -fsSL https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/wazuh/linux/install-wazuh-agent.sh -o /tmp/wz.sh
sudo WAZUH_AGENT_GROUP="default,<GROUP>" bash /tmp/wz.sh && rm /tmp/wz.sh
```

## Configuration (environment variables)

| Variable | Default | Notes |
|----------|---------|-------|
| `WAZUH_MANAGER` | `wazuh.cktechx.com` | Raw IP fallback `69.169.98.99`. |
| `WAZUH_AGENT_GROUP` | `default` | Append the client group at runtime. |
| `WAZUH_AGENT_NAME` | `$(hostname)` | How the manager identifies the host. |
| `WAZUH_VERSION` | `4.14.6-1` | Pinned agent version. |
| `WAZUH_REGISTRATION_PASSWORD` | — | Only if the manager requires authd; never committed or logged. |

## Notes

- Logs: `/var/log/cktech/wazuh/`.
- Requires outbound HTTPS to `packages.wazuh.com` and TCP `1514`/`1515` to the manager.
- The service is `wazuh-agent` (`systemctl status wazuh-agent`).
