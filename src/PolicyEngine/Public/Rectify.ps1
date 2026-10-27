function New-PERectifyPlan
{
    <#
    .SYNOPSIS
    Turns selected findings into plan items for one action, refusing anything that is not safe to rectify.

    .DESCRIPTION
    Returns PlanItem[] = [pscustomobject]@{ Action; ResourceType; Key; Workload; Record; Finding; ConfirmNotRenamed }.
    Every finding must pass, or the whole call throws (nothing is planned from a partly invalid selection):
    - Ambiguous, NotChecked, NotAvailable, Excluded, Unkeyed and Unreadable findings are refused for every action, as
      is any unknown Kind. (Excluded: a type of Data\ExcludedTypes.psd1 that the comparison did not look at.)
    - Create only for Missing (Record = BlueprintRecord). Update only for Changed (Record = BlueprintRecord, the
      desired state). Remove only for TargetOnly with a matching Remove decision (ResourceType and Key,
      case-insensitive), State Open and no Hint (Record = TargetRecord; the configuration sets Ensure = 'Absent').
      Promote only for TargetOnly, State Open or Unmanaged (Record = TargetRecord, applied to the master).
    - Unmanaged findings are refused for Create, Update and Remove.
    - PossibleRename is refused for every action unless -ConfirmNotRenamed: then Create is allowed for one built from
      a blueprint record only, and Remove (with a Remove decision) for one built from a target record only. The item
      has ConfirmNotRenamed = $true and keeps the finding.
    - The finding is checked against -Source, the check state it came from: its type must not be NotChecked there; a
      Missing (or blueprint-side PossibleRename) key must not exist in Source.Records; a TargetOnly, Changed (or
      target-side PossibleRename) key must exist exactly once in Source.Records with the same properties as the
      finding's TargetRecord. A stale finding is refused. A quick-scan source and records without properties
      (key-only scan records) are refused: they carry no settings to apply. Source.Meta.ExportedAt is required (a
      state without a timestamp cannot be audited); with -ExpectedTenantId, Source.Meta.TenantId must equal it.
    - The finding is also checked against -Blueprint, the CURRENT blueprint (callers pass
      Get-PEBlueprint -Name <name> -Version latest), because the blueprint may have changed since the check: its type
      must not be NotChecked there; Remove and Promote need the key to be absent from the blueprint; Create and Update
      need the key exactly once in the blueprint with the same properties as the finding's BlueprintRecord. Otherwise:
      'blueprint changed since the check; re-run the check'.
    The record always comes from the finding. Duplicate (Action, ResourceType, Key) findings collapse to one item.
    Each item carries SourceIdentity (ExportedAt, TenantId, Source of the check state; Version and ExportedAt of the
    blueprint) and is registered in this process: ConvertTo-PEDscConfig accepts only registered, unchanged items.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param
    (
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Findings,

        [Parameter(Mandatory)]
        [ValidateSet('Create', 'Update', 'Remove', 'Promote')]
        [string]$Action,

        [Parameter(Mandatory)]
        [object]$Source,

        [Parameter(Mandatory)]
        [object]$Blueprint,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Decisions = @(),

        [switch]$ConfirmNotRenamed,

        [ValidateNotNullOrEmpty()]
        [string]$ExpectedTenantId
    )

    # TRUST BOUNDARY: this function trusts the caller to pass the LATEST blueprint as -Blueprint; it cannot tell an old
    # version from the latest one. Invoke-PERectify (Task 11) must compare plan.json's Source.BlueprintVersion with the
    # latest blueprint version before applying, and refuse on a mismatch.

    $selected = @($Findings | Where-Object { $null -ne $_ })
    if ($selected.Count -eq 0)
    {
        throw 'No findings to plan: select at least one finding.'
    }
    if ($null -eq $Source -or -not $Source.PSObject.Properties['Records'])
    {
        throw 'Source must be the check state the findings came from (an object with Records and NotChecked).'
    }
    if ($null -eq $Blueprint -or -not $Blueprint.PSObject.Properties['Records'])
    {
        throw 'Blueprint must be the current blueprint state (Get-PEBlueprint -Version latest).'
    }
    $sourceSource = [string](Get-PEMetaValue -Meta $Source.Meta -Name 'Source')
    if ($sourceSource -eq 'quick scan')
    {
        throw 'Source is a quick scan: its records carry keys only, not settings. Run a Full check (or a delta export and check) and plan from its findings.'
    }
    $sourceExportedAt = [string](Get-PEMetaValue -Meta $Source.Meta -Name 'ExportedAt')
    if ([string]::IsNullOrWhiteSpace($sourceExportedAt))
    {
        throw 'Source state has no Meta.ExportedAt: a state without a timestamp cannot be audited.'
    }
    $sourceTenantId = [string](Get-PEMetaValue -Meta $Source.Meta -Name 'TenantId')
    if ($PSBoundParameters.ContainsKey('ExpectedTenantId') -and $sourceTenantId -ine $ExpectedTenantId)
    {
        throw "Source state belongs to tenant '$sourceTenantId', not the expected tenant '$ExpectedTenantId'."
    }
    $blueprintVersion = Get-PEMetaValue -Meta $Blueprint.Meta -Name 'Version'
    $sourceIdentity = [ordered]@{
        ExportedAt          = $sourceExportedAt
        TenantId            = $(if ($sourceTenantId) { $sourceTenantId } else { $null })
        Source              = $(if ($sourceSource) { $sourceSource } else { $null })
        BlueprintVersion    = $(if ($null -ne $blueprintVersion) { [int]$blueprintVersion } else { $null })
        BlueprintExportedAt = [string](Get-PEMetaValue -Meta $Blueprint.Meta -Name 'ExportedAt')
    }

    $sourceIndex = Get-PEStateIndex -State $Source
    $notChecked = Get-PENotCheckedMap -NotChecked @($Source.NotChecked)
    $blueprintIndex = Get-PEStateIndex -State $Blueprint
    $blueprintNotChecked = Get-PENotCheckedMap -NotChecked @($Blueprint.NotChecked)

    $removeDecisions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($decision in @($Decisions))
    {
        if ($null -ne $decision -and $decision.Kind -eq 'Remove' -and
            -not [string]::IsNullOrWhiteSpace([string]$decision.ResourceType) -and -not [string]::IsNullOrWhiteSpace([string]$decision.Key))
        {
            [void]$removeDecisions.Add((Get-PEMatchKey -ResourceType ([string]$decision.ResourceType) -Key ([string]$decision.Key)))
        }
    }

    $refusedKinds = @('Ambiguous', 'NotChecked', 'NotAvailable', 'Excluded', 'Unkeyed', 'Unreadable')
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $items = [System.Collections.Generic.List[object]]::new()

    foreach ($finding in $selected)
    {
        $kind = [string]$finding.Kind
        $type = [string]$finding.ResourceType
        $key = [string]$finding.Key
        $label = "$type '$key'"

        if ($kind -in $refusedKinds)
        {
            throw "Refusing $Action for $label`: $kind findings are never rectified."
        }
        if ($kind -notin 'Missing', 'Changed', 'TargetOnly', 'PossibleRename')
        {
            throw "Refusing $Action for $label`: unknown finding Kind '$kind'."
        }
        # A type the Local Configuration Manager cannot apply for a known reason (Data\RevertBlocked.psd1). Promote only writes the blueprint.
        $blocked = Get-PERevertBlock -ResourceType $type
        if ($blocked -and $Action -ne 'Promote')
        {
            throw "Refusing $Action for $label`: $blocked"
        }
        if ([string]::IsNullOrWhiteSpace($type) -or [string]::IsNullOrWhiteSpace($key))
        {
            throw "Refusing $Action for a $kind finding without a resource type and key."
        }

        $state = [string]$finding.State
        if ($state -ne 'Open' -and -not ($state -eq 'Unmanaged' -and $Action -eq 'Promote'))
        {
            throw "Refusing $Action for $label`: the finding is $state (only Promote is allowed for an Unmanaged item)."
        }

        # Which record is applied, and which side of the comparison the source must confirm.
        $hasBlueprint = $null -ne $finding.BlueprintRecord
        $hasTarget = $null -ne $finding.TargetRecord
        $side = $null
        if ($kind -eq 'PossibleRename')
        {
            if (-not $ConfirmNotRenamed)
            {
                throw "Refusing $Action for $label`: it is a possible rename ($($finding.Hint)). Check the pair; if it is not a rename, use -ConfirmNotRenamed."
            }
            if ($Action -eq 'Create' -and $hasBlueprint -and -not $hasTarget)
            {
                $side = 'Blueprint'
            }
            elseif ($Action -eq 'Remove' -and $hasTarget -and -not $hasBlueprint)
            {
                $side = 'Target'
            }
            else
            {
                throw "Refusing $Action for $label`: with -ConfirmNotRenamed a possible rename can only be created (blueprint side) or removed (target side)."
            }
        }
        elseif ($kind -eq 'Missing' -and $Action -eq 'Create')
        {
            $side = 'Blueprint'
        }
        elseif ($kind -eq 'Changed' -and $Action -eq 'Update')
        {
            $side = 'Changed'
        }
        elseif ($kind -eq 'TargetOnly' -and $Action -in 'Remove', 'Promote')
        {
            $side = 'Target'
        }
        else
        {
            throw "Refusing $Action for $label`: $Action is not allowed for a $kind finding."
        }

        $matchKey = Get-PEMatchKey -ResourceType $type -Key $key
        if ($Action -eq 'Remove')
        {
            if (-not [string]::IsNullOrEmpty([string]$finding.Hint) -and $kind -ne 'PossibleRename')
            {
                throw "Refusing Remove for $label`: the finding has a hint ('$($finding.Hint)'), so it may be part of a rename."
            }
            if (-not $removeDecisions.Contains($matchKey))
            {
                throw "Refusing Remove for $label`: there is no Remove decision for it (Set-PEDecision -Kind Remove)."
            }
        }

        $record = if ($side -eq 'Target') { $finding.TargetRecord } else { $finding.BlueprintRecord }
        if ($null -eq $record)
        {
            throw "Refusing $Action for $label`: the finding carries no record to apply."
        }
        # A blueprint record applied to a different tenant than the blueprint came from must not carry the source tenant's
        # ids (Data\IgnoredProperties.psd1, TenantBound): they are left out so the target tenant's own are used.
        if ($side -ne 'Target' -and (Test-PECrossTenant -BlueprintTenantId (Get-PEMetaValue -Meta $Blueprint.Meta -Name 'TenantId') -TargetTenantId (Get-PEMetaValue -Meta $Source.Meta -Name 'TenantId')))
        {
            $bag = Remove-PEIgnoredPath -ResourceType ([string]$record.ResourceType) -Properties (Get-PEPropertyBag -Record $record) -TenantBound
            $record = [pscustomobject]@{ ResourceType = $record.ResourceType; Key = $record.Key; Workload = $record.Workload; TenantId = $record.TenantId; Properties = $bag }
        }
        if ([string]$record.ResourceType -ine $type -or [string]$record.Key -ine $key)
        {
            throw "Refusing $Action for $label`: the finding's record is $($record.ResourceType) '$($record.Key)'."
        }
        if ((Get-PEPropertyBag -Record $record).Count -eq 0)
        {
            throw "Refusing $Action for $label`: the record has no properties (a key-only quick-scan record); run a Full check first."
        }

        # Validate against the source state.
        if ($notChecked.ContainsKey($type))
        {
            throw "Refusing $Action for $label`: $type was not checked in the source state ($($notChecked[$type]))."
        }
        $inSource = if ($sourceIndex.ContainsKey($matchKey)) { $sourceIndex[$matchKey] } else { $null }
        if ($side -eq 'Blueprint')
        {
            if ($null -ne $inSource)
            {
                throw "Refusing $Action for $label`: the finding is stale, the object now exists in the source state."
            }
        }
        else
        {
            if ($null -eq $inSource -or $inSource.Count -ne 1)
            {
                $count = if ($null -eq $inSource) { 0 } else { $inSource.Count }
                throw "Refusing $Action for $label`: the finding is stale, the source state has $count records with this key."
            }
            if (-not $hasTarget)
            {
                throw "Refusing $Action for $label`: the finding carries no target record."
            }
            $sourceCanon = ConvertTo-PECanonicalValue (Get-PEPropertyBag -Record $inSource[0])
            $findingCanon = ConvertTo-PECanonicalValue (Get-PEPropertyBag -Record $finding.TargetRecord)
            if ($sourceCanon -cne $findingCanon)
            {
                throw "Refusing $Action for $label`: the finding is stale, the object in the source state has different settings."
            }
        }

        # Validate against the current blueprint.
        $blueprintChanged = "Refusing $Action for $label`: blueprint changed since the check; re-run the check."
        if ($blueprintNotChecked.ContainsKey($type))
        {
            throw "Refusing $Action for $label`: $type was not checked in the current blueprint ($($blueprintNotChecked[$type]))."
        }
        $inBlueprint = if ($blueprintIndex.ContainsKey($matchKey)) { $blueprintIndex[$matchKey] } else { $null }
        if ($Action -in 'Remove', 'Promote')
        {
            if ($null -ne $inBlueprint)
            {
                throw $blueprintChanged
            }
        }
        else
        {
            if ($null -eq $inBlueprint -or $inBlueprint.Count -ne 1)
            {
                throw $blueprintChanged
            }
            $blueprintCanon = ConvertTo-PECanonicalValue (Get-PEPropertyBag -Record $inBlueprint[0])
            $findingCanon = ConvertTo-PECanonicalValue (Get-PEPropertyBag -Record $finding.BlueprintRecord)
            if ($blueprintCanon -cne $findingCanon)
            {
                throw $blueprintChanged
            }
        }

        if (-not $seen.Add($Action + '|' + $matchKey))
        {
            continue
        }
        # The item carries a frozen deep copy of the record: later changes to the caller's objects cannot change what
        # is rendered.
        $item = [pscustomobject]@{
            Action            = $Action
            ResourceType      = $type
            Key               = $key
            Workload          = [string]$finding.Workload
            Record            = Copy-PEFrozenRecord -Record $record
            Finding           = $finding
            ConfirmNotRenamed = ($kind -eq 'PossibleRename')
            SourceIdentity    = [pscustomobject]$sourceIdentity
        }
        Register-PEPlanItem -Item $item
        $items.Add($item)
    }

    return $items.ToArray()
}

function ConvertTo-PEDscConfig
{
    <#
    .SYNOPSIS
    Generates the DSC configuration text for a rectify plan.

    .DESCRIPTION
    The configuration contains only the planned instances, one resource block each, inside Node localhost, with
    Import-DscResource for the pinned Microsoft365DSC version. Each block carries the record's properties (nulls
    omitted), Ensure = 'Absent' for Remove and 'Present' otherwise (when the resource has Ensure), and the credentials
    as references to the configuration data, never values:
        ApplicationId = $ConfigurationData.NonNodeData.ApplicationId (likewise TenantId, CertificateThumbprint)
    $OrganizationName is set from $ConfigurationData.NonNodeData.OrganizationName as in the export, because exported
    values refer to the tenant domain through it.

    Refused (throws): an empty plan; any item not produced by New-PERectifyPlan in this process, or changed since
    (hand-built items, copies and items read back from JSON are refused); Target Replica with a Promote item (Target Master takes every action: it restores
    the master to its blueprint); two items for the same resource instance; a
    record that does not match its item; a resource type, property or CIM class unknown to the pinned module's
    schema; a missing Key or Required property; Remove of a type without Ensure; any property on the ignored/secret
    lists (Data\IgnoredProperties.psd1); values that are not plain data. The text is checked with the PowerShell
    parser before it is returned (no errors, one resource block per item).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Plan,

        [Parameter(Mandatory)]
        [ValidatePattern('\A[A-Za-z][A-Za-z0-9_-]{0,63}\z')]
        [string]$ConfigurationName,

        [Parameter(Mandatory)]
        [ValidateSet('Replica', 'Master')]
        [string]$Target,

        # Turns a user principal name into the user's object id in the target tenant (Data\IdentityReferences.psd1); the GUI preview has none.
        [scriptblock]$UserIdResolver,

        # (type, key) -> the Id of that object in the target tenant, for the types in Data\IdentityReferences.psd1 OwnIds.
        [scriptblock]$OwnIdResolver
    )

    $items = @($Plan | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0)
    {
        throw 'The plan is empty: nothing to generate.'
    }

    # Only items issued by New-PERectifyPlan in this process, unchanged since.
    # Validate, then work ONLY from the frozen snapshots stored when the items were issued.
    $snapshotSet = Get-PEPlanSnapshotSet -Items $items
    $planFingerprint = $snapshotSet.Plan
    $items = @($snapshotSet.Snapshots)

    # Target rules next. Restoring the master to its approved blueprint (Create, Update, Remove) is allowed; Invoke-PERectify
    # still demands -ConfirmMasterWrite for any Target Master.
    foreach ($item in $items)
    {
        $action = [string]$item.Action
        if ($action -notin 'Create', 'Update', 'Remove', 'Promote')
        {
            throw "Unknown plan action '$action'."
        }
    }
    foreach ($item in $items)
    {
        if ($Target -eq 'Replica' -and $item.Action -eq 'Promote')
        {
            throw "Refusing Promote of $($item.ResourceType) '$($item.Key)' on the replica: Promote items target the master."
        }
    }

    $ignored = Get-PEIgnoredProperties
    $credentialNames = @('ApplicationId', 'TenantId', 'CertificateThumbprint')
    $never = @('ResourceName', 'ResourceInstanceName', 'DependsOn', 'PsDscRunAsCredential')
    $version = Get-PEPinnedVersion -Name Microsoft365DSC
    $instances = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $usedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $blocks = [System.Collections.Generic.List[string]]::new()
    $header = @(
        "# Generated by PolicyEngine (ConvertTo-PEDscConfig) for Microsoft365DSC $version. Target: $Target. Resource instances: $($items.Count)."
        '# Credentials and the tenant domain come from the configuration data: $ConfigurationData.NonNodeData.ApplicationId,'
        '# TenantId, CertificateThumbprint, OrganizationName and TenantGuid.'
        "Configuration $ConfigurationName"
        '{'
        '    param ()'
        ''
        '    $OrganizationName = $ConfigurationData.NonNodeData.OrganizationName'
        '    $TenantGuid = $ConfigurationData.NonNodeData.TenantGuid'
        ''
        "    Import-DscResource -ModuleName 'Microsoft365DSC' -ModuleVersion '$version'"
        ''
        '    Node localhost'
        '    {'
    ) -join "`n"
    $footer = "    }`n}`n"
    # Exact running length of header + "`n" + blocks joined by "`n" + "`n" + footer.
    $length = $header.Length + $footer.Length + 1

    foreach ($item in $items)
    {
        $type = [string]$item.ResourceType
        $key = [string]$item.Key
        $label = "$type '$key'"
        $record = $item.Record
        if ($UserIdResolver -and $null -ne $record)
        {
            $record = Resolve-PEUserReference -Record $record -Resolver $UserIdResolver
        }
        if ($OwnIdResolver -and $null -ne $record)
        {
            $record = Resolve-PEOwnId -Record $record -Resolver $OwnIdResolver
        }
        $position = "plan item $($blocks.Count + 1) of $($items.Count)"
        # What is left of the total cap for this block; Format-PEDscValue charges every rendered value to it.
        $budget = [pscustomobject]@{ Remaining = $script:PEMaxConfigLength - $length - 1; Exceeded = $false }
        if ($type -cnotmatch $script:PEResourceTypePattern)
        {
            throw "Invalid resource type '$type'."
        }
        if ([string]::IsNullOrWhiteSpace($key))
        {
            throw "Plan item for $type has no key."
        }
        if ($null -eq $record -or [string]$record.ResourceType -ine $type -or [string]$record.Key -ine $key)
        {
            throw "Plan item $label does not carry its own record."
        }
        if (-not $instances.Add((Get-PEMatchKey -ResourceType $type -Key $key)))
        {
            throw "Plan names $label more than once; one resource instance can have only one action."
        }
        $schema = Get-PEDscResourceSchema -ResourceType $type
        if ($null -eq $schema)
        {
            throw "'$type' is not a resource of Microsoft365DSC $version."
        }

        $skip = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in @($ignored.Global) + $never)
        {
            [void]$skip.Add($name)
        }
        if ($ignored.ByType.ContainsKey($type))
        {
            foreach ($name in $ignored.ByType[$type])
            {
                [void]$skip.Add($name)
            }
        }

        if (Test-PEOwnIdType -ResourceType $type)
        {
            [void]$skip.Remove('Id')
        }
        $lines = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $bag = Get-PEPropertyBag -Record $record
        foreach ($rawName in @($bag.get_Keys()))
        {
            $name = [string]$rawName
            if ($name -cnotmatch $script:PEIdentifierPattern)
            {
                throw "Refusing $label`: property name '$name' is not a valid identifier."
            }
            if ($skip.Contains($name))
            {
                throw "Refusing to embed property '$name' of $label`: it is on the ignored/secret list."
            }
            if ($name -ieq 'Ensure')
            {
                continue
            }
            if (-not $schema.ContainsKey($name))
            {
                throw "Property '$name' of $label is not a parameter of $type in Microsoft365DSC $version."
            }
            $value = $bag[$rawName]
            if ($null -eq $value)
            {
                continue
            }
            try
            {
                $lines[$name] = Format-PEDscValue -Value $value -Path "$type[$key].$name" -Indent 12 -Budget $budget
            }
            catch
            {
                if ($budget.Exceeded)
                {
                    throw "The configuration would exceed $($script:PEMaxConfigLength) characters at $($item.Action) $label property $name ($position). Split the plan into smaller batches."
                }
                throw
            }
        }

        if ($schema.ContainsKey('Ensure'))
        {
            $lines['Ensure'] = if ($item.Action -eq 'Remove') { "'Absent'" } else { "'Present'" }
        }
        elseif ($item.Action -eq 'Remove')
        {
            throw "Refusing Remove of $label`: $type has no Ensure property, so DSC cannot remove it."
        }
        foreach ($name in $credentialNames)
        {
            if (-not $schema.ContainsKey($name))
            {
                throw "$type has no $name parameter; certificate authentication is not possible."
            }
            $lines[$name] = '$ConfigurationData.NonNodeData.' + $name
        }
        # A [Key] the ignore list took out of the record (Id) that the record's own Key was built from is read back from the Key.
        foreach ($parameter in @($schema.GetEnumerator()))
        {
            if ($parameter.Value -eq 'Key' -and -not $lines.ContainsKey($parameter.Key))
            {
                $recovered = Get-PEKeyPartFromRecordKey -ResourceType $type -Key $key -Property ([string]$parameter.Key)
                if ($null -ne $recovered)
                {
                    $lines[[string]$parameter.Key] = Format-PEDscValue -Value $recovered -Path "$type[$key].$($parameter.Key)" -Indent 12 -Budget $budget
                }
            }
        }
        foreach ($parameter in $schema.GetEnumerator())
        {
            if ($parameter.Value -in 'Key', 'Required' -and -not $lines.ContainsKey($parameter.Key))
            {
                throw "Refusing $label`: the $($parameter.Value) property '$($parameter.Key)' is missing from the record."
            }
        }

        $names = [System.Collections.Generic.List[string]]::new([string[]]@($lines.get_Keys()))
        $names.Sort([System.StringComparer]::OrdinalIgnoreCase)
        $width = ($names | Measure-Object -Property Length -Maximum).Maximum
        $instanceName = Get-PEDscInstanceName -ResourceType $type -Key $key -Used $usedNames
        $block = [System.Collections.Generic.List[string]]::new()
        $block.Add("        $type '$instanceName'")
        $block.Add('        {')
        foreach ($name in $names)
        {
            $block.Add('            ' + $name.PadRight($width) + ' = ' + $lines[$name] + ';')
        }
        $block.Add('        }')
        $blockText = $block -join "`n"
        $length += $blockText.Length + 1
        if ($length -gt $script:PEMaxConfigLength)
        {
            throw "The configuration would exceed $($script:PEMaxConfigLength) characters at $($item.Action) $label ($position). Split the plan into smaller batches."
        }
        $blocks.Add($blockText)
    }

    $text = $header + "`n" + ($blocks -join "`n") + "`n" + $footer
    if ($text.Length -ne $length)
    {
        throw "Internal error: configuration length $($text.Length) differs from the running length $length."
    }

    # Pure ASCII by construction (ConvertTo-PEDscStringLiteral); anything else is a generator bug.
    if ($text -cmatch '[^\x09\x0A\x0D\x20-\x7E]')
    {
        throw 'Generated configuration contains non-ASCII or control characters.'
    }
    # The text must parse to data only, with exactly one resource block per plan item, under UTF-8 and Windows-1252.
    Test-PEDscConfigSafe -Text $text -ResourceTypes @($items | ForEach-Object { [string]$_.ResourceType }) -ExpectedBlocks $items.Count -ConfigurationName $ConfigurationName
    Register-PEDscConfig -Text $text -PlanFingerprint $planFingerprint -ConfigurationName $ConfigurationName -Target $Target
    return $text
}

function Save-PEAudit
{
    <#
    .SYNOPSIS
    Saves a rectify plan and its configuration for audit; returns the audit folder.

    .DESCRIPTION
    Writes <DataRoot>\audit\<yyyyMMdd-HHmmssfff>\ (with '-2', '-3', ... if that folder exists) containing:
    - config.ps1: the configuration text, exactly as given, UTF-8 with a BOM (ConfigSha256 hashes the bytes written).
    - plan.json: CreatedAt, User, Target and Configuration (as given to ConvertTo-PEDscConfig), ConfigSha256 and one
      entry per item (Action, ResourceType, Key, Workload, Kind, State, Hint, ConfirmNotRenamed, ChangedProperties,
      DifferenceCount, Source = the check state's ExportedAt/TenantId/Source and the blueprint's Version/ExportedAt).
      Property names only: no record or difference values; the finding is never serialised.
    - who.txt: the user and the UTC time.
    Only items from New-PERectifyPlan in this process are accepted, with a Config that ConvertTo-PEDscConfig generated
    from exactly these items in this process (otherwise: 'config was not generated from this plan'). plan.json is written first, then config.ps1 and
    who.txt; files are created once and never overwritten, and if any write fails the folder this call created is
    removed and the error rethrown.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Plan,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Config,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$User,

        [string]$DataRoot
    )

    $items = @($Plan | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0)
    {
        throw 'The plan is empty: nothing to audit.'
    }
    if ([string]::IsNullOrWhiteSpace($Config))
    {
        throw 'The configuration is empty: nothing to audit.'
    }
    # Validate, then work ONLY from the frozen snapshots stored when the items were issued.
    $snapshotSet = Get-PEPlanSnapshotSet -Items $items
    $items = @($snapshotSet.Snapshots)
    $registration = Get-PEDscConfigRegistration -Text $Config -PlanFingerprint $snapshotSet.Plan
    if ($null -eq $registration)
    {
        if (Test-PEDscConfigEvicted -Text $Config)
        {
            throw "The config was not generated from this plan, or its registration may have been evicted after $($script:PEConfigRegistryLimit) newer configs; regenerate the config with ConvertTo-PEDscConfig. Refusing to audit it."
        }
        throw 'The config was not generated from this plan by ConvertTo-PEDscConfig in this session; refusing to audit it.'
    }
    $userText = ConvertTo-PEAuditText -Text $User
    if ([string]::IsNullOrWhiteSpace($userText))
    {
        throw 'User is empty.'
    }

    # Build everything to write before anything touches the disk.
    $now = Get-PEUtcNow
    # config.ps1 is written as UTF-8 WITH a BOM (Windows PowerShell 5.1 reads a BOM-less file as the ANSI code page);
    # ConfigSha256 is the hash of exactly the bytes written, preamble included.
    $encoding = [System.Text.UTF8Encoding]::new($true)
    $configBytes = [byte[]]($encoding.GetPreamble() + $encoding.GetBytes($Config))
    $hash = Get-PETextSha256 -Bytes $configBytes
    # Plain values from the snapshots only: records and difference values are never serialised.
    $entries = foreach ($item in $items)
    {
        $finding = $item.Finding
        $identity = $item.SourceIdentity
        [ordered]@{
            Action            = [string]$item.Action
            ResourceType      = [string]$item.ResourceType
            Key               = [string]$item.Key
            Workload          = [string]$item.Workload
            Kind              = $(if ($null -ne $finding) { [string]$finding.Kind } else { $null })
            State             = $(if ($null -ne $finding) { [string]$finding.State } else { $null })
            Hint              = $(if ($null -ne $finding -and $finding.Hint) { [string]$finding.Hint } else { $null })
            ConfirmNotRenamed = [bool]$item.ConfirmNotRenamed
            ChangedProperties = [string[]]@(if ($null -ne $finding) { $finding.ChangedProperties })
            DifferenceCount   = $(if ($null -ne $finding) { [int]$finding.DifferenceCount } else { 0 })
            Source            = [ordered]@{
                ExportedAt          = [string]$identity.ExportedAt
                TenantId            = $(if ($identity.TenantId) { [string]$identity.TenantId } else { $null })
                Source              = $(if ($identity.Source) { [string]$identity.Source } else { $null })
                BlueprintVersion    = $(if ($null -ne $identity.BlueprintVersion) { [int]$identity.BlueprintVersion } else { $null })
                BlueprintExportedAt = $(if ($identity.BlueprintExportedAt) { [string]$identity.BlueprintExportedAt } else { $null })
            }
        }
    }
    $document = [ordered]@{
        CreatedAt     = $now.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [cultureinfo]::InvariantCulture)
        User          = $userText
        Target        = $registration.Target
        Configuration = $registration.ConfigurationName
        ConfigFile    = 'config.ps1'
        ConfigSha256  = $hash
        ItemCount     = $items.Count
        Items         = @($entries)
    }

    $root = Get-PEDataRoot -Override $DataRoot
    $auditRoot = Join-Path $root 'audit'
    if (-not (Test-Path -LiteralPath $auditRoot -PathType Container))
    {
        New-Item -ItemType Directory -Path $auditRoot -Force | Out-Null
    }

    $stamp = $now.ToString('yyyyMMdd-HHmmssfff', [cultureinfo]::InvariantCulture)
    $folder = $null
    for ($n = 1; $n -le 1000; $n++)
    {
        $name = if ($n -eq 1) { $stamp } else { "$stamp-$n" }
        $candidate = Join-Path $auditRoot $name
        if (Test-Path -LiteralPath $candidate)
        {
            continue
        }
        try
        {
            # Without -Force New-Item fails if the folder appeared in the meantime.
            New-Item -ItemType Directory -Path $candidate -ErrorAction Stop | Out-Null
            $folder = $candidate
            break
        }
        catch
        {
            if (-not (Test-Path -LiteralPath $candidate))
            {
                throw
            }
        }
    }
    if ($null -eq $folder)
    {
        throw "Could not create a unique audit folder for $stamp."
    }

    # This call created the folder, so on any failure it removes it again: no half-written audit entry remains.
    try
    {
        Write-PEJsonNew -Path (Join-Path $folder 'plan.json') -InputObject $document
        Write-PETextNew -Path (Join-Path $folder 'config.ps1') -Text $Config -Bom
        Write-PETextNew -Path (Join-Path $folder 'who.txt') -Text ("User: $userText`nUTC: $($document.CreatedAt)`n")
    }
    catch
    {
        Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }

    return $folder
}
