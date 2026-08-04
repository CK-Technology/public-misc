<#
Behavior tests for the platform-neutral decision logic in deploy-wazuh.ps1.
Windows registry, service, download, and MSI calls are replaced with local mocks.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$deployScript = Join-Path $PSScriptRoot '..\windows\gpo\deploy-wazuh.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $deployScript,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count) {
    throw "Deployment script has $($parseErrors.Count) parse error(s)."
}

$requiredFunctions = @('Assert-Inputs', 'Test-AgentVersion', 'Invoke-Deployment')
foreach ($name in $requiredFunctions) {
    $functionAst = $ast.Find(
        {
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $name
        },
        $true
    )
    if (-not $functionAst) {
        throw "Function not found: $name"
    }
    Invoke-Expression $functionAst.Extent.Text
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

$Manager = 'wazuh.cktechx.com'
$AgentGroup = 'default,CLIENT'
$AgentName = 'TEST-PC'
$Version = '4.14.7-1'
$InstallerUrl = $null
$InstallerPath = $null
$InstallerSha512 = $null
$RegistrationPasswordFile = $null

$script:Scenario = ''
$script:ProductCalls = 0
$script:ManagerCalls = 0
$script:InstallerCalls = 0
$script:MsiCalls = 0
$script:NewEnrollment = $null
$script:StartCalls = 0

function Write-Log { param([string]$Message) }
function Get-WazuhProduct {
    $script:ProductCalls++
    switch ($script:Scenario) {
        'fresh' {
            if ($script:ProductCalls -eq 1) { return $null }
            return [pscustomobject]@{ DisplayVersion = '4.14.7.0' }
        }
        'upgrade' {
            if ($script:ProductCalls -eq 1) {
                return [pscustomobject]@{ DisplayVersion = '4.14.6.0' }
            }
            return [pscustomobject]@{ DisplayVersion = '4.14.7.0' }
        }
        default { return [pscustomobject]@{ DisplayVersion = '4.14.7.0' } }
    }
}
function Get-ConfiguredManager {
    $script:ManagerCalls++
    if ($script:Scenario -eq 'fresh' -and $script:ManagerCalls -eq 1) { return $null }
    if ($script:Scenario -eq 'drift') { return 'old-manager.example.com' }
    if ($script:Scenario -eq 'damaged') { return $null }
    return $Manager
}
function Get-Service {
    param([string]$Name, $ErrorAction)

    if ($script:Scenario -eq 'fresh' -or $script:Scenario -eq 'missing-service') {
        return $null
    }
    if ($script:Scenario -eq 'stopped') {
        return [pscustomobject]@{ Status = 'Stopped' }
    }
    return [pscustomobject]@{ Status = 'Running' }
}
function Get-Installer {
    $script:InstallerCalls++
    return 'C:\mock\wazuh-agent.msi'
}
function Invoke-Msi {
    param([string]$Path, [bool]$NewEnrollment)

    $script:MsiCalls++
    $script:NewEnrollment = $NewEnrollment
}
function Start-AndVerifyService { $script:StartCalls++ }

function Reset-Scenario {
    param([string]$Name)

    $script:Scenario = $Name
    $script:ProductCalls = 0
    $script:ManagerCalls = 0
    $script:InstallerCalls = 0
    $script:MsiCalls = 0
    $script:NewEnrollment = $null
    $script:StartCalls = 0
}

Assert-Equal (Test-AgentVersion '4.14.7.0' '4.14.7-1') $true 'Version core comparison failed.'
Assert-Equal (Test-AgentVersion '4.14.6.0' '4.14.7-1') $false 'Old version was accepted.'

Reset-Scenario 'current'
Assert-Equal (Invoke-Deployment) 0 'Current healthy agent failed.'
Assert-Equal $script:InstallerCalls 0 'Current healthy agent downloaded an installer.'

Reset-Scenario 'stopped'
Assert-Equal (Invoke-Deployment) 0 'Stopped current agent failed.'
Assert-Equal $script:StartCalls 1 'Stopped service was not started.'
Assert-Equal $script:InstallerCalls 0 'Stopped current agent downloaded an installer.'

Reset-Scenario 'drift'
Assert-Equal (Invoke-Deployment) 2 'Manager drift did not fail closed.'
Assert-Equal $script:MsiCalls 0 'Manager drift invoked MSI.'

Reset-Scenario 'damaged'
Assert-Equal (Invoke-Deployment) 2 'Damaged manager configuration did not fail closed.'
Assert-Equal $script:MsiCalls 0 'Damaged manager configuration invoked MSI.'

Reset-Scenario 'upgrade'
Assert-Equal (Invoke-Deployment) 0 'Upgrade path failed.'
Assert-Equal $script:MsiCalls 1 'Upgrade path did not invoke MSI exactly once.'
Assert-Equal $script:NewEnrollment $false 'Upgrade path attempted a new enrollment.'

Reset-Scenario 'fresh'
Assert-Equal (Invoke-Deployment) 0 'Fresh installation path failed.'
Assert-Equal $script:MsiCalls 1 'Fresh path did not invoke MSI exactly once.'
Assert-Equal $script:NewEnrollment $true 'Fresh path omitted enrollment properties.'

Reset-Scenario 'missing-service'
Assert-Equal (Invoke-Deployment) 0 'Missing-service repair path failed.'
Assert-Equal $script:MsiCalls 1 'Missing-service repair did not invoke MSI.'
Assert-Equal $script:NewEnrollment $false 'Missing-service repair attempted re-enrollment.'

Write-Host 'All Windows deployment decision tests passed.'
