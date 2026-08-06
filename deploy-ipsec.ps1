# deploy-ipsec.ps1
# Deploy FortiClient IPsec VPN config from XML via GPO Startup Script
## Deploy via GPO sceduled task
## Scheduled task - At start up, Creation/Modification and Login
## Program Script: powershell
## Arguments -ExecutionPolicy Bypass -File "\\<server>\IT\vpn\deploy-ipsec.ps1" Or whatever the path of this vpn deployment script is

## XML File generate via system with forticlient installed and with VPN profile configured
## EXPORT  xml file via cli:
## & "C:\Program Files\Fortinet\FortiClient\fcconfig.exe" -m vpn -o export -f "C:\Temp\vpn.xml" -p "Password2026"
##
## Import
## & "C:\Program Files\Fortinet\FortiClient\fcconfig.exe" -m vpn -o import -f "C:\Temp\vpn.xml" -p "Password2026"
$xmlSource = "\\<server>\IT\vpn\vpn.xml"
$xmlLocal  = "C:\Temp\vpn.xml"
$fcPath    = "C:\Program Files\Fortinet\FortiClient\fcconfig.exe"
$password  = "Password2026GoesHere"

$dataRoot     = "C:\ProgramData\CKTech"
$logFile      = Join-Path $dataRoot "logs\ipsec_vpn_deploy.log"
$marker       = Join-Path $dataRoot "state\ipsec_vpn_imported.txt"
# The marker used to live in C:\Temp, which every user can write. Endpoints
# deployed before the move still carry it, so it counts as already-imported --
# otherwise this reimports the profile fleet-wide on the next run.
$legacyMarker = "C:\Temp\cktech_vpn_imported.txt"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "$timestamp - $Message"
}

try {
    foreach ($dir in @((Split-Path $logFile), (Split-Path $marker), "C:\Temp")) {
        if (!(Test-Path $dir)) {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
        }
    }

    Write-Log "Starting FortiClient IPsec VPN deployment."

    if (Test-Path $marker) {
        Write-Log "Marker file exists. VPN already imported. Exiting."
        exit 0
    }

    if (Test-Path $legacyMarker) {
        Write-Log "Legacy marker found at $legacyMarker. Treating as imported."
        New-Item -Path $marker -ItemType File -Force | Out-Null
        exit 0
    }

    if (!(Test-Path $fcPath)) {
        Write-Log "FortiClient not found at $fcPath. Exiting."
        exit 0
    }

    if (!(Test-Path $xmlSource)) {
        Write-Log "Source XML not found: $xmlSource. Exiting."
        exit 1
    }

    Copy-Item -Path $xmlSource -Destination $xmlLocal -Force
    Write-Log "Copied XML from $xmlSource to $xmlLocal."

    & $fcPath -m vpn -o import -f $xmlLocal -p $password
    $exitCode = $LASTEXITCODE

    Write-Log "fcconfig import completed with exit code $exitCode."

    if ($exitCode -eq 0) {
        New-Item -Path $marker -ItemType File -Force | Out-Null
        Write-Log "Import successful. Marker file created."
        exit 0
    } else {
        Write-Log "Import failed."
        exit $exitCode
    }
}
catch {
    Write-Log "Unhandled error: $($_.Exception.Message)"
    exit 1
}
