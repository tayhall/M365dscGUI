<#
.SYNOPSIS
    Turns what the LCM reported for each configuration into one of the five outcomes of every approved item.
.DESCRIPTION
    Pure (no tenant access): the apply script calls it with the build's outcomes.json rows and what each configuration's LCM run returned.
    Every approved item ends in exactly one outcome, so the counts add up to the number of approved items:
      Applied           a ToApply item the LCM reported in the desired state after the apply (never without that evidence)
      NoActionRequired  Dev already had the approved outcome: decided by the build from the exported Dev (kept), or found by the LCM test at run
                        time to be in the desired state already (so running the same list again converges)
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

    # One per configuration the LCM was run for: @{ ConfigurationName; Ran; Error; InDesiredState = @(resource id); NotInDesiredState = @(@{ ResourceId; Error });
    # TestInDesiredState = @(resource id) that the LCM test found already in the desired state before any apply }.
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
        $cfg = $configs[[string]$out.ConfigurationName]
        $alreadyDone = $cfg -and $out.ResourceId -and (@($cfg.TestInDesiredState | Where-Object { [string]$_ -ieq [string]$out.ResourceId }).Count -gt 0)
        if ($out.Action -eq 'Remove' -and -not $IncludeRemovals)
        {
            $out.Outcome = 'Skipped'
            $out.Reason = 'removals were not included: tick includeRemovals to apply an approved Remove'
        }
        elseif ($alreadyDone)
        {
            # Dev as it is NOW (the LCM test at run time), not the exported Dev the list was reviewed against: this is what makes a re-run converge.
            $out.Outcome = 'NoActionRequired'
            $out.Reason = 'already in the desired state when the LCM tested it'
        }
        elseif ($Mode -eq 'Apply')
        {
            $fail = { param ($why) $out.Outcome = 'Failed'; $out.Reason = $why }
            if ($null -eq $cfg -or -not $cfg.Ran)
            {
                & $fail $(if ($cfg -and $cfg.Error) { [string]$cfg.Error } else { 'its configuration was not applied' })
            }
            elseif (-not $out.ResourceId)
            {
                & $fail 'its DSC resource id could not be worked out, so the LCM result cannot be checked for it'
            }
            else
            {
                $notIn = @($cfg.NotInDesiredState | Where-Object { $null -ne $_ })
                $inDesired = @($cfg.InDesiredState | Where-Object { $_ })
                $mine = @($notIn | Where-Object { [string]$_.ResourceId -ieq [string]$out.ResourceId })
                $reported = @($inDesired | Where-Object { [string]$_ -ieq [string]$out.ResourceId }).Count -gt 0
                if ($cfg.Error -and $notIn.Count -eq 0 -and $inDesired.Count -eq 0)
                {
                    # The LCM returned an error and no per-resource lists at all: nothing says which resource was done.
                    & $fail ([string]$cfg.Error)
                }
                elseif ($mine.Count -gt 0)
                {
                    & $fail $(if ($mine[0].Error) { [string]$mine[0].Error } elseif ($cfg.Error) { [string]$cfg.Error } else { 'not in the desired state after the apply' })
                }
                elseif ($reported)
                {
                    $out.Outcome = 'Applied'
                    $out.Reason = ''
                }
                else
                {
                    # Applied only on evidence: the LCM must have reported this resource in the desired state.
                    & $fail $(if ($cfg.Error) { "the LCM did not report this resource ($($cfg.Error))" } else { "the LCM did not report this resource ($($inDesired.Count) reported in the desired state, $($notIn.Count) not)" })
                }
            }
        }
    }
    $out
}

$rows = @($result)
$count = { param ($name) @($rows | Where-Object Outcome -EQ $name).Count }
$left = @($rows | Where-Object { $_.Outcome -notin 'Applied', 'NoActionRequired' })
[pscustomobject]@{
    Items    = $rows
    Totals   = [ordered]@{
        Items = $rows.Count; Applied = (& $count 'Applied'); NoActionRequired = (& $count 'NoActionRequired'); NotGenerated = (& $count 'NotGenerated')
        Failed = (& $count 'Failed'); Skipped = (& $count 'Skipped'); ToApply = (& $count 'ToApply')
    }
    Complete = ($left.Count -eq 0)
    Left     = $left
}
