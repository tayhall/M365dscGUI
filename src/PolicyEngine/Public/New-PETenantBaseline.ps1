function New-PETenantBaseline
{
    <#
    .SYNOPSIS
    Makes a replica tenant's own blueprint match what its latest Full check read: a clean slate to compare the tenant with from now on.

    .DESCRIPTION
    Records a new version of the tenant's own blueprint (made, when it has none, as a copy of the master blueprint first) with every
    difference between that blueprint and the latest Full check: new items, changed items and items the tenant no longer has. The
    master blueprint is not touched, so the master layer keeps showing how far the tenant is from the master.

    Left out, so the baseline holds no noise and nothing that needs a decision: items marked Unmanaged for the tenant, possible
    renames, items whose key is not unique, and types the check could not read (their records stay as they were). They are counted
    in the result so they can be settled on the Drift review page.

    Returns $null when the blueprint already matches the check. Otherwise returns Name, Version, CheckId, Added, Changed, Removed,
    Excluded and NeedDecision. The master tenant has no blueprint of its own and is refused.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Slug,

        [Parameter(Mandatory)]
        [string]$MasterBlueprint,

        [string]$DataRoot
    )

    $root = Get-PEDataRoot -Override $DataRoot
    $check = Get-PECheck -Latest -Kind Full -Tenant $Slug -DataRoot $root
    if (-not $PSCmdlet.ShouldProcess("tenant '$Slug'", "Record the tenant as read by check $($check.CheckId) as its blueprint"))
    {
        return $null
    }
    # A copy of the master blueprint first when the tenant has none, so the baseline is one more version on top of it (a replica that
    # already has its own blueprint keeps its history).
    $own = Initialize-PETenantBlueprint -Slug $Slug -MasterBlueprint $MasterBlueprint -DataRoot $root

    $meta = @{}
    foreach ($property in $check.State.Meta.PSObject.Properties) { $meta[$property.Name] = $property.Value }
    $state = New-PEState -Records @($check.State.Records) -NotChecked @($check.State.NotChecked) -Meta $meta

    $unmanaged = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($decision in @(Get-PEDecision -Kind Unmanaged -Tenant $Slug -DataRoot $root)) { [void]$unmanaged.Add(("$($decision.ResourceType)|$($decision.Key)")) }

    $unread = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($check.State.NotChecked)) { if ($null -ne $entry) { [void]$unread.Add([string]$entry.ResourceType) } }

    # Kinds are inverted here (see Get-PEBlueprintChange): Missing = new in the tenant, TargetOnly = gone from the tenant.
    $changes = @(Get-PEBlueprintChange -Name $own -MasterState $state -DataRoot $root)
    $applicable = @($changes | Where-Object { ($_.Kind -in @('Missing', 'TargetOnly', 'Changed')) -and -not $unread.Contains([string]$_.ResourceType) })
    $accept = @($applicable | Where-Object { -not $unmanaged.Contains(("$($_.ResourceType)|$($_.Key)")) })
    $excluded = $applicable.Count - $accept.Count
    $needDecision = @($changes | Where-Object { $_.Kind -in @('PossibleRename', 'Ambiguous') -and -not $unread.Contains([string]$_.ResourceType) }).Count
    if ($accept.Count -eq 0)
    {
        return $null
    }

    $version = Approve-PEBlueprintChange -Name $own -MasterState $state -Accept $accept -Reason "Baseline: tenant '$Slug' as read by check $($check.CheckId)" -DataRoot $root
    [pscustomobject]@{
        Name         = $own
        Version      = $version
        CheckId      = [string]$check.CheckId
        Added        = @($accept | Where-Object Kind -EQ 'Missing').Count
        Changed      = @($accept | Where-Object Kind -EQ 'Changed').Count
        Removed      = @($accept | Where-Object Kind -EQ 'TargetOnly').Count
        Excluded     = $excluded
        NeedDecision = $needDecision
        Items        = @($accept | ForEach-Object { [pscustomobject]@{ ResourceType = [string]$_.ResourceType; Key = [string]$_.Key } })
    }
}
