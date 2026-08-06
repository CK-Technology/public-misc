# ScreenConnect GPO Deployment

Idempotent backfill of **both** ScreenConnect access agents (on-prem + cloud) to
domain-joined Windows devices via a GPO-managed scheduled task.

The task runs `deploy-sc.ps1` straight from the web on each trigger. The script
checks for each agent by its instance GUID and installs **only** the missing
one(s); agents already present are left untouched.

## Files

- `deploy-sc.ps1` — the check-and-install worker. Called by the scheduled task.

It chains the canonical installers:

- On-prem: `screenconnect/onprem/Install-ScreenConnect.ps1` (screlay.cktechx.com)
- Cloud:   `screenconnect/cloud/Install-ScreenConnect.ps1` (cktech.screenconnect.com)

## Instance GUID mapping

| GUID               | Instance | Relay host               |
|--------------------|----------|--------------------------|
| `418b7df0387209de` | On-prem  | screlay.cktechx.com         |
| `aff6f7bc2d41aa0d` | Cloud    | cktech.screenconnect.com |

Detection matches the service **Name** (`ScreenConnect Client (<GUID>)`), not the
DisplayName, so cosmetic name changes won't cause false reinstalls.

## GPO setup

1. **Group Policy Management** → create/edit a GPO linked to the OU with your
   workstations.
2. **Computer Configuration → Preferences → Control Panel Settings → Scheduled
   Tasks** → New → *Scheduled Task (At least Windows 7)*.
3. **General**
   - Name: `CKTech Ensure ScreenConnect`
   - Run as: `NT AUTHORITY\System` (no stored password needed)
   - Run whether user is logged on or not; Run with highest privileges.
4. **Triggers** — add as desired:
   - At log on
   - At startup
   - Daily (e.g. 9:00 AM)
5. **Actions** → Start a program:
   - Program: `powershell.exe`
   - Arguments:
     ```
     -NoProfile -ExecutionPolicy Bypass -Command "irm 'https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/screenconnect/gpo/deploy-sc.ps1' | iex"
     ```
6. **Settings** → enable *Run task as soon as possible after a scheduled start is
   missed* so laptops that were off at 9 AM still catch up.

## Notes

- Target machines need outbound HTTPS to `raw.githubusercontent.com` (to fetch
  the scripts) and to the two relay hosts (to register the agents).
- Logs are written to `C:\ProgramData\CKTech\logs\screenconnect_ensure.log`.
- Re-running is always safe — present agents are skipped, and the installers
  themselves no-op when their instance already exists.
