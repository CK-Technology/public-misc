# ScreenConnect GPO Deployment

[`deploy-sc.ps1`](deploy-sc.ps1) keeps **both** ScreenConnect access agents
installed and running on domain-joined Windows devices through a GPO-managed
scheduled task. It is safe on logon, startup, and daily triggers.

Each agent is reconciled independently by instance GUID:

| State found | Action |
|---|---|
| Service running, Automatic | Nothing |
| Service stopped or disabled | Set to Automatic and started — no reinstall |
| Service missing | That instance's MSI is downloaded and installed |
| MSI registered but service missing | Stale product removed with `msiexec /x`, then installed |

The last case matters: `msiexec /i` treats a registered product as installed
and exits 0 without restoring the service, so a plain reinstall does nothing.

A healthy agent is never reinstalled, so fixing one instance does not drop
sessions on the other.

## Instance GUID mapping

| GUID               | Instance | Relay host               | MSI source |
|--------------------|----------|--------------------------|------------|
| `418b7df0387209de` | On-prem  | screlay.cktechx.com      | `https://help.cktechx.com/downloads/ScreenConnect.ClientSetup.msi` |
| `aff6f7bc2d41aa0d` | Cloud    | instance-be37od-relay.screenconnect.com | `https://cktech.screenconnect.com/Bin/ScreenConnect.ClientSetup.msi?e=Access&y=Guest` |

Detection matches the service **Name** (`ScreenConnect Client (<GUID>)`), not the
DisplayName. Override the MSI sources with `-OnPremMsiUrl` / `-CloudMsiUrl`.

## Stage the script

```text
\\<domain>\NETLOGON\CKTech\ScreenConnect\deploy-sc.ps1
```

Domain Computers need read access; only deployment administrators need write.
Do not point a SYSTEM task at the mutable `main` branch on GitHub — any push
would run as SYSTEM across the fleet. Stage a reviewed copy.

## GPO scheduled task

1. Create or edit a GPO linked to the target computer OU.
2. **Computer Configuration → Preferences → Control Panel Settings → Scheduled
   Tasks** → New → **Scheduled Task (At least Windows 7)**.
3. **General**
   - Name: `CKTech Ensure ScreenConnect`
   - Run as: `NT AUTHORITY\System`
   - Run whether user is logged on or not; Run with highest privileges.
4. **Triggers**
   - At log on — *Any user*, delay task for 1 minute (lets networking settle)
   - At startup — delay 2 minutes
   - Daily — e.g. 9:00 AM
5. **Actions** → Start a program

   Program:

   ```text
   %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
   ```

   Arguments:

   ```text
   -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "\\<domain>\NETLOGON\CKTech\ScreenConnect\deploy-sc.ps1"
   ```

6. **Settings**
   - Run task as soon as possible after a scheduled start is missed.
   - Stop the task if it runs longer than 1 hour.
   - If the task is already running: *Do not start a new instance*.

*Do not start a new instance* is what stops overlapping triggers from running
two installs at once. The script deliberately doesn't use a named mutex: any
local user could create it first and silently block the task.

## Exit codes

```text
0 = both agents installed and running
1 = at least one agent could not be brought to a running state
```

## Logs and network access

- Log: `C:\ProgramData\CKTech\logs\screenconnect_ensure.log` (rotated to `.old` at 1 MB).
- A downloaded MSI is installed only if its Authenticode signature is `Valid`
  and the signer matches that instance's publisher. The two are signed
  differently:

  | Instance | Signer | Parameter |
  |---|---|---|
  | On-prem | `CN=CK Technology LLC` | `-OnPremSignerPattern` |
  | Cloud | `CN="ConnectWise, LLC"` | `-CloudSignerPattern` |

  The patterns match the complete CN, so a certificate issued to a similarly
  named company is refused.

  If the on-prem code-signing certificate is ever replaced by one with a
  different subject, update `-OnPremSignerPattern`, or on-prem installs will
  be refused. Each run logs the status and signer.
- Requires outbound HTTPS to `help.cktechx.com` and `cktech.screenconnect.com`
  for installs, and to both relay hosts (`screlay.cktechx.com:8041`,
  `instance-be37od-relay.screenconnect.com:443`) for the agents to connect.

## Removing other ScreenConnect instances

[`../cleanup/Remove-UnapprovedScreenConnect.ps1`](../cleanup/Remove-UnapprovedScreenConnect.ps1)
removes every ScreenConnect / ConnectWise Control access agent whose GUID is not
one of the two above. It finds agents by uninstall entry, service, and install
directory under Program Files, matching names case-insensitively. It uninstalls
via `msiexec /x` when the agent is MSI-registered, then deletes any leftover
service and Program Files install directory. Both registry views and both
Program Files trees are searched, so a 32-bit PowerShell host sees everything.

If `msiexec /x` fails, the service and files are left alone so the MSI
registration isn't orphaned, and the script exits 1. Exit 1618 (another install
in progress) always waits for the next run. Otherwise, re-run with
`-ForceCleanup` to delete the service and files anyway.

The two CKTech instances are always kept and can't be removed by the script. To
also keep another agent, such as a software vendor's, pass
`-AdditionalAllowedGuids <guid>`.

Preview first:

```powershell
.\Remove-UnapprovedScreenConnect.ps1 -WhatIf
```

Or from the web (ScreenConnect backstage):

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/screenconnect/cleanup/Remove-UnapprovedScreenConnect.ps1'))) -WhatIf
```

Drop `-WhatIf` to remove. It logs to
`C:\ProgramData\CKTech\logs\screenconnect_remove.log`. Run with `-File`, it exits
1 if any unapproved agent is still present afterwards or the inventory could not
be read. The scriptblock form doesn't set an exit code; read the log's final
line instead.

An unexpected ScreenConnect agent is a common persistence mechanism in
intrusions. Check the relay host on the log's `Found service` line
before you remove it, and confirm it isn't a line-of-business vendor's support
agent.
