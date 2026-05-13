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

Collection of PowerShell scripts used across CK Technology managed environments. Designed for remote execution via ScreenConnect backstage commands or GPO deployment against Windows workstations and servers.

All scripts that produce logs write to `C:\ProgramData\CKTECH-Scripts\`.

## ScreenConnect Quick Commands

Copy-paste these into a ScreenConnect backstage PowerShell session:

```powershell
# Tekla PowerFab Update
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/main/TeklaPowerFab/powerfabUp.ps1" | iex

# Windows Update (PSWindowsUpdate with logging)
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/main/winUp.ps1" | iex

# Windows Update (simple, auto-reboot)
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/main/UpdateWindows.ps1" | iex

# Winget - Upgrade All Packages
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/main/wingetUp.ps1" | iex

# Enable Windows Defender
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/main/enableDefender.ps1" | iex

# Bluebeam Revu 21 Update
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/main/bluebeamUpdates.ps1" | iex

# FortiClient IPsec VPN Deploy
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/main/deploy-ipsec.ps1" | iex
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

### bluebeamUpdates.ps1

Automated update script for Bluebeam Revu 21. Checks the installed version against the latest available release via the winget manifest on GitHub, downloads the MSI package, and installs silently. Supports `-Force` reinstall and `-IncludeOCR` flags.

### deploy-ipsec.ps1

Deploys FortiClient IPsec VPN configuration from an exported XML via GPO startup script. Uses a marker file to ensure one-time import per machine. Logs to `CKTECH-Scripts\ckel_vpn_deploy.log`.

> **Note:** Update `$xmlSource`, `$password`, and `$marker` paths to match your environment before deploying.

## Repo Structure

```
public-misc/
├── TeklaPowerFab/
│   └── powerfabUp.ps1
├── UpdateWindows.ps1
├── winUp.ps1
├── wingetUp.ps1
├── enableDefender.ps1
├── bluebeamUpdates.ps1
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
