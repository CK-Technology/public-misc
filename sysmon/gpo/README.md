# Sysmon — Windows Domain Deployment

[`deploy-sysmon.ps1`](deploy-sysmon.ps1) is a reconciler. Each run installs a
missing Sysmon, applies the configuration only when the running configuration
differs from the requested one, and starts a stopped service without
reinstalling. It is safe on a startup and daily trigger.

For a single host at the console or through ScreenConnect backstage, use the
one-liner in [`../README.md`](../README.md) instead.

## What it refuses to do

Sysmon has no in-place binary upgrade. `-i` against an existing installation
fails with *"the service is already registered"*, and the supported sequence is
`-u force`, a reboot, then a fresh install. That drops the driver, loses
telemetry for the window, and on a minority of endpoints leaves `Sysmon` and
`SysmonDrv` service keys that need manual removal.

So a binary version mismatch **fails closed with exit code 2 and changes
nothing**. Pass `-AllowBinaryUpgrade` to authorize the uninstall/reinstall
deliberately, and scope that GPO to a maintenance window — not to the whole
fleet on a daily trigger.

Configuration changes are not affected by this. `-c` updates a live installation
without stopping the service, and the reconciler uses it for all drift.

## Configuration drift

The script records the SHA-256 of the configuration it last applied in
`C:\ProgramData\CKTech\state\sysmon_config.sha256` and compares against that.

That file is a security control — anything that can write it can pin a stale
configuration — so the script sets an explicit ACL on `C:\ProgramData\CKTech`
each run: SYSTEM and Administrators full control, Users read, inheritance
broken. `%ProgramData%` otherwise grants Users create-file with CREATOR OWNER
full control over what they create.

It does not read Sysmon's own compiled rule blob under the driver's `Parameters`
key. That blob's layout changes between Sysmon versions and the driver name is
not guaranteed to be `SysmonDrv`, so parsing it would break silently on a
version bump. The tradeoff is that deleting the marker file causes one redundant
`-c` on the next run, which is harmless.

## Which configuration

With no config parameter the script fetches
[`../config/sysmonconfig-base.xml`](../config/sysmonconfig-base.xml), an
unmodified sysmon-modular build. **It carries no environment-specific tuning and
will be noisy on a real fleet.** It is a starting point, not a deployment target.

Point `-ConfigPath` at a built configuration on a controlled share for anything
real. Tuned configurations name internal hosts, service accounts, and line-of-
business software, and do not belong in a public repository.

## Stage the script

```text
\\<domain>\NETLOGON\CKTech\Sysmon\deploy-sysmon.ps1
\\<domain>\NETLOGON\CKTech\Sysmon\sysmonconfig.xml
```

Domain Computers need read access. Only deployment administrators should have
write access. Do not execute a mutable public branch as SYSTEM — stage a
reviewed copy, or pin `-ConfigUrl` to a commit and supply `-ConfigSha256`.

## GPO scheduled task

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
-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "\\<domain>\NETLOGON\CKTech\Sysmon\deploy-sysmon.ps1" -ConfigPath "\\<domain>\NETLOGON\CKTech\Sysmon\sysmonconfig.xml"
```

To avoid the Sysinternals download on every new install, stage the archive and
append:

```text
-SysmonZipPath "\\<server>\share\Sysmon.zip" -SysmonZipSha256 <SHA256>
```

## Parameters

| Parameter | Default | Notes |
|-----------|---------|-------|
| `-ConfigPath` | — | Local or UNC configuration. Mutually exclusive with `-ConfigUrl`. |
| `-ConfigUrl` | Vendored base config | Absolute HTTPS. Pin to a commit for production. |
| `-ConfigSha256` | — | Required in practice whenever `-ConfigUrl` names a branch. |
| `-Version` | — | Expected `X.Y`, e.g. `15.15`. A mismatch fails closed. |
| `-SysmonZipPath` | — | Staged archive. Mutually exclusive with `-SysmonZipUrl`. |
| `-SysmonZipUrl` | Official Sysinternals HTTPS URL | |
| `-SysmonZipSha256` | — | Optional pin for the archive. |
| `-AllowBinaryUpgrade` | off | Authorizes `-u force` and reinstall. Disruptive. |

## Exit codes

```text
0 = installed, running, and on the requested configuration
1 = failure
2 = refused - a deliberate decision is required; nothing was changed
```

Exit code 2 is not an error to retry. It means the requested binary version
differs from what is installed and the script declined to drop the driver
unattended.

## Verification

The script fails rather than reporting success when any of these do not hold:

- the Sysmon archive carries a valid Authenticode signature from Microsoft;
- the configuration parses as XML with a `Sysmon` root element, checked before
  Sysmon is invoked so a truncated download is caught early;
- a Sysmon binary is present in `%windir%` afterwards;
- the service reaches `Running` and is set to `Automatic`;
- the applied-configuration marker matches what was requested.

## Logs and network access

- Deployment log: `C:\ProgramData\CKTech\logs\sysmon_deploy.log`.
- Applied-config marker: `C:\ProgramData\CKTech\state\sysmon_config.sha256`.
- Requires HTTPS to `download.sysinternals.com` unless `-SysmonZipPath` is used.
- Requires HTTPS to `raw.githubusercontent.com` unless `-ConfigPath` is used.
