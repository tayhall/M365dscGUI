<#
.SYNOPSIS
    Exports a tenant's configuration with Microsoft365DSC using a Reader or Writer app registration.
.DESCRIPTION
    Reads the app details written by New-PETenantApps.ps1 from ~\.m365dsc-policy and authenticates with the
    app's certificate (no interactive sign-in). Exports the chosen workloads, by default Entra ID, Intune, Exchange
    Online and Teams. Output goes to data\exports\<timestamp> in the repo, which is git-ignored because it holds tenant data.
.EXAMPLE
    pwsh -NoProfile -File tools\Export-M365DscTenant.ps1
.EXAMPLE
    pwsh -NoProfile -File tools\Export-M365DscTenant.ps1 -Components AADGroup, TeamsMeetingPolicy
.EXAMPLE
    pwsh -NoProfile -File tools\Export-M365DscTenant.ps1 -Components AADGroup -FiltersPath filters.json
#>
param
(
    [ValidateSet('Reader', 'Writer')]
    [string]$Role = 'Reader',

    # Resource name prefixes that make up each workload. `pwsh -File` passes an array as separate positional arguments,
    # so child processes pass ONE comma-joined string ('AAD,Intune'); it is split below. An array works in-process.
    [string[]]$Workloads = @((Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..\src\PolicyEngine\Data\Workloads.psd1')).Workloads | Where-Object { $_.Default } | ForEach-Object { $_.Prefix }),

    # Overrides -Workloads with an explicit list of DSC resource names.
    [string[]]$Components,

    [string]$OutputPath,

    [string]$FileName = 'export.ps1',

    # JSON file mapping resource name to an OData filter (Export-M365DSCConfiguration -Filters), for delta exports.
    [string]$FiltersPath,

    # Default: the pin in src\PolicyEngine\Data\Versions.psd1 (shared with the PolicyEngine module).
    [string]$ModuleVersion,

    # Which tenant's app to use (see tools\PEAppPath.ps1); the first tenant is 'master'.
    [ValidatePattern('(?-i)\A[a-z0-9][a-z0-9-]{0,39}\z')]
    [string]$Tenant = 'master'
)

# Must stay the FIRST statement after the param block: tests run the param block and this statement offline.
$Workloads = @($Workloads | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
# Same for -Components: a child process gets ONE comma-joined string (see Invoke-PEScopeCheck).
$Components = @($Components | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$ErrorActionPreference = 'Stop'
if (-not $ModuleVersion)
{
    $ModuleVersion = (Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..\src\PolicyEngine\Data\Versions.psd1')).Microsoft365DSC
}
Import-Module Microsoft365DSC -RequiredVersion $ModuleVersion -WarningAction SilentlyContinue

. (Join-Path $PSScriptRoot 'PEAppPath.ps1')
$appInfoPath = Get-PEAppInfoPath -Role $Role -Tenant $Tenant
if (-not (Test-Path $appInfoPath))
{
    throw "App details not found at $appInfoPath. Run tools\New-PETenantApps.ps1 first."
}
$app = Get-Content $appInfoPath -Raw | ConvertFrom-Json

if (-not $Components)
{
    $resourceList = Get-Content (Join-Path (Get-Module Microsoft365DSC).ModuleBase 'ResourcePermissions.json') -Raw | ConvertFrom-Json
    $pattern = '^(' + ($Workloads -join '|') + ')'
    $Components = @($resourceList.PSObject.Properties.Name | Where-Object { $_ -match $pattern })
}
"Exporting $($Components.Count) components as $Role"

if (-not $OutputPath)
{
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $OutputPath = Join-Path $repoRoot ('data\exports\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

# The console output (progress and per-component errors) is also written to export.log next to the export. The check
# reads it to tell failed components from empty ones. Not Start-Transcript: that adds headers and breaks line parsing.
Import-Module (Join-Path $PSScriptRoot '..\src\PolicyEngine\PolicyEngine.psd1') -Force -WarningAction SilentlyContinue
# Microsoft365DSC reads every component of one export in one process, and the workloads marked OwnProcess in
# Data\Workloads.psd1 (Security and Compliance) cannot share it with the others: after an Entra or Intune component their
# connection fails, and before a Teams component Teams fails to load. Those components are exported by a second process of
# this tool (below) and merged into this export. When only such components are asked for, nothing is split.
$split = & (Get-Module PolicyEngine) { param ($c) Split-PEExportComponent -Component $c } $Components
$partComponents = @()
if (@($split.Isolated).Count -gt 0 -and @($split.Main).Count -gt 0)
{
    $partComponents = @($split.Isolated)
    $Components = @($split.Main)
    "Exporting $($partComponents.Count) component(s) in a process of their own: $($partComponents -join ', ')"
}
$exportArguments = @{
    Components            = $Components
    ApplicationId         = $app.ApplicationId
    TenantId              = $app.TenantId
    CertificateThumbprint = $app.Thumbprint
    Path                  = $OutputPath
    FileName              = $FileName
}
if ($FiltersPath)
{
    $exportArguments.Filters = Get-Content -LiteralPath $FiltersPath -Raw | ConvertFrom-Json -AsHashtable
    "Filters: $(($exportArguments.Filters.GetEnumerator() | ForEach-Object { '{0} = {1}' -f $_.Key, $_.Value }) -join '; ')"
}
Invoke-PELoggedCommand -LogPath (Join-Path $OutputPath 'export.log') -ScriptBlock {
    Export-M365DSCConfiguration @exportArguments
}

if ($partComponents.Count -gt 0)
{
    $partPath = Join-Path $OutputPath 'part-own-process'
    $partArguments = @('-NoProfile', '-File', $PSCommandPath, '-Role', $Role, '-Components', ($partComponents -join ','), '-OutputPath', $partPath, '-FileName', $FileName, '-ModuleVersion', $ModuleVersion, '-Tenant', $Tenant)
    if ($FiltersPath) { $partArguments += @('-FiltersPath', $FiltersPath) }
    # One failed connect (for example "A task was canceled") makes Microsoft365DSC skip the rest of the workload, so a part
    # that reports failed components is exported once more from scratch; the second result is merged, failed or not.
    foreach ($attempt in 1, 2)
    {
        if ($attempt -eq 2)
        {
            "The export of $($partComponents -join ', ') reported failed components; trying once more."
            $null = & (Get-Module PolicyEngine) { param ($path) Remove-PEExportPart -PartPath $path } $partPath
        }
        & (Get-Process -Id $PID).Path @partArguments | Out-Host
        if ($LASTEXITCODE -ne 0)
        {
            throw "The export of $($partComponents -join ', ') in its own process failed with exit code $LASTEXITCODE."
        }
        if (-not (& (Get-Module PolicyEngine) { param ($path) Test-PEExportPartFailed -PartPath $path } $partPath)) { break }
    }
    & (Get-Module PolicyEngine) { param ($main, $part, $file) Merge-PEExportPart -Path $main -PartPath $part -FileName $file } $OutputPath $partPath $FileName
    $null = & (Get-Module PolicyEngine) { param ($path) Remove-PEExportPart -PartPath $path } $partPath
}

"Output: $OutputPath"
