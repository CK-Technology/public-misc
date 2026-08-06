# UpdateWindows.ps1
# Installs all available Windows updates via PSWindowsUpdate and reboots if one
# is required. This is the single Windows Update script -- winUp.ps1 was a
# near-duplicate and has been removed.
#
# Run elevated. Logs a transcript to C:\ProgramData\CKTech\logs\.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File UpdateWindows.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File UpdateWindows.ps1 -NoReboot
#
# -NoReboot installs everything but leaves the endpoint pending-reboot, for use
# outside a maintenance window.

[CmdletBinding()]
param(
    [switch]$NoReboot
)

$LogDir = 'C:\ProgramData\CKTech\logs'
$LogPath = Join-Path $LogDir ('WindowsUpdate_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmm'))

# $PSCommandPath is set only for a real -File invocation. Under `irm | iex`
# there is no script file, and `exit` would close the operator's session -- so
# the exit codes below are emitted only when a scheduled task is watching.
$RanAsFile = [bool]$PSCommandPath

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning 'Windows Update requires an elevated session. Nothing was done.'
    if ($RanAsFile) { exit 1 } else { return }
}

# Start-Transcript does not create missing directories; it throws instead.
New-Item -Path $LogDir -ItemType Directory -Force | Out-Null

Start-Transcript -Path $LogPath -Append
$exitCode = 0

try {
    # Process scope only. An unscoped Set-ExecutionPolicy writes to the machine
    # policy and outlives the script.
    Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

    # PSGallery refuses TLS 1.0/1.1; older builds still default to them.
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        Write-Output 'Installing PSWindowsUpdate.'
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Confirm:$false | Out-Null
        Install-Module -Name PSWindowsUpdate -Force -Confirm:$false
    }
    Import-Module -Name PSWindowsUpdate

    # Get-WindowsUpdate with no action switch only lists. The old code called
    # Get-WUInstall here, which is an alias of Install-WindowsUpdate -- it
    # installed updates and then the script installed them a second time.
    $updates = Get-WindowsUpdate -MicrosoftUpdate
    Write-Output "Available updates: $($updates.Count)"
    $updates | ForEach-Object { Write-Output "  $($_.KB) - $($_.Title)" }

    if ($updates.Count -eq 0) {
        Write-Output 'Nothing to install.'
    }
    else {
        $installArgs = @{
            MicrosoftUpdate = $true
            AcceptAll       = $true
            IgnoreUserInput = $true
            Confirm         = $false
        }
        if ($NoReboot) {
            $installArgs['IgnoreReboot'] = $true
            Write-Output 'Installing updates. Reboot suppressed by -NoReboot.'
        }
        else {
            $installArgs['AutoReboot'] = $true
            Write-Output 'Installing updates. The endpoint will reboot if an update requires it.'
        }

        Install-WindowsUpdate @installArgs | Out-String | Write-Output
    }
}
catch {
    Write-Output "An error occurred: $($_.Exception.Message)"
    $exitCode = 1
}
finally {
    Stop-Transcript
}

if ($RanAsFile) { exit $exitCode }
