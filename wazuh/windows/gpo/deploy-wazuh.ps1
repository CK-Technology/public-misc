#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
Installs, upgrades, or repairs the Wazuh agent on supported Windows systems.

.DESCRIPTION
Intended for a GPO scheduled task or an RMM running as SYSTEM. The script keeps
the installed agent on the requested version, starts a stopped service without
reinstalling, and fails closed when an existing agent targets another manager.

Agent groups are enrollment-time, manager-side state. -AgentGroup is used for a
new enrollment only; this script does not claim to reconcile groups on an
already-enrolled endpoint.

Use -InstallerPath to copy an MSI from a controlled share, or omit it to download
the pinned MSI from packages.wazuh.com. Downloaded and copied working files are
removed before exit.

If enrollment requires a password, store it in a local ACL-protected file that
only SYSTEM and Administrators can read, then pass -RegistrationPasswordFile.
Never put that file in SYSVOL/NETLOGON or pass the password in a scheduled-task
command line.

.NOTES
Author: CK Technology LLC
Logs to C:\ProgramData\CKTech\logs\wazuh_deploy.log
#>
[CmdletBinding()]
param(
    [string]$Manager = 'wazuh.cktechx.com',
    [string]$AgentGroup = 'default',
    [string]$AgentName = $env:COMPUTERNAME,
    [string]$Version = '4.14.7-1',
    [string]$InstallerUrl,
    [string]$InstallerPath,
    [string]$InstallerSha512,
    [string]$RegistrationPasswordFile
)

$ErrorActionPreference = 'Stop'

$AgentDir = 'C:\Program Files (x86)\ossec-agent'
$Conf = Join-Path $AgentDir 'ossec.conf'
$LogDir = 'C:\ProgramData\CKTech\logs'
$LogFile = Join-Path $LogDir 'wazuh_deploy.log'
$WorkingMsi = $null
$RegistrationPassword = $null

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Write-Log {
    param([string]$Message)

    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'), $Message
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Value $line
}

function Assert-Inputs {
    if ($Manager -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$') {
        throw 'Manager must be a DNS name or IPv4 address.'
    }
    if ($AgentGroup -notmatch '^[A-Za-z0-9._-]+(?:,[A-Za-z0-9._-]+)*$') {
        throw 'AgentGroup must be a comma-separated list of valid Wazuh group names.'
    }
    if ($AgentName -notmatch '^[A-Za-z0-9._-]+$') {
        throw 'AgentName contains unsupported characters.'
    }
    if ($Version -notmatch '^\d+\.\d+\.\d+(?:-\d+)?$') {
        throw 'Version must use the X.Y.Z-N package format.'
    }
    if ($InstallerPath -and $InstallerUrl) {
        throw 'Use InstallerPath or InstallerUrl, not both.'
    }
    if ($InstallerSha512 -and $InstallerSha512 -notmatch '^[A-Fa-f0-9]{128}$') {
        throw 'InstallerSha512 must be a 128-character SHA-512 value.'
    }
    foreach ($value in @($Manager, $AgentGroup, $AgentName)) {
        if ($value.Contains('"')) {
            throw 'Manager, AgentGroup, and AgentName cannot contain double quotes.'
        }
    }
}

function Get-WazuhProduct {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'Wazuh Agent*' } |
        Select-Object -First 1
}

function Get-ConfiguredManager {
    if (-not (Test-Path -LiteralPath $Conf)) {
        return $null
    }

    $content = Get-Content -LiteralPath $Conf -Raw
    $match = [regex]::Match($content, '<address>\s*([^<]+?)\s*</address>')
    if ($match.Success) {
        return $match.Groups[1].Value.Trim()
    }
    return $null
}

function Test-AgentVersion {
    param(
        [string]$InstalledVersion,
        [string]$RequestedVersion
    )

    if (-not $InstalledVersion) {
        return $false
    }
    $requestedCore = ($RequestedVersion -split '-', 2)[0]
    $installedCore = [regex]::Match($InstalledVersion, '^\d+\.\d+\.\d+').Value
    return $installedCore -eq $requestedCore
}

function Assert-PasswordFileAcl {
    param([string]$Path)

    if ($Path.StartsWith('\\')) {
        throw 'RegistrationPasswordFile must be local; never store it on a share.'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'RegistrationPasswordFile does not exist.'
    }

    $allowedSids = @('S-1-5-18', 'S-1-5-32-544')
    $acl = Get-Acl -LiteralPath $Path
    $rules = $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -eq 'Allow' -and
            $allowedSids -notcontains $rule.IdentityReference.Value) {
            throw "RegistrationPasswordFile grants access to $($rule.IdentityReference.Value)."
        }
    }
}

function Get-RegistrationPassword {
    param([string]$Path)

    Assert-PasswordFileAcl -Path $Path
    $value = Get-Content -LiteralPath $Path -Raw
    $value = $value.TrimEnd("`r", "`n")
    if (-not $value) {
        throw 'RegistrationPasswordFile is empty.'
    }
    if ($value -match '[\r\n"]') {
        throw 'The enrollment password cannot contain a quote or newline.'
    }
    return $value
}

function Get-Installer {
    $destination = Join-Path $env:TEMP (
        'wazuh-agent-{0}-{1}.msi' -f $Version, [guid]::NewGuid().ToString('N')
    )
    $script:WorkingMsi = $destination

    if ($InstallerPath) {
        if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
            throw "InstallerPath does not exist: $InstallerPath"
        }
        Write-Log "Copying MSI from $InstallerPath"
        Copy-Item -LiteralPath $InstallerPath -Destination $destination
    }
    else {
        $url = $InstallerUrl
        if (-not $url) {
            $url = "https://packages.wazuh.com/4.x/windows/wazuh-agent-$Version.msi"
        }
        $uri = [uri]$url
        if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https') {
            throw 'InstallerUrl must be an absolute HTTPS URL.'
        }

        Write-Log "Downloading $url"
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $uri -OutFile $destination -UseBasicParsing
    }

    if ($InstallerSha512) {
        $actualHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA512).Hash
        if ($actualHash -ne $InstallerSha512) {
            throw 'MSI SHA-512 does not match InstallerSha512.'
        }
        Write-Log 'MSI SHA-512 verified.'
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $destination
    $signedByWazuh = $signature.SignerCertificate -and
        $signature.SignerCertificate.Subject -match 'Wazuh'
    if ($signature.Status -ne 'Valid' -or -not $signedByWazuh) {
        if (-not $InstallerSha512) {
            throw "MSI Authenticode validation failed: $($signature.Status)."
        }
        Write-Log 'WARNING: Authenticode was not valid; accepting the explicitly pinned SHA-512.'
    }
    else {
        Write-Log "MSI signature verified: $($signature.SignerCertificate.Subject)"
    }

    return $destination
}

function Start-AndVerifyService {
    Set-Service -Name 'WazuhSvc' -StartupType Automatic
    $service = Get-Service -Name 'WazuhSvc'
    if ($service.Status -ne 'Running') {
        Start-Service -Name 'WazuhSvc'
        $service = Get-Service -Name 'WazuhSvc'
        $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    }

    $service = Get-Service -Name 'WazuhSvc'
    if ($service.Status -ne 'Running') {
        throw 'WazuhSvc did not reach Running state.'
    }
}

function Invoke-Msi {
    param(
        [string]$Path,
        [bool]$NewEnrollment
    )

    $arguments = @('/i', "`"$Path`"", '/qn', '/norestart')
    $msiLog = Join-Path $LogDir "wazuh_msi_$((Get-Date -Format 'yyyyMMdd-HHmmss')).log"

    if ($NewEnrollment) {
        $arguments += "WAZUH_MANAGER=`"$Manager`""
        $arguments += "WAZUH_AGENT_GROUP=`"$AgentGroup`""
        $arguments += "WAZUH_AGENT_NAME=`"$AgentName`""

        if ($RegistrationPasswordFile) {
            $script:RegistrationPassword = Get-RegistrationPassword -Path $RegistrationPasswordFile
            $arguments += 'MsiHiddenProperties=WAZUH_REGISTRATION_PASSWORD'
            $arguments += "WAZUH_REGISTRATION_PASSWORD=`"$script:RegistrationPassword`""
            Write-Log 'Using an enrollment password from a protected local file.'
        }
        else {
            $arguments += @('/L*v', "`"$msiLog`"")
        }
    }
    else {
        $arguments += @('/L*v', "`"$msiLog`"")
    }

    Write-Log 'Running msiexec; MSI property values are not written to the deployment log.'
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru
    Write-Log "msiexec exit code: $($process.ExitCode)"
    if ($process.ExitCode -notin @(0, 3010)) {
        throw "MSI operation returned $($process.ExitCode)."
    }
    if ($process.ExitCode -eq 3010) {
        Write-Log 'MSI completed successfully and requested a reboot.'
    }
}

function Invoke-Deployment {
    Assert-Inputs
    Write-Log '=== Wazuh GPO deploy ==='
    Write-Log "manager=$Manager group=$AgentGroup name=$AgentName version=$Version"

    $product = Get-WazuhProduct
    $service = Get-Service -Name 'WazuhSvc' -ErrorAction SilentlyContinue
    $currentManager = Get-ConfiguredManager

    if ($product -and $currentManager -and $currentManager -ne $Manager) {
        Write-Log "FAIL: existing agent targets '$currentManager', not '$Manager'."
        Write-Log 'Manager migration requires deliberate re-enrollment; no changes were made.'
        return 2
    }
    if ($product -and -not $currentManager) {
        Write-Log 'FAIL: Wazuh is installed but ossec.conf has no manager address.'
        Write-Log 'The damaged configuration requires deliberate repair; no changes were made.'
        return 2
    }

    if ($product -and (Test-AgentVersion -InstalledVersion $product.DisplayVersion -RequestedVersion $Version)) {
        if ($service) {
            if ($service.Status -ne 'Running') {
                Write-Log 'Installed version is correct; starting the stopped service.'
                Start-AndVerifyService
            }
            Write-Log "Wazuh Agent $($product.DisplayVersion) is installed and running."
            Write-Log 'Existing group membership must be verified on the Wazuh manager.'
            return 0
        }

        Write-Log 'MSI registration exists but WazuhSvc is missing; repairing the installation.'
        $script:WorkingMsi = Get-Installer
        Invoke-Msi -Path $script:WorkingMsi -NewEnrollment $false
    }
    elseif ($product) {
        Write-Log "Upgrading Wazuh Agent $($product.DisplayVersion) to $Version."
        $script:WorkingMsi = Get-Installer
        Invoke-Msi -Path $script:WorkingMsi -NewEnrollment $false
    }
    else {
        Write-Log 'Wazuh Agent is not installed; performing a new enrollment.'
        $script:WorkingMsi = Get-Installer
        Invoke-Msi -Path $script:WorkingMsi -NewEnrollment $true
    }

    Start-AndVerifyService

    $configuredManager = Get-ConfiguredManager
    if ($configuredManager -ne $Manager) {
        throw "Post-install manager is '$configuredManager', expected '$Manager'."
    }
    $installedProduct = Get-WazuhProduct
    if (-not $installedProduct -or
        -not (Test-AgentVersion -InstalledVersion $installedProduct.DisplayVersion -RequestedVersion $Version)) {
        throw 'Post-install version verification failed.'
    }

    Write-Log "Wazuh Agent $($installedProduct.DisplayVersion) is running. Deployment complete."
    return 0
}

$exitCode = 1
try {
    $exitCode = Invoke-Deployment
}
catch {
    Write-Log "FAIL: $($_.Exception.Message)"
    $exitCode = 1
}
finally {
    $RegistrationPassword = $null
    if ($WorkingMsi -and (Test-Path -LiteralPath $WorkingMsi)) {
        Remove-Item -LiteralPath $WorkingMsi -Force -ErrorAction SilentlyContinue
    }
}

exit $exitCode
