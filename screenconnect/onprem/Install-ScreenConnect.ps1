# onprem/Install-ScreenConnect.ps1
# Silent install of the ScreenConnect access agent -- ON-PREM instance.
#
# $InstallerUrl points at the signed MSI hosted on help.cktechx.com. Must be the
# .msi (this script validates the MSI header and runs msiexec); the .exe will not
# work with this flow.
#
# One-liner (elevated PowerShell / SC backstage runs as SYSTEM):
#   irm 'https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/screenconnect/onprem/Install-ScreenConnect.ps1' | iex
#
# Wrapped in a function so it is safe to run via `irm | iex` -- uses `return`,
# never `exit`, so it will not close the host PowerShell window.

function Install-ScreenConnectAgent {
    param(
        [string]$InstallerUrl = 'https://help.cktechx.com/downloads/cktech-screenconnect.msi',
        [switch]$Force
    )

    $logFile = "C:\ProgramData\CKTech\logs\screenconnect_install.log"
    $msiPath = "$env:TEMP\ScreenConnect.ClientSetup.msi"

    function Write-Log {
        param([string]$Message)
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        if (!(Test-Path "C:\ProgramData\CKTech\logs")) {
            New-Item -Path "C:\ProgramData\CKTech\logs" -ItemType Directory -Force | Out-Null
        }
        Add-Content -Path $logFile -Value "$ts - $Message"
        Write-Host "$ts - $Message"
    }

    Write-Log "Starting ScreenConnect agent install (on-prem)."

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Log "NOT elevated. Re-run from an Administrator PowerShell (SC backstage runs as SYSTEM and is fine). Aborting."
        return
    }

    # Match THIS instance only (by host in the service path), so other
    # ScreenConnect agents (e.g. the cloud one) are left untouched.
    # NOTE: $scHost is the host of the *download* URL (help.cktechx.com), not the
    # agent's relay host, so this will not match an installed service and the
    # script will (re)install each run. The Found-agent log lines below show what
    # is present so this can be re-scoped to the real relay host later if needed.
    $scHost = ([uri]$InstallerUrl).Host
    $allSc = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'ScreenConnect Client*' })
    foreach ($s in $allSc) { Write-Log "Found agent: $($s.Name) | $($s.PathName)" }
    Write-Log "Target host: $scHost"
    $existing = $allSc | Where-Object { $_.PathName -like "*$scHost*" }
    if ($existing -and -not $Force) {
        Write-Log "Agent for $scHost already installed ($($existing.Name)). Use -Force to reinstall. Done."
        return
    }

    try {
        Write-Log "Downloading from $InstallerUrl"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        (New-Object System.Net.WebClient).DownloadFile($InstallerUrl, $msiPath)
    }
    catch {
        Write-Log "Download failed: $($_.Exception.Message)"
        return
    }

    if (-not (Test-Path $msiPath)) {
        Write-Log "Installer not found after download. Aborting."
        return
    }

    $size = (Get-Item $msiPath).Length
    $bytes = [System.IO.File]::ReadAllBytes($msiPath) | Select-Object -First 2
    if ($bytes[0] -ne 0xD0 -or $bytes[1] -ne 0xCF) {
        Write-Log "Downloaded file is not a valid MSI ($size bytes). Check the URL. Aborting."
        return
    }

    Write-Log "Download OK ($size bytes). Installing silently."
    $proc = Start-Process -FilePath "msiexec.exe" `
        -ArgumentList "/i `"$msiPath`" /qn /norestart REBOOT=REALLYSUPPRESS" `
        -Wait -PassThru
    $code = $proc.ExitCode

    switch ($code) {
        0    { Write-Log "Install succeeded (exit 0)." }
        3010 { Write-Log "Install succeeded; reboot required (exit 3010)." }
        1641 { Write-Log "Install succeeded; installer initiated reboot (exit 1641)." }
        default { Write-Log "Install FAILED (msiexec exit $code)." }
    }

    Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue
}

Install-ScreenConnectAgent
