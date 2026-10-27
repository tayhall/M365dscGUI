# Moves between blueprint layers. A move changes only the target blueprint (a new version with a reason, written by the
# same crash-safe writer as Approve-PEBlueprintChange) and never a tenant. The differences are found by the existing
# inverted comparison, with the SOURCE blueprint standing in as the "master state" of Get-PEBlueprintChange:
#   Missing = the source has it, the target does not -> Added in the target
#   TargetOnly = the target has it, the source does not -> Removed from the target
#   Changed = both have it with different properties -> the target takes the source's values

function Get-PEBlueprintMovePreview
{
    <#
    .SYNOPSIS
    What moving items from one blueprint into another would do to the target: one row per item with Op Added, Changed
    or Removed. Without -Item every difference is listed. Throws for an item that is not a difference.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$From,

        [Parameter(Mandatory)]
        [string]$To,

        [object[]]$Item,

        [string]$DataRoot
    )

    $applicable = @{ Missing = 'Added'; TargetOnly = 'Removed'; Changed = 'Changed' }
    $changes = @(Get-PEBlueprintChange -Name $To -MasterState (Get-PEBlueprint -Name $From -DataRoot $DataRoot) -DataRoot $DataRoot |
            Where-Object { $applicable.ContainsKey([string]$_.Kind) -and -not [string]::IsNullOrEmpty([string]$_.Key) })
    $named = @($Item | Where-Object { $null -ne $_ })
    $picked = if ($named.Count -eq 0) { $changes } else
    {
        foreach ($entry in $named)
        {
            $match = @($changes | Where-Object { $_.ResourceType -ieq [string]$entry.ResourceType -and $_.Key -ieq [string]$entry.Key })
            if ($match.Count -ne 1)
            {
                throw "$($entry.ResourceType) '$($entry.Key)' is not a difference between blueprint '$From' and blueprint '$To'."
            }
            $match[0]
        }
    }
    foreach ($finding in @($picked))
    {
        [pscustomobject]@{ ResourceType = [string]$finding.ResourceType; Key = [string]$finding.Key; Kind = [string]$finding.Kind; Op = $applicable[[string]$finding.Kind]; Finding = $finding }
    }
}

function Move-PEBlueprintItem
{
    <#
    .SYNOPSIS
    Moves items from one blueprint into another (promote up, or pull down) as a new version of the target. Returns the new
    version number. No tenant is written to.

    .DESCRIPTION
    -ExpectedVersion is the latest version of the target blueprint the caller reviewed; when the target has moved on, nothing
    is written and the call throws. The check and the write happen under the target blueprint's lock.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param
    (
        [Parameter(Mandatory)]
        [string]$From,

        [Parameter(Mandatory)]
        [string]$To,

        [Parameter(Mandatory)]
        [object[]]$Item,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Reason,

        [Parameter(Mandatory)]
        [int]$ExpectedVersion,

        # The latest version of the source blueprint the caller reviewed; checked when given.
        [int]$ExpectedSourceVersion,

        [string]$DataRoot
    )

    if ($From -eq $To)
    {
        throw 'The source and the target are the same blueprint.'
    }
    $directory = Get-PEBlueprintDirectory -Name $To -DataRoot $DataRoot
    # Stale first: when the target has moved on, its differences are not the ones that were reviewed.
    $seen = @(Get-PEBlueprintVersionNumber -Directory $directory)[-1]
    if ($seen -ne $ExpectedVersion)
    {
        throw "Blueprint '$To' has changed since the review (version $seen, expected $ExpectedVersion). Check again and retry."
    }
    if ($PSBoundParameters.ContainsKey('ExpectedSourceVersion'))
    {
        $source = @(Get-PEBlueprintVersionNumber -Directory (Get-PEBlueprintDirectory -Name $From -DataRoot $DataRoot))[-1]
        if ($source -ne $ExpectedSourceVersion)
        {
            throw "Blueprint '$From' has changed since the review (version $source, expected $ExpectedSourceVersion). Check again and retry."
        }
    }
    $rows = @(Get-PEBlueprintMovePreview -From $From -To $To -Item $Item -DataRoot $DataRoot)
    if ($rows.Count -eq 0)
    {
        throw "Nothing to move from blueprint '$From' into '$To'."
    }
    $lock = Enter-PEBlueprintLock -Directory $directory
    try
    {
        $latest = @(Get-PEBlueprintVersionNumber -Directory $directory)[-1]
        if ($latest -ne $ExpectedVersion)
        {
            throw "Blueprint '$To' has changed since the review (version $latest, expected $ExpectedVersion). Check again and retry."
        }
        return (Write-PEBlueprintVersion -Name $To -MasterState (Get-PEBlueprint -Name $From -DataRoot $DataRoot) -Accepted @($rows | ForEach-Object { $_.Finding }) -Reason $Reason -DataRoot $DataRoot)
    }
    finally
    {
        Exit-PEBlueprintLock -Lock $lock
    }
}
