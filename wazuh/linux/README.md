# Wazuh Agent — Linux

Install, health-check, and removal for Wazuh agents on Debian/Ubuntu, RHEL/Rocky/
Alma/Fedora, and openSUSE, on `x86_64` and `aarch64`.

## Scripts

| Script | Does |
|--------|------|
| [`install-wazuh-agent.sh`](install-wazuh-agent.sh) | Detect package manager + arch, download the pinned package, enroll, enable, start, verify. |
| [`migrate-wazuh-agent.sh`](migrate-wazuh-agent.sh) | Back up and move an installed agent to a new manager with automatic rollback on failure. |
| [`health-check-wazuh-agent.sh`](health-check-wazuh-agent.sh) | Service, configured manager, port `1514`/`1515` reachability, enrollment errors. Exit codes `0–5`. |
| [`remove-wazuh-agent.sh`](remove-wazuh-agent.sh) | Stop, purge the package, preserve `/var/ossec` to a timestamped backup. |

## Quick install

From a reviewed local checkout, agent name defaults to the hostname:

```bash
sudo WAZUH_AGENT_GROUP="default,<GROUP>" ./install-wazuh-agent.sh
```

For RMM automation, pin the download to a reviewed commit before executing it:

```bash
curl -fsSL https://raw.githubusercontent.com/CK-Technology/public-misc/<COMMIT>/wazuh/linux/install-wazuh-agent.sh -o /var/tmp/wz.sh
sudo WAZUH_AGENT_GROUP="default,<GROUP>" bash /var/tmp/wz.sh && rm /var/tmp/wz.sh
```

## Configuration (environment variables)

| Variable | Default | Notes |
|----------|---------|-------|
| `WAZUH_MANAGER` | `wazuh.cktechx.com` | Raw IP fallback `69.169.98.99`. |
| `WAZUH_AGENT_GROUP` | `default` | Append the client group at runtime. |
| `WAZUH_AGENT_NAME` | `$(hostname)` | How the manager identifies the host. |
| `WAZUH_VERSION` | Script pin | Override only when the manager is the same or newer. |
| `WAZUH_REGISTRATION_PASSWORD` | — | Only if the manager requires authd; never committed or logged. |

## Migrate an existing agent

Run a non-mutating preflight first:

```bash
sudo WAZUH_MANAGER="manager.example.com" \
  WAZUH_AGENT_NAME="host-01" \
  WAZUH_AGENT_GROUP="default,<GROUP>" \
  WAZUH_DRY_RUN=1 \
  ./migrate-wazuh-agent.sh
```

Remove `WAZUH_DRY_RUN=1` to migrate. The script preserves the installed package,
backs up `ossec.conf` and `client.keys` under `/var/backups`, rolls back
automatically on failure, and leaves the backup in place until central event
ingestion has been verified. It does not delete the stale record from the old
manager.

## Notes

- Logs: `/var/log/cktech/wazuh/`.
- Requires outbound HTTPS to `packages.wazuh.com` and TCP `1514`/`1515` to the manager.
- The service is `wazuh-agent` (`systemctl status wazuh-agent`).
