<h1 align="center">Public Misc</h1>

<p align="center">
  <strong>IT Administration Scripts & Utilities</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/PowerShell-5391FE?style=for-the-badge&logo=powershell&logoColor=white" alt="PowerShell">
  <img src="https://img.shields.io/badge/Windows-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Windows">
  <img src="https://img.shields.io/badge/ScreenConnect-0078D4?style=for-the-badge&logoColor=white" alt="ScreenConnect">
</p>

---

## Overview

Collection of administration scripts and utilities used across CK Technology managed environments. The bulk are PowerShell for Windows (remote execution via ScreenConnect backstage or GPO), alongside cross-platform Wazuh agent tooling (Linux/macOS) and UniFi provisioning/adoption helpers (Bash/Python).

Windows scripts that produce logs write to `C:\ProgramData\CKTECH-Scripts\`.

## One-Liners

Copy-paste into an elevated PowerShell session (ScreenConnect backstage, RDP, or local).
All run as `irm <url> | iex` and require administrative privileges.

### Windows Updates

```powershell
# Windows Update (PSWindowsUpdate with logging)
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/winUp.ps1" | iex

# Windows Update (simple, auto-reboot)
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

### winUp.ps1

Windows Update via PSWindowsUpdate module with full transcript logging. Lists available updates with KB numbers before installing. Does not auto-reboot -- use this when you want controlled patching.

### UpdateWindows.ps1

Simplified Windows Update script. Installs PSWindowsUpdate and applies all available updates with auto-reboot. Use when you want fire-and-forget patching.

### wingetUp.ps1

Locates the winget executable and upgrades all installed packages silently. Logs output to `CKTECH-Scripts\winget.txt`.

### enableDefender.ps1

Re-enables Windows Defender real-time protection, IOAV protection, behavior monitoring, and on-access protection via both `Set-MpPreference` and registry keys. Starts the `WinDefend` and `WdNisSvc` services.

### bluebeamdiag.ps1

Read-only Windows Installer state diagnostic for Revu 21. Makes no changes -- never writes the registry, never calls `msiexec`. Reports Add/Remove Programs entries in both registry nodes, Windows Installer product registrations across **all** user contexts (including ones with missing `InstallProperties` that the other two scripts skip silently), whether each `LocalPackage` cached MSI still exists on disk, and the `HKCR:\Installer\UpgradeCodes` hive that neither other script reads. Cross-references everything against the vendor's published Revu 21 ProductCode table to name the exact residue blocking a reinstall. Run this first on any failing machine and send the log from `CKScripts\Logs\BluebeamDiag.log`.

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

Clears the orphaned Revu 21 Windows Installer registration that makes every reinstall fail with `1612` -> `1714` -> `1603`, then installs Revu from a staged MSI. Only ProductCodes published by Bluebeam for Revu 21 are eligible for removal, and only when the product has no `InstallProperties`/`LocalPackage` -- a healthy install is never touched. Removes traces from `Classes\Installer\Products`, `Features`, the `UpgradeCodes` hive (value-level), `Uninstall`, and `UserData`, exporting each key to a `.reg` under `CKScripts\RegistryBackup\<timestamp>\` first, then verifies the residue is gone. Picks its install source by reading `ProductVersion` out of each staged MSI database rather than trusting folder names. **Dry run by default** -- set `$env:BBCLEAN_APPLY='1'` to apply. Run `bluebeamdiag.ps1` first.

### deploy-ipsec.ps1

Deploys FortiClient IPsec VPN configuration from an exported XML via GPO startup script. Uses a marker file to ensure one-time import per machine. Logs to `CKTECH-Scripts\ckel_vpn_deploy.log`.

> **Note:** Update `$xmlSource`, `$password`, and `$marker` paths to match your environment before deploying.

### screenconnect/cloud/Install-ScreenConnect.ps1

Silent install of the ScreenConnect / ConnectWise Control access agent against the **cloud** instance (`cktech.screenconnect.com`). Downloads the MSI from the instance `Bin` endpoint, validates it is a real MSI (guards against HTML interstitials from hosts like Google Drive), and installs silently via `msiexec /qn`. Requires admin; skips if the agent is already present unless `-Force` is passed. Override the target with `-InstallerUrl`. Logs to `CKScripts\screenconnect_install.log`.

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
├── winUp.ps1
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
- Network share access where applicable (e.g., `\\Iron-file1\...`, `\\CKEL-FILE1\...`)
- PowerShell execution policy allows script execution (or use `-ExecutionPolicy Bypass`)

## License

MIT - See [LICENSE](LICENSE) for details.

---

<p align="center">
  CK Technology
</p>
