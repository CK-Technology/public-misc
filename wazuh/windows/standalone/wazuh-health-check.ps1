#requires -RunAsAdministrator
<#
.SYNOPSIS
Report Wazuh agent health on Windows for RMM/GPO/Intune automation.

.DESCRIPTION
Checks the WazuhSvc service, the configured manager in ossec.conf, TCP
reachability to the reporting (1514) and enrollment (1515) ports, and recent
ossec.log errors. Returns an automation-friendly exit code.

Exit codes:
  0 = healthy
  1 = service missing
  2 = service stopped
  3 = manager unreachable
  4 = enrollment failure
  5 = configuration invalid

.NOTES
Author: CK Technology LLC
Contains no credentials or customer-specific values.
#>
[CmdletBinding()]
param(
    [int]$ReportPort = 1514,
    [int]$EnrollPort = 1515
)

$AgentDir = 'C:\Program Files (x86)\ossec-agent'
$Conf     = Join-Path $AgentDir 'ossec.conf'
$AgentLog = Join-Path $AgentDir 'ossec.log'
$ClientKeys = Join-Path $AgentDir 'client.keys'

function Write-Result { param([string]$Message) Write-Host $Message }

# --- Service present? --------------------------------------------------------
$svc = Get-Service -Name 'WazuhSvc' -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Result 'FAIL: WazuhSvc is not installed.'
    exit 1
}
if ($svc.Status -ne 'Running') {
    Write-Result "FAIL: WazuhSvc is $($svc.Status)."
    exit 2
}
Write-Result 'OK: WazuhSvc is running.'

# --- Configured manager ------------------------------------------------------
if (-not (Test-Path -LiteralPath $Conf)) {
    Write-Result "FAIL: cannot read $Conf."
    exit 5
}
$manager = ([regex]::Match((Get-Content -LiteralPath $Conf -Raw), '<address>([^<]+)</address>')).Groups[1].Value.Trim()
if (-not $manager) {
    Write-Result "FAIL: no <address> in $Conf."
    exit 5
}
Write-Result "OK: configured manager is $manager."

if (-not (Test-Path -LiteralPath $ClientKeys) -or
    (Get-Item -LiteralPath $ClientKeys).Length -eq 0) {
    Write-Result "FAIL: enrollment key is missing or empty ($ClientKeys)."
    exit 4
}
Write-Result 'OK: enrollment key is present.'

# --- Reachability ------------------------------------------------------------
function Test-Port { param([string]$ComputerName, [int]$Port)
    (Test-NetConnection -ComputerName $ComputerName -Port $Port -WarningAction SilentlyContinue).TcpTestSucceeded
}

if (-not (Test-Port -ComputerName $manager -Port $ReportPort)) {
    Write-Result "FAIL: cannot reach ${manager}:$ReportPort (reporting)."
    exit 3
}
Write-Result "OK: ${manager}:$ReportPort reachable."

if (-not (Test-Port -ComputerName $manager -Port $EnrollPort)) {
    Write-Result "WARN: ${manager}:$EnrollPort (enrollment) not reachable."
}

# --- Enrollment / recent errors ----------------------------------------------
if (Test-Path -LiteralPath $AgentLog) {
    $tail = Get-Content -LiteralPath $AgentLog -Tail 200
    $lastError = -1
    $lastSuccess = -1
    for ($index = 0; $index -lt $tail.Count; $index++) {
        if ($tail[$index] -match 'Unable to connect to enrollment|Invalid password|No key received') {
            $lastError = $index
        }
        if ($tail[$index] -match 'Connected to the server') {
            $lastSuccess = $index
        }
    }
    if ($lastError -gt $lastSuccess) {
        Write-Result "FAIL: enrollment errors in $AgentLog."
        exit 4
    }
    if ($lastSuccess -ge 0) {
        Write-Result 'OK: agent reports it is connected to the server.'
    }
    else {
        Write-Result 'WARN: no connection message was found in the last 200 log lines.'
    }
}

Write-Result 'HEALTHY.'
exit 0
