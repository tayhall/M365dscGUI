function New-PERectifyPlanSafe
{
    # Plans the findings of ONE action through New-PERectifyPlan without failing as a whole when the engine refuses some of them.
    # Every New-PERectifyPlan call indexes all records of the source and the blueprint, so asking once per finding would take minutes on a
    # large export. The findings are asked together; when the engine refuses, the group is halved until the refused finding is alone
    # (as ConvertTo-PEDscConfigSafe does for the configuration text). With few refusals it is a handful of calls.
    # Returns [pscustomobject]@{ Planned = @(@{ Finding; Action; Plan }) in the order given; Refused = @(@{ Finding; Reason }) } with the
    # engine's message cut to its first line. Plan items are registered in this process only (ConvertTo-PEDscConfig accepts only those).
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param
    (
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Finding = @(),

        [Parameter(Mandatory)]
        [ValidateSet('Create', 'Update', 'Remove', 'Promote')]
        [string]$Action,

        [Parameter(Mandatory)]
        [object]$Source,

        [Parameter(Mandatory)]
        [object]$Blueprint,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Decision = @(),

        [string]$ExpectedTenantId
    )

    $findings = @($Finding | Where-Object { $null -ne $_ })
    $planned = [System.Collections.Generic.Dictionary[object, object]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)
    $refused = [System.Collections.Generic.Dictionary[object, string]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)

    $ask = {
        param ([object[]]$group)
        $arguments = @{ Source = $Source; Blueprint = $Blueprint; Decisions = @($Decision) }
        if ($ExpectedTenantId) { $arguments.ExpectedTenantId = $ExpectedTenantId }
        try
        {
            $plans = @(New-PERectifyPlan -Findings $group -Action $Action @arguments)
            foreach ($finding in $group)
            {
                $plan = $plans | Where-Object { [string]$_.ResourceType -ieq [string]$finding.ResourceType -and [string]$_.Key -ceq [string]$finding.Key } | Select-Object -First 1
                if ($null -eq $plan) { $plan = $plans | Where-Object { [string]$_.ResourceType -ieq [string]$finding.ResourceType -and [string]$_.Key -ieq [string]$finding.Key } | Select-Object -First 1 }
                if ($null -eq $plan) { $refused[$finding] = 'The engine returned no plan item for it.' } else { $planned[$finding] = $plan }
            }
        }
        catch
        {
            if ($group.Count -eq 1)
            {
                $refused[$group[0]] = (([string]$_.Exception.Message) -split "`r?`n")[0].Trim()
            }
            else
            {
                $half = [int][Math]::Ceiling($group.Count / 2)
                & $ask @($group[0..($half - 1)])
                & $ask @($group[$half..($group.Count - 1)])
            }
        }
    }
    if ($findings.Count -gt 0) { & $ask $findings }

    [pscustomobject]@{
        Planned = @($findings | Where-Object { $planned.ContainsKey($_) } | ForEach-Object { [pscustomobject]@{ Finding = $_; Action = $Action; Plan = $planned[$_] } })
        Refused = @($findings | Where-Object { $refused.ContainsKey($_) } | ForEach-Object { [pscustomobject]@{ Finding = $_; Reason = $refused[$_] } })
    }
}
