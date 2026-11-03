function Get-PEDriftReportData
{
    <#
    .SYNOPSIS
    Turns the findings of Invoke-PEExportComparison into the plain data the HTML drift report shows.

    .DESCRIPTION
    Returns [pscustomobject]@{ Meta; Totals; Items }. An item is one open finding:
      Id            '<Action>|<ResourceType>|<Key>' for an actionable finding, '<Kind>|<ResourceType>|<Key>' for any other
      Action        Create (Missing in Dev), Update (Changed), Remove (only in Dev), or $null for every other kind
      Approvable    true only when New-PERectifyPlan accepts the finding (the engine's own rules, called once per drifted item),
                    and, for a Remove, the blueprint (PreProd) manages the type and the finding has no hint
      Reason        why it cannot be approved (the engine's message, one line), empty when it can
      Differences   @{ Property; Dev; PreProd } with display strings, cut at -MaxValueLength
    Resources that match are only counted (Totals.Matching), never listed. Totals.Create/Update/Remove count approvable items;
    Totals.CannotApprove counts the others. Totals.Matching is the PreProd records without a finding.
    No comparison happens here: the findings are the engine's.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param
    (
        [Parameter(Mandatory)]
        [object]$Comparison,

        [Parameter(Mandatory)]
        [string]$Tenant,

        # @{ Run; ExportedAt; Fingerprint } of the PreProd (source) and Dev (target) exports, as New-PEApprovedList takes them.
        [Parameter(Mandatory)]
        [hashtable]$Source,

        [Parameter(Mandatory)]
        [hashtable]$Target,

        [datetime]$GeneratedUtc = [datetime]::UtcNow,

        [ValidateRange(10, 100000)]
        [int]$MaxValueLength = 4000
    )

    $actionFor = @{ Missing = 'Create'; Changed = 'Update'; TargetOnly = 'Remove' }
    $display = {
        param ($value)
        if ($null -eq $value) { return '(none)' }
        $text = if ($value -is [string]) { $value } else { ConvertTo-Json -InputObject $value -Compress -Depth 6 }
        if ($text.Length -gt $MaxValueLength) { $text = $text.Substring(0, $MaxValueLength) + [string][char]0x2026 }
        $text
    }

    $blueprint = $Comparison.Blueprint
    $state = $Comparison.Check.State
    $managedTypes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($record in @($blueprint.Records)) { [void]$managedTypes.Add([string]$record.ResourceType) }

    $items = [System.Collections.Generic.List[object]]::new()
    $matchingTaken = 0
    foreach ($finding in @($Comparison.Findings | Where-Object { $_.State -eq 'Open' }))
    {
        $kind = [string]$finding.Kind
        $action = if ($actionFor.ContainsKey($kind)) { $actionFor[$kind] } else { $null }
        $key = [string]$finding.Key
        $approvable = $false
        $reason = ''

        if ($null -eq $action)
        {
            $reason = if (-not [string]::IsNullOrWhiteSpace([string]$finding.Hint)) { [string]$finding.Hint } else { $kind }
        }
        elseif ([string]::IsNullOrEmpty($key))
        {
            $reason = "$kind finding without a key"
        }
        elseif ($kind -eq 'TargetOnly' -and -not $managedTypes.Contains([string]$finding.ResourceType))
        {
            $reason = "type '$($finding.ResourceType)' has no records in PreProd's export, so nothing says Dev should not have these"
        }
        elseif (-not [string]::IsNullOrEmpty([string]$finding.Hint))
        {
            $reason = [string]$finding.Hint
        }
        else
        {
            $planArguments = @{ Source = $state; Blueprint = $blueprint }
            if ($action -eq 'Remove')
            {
                $planArguments.Decisions = @([pscustomobject]@{
                        Kind = 'Remove'; ResourceType = [string]$finding.ResourceType; Key = $key; Property = $null; Value = $null
                        Reason = 'drift report (not stored)'; At = '2026-01-01T00:00:00.000Z'
                    })
            }
            try
            {
                New-PERectifyPlan -Findings @($finding) -Action $action @planArguments | Out-Null
                $approvable = $true
            }
            catch
            {
                $reason = (([string]$_.Exception.Message) -split "`r?`n")[0].Trim()
            }
        }

        $differences = @(foreach ($difference in @($finding.Differences | Where-Object { $null -ne $_ }))
            {
                [pscustomobject][ordered]@{ Property = [string]$difference.Property; Dev = (& $display $difference.Target); PreProd = (& $display $difference.Blueprint) }
            })
        $idLead = if ($action) { $action } else { $kind }
        $items.Add([pscustomobject][ordered]@{
                Id           = "$idLead|$($finding.ResourceType)|$key"
                Action       = $action
                Kind         = $kind
                ResourceType = [string]$finding.ResourceType
                Key          = $key
                Workload     = [string]$finding.Workload
                Approvable   = $approvable
                Reason       = $reason
                Differences  = $differences
            })

        # A record of PreProd that has a finding does not match: Missing and Changed are one record each, Ambiguous holds BlueprintCount.
        if ($kind -in 'Missing', 'Changed') { $matchingTaken++ }
        elseif ($kind -eq 'Ambiguous' -and $null -ne $finding.PSObject.Properties['BlueprintCount']) { $matchingTaken += [int]$finding.BlueprintCount }
    }

    $sourceRecords = @($Comparison.SourceState.Records).Count
    $removeOnly = @($items | Where-Object { $_.Kind -eq 'TargetOnly' }).Count
    $matching = [Math]::Max(0, $sourceRecords - $matchingTaken)
    $approvableItems = @($items | Where-Object Approvable)
    $totals = [pscustomobject][ordered]@{
        Total         = ($sourceRecords + $removeOnly)
        Matching      = $matching
        Create        = @($approvableItems | Where-Object Action -EQ 'Create').Count
        Update        = @($approvableItems | Where-Object Action -EQ 'Update').Count
        Remove        = @($approvableItems | Where-Object Action -EQ 'Remove').Count
        CannotApprove = @($items | Where-Object { -not $_.Approvable }).Count
    }

    $side = { param ($h) [pscustomobject][ordered]@{ Run = [string]$h.Run; ExportedAt = [string]$h.ExportedAt; Fingerprint = [string]$h.Fingerprint } }
    $reportId = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
            [System.Text.Encoding]::UTF8.GetBytes([string]$Source.Fingerprint + [string]$Target.Fingerprint))).ToLowerInvariant()
    [pscustomobject][ordered]@{
        Meta   = [pscustomobject][ordered]@{
            Tenant        = $Tenant
            Source        = & $side $Source
            Target        = & $side $Target
            ModuleVersion = (Get-PEPinnedVersion -Name Microsoft365DSC)
            GeneratedUtc  = $GeneratedUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            ReportId      = $reportId
        }
        Totals = $totals
        Items  = @($items | Sort-Object ResourceType, Key, Kind)
    }
}
