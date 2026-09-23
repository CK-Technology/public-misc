#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
Ensures both CKTech ScreenConnect access agents (on-prem and cloud) are
installed and running.

.DESCRIPTION
Intended for a GPO scheduled task running as SYSTEM at logon, startup, and daily.
Each agent is reconciled independently by its instance GUID:

  - service present            -> set to Automatic and started if it is not
  - service missing            -> that instance's MSI is downloaded and installed
  - MSI registered, no service -> the stale product is removed first, because
                                  msiexec /i treats a registered product as
                                  installed and would do nothing

A healthy agent is never reinstalled, so the other instance's sessions are not
interrupted when only one is broken.

A downloaded MSI is only run if its Authenticode signature is valid and the
signer matches that instance's expected signer, because msiexec executes it as
SYSTEM. The two MSIs are signed by different publishers: the cloud MSI by
ConnectWise, the self-hosted on-prem MSI by CK Technology LLC.

Overlapping runs are prevented by the scheduled task's "Do not start a new
instance" setting, not by a named mutex, which any local user could pre-create
to suppress the task.

.PARAMETER OnPremMsiUrl
MSI for the on-prem instance (relay screlay.cktechx.com).

.PARAMETER CloudMsiUrl
MSI for the cloud instance (cktech.screenconnect.com).

.PARAMETER OnPremSignerPattern
Case-insensitive regex the on-prem MSI signer's certificate subject must match.

.PARAMETER CloudSignerPattern
Case-insensitive regex the cloud MSI signer's certificate subject must match.

.NOTES
Exit codes:
  0  Both agents installed and running
  1  At least one agent could not be brought to a running state
#>
[CmdletBinding()]
param(
    [string]$OnPremMsiUrl = 'https://help.cktechx.com/downloads/ScreenConnect.ClientSetup.msi',
    [string]$CloudMsiUrl = 'https://cktech.screenconnect.com/Bin/ScreenConnect.ClientSetup.msi?e=Access&y=Guest',
    [string]$OnPremSignerPattern = '^CN=CK Technology LLC(,|$)',
    [string]$CloudSignerPattern = '^CN="ConnectWise, LLC"(,|$)'
)

$ErrorActionPreference = 'Stop'

# The GUID is the instance's public-key thumbprint, embedded in the service name
# as "ScreenConnect Client (<GUID>)". It is stable across agent upgrades and
# cosmetic renames of the DisplayName.
$Instances = @(
    @{ Label = 'On-prem'; Guid = '418b7df0387209de'; Url = $OnPremMsiUrl; Signer = $OnPremSignerPattern }
    @{ Label = 'Cloud';   Guid = 'aff6f7bc2d41aa0d'; Url = $CloudMsiUrl;  Signer = $CloudSignerPattern }
)

$LogDir = 'C:\ProgramData\CKTech\logs'
$LogFile = Join-Path $LogDir 'screenconnect_ensure.log'

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
# Logon plus daily triggers append indefinitely; keep one generation back.
if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt 1MB) {
    Move-Item -LiteralPath $LogFile -Destination "$LogFile.old" -Force
}

function Write-Log {
    param([string]$Message)

    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'), $Message
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Value $line
}

function Get-AgentService {
    param([string]$Guid)

    # A failed query must not read as "not installed" and trigger an
    # uninstall/reinstall; no match returns nothing without an error.
    Get-CimInstance Win32_Service -Filter "Name='ScreenConnect Client ($Guid)'" -ErrorAction Stop
}

function Get-AgentProduct {
    param([string]$Guid)

    # Both registry views explicitly: the HKLM: drive follows the process
    # bitness, so a 32-bit host would miss a native registration.
    $codes = foreach ($view in 'Registry64', 'Registry32') {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', $view)
        try {
            $root = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if (-not $root) { continue }
            try {
                foreach ($name in $root.GetSubKeyNames()) {
                    if ($name -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { continue }
                    $key = $root.OpenSubKey($name)
                    if (-not $key) { continue }
                    try {
                        if ($key.GetValue('DisplayName') -eq "ScreenConnect Client ($Guid)") { $name }
                    }
                    finally { $key.Dispose() }
                }
            }
            finally { $root.Dispose() }
        }
        finally { $base.Dispose() }
    }
    # On 32-bit Windows both views are the same hive.
    $codes | Select-Object -Unique
}

function Invoke-Msiexec {
    param([string]$Arguments)

    $proc = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList $Arguments -Wait -PassThru
    return $proc.ExitCode
}

function Start-Agent {
    param([string]$Label, [string]$Guid)

    $svc = Get-AgentService $Guid
    if ($svc.StartMode -ne 'Auto') {
        Write-Log "$Label agent start mode is $($svc.StartMode); setting Automatic."
        Set-Service -Name $svc.Name -StartupType Automatic
    }
    if ($svc.State -ne 'Running') {
        Write-Log "$Label agent is $($svc.State); starting."
        Start-Service -Name $svc.Name
        (Get-Service -Name $svc.Name).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    }
}

function Install-Agent {
    param([string]$Label, [string]$Guid, [string]$Url, [string]$SignerPattern)

    foreach ($productCode in @(Get-AgentProduct $Guid)) {
        Write-Log "$Label product $productCode is registered without a service; removing it before reinstall."
        $code = Invoke-Msiexec "/x $productCode /qn /norestart REBOOT=REALLYSUPPRESS"
        Write-Log "$Label stale product removal exit code: $code"
    }

    # A fresh directory under SYSTEM's %TEMP% is owned by SYSTEM and not writable
    # by users, so the MSI cannot be swapped between download and msiexec.
    $workDir = Join-Path $env:TEMP ('cktech-sc-' + [IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    try {
        $msiPath = Join-Path $workDir "ScreenConnect-$Guid.msi"
        Write-Log "$Label downloading $Url"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        (New-Object System.Net.WebClient).DownloadFile($Url, $msiPath)

        # Catches HTML error pages and interstitials served with a 200.
        $header = New-Object byte[] 8
        $stream = [IO.File]::OpenRead($msiPath)
        try { [void]$stream.Read($header, 0, 8) } finally { $stream.Dispose() }
        if ([BitConverter]::ToString($header) -ne 'D0-CF-11-E0-A1-B1-1A-E1') {
            throw "download is not an MSI ($((Get-Item -LiteralPath $msiPath).Length) bytes)"
        }

        $sig = Get-AuthenticodeSignature -LiteralPath $msiPath
        $signer = $sig.SignerCertificate.Subject
        Write-Log "$Label MSI signature: $($sig.Status) $signer"
        if ($sig.Status -ne 'Valid' -or $signer -notmatch $SignerPattern) {
            throw "MSI signature rejected (status $($sig.Status), signer '$signer'); not installing"
        }

        $code = Invoke-Msiexec "/i `"$msiPath`" /qn /norestart REBOOT=REALLYSUPPRESS"
        Write-Log "$Label msiexec exit code: $code"
        if ($code -notin 0, 1641, 3010) {
            throw "msiexec failed with exit code $code"
        }
    }
    finally {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # The service is registered at the end of the MSI, but give it time to appear.
    $deadline = (Get-Date).AddSeconds(60)
    while (-not (Get-AgentService $Guid) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
    }
    if (-not (Get-AgentService $Guid)) {
        throw 'installer completed but the agent service did not appear'
    }
}

function Invoke-Reconcile {
    param([hashtable]$Instance)

    $label = $Instance.Label
    $guid = $Instance.Guid
    try {
        if (Get-AgentService $guid) {
            Start-Agent $label $guid
        }
        else {
            Write-Log "$label agent ($guid) is missing; installing."
            Install-Agent $label $guid $Instance.Url $Instance.Signer
            Start-Agent $label $guid
            Write-Log "$label agent installed."
        }

        $svc = Get-AgentService $guid
        if ($svc.State -ne 'Running') {
            throw "service is $($svc.State) after reconcile"
        }
        Write-Log "$label agent ($guid) OK: $($svc.State), $($svc.StartMode)."
        return $true
    }
    catch {
        Write-Log "$label agent ($guid) FAIL: $($_.Exception.Message)"
        return $false
    }
}

$exitCode = 1
try {
    Write-Log "deploy-sc starting on $env:COMPUTERNAME."
    $results = foreach ($instance in $Instances) { Invoke-Reconcile $instance }
    $exitCode = if ($results -contains $false) { 1 } else { 0 }
    Write-Log "deploy-sc done (exit $exitCode)."
}
catch {
    Write-Log "FAIL: $($_.Exception.Message)"
    $exitCode = 1
}

exit $exitCode
