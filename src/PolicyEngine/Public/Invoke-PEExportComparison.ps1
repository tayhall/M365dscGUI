function Invoke-PEExportComparison
{
    <#
    .SYNOPSIS
    Compares a SOURCE export (what the target should look like, for example PreProd) with a TARGET export (for example Dev), offline.

    .DESCRIPTION
    The source export becomes the blueprint 'source' and the offline tenant 'target' gets a copy of it as its own blueprint; the
    target export is uploaded as that tenant's Full check; Compare-PEState then compares the two. Everything is written under
    -DataRoot (a throwaway folder), never the GUI's data folder. -CompleteWorkload takes workload name prefixes (Data\Workloads.psd1,
    for example AAD, Intune): a type with no records in a complete workload is really empty, so what the source has of it is Missing.
    -WorkloadPrefix keeps only that workload's records of the source. -SourceState passes an already parsed source export, so a caller
    that compares several workloads parses the (large) export once; -TargetState does the same for the target.

    Returns [pscustomobject]@{ Findings; Check; Blueprint; DataRoot; SourceState }. The tools\Invoke-PEPipelineCompare.ps1 tool and the
    HTML drift report both use this, so they agree on what is drift.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param
    (
        [Parameter(Mandatory)]
        [string]$SourceExportPath,

        [Parameter(Mandatory)]
        [string]$TargetExportPath,

        [Parameter(Mandatory)]
        [string]$TargetTenantDomain,

        [Parameter(Mandatory)]
        [string]$DataRoot,

        [string[]]$CompleteWorkload = @(),

        [string]$WorkloadPrefix,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Decision = @(),

        [object]$SourceState,

        [object]$TargetState
    )

    foreach ($path in $SourceExportPath, $TargetExportPath)
    {
        if (-not (Test-Path -LiteralPath (Join-Path $path 'export.ps1'))) { throw "No export.ps1 in $path" }
    }
    $CompleteWorkload = @($CompleteWorkload | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $workloadData = @((Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..\Data\Workloads.psd1')).Workloads)

    if ($null -eq $SourceState)
    {
        $SourceState = New-PEStateFromExport -Path (Resolve-Path -LiteralPath $SourceExportPath).ProviderPath -WarningAction SilentlyContinue
    }
    $targetState = $TargetState
    if ($null -eq $targetState)
    {
        $targetState = New-PEStateFromExport -Path (Resolve-Path -LiteralPath $TargetExportPath).ProviderPath -AllowMissingLog -WarningAction SilentlyContinue
    }

    # The target export as an uploaded snapshot (the same files the pipeline exported; every file must carry the pinned DSC version).
    # -CompleteWorkload of the upload takes workload names and refuses one the upload holds no record of, so the prefixes are mapped
    # to names and only the workloads the target export has records of are passed.
    $files = @(Get-ChildItem -LiteralPath $TargetExportPath -Filter 'export.ps1' | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Text = [IO.File]::ReadAllText($_.FullName) } })
    $present = @($targetState.Records | ForEach-Object { [string]$_.Workload } | Sort-Object -Unique)
    $completeNames = @($workloadData | Where-Object { $CompleteWorkload -contains $_.Prefix -and $present -contains $_.Name } | ForEach-Object { $_.Name })

    New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
    $state = $SourceState
    if ($WorkloadPrefix)
    {
        $workloadName = ($workloadData | Where-Object { $_.Prefix -eq $WorkloadPrefix }).Name
        $state = $SourceState | Select-Object -Property *
        $state.Records = @($SourceState.Records | Where-Object { [string]$_.Workload -eq $workloadName })
        $state.NotChecked = @($SourceState.NotChecked | Where-Object { $null -ne $_ -and [string]$_.ResourceType -like "$WorkloadPrefix*" })
    }
    Initialize-PEBlueprint -Name 'source' -State $state -DataRoot $DataRoot | Out-Null
    Set-PETenant -Slug 'target' -DisplayName 'target' -TenantId $TargetTenantDomain -Offline -DataRoot $DataRoot | Out-Null
    # The tenant's own blueprint is a copy of the source: that is what the generator compares with.
    Initialize-PETenantBlueprint -Slug 'target' -MasterBlueprint 'source' -DataRoot $DataRoot | Out-Null
    $upload = @{ Tenant = 'target'; File = $files; TenantDomain = $TargetTenantDomain; DataRoot = $DataRoot }
    if ($completeNames.Count) { $upload.CompleteWorkload = $completeNames }
    New-PEUploadCheck @upload | Out-Null

    $check = Get-PECheck -Latest -Kind Full -Tenant 'target' -DataRoot $DataRoot
    $blueprint = Get-PEBlueprint -Name 'target' -DataRoot $DataRoot
    $findings = @(Compare-PEState -Blueprint $blueprint -Target $check.State -Decisions @($Decision) -WarningAction SilentlyContinue)
    [pscustomobject]@{ Findings = $findings; Check = $check; Blueprint = $blueprint; DataRoot = $DataRoot; SourceState = $SourceState }
}
