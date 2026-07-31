#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Pilot recovery for damaged Bluebeam Revu 21 installations.
.DESCRIPTION
    Stages the exact prior and current deployment packages before changing the
    machine, supplies the prior MSI to remove an orphaned Windows Installer
    product, installs the bundled prerequisites, installs the current Revu MSI,
    and verifies the result. Intended for one-workstation-at-a-time validation.
#>

function Invoke-BluebeamRecovery {
    [CmdletBinding()]
    param()

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $damagedFleetVersion = [version]'21.8.0'
    $fallbackLatestVersion = [version]'21.10.0'
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
            Write-RecoveryLog "Latest-version lookup failed: $($_.Exception.Message)" -Level WARN
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

        $existingMsi = Get-ChildItem -Path $extractRoot -Filter 'Bluebeam Revu x64 21.msi' -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($existingMsi) {
            Test-ValidSignature -Path $existingMsi.FullName -Description "Staged Revu $versionString MSI"
            Write-RecoveryLog "Using staged Revu $versionString package at $($existingMsi.FullName)"
            return [pscustomobject]@{
                Version     = $Version
                MsiPath     = $existingMsi.FullName
                ExtractRoot = $extractRoot
            }
        }

        $downloadUrl = "https://downloads.bluebeam.com/software/downloads/$versionString/MSIBluebeamRevu${versionString}x64.zip"
        $partialPath = "$zipPath.partial"
        Remove-Item -Path $partialPath -Force -ErrorAction SilentlyContinue

        Write-RecoveryLog "Downloading official Revu $versionString deployment package."
        Invoke-WebRequest -Uri $downloadUrl -OutFile $partialPath -UseBasicParsing -TimeoutSec 3600
        if ((Get-Item -Path $partialPath).Length -lt 1GB) {
            throw "Downloaded Revu $versionString archive is unexpectedly small."
        }

        Move-Item -Path $partialPath -Destination $zipPath -Force
        Remove-Item -Path $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive -Path $zipPath -DestinationPath $extractRoot -Force

        $msiFiles = @(Get-ChildItem -Path $extractRoot -Filter 'Bluebeam Revu x64 21.msi' -Recurse)
        if ($msiFiles.Count -ne 1) {
            throw "Expected one Revu MSI in the $versionString archive; found $($msiFiles.Count)."
        }

        Test-ValidSignature -Path $msiFiles[0].FullName -Description "Revu $versionString MSI"
        return [pscustomobject]@{
            Version     = $Version
            MsiPath     = $msiFiles[0].FullName
            ExtractRoot = $extractRoot
        }
    }

    function Write-MsiFailureContext {
        param([Parameter(Mandatory)] [string]$MsiLogPath)

        if (-not (Test-Path -Path $MsiLogPath)) {
            return
        }

        $failure = Select-String -Path $MsiLogPath -Pattern 'Return value 3' -Context 15, 25 |
            Select-Object -Last 1
        if ($failure) {
            Write-RecoveryLog "Windows Installer failure context from $MsiLogPath" -Level ERROR
            @($failure.Context.PreContext) + @($failure.Line) + @($failure.Context.PostContext) |
                ForEach-Object { Write-RecoveryLog $_ -Level ERROR }
        }
    }

    function Invoke-MsiExec {
        param(
            [Parameter(Mandatory)] [string[]]$Arguments,
            [Parameter(Mandatory)] [string]$Operation,
            [Parameter(Mandatory)] [string]$MsiLogPath,
            [int[]]$AllowedExitCodes = @(0, 1641, 3010)
        )

        Write-RecoveryLog "Starting Windows Installer operation: $Operation"
        $process = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" `
            -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
        Write-RecoveryLog "$Operation completed with exit code $($process.ExitCode)"

        if ($process.ExitCode -notin $AllowedExitCodes) {
            Write-MsiFailureContext -MsiLogPath $MsiLogPath
            throw "$Operation failed with Windows Installer exit code $($process.ExitCode)."
        }
    }

    function Invoke-Prerequisite {
        param(
            [Parameter(Mandatory)] [string]$Path,
            [Parameter(Mandatory)] [string]$Name,
            [Parameter(Mandatory)] [string[]]$Arguments,
            [int[]]$AllowedExitCodes = @(0, 1638, 3010)
        )

        Test-ValidSignature -Path $Path -Description $Name
        Write-RecoveryLog "Installing prerequisite: $Name"
        $process = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
        Write-RecoveryLog "$Name completed with exit code $($process.ExitCode)"
        if ($process.ExitCode -notin $AllowedExitCodes) {
            throw "$Name failed with exit code $($process.ExitCode)."
        }
    }

    function Install-RevuPrerequisites {
        param([Parameter(Mandatory)] $Package)

        foreach ($fileName in 'vc_redist.x86.exe', 'vc_redist.x64.exe') {
            $installer = Get-ChildItem -Path $Package.ExtractRoot -Filter $fileName -Recurse |
                Select-Object -First 1
            if (-not $installer) {
                throw "The official Revu package does not contain $fileName."
            }
            Invoke-Prerequisite -Path $installer.FullName -Name $fileName -Arguments @('/install', '/quiet', '/norestart')
        }

        $dotNetRelease = Get-ItemPropertyValue `
            -Path 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' `
            -Name Release -ErrorAction SilentlyContinue
        if ($dotNetRelease -lt 528040) {
            $dotNetInstaller = Get-ChildItem -Path $Package.ExtractRoot -Filter 'ndp48-*.exe' -Recurse |
                Select-Object -First 1
            if (-not $dotNetInstaller) {
                throw 'The official Revu package does not contain the .NET Framework prerequisite.'
            }
            Invoke-Prerequisite -Path $dotNetInstaller.FullName -Name '.NET Framework 4.8' `
                -Arguments @('/q', '/norestart') -AllowedExitCodes @(0, 3010)
        }
        else {
            Write-RecoveryLog ".NET Framework 4.8 or later is already installed (release $dotNetRelease)."
        }
    }

    Write-RecoveryLog 'Bluebeam pilot recovery started.'

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Recovery must run as Administrator or SYSTEM.'
    }

    $systemDrive = Get-PSDrive -Name (($env:SystemDrive).TrimEnd(':'))
    if ($systemDrive.Free -lt 16GB) {
        throw 'At least 16 GB of free system-drive space is required to stage both deployment packages safely.'
    }

    $installedApp = Get-InstalledRevu
    $sourceVersion = if ($installedApp) { [version]($installedApp.DisplayVersion) } else { $damagedFleetVersion }
    $latestVersion = Get-LatestRevuVersion
    Write-RecoveryLog "Prior source version: $sourceVersion; latest version: $latestVersion"

    # No MSI operation occurs until both full, signed packages are staged.
    $sourcePackage = Get-RevuPackage -Version $sourceVersion
    $latestPackage = if ($latestVersion -eq $sourceVersion) {
        $sourcePackage
    }
    else {
        Get-RevuPackage -Version $latestVersion
    }
    Install-RevuPrerequisites -Package $latestPackage

    'Revu', 'Stapler', 'PbMngr5', 'BBPrint' | ForEach-Object {
        Get-Process -Name $_ -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }

    $uninstallLog = Join-Path $logRoot 'BluebeamRecovery-Uninstall.log'
    Invoke-MsiExec -Operation "Remove orphaned/current Revu $sourceVersion" `
        -MsiLogPath $uninstallLog -AllowedExitCodes @(0, 1605, 1614, 1641, 3010) -Arguments @(
            '/x', "`"$($sourcePackage.MsiPath)`"", '/qn', '/norestart',
            '/l*v', "`"$uninstallLog`"", 'IGNORE_RBT=1', 'REBOOT=ReallySuppress'
        )

    $installLog = Join-Path $logRoot 'BluebeamRecovery-Install.log'
    Invoke-MsiExec -Operation "Install Revu $latestVersion" -MsiLogPath $installLog -Arguments @(
        '/i', "`"$($latestPackage.MsiPath)`"", '/qn', '/norestart',
        '/l*v', "`"$installLog`"", 'BB_AUTO_UPDATE=0', 'IGNORE_RBT=1', 'REBOOT=ReallySuppress'
    )

    $verifiedApp = Get-InstalledRevu
    if (-not $verifiedApp) {
        throw 'Revu 21 was not found in the registry after installation.'
    }

    $verifiedVersion = [version]$verifiedApp.DisplayVersion
    if ($verifiedVersion -lt $latestVersion) {
        throw "Recovery verification failed: expected at least $latestVersion, found $verifiedVersion."
    }

    Write-RecoveryLog "SUCCESS: Bluebeam Revu $verifiedVersion is installed."
    Write-RecoveryLog "Current servicing source retained under $packageRoot."
}

try {
    Invoke-BluebeamRecovery
}
catch {
    Write-Error "Bluebeam recovery FAILED: $($_.Exception.Message)"
    throw
}
