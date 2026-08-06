<h1 align="center">Public Misc</h1>

<p align="center">
  <strong>IT Administration Scripts & Utilities</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/PowerShell-5391FE?style=for-the-badge&logo=powershell&logoColor=white" alt="PowerShell">
  <img src="https://img.shields.io/badge/Bash-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white" alt="Bash">
  <img src="https://img.shields.io/badge/Python-3776AB?style=for-the-badge&logo=python&logoColor=white" alt="Python">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Windows-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Windows">
  <img src="https://img.shields.io/badge/Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black" alt="Linux">
  <img src="https://img.shields.io/badge/macOS-000000?style=for-the-badge&logo=apple&logoColor=white" alt="macOS">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Sysmon-0078D4?style=for-the-badge&logo=microsoft&logoColor=white" alt="Sysmon">
  <img src="https://img.shields.io/badge/Wazuh-3B7DDD?style=for-the-badge&logo=wazuh&logoColor=white" alt="Wazuh">
  <img src="https://img.shields.io/badge/Grafana-F46800?style=for-the-badge&logo=grafana&logoColor=white" alt="Grafana">
  <img src="https://img.shields.io/badge/Prometheus-E6522C?style=for-the-badge&logo=prometheus&logoColor=white" alt="Prometheus">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/ScreenConnect-0078D4?style=for-the-badge&logoColor=white" alt="ScreenConnect">
  <img src="https://img.shields.io/badge/UniFi-0559C9?style=for-the-badge&logo=ubiquiti&logoColor=white" alt="UniFi">
  <img src="https://img.shields.io/badge/Tekla%20PowerFab-0063A3?style=for-the-badge&logo=trimble&logoColor=white" alt="Tekla PowerFab">
  <img src="https://img.shields.io/badge/Bluebeam-1B7FC3?style=for-the-badge&logoColor=white" alt="Bluebeam">
</p>

---

## Overview

Collection of administration scripts and utilities used across CK Technology managed environments. The bulk are PowerShell for Windows (remote execution via ScreenConnect backstage or GPO), alongside cross-platform Wazuh agent tooling (Linux/macOS) and UniFi provisioning/adoption helpers (Bash/Python).

### Where things are written

Everything a script leaves behind on Windows goes under `C:\ProgramData\CKTech\`:

| Path | Contents |
|---|---|
| `logs\` | Script logs and PowerShell transcripts |
| `state\` | Markers and applied-config hashes that decide whether a run is a no-op |
| `backups\` | Registry exports taken before a destructive change |
| `cache\` | Staged installers kept between runs |

`CKTech` matches the vendor namespace already used by `/Library/Logs/CKTech/` on
macOS and `\\<domain>\NETLOGON\CKTech\` for staged scripts. Linux uses
`/var/log/cktech/` to suit that platform's convention. The earlier
`CKScripts` and `CKTECH-Scripts` directories are gone; nothing reads them.

There is deliberately no `scripts\` directory. `%ProgramData%` grants Users
create-file and gives CREATOR OWNER full control of the result, so a directory
there that SYSTEM executes from is a privilege-escalation path. Scripts run from
NETLOGON, which is already ACL'd, or from a disposable temp directory.

## One-Liners

Copy-paste into an elevated PowerShell session (ScreenConnect backstage, RDP, or local).
All run as `irm <url> | iex` and require administrative privileges.

### Windows Updates

```powershell
# Windows Update - installs everything and reboots if an update requires it
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/UpdateWindows.ps1" | iex

# Winget - Upgrade All Packages
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/wingetUp.ps1" | iex
```

### Bluebeam Revu 21

Run the diagnostic first. The cleanup is dry run unless `BBCLEAN_APPLY=1`.

```powershell
# Diagnostics
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/bluebeamdiag.ps1" | iex

# Orphan Cleanup (dry run)
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/bluebeamclean.ps1" | iex

# Orphan Cleanup (apply)
$env:BBCLEAN_APPLY='1'; irm "https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/bluebeamclean.ps1" | iex

# Point-release Update (dry run)
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/bluebeamUpdates.ps1" | iex

# Point-release Update (apply, from a staged share -- strongly preferred)
$env:BBUPDATE_APPLY='1'; $env:BBUPDATE_SOURCE='\\Iron-file1\it\Applications\Bluebeam\21.10.0'
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/bluebeamUpdates.ps1" | iex
```

### Application Deployment

```powershell
# Tekla PowerFab Update
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/TeklaPowerFab/powerfabUp.ps1" | iex

# FortiClient IPsec VPN Deploy
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/deploy-ipsec.ps1" | iex
```

### Security

```powershell
# Enable Windows Defender
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/enableDefender.ps1" | iex

# Sysmon (installs or reconciles; uses the untuned base config)
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/sysmon/install-sysmon.ps1" | iex

# Sysmon with a built configuration from a share
$env:SYSMON_CONFIG_PATH='\\<server>\share\Sysmon\sysmonconfig.xml'
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/sysmon/install-sysmon.ps1" | iex
```

### ScreenConnect Agent

```powershell
# Cloud instance
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/screenconnect/cloud/Install-ScreenConnect.ps1" | iex

# On-prem instance (set server URL in the script first)
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/screenconnect/onprem/Install-ScreenConnect.ps1" | iex
```

## Scripts

### TeklaPowerFab/powerfabUp.ps1

Copies the Tekla PowerFab installer from a network share (`\\Iron-file1`) to the local update directory and launches it. Intended for rolling out PowerFab service packs across all PowerFab workstations.

### UpdateWindows.ps1

The Windows Update script. Installs PSWindowsUpdate, lists what is available with KB numbers, installs everything, and reboots if an update requires it. Transcript to `CKTech\logs\WindowsUpdate_<timestamp>.log`.

Pass `-NoReboot` to install and leave the endpoint pending-reboot instead. Deployed as a GPO scheduled task running as SYSTEM:

```text
-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "\\<domain>\NETLOGON\CKTech\UpdateWindows.ps1"
```

This replaced `winUp.ps1`, which was a near-duplicate. Three defects were fixed in the merge: an unscoped `Set-ExecutionPolicy -Unrestricted` that wrote the machine policy and was never restored; `$Updates = Get-WUInstall`, which is an alias of `Install-WindowsUpdate` and so installed everything a first time before the script installed it again; and a transcript path whose parent directory was never created.

### wingetUp.ps1

Upgrades all winget packages silently. Logs to `CKTech\logs\winget.log`.

Resolves `winget.exe` from `PATH` first and only falls back to the `WindowsApps` package directory — the previous version recursed the entire `WindowsApps` tree and sorted the results as strings, which ranks `1.9` above `1.22` and could select an older winget. Also passes `--accept-package-agreements`, without which any package carrying a licence prompt fails.

Under SYSTEM this reaches machine-scope packages only; winget is a per-user MSIX app and user-scope packages are invisible to it.

### enableDefender.ps1

Re-enables Windows Defender real-time protection, IOAV protection, behavior monitoring, and on-access protection via both `Set-MpPreference` and registry keys. Starts the `WinDefend` and `WdNisSvc` services.

### bluebeamdiag.ps1

Read-only Windows Installer state diagnostic for Revu 21. Makes no changes -- never writes the registry, never calls `msiexec`. Reports Add/Remove Programs entries in both registry nodes, Windows Installer product registrations across **all** user contexts (including ones with missing `InstallProperties` that the other two scripts skip silently), whether each `LocalPackage` cached MSI still exists on disk, and the `HKCR:\Installer\UpgradeCodes` hive that neither other script reads. Cross-references everything against the vendor's published Revu 21 ProductCode table to name the exact residue blocking a reinstall. Run this first on any failing machine and send the log from `CKTech\logs\BluebeamDiag.log`.

### bluebeamUpdates.ps1

Point-release updater for Revu 21. **Update-only: it never installs Revu where none is registered**, so bare machines and the legacy Revu 20 shop devices are structurally out of reach.

Before it touches anything it requires all of: exactly one vendor-published Revu 21 ProductCode registered; that code present in *both* Add/Remove Programs and the Windows Installer `UserData` hive with matching versions; a cached `LocalPackage` MSI that exists on disk *and* whose ProductCode matches the registration; no Bluebeam entries in `PendingFileRenameOperations`; no leftover `.rbs` rollback scripts; no Group Policy advertisement naming a Revu 21 ProductCode; and Revu not running. Anything else is logged as a blocking condition and nothing is changed -- a machine in that state needs `bluebeamdiag.ps1` and `bluebeamclean.ps1`, not an upgrade. The cached-MSI check is the important one: without it `RemoveExistingProducts` cannot remove the outgoing build and the upgrade dies at `1612`, which is how this fleet got broken in the first place.

The upgrade is a single `msiexec /i` transaction so a failure rolls back as a unit; there is no separate repair pass. The package is verified by Authenticode signature and its ProductCode checked against the vendor table before it is installed. Bluebeam OCR 21 is a separate product and is never modified -- it is recorded before and after so its survival is provable.

**Dry run by default.** Environment:

| Variable | Effect |
|---|---|
| `BBUPDATE_APPLY=1` | perform the upgrade (otherwise report only) |
| `BBUPDATE_SOURCE=<path>` | UNC/local directory, `.zip`, or `.msi` to update from. Set this for fleet work -- the CDN package is ~2.5 GB per machine |
| `BBUPDATE_VERSION=x.y.z` | pin the target release instead of taking the newest available |
| `BBUPDATE_FORCE=1` | close a running Revu instead of deferring |

Exit codes: `0` updated / already current / not managed, `2` blocked (machine needs remediation first), `1` failure.

### bluebeamclean.ps1

Clears the orphaned Revu 21 Windows Installer registration that makes every reinstall fail with `1612` -> `1714` -> `1603`, then installs Revu from a staged MSI. Only ProductCodes published by Bluebeam for Revu 21 are eligible for removal, and only when the product has no `InstallProperties`/`LocalPackage` -- a healthy install is never touched. Removes traces from `Classes\Installer\Products`, `Features`, the `UpgradeCodes` hive (value-level), `Uninstall`, and `UserData`, exporting each key to a `.reg` under `CKTech\backups\registry\<timestamp>\` first, then verifies the residue is gone. Picks its install source by reading `ProductVersion` out of each staged MSI database rather than trusting folder names. **Dry run by default** -- set `$env:BBCLEAN_APPLY='1'` to apply. Run `bluebeamdiag.ps1` first.

### deploy-ipsec.ps1

Deploys FortiClient IPsec VPN configuration from an exported XML via GPO startup script. Uses a marker file to ensure one-time import per machine. Logs to `CKTech\logs\ipsec_vpn_deploy.log`.

The marker moved from `C:\Temp` (world-writable — any user could suppress or force a reimport) to `CKTech\state\ipsec_vpn_imported.txt`. The old path is still checked and counts as already-imported, so machines deployed before the move do not reimport.

> **Note:** Update `$xmlSource` and `$password` to match your environment before deploying.

### screenconnect/cloud/Install-ScreenConnect.ps1

Silent install of the ScreenConnect / ConnectWise Control access agent against the **cloud** instance (`cktech.screenconnect.com`). Downloads the MSI from the instance `Bin` endpoint, validates it is a real MSI (guards against HTML interstitials from hosts like Google Drive), and installs silently via `msiexec /qn`. Requires admin; skips if the agent is already present unless `-Force` is passed. Override the target with `-InstallerUrl`. Logs to `CKTech\logs\screenconnect_install.log`.

### screenconnect/onprem/Install-ScreenConnect.ps1

Same as the cloud installer but targets the **on-prem** instance. Update the default `$InstallerUrl` in the script (currently a `REPLACE-ME` placeholder that the script refuses to run against) once the on-prem server is stood up, or pass `-InstallerUrl` at runtime.

> **Note:** Get the URL from your instance: Access tab → Build → copy the `.msi` download link. Agent installer binaries (`*.exe`/`*.msi`) are git-ignored and must never be committed to this public repo.

### wazuh/

Cross-platform Wazuh agent lifecycle scripts for Linux and macOS. Each platform folder (`linux/`, `macos/`) has an installer, health-check, and removal script that register the agent against the Wazuh manager. See [`wazuh/README.md`](wazuh/README.md) and the per-platform READMEs.

### sysmon/

Sysinternals Sysmon install and configuration reconciler for Windows. One script does the work ([`sysmon/gpo/deploy-sysmon.ps1`](sysmon/gpo/deploy-sysmon.ps1)); [`sysmon/install-sysmon.ps1`](sysmon/install-sysmon.ps1) is an `irm | iex` wrapper around it for single-host work. Each run installs a missing Sysmon, applies the configuration only when it has drifted (tracked by SHA-256 marker file, not by parsing Sysmon's version-sensitive rule blob), and starts a stopped service without reinstalling. Verifies the archive's Microsoft Authenticode signature and parses the configuration before invoking Sysmon.

Sysmon has no in-place binary upgrade, so a version mismatch **fails closed with exit code 2 and changes nothing** unless `-AllowBinaryUpgrade` is passed -- the uninstall/reinstall sequence drops the driver and needs manual cleanup on a minority of endpoints. The vendored `config/sysmonconfig-base.xml` is an unmodified sysmon-modular build with no environment tuning; real deployments supply a built configuration via `-ConfigPath`. See [`sysmon/README.md`](sysmon/README.md).

### unifi/

UniFi provisioning and adoption tooling for the self-hosted UniFi OS Server controller. Standalone Bash/Python helpers for DHCP Option 43 encoding, controller health probes, factory-device `set-inform` adoption, and a CrowdSec whitelist, plus discovery docs (DHCP/DNS). Copy `scripts/.env.example` to `.env` (git-ignored) for adoption credentials. See [`unifi/README.md`](unifi/README.md).

## Security Stack

Three of the directories here are one system, not three unrelated scripts. Sysmon
decides what an endpoint emits, the Wazuh agent ships it, and the Wazuh manager decides
what it means. They are coupled: suppressing a Sysmon event ID silently removes the
detections that depended on it.

```text
endpoint                          manager                       operator
--------                          -------                       --------
Sysmon  --> Windows Event Log --> Wazuh manager --> indexer --> Wazuh dashboard
config                 |          rules/decoders                Grafana
                  Wazuh agent                                   (Wazuh datasource,
                                                                 alongside Prometheus
                                                                 infrastructure metrics)
```

**What lives here:** the machinery that installs and reconciles agents.
[`sysmon/`](sysmon/README.md) and [`wazuh/`](wazuh/README.md) are deployment tooling —
installers, GPO scripts, health checks, one-liners. They are public so unauthenticated
fetches work from a customer network without a token.

**What does not live here:** the detection content. Tuned Sysmon overlays, Wazuh rules,
decoders, and dashboards are held in a separate **private** `security` repository.

That split is deliberate and it is not about the scripts being secret. A tuned Sysmon
configuration is an exclusion list, and an exclusion list is a written description of
what we have chosen *not* to log — the exact document an attacker would want. It also
names internal hosts, service accounts, and line-of-business software. Deployment
tooling is generic and parameterised; detection content is environment-specific
intelligence. Only the first belongs in public.

The seam between the two repositories is a file path. The reconciler here takes
`-ConfigPath` (or `SYSMON_CONFIG_PATH`); the private repo builds the configuration that
path points at. Nothing in this repo needs to know what is inside it.

## Repo Structure

```
public-misc/
├── TeklaPowerFab/
│   └── powerfabUp.ps1
├── screenconnect/
│   ├── cloud/
│   │   └── Install-ScreenConnect.ps1
│   └── onprem/
│       └── Install-ScreenConnect.ps1
├── sysmon/
│   ├── install-sysmon.ps1
│   ├── config/
│   │   └── sysmonconfig-base.xml
│   └── gpo/
│       └── deploy-sysmon.ps1
├── wazuh/
│   ├── windows/
│   │   ├── standalone/
│   │   ├── gpo/
│   │   └── intune/
│   ├── linux/
│   │   ├── install-wazuh-agent.sh
│   │   ├── health-check-wazuh-agent.sh
│   │   └── remove-wazuh-agent.sh
│   └── macos/
│       ├── install-wazuh-agent.sh
│       ├── health-check-wazuh-agent.sh
│       ├── remove-wazuh-agent.sh
│       └── intune/
├── unifi/
│   ├── crowdsec/
│   ├── dhcp-option-43/
│   └── scripts/
├── UpdateWindows.ps1
├── wingetUp.ps1
├── enableDefender.ps1
├── bluebeamdiag.ps1
├── bluebeamUpdates.ps1
├── bluebeamclean.ps1
├── deploy-ipsec.ps1
└── README.md
```

## Prerequisites

- Administrative privileges on the target machine
- Network share access where applicable (`\\<server>\...` placeholders in the scripts)
- PowerShell execution policy allows script execution (or use `-ExecutionPolicy Bypass`)

## Security guardrail

**This repository is public.** Everything committed here is world-readable and stays in
the git history after deletion. Never commit:

| Never | Why |
|---|---|
| Customer names, client codes, site names | Public inventory of who we manage |
| Tuned Sysmon configurations | An exclusion list documents what is not logged |
| Wazuh enrollment passwords, API tokens, agent keys | Direct path onto the manager |
| Agent installers (`*.exe`, `*.msi`) | ScreenConnect binaries embed instance connection info |
| Real internal hostnames, UNC paths, domain SIDs | Reconnaissance for anyone who reads it |
| VPN configuration exports, certificates, private keys | Credential material |

Supply all of it at runtime instead — GPO parameters, RMM/MDM variables, environment
variables, or a private config store. The scripts here are written to be parameterised
for exactly this reason, and they never write secrets to their logs.

Two habits that matter more than the list:

- **Prefer a staged, reviewed copy over a live branch fetch for fleet work.** The
  `irm | iex` one-liners are for a single host with an admin watching. A GPO running as
  SYSTEM should execute a reviewed copy from NETLOGON, or pin the raw URL to a commit
  and verify a hash — not track a mutable branch.
- **A leaked secret is a rotated secret.** Removing the commit is not sufficient; the
  value must be changed at the source.

If something needs to be environment-specific to be useful, that is the signal it
belongs in the private `security` repository or in Hudu, not here.

## License

MIT - See [LICENSE](LICENSE) for details.

---

<p align="center">
  CK Technology
</p>
