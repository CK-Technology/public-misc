<h1 align="center">Sysmon Deployment</h1>

<p align="center">
  <strong>Install and reconcile Sysinternals Sysmon across Windows endpoints</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Sysmon-0078D4?style=for-the-badge&logo=microsoft&logoColor=white" alt="Sysmon">
  <img src="https://img.shields.io/badge/Windows-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Windows">
  <img src="https://img.shields.io/badge/PowerShell-5391FE?style=for-the-badge&logo=powershell&logoColor=white" alt="PowerShell">
  <img src="https://img.shields.io/badge/XML-005FAD?style=for-the-badge&logo=xml&logoColor=white" alt="XML">
</p>

---

## Overview

One reconciler, two entry points. [`gpo/deploy-sysmon.ps1`](gpo/deploy-sysmon.ps1)
does all the work; [`install-sysmon.ps1`](install-sysmon.ps1) is a thin `irm | iex`
wrapper around it for single-host work.

Each run installs a missing Sysmon, applies the configuration only when it has
drifted, and starts a stopped service without reinstalling. Safe to run
repeatedly.

## Layout

```text
sysmon/
├── install-sysmon.ps1            # irm | iex entry point for a single host
├── config/
│   └── sysmonconfig-base.xml     # unmodified sysmon-modular base - no tuning
└── gpo/
    ├── deploy-sysmon.ps1         # the reconciler
    └── README.md                 # scheduled task, parameters, exit codes
```

## Quick install

Elevated PowerShell, ScreenConnect backstage, or RDP:

```powershell
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/sysmon/install-sysmon.ps1" | iex
```

With a built configuration from a controlled share:

```powershell
$env:SYSMON_CONFIG_PATH='\\<server>\share\Sysmon\sysmonconfig.xml'
irm "https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/sysmon/install-sysmon.ps1" | iex
```

| Variable | Effect |
|---|---|
| `SYSMON_CONFIG_PATH` | Local or UNC path to a built configuration |
| `SYSMON_CONFIG_URL` | Absolute HTTPS URL to a configuration |
| `SYSMON_CONFIG_SHA256` | SHA-256 pin for the above |
| `SYSMON_VERSION` | Expected version, e.g. `15.15` |
| `SYSMON_ALLOW_UPGRADE=1` | Authorize an uninstall/reinstall binary upgrade |

Environment variables, not parameters, because `iex` has no way to pass
arguments — the same pattern as `bluebeamUpdates.ps1`.

## Fleet deployment

Use a GPO scheduled task. See [`gpo/README.md`](gpo/README.md) for the task
definition, the full parameter table, and the staging layout.

Do not point a fleet at the one-liner. It fetches a mutable branch on every run;
a GPO should execute a reviewed copy from NETLOGON.

## The base configuration is not a deployment target

[`config/sysmonconfig-base.xml`](config/sysmonconfig-base.xml) is an unmodified
[sysmon-modular](https://github.com/olafhartong/sysmon-modular) balanced build
(schema 4.90, MIT), used as the default so the scripts work out of the box.

**It carries no environment-specific tuning and will be noisy on a real fleet.**
Tuned configurations name internal hosts, service accounts, and line-of-business
software, so they are built and stored privately and delivered via
`-ConfigPath` / `SYSMON_CONFIG_PATH`.

```text
sha256  4516404fa30ee87cea558567820cdc78863cc4ab07889519e49eac3cca92e0d2
```

## Sysmon has no in-place upgrade

Running `-i` over an existing installation fails with *"the service is already
registered"*. The supported sequence is `-u force`, a reboot, then a fresh
install — which drops the driver and on a minority of endpoints leaves service
keys needing manual removal.

The reconciler therefore **refuses a binary version change and exits 2 without
changing anything** unless `-AllowBinaryUpgrade` is passed. Configuration
changes are unaffected: `-c` updates a live installation without stopping the
service.

## Logging

| Path | Contents |
|---|---|
| `C:\ProgramData\CKScripts\sysmon_deploy.log` | Deployment log |
| `C:\ProgramData\CKScripts\sysmon_config.sha256` | SHA-256 of the applied configuration |

## Security guardrail

This is a public repository. Tuned Sysmon configurations are a map of the
environment they protect — exclusion lists name real hosts, accounts, and
software. Never commit one here. Only the upstream base configuration lives in
this directory.
