function ConvertTo-PEDscConfigSafe
{
    # Generates one DSC configuration from plan entries, leaving out the entries the engine refuses instead of failing as a whole.
    # Each entry is [pscustomobject]@{ Plan; Finding; Action } (as New-PEOfflineConfig and New-PEApprovedConfig build them). The whole
    # list is tried first; when ConvertTo-PEDscConfig throws, the list is halved again and again until the refused entry is alone, so
    # the rest is still generated, in its order. Returns [pscustomobject]@{ Text; Refused = @([pscustomobject]@{ Entry; Reason }) };
    # Text is $null when nothing is left. Plan items are registered in this process only, so this must run in the process that made them.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param
    (
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Entry = @(),

        [Parameter(Mandatory)]
        [string]$ConfigurationName,

        [Parameter(Mandatory)]
        [ValidateSet('Replica', 'Master')]
        [string]$Target
    )

    $entries = @($Entry | Where-Object { $null -ne $_ })
    $refused = [System.Collections.Generic.List[object]]::new()
    if ($entries.Count -eq 0)
    {
        return [pscustomobject]@{ Text = $null; Refused = @() }
    }

    # The entries ConvertTo-PEDscConfig accepts: the whole group when it can, otherwise each half again, down to one entry.
    $accepted = {
        param ([object[]]$group)
        try
        {
            ConvertTo-PEDscConfig -Plan @($group | ForEach-Object { $_.Plan }) -ConfigurationName $ConfigurationName -Target $Target | Out-Null
            return $group
        }
        catch
        {
            if ($group.Count -eq 1)
            {
                $refused.Add([pscustomobject]@{ Entry = $group[0]; Reason = $_.Exception.Message })
                return
            }
        }
        $half = [int][Math]::Floor($group.Count / 2)
        & $accepted @($group[0..($half - 1)])
        & $accepted @($group[$half..($group.Count - 1)])
    }

    $text = $null
    try
    {
        $text = ConvertTo-PEDscConfig -Plan @($entries | ForEach-Object { $_.Plan }) -ConfigurationName $ConfigurationName -Target $Target
    }
    catch
    {
        if ($entries.Count -eq 1)
        {
            $refused.Add([pscustomobject]@{ Entry = $entries[0]; Reason = $_.Exception.Message })
        }
        else
        {
            $good = @(& $accepted $entries)
            if ($good.Count -gt 0)
            {
                # The entries that pass on their own, together and in their order.
                $text = ConvertTo-PEDscConfig -Plan @($good | ForEach-Object { $_.Plan }) -ConfigurationName $ConfigurationName -Target $Target
            }
        }
    }

    [pscustomobject]@{ Text = $text; Refused = @($refused) }
}
