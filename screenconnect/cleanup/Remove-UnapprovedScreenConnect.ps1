#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
Removes every ScreenConnect access agent except the approved CKTech instances.

.DESCRIPTION
Finds ScreenConnect / ConnectWise Control access agents by instance GUID, from
the Windows Installer uninstall entries, the services, and the standard Program
Files install directories, and removes any whose GUID is not approved.

The CKTech on-prem and cloud instances are always approved and cannot be
removed by this script. -AdditionalAllowedGuids adds to them, for example to
keep a line-of-business vendor's support agent.

An agent with an MSI registration is removed with msiexec /x. Anything left
behind afterwards, or an agent installed without an MSI registration, has its
service stopped and deleted and its install directory removed.

If msiexec /x fails, that agent's service and files are left alone so the MSI
registration is not orphaned; pass -ForceCleanup to delete them anyway. Exit
1618 (another installation in progress) always defers to the next run.

Both registry views and both Program Files trees are searched, so a 32-bit
PowerShell host on 64-bit Windows sees the same inventory as a native one.

Run with -WhatIf first to see what would be removed.

.PARAMETER AdditionalAllowedGuids
Instance GUIDs to keep in addition to the CKTech instances.

.PARAMETER ForceCleanup
Delete the service and install directory even when msiexec /x fails with an
error other than 1618.

.EXAMPLE
.\Remove-UnapprovedScreenConnect.ps1 -WhatIf

.EXAMPLE
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/screenconnect/cleanup/Remove-UnapprovedScreenConnect.ps1'))) -WhatIf

.NOTES
Exit codes (when run with -File; a scriptblock invocation does not call exit,
so read the final log line instead):
  0  No unapproved agents remain (or -WhatIf)
  1  An unapproved agent remains, or the inventory could not be read
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[0-9a-fA-F]{16}$')]
    [string[]]$AdditionalAllowedGuids = @(),
    [switch]$ForceCleanup
)

$ErrorActionPreference = 'Stop'

$ProtectedGuids = @('418b7df0387209de', 'aff6f7bc2d41aa0d')
$AllowedGuids = @($ProtectedGuids + @($AdditionalAllowedGuids | ForEach-Object { $_.ToLowerInvariant() }) |
    Sort-Object -Unique)

$LogDir = 'C:\ProgramData\CKTech\logs'
$LogFile = Join-Path $LogDir 'screenconnect_remove.log'
# Older releases were branded ConnectWise Control; both use the same GUID scheme.
$NameRegex = New-Object System.Text.RegularExpressions.Regex(
    '^(ScreenConnect|ConnectWise Control) Client \(([0-9a-f]{16})\)$',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
# ProgramW6432 is the native Program Files even from a 32-bit process;
# ProgramFiles(x86) is unset on 32-bit Windows.
$ProgramFilesDirs = @($env:ProgramW6432, ${env:ProgramFiles(x86)}, $env:ProgramFiles) |
    Where-Object { $_ } | Select-Object -Unique

New-Item -ItemType Directory -Path $LogDir -Force -WhatIf:$false | Out-Null

function Write-Log {
    param([string]$Message)

    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'), $Message
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Value $line -WhatIf:$false
}

# Returns the lowercased instance GUID, or $null when the name is not an agent.
function Get-AgentGuid {
    param([string]$Name)

    $m = $NameRegex.Match([string]$Name)
    if ($m.Success) { $m.Groups[2].Value.ToLowerInvariant() }
}

# Opens the 64- and 32-bit registry views explicitly. The HKLM: drive follows
# the process bitness, so a 32-bit host would miss native registrations.
function Get-UninstallEntries {
    $seen = @{}
    foreach ($view in 'Registry64', 'Registry32') {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', $view)
        try {
            $root = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if (-not $root) { continue }
            try {
                foreach ($name in $root.GetSubKeyNames()) {
                    $key = $root.OpenSubKey($name)
                    if (-not $key) { continue }
                    try { $displayName = $key.GetValue('DisplayName') } finally { $key.Dispose() }
                    # On 32-bit Windows both views are the same hive.
                    if ($seen.ContainsKey("$name|$displayName")) { continue }
                    $seen["$name|$displayName"] = $true
                    [pscustomobject]@{ KeyName = $name; DisplayName = $displayName }
                }
            }
            finally { $root.Dispose() }
        }
        finally { $base.Dispose() }
    }
}

# Enumeration errors are terminating on purpose: an unreadable inventory must
# not be mistaken for an empty one and reported as clean.
function Get-AgentProducts {
    foreach ($entry in Get-UninstallEntries) {
        $guid = Get-AgentGuid $entry.DisplayName
        if ($guid) {
            [pscustomobject]@{
                Guid        = $guid
                DisplayName = $entry.DisplayName
                ProductCode = if ($entry.KeyName -match '^\{[0-9A-Fa-f-]{36}\}$') { $entry.KeyName }
            }
        }
    }
}

function Get-AgentServices {
    foreach ($svc in Get-CimInstance Win32_Service) {
        $guid = Get-AgentGuid $svc.Name
        if ($guid) {
            [pscustomobject]@{ Guid = $guid; Name = $svc.Name; PathName = $svc.PathName }
        }
    }
}

function Get-AgentDirectories {
    foreach ($base in $ProgramFilesDirs) {
        foreach ($dir in Get-ChildItem -LiteralPath $base -Directory) {
            $guid = Get-AgentGuid $dir.Name
            if ($guid) { [pscustomobject]@{ Guid = $guid; Path = $dir.FullName } }
        }
    }
}

function Get-UnapprovedGuids {
    @(@(Get-AgentProducts) + @(Get-AgentServices) + @(Get-AgentDirectories) |
        ForEach-Object { $_.Guid } |
        Where-Object { $_ -notin $AllowedGuids } |
        Sort-Object -Unique)
}

function Remove-Agent {
    param([string]$Guid)

    if ($Guid -in $ProtectedGuids) {
        throw "refusing to remove protected instance $Guid"
    }

    foreach ($product in @(Get-AgentProducts | Where-Object { $_.Guid -eq $Guid -and $_.ProductCode })) {
        if ($PSCmdlet.ShouldProcess("$($product.DisplayName) $($product.ProductCode)", 'msiexec /x')) {
            $proc = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" `
                -ArgumentList "/x $($product.ProductCode) /qn /norestart REBOOT=REALLYSUPPRESS" -Wait -PassThru
            $code = $proc.ExitCode
            Write-Log "msiexec /x $($product.DisplayName) $($product.ProductCode): exit $code"
            # 1605 = product no longer installed, so there is nothing to orphan.
            if ($code -in 0, 1605, 1641, 3010) { continue }
            if ($code -eq 1618) {
                throw 'Windows Installer is busy (1618); deferring to the next run, nothing else removed'
            }
            if (-not $ForceCleanup) {
                throw "msiexec /x failed ($code); service and files left in place. Re-run with -ForceCleanup to delete them anyway"
            }
            Write-Log "msiexec /x failed ($code); -ForceCleanup set, deleting service and files."
        }
    }

    # Leftovers from a failed uninstall, or an agent that was never MSI-registered.
    foreach ($svc in @(Get-AgentServices | Where-Object { $_.Guid -eq $Guid })) {
        if ($PSCmdlet.ShouldProcess($svc.Name, 'stop and delete service')) {
            Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
            & "$env:SystemRoot\System32\sc.exe" delete $svc.Name | Out-Null
            Write-Log "Deleted service $($svc.Name) (sc exit $LASTEXITCODE)"
        }
    }

    foreach ($dir in @(Get-AgentDirectories | Where-Object { $_.Guid -eq $Guid })) {
        if ($PSCmdlet.ShouldProcess($dir.Path, 'remove directory')) {
            Remove-Item -LiteralPath $dir.Path -Recurse -Force
            Write-Log "Removed $($dir.Path)"
        }
    }
}

$exitCode = 1
try {
    Write-Log "Remove-UnapprovedScreenConnect starting on $env:COMPUTERNAME. Allowed: $($AllowedGuids -join ', ')"

    foreach ($p in @(Get-AgentProducts)) { Write-Log "Found product: $($p.DisplayName) $($p.ProductCode)" }
    foreach ($s in @(Get-AgentServices)) { Write-Log "Found service: $($s.Name) | $($s.PathName)" }
    foreach ($d in @(Get-AgentDirectories)) { Write-Log "Found directory: $($d.Path)" }

    $unapproved = Get-UnapprovedGuids
    if ($unapproved.Count -eq 0) {
        Write-Log 'No unapproved ScreenConnect agents found.'
        $exitCode = 0
    }
    else {
        foreach ($guid in $unapproved) {
            Write-Log "Unapproved instance: $guid"
            try { Remove-Agent $guid }
            catch { Write-Log "Removal of $guid FAILED: $($_.Exception.Message)" }
        }

        if ($WhatIfPreference) {
            $exitCode = 0
        }
        else {
            $remaining = Get-UnapprovedGuids
            if ($remaining.Count -gt 0) {
                Write-Log "Still present after removal (product, service, or directory): $($remaining -join ', ')"
            }
            else {
                Write-Log 'All unapproved agents removed.'
                $exitCode = 0
            }
        }
    }
}
catch {
    Write-Log "FAIL: $($_.Exception.Message)"
    $exitCode = 1
}

Write-Log "Remove-UnapprovedScreenConnect done (exit $exitCode)."
# `exit` would close the host window when run via scriptblock/iex.
if ($PSCommandPath) { exit $exitCode }
