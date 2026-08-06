#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
Installs Sysmon, or reconciles an installed Sysmon onto the requested configuration.

.DESCRIPTION
Intended for a GPO scheduled task or an RMM running as SYSTEM. Safe to run
repeatedly: it installs a missing Sysmon, applies the configuration only when the
running configuration differs from the requested one, and starts a stopped
service without reinstalling.

Sysmon has no in-place binary upgrade. Running -i against an existing
installation fails with "the service is already registered", and the supported
sequence is an uninstall followed by a fresh install, which is disruptive and is
known to leave remnants on a minority of endpoints. This script therefore fails
closed on a binary version mismatch and reports it rather than acting. Pass
-AllowBinaryUpgrade to authorize the uninstall/reinstall deliberately.

Configuration drift is tracked with a marker file recording the SHA-256 of the
configuration this script last applied. Sysmon's own compiled rule blob under the
driver's Parameters key is not used: its layout changes between Sysmon versions,
and the driver name is not guaranteed to be SysmonDrv.

Use -ConfigPath to apply a built configuration from a controlled share. Omit both
config parameters to fetch the vendored base configuration, which is an unmodified
sysmon-modular build and contains no environment-specific tuning.

.PARAMETER ConfigPath
Local or UNC path to a Sysmon configuration. Mutually exclusive with -ConfigUrl.

.PARAMETER ConfigUrl
Absolute HTTPS URL to a Sysmon configuration. Pin it to an immutable commit.

.PARAMETER ConfigSha256
Optional SHA-256 pin for the configuration. Strongly recommended when -ConfigUrl
points at a mutable branch reference.

.PARAMETER Version
Optional expected Sysmon binary version, for example '15.15'. When supplied and
the installed version differs, the script reports and stops unless
-AllowBinaryUpgrade is also supplied.

.PARAMETER AllowBinaryUpgrade
Authorizes 'sysmon -u force' followed by a fresh install. Disruptive. Expect to
reboot the endpoint, and expect a minority of endpoints to need manual cleanup.

.NOTES
Author: CK Technology LLC
Logs to C:\ProgramData\CKTech\logs\sysmon_deploy.log

Exit codes:
  0  Sysmon is installed, running, and on the requested configuration
  1  Failure
  2  Refused - a deliberate decision is required; nothing was changed
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$ConfigUrl,
    [string]$ConfigSha256,
    [string]$Version,
    [string]$SysmonZipPath,
    [string]$SysmonZipUrl = 'https://download.sysinternals.com/files/Sysmon.zip',
    [string]$SysmonZipSha256,
    [switch]$AllowBinaryUpgrade
)

$ErrorActionPreference = 'Stop'

$DefaultConfigUrl = 'https://raw.githubusercontent.com/CK-Technology/public-misc/main/sysmon/config/sysmonconfig-base.xml'
$DataRoot = 'C:\ProgramData\CKTech'
$LogDir = Join-Path $DataRoot 'logs'
$StateDir = Join-Path $DataRoot 'state'
$LogFile = Join-Path $LogDir 'sysmon_deploy.log'
$MarkerFile = Join-Path $StateDir 'sysmon_config.sha256'
# The old C:\ProgramData\CKScripts marker is deliberately not read. It sat on a
# path any user could write, and ignoring it costs one redundant 'sysmon -c'.
$WorkingDir = $null

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

# %ProgramData% grants Users create-file/create-folder, and CREATOR OWNER full
# control of whatever they create. The marker file below decides whether Sysmon
# is reconfigured, so a user who can write it can pin a stale configuration.
# Inheritance is broken and the ACL set explicitly on every run.
try {
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $account = (New-Object System.Security.Principal.SecurityIdentifier($sid))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $account, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    $users = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $users, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    Set-Acl -LiteralPath $DataRoot -AclObject $acl
}
catch {
    Write-Warning "Could not harden $DataRoot ACL: $($_.Exception.Message)"
}

function Write-Log {
    param([string]$Message)

    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'), $Message
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Value $line
}

function Assert-Inputs {
    if ($ConfigPath -and $ConfigUrl) {
        throw 'Use ConfigPath or ConfigUrl, not both.'
    }
    if ($ConfigSha256 -and $ConfigSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'ConfigSha256 must be a 64-character SHA-256 value.'
    }
    if ($SysmonZipSha256 -and $SysmonZipSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'SysmonZipSha256 must be a 64-character SHA-256 value.'
    }
    if ($Version -and $Version -notmatch '^\d+\.\d+$') {
        throw 'Version must use the Sysmon X.Y format, for example 15.15.'
    }
    if ($SysmonZipPath -and $PSBoundParameters.ContainsKey('SysmonZipUrl')) {
        throw 'Use SysmonZipPath or SysmonZipUrl, not both.'
    }
}

function Get-TargetArchitecture {
    # A 32-bit PowerShell host on a 64-bit OS reports x86 in PROCESSOR_ARCHITECTURE
    # and the real architecture in PROCESSOR_ARCHITEW6432.
    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) {
        $arch = $env:PROCESSOR_ARCHITECTURE
    }

    switch ($arch.ToUpperInvariant()) {
        'AMD64' { return 'Sysmon64.exe' }
        'ARM64' { return 'Sysmon64a.exe' }
        'X86'   { return 'Sysmon.exe' }
        default { throw "Unsupported processor architecture: $arch" }
    }
}

function Get-InstalledSysmon {
    # Sysmon copies itself into %windir% on install. Detect what is actually
    # present rather than assuming the name matching this machine's architecture,
    # so a mismatched historical install is still found and reported.
    foreach ($name in @('Sysmon64.exe', 'Sysmon64a.exe', 'Sysmon.exe')) {
        $path = Join-Path $env:SystemRoot $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $item = Get-Item -LiteralPath $path
            return [pscustomobject]@{
                Path        = $path
                ServiceName = [IO.Path]::GetFileNameWithoutExtension($name)
                Version     = $item.VersionInfo.FileVersion
            }
        }
    }
    return $null
}

function Get-SysmonService {
    param([string]$PreferredName)

    $names = @($PreferredName, 'Sysmon64', 'Sysmon64a', 'Sysmon') |
        Where-Object { $_ } |
        Select-Object -Unique

    foreach ($name in $names) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($service) {
            return $service
        }
    }
    return $null
}

function Test-SysmonVersion {
    param(
        [string]$InstalledVersion,
        [string]$RequestedVersion
    )

    if (-not $RequestedVersion) {
        return $true
    }
    if (-not $InstalledVersion) {
        return $false
    }
    $installedCore = [regex]::Match($InstalledVersion, '^\d+\.\d+').Value
    return $installedCore -eq $RequestedVersion
}

function Get-Configuration {
    $destination = Join-Path $script:WorkingDir 'sysmonconfig.xml'

    if ($ConfigPath) {
        if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
            throw "ConfigPath does not exist: $ConfigPath"
        }
        Write-Log "Copying configuration from $ConfigPath"
        Copy-Item -LiteralPath $ConfigPath -Destination $destination
    }
    else {
        $url = $ConfigUrl
        if (-not $url) {
            $url = $DefaultConfigUrl
            Write-Log 'No configuration supplied; using the vendored base configuration.'
            Write-Log 'The base carries no environment tuning. Use -ConfigPath for a built configuration.'
        }
        $uri = [uri]$url
        if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https') {
            throw 'ConfigUrl must be an absolute HTTPS URL.'
        }
        if (-not $ConfigSha256 -and $uri.AbsolutePath -match '/refs/heads/|/main/|/master/') {
            Write-Log 'WARNING: fetching a configuration from a mutable branch reference without a SHA-256 pin.'
            Write-Log 'WARNING: pin ConfigUrl to a commit and supply -ConfigSha256 for production use.'
        }

        Write-Log "Downloading configuration from $url"
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $uri -OutFile $destination -UseBasicParsing
    }

    $hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    if ($ConfigSha256 -and $hash -ne $ConfigSha256.ToUpperInvariant()) {
        throw 'Configuration SHA-256 does not match ConfigSha256.'
    }
    if ($ConfigSha256) {
        Write-Log 'Configuration SHA-256 verified.'
    }

    # Fail before touching Sysmon rather than handing it a truncated download.
    # XmlDocument.Load is used instead of an [xml] cast so the byte-order mark and
    # the declared encoding are handled at the file level.
    $document = New-Object System.Xml.XmlDocument
    try {
        $document.Load($destination)
    }
    catch {
        throw "Configuration is not well-formed XML: $($_.Exception.Message)"
    }
    if ($document.DocumentElement.Name -ne 'Sysmon') {
        throw "Configuration root element is '$($document.DocumentElement.Name)', expected 'Sysmon'."
    }

    return [pscustomobject]@{
        Path = $destination
        Hash = $hash
    }
}

function Get-SysmonBinary {
    $wanted = Get-TargetArchitecture
    $zip = Join-Path $script:WorkingDir 'Sysmon.zip'
    $extracted = Join-Path $script:WorkingDir 'Sysmon'

    if ($SysmonZipPath) {
        if (-not (Test-Path -LiteralPath $SysmonZipPath -PathType Leaf)) {
            throw "SysmonZipPath does not exist: $SysmonZipPath"
        }
        Write-Log "Copying Sysmon archive from $SysmonZipPath"
        Copy-Item -LiteralPath $SysmonZipPath -Destination $zip
    }
    else {
        $uri = [uri]$SysmonZipUrl
        if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https') {
            throw 'SysmonZipUrl must be an absolute HTTPS URL.'
        }
        Write-Log "Downloading Sysmon from $SysmonZipUrl"
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $uri -OutFile $zip -UseBasicParsing
    }

    if ($SysmonZipSha256) {
        $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        if ($actual -ne $SysmonZipSha256.ToUpperInvariant()) {
            throw 'Sysmon archive SHA-256 does not match SysmonZipSha256.'
        }
        Write-Log 'Sysmon archive SHA-256 verified.'
    }

    Expand-Archive -LiteralPath $zip -DestinationPath $extracted -Force
    $binary = Join-Path $extracted $wanted
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
        throw "The Sysmon archive does not contain $wanted."
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $binary
    $signedByMicrosoft = $signature.SignerCertificate -and
        $signature.SignerCertificate.Subject -match 'O=Microsoft Corporation'
    if ($signature.Status -ne 'Valid' -or -not $signedByMicrosoft) {
        throw "Sysmon Authenticode validation failed: $($signature.Status)."
    }
    Write-Log "Sysmon signature verified: $($signature.SignerCertificate.Subject)"
    Write-Log "Sysmon binary version: $((Get-Item -LiteralPath $binary).VersionInfo.FileVersion)"

    return $binary
}

function Invoke-Sysmon {
    param(
        [string]$Binary,
        [string[]]$Arguments
    )

    $stdout = Join-Path $script:WorkingDir 'sysmon-out.txt'
    $stderr = Join-Path $script:WorkingDir 'sysmon-err.txt'

    $process = Start-Process -FilePath $Binary -ArgumentList $Arguments -Wait -PassThru `
        -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr

    foreach ($file in @($stdout, $stderr)) {
        if (Test-Path -LiteralPath $file) {
            Get-Content -LiteralPath $file |
                Where-Object { $_.Trim() } |
                ForEach-Object { Write-Log "  sysmon: $_" }
        }
    }

    return $process.ExitCode
}

function Start-AndVerifyService {
    param([string]$ServiceName)

    $service = Get-SysmonService -PreferredName $ServiceName
    if (-not $service) {
        throw 'The Sysmon service is not registered.'
    }

    Set-Service -Name $service.Name -StartupType Automatic
    if ($service.Status -ne 'Running') {
        Start-Service -Name $service.Name
        (Get-Service -Name $service.Name).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    }

    if ((Get-Service -Name $service.Name).Status -ne 'Running') {
        throw "$($service.Name) did not reach Running state."
    }
}

function Get-AppliedConfigHash {
    if (-not (Test-Path -LiteralPath $MarkerFile -PathType Leaf)) {
        return $null
    }
    return (Get-Content -LiteralPath $MarkerFile -Raw).Trim().ToUpperInvariant()
}

function Set-AppliedConfigHash {
    param([string]$Hash)

    Set-Content -LiteralPath $MarkerFile -Value $Hash.ToUpperInvariant() -Encoding ASCII
}

function Invoke-Deployment {
    Assert-Inputs
    Write-Log '=== Sysmon deploy ==='

    $script:WorkingDir = Join-Path $env:TEMP ('sysmon-deploy-{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:WorkingDir -Force | Out-Null

    $config = Get-Configuration
    Write-Log "Requested configuration SHA-256: $($config.Hash)"

    $installed = Get-InstalledSysmon
    $service = if ($installed) { Get-SysmonService -PreferredName $installed.ServiceName } else { $null }

    if ($installed -and -not (Test-SysmonVersion -InstalledVersion $installed.Version -RequestedVersion $Version)) {
        if (-not $AllowBinaryUpgrade) {
            Write-Log "REFUSED: Sysmon $($installed.Version) is installed; $Version was requested."
            Write-Log 'Sysmon has no in-place upgrade. Changing the binary requires an uninstall and'
            Write-Log 'reinstall, which drops the driver and is known to need manual cleanup on some'
            Write-Log 'endpoints. Re-run with -AllowBinaryUpgrade to authorize it. No changes were made.'
            return 2
        }

        Write-Log "Upgrading Sysmon $($installed.Version) to $Version via uninstall and reinstall."
        $binary = Get-SysmonBinary
        # Uninstall with the NEW binary to avoid a client/service version mismatch.
        $code = Invoke-Sysmon -Binary $binary -Arguments @('-u', 'force')
        Write-Log "sysmon -u force exit code: $code"

        if (Get-InstalledSysmon) {
            Write-Log 'FAIL: Sysmon is still present after -u force.'
            Write-Log 'This endpoint needs a reboot and likely manual removal of the leftover'
            Write-Log 'Sysmon and SysmonDrv service keys before it can be reinstalled.'
            return 1
        }

        $code = Invoke-Sysmon -Binary $binary -Arguments @('-accepteula', '-i', $config.Path)
        if ($code -ne 0) {
            throw "sysmon -i returned $code."
        }
        Set-AppliedConfigHash -Hash $config.Hash
    }
    elseif (-not $installed) {
        Write-Log 'Sysmon is not installed; performing a new installation.'
        $binary = Get-SysmonBinary
        # Install with the config in one step. A bare -i followed by -c leaves a
        # window in which Sysmon runs on its default minimal configuration.
        $code = Invoke-Sysmon -Binary $binary -Arguments @('-accepteula', '-i', $config.Path)
        if ($code -ne 0) {
            throw "sysmon -i returned $code."
        }
        Set-AppliedConfigHash -Hash $config.Hash
    }
    else {
        Write-Log "Sysmon $($installed.Version) is installed as service $($installed.ServiceName)."
        $applied = Get-AppliedConfigHash

        if ($applied -ne $config.Hash) {
            if ($applied) {
                Write-Log "Configuration drift: applied $applied, requested $($config.Hash)."
            }
            else {
                Write-Log 'No applied-configuration marker found; applying the requested configuration.'
            }
            # -c updates a live installation without stopping the service.
            $code = Invoke-Sysmon -Binary $installed.Path -Arguments @('-c', $config.Path)
            if ($code -ne 0) {
                throw "sysmon -c returned $code."
            }
            Set-AppliedConfigHash -Hash $config.Hash
        }
        else {
            Write-Log 'Configuration already matches; no change required.'
        }
    }

    $installed = Get-InstalledSysmon
    if (-not $installed) {
        throw 'Post-install verification failed: no Sysmon binary in the Windows directory.'
    }
    Start-AndVerifyService -ServiceName $installed.ServiceName

    if ((Get-AppliedConfigHash) -ne $config.Hash) {
        throw 'Post-install verification failed: the applied-configuration marker does not match.'
    }

    Write-Log "Sysmon $($installed.Version) is running on configuration $($config.Hash). Deployment complete."
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
    if ($WorkingDir -and (Test-Path -LiteralPath $WorkingDir)) {
        Remove-Item -LiteralPath $WorkingDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

exit $exitCode
