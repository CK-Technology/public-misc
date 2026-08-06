#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Read-only Bluebeam Revu 21 Windows Installer state diagnostic.
.DESCRIPTION
    Reports every trace of Revu 21 across Add/Remove Programs, all Windows
    Installer user contexts, the Classes installer hive, and the filesystem,
    then names the specific residue that blocks reinstall or upgrade.

    This script makes NO changes. It never writes the registry, never calls
    msiexec, and never touches files outside its own log. Run it on a failing
    workstation and send back the log.
#>

function Invoke-BluebeamDiagnostic {
    [CmdletBinding()]
    param()

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    $logRoot = 'C:\ProgramData\CKTech\logs'
    $logPath = Join-Path $logRoot 'BluebeamDiag.log'
    New-Item -Path $logRoot -ItemType Directory -Force | Out-Null
    Set-Content -Path $logPath -Value '' -Encoding UTF8

    function Write-Report {
        param([string]$Message = '')
        Write-Host $Message
        Add-Content -Path $logPath -Value $Message -Encoding UTF8
    }

    function Write-Section {
        param([Parameter(Mandatory)] [string]$Title)
        Write-Report ''
        Write-Report ('=' * 78)
        Write-Report "  $Title"
        Write-Report ('=' * 78)
    }

    # Windows Installer stores GUIDs "packed": the first three fields are
    # reversed and the last two are byte-pair swapped. Both directions are
    # needed to cross-reference the Classes hive against UserData.
    function ConvertFrom-PackedGuid {
        param([Parameter(Mandatory)] [string]$Packed)
        if ($Packed -notmatch '^[0-9A-Fa-f]{32}$') { return $null }
        $tail = for ($index = 16; $index -lt 32; $index += 2) {
            $Packed[$index + 1]
            $Packed[$index]
        }
        $guid = '{{{0}-{1}-{2}-{3}-{4}}}' -f `
            (-join $Packed[7..0]),
            (-join $Packed[11..8]),
            (-join $Packed[15..12]),
            (-join $tail[0..3]),
            (-join $tail[4..15])
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

    # ProductCodes lifted verbatim from the vendor's "Uninstall Previous
    # Versions.txt" shipped inside MSIBluebeamRevu21.10.0x64.zip. This is the
    # complete Revu 21 line - 20 Revu builds plus the 3 OCR 21 builds. Revu 20
    # and older start further down that same file and are deliberately absent:
    # the shop still runs 20.2 unlicensed and nothing here may touch it.
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
        '{93315BA6-A757-4D3D-84BE-4F2C244A4464}' = 'Bluebeam OCR 21.0.30 x64'
        '{57FC1FE0-868F-4C64-8414-25A8ACBF8847}' = 'Bluebeam OCR 21.0.15 x64'
        '{4A394C24-3C6F-4ADE-9694-1D771C564DBD}' = 'Bluebeam OCR 21.0.15 x86'
    }

    $findings = New-Object Collections.Generic.List[string]

    Write-Section 'MACHINE'
    Write-Report "Computer     : $env:COMPUTERNAME"
    Write-Report "Collected    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Report "OS           : $((Get-CimInstance Win32_OperatingSystem).Caption)"
    Write-Report "Running as   : $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Report "Log          : $logPath"

    # ------------------------------------------------------------------
    Write-Section '1. ADD/REMOVE PROGRAMS (both registry nodes)'
    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $arpEntries = foreach ($root in $uninstallRoots) {
        Get-ChildItem -Path $root -ErrorAction SilentlyContinue | ForEach-Object {
            $values = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
            if ($values.DisplayName -like '*Bluebeam*') {
                [pscustomobject]@{
                    Key         = $_.PSChildName
                    DisplayName = [string]$values.DisplayName
                    Version     = [string]$values.DisplayVersion
                    Node        = if ($root -match 'WOW6432') { 'WOW6432Node' } else { 'Native' }
                }
            }
        }
    }
    if ($arpEntries) {
        $arpEntries | ForEach-Object {
            Write-Report ("  {0}  {1}  [{2}]  {3}" -f $_.Key, $_.DisplayName, $_.Version, $_.Node)
        }
    }
    else {
        Write-Report '  (none) - Bluebeam is not registered in Add/Remove Programs.'
        $findings.Add('No ARP registration. Vendor uninstall script will SKIP this machine, because every one of its removals is gated behind a REG QUERY of the Uninstall key.')
    }

    # ------------------------------------------------------------------
    Write-Section '2. WINDOWS INSTALLER PRODUCTS - ALL user contexts'
    Write-Report 'Includes registrations with missing or gutted InstallProperties,'
    Write-Report 'which the recovery script silently skips.'
    Write-Report ''

    $userDataRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData'
    $userDataProducts = New-Object Collections.Generic.List[object]
    foreach ($sidKey in Get-ChildItem -Path $userDataRoot -ErrorAction SilentlyContinue) {
        $productsPath = Join-Path $sidKey.PSPath 'Products'
        foreach ($productKey in Get-ChildItem -Path $productsPath -ErrorAction SilentlyContinue) {
            $properties = Get-ItemProperty -Path (Join-Path $productKey.PSPath 'InstallProperties') `
                -ErrorAction SilentlyContinue
            $productCode = ConvertFrom-PackedGuid -Packed $productKey.PSChildName
            $isKnownRevu = $productCode -and $knownProducts.Contains($productCode)
            $looksBluebeam = $properties -and $properties.DisplayName -like '*Bluebeam*'
            if (-not ($isKnownRevu -or $looksBluebeam)) { continue }

            $localPackage = [string]$properties.LocalPackage
            $userDataProducts.Add([pscustomobject]@{
                Sid              = $sidKey.PSChildName
                ProductCode      = $productCode
                KnownAs          = if ($isKnownRevu) { $knownProducts[$productCode] } else { '' }
                DisplayName      = if ($properties) { [string]$properties.DisplayName } else { '<NO InstallProperties>' }
                DisplayVersion   = if ($properties) { [string]$properties.DisplayVersion } else { '' }
                LocalPackage     = $localPackage
                LocalPackageOk   = if ($localPackage) { Test-Path -LiteralPath $localPackage } else { $false }
                HasInstallProps  = [bool]$properties
            })
        }
    }

    if ($userDataProducts.Count -eq 0) {
        Write-Report '  (none)'
        $findings.Add('Zero Windows Installer product registrations. Revu is not installed as far as Windows Installer is concerned, regardless of what Add/Remove Programs or the filesystem show. Run bluebeamclean.ps1 to clear any residue, then install fresh.')
    }
    foreach ($product in $userDataProducts) {
        Write-Report "  SID            : $($product.Sid)"
        Write-Report "  ProductCode    : $($product.ProductCode)"
        if ($product.KnownAs) { Write-Report "  Vendor build   : $($product.KnownAs)" }
        Write-Report "  DisplayName    : $($product.DisplayName)"
        Write-Report "  DisplayVersion : $($product.DisplayVersion)"
        Write-Report "  LocalPackage   : $($product.LocalPackage)"
        Write-Report "  Cached MSI     : $(if ($product.LocalPackageOk) { 'PRESENT' } else { '*** MISSING ***' })"
        Write-Report ''
        if (-not $product.HasInstallProps) {
            $findings.Add("Product $($product.ProductCode) has NO InstallProperties subkey. Both existing scripts 'continue' past this silently, so they cannot see it.")
        }
        if ($product.LocalPackage -and -not $product.LocalPackageOk) {
            $findings.Add("Cached MSI missing for $($product.ProductCode) (LocalPackage points at $($product.LocalPackage)). This is the direct cause of MSI error 1612, which surfaces to the caller as 1714.")
        }
        if ($product.HasInstallProps -and -not $product.LocalPackage) {
            $findings.Add("Product $($product.ProductCode) has InstallProperties but no LocalPackage value; Windows Installer has no source to service or remove it.")
        }
    }

    # ------------------------------------------------------------------
    Write-Section '3. CLASSES INSTALLER HIVE - Products'
    $classesProducts = @{}
    foreach ($productKey in Get-ChildItem -Path 'Registry::HKEY_CLASSES_ROOT\Installer\Products' -ErrorAction SilentlyContinue) {
        $productCode = ConvertFrom-PackedGuid -Packed $productKey.PSChildName
        if (-not $productCode) { continue }
        $classesProducts[$productCode] = $productKey.PSChildName
        $values = Get-ItemProperty -Path $productKey.PSPath -ErrorAction SilentlyContinue
        $name = [string]$values.ProductName
        if ($knownProducts.Contains($productCode) -or $name -like '*Bluebeam*') {
            Write-Report "  $productCode  $name"
            $hasUserData = $userDataProducts | Where-Object { $_.ProductCode -eq $productCode }
            if (-not $hasUserData) {
                Write-Report '      -> no matching UserData registration  *** ORPHAN ***'
                $findings.Add("ORPHAN: $productCode is registered under HKCR\Installer\Products with no UserData counterpart. Windows Installer still believes this product exists.")
            }
        }
    }

    Write-Report ''
    Write-Report 'Features hive - a separate key under the same ProductCode. Clearing'
    Write-Report 'Products alone leaves this behind.'
    Write-Report ''
    foreach ($featureKey in Get-ChildItem -Path 'Registry::HKEY_CLASSES_ROOT\Installer\Features' -ErrorAction SilentlyContinue) {
        $productCode = ConvertFrom-PackedGuid -Packed $featureKey.PSChildName
        if (-not $productCode) { continue }
        if (-not $knownProducts.Contains($productCode)) { continue }
        $hasUserData = $userDataProducts | Where-Object { $_.ProductCode -eq $productCode }
        $state = if ($hasUserData) { 'installed' } else { '*** ORPHAN ***' }
        Write-Report "  $productCode  $($knownProducts[$productCode])  $state"
        if (-not $hasUserData) {
            $findings.Add("ORPHAN FEATURES KEY: $productCode has a HKCR\Installer\Features key with no product registration. This is separate from the Products key and is missed by any cleanup that only clears Products.")
        }
    }

    # ------------------------------------------------------------------
    Write-Section '4. CLASSES INSTALLER HIVE - UpgradeCodes (dangling references)'
    Write-Report 'A ProductCode listed here with no product data is what makes'
    Write-Report 'RemoveExistingProducts fail during an upgrade.'
    Write-Report ''

    $knownPacked = @{}
    foreach ($guid in $knownProducts.Keys) {
        $packed = ConvertTo-PackedGuid -Guid $guid
        if ($packed) { $knownPacked[$packed] = $guid }
    }

    foreach ($upgradeKey in Get-ChildItem -Path 'Registry::HKEY_CLASSES_ROOT\Installer\UpgradeCodes' -ErrorAction SilentlyContinue) {
        $item = Get-Item -Path $upgradeKey.PSPath -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        $memberNames = @($item.GetValueNames() | Where-Object { $_ })
        $revuMembers = @($memberNames | Where-Object { $knownPacked.ContainsKey($_) })
        if ($revuMembers.Count -eq 0) { continue }

        $upgradeCode = ConvertFrom-PackedGuid -Packed $upgradeKey.PSChildName
        Write-Report "  UpgradeCode : $upgradeCode"
        Write-Report "  Raw key     : HKCR\Installer\UpgradeCodes\$($upgradeKey.PSChildName)"
        foreach ($member in $memberNames) {
            $memberCode = ConvertFrom-PackedGuid -Packed $member
            $label = if ($knownPacked.ContainsKey($member)) { $knownProducts[$knownPacked[$member]] } else { 'unknown product' }
            $live = $userDataProducts | Where-Object { $_.ProductCode -eq $memberCode }
            $state = if ($live) { 'installed' } else { '*** DANGLING - no product data ***' }
            Write-Report "      $memberCode  ($label)  $state"
            if (-not $live) {
                $findings.Add("DANGLING UPGRADECODE MEMBER: $memberCode ($label) is listed under UpgradeCode $upgradeCode but has no product registration. On the next /i, RemoveExistingProducts will try to uninstall it, get 1612, and abort the whole install with 1714.")
            }
        }
        Write-Report ''
    }

    # ------------------------------------------------------------------
    Write-Section '5. KNOWN REVU 21 PRODUCTCODE CROSS-CHECK'
    Write-Report 'Where each vendor-published build leaves traces. Partial rows'
    Write-Report 'mean a half-removed product.'
    Write-Report ''
    Write-Report ('  {0,-40} {1,-24} {2,-4} {3,-8} {4}' -f 'ProductCode', 'Build', 'ARP', 'UserData', 'Classes')
    foreach ($guid in $knownProducts.Keys) {
        $inArp = [bool]($arpEntries | Where-Object { $_.Key -eq $guid })
        $inUserData = [bool]($userDataProducts | Where-Object { $_.ProductCode -eq $guid })
        $inClasses = $classesProducts.ContainsKey($guid)
        if (-not ($inArp -or $inUserData -or $inClasses)) { continue }
        Write-Report ('  {0,-40} {1,-24} {2,-4} {3,-8} {4}' -f `
            $guid, $knownProducts[$guid],
            $(if ($inArp) { 'yes' } else { 'no' }),
            $(if ($inUserData) { 'yes' } else { 'no' }),
            $(if ($inClasses) { 'yes' } else { 'no' }))
        if ($inClasses -and -not $inArp) {
            $findings.Add("HALF-REMOVED: $($knownProducts[$guid]) ($guid) is absent from Add/Remove Programs but still present in the Classes installer hive. Reinstall will keep failing until this is cleared.")
        }
    }

    # ------------------------------------------------------------------
    Write-Section '6. STALE ROLLBACK SCRIPTS AND IN-PROGRESS STATE'
    Write-Report 'At the end of EVERY Windows Installer transaction, a standard action'
    Write-Report 'reads Installer\Rollback\Scripts and executes any .rbs it finds. An'
    Write-Report 'orphaned .rbs left by the failed upgrade will roll back an otherwise'
    Write-Report 'healthy install - which makes every later reinstall attempt fail on a'
    Write-Report 'machine that looks clean. This is fleet-wide, not per-product.'
    Write-Report ''

    $rollbackKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\Rollback\Scripts'
    if (Test-Path -LiteralPath $rollbackKey) {
        $rollbackItem = Get-Item -LiteralPath $rollbackKey
        $rollbackNames = @($rollbackItem.GetValueNames())
        if ($rollbackNames.Count -eq 0) {
            Write-Report '  Rollback\Scripts exists but is empty.'
        }
        foreach ($name in $rollbackNames) {
            $value = $rollbackItem.GetValue($name)
            Write-Report "  Value : $name"
            Write-Report "  Data  : $value"
            $findings.Add("STALE ROLLBACK SCRIPT: $rollbackKey has value '$name' -> $value. Windows Installer executes this .rbs at the end of every subsequent install, which can roll back a good install and make Revu appear to fail for no reason. Identify its owner with WiLstScr.vbs from the Windows Installer SDK before removing it.")
        }
    }
    else {
        Write-Report '  Rollback\Scripts key not present (good).'
    }

    $rbsFiles = @(Get-ChildItem -LiteralPath "$env:SystemRoot\Installer" -Filter '*.rbs' -ErrorAction SilentlyContinue)
    $rbfFiles = @(Get-ChildItem -LiteralPath "$env:SystemRoot\Installer" -Filter '*.rbf' -ErrorAction SilentlyContinue)
    Write-Report ''
    Write-Report "  Leftover .rbs rollback scripts in $env:SystemRoot\Installer : $($rbsFiles.Count)"
    Write-Report "  Leftover .rbf backup files  in $env:SystemRoot\Installer : $($rbfFiles.Count)"
    $rbsFiles | Select-Object -First 10 | ForEach-Object {
        Write-Report ("    {0:yyyy-MM-dd HH:mm}  {1}" -f $_.LastWriteTime, $_.Name)
    }
    if ($rbsFiles.Count -gt 0) {
        $findings.Add("$($rbsFiles.Count) orphaned .rbs rollback script(s) remain in $env:SystemRoot\Installer, indicating a Windows Installer transaction that never completed or cleaned up.")
    }

    $inProgressKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\InProgress'
    if (Test-Path -LiteralPath $inProgressKey) {
        Write-Report ''
        Write-Report "  InProgress key PRESENT - a Windows Installer transaction is recorded as still running."
        (Get-Item -LiteralPath $inProgressKey).GetValueNames() | ForEach-Object {
            Write-Report "    $_ = $((Get-Item -LiteralPath $inProgressKey).GetValue($_))"
        }
        $findings.Add("Installer\InProgress key is present. Windows Installer believes a transaction is still running, so new installs are refused or hang. This matches the reported 'Bluebeam says it is currently installing and never finishes' behaviour.")
    }

    $pendingRename = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($pendingRename) {
        $bluebeamPending = @($pendingRename | Where-Object { $_ -like '*Bluebeam*' })
        Write-Report ''
        Write-Report "  PendingFileRenameOperations entries: $($pendingRename.Count) (Bluebeam-related: $($bluebeamPending.Count))"
        $bluebeamPending | Select-Object -First 10 | ForEach-Object { Write-Report "    $_" }
        if ($bluebeamPending.Count -gt 0) {
            $findings.Add("Bluebeam files are queued in PendingFileRenameOperations. A reboot is owed before any further install; MSI will keep failing its reboot check until then.")
        }
    }

    # ------------------------------------------------------------------
    Write-Section '7. FILESYSTEM'
    foreach ($path in @(
            'C:\Program Files\Bluebeam Software',
            'C:\Program Files (x86)\Bluebeam Software',
            'C:\ProgramData\Bluebeam Software',
            'C:\Program Files\Common Files\Bluebeam Software',
            'C:\ProgramData\CKTech\cache\bluebeam')) {
        if (Test-Path -LiteralPath $path) {
            $size = (Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
            Write-Report ("  PRESENT  {0}  ({1:N1} MB)" -f $path, ($size / 1MB))
        }
        else {
            Write-Report "  absent   $path"
        }
    }

    $revuExe = 'C:\Program Files\Bluebeam Software\Bluebeam Revu\21\Revu\Revu.exe'
    if (Test-Path -LiteralPath $revuExe) {
        $fileVersion = (Get-Item -LiteralPath $revuExe).VersionInfo.FileVersion
        Write-Report "  Revu.exe file version: $fileVersion"
    }
    else {
        Write-Report '  Revu.exe: NOT PRESENT'
        $findings.Add('Revu.exe is missing from disk. The application binaries were removed; only installer bookkeeping remains.')
    }

    # ------------------------------------------------------------------
    Write-Section '8. RECENT WINDOWS INSTALLER LOGS'
    $ckLogs = 'C:\ProgramData\CKTech\logs'
    if (Test-Path -LiteralPath $ckLogs) {
        Get-ChildItem -LiteralPath $ckLogs -Filter '*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 10 |
            ForEach-Object { Write-Report ("  {0:yyyy-MM-dd HH:mm}  {1,10:N0}  {2}" -f $_.LastWriteTime, $_.Length, $_.Name) }
    }

    foreach ($logFile in @('BluebeamRecovery-Install.log', 'BluebeamUpdate-Install.log', 'BluebeamRecovery-Recache.log', 'BluebeamUpdate-Recache.log')) {
        $candidate = Join-Path $ckLogs $logFile
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        $errorLines = Select-String -Path $candidate -Pattern 'Return value 3|error 1(612|714|605|603)|Couldn''t find local patch|RemoveExistingProducts' -ErrorAction SilentlyContinue |
            Select-Object -Last 12
        if ($errorLines) {
            Write-Report ''
            Write-Report "  --- $logFile ---"
            $errorLines | ForEach-Object { Write-Report "    $($_.Line.Trim())" }
        }
    }

    # ------------------------------------------------------------------
    Write-Section '9. COMPONENT CLIENT REGISTRATIONS'
    Write-Report 'Every installed component key under Classes\Installer\Components'
    Write-Report 'carries one value per owning product, named with that product''s'
    Write-Report 'packed ProductCode. Clearing Products/Features/UpgradeCodes does'
    Write-Report 'not clear these. A component still claiming a removed product as'
    Write-Report 'a client is what makes Windows Installer prompt for that product''s'
    Write-Report 'source MSI ("...is on a network resource that is unavailable").'
    Write-Report ''

    $componentsRoot = 'HKLM\SOFTWARE\Classes\Installer\Components'
    foreach ($guid in $knownProducts.Keys) {
        $packed = ConvertTo-PackedGuid -Guid $guid
        if (-not $packed) { continue }
        # reg.exe searches value names across the whole subtree far faster than
        # enumerating tens of thousands of component keys from PowerShell.
        $hits = @(& "$env:SystemRoot\System32\reg.exe" query $componentsRoot /s /v $packed 2>$null |
            Where-Object { $_ -match '^HKEY_' })
        if ($hits.Count -eq 0) { continue }

        $registered = @($userDataProducts | Where-Object { $_.ProductCode -eq $guid }).Count -gt 0
        $state = if ($registered) { 'installed' } else { '*** STALE ***' }
        Write-Report "  $guid  $($knownProducts[$guid])  $($hits.Count) component(s)  $state"
        foreach ($hit in ($hits | Select-Object -First 15)) { Write-Report "      $($hit.Trim())" }
        if ($hits.Count -gt 15) { Write-Report "      ... and $($hits.Count - 15) more" }
        if (-not $registered) {
            $findings.Add("STALE COMPONENT CLIENTS: $($hits.Count) component key(s) under Classes\Installer\Components still name $guid ($($knownProducts[$guid])) as a client, but that product is not installed. Windows Installer will try to resolve a source for it and prompt for 'Bluebeam Revu x64 21.msi'. This hive is NOT cleared by bluebeamclean.ps1.")
        }
    }

    # ------------------------------------------------------------------
    Write-Section '10. SOURCELIST / LASTUSEDSOURCE'
    Write-Report 'Where Windows Installer thinks the source media lives. This is'
    Write-Report 'what pre-fills the "Use source:" box on a 1706 prompt.'
    Write-Report ''

    foreach ($root in @(
            'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData',
            'HKLM\SOFTWARE\Classes\Installer\Products')) {
        foreach ($valueName in @('LastUsedSource', 'PackageName')) {
            $hits = @(& "$env:SystemRoot\System32\reg.exe" query $root /s /v $valueName 2>$null |
                Where-Object { $_ -match 'Bluebeam|\.msi' })
            foreach ($hit in ($hits | Select-Object -First 20)) { Write-Report "  $($hit.Trim())" }
        }
    }

    # ------------------------------------------------------------------
    Write-Section 'FINDINGS'
    if ($findings.Count -eq 0) {
        Write-Report '  No installer-state problems detected.'
    }
    else {
        $index = 1
        foreach ($finding in ($findings | Select-Object -Unique)) {
            Write-Report "  [$index] $finding"
            Write-Report ''
            $index++
        }
    }

    Write-Section 'NEXT STEP'
    Write-Report '  This script changed nothing. The log is at:'
    Write-Report "      $logPath"
    Write-Report ''
    Write-Report '  If any ORPHAN finding is listed above, run bluebeamclean.ps1 as a'
    Write-Report '  dry run first, confirm the residue it reports matches this log,'
    Write-Report '  then re-run it with BBCLEAN_APPLY=1.'
}

try {
    Invoke-BluebeamDiagnostic
}
catch {
    Write-Error "Bluebeam diagnostic FAILED: $($_.Exception.Message)"
    throw
}
