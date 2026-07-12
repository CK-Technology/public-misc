# Wazuh Agent — macOS

Install, health-check, and removal for Wazuh agents on macOS (Intel and Apple
silicon). Suitable for local run or MDM (Jamf, Addigy, Kandji, Mosyle).

## Scripts

| Script | Does |
|--------|------|
| [`install-wazuh-agent.sh`](install-wazuh-agent.sh) | Detect arch, download the pinned `.pkg`, enroll via `/tmp/wazuh_envs`, install, start with `launchctl`, verify. |
| [`health-check-wazuh-agent.sh`](health-check-wazuh-agent.sh) | `wazuh-control` status, configured manager, port `1514`/`1515` reachability, enrollment errors. Exit codes `0–5`. |
| [`remove-wazuh-agent.sh`](remove-wazuh-agent.sh) | Stop, unload the launch daemon, forget receipts, preserve `/Library/Ossec` to a timestamped backup. |

## Quick install

Default group only, agent name = computer name:

```bash
curl -fsSL https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/wazuh/macos/install-wazuh-agent.sh | sudo bash
```

With a client group appended at runtime (not committed to this repo):

```bash
curl -fsSL https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/wazuh/macos/install-wazuh-agent.sh -o /tmp/wz.sh
sudo WAZUH_AGENT_GROUP="default,<GROUP>" bash /tmp/wz.sh && rm /tmp/wz.sh
```

## Configuration (environment variables)

| Variable | Default | Notes |
|----------|---------|-------|
| `WAZUH_MANAGER` | `wazuh.cktechx.com` | Raw IP fallback `69.169.98.99`. |
| `WAZUH_AGENT_GROUP` | `default` | Append the client group at runtime. |
| `WAZUH_AGENT_NAME` | ComputerName | How the manager identifies the Mac. |
| `WAZUH_VERSION` | `4.14.6-1` | Pinned agent version. |
| `WAZUH_REGISTRATION_PASSWORD` | — | Only if the manager requires authd; never committed or logged. |

## Notes

- Install path: `/Library/Ossec`. Control binary: `/Library/Ossec/bin/wazuh-control`.
- Logs: `/Library/Logs/CKTech/Wazuh/`.
- MDM deployments may need Full Disk Access granted to the agent via a PPPC
  profile; a local `sudo` run and an MDM run do not have identical permissions.
- Requires outbound HTTPS to `packages.wazuh.com` and TCP `1514`/`1515` to the manager.
