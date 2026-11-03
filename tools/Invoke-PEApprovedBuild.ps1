<#
.SYNOPSIS
    Builds the configuration and MOF files for an approved list (approved.json): only the approved items, one MOF per resource type and phase.
.DESCRIPTION
    Built for pipelines (no GUI, no worker). Thin wrapper over the PolicyEngine module: Read-PEApprovedList, Test-PEExportComplete,
    Get-PEExportFingerprint and New-PEApprovedConfig (which uses the engine's own comparison, planner and generator), and
    Microsoft365DSC's Invoke-M365DSCConfigurationBuild to compile. Nothing here connects to a tenant and nothing is applied.

    These checks are on the run as a whole and stop it BEFORE anything is written, with a message that names the cause:
      list's tenant   the list is for the tenant this pipeline applies to (-ExpectedTenant, dev)
      G1 complete     neither export has a failed component, a Graph shortfall line ("Graph reported N items but only M were returned"),
                      or a missing export.log: re-export instead
      G7 pinned       each export's SHA-256 is the one the list names, so the list is applied to what was reviewed
      G8 not too old  the Dev export in the list is not older than -MaxAgeDays (and not dated in the future)
    Writes into -OutputPath: outcomes.json (one row per approved item: Action, ResourceType, Key, Outcome, Reason, ResourceId; Outcome is
    ToApply, NoActionRequired, Skipped or NotGenerated), summary.json (Totals, ByTypeAction, Lines such as "Create 10 AADGroup"),
    NN-<Type>-<Phase>.ps1 for each configuration in apply order (all Changes, then Removals) and, unless -NoCompile, MOF\NN-<Type>-<Phase>\.
.EXAMPLE
    pwsh -NoProfile -File tools\Invoke-PEApprovedBuild.ps1 -ListPath approvals\2026-11-03.json -SourceExportPath preprod -TargetExportPath dev -TargetTenantDomain contoso-dev.onmicrosoft.com -OutputPath out -NoCompile
#>
param
(
    [Parameter(Mandatory)]
    [string]$ListPath,

    # Folders holding export.ps1 and export.log: PreProd (what Dev should look like) and Dev. They must be the exports the list names.
    [Parameter(Mandatory)]
    [string]$SourceExportPath,

    [Parameter(Mandatory)]
    [string]$TargetExportPath,

    [Parameter(Mandatory)]
    [string]$TargetTenantDomain,

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [ValidateRange(1, 365)]
    [int]$MaxAgeDays = 7,

    # The tenant slug the list must carry (the apply pipeline only ever applies to Dev).
    [ValidatePattern('\A[a-z0-9][a-z0-9-]{0,39}\z')]
    [string]$ExpectedTenant = 'dev',

    [string[]]$CompleteWorkload = @('AAD', 'Intune', 'EXO', 'Teams'),

    # Compile with Microsoft365DSC; needs the target tenant's Writer app (as tools\Invoke-PEPipelineCompare.ps1).
    [string]$ApplicationId,
    [string]$CertificateThumbprint,
    [string]$OrganizationName,
    [switch]$NoCompile,

    # For tests: the time the age of the Dev export is measured against.
    [datetime]$Now = [datetime]::UtcNow
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\PolicyEngine\PolicyEngine.psd1') -Force -WarningAction SilentlyContinue

$list = Read-PEApprovedList -Path $ListPath
if ($list.Tenant -cne $ExpectedTenant)
{
    throw "The approved list is for tenant '$($list.Tenant)', but this pipeline applies to '$ExpectedTenant'. Nothing was built."
}

# G1, G7: both exports, before anything else is read or written.
foreach ($side in @(@{ Name = 'PreProd'; Path = $SourceExportPath; Pinned = $list.Source }, @{ Name = 'Dev'; Path = $TargetExportPath; Pinned = $list.Target }))
{
    if (-not (Test-Path -LiteralPath (Join-Path $side.Path 'export.ps1'))) { throw "No export.ps1 in the $($side.Name) export folder $($side.Path)." }
    $check = Test-PEExportComplete -Path $side.Path
    if (-not $check.LogPresent) { throw "The $($side.Name) export has no export.log, so failed components cannot be told from empty ones. Re-export it. Nothing was built." }
    if (@($check.FailedComponents).Count -gt 0) { throw "The $($side.Name) export is not complete: failed components $(@($check.FailedComponents) -join ', '). Re-export it. Nothing was built." }
    if (@($check.Shortfalls).Count -gt 0) { throw "The $($side.Name) export is not complete: $(@($check.Shortfalls) -join ' | '). Re-export it. Nothing was built." }
    $fingerprint = Get-PEExportFingerprint -Path $side.Path
    if ($fingerprint -cne $side.Pinned.Fingerprint)
    {
        throw "The $($side.Name) export in $($side.Path) is not the one the approved list names (run $($side.Pinned.Run)): its fingerprint is $fingerprint, the list has $($side.Pinned.Fingerprint). Nothing was built."
    }
}

# G8: Dev can have changed since it was exported.
$exportedAt = [datetime]::Parse($list.Target.ExportedAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
$ageDays = ($Now.ToUniversalTime() - $exportedAt).TotalDays
if ($ageDays -lt (-5 / 1440))
{
    throw "The Dev export in the approved list (run $($list.Target.Run)) is dated in the future ($($list.Target.ExportedAt)), so its age cannot be trusted. Nothing was built."
}
if ($ageDays -gt $MaxAgeDays)
{
    throw ("The Dev export in the approved list (run $($list.Target.Run)) is {0:n1} days old, older than the maximum of $MaxAgeDays. Dev may have changed since: export it again and approve again. Nothing was built." -f $ageDays)
}

if (-not $NoCompile -and -not ($ApplicationId -and $CertificateThumbprint -and $OrganizationName))
{
    throw 'Compiling needs -ApplicationId, -CertificateThumbprint and -OrganizationName (Dev''s Writer app), or pass -NoCompile.'
}

# The comparison and the generation, in a throwaway folder: the output folder stays empty until everything above has held.
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-approved-' + [guid]::NewGuid().ToString('N'))
try
{
    $built = New-PEApprovedConfig -List $list -SourceExportPath $SourceExportPath -TargetExportPath $TargetExportPath `
        -TargetTenantDomain $TargetTenantDomain -DataRoot $work -CompleteWorkload $CompleteWorkload -WarningAction SilentlyContinue
}
finally
{
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$OutputPath = (Resolve-Path -LiteralPath $OutputPath).ProviderPath
ConvertTo-Json -InputObject @($built.Items) -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputPath 'outcomes.json') -Encoding utf8

$names = @()
$number = 0
foreach ($config in @($built.Configs))
{
    $number++
    $name = '{0:00}-{1}-{2}' -f $number, $config.ResourceType, $config.Phase
    $names += $name
    Set-Content -LiteralPath (Join-Path $OutputPath "$name.ps1") -Value $config.Text -Encoding utf8
}

$lines = @($list.Counts | ForEach-Object { '{0} {1} {2}' -f $_.Action, $_.Count, $_.ResourceType })
$totals = [ordered]@{
    Items            = @($built.Items).Count
    ToApply          = @($built.Items | Where-Object Outcome -EQ 'ToApply').Count
    NoActionRequired = @($built.Items | Where-Object Outcome -EQ 'NoActionRequired').Count
    Skipped          = @($built.Items | Where-Object Outcome -EQ 'Skipped').Count
    NotGenerated     = @($built.Items | Where-Object Outcome -EQ 'NotGenerated').Count
}
[ordered]@{
    List          = (Split-Path $ListPath -Leaf)
    ApprovedBy    = $list.ApprovedBy
    Tenant        = $list.Tenant
    SourceRun     = $list.Source.Run
    TargetRun     = $list.Target.Run
    Totals        = $totals
    ByTypeAction  = @($list.Counts)
    Lines         = $lines
    Configs       = @(for ($i = 0; $i -lt $names.Count; $i++) { [ordered]@{ Name = $names[$i]; ConfigurationName = $built.Configs[$i].ConfigurationName; ItemCount = $built.Configs[$i].ItemCount } })
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputPath 'summary.json') -Encoding utf8

'Approved items:'
$lines | ForEach-Object { "  $_" }
'Outcomes: ToApply {0}, NoActionRequired {1}, Skipped {2}, NotGenerated {3} (of {4} approved items)' -f $totals.ToApply, $totals.NoActionRequired, $totals.Skipped, $totals.NotGenerated, $totals.Items
foreach ($row in @($built.Items | Where-Object { $_.Outcome -in 'Skipped', 'NotGenerated' })) { "  $($row.Outcome): $($row.Action) $($row.ResourceType) '$($row.Key)': $($row.Reason)" }

if (-not $NoCompile -and $names.Count -gt 0)
{
    $pin = (Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..\src\PolicyEngine\Data\Versions.psd1')).Microsoft365DSC
    Import-Module Microsoft365DSC -RequiredVersion $pin -WarningAction SilentlyContinue
    $dataPath = Join-Path $OutputPath 'ConfigurationData.psd1'
    # The values go into single-quoted strings of a data file that is imported later: one line each, quotes doubled.
    $quote = {
        param ([string]$label, [string]$value)
        if ($value -match '[\r\n]') { throw "$label must be a single line." }
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
    for ($i = 0; $i -lt $names.Count; $i++)
    {
        $mofPath = Join-Path $OutputPath "MOF\$($names[$i])"
        $null = Invoke-M365DSCConfigurationBuild -Path (Join-Path $OutputPath "$($names[$i]).ps1") -ConfigurationDataPath $dataPath -ConfigurationName $built.Configs[$i].ConfigurationName -OutputPath $mofPath -Engine Standard
        "Compiled $($names[$i]) -> $mofPath ($(@(Get-ChildItem -LiteralPath $mofPath -Filter *.mof).Count) MOF)"
        # Pre-flight: the apply result is matched to the approved items by the resource ids Microsoft365DSC wrote into the MOF. If they are
        # not the ones expected, stop now (nothing has touched Dev) instead of ending with every item Failed.
        $rows = @($built.Items | Where-Object { $_.Outcome -eq 'ToApply' -and $_.ConfigurationName -eq $built.Configs[$i].ConfigurationName })
        $unknown = @($rows | Where-Object { -not $_.ResourceId })
        if ($unknown.Count -gt 0) { throw "$($names[$i]): the DSC resource id of $($unknown.Count) approved item(s) could not be worked out, so the apply result could not be matched to them. Nothing was applied." }
        $missing = @(Test-PEResourceIdInMof -ExpectedId @($rows.ResourceId) -Path $mofPath)
        if ($missing.Count -gt 0) { throw "$($names[$i]): the compiled MOF does not contain the resource id(s) $($missing -join ', ') that the apply result is matched by. Nothing was applied." }
    }
}
