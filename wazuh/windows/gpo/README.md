# Wazuh Agent — Windows Domain Deployment

Two deliberately separate deployment paths are provided:

- [`deploy-wazuh.ps1`](deploy-wazuh.ps1) is the standard reconciler for current
  environments and patched Windows 7/Server 2008 R2 systems with PowerShell 5.1.
- [`deploy-wazuh-legacy.cmd`](deploy-wazuh-legacy.cmd) is an install-if-missing
  startup script for XP-class systems. It uses a pre-staged MSI and does not
  require PowerShell or internet access.

Do not weaken the standard script to accommodate obsolete endpoints. Scope the
legacy GPO only to an explicit legacy OU or security group, and do not apply both
deployment paths to the same computer.

## Groups

Enroll new agents as `default,<CLIENT>`: `default` is the fleet baseline and the
client group supplies the later, higher-priority overrides. The client group must
already exist on the Wazuh manager.

Group membership is manager-side state. The endpoint scripts use the requested
groups only during a new enrollment and cannot verify or repair groups on an
already-enrolled agent. Check or correct existing agents on the manager:

```console
/var/ossec/bin/agent_groups -s -i <AGENT_ID>
/var/ossec/bin/agent_groups -a -i <AGENT_ID> -g <CLIENT> -q
```

## Stage the scripts

Copy the scripts to a domain-controlled location such as:

```text
\\<domain>\NETLOGON\CKTech\Wazuh\deploy-wazuh.ps1
\\<domain>\NETLOGON\CKTech\Wazuh\deploy-wazuh-legacy.cmd
```

Domain Computers need read access. Only deployment administrators should have
write access. Do not execute a mutable script from a public repository branch as
SYSTEM.

The standard script downloads the signed MSI directly from Wazuh by default. It
also accepts `-InstallerPath` when an environment requires a controlled share.

## Standard GPO scheduled task

1. Create or edit a GPO linked to the target computer OU.
2. Open **Computer Configuration → Preferences → Control Panel Settings →
   Scheduled Tasks** and create **Scheduled Task (At least Windows 7)**.
3. Configure it to run as `NT AUTHORITY\SYSTEM`, whether or not a user is logged
   on, with highest privileges.
4. Add startup and daily triggers. Enable **Run task as soon as possible after a
   scheduled start is missed**.
5. Use this action:

Program:

```text
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
```

Arguments, kept on one line for reliable copy/paste:

```text
-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "\\<domain>\NETLOGON\CKTech\Wazuh\deploy-wazuh.ps1" -AgentGroup "default,<CLIENT>"
```

To use a staged MSI, append this to the same argument line:

```text
-InstallerPath "\\<server>\share\wazuh-agent-<VERSION>.msi"
```

The script performs these actions:

- installs and enrolls a missing agent;
- upgrades an older agent to the pinned version without re-enrolling it;
- starts a stopped current-version service without downloading or reinstalling;
- repairs a missing service when MSI registration and configuration remain;
- refuses to overwrite an agent configured for another manager;
- verifies the MSI signature, installed version, manager, and running service;
- suppresses automatic reboot and removes its working MSI.

## Legacy GPO startup script

Use this only for explicitly identified systems that cannot run the standard
PowerShell script.

Wazuh documents an additional enrollment requirement for operating systems older
than Windows 7/Server 2008: run `wazuh-authd` in compatibility mode with `-a`, or
set `<ssl_auto_negotiate>yes</ssl_auto_negotiate>` in the manager's `<auth>`
configuration. Review that manager-side security tradeoff before enabling it. A
pre-generated, uniquely imported agent key avoids automatic legacy enrollment but
requires a separate per-host key workflow.

1. Put `deploy-wazuh-legacy.cmd` and its pinned MSI on a controlled
   read-only share. Verify the MSI before staging it.
2. Enable **Always wait for the network at computer startup and logon** for the
   legacy scope.
3. Add a **Computer Configuration → Policies → Windows Settings → Scripts →
   Startup** script with these three parameters:

```text
wazuh.cktechx.com default,<CLIENT> "\\<server>\share\wazuh-agent-<VERSION>.msi"
```

The batch script installs only when `WazuhSvc` is absent, starts and verifies the
service, and returns the real MSI or service failure. It deliberately does not
upgrade an installed legacy agent or accept an enrollment password.

## Standard-script parameters

| Parameter | Default | Notes |
|-----------|---------|-------|
| `-Manager` | `wazuh.cktechx.com` | Existing manager drift fails closed. |
| `-AgentGroup` | `default` | For new enrollment; use `default,<CLIENT>`. |
| `-AgentName` | `%COMPUTERNAME%` | For new enrollment. |
| `-Version` | Script pin | Must not be newer than the manager. |
| `-InstallerUrl` | Official Wazuh HTTPS URL | Mutually exclusive with `-InstallerPath`. |
| `-InstallerPath` | — | Local or UNC source copied to a unique local working file. |
| `-InstallerSha512` | — | Optional official SHA-512 pin and old-OS signature fallback. |
| `-RegistrationPasswordFile` | — | Local, ACL-protected file; never SYSVOL/NETLOGON. |

## Logs and network access

- Standard deployment log: `C:\ProgramData\CKTech\logs\wazuh_deploy.log`.
- MSI verbose logs are created only when no enrollment password is used.
- Legacy logs use `%ALLUSERSPROFILE%\CKTech\logs`.
- Standard download requires HTTPS to `packages.wazuh.com`.
- Agents require TCP `1514` for reporting and TCP `1515` for enrollment.
