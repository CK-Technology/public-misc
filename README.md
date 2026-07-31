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

## ScreenConnect Quick Commands

Copy-paste these into a ScreenConnect backstage PowerShell session:

```powershell
# Tekla PowerFab Update
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/TeklaPowerFab/powerfabUp.ps1" | iex

# Windows Update (PSWindowsUpdate with logging)
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/winUp.ps1" | iex

# Windows Update (simple, auto-reboot)
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/UpdateWindows.ps1" | iex

# Winget - Upgrade All Packages
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/wingetUp.ps1" | iex

# Enable Windows Defender
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/enableDefender.ps1" | iex

# Bluebeam Revu 21 Recovery — pilot one workstation at a time
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/bluebeamRecovery.ps1" | iex

# FortiClient IPsec VPN Deploy
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/deploy-ipsec.ps1" | iex

# ScreenConnect Agent Install - Cloud instance
irm 'https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/screenconnect/cloud/Install-ScreenConnect.ps1' | iex

# ScreenConnect Agent Install - On-prem instance (set server URL in the script first)
irm 'https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/screenconnect/onprem/Install-ScreenConnect.ps1' | iex
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

### bluebeamRecovery.ps1

Pilot-only recovery for Revu 21 machines left with an orphaned Windows Installer product. Stages signed prior and current deployment packages before changing the machine, supplies the prior MSI during removal, installs Bluebeam's bundled prerequisites and current MSI, verifies the installed version, and prints MSI failure context automatically. Run on one workstation at a time until validated.

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
├── wazuh/
│   ├── linux/
│   │   ├── install-wazuh-agent.sh
│   │   ├── health-check-wazuh-agent.sh
│   │   └── remove-wazuh-agent.sh
│   └── macos/
│       ├── install-wazuh-agent.sh
│       ├── health-check-wazuh-agent.sh
│       └── remove-wazuh-agent.sh
├── unifi/
│   ├── crowdsec/
│   ├── dhcp-option-43/
│   └── scripts/
├── UpdateWindows.ps1
├── winUp.ps1
├── wingetUp.ps1
├── enableDefender.ps1
├── bluebeamRecovery.ps1
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
