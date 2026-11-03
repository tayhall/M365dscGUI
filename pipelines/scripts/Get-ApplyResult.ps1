<#
.SYNOPSIS
    Turns what the LCM reported for each configuration into one of the five outcomes of every approved item.
.DESCRIPTION
    Pure (no tenant access): the apply script calls it with the build's outcomes.json rows and what each configuration's LCM run returned.
    Every approved item ends in exactly one outcome, so the counts add up to the number of approved items:
      Applied           a ToApply item whose resource is in the desired state after the apply
      NoActionRequired  Dev already had the approved outcome (decided by the build, kept)
      NotGenerated      the engine refused to generate it (decided by the build, kept)
      Failed            applied but not in the desired state, or its configuration did not run (the DSC error is the reason)
      Skipped           Dev was not in the state the approval expected (decided by the build, kept), or an approved Remove while removals
                        were not included
    In -Mode Test nothing is applied: ToApply items stay ToApply (what an Apply would do).
    The LCM carries on after a failed resource, so this reports each resource on its own: one Failed item never turns another into Failed.
    Returns [pscustomobject]@{ Items; Totals; Complete; Left } where Left are the items that are neither Applied nor NoActionRequired and
    Complete is true when Left is empty (and, in Test mode, when nothing is left to apply).
#>
param
(
    # The rows of the build's outcomes.json: Action, ResourceType, Key, Outcome, Reason, ResourceId, ConfigurationName.
    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [object[]]$Item,

    # One per configuration the LCM was run for: @{ ConfigurationName; Ran; Error; InDesiredState = @(resource id); NotInDesiredState = @(@{ ResourceId; Error }) }.
    [AllowNull()]
    [AllowEmptyCollection()]
    [object[]]$ConfigResult = @(),

    [ValidateSet('Test', 'Apply')]
    [string]$Mode = 'Apply',

    [switch]$IncludeRemovals
)

$configs = @{}
foreach ($c in @($ConfigResult | Where-Object { $null -ne $_ })) { $configs[[string]$c.ConfigurationName] = $c }

$result = foreach ($row in @($Item))
{
    $out = [pscustomobject][ordered]@{
        Action = [string]$row.Action; ResourceType = [string]$row.ResourceType; Key = [string]$row.Key
        Outcome = [string]$row.Outcome; Reason = [string]$row.Reason; ResourceId = $row.ResourceId; ConfigurationName = $row.ConfigurationName
    }
    if ($out.Outcome -eq 'ToApply')
    {
        if ($out.Action -eq 'Remove' -and -not $IncludeRemovals)
        {
            $out.Outcome = 'Skipped'
            $out.Reason = 'removals were not included: tick includeRemovals to apply an approved Remove'
        }
        elseif ($Mode -eq 'Apply')
        {
            $cfg = $configs[[string]$out.ConfigurationName]
            if ($null -eq $cfg -or -not $cfg.Ran)
            {
                $out.Outcome = 'Failed'
                $out.Reason = if ($cfg -and $cfg.Error) { [string]$cfg.Error } else { 'its configuration was not applied' }
            }
            elseif ($cfg.Error)
            {
                $out.Outcome = 'Failed'
                $out.Reason = [string]$cfg.Error
            }
            else
            {
                $notIn = @($cfg.NotInDesiredState | Where-Object { $null -ne $_ })
                $mine = if ($out.ResourceId) { @($notIn | Where-Object { [string]$_.ResourceId -ieq [string]$out.ResourceId }) } else { @() }
                $reported = $out.ResourceId -and (@($cfg.InDesiredState | Where-Object { [string]$_ -ieq [string]$out.ResourceId }).Count -gt 0)
                if ($mine.Count -gt 0)
                {
                    $out.Outcome = 'Failed'
                    $out.Reason = if ($mine[0].Error) { [string]$mine[0].Error } else { 'not in the desired state after the apply' }
                }
                elseif ($reported -or $notIn.Count -eq 0)
                {
                    $out.Outcome = 'Applied'
                    $out.Reason = ''
                }
                else
                {
                    $out.Outcome = 'Failed'
                    $out.Reason = 'the LCM did not report this resource, and its configuration still has resources not in the desired state'
                }
            }
        }
    }
    $out
}

$items = @($result)
$count = { param ($name) @($items | Where-Object Outcome -EQ $name).Count }
$left = @($items | Where-Object { $_.Outcome -notin 'Applied', 'NoActionRequired' })
[pscustomobject]@{
    Items    = $items
    Totals   = [ordered]@{
        Items = $items.Count; Applied = (& $count 'Applied'); NoActionRequired = (& $count 'NoActionRequired'); NotGenerated = (& $count 'NotGenerated')
        Failed = (& $count 'Failed'); Skipped = (& $count 'Skipped'); ToApply = (& $count 'ToApply')
    }
    Complete = ($left.Count -eq 0)
    Left     = $left
}
