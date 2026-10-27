<#
.SYNOPSIS
Seeds a data folder so the Standards pages of the GUI can be tried on real engine data, without a tenant.

.DESCRIPTION
Thin wrapper over the engine commands. It creates a blueprint 'main', imports the small ASD sample in tests\fixtures\asd-mini as version
v1.4.0 of the standard 'asd', runs a standard check of the master tenant against a fake export (a named location that differs and a Teams
policy that is missing), and exports the GUI view models. Nothing talks to a tenant. The folder must not exist yet; remove it yourself to start over.

With -NewVersion it also accepts the named-location risk, imports a changed copy of the sample as v1.5.0 and checks again, so that
accepted risk shows as "Look again".

Then: pwsh -NoProfile -File gui\Start-PEGui.ps1 -DataRoot <DataRoot>\gui   and, in another window,
      pwsh -NoProfile -File tools\Start-PEGuiWorker.ps1 -BlueprintName main -DataRoot <DataRoot>
The worker does Adopt, Accept risk and Remove (local files only). A standard check needs a connected tenant and is not offered here.

.EXAMPLE
pwsh -NoProfile -File tools\PEDemoStandards.ps1 -DataRoot data\demo-standards
#>
[CmdletBinding()]
param
(
    [string]$DataRoot,

    [switch]$NewVersion
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'src\PolicyEngine\PolicyEngine.psd1') -Force -WarningAction SilentlyContinue
$script:Fixture = Join-Path $repo 'tests\fixtures\asd-mini'
. (Join-Path $repo 'tests\StandardTestHelper.ps1')

if (-not $DataRoot)
{
    $DataRoot = Join-Path $repo 'data\demo-standards'
}
if (Test-Path -LiteralPath $DataRoot)
{
    throw "'$DataRoot' already exists. Remove it to start over."
}
New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null
$DataRoot = Convert-Path -LiteralPath $DataRoot
$gui = Join-Path $DataRoot 'gui'

# The master blueprint (empty: the standard is what is being looked at) and the one Full check the GUI export starts from.
$state = & (Get-Module PolicyEngine) { New-PEState -Records @() -NotChecked @() -Meta @{ TenantId = 'demo'; ExportedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') } }
Initialize-PEBlueprint -Name 'main' -State $state -DataRoot $DataRoot | Out-Null
$checks = Join-Path $DataRoot 'checks\20261021-020000'
New-Item -ItemType Directory -Path $checks -Force | Out-Null
[ordered]@{ CheckId = '20261021-020000'; Kind = 'Full'; BlueprintName = 'main'; BlueprintVersion = 1; Findings = @(); State = $state } |
    ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $checks 'result.json') -Encoding utf8

Import-PEStandardRelease -Standard asd -Tag v1.4.0 -Path $script:Fixture -DataRoot $DataRoot -WarningAction SilentlyContinue | Out-Null
$check = {
    $folder = New-TenantExport -Root $DataRoot -Countries '@("AU","NZ")'
    $export = { $folder }.GetNewClosure()
    Invoke-PEStandardCheck -StandardName asd -ExportScript $export -TargetTenantId 'demo-tenant' -DataRoot $DataRoot
}
$result = & $check

if ($NewVersion)
{
    Set-PERiskAcceptance -Standard asd -Tenant master -ResourceType AADNamedLocationPolicy -Key 'Allowed Countries' -ApprovedBy 'J. Citizen' -Reason 'NZ staff' -DataRoot $DataRoot | Out-Null
    $changed = Join-Path $DataRoot 'sources\asd-v1.5.0'
    New-Item -ItemType Directory -Path (Split-Path -Parent $changed) -Force | Out-Null
    Copy-Item -LiteralPath $script:Fixture -Destination $changed -Recurse
    $entra = Join-Path $changed 'Entra.txt'
    (Get-Content -LiteralPath $entra -Raw).Replace('CountriesAndRegions               = @("AU");', 'CountriesAndRegions               = @("AU","FJ");') | Set-Content -LiteralPath $entra -NoNewline
    Import-PEStandardRelease -Standard asd -Tag v1.5.0 -Path $changed -DataRoot $DataRoot -WarningAction SilentlyContinue | Out-Null
    $result = & $check
}

Export-PEGuiData -BlueprintName main -DataRoot $DataRoot -GuiRoot $gui -WarningAction SilentlyContinue | Out-Null
$c = $result.Coverage
"Seeded ${DataRoot}: checked $($c.Checked) of $($c.Total) settings of the sample standard$(if ($NewVersion) { ' (v1.5.0, with an accepted risk to look at again)' } else { ' (v1.4.0)' })."
"  Start the GUI:    pwsh -NoProfile -File gui\Start-PEGui.ps1 -DataRoot `"$gui`""
"  Start the worker: pwsh -NoProfile -File tools\Start-PEGuiWorker.ps1 -BlueprintName main -DataRoot `"$DataRoot`""
