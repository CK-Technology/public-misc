#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Updates an existing, healthy Bluebeam Revu 21 install to a newer point
    release. Never installs Revu where it is absent.
.DESCRIPTION
    This is an UPDATE-ONLY tool. It refuses to act on any machine that is not
    already in a known-good state, because a Revu 21 upgrade launched against a
    damaged registration is what leaves the 1612 -> 1714 -> 1603 residue that
    bluebeamclean.ps1 exists to remove.

    Before touching anything it requires ALL of:

      * exactly one Revu 21 ProductCode from the vendor table registered
      * that ProductCode present in BOTH Add/Remove Programs and the Windows
        Installer UserData hive, with matching versions
      * a cached LocalPackage MSI that exists on disk AND whose ProductCode
        matches the registration -- without this, RemoveExistingProducts cannot
        remove the old build and the upgrade dies at 1612
      * no Bluebeam entries in PendingFileRenameOperations (a reboot is owed)
      * no leftover .rbs rollback scripts
      * no Group Policy advertisement naming a Revu 21 ProductCode
      * Revu not currently running

    Anything else: it logs the reason, changes nothing, and exits.

    NOT MANAGED, BY DESIGN:
      * Revu 20 and older. The shop runs 20.2 unlicensed with no portal sign-in.
        No Revu 20 ProductCode appears in this script and no code path installs
        Revu where none is registered.
      * Bluebeam OCR 21. Separate product, separate UpgradeCode. Recorded before
        and after the upgrade so its survival is provable, never modified.

    DRY RUN BY DEFAULT. To apply, set BBUPDATE_APPLY=1 first:
        $env:BBUPDATE_APPLY='1'; irm <url> | iex

    Environment:
        BBUPDATE_APPLY=1        perform the upgrade (otherwise report only)
        BBUPDATE_SOURCE=<path>  UNC/local directory, .zip, or .msi to update
                                from. Strongly preferred for fleet work -- the
                                CDN package is 2.5 GB per machine.
        BBUPDATE_VERSION=x.y.z  pin the target release instead of taking newest
        BBUPDATE_FORCE=1        close a running Revu instead of deferring

    Exit codes: 0 updated / already current / not managed
                2 blocked, machine needs remediation first
                1 failure
#>

function Invoke-BluebeamUpdate {
    [CmdletBinding()]
    param()

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    $apply = $env:BBUPDATE_APPLY -eq '1'
    $force = $env:BBUPDATE_FORCE -eq '1'
    $dataRoot = 'C:\ProgramData\CKTech'
    $packageRoot = Join-Path $dataRoot 'cache\bluebeam'
    $logRoot = Join-Path $dataRoot 'logs'
    $logPath = Join-Path $logRoot 'BluebeamUpdate.log'
    New-Item -Path $logRoot -ItemType Directory -Force | Out-Null

    $script:exitCode = 0

    function Write-UpdateLog {
        param(
            [string]$Message = '',
            [ValidateSet('INFO', 'WARN', 'ERROR', 'ACTION')] [string]$Level = 'INFO'
        )
        $entry = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Write-Host $entry
        Add-Content -Path $logPath -Value $entry -Encoding UTF8
    }

    function ConvertTo-PackedGuid {
        param([Parameter(Mandatory)] [string]$Guid)
        $hex = ($Guid -replace '[{}\-]', '').ToUpperInvariant()
        if ($hex -notmatch '^[0-9A-F]{32}$') { return $null }
        $swap = {
            param([string]$Text)
            $builder = New-Object Text.StringBuilder
            for ($index = 0; $index -lt $Text.Length; $index += 2) {
                [void]$builder.Append($Text[$index + 1]).Append($Text[$index])
            }
            $builder.ToString()
        }
        return (-join $hex[7..0]) + (-join $hex[11..8]) + (-join $hex[15..12]) +
               (& $swap $hex.Substring(16, 4)) + (& $swap $hex.Substring(20, 12))
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

    # Complete Revu 21 line, verbatim from "Uninstall Previous Versions.txt" in
    # MSIBluebeamRevu21.10.0x64.zip. Revu 20 and older begin further down that
    # same vendor file and are deliberately absent here: a ProductCode that is
    # not in this table is never recognised, never updated, never touched.
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

    # Read for reporting only. Never an upgrade target, never removed.
    $ocrProducts = [ordered]@{
        '{93315BA6-A757-4D3D-84BE-4F2C244A4464}' = 'Bluebeam OCR 21.0.30 x64'
        '{57FC1FE0-868F-4C64-8414-25A8ACBF8847}' = 'Bluebeam OCR 21.0.15 x64'
        '{4A394C24-3C6F-4ADE-9694-1D771C564DBD}' = 'Bluebeam OCR 21.0.15 x86'
    }

    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $userDataRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products'
    $msiName = 'Bluebeam Revu x64 21.msi'

    function Get-Registration {
        # Look up one known ProductCode across both places that must agree.
        param([Parameter(Mandatory)] [string]$ProductCode)

        $arp = $null
        foreach ($root in $uninstallRoots) {
            $key = Join-Path $root $ProductCode
            if (Test-Path -LiteralPath $key) {
                $arp = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
                break
            }
        }

        $packed = ConvertTo-PackedGuid -Guid $ProductCode
        $installProperties = $null
        if ($packed) {
            $key = Join-Path (Join-Path $userDataRoot $packed) 'InstallProperties'
            if (Test-Path -LiteralPath $key) {
                $installProperties = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
            }
        }

        if (-not $arp -and -not $installProperties) { return $null }

        [pscustomobject]@{
            ProductCode      = $ProductCode
            Packed           = $packed
            ArpVersion       = if ($arp) { [string]$arp.DisplayVersion } else { $null }
            UserDataVersion  = if ($installProperties) { [string]$installProperties.DisplayVersion } else { $null }
            LocalPackage     = if ($installProperties) { [string]$installProperties.LocalPackage } else { $null }
        }
    }

    function Get-GroupPolicyAdvertisements {
        # A GPO-assigned package registers in the Classes installer hive without
        # any UserData counterpart -- indistinguishable from upgrade residue,
        # and it comes straight back after any cleanup while the policy is
        # still linked. Refuse to update a machine that has one.
        $appMgmt = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\AppMgmt'
        $dump = @(& "$env:SystemRoot\System32\reg.exe" query $appMgmt /s 2>$null)
        if ($dump.Count -eq 0) { return @() }
        $text = ($dump -join "`n").ToUpperInvariant()

        $hits = New-Object Collections.Generic.List[string]
        foreach ($guid in $knownProducts.Keys) {
            $packed = ConvertTo-PackedGuid -Guid $guid
            if ($text -match [regex]::Escape($guid.ToUpperInvariant()) -or
                ($packed -and $text -match [regex]::Escape($packed))) {
                $hits.Add("$guid ($($knownProducts[$guid]))")
            }
        }
        return $hits.ToArray()
    }

    function Get-BlockingConditions {
        param([Parameter(Mandatory)] [AllowNull()] [object]$Product)

        $blocks = New-Object Collections.Generic.List[string]

        if (-not $Product.ArpVersion) {
            $blocks.Add('Registered in the Windows Installer hive but absent from Add/Remove Programs (half-removed). Run bluebeamdiag.ps1, then bluebeamclean.ps1.')
        }
        if (-not $Product.UserDataVersion) {
            $blocks.Add('Present in Add/Remove Programs but has no Windows Installer product data. Run bluebeamdiag.ps1, then bluebeamclean.ps1.')
        }
        if ($Product.ArpVersion -and $Product.UserDataVersion -and
            $Product.ArpVersion -ne $Product.UserDataVersion) {
            $blocks.Add("Version mismatch: Add/Remove Programs says $($Product.ArpVersion), Windows Installer says $($Product.UserDataVersion).")
        }

        # The single most important precondition. RemoveExistingProducts needs
        # this exact package to uninstall the outgoing build; without it the
        # upgrade fails 1612 and aborts the transaction with 1714.
        if (-not $Product.LocalPackage) {
            $blocks.Add('No LocalPackage recorded. Windows Installer has no cached MSI for this product and cannot service or remove it.')
        }
        elseif (-not (Test-Path -LiteralPath $Product.LocalPackage)) {
            $blocks.Add("Cached MSI is missing from disk: $($Product.LocalPackage). Windows Installer cannot remove the outgoing build.")
        }
        else {
            try {
                $cachedCode = (Get-MsiProperty -Path $Product.LocalPackage -Property ProductCode).ToUpperInvariant()
                if ($cachedCode -ne $Product.ProductCode.ToUpperInvariant()) {
                    $blocks.Add("Cached MSI $($Product.LocalPackage) is ProductCode $cachedCode but the registration is $($Product.ProductCode).")
                }
            }
            catch {
                $blocks.Add("Cached MSI $($Product.LocalPackage) could not be read: $($_.Exception.Message)")
            }
        }

        $sessionManager = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
        $pfro = (Get-ItemProperty -LiteralPath $sessionManager -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
        if ($pfro) {
            $pending = @($pfro | Where-Object { $_ -like '*Bluebeam*' })
            if ($pending.Count -gt 0) {
                $blocks.Add("$($pending.Count) Bluebeam path(s) queued in PendingFileRenameOperations. A reboot is owed; installing now would let the next boot delete the new files.")
            }
        }

        $rollbackKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\Rollback\Scripts'
        if (Test-Path -LiteralPath $rollbackKey) {
            $blocks.Add('Installer\Rollback\Scripts exists. A stale rollback script will undo this upgrade at the end of the transaction.')
        }
        $rbs = @(Get-ChildItem -Path (Join-Path $env:SystemRoot 'Installer') -Filter '*.rbs' -ErrorAction SilentlyContinue)
        if ($rbs.Count -gt 0) {
            $blocks.Add("$($rbs.Count) leftover .rbs rollback script(s) in $env:SystemRoot\Installer.")
        }

        foreach ($advert in Get-GroupPolicyAdvertisements) {
            $blocks.Add("Group Policy still advertises $advert. Unlink the Software Installation policy and reboot, or the advertisement will reappear after any cleanup.")
        }

        $running = @('Revu', 'Stapler', 'PbMngr5', 'BBPrint' |
            ForEach-Object { Get-Process -Name $_ -ErrorAction SilentlyContinue })
        if ($running.Count -gt 0) {
            $names = ($running | Select-Object -ExpandProperty Name -Unique) -join ', '
            if ($force) {
                Write-UpdateLog "BBUPDATE_FORCE is set; these will be closed if the upgrade proceeds: $names" -Level WARN
            }
            else {
                $blocks.Add("Bluebeam is running ($names). Deferring so no unsaved markup is lost. Set BBUPDATE_FORCE=1 to close it.")
            }
        }

        return $blocks.ToArray()
    }

    function Expand-RevuMsiFromZip {
        param([string]$ZipPath, [string]$Destination)
        # Pull only the Revu MSI. The archive also holds the 986 MB OCR MSI and
        # the redistributables, none of which this script installs.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            $entry = $archive.Entries | Where-Object { $_.Name -eq $msiName } | Select-Object -First 1
            if (-not $entry) { throw "No '$msiName' inside $ZipPath." }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $Destination, $true)
        }
        finally { $archive.Dispose() }
    }

    function Get-TargetMsi {
        # BBUPDATE_SOURCE first: a UNC/local directory, .zip, or .msi. Fleet
        # work should always set it -- the CDN package is 2.5 GB per machine.
        # Falls back to the Bluebeam CDN, newest table version that answers.
        $staged = Join-Path $packageRoot "update\$msiName"
        New-Item -Path (Split-Path $staged) -ItemType Directory -Force | Out-Null

        $source = $env:BBUPDATE_SOURCE
        if ($source) {
            Write-UpdateLog "BBUPDATE_SOURCE is set: $source"
            if (-not (Test-Path -LiteralPath $source)) {
                Write-UpdateLog 'BBUPDATE_SOURCE is unreachable from this machine. SYSTEM context cannot use mapped drives; use a UNC path.' -Level WARN
                return $null
            }
            $item = Get-Item -LiteralPath $source
            if ($item.PSIsContainer) {
                # Newest MSI wins; version comes from the package itself, never
                # from a directory name that someone may have mistyped.
                $candidates = @(Get-ChildItem -Path $item.FullName -Filter $msiName -Recurse -ErrorAction SilentlyContinue)
                if ($candidates.Count -eq 0) {
                    Write-UpdateLog "No '$msiName' found under $source." -Level WARN
                    return $null
                }
                $best = $candidates |
                    ForEach-Object {
                        try { [pscustomobject]@{ File = $_; Version = [version](Get-MsiProperty -Path $_.FullName -Property ProductVersion) } }
                        catch { Write-UpdateLog "Skipping unreadable MSI $($_.FullName)" -Level WARN }
                    } |
                    Sort-Object Version -Descending |
                    Select-Object -First 1
                if (-not $best) { return $null }
                Write-UpdateLog "Selected Revu $($best.Version) from $($best.File.FullName)"
                Copy-Item -LiteralPath $best.File.FullName -Destination $staged -Force
            }
            elseif ($item.Extension -eq '.zip') {
                Write-UpdateLog "Extracting $msiName from $($item.FullName)" -Level ACTION
                Expand-RevuMsiFromZip -ZipPath $item.FullName -Destination $staged
            }
            elseif ($item.Extension -eq '.msi') {
                Copy-Item -LiteralPath $item.FullName -Destination $staged -Force
            }
            else {
                Write-UpdateLog 'BBUPDATE_SOURCE must be a directory, a .zip, or a .msi.' -Level WARN
                return $null
            }
            return (Get-Item -LiteralPath $staged)
        }

        $versions = @(
            $knownProducts.Values |
                Where-Object { $_ -match '^Revu (\d+\.\d+\.\d+) x64$' } |
                ForEach-Object { [version]$Matches[1] } |
                Sort-Object -Descending
        )
        if ($env:BBUPDATE_VERSION) {
            Write-UpdateLog "BBUPDATE_VERSION pins the target to $env:BBUPDATE_VERSION."
            $versions = @([version]$env:BBUPDATE_VERSION)
        }

        $systemDrive = Get-PSDrive -Name ($env:SystemDrive).TrimEnd(':')
        if ($systemDrive.Free -lt 10GB) {
            Write-UpdateLog "Only $([math]::Round($systemDrive.Free / 1GB, 1)) GB free; the CDN package needs about 10 GB to download and extract. Set BBUPDATE_SOURCE to a share instead." -Level WARN
            return $null
        }

        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        foreach ($version in $versions) {
            $text = '{0}.{1}.{2}' -f $version.Major, $version.Minor, $version.Build
            $url = "https://downloads.bluebeam.com/software/downloads/$text/MSIBluebeamRevu${text}x64.zip"
            try { $head = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 60 }
            catch { continue }
            if ($head.StatusCode -ne 200) { continue }

            $expected = [int64]$head.Headers['Content-Length']
            Write-UpdateLog "Revu $text available from Bluebeam ($([math]::Round($expected / 1GB, 2)) GB). Downloading." -Level ACTION
            $zipPath = Join-Path $packageRoot "$text\MSIBluebeamRevu${text}x64.zip"
            New-Item -Path (Split-Path $zipPath) -ItemType Directory -Force | Out-Null
            $partial = "$zipPath.partial"
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            Invoke-WebRequest -Uri $url -OutFile $partial -UseBasicParsing -TimeoutSec 7200
            $actual = (Get-Item -LiteralPath $partial).Length
            if ($actual -ne $expected) {
                Write-UpdateLog "Download truncated: expected $expected bytes, got $actual." -Level ERROR
                Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
                return $null
            }
            Move-Item -LiteralPath $partial -Destination $zipPath -Force
            Expand-RevuMsiFromZip -ZipPath $zipPath -Destination $staged
            return (Get-Item -LiteralPath $staged)
        }

        Write-UpdateLog 'No Revu package could be retrieved from Bluebeam.' -Level WARN
        return $null
    }

    function Write-MsiFailureContext {
        param([Parameter(Mandatory)] [string]$MsiLogPath)
        if (-not (Test-Path -LiteralPath $MsiLogPath)) { return }
        $failure = Select-String -Path $MsiLogPath -Pattern 'Return value 3' -Context 15, 25 |
            Select-Object -Last 1
        if (-not $failure) { return }
        Write-UpdateLog "Windows Installer failure context from $MsiLogPath" -Level ERROR
        @($failure.Context.PreContext) + @($failure.Line) + @($failure.Context.PostContext) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { Write-UpdateLog $_ -Level ERROR }
    }

    function Get-OcrState {
        $found = New-Object Collections.Generic.List[string]
        foreach ($guid in $ocrProducts.Keys) {
            $registration = Get-Registration -ProductCode $guid
            if ($registration) {
                $version = if ($registration.ArpVersion) { $registration.ArpVersion } else { $registration.UserDataVersion }
                $found.Add("$($ocrProducts[$guid]) [$version]")
            }
        }
        return $found.ToArray()
    }

    # ------------------------------------------------------------------ start
    Write-UpdateLog ''
    Write-UpdateLog "Bluebeam Revu 21 updater starting on $env:COMPUTERNAME."
    if (-not $apply) {
        Write-UpdateLog 'DRY RUN. Set BBUPDATE_APPLY=1 to perform the upgrade.' -Level WARN
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Updater must run as Administrator or SYSTEM.'
    }

    $registered = @(
        foreach ($guid in $knownProducts.Keys) {
            $registration = Get-Registration -ProductCode $guid
            if ($registration) { $registration }
        }
    )

    if ($registered.Count -eq 0) {
        # Covers bare machines and every Revu 20 shop device. This script has
        # no install path; that is the point.
        Write-UpdateLog 'No Revu 21 registration found. This machine is not managed by this script; nothing to do.'
        Write-UpdateLog 'Revu 20 and older are intentionally out of scope and are never upgraded here.'
        return
    }
    if ($registered.Count -gt 1) {
        Write-UpdateLog "Found $($registered.Count) Revu 21 registrations; expected exactly one. Refusing to guess." -Level ERROR
        foreach ($item in $registered) {
            Write-UpdateLog "  $($item.ProductCode)  $($knownProducts[$item.ProductCode])  ARP=$($item.ArpVersion)  UserData=$($item.UserDataVersion)"
        }
        Write-UpdateLog 'Run bluebeamdiag.ps1 and clear the extra registration first.'
        $script:exitCode = 2
        return
    }

    $product = $registered[0]
    Write-UpdateLog "Installed: $($knownProducts[$product.ProductCode]) $($product.ProductCode)"

    $ocrBefore = Get-OcrState
    if ($ocrBefore.Count -gt 0) {
        foreach ($entry in $ocrBefore) { Write-UpdateLog "OCR present (will not be modified): $entry" }
    }

    $blocks = Get-BlockingConditions -Product $product
    if ($blocks.Count -gt 0) {
        Write-UpdateLog "Machine is not in a safe state to update. $($blocks.Count) blocking condition(s):" -Level ERROR
        foreach ($block in $blocks) { Write-UpdateLog "  - $block" -Level ERROR }
        Write-UpdateLog 'No changes made.'
        $script:exitCode = 2
        return
    }
    Write-UpdateLog 'Preconditions passed: registration consistent, cached MSI valid, no pending reboot, no policy advertisement.'

    $installedVersion = [version]$product.UserDataVersion
    $msi = Get-TargetMsi
    if (-not $msi) {
        Write-UpdateLog 'No update package available. No changes made.' -Level WARN
        return
    }

    $signature = Get-AuthenticodeSignature -FilePath $msi.FullName
    if ($signature.Status -ne 'Valid') {
        throw "Staged MSI signature is not valid: $($signature.Status)."
    }
    $targetVersion = [version](Get-MsiProperty -Path $msi.FullName -Property ProductVersion)
    $targetCode = (Get-MsiProperty -Path $msi.FullName -Property ProductCode).ToUpperInvariant()
    if (-not $knownProducts.Contains($targetCode)) {
        throw "Staged MSI ProductCode $targetCode is not a published Revu 21 release. Refusing to install it."
    }
    Write-UpdateLog "Update package: $($knownProducts[$targetCode]) $targetCode (signed by $($signature.SignerCertificate.Subject.Split(',')[0]))"

    if ($targetVersion -le $installedVersion) {
        Write-UpdateLog "Installed $installedVersion is already at or above the available $targetVersion. Nothing to do."
        return
    }
    Write-UpdateLog "Upgrade path: $installedVersion -> $targetVersion" -Level ACTION

    if (-not $apply) {
        Write-UpdateLog 'DRY RUN complete. This machine would be upgraded. Re-run with BBUPDATE_APPLY=1.' -Level WARN
        return
    }

    if ($force) {
        'Revu', 'Stapler', 'PbMngr5', 'BBPrint' | ForEach-Object {
            Get-Process -Name $_ -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }

    # One transaction. The vendor MSI owns removal of the outgoing build and
    # installation of the new one, so a failure rolls back as a unit. No
    # separate /f repair pass -- the cached-package check above already proved
    # Windows Installer can remove the outgoing build.
    #
    # IGNORE_RBT=1 suppresses Bluebeam's own reboot check. Unrelated pending
    # renames are common and would abort the install; Bluebeam-specific ones
    # are caught by Get-BlockingConditions before reaching this point.
    $upgradeLog = Join-Path $logRoot 'BluebeamUpdate-Install.log'
    Write-UpdateLog "Upgrading. Windows Installer log: $upgradeLog" -Level ACTION
    $process = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -Wait -PassThru -NoNewWindow -ArgumentList @(
        '/i', "`"$($msi.FullName)`"", '/qn', '/norestart',
        '/l*v', "`"$upgradeLog`"", 'BB_AUTO_UPDATE=0', 'IGNORE_RBT=1', 'REBOOT=ReallySuppress'
    )
    Write-UpdateLog "msiexec exit code $($process.ExitCode)"
    if ($process.ExitCode -notin @(0, 1641, 3010)) {
        Write-MsiFailureContext -MsiLogPath $upgradeLog
        throw "Upgrade failed with Windows Installer exit code $($process.ExitCode). Run bluebeamdiag.ps1 before retrying."
    }

    $after = Get-Registration -ProductCode $targetCode
    if (-not $after -or -not $after.UserDataVersion) {
        throw 'Upgrade reported success but the new product is not registered. Run bluebeamdiag.ps1.'
    }
    if ([version]$after.UserDataVersion -lt $targetVersion) {
        throw "Verification failed: expected $targetVersion, found $($after.UserDataVersion)."
    }
    if (-not $after.LocalPackage -or -not (Test-Path -LiteralPath $after.LocalPackage)) {
        Write-UpdateLog 'Upgrade succeeded but no cached MSI was recorded. The next update will be blocked until this is repaired.' -Level WARN
    }

    $ocrAfter = Get-OcrState
    if ($ocrBefore.Count -ne $ocrAfter.Count) {
        Write-UpdateLog "OCR changed across the upgrade: $($ocrBefore.Count) before, $($ocrAfter.Count) after." -Level WARN
    }
    elseif ($ocrAfter.Count -gt 0) {
        Write-UpdateLog "OCR intact after upgrade: $($ocrAfter -join '; ')"
    }

    Write-UpdateLog "SUCCESS: Bluebeam Revu updated to $($after.UserDataVersion)."
    if ($process.ExitCode -in @(1641, 3010)) {
        Write-UpdateLog 'Windows Installer requested a reboot. Schedule one before the next update run.' -Level WARN
    }
}

$script:exitCode = 1

try {
    Invoke-BluebeamUpdate
}
catch {
    Write-Error "Bluebeam update FAILED: $($_.Exception.Message)"
    $script:exitCode = 1
}

# The documented delivery is `irm <url> | iex`, where a bare `exit` would close
# the operator's console. Only hand back a process exit code when this is
# actually running as a file, which is the only case where one gets read.
if ($PSCommandPath) {
    exit $script:exitCode
}
if ($script:exitCode -ne 0) {
    Write-Error "Bluebeam update did not complete (code $script:exitCode)."
}
