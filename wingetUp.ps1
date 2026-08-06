# wingetUp.ps1
# Upgrades all winget packages silently, with a transcript.
#
# Run elevated. Logs to C:\ProgramData\CKTech\logs\winget.log.
#
# Note on SYSTEM: winget is a per-user MSIX app. Running this as SYSTEM (RMM,
# scheduled task) upgrades machine-scope packages only; user-scope packages are
# invisible to it. That is a winget limitation, not something this script can
# work around.

$LogDir = 'C:\ProgramData\CKTech\logs'
$LogPath = Join-Path $LogDir 'winget.log'

# Under `irm | iex` there is no script file, and `exit` would close the
# operator's session. Only a real -File invocation gets an exit code.
$RanAsFile = [bool]$PSCommandPath

# Start-Transcript does not create missing directories; it throws instead.
New-Item -Path $LogDir -ItemType Directory -Force | Out-Null

Start-Transcript -Path $LogPath -Append
$exitCode = 0

try {
    # Prefer the PATH alias. It resolves in a normal user or admin session and
    # avoids touching WindowsApps at all.
    $wingetPath = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source

    if (-not $wingetPath) {
        # SYSTEM and some service contexts have no winget alias, so fall back to
        # the package directory. One level deep -- a -Recurse over all of
        # WindowsApps walks tens of thousands of ACL-denied files.
        $package = Get-ChildItem -Path 'C:\Program Files\WindowsApps' `
                                 -Directory `
                                 -Filter 'Microsoft.DesktopAppInstaller_*_x64__*' `
                                 -ErrorAction SilentlyContinue |
            ForEach-Object {
                # Microsoft.DesktopAppInstaller_1.22.10731.0_x64__8wekyb3d8bbwe
                $parsed = $null
                if ([version]::TryParse(($_.Name -split '_')[1], [ref]$parsed)) {
                    [pscustomobject]@{ Version = $parsed; Path = $_.FullName }
                }
            } |
            Sort-Object Version -Descending |
            Select-Object -First 1

        # Sorting on the folder name as a string picks 1.9 over 1.22, so the
        # version is parsed and sorted as a [version] instead.
        if ($package) {
            $candidate = Join-Path $package.Path 'winget.exe'
            if (Test-Path -LiteralPath $candidate) { $wingetPath = $candidate }
        }
    }

    if (-not $wingetPath) {
        throw 'winget.exe was not found. Install the App Installer package first.'
    }

    Write-Output "Winget path: $wingetPath"
    & $wingetPath --version

    & $wingetPath source update

    # --accept-package-agreements is required as well as the source agreement,
    # or any package carrying a licence prompt fails.
    & $wingetPath upgrade --all --silent `
        --accept-source-agreements `
        --accept-package-agreements `
        --disable-interactivity | Out-String | Write-Output

    # winget returns 0x8A15002B (-1978335189) when nothing is upgradable.
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        Write-Output "winget exited with code $LASTEXITCODE."
        $exitCode = $LASTEXITCODE
    }
}
catch {
    Write-Output "An error occurred: $($_.Exception.Message)"
    $exitCode = 1
}
finally {
    Stop-Transcript
}

if ($RanAsFile) { exit $exitCode }
