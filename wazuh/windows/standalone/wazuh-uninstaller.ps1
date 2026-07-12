#requires -RunAsAdministrator

<#
.SYNOPSIS
Force-removes a broken Wazuh Windows agent installation.

.DESCRIPTION
Use this script only when the normal Wazuh MSI uninstall fails, commonly
with MSI exit code 1603 or Error 1720 from CustomAction_RemoveAllScript.

The script:
- Confirms it is running elevated
- Locates the installed Wazuh Agent MSI product code
- Stops and disables Wazuh services
- Terminates remaining Wazuh/OSSEC processes
- Moves the active ossec-agent directory to a timestamped backup
- Retries the official MSI uninstall
- Removes orphaned services, shortcuts, and Wazuh-specific registry keys
- Verifies that the service, files, and MSI registration are gone

The old agent directory is preserved under:
C:\Wazuh-Removal-Backup-<timestamp>

Reboot before reinstalling Wazuh.

.NOTES
Author: CK Technology LLC
Run as Administrator.
Test on a noncritical endpoint before broad deployment.
Keep the backup until the replacement Wazuh agent is confirmed healthy.

This script does not contain manager credentials, enrollment passwords,
API keys, customer names, or environment-specific secrets.

.EXAMPLE
PS C:\> .\wazuh-forced-uninstaller.ps1

.LINK
https://documentation.wazuh.com/current/installation-guide/uninstalling-wazuh/agent.html
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$ServiceNames = @(
    'WazuhSvc',
    'OssecSvc'
)

$AgentDir = 'C:\Program Files (x86)\ossec-agent'
$StartMenuDir = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\OSSEC'
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$BackupRoot = "C:\Wazuh-Removal-Backup-$Timestamp"
$BackupAgentDir = Join-Path $BackupRoot 'ossec-agent'
$MsiLog = Join-Path $env:TEMP "wazuh-uninstall-$Timestamp.log"

$UninstallRegistryPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

$WazuhRegistryKeys = @(
    'HKLM:\SOFTWARE\Wazuh, Inc.',
    'HKLM:\SOFTWARE\WOW6432Node\Wazuh, Inc.',
    'HKCU:\SOFTWARE\Wazuh, Inc.'
)

function Write-Step {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Get-WazuhProduct {
    Get-ItemProperty $UninstallRegistryPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'Wazuh Agent*' } |
        Select-Object -First 1
}

if (-not (Test-IsAdministrator)) {
    throw 'Run this script from PowerShell as Administrator.'
}

Write-Host '=== Wazuh forced clean removal ===' -ForegroundColor Green

Write-Step 'Locating installed Wazuh Agent MSI registration'
$WazuhProduct = Get-WazuhProduct

if ($WazuhProduct) {
    $ProductCode = $WazuhProduct.PSChildName

    Write-Host "Found: $($WazuhProduct.DisplayName)"
    Write-Host "Version: $($WazuhProduct.DisplayVersion)"
    Write-Host "Product code: $ProductCode"
}
else {
    $ProductCode = $null
    Write-Warning 'No Wazuh Agent MSI registration was found.'
}

Write-Step 'Stopping and disabling Wazuh services'
foreach ($ServiceName in $ServiceNames) {
    $Service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

    if ($Service) {
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        Set-Service -Name $ServiceName -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Host "Stopped and disabled: $ServiceName"
    }
}

Write-Step 'Terminating remaining Wazuh and OSSEC processes'
Get-Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProcessName -match 'wazuh|ossec|win32ui'
    } |
    ForEach-Object {
        Write-Host "Stopping process: $($_.ProcessName) (PID $($_.Id))"
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }

Start-Sleep -Seconds 2

Write-Step 'Preserving the existing Wazuh agent directory'
New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null

if (Test-Path -LiteralPath $AgentDir) {
    Write-Host "Moving:"
    Write-Host "  $AgentDir"
    Write-Host "to:"
    Write-Host "  $BackupAgentDir"

    Move-Item -LiteralPath $AgentDir -Destination $BackupAgentDir -Force
}
else {
    Write-Host 'Active ossec-agent directory was not present.'
}

$MsiExitCode = $null

if ($ProductCode) {
    Write-Step 'Running the official MSI uninstall after moving the broken data directory'

    $Process = Start-Process `
        -FilePath 'msiexec.exe' `
        -ArgumentList @(
            '/x',
            $ProductCode,
            '/qn',
            '/norestart',
            '/L*v',
            "`"$MsiLog`""
        ) `
        -Wait `
        -PassThru

    $MsiExitCode = $Process.ExitCode
    Write-Host "MSI exit code: $MsiExitCode"

    switch ($MsiExitCode) {
        0 {
            Write-Host 'MSI removal succeeded.' -ForegroundColor Green
        }
        3010 {
            Write-Host 'MSI removal succeeded; reboot required.' -ForegroundColor Green
        }
        1605 {
            Write-Host 'MSI reports the product is already absent.' -ForegroundColor Yellow
        }
        default {
            Write-Warning "MSI removal returned exit code $MsiExitCode."
            Write-Warning "Review the log at: $MsiLog"
        }
    }
}

Write-Step 'Removing orphaned Wazuh services'
foreach ($ServiceName in $ServiceNames) {
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        & sc.exe delete $ServiceName | Out-Null
        Write-Host "Deleted orphaned service: $ServiceName"
    }
}

Write-Step 'Removing active-path leftovers recreated during MSI rollback'
if (Test-Path -LiteralPath $AgentDir) {
    Remove-Item -LiteralPath $AgentDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Removed: $AgentDir"
}

if (Test-Path -LiteralPath $StartMenuDir) {
    Remove-Item -LiteralPath $StartMenuDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Removed: $StartMenuDir"
}

Write-Step 'Removing Wazuh-specific application registry keys'
foreach ($RegistryKey in $WazuhRegistryKeys) {
    if (Test-Path $RegistryKey) {
        Remove-Item $RegistryKey -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Removed: $RegistryKey"
    }
}

Write-Step 'Verifying removal'
$RemainingProduct = Get-WazuhProduct
$RemainingServices = Get-Service -Name $ServiceNames -ErrorAction SilentlyContinue
$AgentDirectoryExists = Test-Path -LiteralPath $AgentDir

Write-Host "Agent directory exists: $AgentDirectoryExists"
Write-Host "Wazuh services remain: $([bool]$RemainingServices)"
Write-Host "MSI registration remains: $([bool]$RemainingProduct)"
Write-Host "Preserved backup: $BackupRoot"
Write-Host "MSI log: $MsiLog"

if (
    -not $AgentDirectoryExists -and
    -not $RemainingServices -and
    -not $RemainingProduct
) {
    Write-Host "`nWazuh Agent was cleanly removed." -ForegroundColor Green
    Write-Host 'Reboot before reinstalling.'
    exit 0
}

if ($RemainingProduct) {
    Write-Warning 'The active Wazuh agent is removed, but corrupted MSI registration remains.'
    Write-Warning 'Use the Microsoft Program Install and Uninstall troubleshooter for the remaining entry.'
}

Write-Warning 'Some Wazuh remnants remain. Review the verification output before reinstalling.'
exit 1
