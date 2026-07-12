# Wazuh Agent — Windows GPO Deployment

Idempotent backfill of the Wazuh agent to domain-joined Windows devices via a
GPO-managed scheduled task, following the same pattern as the ScreenConnect GPO
deploy in this repo.

The task runs [`deploy-wazuh.ps1`](deploy-wazuh.ps1) from the web on each
trigger. The script:

- exits `0` without changes if `WazuhSvc` is already running and pointed at the
  target manager;
- otherwise downloads the pinned MSI and installs silently, setting the manager,
  group, and agent name (defaults to the computer name).

## GPO setup

1. **Group Policy Management** → create/edit a GPO linked to the OU with your
   workstations/servers.
2. **Computer Configuration → Preferences → Control Panel Settings → Scheduled
   Tasks** → New → *Scheduled Task (At least Windows 7)*.
3. **General**
   - Name: `CKTech Ensure Wazuh`
   - Run as: `NT AUTHORITY\System`
   - Run whether user is logged on or not; Run with highest privileges.
4. **Triggers** — At startup, and Daily (e.g. 9:00 AM).
5. **Actions** → Start a program:
   - Program: `powershell.exe`
   - Arguments (default `default` group only):
     ```
     -NoProfile -ExecutionPolicy Bypass -Command "irm 'https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/wazuh/windows/gpo/deploy-wazuh.ps1' | iex"
     ```
   - To pass a client group, download-then-invoke with parameters instead of a
     bare `iex` (keeps the group out of the public script):
     ```
     -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.Path]::GetTempFileName()+'.ps1'; irm 'https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/wazuh/windows/gpo/deploy-wazuh.ps1' -OutFile $s; & $s -AgentGroup 'default,<GROUP>'; Remove-Item $s"
     ```
6. **Settings** → enable *Run task as soon as possible after a scheduled start is
   missed*.

## Parameters

| Parameter | Default | Notes |
|-----------|---------|-------|
| `-Manager` | `wazuh.cktechx.com` | Raw IP fallback `69.169.98.99`. |
| `-AgentGroup` | `default` | Append the client group at runtime, e.g. `default,<GROUP>`. |
| `-AgentName` | `%COMPUTERNAME%` | How the manager identifies the endpoint. |
| `-Version` | `4.14.6-1` | Pinned agent version. |
| `-RegistrationPassword` | — | Only if the manager requires authd; never committed or logged. |

## Notes

- Targets need outbound HTTPS to `raw.githubusercontent.com` and
  `packages.wazuh.com`, and TCP `1514`/`1515` to the manager.
- Logs: `C:\ProgramData\CKScripts\wazuh_deploy.log` and a per-run MSI verbose log.
- Re-running is always safe — a healthy, correctly-pointed agent is left untouched.
