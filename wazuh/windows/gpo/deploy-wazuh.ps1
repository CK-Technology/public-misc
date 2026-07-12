#requires -Version 5.1
<#
.SYNOPSIS
Idempotent Wazuh agent deployment for GPO / RMM against domain-joined Windows.

.DESCRIPTION
Designed to run from a GPO scheduled task (or `irm ... | iex`) on every trigger.
It is safe to re-run:

  1. If WazuhSvc is running and already points at the target manager, it exits 0
     without touching anything.
  2. Otherwise it downloads the pinned Wazuh MSI and installs silently, setting
     the manager, group, and agent name (defaults to the computer name).
  3. Starts and verifies the service.

The agent name defaults to $env:COMPUTERNAME, which is how the manager will
identify the endpoint.

NEVER hardcode a client group or an enrollment password in this public repo.
Pass -AgentGroup / -RegistrationPassword at runtime (GPO parameters, RMM
variables); the password is never written to the log.

.NOTES
Author: CK Technology LLC
Logs to C:\ProgramData\CKScripts\wazuh_deploy.log
#>
[CmdletBinding()]
param(
    [string]$Manager   = 'wazuh.cktechx.com',   # raw IP fallback: 69.169.98.99
    [string]$AgentGroup = 'default',
    [string]$AgentName = $env:COMPUTERNAME,
    [string]$Version   = '4.14.6-1',
    [string]$InstallerUrl,
    [string]$RegistrationPassword
)

$ErrorActionPreference = 'Stop'

$AgentDir = 'C:\Program Files (x86)\ossec-agent'
$Conf     = Join-Path $AgentDir 'ossec.conf'
$LogDir   = 'C:\ProgramData\CKScripts'
$LogFile  = Join-Path $LogDir 'wazuh_deploy.log'

if (-not $InstallerUrl) {
    $InstallerUrl = "https://packages.wazuh.com/4.x/windows/wazuh-agent-$Version.msi"
}

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
function Log { param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'), $Message
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Value $line
}

Log '=== Wazuh GPO deploy ==='
Log "manager=$Manager group=$AgentGroup name=$AgentName version=$Version"

# --- Already installed and correct? -----------------------------------------
$svc = Get-Service -Name 'WazuhSvc' -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running' -and (Test-Path -LiteralPath $Conf)) {
    $current = ([regex]::Match((Get-Content -LiteralPath $Conf -Raw), '<address>([^<]+)</address>')).Groups[1].Value.Trim()
    if ($current -eq $Manager) {
        Log "WazuhSvc already running and pointed at $Manager. Nothing to do."
        exit 0
    }
    Log "WazuhSvc points at '$current', expected '$Manager'. Reinstalling."
}

# --- Download MSI ------------------------------------------------------------
$msi = Join-Path $env:TEMP "wazuh-agent-$Version.msi"
Log "Downloading $InstallerUrl"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $InstallerUrl -OutFile $msi -UseBasicParsing

# --- Install silently --------------------------------------------------------
$msiLog = Join-Path $LogDir "wazuh_msi_$((Get-Date -Format 'yyyyMMdd-HHmmss')).log"
$props = @(
    "WAZUH_MANAGER=`"$Manager`"",
    "WAZUH_AGENT_GROUP=`"$AgentGroup`"",
    "WAZUH_AGENT_NAME=`"$AgentName`""
)
if ($RegistrationPassword) {
    $props += "WAZUH_REGISTRATION_PASSWORD=`"$RegistrationPassword`""
    Log 'Using an enrollment password from the parameter.'
}

$arguments = @('/i', "`"$msi`"", '/q', '/L*v', "`"$msiLog`"") + $props
Log 'Running msiexec (properties not shown to avoid logging secrets).'
$proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru
Log "msiexec exit code: $($proc.ExitCode)"
if ($proc.ExitCode -notin 0, 3010) {
    Log "FAIL: MSI install returned $($proc.ExitCode). See $msiLog."
    exit $proc.ExitCode
}

# --- Start + verify ----------------------------------------------------------
Start-Sleep -Seconds 2
Set-Service -Name 'WazuhSvc' -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service -Name 'WazuhSvc' -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

$svc = Get-Service -Name 'WazuhSvc' -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
    Log 'WazuhSvc is running. Deployment complete.'
    exit 0
}

Log 'FAIL: WazuhSvc did not reach Running state.'
exit 1
