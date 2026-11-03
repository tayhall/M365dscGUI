<#
.SYNOPSIS
    Headless drift comparison of two exports (no GUI, no worker): what must change in the target tenant to match the source.
.DESCRIPTION
    Built for pipelines. Takes a SOURCE export (for example PreProd, what the target should look like) and a TARGET export
    (for example Dev) and writes, into -OutputPath:
      drift.json / drift.csv     every finding (Missing, Changed, TargetOnly, PossibleRename, ...) of the target against the source
      Manual.json                items nothing was generated for, each with the reason
      summary.json               counts
      ConfigurationData.psd1     with -Compile: the app values the generated text references
    and the configurations, by -MofLayout:
      Combined (default)   Changes.ps1 and Removals.ps1 (PE_Changes, PE_Removals); with -Compile MOF\Changes and MOF\Removals
      PerWorkload          the same under <Prefix>\ for each workload the source has records of (AAD, Intune, EXO, Teams, ...),
                           in the order of Data\Workloads.psd1; with -Compile <Prefix>\MOF\Changes and <Prefix>\MOF\Removals
    It is a thin wrapper over the PolicyEngine module's own comparison (Compare-PEState) and generator (New-PEOfflineConfig):
    the SOURCE export becomes a blueprint and the TARGET export an uploaded snapshot, in a throwaway data folder under
    -OutputPath\work, so nothing of the GUI's data folder is touched. A per-workload run is the same flow with the blueprint
    holding only that workload's records (nothing is cut out of generated text). Compiling is Microsoft365DSC's
    Invoke-M365DSCConfigurationBuild. Nothing here connects to a tenant and nothing is applied.
.EXAMPLE
    pwsh -NoProfile -File tools\Invoke-PEPipelineCompare.ps1 -SourceExportPath preprod -TargetExportPath dev -TargetTenantDomain contoso-dev.onmicrosoft.com -OutputPath out -MofLayout PerWorkload
#>
param
(
    # Folders holding export.ps1 (as written by tools\Export-M365DscTenant.ps1).
    [Parameter(Mandatory)]
    [string]$SourceExportPath,

    [Parameter(Mandatory)]
    [string]$TargetExportPath,

    # The target tenant's domain, for example contoso-dev.onmicrosoft.com (used to ignore differences that are only the tenant's own name).
    [Parameter(Mandatory)]
    [string]$TargetTenantDomain,

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [ValidateSet('Combined', 'PerWorkload')]
    [string]$MofLayout = 'Combined',

    # Workloads (DSC name prefix, as in Data\Workloads.psd1) whose export in the TARGET is complete: an object type with no records
    # there is then really empty, so what the source has of it is Missing. Without it such a type is NotChecked and nothing is created.
    [string[]]$CompleteWorkload = @('AAD', 'Intune', 'EXO', 'Teams'),

    # Compile the configurations to MOF files with Microsoft365DSC (needs the pinned module installed).
    [switch]$Compile,

    # The TARGET tenant's Writer app, written into the ConfigurationData the generated text references.
    [string]$ApplicationId,
    [string]$CertificateThumbprint,
    [string]$OrganizationName
)

$ErrorActionPreference = 'Stop'
$CompleteWorkload = @($CompleteWorkload | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
Import-Module (Join-Path $PSScriptRoot '..\src\PolicyEngine\PolicyEngine.psd1') -Force -WarningAction SilentlyContinue

New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$OutputPath = (Resolve-Path -LiteralPath $OutputPath).ProviderPath
$work = Join-Path $OutputPath 'work'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Force -Path $work | Out-Null

foreach ($path in $SourceExportPath, $TargetExportPath)
{
    if (-not (Test-Path -LiteralPath (Join-Path $path 'export.ps1'))) { throw "No export.ps1 in $path" }
}

$workloadData = @((Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..\src\PolicyEngine\Data\Workloads.psd1')).Workloads)
$sourceState = New-PEStateFromExport -Path (Resolve-Path -LiteralPath $SourceExportPath).ProviderPath -WarningAction SilentlyContinue
$targetState = New-PEStateFromExport -Path (Resolve-Path -LiteralPath $TargetExportPath).ProviderPath -AllowMissingLog -WarningAction SilentlyContinue

# Which workloads of the target export count as complete (reported here; Invoke-PEExportComparison applies the same rule).
$present = @($targetState.Records | ForEach-Object { [string]$_.Workload } | Sort-Object -Unique)
$completeNames = @($workloadData | Where-Object { $CompleteWorkload -contains $_.Prefix -and $present -contains $_.Name } | ForEach-Object { $_.Name })
"Target workloads with records: $($present -join ', '); treated as complete: $($completeNames -join ', ')"

function Invoke-ComparisonRun
{
    # One flow in its own data folder: the source (all of it, or one workload) becomes the blueprint of the offline tenant 'target',
    # the target export its uploaded check. Returns the findings and what New-PEOfflineConfig generated.
    param ([string]$Name, [string]$WorkloadPrefix)

    $root = Join-Path $work $Name
    $run = Invoke-PEExportComparison -SourceExportPath $SourceExportPath -TargetExportPath $TargetExportPath `
        -TargetTenantDomain $TargetTenantDomain -DataRoot $root -CompleteWorkload $CompleteWorkload -WorkloadPrefix $WorkloadPrefix `
        -SourceState $sourceState -TargetState $targetState -WarningAction SilentlyContinue
    [pscustomobject]@{ Findings = $run.Findings; Config = (New-PEOfflineConfig -Tenant 'target' -DataRoot $root) }
}

function Write-Configuration
{
    param ($Config, [string]$Directory)
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    if ($Config.Changes) { Set-Content -LiteralPath (Join-Path $Directory 'Changes.ps1') -Value $Config.Changes -Encoding utf8 }
    if ($Config.Removals) { Set-Content -LiteralPath (Join-Path $Directory 'Removals.ps1') -Value $Config.Removals -Encoding utf8 }
}

# The full comparison always runs: it is the drift report and the Manual list (including target-only types the source has no records of).
$full = Invoke-ComparisonRun -Name 'full'
$findings = $full.Findings
$findings | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputPath 'drift.json') -Encoding utf8
$findings | Where-Object { $_.Kind -ne 'Excluded' } | ForEach-Object {
    [pscustomobject]@{
        State        = $_.State
        Kind         = $_.Kind
        ResourceType = $_.ResourceType
        Key          = $_.Key
        Properties   = (@($_.Differences | ForEach-Object { $_.Property }) -join '; ')
        Hint         = $_.Hint
    }
} | Export-Csv -LiteralPath (Join-Path $OutputPath 'drift.csv') -NoTypeInformation -Encoding utf8
ConvertTo-Json -InputObject @($full.Config.Manual) -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputPath 'Manual.json') -Encoding utf8

# Where the configurations go: one folder (Combined) or one per workload the source has records of, in the order of Workloads.psd1.
$sets = [System.Collections.Generic.List[object]]::new()
if ($MofLayout -eq 'Combined')
{
    Write-Configuration -Config $full.Config -Directory $OutputPath
    $sets.Add([pscustomobject]@{ Name = 'Combined'; Directory = $OutputPath; Config = $full.Config })
}
else
{
    $sourceWorkloads = @($sourceState.Records | ForEach-Object { [string]$_.Workload } | Sort-Object -Unique)
    foreach ($workload in $workloadData | Where-Object { $sourceWorkloads -contains $_.Name })
    {
        "Comparing workload $($workload.Prefix) ($($workload.Name))"
        $run = Invoke-ComparisonRun -Name $workload.Prefix -WorkloadPrefix $workload.Prefix
        $directory = Join-Path $OutputPath $workload.Prefix
        Write-Configuration -Config $run.Config -Directory $directory
        $sets.Add([pscustomobject]@{ Name = $workload.Prefix; Directory = $directory; Config = $run.Config })
    }
}

$summary = [ordered]@{
    MofLayout     = $MofLayout
    OpenFindings  = @($findings | Where-Object { $_.State -eq 'Open' }).Count
    ByKind        = @($findings | Where-Object { $_.State -eq 'Open' } | Group-Object Kind | ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }) -join ', '
    Manual        = @($full.Config.Manual).Count
    SourceRecords = @($sourceState.Records).Count
    Sets          = @($sets | ForEach-Object { [ordered]@{ Name = $_.Name; Changes = [bool]$_.Config.Changes; Removals = [bool]$_.Config.Removals } })
}
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputPath 'summary.json') -Encoding utf8
$summary.GetEnumerator() | Where-Object { $_.Key -ne 'Sets' } | ForEach-Object { '{0,-16}{1}' -f $_.Key, $_.Value }
foreach ($set in $sets) { '  {0,-10} Changes={1} Removals={2}' -f $set.Name, [bool]$set.Config.Changes, [bool]$set.Config.Removals }

if ($Compile)
{
    if (-not ($ApplicationId -and $CertificateThumbprint -and $OrganizationName))
    {
        throw '-Compile needs -ApplicationId, -CertificateThumbprint and -OrganizationName (the target tenant''s Writer app).'
    }
    $pin = (Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..\src\PolicyEngine\Data\Versions.psd1')).Microsoft365DSC
    Import-Module Microsoft365DSC -RequiredVersion $pin -WarningAction SilentlyContinue
    $dataPath = Join-Path $OutputPath 'ConfigurationData.psd1'
    # The values go into single-quoted strings of a data file that is imported later: one line each, quotes doubled.
    $quote = {
        param ([string]$name, [string]$value)
        if ($value -match '[\r\n]') { throw "$name must be a single line." }
        $value -replace "'", "''"
    }
    $applicationIdText = & $quote 'ApplicationId' $ApplicationId
    $tenantText = & $quote 'TargetTenantDomain' $TargetTenantDomain
    $thumbprintText = & $quote 'CertificateThumbprint' $CertificateThumbprint
    $organizationText = & $quote 'OrganizationName' $OrganizationName
    @"
@{
    AllNodes    = @(@{ NodeName = 'localhost' })
    NonNodeData = @{
        ApplicationId         = '$applicationIdText'
        TenantId              = '$tenantText'
        CertificateThumbprint = '$thumbprintText'
        OrganizationName      = '$organizationText'
    }
}
"@ | Set-Content -LiteralPath $dataPath -Encoding utf8
    foreach ($set in $sets)
    {
        foreach ($kind in 'Changes', 'Removals')
        {
            $script = Join-Path $set.Directory "$kind.ps1"
            if (-not (Test-Path -LiteralPath $script)) { continue }
            $mofPath = Join-Path $set.Directory "MOF\$kind"
            $null = Invoke-M365DSCConfigurationBuild -Path $script -ConfigurationDataPath $dataPath -ConfigurationName "PE_$kind" -OutputPath $mofPath -Engine Standard
            "Compiled $($set.Name) $kind -> $mofPath ($(@(Get-ChildItem -LiteralPath $mofPath -Filter *.mof).Count) MOF)"
        }
    }
}

# The throwaway data folders hold copies of both exports; they are not an output.
Remove-Item -LiteralPath $work -Recurse -Force
