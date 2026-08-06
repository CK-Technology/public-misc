#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Clears orphaned Bluebeam Revu 21 Windows Installer registrations, then
    installs Revu from a staged MSI.
.DESCRIPTION
    A Revu 21 upgrade that fails part way leaves a ProductCode registered in
    the Classes installer hive and listed under its UpgradeCode, with no
    product data and no cached MSI. FindRelatedProducts still finds it, then
    RemoveExistingProducts cannot resolve a source to remove it, so every
    later install dies with 1612 -> 1714 -> 1603. That residue is invisible to
    the vendor uninstall script, which gates every removal behind a REG QUERY
    of the Uninstall key that no longer exists.

    This script removes only that residue, and only for ProductCodes published
    by Bluebeam for Revu 21. Every key is exported to a .reg backup before it
    is touched. Anything not in the vendor table is left alone.

    DRY RUN BY DEFAULT. To apply changes, set BBCLEAN_APPLY=1 first:
        $env:BBCLEAN_APPLY='1'; irm <url> | iex

    Run bluebeamdiag.ps1 first. Do not run this on a machine with a healthy
    Revu registration -- it will find nothing to do and say so.
#>

function Invoke-BluebeamClean {
    [CmdletBinding()]
    param()

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    $apply = $env:BBCLEAN_APPLY -eq '1'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dataRoot = 'C:\ProgramData\CKTech'
    $logRoot = Join-Path $dataRoot 'logs'
    $backupRoot = Join-Path $dataRoot "backups\registry\$stamp"
    $logPath = Join-Path $logRoot 'BluebeamClean.log'
    New-Item -Path $logRoot -ItemType Directory -Force | Out-Null

    function Write-CleanLog {
        param(
            [string]$Message = '',
            [ValidateSet('INFO', 'WARN', 'ERROR', 'ACTION')] [string]$Level = 'INFO'
        )
        $entry = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Write-Host $entry
        Add-Content -Path $logPath -Value $entry -Encoding UTF8
    }

    function ConvertFrom-PackedGuid {
        param([Parameter(Mandatory)] [string]$Packed)
        if ($Packed -notmatch '^[0-9A-Fa-f]{32}$') { return $null }
        $tail = for ($index = 16; $index -lt 32; $index += 2) {
            $Packed[$index + 1]
            $Packed[$index]
        }
        $guid = '{{{0}-{1}-{2}-{3}-{4}}}' -f `
            (-join $Packed[7..0]), (-join $Packed[11..8]), (-join $Packed[15..12]),
            (-join $tail[0..3]), (-join $tail[4..15])
        return $guid.ToUpperInvariant()
    }

    function ConvertTo-PackedGuid {
        param([Parameter(Mandatory)] [string]$Guid)
        $hex = ($Guid -replace '[{}\-]', '').ToUpperInvariant()
        if ($hex -notmatch '^[0-9A-F]{32}$') { return $null }
        $swapPairs = {
            param([string]$Text)
            $builder = New-Object Text.StringBuilder
            for ($index = 0; $index -lt $Text.Length; $index += 2) {
                [void]$builder.Append($Text[$index + 1]).Append($Text[$index])
            }
            $builder.ToString()
        }
        return (-join $hex[7..0]) + (-join $hex[11..8]) + (-join $hex[15..12]) +
            (& $swapPairs $hex.Substring(16, 4)) + (& $swapPairs $hex.Substring(20, 12))
    }

    function Get-MsiProperty {
        param(
            [Parameter(Mandatory)] [string]$Path,
            [Parameter(Mandatory)] [ValidateSet('ProductCode', 'ProductVersion')] [string]$Property
        )

        if (-not ('CKBluebeam.NativeMsi' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace CKBluebeam {
    public static class NativeMsi {
        [DllImport("msi.dll", CharSet = CharSet.Unicode)]
        private static extern uint MsiOpenDatabase(string path, IntPtr persist, out IntPtr database);
        [DllImport("msi.dll", CharSet = CharSet.Unicode)]
        private static extern uint MsiDatabaseOpenView(IntPtr database, string query, out IntPtr view);
        [DllImport("msi.dll")]
        private static extern uint MsiViewExecute(IntPtr view, IntPtr record);
        [DllImport("msi.dll")]
        private static extern uint MsiViewFetch(IntPtr view, out IntPtr record);
        [DllImport("msi.dll", CharSet = CharSet.Unicode)]
        private static extern uint MsiRecordGetString(IntPtr record, uint field, StringBuilder value, ref uint size);
        [DllImport("msi.dll")]
        private static extern uint MsiCloseHandle(IntPtr handle);

        private static void Check(uint result, string operation) {
            if (result != 0) throw new Win32Exception((int)result, operation + " failed");
        }

        public static string GetProperty(string path, string property) {
            IntPtr database = IntPtr.Zero;
            IntPtr view = IntPtr.Zero;
            IntPtr record = IntPtr.Zero;
            try {
                Check(MsiOpenDatabase(path, IntPtr.Zero, out database), "MsiOpenDatabase");
                string query = "SELECT `Value` FROM `Property` WHERE `Property`='" + property + "'";
                Check(MsiDatabaseOpenView(database, query, out view), "MsiDatabaseOpenView");
                Check(MsiViewExecute(view, IntPtr.Zero), "MsiViewExecute");
                Check(MsiViewFetch(view, out record), "MsiViewFetch");
                uint size = 256;
                StringBuilder value = new StringBuilder((int)size);
                Check(MsiRecordGetString(record, 1, value, ref size), "MsiRecordGetString");
                return value.ToString();
            }
            finally {
                if (record != IntPtr.Zero) MsiCloseHandle(record);
                if (view != IntPtr.Zero) MsiCloseHandle(view);
                if (database != IntPtr.Zero) MsiCloseHandle(database);
            }
        }
    }
}
'@
        }
        return [CKBluebeam.NativeMsi]::GetProperty($Path, $Property)
    }

    # Sourced verbatim from "Uninstall Previous Versions.txt" in the vendor's
    # 21.10.0 deployment package. This table is the safety boundary: a key is
    # only ever removed if its ProductCode appears here.
    $knownProducts = [ordered]@{
        '{9CF5BE6F-EE13-4223-860F-799F6A579012}' = 'Revu 21.10.0 x64'
        '{26F14882-5288-41A1-B6EC-DE55EBDC7925}' = 'Revu 21.9.0 x64'
        '{11C566C0-9F6C-4FC0-A54F-CE3F979EB29B}' = 'Revu 21.8.0 x64'
        '{99588A9A-57A2-4807-9B55-6CB84E83FECA}' = 'Revu 21.7.0 x64'
        '{6FF2A905-75DD-476C-A68C-908367C4C862}' = 'Revu 21.6.1 x64'
        '{79C165CF-EC85-4E26-A547-8852CD92855D}' = 'Revu 21.6.0 x64'
        '{4654C225-1369-4FBA-B3A5-A4C03C19FF01}' = 'Revu 21.5.0 x64'
        '{143F713F-C3CD-482F-8630-7C3A21505973}' = 'Revu 21.4.0 x64'
        '{89CC9BA4-F31C-4A21-A382-48FC60B53FBD}' = 'Revu 21.3.0 x64'
        '{63346F03-08A1-42D6-BE10-3F833B7E0566}' = 'Revu 21.2.1 x64'
        '{1BDC2EDF-3FA6-4C6F-A7BA-CD78E43F52A8}' = 'Revu 21.2.0 x64'
        '{9648D04F-E34D-4F89-B039-E0BB5E3E82B4}' = 'Revu 21.1.0 x64'
        '{66294273-86AD-4C47-91D5-9E7CC3C868B9}' = 'Revu 21.0.50 x64'
        '{72C7C3DC-A002-40D3-BBD9-2876F358CBE2}' = 'Revu 21.0.45 x64'
        '{5DBD4D93-F6C5-491A-A5B3-E88DA96568CB}' = 'Revu 21.0.40 x64'
        '{29C43448-6613-4312-A9B2-CD765FAB316B}' = 'Revu 21.0.30 x64'
        '{1A0E01E9-6CA1-49A8-A8D4-9F40831E10F0}' = 'Revu 21.0.20 x64'
        '{EDF2C191-4EFB-4738-8333-709576B0E914}' = 'Revu 21.0.20 x86'
        '{58DBE485-7210-4841-B468-16E101D5C504}' = 'Revu 21.0.15 x64'
        '{226345A6-28F4-43E2-8D98-1DF1FB7AC88F}' = 'Revu 21.0.15 x86'
    }

    function Get-RevuMsi {
        # Nothing staged locally. Get the Revu MSI from, in order of preference:
        #   1. $env:BBCLEAN_SOURCE - a UNC/local directory, .msi, or .zip.
        #      Use this for fleet work; the CDN zip is 2.5 GB per machine.
        #   2. The Bluebeam CDN, newest version in the vendor table first.
        # Returns a FileInfo for the extracted MSI, or $null.
        param(
            [Parameter(Mandatory)] [string]$PackageRoot,
            [Parameter(Mandatory)] [object]$KnownProducts
        )

        $msiName = 'Bluebeam Revu x64 21.msi'

        function Expand-RevuMsiFromZip {
            param([string]$ZipPath, [string]$Destination)
            # Pull only the Revu MSI. Expand-Archive would also write the 986 MB
            # OCR MSI and the redistributables, which are not needed here.
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
            try {
                $entry = $archive.Entries | Where-Object { $_.Name -eq $msiName } | Select-Object -First 1
                if (-not $entry) { throw "No '$msiName' inside $ZipPath." }
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $Destination, $true)
            }
            finally { $archive.Dispose() }
        }

        # ---- 1. Operator-supplied source -----------------------------------
        $source = $env:BBCLEAN_SOURCE
        if ($source) {
            Write-CleanLog "BBCLEAN_SOURCE is set: $source"
            if (-not (Test-Path -LiteralPath $source)) {
                Write-CleanLog "BBCLEAN_SOURCE does not exist or is unreachable from this machine (SYSTEM context cannot use mapped drives; use a UNC path)." -Level WARN
                return $null
            }
            $item = Get-Item -LiteralPath $source
            $staged = Join-Path $PackageRoot "from-source\$msiName"
            New-Item -Path (Split-Path $staged) -ItemType Directory -Force | Out-Null

            if ($item.PSIsContainer) {
                $found = Get-ChildItem -Path $item.FullName -Filter $msiName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $found) {
                    Write-CleanLog "No '$msiName' found under $source." -Level WARN
                    return $null
                }
                Write-CleanLog "Copying $($found.FullName)"
                Copy-Item -LiteralPath $found.FullName -Destination $staged -Force
            }
            elseif ($item.Extension -eq '.zip') {
                Write-CleanLog "Extracting $msiName from $($item.FullName)" -Level ACTION
                Expand-RevuMsiFromZip -ZipPath $item.FullName -Destination $staged
            }
            elseif ($item.Extension -eq '.msi') {
                Write-CleanLog "Copying $($item.FullName)"
                Copy-Item -LiteralPath $item.FullName -Destination $staged -Force
            }
            else {
                Write-CleanLog "BBCLEAN_SOURCE must be a directory, a .zip, or a .msi." -Level WARN
                return $null
            }
            return (Get-Item -LiteralPath $staged)
        }

        # ---- 2. Bluebeam CDN ------------------------------------------------
        # Versions come from the vendor table, newest first, so this never
        # hardcodes a release. HEAD each URL and take the first that answers.
        $versions = @(
            $KnownProducts.Values |
                Where-Object { $_ -match '^Revu (\d+\.\d+\.\d+) x64$' } |
                ForEach-Object { [version]$Matches[1] } |
                Sort-Object -Descending
        )
        if ($env:BBCLEAN_VERSION) {
            Write-CleanLog "BBCLEAN_VERSION pins the download to $env:BBCLEAN_VERSION."
            $versions = @([version]$env:BBCLEAN_VERSION)
        }

        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $previousProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'   # progress rendering cripples a 2.5 GB download
        try {
            foreach ($version in $versions) {
                $text = '{0}.{1}.{2}' -f $version.Major, $version.Minor, $version.Build
                $url = "https://downloads.bluebeam.com/software/downloads/$text/MSIBluebeamRevu${text}x64.zip"
                try {
                    $head = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 60
                }
                catch { continue }
                if ($head.StatusCode -ne 200) { continue }

                $expected = [int64]$head.Headers['Content-Length']
                $sizeGb = [math]::Round($expected / 1GB, 2)
                Write-CleanLog "Revu $text is available from Bluebeam ($sizeGb GB). Downloading." -Level ACTION
                Write-CleanLog 'For more than one machine, stage this once on a share and set BBCLEAN_SOURCE instead.'

                $versionRoot = Join-Path $PackageRoot $text
                New-Item -Path $versionRoot -ItemType Directory -Force | Out-Null
                $zipPath = Join-Path $versionRoot "MSIBluebeamRevu${text}x64.zip"
                $partial = "$zipPath.partial"
                Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue

                Invoke-WebRequest -Uri $url -OutFile $partial -UseBasicParsing -TimeoutSec 7200
                $actual = (Get-Item -LiteralPath $partial).Length
                if ($actual -ne $expected) {
                    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
                    Write-CleanLog "Download truncated: got $actual bytes, expected $expected." -Level WARN
                    return $null
                }
                Move-Item -LiteralPath $partial -Destination $zipPath -Force

                $staged = Join-Path $versionRoot $msiName
                Write-CleanLog "Extracting $msiName" -Level ACTION
                Expand-RevuMsiFromZip -ZipPath $zipPath -Destination $staged
                return (Get-Item -LiteralPath $staged)
            }
        }
        finally { $ProgressPreference = $previousProgress }

        Write-CleanLog 'No Revu 21 package could be reached at Bluebeam.' -Level WARN
        return $null
    }

    function Test-ProductRegistered {
        param([Parameter(Mandatory)] [string]$Packed)
        $userDataRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData'
        foreach ($sidKey in Get-ChildItem -Path $userDataRoot -ErrorAction SilentlyContinue) {
            $productPath = Join-Path (Join-Path $sidKey.PSPath 'Products') $Packed
            if (-not (Test-Path -LiteralPath $productPath)) { continue }
            $properties = Get-ItemProperty -Path (Join-Path $productPath 'InstallProperties') -ErrorAction SilentlyContinue
            # A registration with no InstallProperties is bookkeeping, not a product.
            if ($properties -and $properties.LocalPackage) { return $true }
        }
        return $false
    }

    function Backup-RegistryKey {
        param(
            [Parameter(Mandatory)] [string]$RegPath,
            [Parameter(Mandatory)] [string]$Label
        )
        New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null
        $file = Join-Path $backupRoot "$Label.reg"
        $result = & "$env:SystemRoot\System32\reg.exe" export $RegPath $file /y 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Backup of $RegPath failed: $result"
        }
        Write-CleanLog "Backed up $RegPath -> $file"
    }

    Write-CleanLog "Bluebeam orphan cleanup started on $env:COMPUTERNAME."
    Write-CleanLog $(if ($apply) { 'MODE: APPLY - changes WILL be written.' } else { 'MODE: DRY RUN - no changes. Set $env:BBCLEAN_APPLY=''1'' to apply.' }) -Level $(if ($apply) { 'ACTION' } else { 'INFO' })

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Must run as Administrator or SYSTEM.'
    }

    # ---- Discover orphans -------------------------------------------------
    $orphans = New-Object Collections.Generic.List[object]
    foreach ($guid in $knownProducts.Keys) {
        $packed = ConvertTo-PackedGuid -Guid $guid
        if (-not $packed) { throw "Internal error packing $guid." }
        if (Test-ProductRegistered -Packed $packed) { continue }

        $traces = New-Object Collections.Generic.List[object]
        foreach ($hive in @('Products', 'Features')) {
            $path = "HKLM:\SOFTWARE\Classes\Installer\$hive\$packed"
            if (Test-Path -LiteralPath $path) {
                $traces.Add([pscustomobject]@{ Kind = 'Key'; Path = $path; Value = $null })
            }
        }
        foreach ($upgradeKey in Get-ChildItem -Path 'HKLM:\SOFTWARE\Classes\Installer\UpgradeCodes' -ErrorAction SilentlyContinue) {
            $item = Get-Item -Path $upgradeKey.PSPath -ErrorAction SilentlyContinue
            if ($item -and ($item.GetValueNames() -contains $packed)) {
                $traces.Add([pscustomobject]@{
                    Kind  = 'Value'
                    Path  = "HKLM:\SOFTWARE\Classes\Installer\UpgradeCodes\$($upgradeKey.PSChildName)"
                    Value = $packed
                })
            }
        }
        $uninstallPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$guid"
        if (Test-Path -LiteralPath $uninstallPath) {
            $traces.Add([pscustomobject]@{ Kind = 'Key'; Path = $uninstallPath; Value = $null })
        }
        $userDataRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData'
        foreach ($sidKey in Get-ChildItem -Path $userDataRoot -ErrorAction SilentlyContinue) {
            $productPath = Join-Path (Join-Path $sidKey.PSPath 'Products') $packed
            if (Test-Path -LiteralPath $productPath) {
                $traces.Add([pscustomobject]@{ Kind = 'Key'; Path = $productPath.Replace('Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE', 'HKLM:'); Value = $null })
            }
        }

        if ($traces.Count -gt 0) {
            $orphans.Add([pscustomobject]@{
                ProductCode = $guid
                Packed      = $packed
                Build       = $knownProducts[$guid]
                Traces      = $traces
            })
        }
    }

    if ($orphans.Count -eq 0) {
        Write-CleanLog 'No orphaned Revu 21 registrations found. Nothing to clean.'
        Write-CleanLog 'If Revu still will not install, the cause is outside the scope of this script. Send BluebeamDiag.log.'
        return
    }

    foreach ($orphan in $orphans) {
        Write-CleanLog "ORPHAN: $($orphan.Build)  $($orphan.ProductCode)"
        foreach ($trace in $orphan.Traces) {
            $description = if ($trace.Kind -eq 'Value') { "$($trace.Path)  [value: $($trace.Value)]" } else { $trace.Path }
            Write-CleanLog "    $($trace.Kind): $description"
        }
    }

    if (-not $apply) {
        Write-CleanLog ''
        Write-CleanLog "DRY RUN complete. $($orphans.Count) orphan(s) would be cleared."
        Write-CleanLog 'Re-run with:  $env:BBCLEAN_APPLY=''1''; irm <url> | iex'
        return
    }

    # ---- Remove ------------------------------------------------------------
    foreach ($orphan in $orphans) {
        Write-CleanLog "Clearing $($orphan.Build) ($($orphan.ProductCode))" -Level ACTION
        $index = 0
        foreach ($trace in $orphan.Traces) {
            $index++
            $label = '{0}-{1:D2}' -f ($orphan.ProductCode -replace '[{}]', ''), $index
            $regPath = $trace.Path -replace '^HKLM:\\', 'HKLM\'
            Backup-RegistryKey -RegPath $regPath -Label $label

            if ($trace.Kind -eq 'Value') {
                Remove-ItemProperty -LiteralPath $trace.Path -Name $trace.Value -Force
                Write-CleanLog "Removed value $($trace.Value) from $($trace.Path)" -Level ACTION
                $remaining = @((Get-Item -LiteralPath $trace.Path).GetValueNames() | Where-Object { $_ })
                if ($remaining.Count -eq 0) {
                    Remove-Item -LiteralPath $trace.Path -Force
                    Write-CleanLog "Removed now-empty UpgradeCode key $($trace.Path)" -Level ACTION
                }
            }
            else {
                Remove-Item -LiteralPath $trace.Path -Recurse -Force
                Write-CleanLog "Removed key $($trace.Path)" -Level ACTION
            }
        }
    }

    Write-CleanLog "Registry backups written to $backupRoot"

    # ---- Verify ------------------------------------------------------------
    foreach ($orphan in $orphans) {
        foreach ($trace in $orphan.Traces) {
            if ($trace.Kind -eq 'Value') {
                if (Test-Path -LiteralPath $trace.Path) {
                    $item = Get-Item -LiteralPath $trace.Path
                    if ($item.GetValueNames() -contains $trace.Value) {
                        throw "Verification failed: value $($trace.Value) still present at $($trace.Path)."
                    }
                }
            }
            elseif (Test-Path -LiteralPath $trace.Path) {
                throw "Verification failed: key still present at $($trace.Path)."
            }
        }
    }
    Write-CleanLog 'Verified: all targeted residue is gone.'

    # ---- Bluebeam OCR is a separate product and must survive ----------------
    # Different ProductCode, different UpgradeCode, its own ARP entry. It is not
    # in $knownProducts so it was never a deletion candidate, but say so out
    # loud: an operator reading this log needs to see OCR was left alone.
    $ocrProducts = @('{93315BA6-A757-4D3D-84BE-4F2C244A4464}',
                     '{57FC1FE0-868F-4C64-8414-25A8ACBF8847}',
                     '{4A394C24-3C6F-4ADE-9694-1D771C564DBD}')
    $ocrInstalled = Get-ItemProperty -Path @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        ) -ErrorAction SilentlyContinue |
        Where-Object { $ocrProducts -contains $_.PSChildName } |
        Select-Object -First 1
    if ($ocrInstalled) {
        Write-CleanLog "Bluebeam OCR $($ocrInstalled.DisplayVersion) is installed and was not touched. It persists across Revu point releases and does not need reinstalling."
    }
    else {
        Write-CleanLog 'Bluebeam OCR is not installed. If this machine needs OCR, AutoMark, Sets or Batch Link, deploy the OCR MSI separately after Revu.' -Level WARN
    }

    # ---- A pending rename will delete the install we are about to make ------
    # Entries like "*1\??\C:\Program Files\Bluebeam Software" with no
    # destination are queued deletions executed at boot. Installing before that
    # reboot means the next boot deletes the fresh install directory. Do not
    # install; make the operator reboot and re-run.
    $pending = @()
    $sessionManager = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    $pfro = (Get-ItemProperty -Path $sessionManager -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($pfro) { $pending = @($pfro | Where-Object { $_ -like '*Bluebeam*' }) }
    if ($pending.Count -gt 0) {
        Write-CleanLog "$($pending.Count) Bluebeam path(s) are queued in PendingFileRenameOperations:" -Level WARN
        foreach ($entry in $pending) { Write-CleanLog "    $entry" -Level WARN }
        Write-CleanLog '' -Level WARN
        Write-CleanLog 'The registry is clean, but installing now is unsafe: these renames run at' -Level WARN
        Write-CleanLog 'boot and would delete the freshly installed files. REBOOT, then re-run' -Level WARN
        Write-CleanLog 'this script with BBCLEAN_APPLY=1 to install.' -Level WARN
        return
    }

    # ---- Pick the install source by reading each MSI, not its folder name ---
    $packageRoot = Join-Path $dataRoot 'cache\bluebeam'
    $candidates = @(Get-ChildItem -Path $packageRoot -Filter 'Bluebeam Revu x64 21.msi' -Recurse -ErrorAction SilentlyContinue)
    Write-CleanLog "Found $($candidates.Count) staged Revu MSI(s) under $packageRoot."

    if ($candidates.Count -eq 0) {
        $acquired = Get-RevuMsi -PackageRoot $packageRoot -KnownProducts $knownProducts
        if ($acquired) { $candidates = @($acquired) }
    }

    $staged = New-Object Collections.Generic.List[object]
    foreach ($candidate in $candidates) {
        try {
            $productVersion = [version](Get-MsiProperty -Path $candidate.FullName -Property ProductVersion)
            $productCode = (Get-MsiProperty -Path $candidate.FullName -Property ProductCode).ToUpperInvariant()
        }
        catch {
            Write-CleanLog "Unreadable MSI skipped ($($candidate.FullName)): $($_.Exception.Message)" -Level WARN
            continue
        }
        $folderVersion = $candidate.FullName -replace '^.*\\cache\\bluebeam\\([^\\]+)\\.*$', '$1'
        if ($folderVersion -ne "$productVersion") {
            Write-CleanLog "Staged path says $folderVersion but the MSI is actually $productVersion; trusting the MSI." -Level WARN
        }
        $staged.Add([pscustomobject]@{
            Path        = $candidate.FullName
            Version     = $productVersion
            ProductCode = $productCode
        })
    }

    $ranked = @($staged | Sort-Object Version -Descending)
    foreach ($item in $ranked) {
        Write-CleanLog "  candidate $($item.Version)  $($item.ProductCode)  $($item.Path)"
    }

    $msi = $ranked | Select-Object -First 1
    if (-not $msi) {
        Write-CleanLog "No Revu MSI could be staged under $packageRoot. The registry is clean; the install is what is missing." -Level WARN
        Write-CleanLog 'Point the script at a source and re-run:' -Level WARN
        Write-CleanLog '  $env:BBCLEAN_SOURCE=''\\server\share\Bluebeam\21.10.0''; $env:BBCLEAN_APPLY=''1''; irm <url> | iex' -Level WARN
        Write-CleanLog 'Or install by hand from a copy of "Bluebeam Revu x64 21.msi":' -Level WARN
        Write-CleanLog '  msiexec /i "<full path to>\Bluebeam Revu x64 21.msi" /qn /norestart BB_AUTO_UPDATE=0 IGNORE_RBT=1 REBOOT=ReallySuppress' -Level WARN
        return
    }
    Write-CleanLog "Selected Revu $($msi.Version) ($($msi.ProductCode))"

    if ($orphans.ProductCode -contains $msi.ProductCode) {
        Write-CleanLog "$($msi.ProductCode) was one of the cleared orphans; installing it fresh."
    }

    $signature = Get-AuthenticodeSignature -FilePath $msi.Path
    if ($signature.Status -ne 'Valid') {
        throw "Staged MSI signature is not valid ($($signature.Status)): $($msi.Path)"
    }

    'Revu', 'Stapler', 'PbMngr5', 'BBPrint' | ForEach-Object {
        Get-Process -Name $_ -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    $installLog = Join-Path $logRoot 'BluebeamClean-Install.log'
    Write-CleanLog "Installing $($msi.Path)" -Level ACTION
    $process = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -Wait -PassThru -NoNewWindow -ArgumentList @(
        '/i', "`"$($msi.Path)`"", '/qn', '/norestart',
        '/l*v', "`"$installLog`"", 'BB_AUTO_UPDATE=0', 'IGNORE_RBT=1', 'REBOOT=ReallySuppress'
    )
    Write-CleanLog "Install completed with exit code $($process.ExitCode)"
    if ($process.ExitCode -notin @(0, 1641, 3010)) {
        $failure = Select-String -Path $installLog -Pattern 'Return value 3' -Context 10, 20 -ErrorAction SilentlyContinue |
            Select-Object -Last 1
        if ($failure) {
            @($failure.Context.PreContext) + @($failure.Line) + @($failure.Context.PostContext) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { Write-CleanLog $_ -Level ERROR }
        }
        throw "Install failed with exit code $($process.ExitCode). Registry backups are in $backupRoot."
    }

    $installed = Get-ItemProperty -Path @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        ) -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'Bluebeam Revu*' -and $_.DisplayVersion -match '^21(?:\.|$)' } |
        Select-Object -First 1
    if (-not $installed) { throw 'Install reported success but Revu is not registered.' }
    Write-CleanLog "SUCCESS: Bluebeam Revu $($installed.DisplayVersion) is installed."
}

try {
    Invoke-BluebeamClean
}
catch {
    Write-Error "Bluebeam cleanup FAILED: $($_.Exception.Message)"
    throw
}
