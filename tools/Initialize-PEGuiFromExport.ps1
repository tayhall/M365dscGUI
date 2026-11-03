<#
.SYNOPSIS
    Sets up the GUI's data from one Microsoft365DSC export folder, so the GUI can start from nothing but that folder.
.DESCRIPTION
    A thin wrapper over the engine commands, in this order: the export becomes a blueprint ('<name>-blueprint', created once and
    never changed by later runs); the tenant is registered as an offline tenant that follows it; the export is uploaded as the
    tenant's latest snapshot; the view-model files the GUI reads are written (Export-PEGuiData). Run again with a newer export of
    the same tenant and it adds that export as a new snapshot, so the GUI then shows what changed against the first export.
    The tenant name is the export folder's name (C:\Blueprints\Dev gives tenant 'dev'). The tenant domain comes from -TenantDomain,
    or from the ConfigurationData.psd1 that Microsoft365DSC writes next to an export (NonNodeData.OrganizationName or TenantId).
    export.log is optional: without it a failed component cannot be told from an empty one, so no component is marked as failed.
.EXAMPLE
    pwsh -NoProfile -File tools\Initialize-PEGuiFromExport.ps1 -ExportPath C:\Blueprints\Dev -TenantDomain contoso-dev.onmicrosoft.com
#>
param
(
    [Parameter(Mandatory)]
    [string]$ExportPath,

    [string]$TenantDomain,

    # Shown in the GUI; default: the export folder's name.
    [string]$DisplayName,

    # The engine's data folder (default: data under the repo).
    [string]$DataRoot,

    # Where the GUI's view-model files go (default: gui under the data folder).
    [string]$GuiRoot
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\PolicyEngine\PolicyEngine.psd1') -Force -WarningAction SilentlyContinue

if (-not (Test-Path -LiteralPath (Join-Path $ExportPath 'export.ps1')))
{
    throw "No export.ps1 in '$ExportPath'. Point -ExportPath at the folder that holds the export."
}
$ExportPath = (Resolve-Path -LiteralPath $ExportPath).ProviderPath

$leaf = Split-Path -Leaf $ExportPath
$slug = (($leaf.ToLowerInvariant() -replace '[^a-z0-9-]+', '-').Trim('-'))
if ($slug.Length -gt 30) { $slug = $slug.Substring(0, 30).Trim('-') }
if (-not $slug -or $slug -eq 'master') { throw "Cannot make a tenant name from the folder name '$leaf'. Rename the folder (letters, digits and hyphens; not 'master')." }
if (-not $DisplayName) { $DisplayName = $leaf }
$blueprintName = "$slug-blueprint"

if (-not $TenantDomain)
{
    $dataFile = Join-Path $ExportPath 'ConfigurationData.psd1'
    if (Test-Path -LiteralPath $dataFile)
    {
        $nonNode = (Import-PowerShellDataFile -Path $dataFile).NonNodeData
        foreach ($name in 'OrganizationName', 'TenantId')
        {
            $candidate = [string]$nonNode[$name]
            if ($candidate -match '\A[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}\z') { $TenantDomain = $candidate; break }
        }
    }
}
if (-not $TenantDomain) { throw "The tenant domain is needed (for example contoso-dev.onmicrosoft.com) and was not found next to the export. Pass -TenantDomain." }

$root = if ($DataRoot) { $DataRoot } else { Join-Path (Split-Path $PSScriptRoot -Parent) 'data' }
$arguments = @{ DataRoot = $root }

# 1. The export becomes the blueprint, once.
$blueprintExists = $true
try { Get-PEBlueprint -Name $blueprintName @arguments | Out-Null }
catch
{
    if ($_.Exception.Message -notlike "Blueprint '$blueprintName' not found under*") { throw }
    $blueprintExists = $false
}
if (-not $blueprintExists)
{
    $state = New-PEStateFromExport -Path $ExportPath -AllowMissingLog -WarningAction SilentlyContinue
    Initialize-PEBlueprint -Name $blueprintName -State $state @arguments | Out-Null
    "Blueprint '$blueprintName' created from $ExportPath ($(@($state.Records).Count) records)."
}
else
{
    "Blueprint '$blueprintName' already exists and is kept as it is."
}

# 2. The tenant follows it, as an offline tenant (nothing connects to it).
Set-PETenant -Slug $slug -DisplayName $DisplayName -TenantId $TenantDomain -Offline @arguments | Out-Null
Initialize-PETenantBlueprint -Slug $slug -MasterBlueprint $blueprintName @arguments | Out-Null

# 3. The export is the tenant's latest snapshot.
$files = @(Get-ChildItem -LiteralPath $ExportPath -Filter 'export.ps1' | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Text = [IO.File]::ReadAllText($_.FullName) } })
New-PEUploadCheck -Tenant $slug -File $files -TenantDomain $TenantDomain @arguments | Out-Null

# 4. The files the GUI reads.
$guiArguments = @{ BlueprintName = $blueprintName; TenantDisplayName = $DisplayName; DataRoot = $root }
if ($GuiRoot) { $guiArguments.GuiRoot = $GuiRoot }
$result = Export-PEGuiData @guiArguments
"GUI data written to $($result.GuiRoot) (tenant '$slug', domain $TenantDomain)."
