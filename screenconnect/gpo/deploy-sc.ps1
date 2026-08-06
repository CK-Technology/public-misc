# gpo/deploy-sc.ps1
# Idempotent check-and-install for BOTH ScreenConnect agents (on-prem + cloud).
#
# Run directly from the web (GPO scheduled task action, as SYSTEM):
#   powershell -ep bypass -c "irm 'https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/screenconnect/gpo/deploy-sc.ps1' | iex"
#
# Each run checks for each agent by instance GUID and installs only the missing
# one(s); agents already present are left untouched. Wrapped in a function that
# uses `return`, never `exit`, so it is safe to run via `irm | iex`.
#
# GUID -> instance mapping (confirmed against live services on a deployed host):
#   418b7df0387209de = On-prem (help.cktechx.com)
#   aff6f7bc2d41aa0d = Cloud   (cktech.screenconnect.com)

function Invoke-EnsureScreenConnect {
    $OnPremGuid = '418b7df0387209de'
    $CloudGuid  = 'aff6f7bc2d41aa0d'

    $OnPremInstall = 'https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/screenconnect/onprem/Install-ScreenConnect.ps1'
    $CloudInstall  = 'https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/screenconnect/cloud/Install-ScreenConnect.ps1'

    $logDir  = 'C:\ProgramData\CKTech\logs'
    $logFile = Join-Path $logDir 'screenconnect_ensure.log'

    function Write-Log {
        param([string]$Message)
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        if (!(Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
        Add-Content -Path $logFile -Value "$ts - $Message"
        Write-Host "$ts - $Message"
    }

    function Test-InstanceInstalled {
        param([string]$Guid)
        @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "ScreenConnect Client ($Guid)*" }).Count -gt 0
    }

    function Ensure-Instance {
        param([string]$Label, [string]$Guid, [string]$Url)

        if (Test-InstanceInstalled $Guid) {
            Write-Log "$Label agent ($Guid) already installed."
            return
        }

        Write-Log "$Label agent ($Guid) missing -- installing from $Url"
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-Expression (Invoke-RestMethod -Uri $Url)
            Write-Log "$Label installer finished."
        } catch {
            Write-Log "$Label install FAILED: $($_.Exception.Message)"
            return
        }

        # Give the service a moment to register, then confirm it actually appeared.
        Start-Sleep -Seconds 10
        if (Test-InstanceInstalled $Guid) {
            Write-Log "$Label agent verified installed."
        } else {
            Write-Log "$Label agent STILL MISSING after install attempt."
        }
    }

    Write-Log 'deploy-sc starting.'
    Ensure-Instance 'On-prem' $OnPremGuid $OnPremInstall
    Ensure-Instance 'Cloud'   $CloudGuid  $CloudInstall
    Write-Log 'deploy-sc done.'
}

Invoke-EnsureScreenConnect
