function Invoke-PEStandardCheck
{
    <#
    .SYNOPSIS
    Reads a tenant for the workloads a standard covers, compares it with the standard and saves the result as checks\<CheckId>\result.json
    (Kind 'Standard'). Returns CheckId, Findings, Coverage, State and Path.

    .DESCRIPTION
    Only what the standard states is compared (Compare-PEState -Subset): tenant objects and properties it does not mention are not drift.
    Coverage says how much of the standard this run covered: Total items in the standard, Covered (stored; the rest are not covered because
    of a placeholder or a property the pinned module does not have), Checked (covered items of types the export could read) and
    NotReadable (covered items of types it could not: a failed component, or a workload this tool does not export). It is kept per
    workload too. A Full check lookup (Get-PECheck -Kind Full) never returns a Standard check.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$StandardName,

        [ValidatePattern('^(latest|\d+)$')]
        [string]$Version = 'latest',

        # Which tenant to read (see Get-PETenant); the first tenant is 'master'.
        [ValidatePattern('(?-i)\A[a-z0-9][a-z0-9-]{0,39}\z')]
        [string]$Tenant = 'master',

        [scriptblock]$ExportScript,

        [string]$TargetTenantId,

        [string]$DataRoot
    )

    $root = Get-PEDataRoot -Override $DataRoot
    $info = Get-PEStandardInfo -Name $StandardName -DataRoot $root
    if ($null -eq $info)
    {
        throw "'$StandardName' is not a standard (import one with Import-PEStandard)."
    }
    $standard = Get-PEBlueprint -Name $StandardName -Version $Version -DataRoot $root
    $standardVersion = [int](Get-PEMetaValue -Meta $standard.Meta -Name 'Version')
    if ($standardVersion -eq 0)
    {
        $standardVersion = 1
    }
    $sourceVersion = [string](Get-PEMetaValue -Meta $standard.Meta -Name 'SourceVersion')

    $prefixes = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @($standard.Records | ForEach-Object { [string]$_.Workload } | Sort-Object -Unique))
    {
        foreach ($definition in @(Get-PEWorkloadDefinition | Where-Object { $_.Name -eq $name }))
        {
            $prefixes.Add([string]$definition.Prefix)
        }
    }
    if ($prefixes.Count -eq 0)
    {
        throw "Standard '$StandardName' holds no item of a workload this tool can read."
    }

    $checkId = New-PECheckId -Root $root
    $exported = Get-PETenantExportState -Blueprint $standard -Workloads @($prefixes) -CheckId $checkId -Tenant $Tenant -Root $root -ExportScript $ExportScript -TargetTenantId $TargetTenantId
    $state = $exported.State
    # A risk accepted against another standard does not apply here.
    $decisions = @(Get-PEDecision -DataRoot $root -Tenant $Tenant | Where-Object { $_.Kind -ne 'RiskAccepted' -or [string]$_.Standard -ceq $StandardName })
    $findings = @(Compare-PEState -Blueprint $standard -Target $state -Decisions $decisions -Subset)

    # Coverage of this run: items of types the export could not read are NotReadable, never Missing.
    $unreadable = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($state.NotChecked))
    {
        [void]$unreadable.Add([string]$entry.ResourceType)
    }
    $byWorkload = [ordered]@{}
    $covered = 0
    $notReadable = 0
    foreach ($record in @($standard.Records))
    {
        $workload = [string]$record.Workload
        if (-not $byWorkload.Contains($workload))
        {
            $byWorkload[$workload] = [ordered]@{ Total = 0; Covered = 0; Checked = 0 }
        }
        $byWorkload[$workload].Total++
        $byWorkload[$workload].Covered++
        $covered++
        if ($unreadable.Contains([string]$record.ResourceType))
        {
            $notReadable++
        }
        else
        {
            $byWorkload[$workload].Checked++
        }
    }
    $notCovered = [ordered]@{}
    foreach ($row in @(Get-PEStandardCoverage -Name $StandardName -Version ([string]$standardVersion) -DataRoot $root))
    {
        $workload = [string]$row.Workload
        if (-not $byWorkload.Contains($workload))
        {
            $byWorkload[$workload] = [ordered]@{ Total = 0; Covered = 0; Checked = 0 }
        }
        $byWorkload[$workload].Total++
        $notCovered[[string]$row.Reason] = 1 + [int]$notCovered[[string]$row.Reason]
    }
    $coverage = [ordered]@{
        Total       = $covered + (@($notCovered.Values) | Measure-Object -Sum).Sum
        Covered     = $covered
        Checked     = $covered - $notReadable
        NotCovered  = $notCovered
        NotReadable = $notReadable
        ByWorkload  = $byWorkload
    }

    $document = [ordered]@{
        CheckId         = $checkId
        Kind            = 'Standard'
        TenantSlug      = $Tenant
        StandardName    = $StandardName
        StandardVersion = $standardVersion
        SourceVersion   = $sourceVersion
        Path            = $exported.ExportPath
        LogWarnings     = @($exported.LogWarnings)
        Coverage        = $coverage
        Findings        = $findings
        State           = $state
    }
    Write-PEJsonNew -Path (Join-Path $root "checks\$checkId\result.json") -InputObject $document

    [pscustomobject]@{
        CheckId  = $checkId
        Findings = $findings
        Coverage = $coverage
        State    = $state
        Path     = $exported.ExportPath
    }
}
