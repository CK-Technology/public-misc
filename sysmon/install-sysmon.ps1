# sysmon/install-sysmon.ps1
# One-liner entry point for a manual Sysmon install on a single Windows host.
#
#   irm "https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/sysmon/install-sysmon.ps1" | iex
#
# This is a thin wrapper. All of the work is done by sysmon/gpo/deploy-sysmon.ps1,
# which this script downloads and invokes -- there is one reconciler, not two.
#
# The wrapper exists because deploy-sysmon.ps1 cannot be piped into `iex` safely:
# it ends in `exit`, which would close the operator's session; its param() block
# cannot bind arguments through a pipeline, so every switch would silently take
# its default; and #requires -RunAsAdministrator is a script-file directive that
# is not enforced on an expression string.
#
# Wrapped in a function that uses `return`, never `exit`, so it is safe to run
# via `irm | iex`. Configuration is by environment variable, since `iex` has no
# way to pass parameters.
#
#   SYSMON_CONFIG_PATH    local or UNC path to a built configuration
#   SYSMON_CONFIG_URL     absolute HTTPS URL to a configuration
#   SYSMON_CONFIG_SHA256  SHA-256 pin for the above
#   SYSMON_VERSION        expected Sysmon version, e.g. 15.15
#   SYSMON_ALLOW_UPGRADE  set to 1 to authorize an uninstall/reinstall upgrade
#
# With no environment set, it installs the vendored base configuration, which is
# an unmodified sysmon-modular build carrying no environment-specific tuning.

function Invoke-InstallSysmon {
    $DeployUrl = 'https://raw.githubusercontent.com/CK-Technology/public-misc/refs/heads/main/sysmon/gpo/deploy-sysmon.ps1'

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Warning 'Sysmon installs a kernel driver and requires an elevated session. Nothing was done.'
        return
    }

    # A disposable directory, not C:\ProgramData\CKScripts -- a GPO may have staged
    # a commit-pinned copy of the reconciler there, and this must not overwrite it.
    $workingDir = Join-Path $env:TEMP ('sysmon-oneliner-{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -Path $workingDir -ItemType Directory -Force | Out-Null
    $scriptPath = Join-Path $workingDir 'deploy-sysmon.ps1'
    $code = 1

    try {
        Write-Host "Downloading the reconciler from $DeployUrl"
        try {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $DeployUrl -OutFile $scriptPath -UseBasicParsing
        }
        catch {
            Write-Warning "Could not download the reconciler: $($_.Exception.Message)"
            return
        }

        # Saved to disk and invoked with & rather than piped, so #requires is honoured,
        # parameters bind, and the reconciler's `exit` terminates only the child script.
        $arguments = @{}
        if ($env:SYSMON_CONFIG_PATH)   { $arguments['ConfigPath']   = $env:SYSMON_CONFIG_PATH }
        if ($env:SYSMON_CONFIG_URL)    { $arguments['ConfigUrl']    = $env:SYSMON_CONFIG_URL }
        if ($env:SYSMON_CONFIG_SHA256) { $arguments['ConfigSha256'] = $env:SYSMON_CONFIG_SHA256 }
        if ($env:SYSMON_VERSION)       { $arguments['Version']      = $env:SYSMON_VERSION }
        if ($env:SYSMON_ALLOW_UPGRADE -eq '1') { $arguments['AllowBinaryUpgrade'] = $true }

        & $scriptPath @arguments
        $code = $LASTEXITCODE
    }
    finally {
        Remove-Item -LiteralPath $workingDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    switch ($code) {
        0 {
            Write-Host 'Sysmon is installed, running, and on the requested configuration.'
        }
        2 {
            Write-Warning 'Refused: a binary version change was requested and nothing was changed.'
            Write-Warning 'Sysmon has no in-place upgrade. Read the log, then re-run with:'
            Write-Warning '  $env:SYSMON_ALLOW_UPGRADE=''1''; irm <url> | iex'
        }
        default {
            Write-Warning "Deployment failed with exit code $code."
        }
    }
    Write-Host 'Log: C:\ProgramData\CKScripts\sysmon_deploy.log'
}

Invoke-InstallSysmon
