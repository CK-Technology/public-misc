#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Transactional Bluebeam Revu 21 updater.
.DESCRIPTION
    Stages signed current and latest deployment packages, installs bundled
    prerequisites, re-caches the current Windows Installer source, then invokes
    the latest MSI as an in-place upgrade. It never explicitly uninstalls Revu.
#>

function Invoke-BluebeamUpdate {
    [CmdletBinding()]
    param()

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $fallbackLatestVersion = [version]'21.10.0'
    $dataRoot = 'C:\ProgramData\CKScripts'
    $packageRoot = Join-Path $dataRoot 'BluebeamPackages'
    $logRoot = Join-Path $dataRoot 'Logs'
    $logPath = Join-Path $logRoot 'BluebeamUpdate.log'
    New-Item -Path $packageRoot -ItemType Directory -Force | Out-Null
    New-Item -Path $logRoot -ItemType Directory -Force | Out-Null

    function Write-UpdateLog {
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
            $response = Invoke-RestMethod -Uri $manifestUrl -UseBasicParsing -TimeoutSec 30
            $versions = $response |
                Where-Object { $_.type -eq 'dir' -and $_.name -match '^\d+\.\d+\.\d+$' } |
                ForEach-Object { [version]$_.name } |
                Sort-Object -Descending
            if ($versions) {
                return [version]($versions[0])
            }
        }
        catch {
            Write-UpdateLog "Latest-version lookup failed: $($_.Exception.Message)" -Level WARN
        }
        return $fallbackLatestVersion
    }

    function Get-VersionString {
        param([Parameter(Mandatory)] [version]$Version)
        '{0}.{1}.{2}' -f $Version.Major, $Version.Minor, $Version.Build
    }

    function Test-ValidSignature {
        param(
            [Parameter(Mandatory)] [string]$Path,
            [Parameter(Mandatory)] [string]$Description
        )
        $signature = Get-AuthenticodeSignature -FilePath $Path
        if ($signature.Status -ne 'Valid') {
            throw "$Description signature is not valid: $($signature.Status)."
        }
    }

    function Get-RevuPackage {
        param([Parameter(Mandatory)] [version]$Version)

        $versionString = Get-VersionString -Version $Version
        $versionRoot = Join-Path $packageRoot $versionString
        $extractRoot = Join-Path $versionRoot 'MSI'
        $zipPath = Join-Path $versionRoot "MSIBluebeamRevu${versionString}x64.zip"
        New-Item -Path $versionRoot -ItemType Directory -Force | Out-Null

        $msi = Get-ChildItem -Path $extractRoot -Filter 'Bluebeam Revu x64 21.msi' -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $msi) {
            $downloadUrl = "https://downloads.bluebeam.com/software/downloads/$versionString/MSIBluebeamRevu${versionString}x64.zip"
            $partialPath = "$zipPath.partial"
            Remove-Item -Path $partialPath -Force -ErrorAction SilentlyContinue
            Write-UpdateLog "Downloading official Revu $versionString deployment package."
            Invoke-WebRequest -Uri $downloadUrl -OutFile $partialPath -UseBasicParsing -TimeoutSec 3600
            if ((Get-Item -Path $partialPath).Length -lt 1GB) {
                throw "Downloaded Revu $versionString archive is unexpectedly small."
            }
            Move-Item -Path $partialPath -Destination $zipPath -Force
            Remove-Item -Path $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
            Expand-Archive -Path $zipPath -DestinationPath $extractRoot -Force
            $matches = @(Get-ChildItem -Path $extractRoot -Filter 'Bluebeam Revu x64 21.msi' -Recurse)
            if ($matches.Count -ne 1) {
                throw "Expected one Revu MSI in the $versionString archive; found $($matches.Count)."
            }
            $msi = $matches[0]
        }

        Test-ValidSignature -Path $msi.FullName -Description "Revu $versionString MSI"
        [pscustomobject]@{
            Version     = $Version
            MsiPath     = $msi.FullName
            ExtractRoot = $extractRoot
        }
    }

    function Write-MsiFailureContext {
        param([Parameter(Mandatory)] [string]$MsiLogPath)
        if (-not (Test-Path -Path $MsiLogPath)) { return }
        $failure = Select-String -Path $MsiLogPath -Pattern 'Return value 3' -Context 15, 25 |
            Select-Object -Last 1
        if ($failure) {
            Write-UpdateLog "Windows Installer failure context from $MsiLogPath" -Level ERROR
            @($failure.Context.PreContext) + @($failure.Line) + @($failure.Context.PostContext) |
                ForEach-Object { Write-UpdateLog $_ -Level ERROR }
        }
    }

    function Invoke-MsiExec {
        param(
            [Parameter(Mandatory)] [string[]]$Arguments,
            [Parameter(Mandatory)] [string]$Operation,
            [Parameter(Mandatory)] [string]$MsiLogPath
        )
        Write-UpdateLog "Starting Windows Installer operation: $Operation"
        $process = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" `
            -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
        Write-UpdateLog "$Operation completed with exit code $($process.ExitCode)"
        if ($process.ExitCode -notin @(0, 1641, 3010)) {
            Write-MsiFailureContext -MsiLogPath $MsiLogPath
            throw "$Operation failed with Windows Installer exit code $($process.ExitCode)."
        }
    }

    function Install-RevuPrerequisites {
        param([Parameter(Mandatory)] $Package)
        foreach ($fileName in 'vc_redist.x86.exe', 'vc_redist.x64.exe') {
            $installer = Get-ChildItem -Path $Package.ExtractRoot -Filter $fileName -Recurse |
                Select-Object -First 1
            if (-not $installer) { throw "The official Revu package does not contain $fileName." }
            Test-ValidSignature -Path $installer.FullName -Description $fileName
            Write-UpdateLog "Installing prerequisite: $fileName"
            $process = Start-Process -FilePath $installer.FullName `
                -ArgumentList @('/install', '/quiet', '/norestart') -Wait -PassThru -NoNewWindow
            Write-UpdateLog "$fileName completed with exit code $($process.ExitCode)"
            if ($process.ExitCode -notin @(0, 1638, 3010)) {
                throw "$fileName failed with exit code $($process.ExitCode)."
            }
        }
    }

    Write-UpdateLog 'Bluebeam transactional update started.'
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Updater must run as Administrator or SYSTEM.'
    }

    $installedApp = Get-InstalledRevu
    if (-not $installedApp) {
        throw 'No normal Revu 21 installation is registered. Use bluebeamRecovery.ps1 instead.'
    }

    $installedVersion = [version]($installedApp.DisplayVersion)
    $latestVersion = Get-LatestRevuVersion
    Write-UpdateLog "Installed version: $installedVersion; latest version: $latestVersion"
    if ($installedVersion -ge $latestVersion) {
        Write-UpdateLog 'Bluebeam Revu is already current; no changes made.'
        return
    }

    $systemDrive = Get-PSDrive -Name (($env:SystemDrive).TrimEnd(':'))
    if ($systemDrive.Free -lt 16GB) {
        throw 'At least 16 GB of free system-drive space is required to stage both deployment packages safely.'
    }

    # Stage and validate both packages before servicing the existing product.
    $installedPackage = Get-RevuPackage -Version $installedVersion
    $latestPackage = Get-RevuPackage -Version $latestVersion
    Install-RevuPrerequisites -Package $latestPackage

    'Revu', 'Stapler', 'PbMngr5', 'BBPrint' | ForEach-Object {
        Get-Process -Name $_ -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }

    # Re-cache the exact installed package so Windows Installer no longer needs
    # the original network location. Failure stops before the upgrade begins.
    $recacheLog = Join-Path $logRoot 'BluebeamUpdate-Recache.log'
    Invoke-MsiExec -Operation "Repair and re-cache Revu $installedVersion" -MsiLogPath $recacheLog -Arguments @(
        '/fvomus', "`"$($installedPackage.MsiPath)`"", '/qn', '/norestart',
        '/l*v', "`"$recacheLog`"", 'IGNORE_RBT=1', 'REBOOT=ReallySuppress'
    )

    # Bluebeam's point-release MSI owns removal and replacement as one Windows
    # Installer transaction, preserving rollback if the upgrade fails.
    $upgradeLog = Join-Path $logRoot 'BluebeamUpdate-Install.log'
    Invoke-MsiExec -Operation "Upgrade Revu to $latestVersion" -MsiLogPath $upgradeLog -Arguments @(
        '/i', "`"$($latestPackage.MsiPath)`"", '/qn', '/norestart',
        '/l*v', "`"$upgradeLog`"", 'BB_AUTO_UPDATE=0', 'IGNORE_RBT=1', 'REBOOT=ReallySuppress'
    )

    $verifiedApp = Get-InstalledRevu
    if (-not $verifiedApp) { throw 'Revu disappeared from the registry after the upgrade.' }
    $verifiedVersion = [version]($verifiedApp.DisplayVersion)
    if ($verifiedVersion -lt $latestVersion) {
        throw "Update verification failed: expected at least $latestVersion, found $verifiedVersion."
    }
    Write-UpdateLog "SUCCESS: Bluebeam Revu updated to $verifiedVersion."
    Write-UpdateLog "Current servicing source retained under $packageRoot."
}

try {
    Invoke-BluebeamUpdate
}
catch {
    Write-Error "Bluebeam update FAILED: $($_.Exception.Message)"
    throw
}
