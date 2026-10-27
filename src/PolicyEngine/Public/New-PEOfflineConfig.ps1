function New-PEOfflineConfig
{
    <#
    .SYNOPSIS
    Generates the DSC configuration that brings a tenant in line with its own blueprint: changes in one file, removals in
    another, and a list of what needs manual action. Nothing connects to a tenant and nothing is stored.

    .DESCRIPTION
    Made for an offline tenant, whose owner runs the configuration in their own pipeline; a connected tenant works the same.
    The latest Full check of the tenant is compared again (Compare-PEState) with the tenant's own blueprint (the last one it
    follows, named after the tenant) as it is now and with the decisions as they are now, so an item moved into the
    blueprint or excluded after the check counts as it does in the GUI. A type the blueprint gained after the check was never
    read by it and counts as NotChecked. The check must be of the tenant as registered (its TenantId, when set). Of the Open
    findings:
    - Missing -> Create and Changed -> Update go into Changes (configuration PE_Changes);
    - TargetOnly with no hint -> Remove goes into Removals (configuration PE_Removals), but only for a type the blueprint
      manages (at least one record of it in the blueprint); a TargetOnly item of any other type goes into Manual and is
      counted in NoBlueprintTypeCount. New-PERectifyPlan removes only with
      a Remove decision: one is made in memory for exactly these findings (as Get-PEGuiRevertConfig does) and never stored;
    - PossibleRename, Ambiguous, and a Missing or TargetOnly finding with a hint go into Manual with the hint as the reason.
    NotChecked, NotAvailable, Excluded and Unmanaged findings are not planned.
    The plans and the text come from New-PERectifyPlan and ConvertTo-PEDscConfig (-Target Replica), in this one call (plan
    items are registered in this process only): both files carry the pinned module version and credentials only as
    $ConfigurationData.NonNodeData references. An item either of them refuses (no Ensure, a property on the ignored/secret
    list or unknown to the module, a type that cannot be reverted) is narrowed down by halving the list until it is alone,
    and goes into Manual with the error as the reason; the rest of its file is still generated. A file with nothing in it
    is $null. Each file starts with comment lines saying how to run it.
    Returns @{ Changes; Removals; Manual = @(@{ ResourceType; Key; Action; Reason }); CheckId; BlueprintName; BlueprintVersion
    (compared with); CheckBlueprintVersion (the check was made against); NoBlueprintTypeCount }.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [ValidatePattern('(?-i)\A[a-z0-9][a-z0-9-]{0,39}\z')]
        [string]$Tenant,

        [string]$DataRoot
    )

    $root = Get-PEDataRoot -Override $DataRoot
    # The own blueprint is named after the tenant and is the last one it follows (Initialize-PETenantBlueprint, New-PEUploadCheck).
    $layers = @(@((Get-PETenant -Slug $Tenant -DataRoot $root).Blueprints) | Where-Object { $_ })
    if ($layers.Count -eq 0 -or $layers[-1] -cne $Tenant)
    {
        throw "Tenant '$Tenant' has no blueprint of its own, so there is nothing to bring it in line with. Save its first upload as its blueprint, or give it one and move the wanted items into it, then generate again."
    }
    $check = Get-PECheck -Latest -Kind Full -Tenant $Tenant -DataRoot $root
    # The check must be of this tenant: its state names the tenant it was read from, the registry the tenant's own id.
    $registeredId = [string](Get-PETenant -Slug $Tenant -DataRoot $root).TenantId
    $sourceTenantId = [string](Get-PEMetaValue -Meta $check.State.Meta -Name 'TenantId')
    if ($registeredId -and $sourceTenantId -ine $registeredId)
    {
        throw "The latest check of '$Tenant' ($($check.CheckId)) was read from tenant '$sourceTenantId', not from '$registeredId' as registered. Upload or check the tenant again."
    }
    $blueprintVersion = @(Get-PEBlueprintVersionNumber -Directory (Get-PEBlueprintDirectory -Name $Tenant -DataRoot $root))[-1]
    $blueprint = Get-PEBlueprint -Name $Tenant -Version ([string]$blueprintVersion) -DataRoot $root
    $checkBlueprintVersion = if ($null -ne $check.BlueprintVersion) { [int]$check.BlueprintVersion } else { $null }

    # A type the blueprint gained after the check was never read by it: with no records in the state it would look Missing and be
    # created blind. The check judged exactly the types of the blueprint version it was compared with (a live check exports those
    # types; an upload marks those of them it does not hold NotChecked or, for a complete workload, empty). So every type of the
    # current blueprint that has no records in the state, is not NotChecked there and was not in that blueprint version is added
    # to a copy of the state as NotChecked; a check compared with no blueprint judged none. The copy is the plan's source too.
    # A check Invoke-PEScopeCheck patched keeps the base check's BlueprintVersion while its scope was compared with a later
    # blueprint, so this rule cannot tell what it read: refuse rather than guess. (An upload fold records the version it used.)
    if ($null -ne (Get-PEMetaValue -Meta $check.State.Meta -Name 'ScopeChecks'))
    {
        throw "The latest check of '$Tenant' ($($check.CheckId)) was patched by a scope check, so which types it read cannot be told from its blueprint version. Run a full check of the tenant (or upload a new snapshot) first, then generate again."
    }
    $judged = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($check.BlueprintName -and $null -ne $checkBlueprintVersion)
    {
        try
        {
            $checkBlueprint = Get-PEBlueprint -Name ([string]$check.BlueprintName) -Version ([string]$checkBlueprintVersion) -DataRoot $root
        }
        catch
        {
            throw "The blueprint the latest check of '$Tenant' ($($check.CheckId)) was made against, '$($check.BlueprintName)' v$checkBlueprintVersion, cannot be read ($($_.Exception.Message)), so which types the check read cannot be told."
        }
        foreach ($record in @($checkBlueprint.Records)) { [void]$judged.Add([string]$record.ResourceType) }
    }
    foreach ($record in @($check.State.Records)) { [void]$judged.Add([string]$record.ResourceType) }
    foreach ($entry in @($check.State.NotChecked | Where-Object { $null -ne $_ })) { [void]$judged.Add([string]$entry.ResourceType) }
    $unread = @(@($blueprint.Records) | ForEach-Object { [string]$_.ResourceType } | Where-Object { $_ -and -not $judged.Contains($_) } | Sort-Object -Unique |
            ForEach-Object { [pscustomobject]@{ ResourceType = $_; Reason = 'not read by the check: added to the blueprint after it' } })
    $state = $check.State | Select-Object -Property *
    $state.NotChecked = @(@($check.State.NotChecked | Where-Object { $null -ne $_ }) + $unread)

    $decisions = @(Get-PEDecision -Tenant $Tenant -DataRoot $root)
    $findings = @(Compare-PEState -Blueprint $blueprint -Target $state -Decisions $decisions -WarningAction SilentlyContinue)

    $manual = [System.Collections.Generic.List[object]]::new()
    $addManual = {
        param ($finding, $action, $reason)
        $manual.Add([pscustomobject]@{ ResourceType = [string]$finding.ResourceType; Key = [string]$finding.Key; Action = $action; Reason = [string]$reason })
    }
    $actionFor = @{ Missing = 'Create'; Changed = 'Update'; TargetOnly = 'Remove' }
    # An Open TargetOnly item is one the user left as drift (undecided counts as drift), but only for a type the blueprint manages,
    # that is, a type with at least one record in it. Of any other type the blueprint says nothing (the own blueprint seeded from an
    # Entra-only upload has no Exchange type, so every Exchange object would be target-only): those items are not removed, they go
    # into Manual, and NoBlueprintTypeCount says how many there are.
    $managedTypes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($record in @($blueprint.Records)) { [void]$managedTypes.Add([string]$record.ResourceType) }
    $noBlueprintType = 0
    $chosen = [System.Collections.Generic.List[object]]::new()
    foreach ($finding in $findings | Where-Object { $_.State -eq 'Open' -and -not [string]::IsNullOrEmpty([string]$_.Key) })
    {
        $kind = [string]$finding.Kind
        if ($kind -eq 'TargetOnly' -and -not $managedTypes.Contains([string]$finding.ResourceType))
        {
            $noBlueprintType++
            & $addManual $finding 'Remove' "type '$($finding.ResourceType)' has no records in the blueprint, so nothing says the tenant should not have these; add them to the blueprint, exclude them, or remove by hand"
        }
        elseif ($actionFor.ContainsKey($kind) -and [string]::IsNullOrEmpty([string]$finding.Hint))
        {
            $chosen.Add([pscustomobject]@{ Finding = $finding; Action = $actionFor[$kind] })
        }
        elseif ($actionFor.ContainsKey($kind))
        {
            & $addManual $finding $actionFor[$kind] "$($finding.Hint). Check it by hand; nothing was generated for it."
        }
        elseif ($kind -eq 'PossibleRename')
        {
            $side = if ($null -ne $finding.BlueprintRecord) { 'Create' } else { 'Remove' }
            & $addManual $finding $side "$($finding.Hint). A rename is not created or removed automatically: rename it back in the tenant, or decide it in the GUI."
        }
        elseif ($kind -eq 'Ambiguous')
        {
            & $addManual $finding 'Review' 'The key appears more than once in the tenant or the blueprint, so it cannot be matched to one object.'
        }
    }

    # One plan item per finding, so a finding New-PERectifyPlan refuses only loses itself. Removals carry the in-memory decisions.
    $removeDecisions = @($chosen | Where-Object Action -EQ 'Remove' | ForEach-Object {
            [pscustomobject]@{ Kind = 'Remove'; ResourceType = [string]$_.Finding.ResourceType; Key = [string]$_.Finding.Key; Property = $null; Value = $null; Reason = 'generated configuration (not stored)'; At = '2026-01-01T00:00:00.000Z' }
        })
    $planArguments = @{ Source = $state; Blueprint = $blueprint; Decisions = $removeDecisions }
    if ($registeredId) { $planArguments.ExpectedTenantId = $registeredId }
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @(if ($chosen.Count) { Sort-PERevertEntry -Entry $chosen.ToArray() }))
    {
        try
        {
            $plan = @(New-PERectifyPlan -Findings @($entry.Finding) -Action $entry.Action @planArguments)
            $entries.Add([pscustomobject]@{ Finding = $entry.Finding; Action = $entry.Action; Plan = $plan[0] })
        }
        catch
        {
            & $addManual $entry.Finding $entry.Action $_.Exception.Message
        }
    }

    # The entries ConvertTo-PEDscConfig accepts: the whole list when it can, otherwise each half again, down to one item.
    $accepted = {
        param ([object[]]$group, [string]$name)
        try
        {
            ConvertTo-PEDscConfig -Plan @($group | ForEach-Object { $_.Plan }) -ConfigurationName $name -Target Replica | Out-Null
            return $group
        }
        catch
        {
            if ($group.Count -eq 1)
            {
                & $addManual $group[0].Finding $group[0].Action $_.Exception.Message
                return
            }
        }
        $half = [int][Math]::Floor($group.Count / 2)
        & $accepted @($group[0..($half - 1)]) $name
        & $accepted @($group[$half..($group.Count - 1)]) $name
    }
    $generate = {
        param ([object[]]$group, [string]$name)
        if ($group.Count -eq 0) { return $null }
        try
        {
            return (ConvertTo-PEDscConfig -Plan @($group | ForEach-Object { $_.Plan }) -ConfigurationName $name -Target Replica)
        }
        catch
        {
            if ($group.Count -eq 1)
            {
                & $addManual $group[0].Finding $group[0].Action $_.Exception.Message
                return $null
            }
        }
        $good = @(& $accepted $group $name)
        if ($good.Count -eq 0) { return $null }
        # The items that pass on their own, together and in their order.
        ConvertTo-PEDscConfig -Plan @($good | ForEach-Object { $_.Plan }) -ConfigurationName $name -Target Replica
    }

    $changes = & $generate @($entries | Where-Object Action -In 'Create', 'Update') 'PE_Changes'
    $removals = & $generate @($entries | Where-Object Action -EQ 'Remove') 'PE_Removals'

    # How to run it, in front of each file (comment lines only, so the text still parses as ConvertTo-PEDscConfig checked it).
    $version = Get-PEPinnedVersion -Name Microsoft365DSC
    $howTo = {
        param ($name, $what)
        @(
            "# $name brings tenant '$Tenant' in line with its blueprint '$Tenant' v$blueprintVersion (check $($check.CheckId)). $what"
            "# Needs Microsoft365DSC $version on the machine that runs it (the Import-DscResource line below pins it)."
            '# How to run it:'
            '#   . .\<this file>.ps1'
            "#   $name -ConfigurationData .\ConfigurationData.psd1 -OutputPath .\$name"
            "#   Start-DscConfiguration -Path .\$name -Wait -Verbose     (or your pipeline's usual way of applying a DSC configuration)"
            '# ConfigurationData.psd1: AllNodes = @(@{ NodeName = ''localhost'' }); its NonNodeData holds ApplicationId, TenantId, CertificateThumbprint and OrganizationName'
            '# (and TenantGuid when a block uses it), the same values your Microsoft365DSC export pipeline uses.'
            '# Apply PE_Changes before PE_Removals, and review every block of PE_Removals first: it deletes objects.'
            ''
        ) -join "`n"
    }
    if ($changes) { $changes = (& $howTo 'PE_Changes' 'Creates what is missing and sets what changed.') + $changes }
    if ($removals) { $removals = (& $howTo 'PE_Removals' 'Removes the objects left as drift that are not in the blueprint.') + $removals }

    [pscustomobject]@{
        Changes               = $changes
        Removals              = $removals
        Manual                = [object[]]$manual.ToArray()
        CheckId               = [string]$check.CheckId
        BlueprintName         = $Tenant
        # The blueprint version compared with, and the one the check was made against (they differ when the blueprint changed since).
        BlueprintVersion      = [int]$blueprintVersion
        CheckBlueprintVersion = $checkBlueprintVersion
        # Target-only items of a type with no records in the blueprint: in Manual, never in Removals.
        NoBlueprintTypeCount  = $noBlueprintType
    }
}
