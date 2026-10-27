function Invoke-PEStandardCheck
{
    <#
    .SYNOPSIS
    Compares a tenant's own blueprint with a standard and saves the result as checks\<CheckId>\result.json (Kind 'Standard'). Returns
    CheckId, Findings, Coverage, State, BlueprintName and BlueprintVersion.

    .DESCRIPTION
    A tenant is managed against its blueprint, so the question is whether that blueprint meets the standard. Nothing is read from the
    tenant (no export, no snapshot), which also makes it work for an offline tenant. The blueprint is the tenant's own (the last of its
    list, see Get-PETenantBlueprint); -BlueprintName is the master blueprint, which a tenant with no list of its own follows. Only what
    the standard states is compared (Compare-PEState -Subset). A difference is closed by changing the blueprint (Copy-PEStandardItem
    copies the standard's setting in) and then reverting the tenant to its blueprint as usual.
    Coverage says how much of the standard was compared: Total items in the standard, Covered (stored; the rest are not covered because of
    a placeholder or a property the pinned module does not have), Checked (covered items of types the blueprint has data for) and
    NotReadable (covered items of types the blueprint has no data for: they were not read when it was made). It is kept per workload too.
    A Full check lookup (Get-PECheck -Kind Full) never returns a Standard check.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$StandardName,

        # The master blueprint (as for Invoke-PEFullCheck): the blueprint a tenant with no list of its own follows.
        [Parameter(Mandatory)]
        [string]$BlueprintName,

        [ValidatePattern('^(latest|\d+)$')]
        [string]$Version = 'latest',

        # Which tenant's blueprint to compare (see Get-PETenant); the first tenant is 'master'.
        [ValidatePattern('(?-i)\A[a-z0-9][a-z0-9-]{0,39}\z')]
        [string]$Tenant = 'master',

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

    $own = @(Get-PETenantBlueprint -Tenant $Tenant -MasterBlueprint $BlueprintName -DataRoot $root)[-1]
    Assert-PEBlueprintNotStandard -Name $own -Action 'be compared as a tenant blueprint' -DataRoot $root
    $blueprint = Get-PEBlueprint -Name $own -DataRoot $root
    $blueprintVersion = @(Get-PEBlueprintVersionNumber -Directory (Get-PEBlueprintDirectory -Name $own -DataRoot $root))[-1]

    $checkId = New-PECheckId -Root $root
    $decisions = @(Get-PEStandardDecision -Tenant $Tenant -StandardName $StandardName -DataRoot $root)
    $findings = @(Compare-PEState -Blueprint $standard -Target $blueprint -Decisions $decisions -Subset)

    # Items of types the blueprint has no data for are NotReadable, never Missing.
    $unreadable = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($blueprint.NotChecked))
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
        Total       = $covered + [int](@($notCovered.Values) | Measure-Object -Sum).Sum
        Covered     = $covered
        Checked     = $covered - $notReadable
        NotCovered  = $notCovered
        NotReadable = $notReadable
        ByWorkload  = $byWorkload
    }

    $document = [ordered]@{
        CheckId          = $checkId
        Kind             = 'Standard'
        TenantSlug       = $Tenant
        StandardName     = $StandardName
        StandardVersion  = $standardVersion
        SourceVersion    = $sourceVersion
        BlueprintName    = $own
        BlueprintVersion = $blueprintVersion
        CheckedAt        = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        Coverage         = $coverage
        Findings         = $findings
        State            = $blueprint
    }
    Write-PEJsonNew -Path (Join-Path $root "checks\$checkId\result.json") -InputObject $document

    [pscustomobject]@{
        CheckId          = $checkId
        Findings         = $findings
        Coverage         = $coverage
        State            = $blueprint
        BlueprintName    = $own
        BlueprintVersion = $blueprintVersion
    }
}
