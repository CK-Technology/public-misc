# onprem/Install-ScreenConnect.ps1
# Silent install of the ScreenConnect / ConnectWise Control agent -- ON-PREM instance.
#
# Set the default $InstallerUrl below to your on-prem server's Bin endpoint once
# the server is stood up (Access tab -> Build -> copy the .msi download link).
#
# One-liner (elevated PowerShell / backstage):
#   irm 'https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/screenconnect/onprem/Install-ScreenConnect.ps1' | iex
#
# Override the target with -InstallerUrl if needed. Re-run with -Force to reinstall.

param(
    [string]$InstallerUrl = 'https://REPLACE-ME.cktech.com/Bin/ScreenConnect.ClientSetup.msi?e=Access&y=Guest',

    [switch]$Force
)

$logFile = "C:\ProgramData\CKTECH-Scripts\screenconnect_install.log"
$msiPath = "$env:TEMP\ScreenConnect.ClientSetup.msi"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "$timestamp - $Message"
    Write-Host "$timestamp - $Message"
}

try {
    if (!(Test-Path "C:\ProgramData\CKTECH-Scripts")) {
        New-Item -Path "C:\ProgramData\CKTECH-Scripts" -ItemType Directory -Force | Out-Null
    }

    Write-Log "Starting ScreenConnect agent install (on-prem)."

    # Guard -- refuse to run until the on-prem server URL has been configured.
    if ($InstallerUrl -like '*REPLACE-ME*') {
        Write-Log "InstallerUrl not configured. Set the default in onprem/Install-ScreenConnect.ps1 or pass -InstallerUrl. Aborting."
        exit 1
    }

    # Require elevation -- msiexec install needs admin.
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (!$isAdmin) {
        Write-Log "Not running as administrator. Aborting."
        exit 1
    }

    # Idempotency -- skip if the agent service is already present.
    $existing = Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'ScreenConnect Client*' }
    if ($existing -and !$Force) {
        Write-Log "ScreenConnect Client service already present ($($existing.Name)). Use -Force to reinstall. Exiting."
        exit 0
    }

    Write-Log "Downloading installer from $InstallerUrl"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $InstallerUrl -OutFile $msiPath -UseBasicParsing

    # Guard against hosts that return an HTML interstitial instead of the raw
    # MSI -- a valid MSI starts with the OLE compound-file magic bytes.
    $bytes = [System.IO.File]::ReadAllBytes($msiPath) | Select-Object -First 2
    if ($bytes[0] -ne 0xD0 -or $bytes[1] -ne 0xCF) {
        Write-Log "Downloaded file is not a valid MSI (size $((Get-Item $msiPath).Length) bytes). Check the URL/host. Aborting."
        exit 1
    }

    Write-Log "Download complete ($((Get-Item $msiPath).Length) bytes). Installing silently."
    $proc = Start-Process -FilePath "msiexec.exe" `
        -ArgumentList "/i `"$msiPath`" /qn /norestart" `
        -Wait -PassThru
    $exitCode = $proc.ExitCode

    if ($exitCode -eq 0 -or $exitCode -eq 3010) {
        Write-Log "Install succeeded (msiexec exit code $exitCode)."
        Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue
        exit 0
    }
    else {
        Write-Log "Install failed (msiexec exit code $exitCode)."
        exit $exitCode
    }
}
catch {
    Write-Log "Unhandled error: $($_.Exception.Message)"
    exit 1
}
