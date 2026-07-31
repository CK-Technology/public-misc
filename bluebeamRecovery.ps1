#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Unattended recovery and reinstall for Bluebeam Revu 21.
.DESCRIPTION
    Intended for remote execution as Administrator or SYSTEM. Downloads the
    exact installed Revu MSI to satisfy Windows Installer source requirements,
    downloads the latest Revu MSI before making changes, silently removes the
    existing installation, installs the latest release, and verifies success.

    Run through ScreenConnect:
    powershell -NoProfile -ExecutionPolicy Bypass -Command "irm 'https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/bluebeamRecovery.ps1' | iex"
#>

function Invoke-BluebeamRecovery {
    [CmdletBinding()]
    param()

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $dataRoot = 'C:\ProgramData\CKScripts'
    $packageRoot = Join-Path $dataRoot 'BluebeamPackages'
    $logRoot = Join-Path $dataRoot 'Logs'
    $logPath = Join-Path $logRoot 'BluebeamRecovery.log'

    New-Item -Path $packageRoot -ItemType Directory -Force | Out-Null
    New-Item -Path $logRoot -ItemType Directory -Force | Out-Null

    function Write-RecoveryLog {
        param(
            [Parameter(Mandatory)] [string]$Message,
            [ValidateSet('INFO', 'WARN', 'ERROR')] [string]$Level = 'INFO'
        )

        $entry = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Write-Host $entry
        Add-Content -Path $logPath -Value $entry
    }

    function Get-InstalledRevu {
        $paths = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )

        Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DisplayName -like '*Bluebeam Revu*' -and
                $_.DisplayVersion -match '^21(?:\.|$)'
            } |
            Sort-Object { [version]$_.DisplayVersion } -Descending |
            Select-Object -First 1
    }

    function Get-LatestRevuVersion {
        $manifestUrl = 'https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/b/Bluebeam/Revu/21'

        try {
            $versions = Invoke-RestMethod -Uri $manifestUrl -UseBasicParsing -TimeoutSec 30 |
                Where-Object { $_.type -eq 'dir' -and $_.name -match '^\d+\.\d+\.\d+$' } |
                ForEach-Object { [version]$_.name } |
                Sort-Object -Descending

            if ($versions) {
                return $versions[0]
            }
        }
        catch {
            Write-RecoveryLog "Latest-version lookup failed: $($_.Exception.Message)" -Level WARN
        }

        return [version]'21.10.0'
    }

    function Get-VersionString {
        param([Parameter(Mandatory)] [version]$Version)
        '{0}.{1}.{2}' -f $Version.Major, $Version.Minor, $Version.Build
    }

    function Get-RevuPackage {
        param([Parameter(Mandatory)] [version]$Version)

        $versionString = Get-VersionString -Version $Version
        $versionRoot = Join-Path $packageRoot $versionString
        $extractRoot = Join-Path $versionRoot 'MSI'
        $zipPath = Join-Path $versionRoot "MSIBluebeamRevu${versionString}x64.zip"

        New-Item -Path $versionRoot -ItemType Directory -Force | Out-Null

        $existingMsi = Get-ChildItem -Path $extractRoot -Filter 'Bluebeam Revu x64 21.msi' -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($existingMsi) {
            Write-RecoveryLog "Using staged Revu $versionString package at $($existingMsi.FullName)"
            return $existingMsi.FullName
        }

        $downloadUrl = "https://downloads.bluebeam.com/software/downloads/$versionString/MSIBluebeamRevu${versionString}x64.zip"
        $partialPath = "$zipPath.partial"
        Remove-Item -Path $partialPath -Force -ErrorAction SilentlyContinue

        Write-RecoveryLog "Downloading Revu $versionString from $downloadUrl"
        Invoke-WebRequest -Uri $downloadUrl -OutFile $partialPath -UseBasicParsing -TimeoutSec 900

        if ((Get-Item -Path $partialPath).Length -lt 1MB) {
            throw "Downloaded Revu $versionString archive is unexpectedly small."
        }

        Move-Item -Path $partialPath -Destination $zipPath -Force
        Remove-Item -Path $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive -Path $zipPath -DestinationPath $extractRoot -Force

        $msiFiles = @(Get-ChildItem -Path $extractRoot -Filter 'Bluebeam Revu x64 21.msi' -Recurse)
        if ($msiFiles.Count -ne 1) {
            throw "Expected one Revu MSI in the $versionString archive; found $($msiFiles.Count)."
        }

        $signature = Get-AuthenticodeSignature -FilePath $msiFiles[0].FullName
        if ($signature.Status -ne 'Valid') {
            throw "Revu $versionString MSI signature is not valid: $($signature.Status)."
        }

        return $msiFiles[0].FullName
    }

    function Invoke-MsiExec {
        param(
            [Parameter(Mandatory)] [string[]]$Arguments,
            [Parameter(Mandatory)] [string]$Operation,
            [int[]]$AllowedExitCodes = @(0, 1641, 3010)
        )

        Write-RecoveryLog "Starting Windows Installer operation: $Operation"
        $process = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" `
            -ArgumentList $Arguments -Wait -PassThru -NoNewWindow

        Write-RecoveryLog "$Operation completed with exit code $($process.ExitCode)"
        if ($process.ExitCode -notin $AllowedExitCodes) {
            throw "$Operation failed with Windows Installer exit code $($process.ExitCode)."
        }

        return $process.ExitCode
    }

    Write-RecoveryLog 'Bluebeam unattended recovery started.'

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Recovery must run as Administrator or SYSTEM.'
    }

    $installedApp = Get-InstalledRevu
    $latestVersion = Get-LatestRevuVersion
    Write-RecoveryLog "Latest available Revu version: $latestVersion"

    # Stage every package before uninstalling so a network failure cannot leave
    # the machine without Revu.
    $latestMsi = Get-RevuPackage -Version $latestVersion
    $installedMsi = $null
    $installedVersion = $null

    if ($installedApp) {
        $installedVersion = [version]$installedApp.DisplayVersion
        Write-RecoveryLog "Detected installed Revu version: $installedVersion"
        $installedMsi = Get-RevuPackage -Version $installedVersion
    }
    else {
        Write-RecoveryLog 'No registered Revu 21 installation found; proceeding with a clean install.' -Level WARN
    }

    'Revu', 'Stapler', 'PbMngr5', 'BBPrint' | ForEach-Object {
        Get-Process -Name $_ -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    if ($installedMsi) {
        $uninstallLog = Join-Path $logRoot 'BluebeamRecovery-Uninstall.log'
        Invoke-MsiExec -Operation "Uninstall Revu $installedVersion" -AllowedExitCodes @(0, 1605, 1614, 1641, 3010) -Arguments @(
            '/x', "`"$installedMsi`"", '/qn', '/norestart', '/l*v', "`"$uninstallLog`"", 'IGNORE_RBT=1'
        ) | Out-Null
    }

    $installLog = Join-Path $logRoot 'BluebeamRecovery-Install.log'
    Invoke-MsiExec -Operation "Install Revu $latestVersion" -Arguments @(
        '/i', "`"$latestMsi`"", '/qn', '/norestart', '/l*v', "`"$installLog`"", 'BB_AUTO_UPDATE=0', 'IGNORE_RBT=1'
    ) | Out-Null

    $verifiedApp = Get-InstalledRevu
    if (-not $verifiedApp) {
        throw 'Revu 21 was not found in the registry after installation.'
    }

    $verifiedVersion = [version]$verifiedApp.DisplayVersion
    if ($verifiedVersion -lt $latestVersion) {
        throw "Recovery verification failed: expected at least $latestVersion, found $verifiedVersion."
    }

    Write-RecoveryLog "SUCCESS: Bluebeam Revu $verifiedVersion is installed."
    Write-RecoveryLog "The current MSI source is retained under $packageRoot for future servicing."
}

try {
    Invoke-BluebeamRecovery
}
catch {
    $message = "Bluebeam recovery FAILED: $($_.Exception.Message)"
    Write-Error $message
    throw
}
