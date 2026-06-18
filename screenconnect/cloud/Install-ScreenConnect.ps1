# cloud/Install-ScreenConnect.ps1
# Silent install of the ScreenConnect access agent -- CLOUD instance.
#
# One-liner (elevated PowerShell / SC backstage runs as SYSTEM):
#   irm 'https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/screenconnect/cloud/Install-ScreenConnect.ps1' | iex
#
# Wrapped in a function so it is safe to run via `irm | iex` -- uses `return`,
# never `exit`, so it will not close the host PowerShell window.

function Install-ScreenConnectAgent {
    param(
        [string]$InstallerUrl = 'https://cktech.screenconnect.com/Bin/ScreenConnect.ClientSetup.exe?e=Access&y=Guest&c=_WEB&c=&c=&c=&c=&c=&c=&c=',
        [switch]$Force
    )

    $logFile = "C:\ProgramData\CKScripts\screenconnect_install.log"
    $installerPath = "$env:TEMP\ScreenConnect.ClientSetup.exe"

    function Write-Log {
        param([string]$Message)
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        if (!(Test-Path "C:\ProgramData\CKScripts")) {
            New-Item -Path "C:\ProgramData\CKScripts" -ItemType Directory -Force | Out-Null
        }
        Add-Content -Path $logFile -Value "$ts - $Message"
        Write-Host "$ts - $Message"
    }

    Write-Log "Starting ScreenConnect agent install (cloud)."

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Log "NOT elevated. Re-run from an Administrator PowerShell (SC backstage runs as SYSTEM and is fine). Aborting."
        return
    }

    # Match THIS instance only (by host in the service path), so other
    # ScreenConnect agents (e.g. the on-prem one) are left untouched.
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

    # Download with curl.exe, which uses the OS Schannel + system certificate
    # store. That validates ConnectWise's rotated DigiCert chain, where the .NET
    # Framework WebClient hit "could not establish trust relationship". Falls
    # back to BITS (WinHTTP) on older boxes without curl.exe.
    Write-Log "Downloading from $InstallerUrl"
    $curl = "$env:SystemRoot\System32\curl.exe"
    try {
        if (Test-Path $curl) {
            & $curl --fail --location --silent --show-error `
                --output $installerPath $InstallerUrl
            if ($LASTEXITCODE -ne 0) { throw "curl.exe exited $LASTEXITCODE" }
        }
        else {
            Start-BitsTransfer -Source $InstallerUrl -Destination $installerPath -ErrorAction Stop
        }
    }
    catch {
        Write-Log "Primary download failed ($($_.Exception.Message)); retrying via BITS."
        try {
            Start-BitsTransfer -Source $InstallerUrl -Destination $installerPath -ErrorAction Stop
        }
        catch {
            Write-Log "Download failed: $($_.Exception.Message)"
            return
        }
    }

    if (-not (Test-Path $installerPath)) {
        Write-Log "Installer not found after download. Aborting."
        return
    }

    $size = (Get-Item $installerPath).Length
    $bytes = [System.IO.File]::ReadAllBytes($installerPath) | Select-Object -First 2
    if ($bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        Write-Log "Downloaded file is not a valid EXE ($size bytes). Check the URL. Aborting."
        return
    }

    Write-Log "Download OK ($size bytes). Installing silently."
    # ConnectWise's signed ClientSetup.exe installs the agent unattended when
    # launched (it wraps msiexec internally), so no extra silent switches needed.
    $proc = Start-Process -FilePath $installerPath -Wait -PassThru
    $code = $proc.ExitCode

    switch ($code) {
        0    { Write-Log "Install succeeded (exit 0)." }
        3010 { Write-Log "Install succeeded; reboot required (exit 3010)." }
        default { Write-Log "Install FAILED (installer exit $code)." }
    }

    Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
}

Install-ScreenConnectAgent
