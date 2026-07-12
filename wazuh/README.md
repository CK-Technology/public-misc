<h1 align="center">Wazuh Agent Deployment</h1>

<p align="center">
  <strong>Deploy, validate, and remove Wazuh agents across Windows, Linux, and macOS</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Wazuh-3B7DDD?style=for-the-badge&logo=wazuh&logoColor=white" alt="Wazuh">
  <img src="https://img.shields.io/badge/Windows-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Windows">
  <img src="https://img.shields.io/badge/Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black" alt="Linux">
  <img src="https://img.shields.io/badge/macOS-000000?style=for-the-badge&logo=apple&logoColor=white" alt="macOS">
  <img src="https://img.shields.io/badge/PowerShell-5391FE?style=for-the-badge&logo=powershell&logoColor=white" alt="PowerShell">
  <img src="https://img.shields.io/badge/Bash-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white" alt="Bash">
</p>

---

## Overview

Reusable install, health-check, and removal scripts for Wazuh agents, plus a
Windows GPO deployment and a forced-recovery uninstaller for broken MSI
installs. Every script is parameterized — no customer names, client codes, or
secrets live in this public repo.

- **Manager:** `wazuh.cktechx.com` (raw IP fallback `69.169.98.99`)
- **Agent version:** pinned to `4.14.6-1` (overridable)
- **Agent name:** defaults to the machine hostname (see below)
- **Ports:** `1514/tcp` reporting, `1515/tcp` enrollment

## Layout

```text
wazuh/
├── windows/
│   ├── standalone/
│   │   ├── wazuh-uninstaller.ps1     # forced recovery for broken MSI removal
│   │   └── wazuh-health-check.ps1
│   └── gpo/
│       ├── deploy-wazuh.ps1          # idempotent install-if-missing
│       └── README.md
├── linux/
│   ├── install-wazuh-agent.sh
│   ├── health-check-wazuh-agent.sh
│   ├── remove-wazuh-agent.sh
│   └── README.md
└── macos/
    ├── install-wazuh-agent.sh
    ├── health-check-wazuh-agent.sh
    ├── remove-wazuh-agent.sh
    └── README.md
```

## Agent name = hostname

Wazuh uses the endpoint **hostname as the agent name** when no name is supplied,
which is exactly what the *"Assign an agent name"* field in the manager's
*Deploy new agent* wizard leaves blank. These scripts set it explicitly so the
result is deterministic:

- Linux: `WAZUH_AGENT_NAME=$(hostname)`
- macOS: the computer name (`scutil --get ComputerName`, falling back to `hostname`)
- Windows: `%COMPUTERNAME%`

Override it by passing `WAZUH_AGENT_NAME` (or `-AgentName` on Windows). Agent
names must be unique and cannot be changed after enrollment.

## Groups

`WAZUH_AGENT_GROUP` defaults to `default`. To place an endpoint in additional
groups, append them **at runtime** — e.g. `WAZUH_AGENT_GROUP="default,<GROUP>"`
(or `-AgentGroup` on Windows). Client-specific group names are supplied by GPO
parameters, RMM variables, or MDM, and are **never committed to this repo**.

## Quick deploy

**Linux** (default group, hostname as name):

```bash
curl -fsSL https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/wazuh/linux/install-wazuh-agent.sh | sudo bash
```

**macOS**:

```bash
curl -fsSL https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/wazuh/macos/install-wazuh-agent.sh | sudo bash
```

**Windows** — deploy by GPO scheduled task; see
[`windows/gpo/README.md`](windows/gpo/README.md).

To append a client group, download-then-run with the group variable instead of a
bare pipe (per-OS READMEs show the exact form).

## Health checks

Each OS ships a health-check with automation-friendly exit codes:

```text
0 = healthy          3 = manager unreachable
1 = service missing  4 = enrollment failure
2 = service stopped  5 = configuration invalid
```

## Windows forced uninstaller

Use [`windows/standalone/wazuh-uninstaller.ps1`](windows/standalone/wazuh-uninstaller.ps1)
**only** when a normal uninstall fails — MSI exit `1603`, Error `1720`, a
`CustomAction_RemoveAllScript` failure, or a stale `ossec-agent` directory
blocking reinstall. It stops services, backs up the agent directory to
`C:\Wazuh-Removal-Backup-<timestamp>`, retries the MSI uninstall, and clears
orphaned services and registry keys. Reboot before reinstalling; keep the backup
until the replacement agent is confirmed healthy. Proven against the Wazuh 4.14.x
MSI `CustomAction_RemoveAllScript` failure.

## Logging

| OS | Path |
|----|------|
| Windows | `C:\ProgramData\CKScripts\` |
| Linux | `/var/log/cktech/wazuh/` |
| macOS | `/Library/Logs/CKTech/Wazuh/` |

## Security guardrail

This is a public repository. Never commit enrollment passwords, API tokens,
customer names, client group codes, private inventory, or any manager secret.
Supply those at runtime via GPO parameters, RMM/MDM variables, or a private
config store. Enrollment passwords are read from the environment/parameters only
and are never written to logs.

## License

MIT — see [LICENSE](../LICENSE) for details.

---

<p align="center">
  CK Technology
</p>
