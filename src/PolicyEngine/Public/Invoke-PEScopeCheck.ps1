function Invoke-PEScopeCheck
{
    <#
    .SYNOPSIS
    Checks one scope (named set of resource types, optionally only keys matching patterns) against the blueprint and
    folds the result into the latest Full check, so only that slice is re-read and re-judged.

    .DESCRIPTION
    1. Exports just the scope's types with the Reader app (one export, minutes at most for a handful of types, instead of
       the half hour a whole tenant takes), and classifies each type from export.log like a Full check: Failed and
       Incomplete types become NotChecked, never Missing; a type the log never mentions is NotChecked.
    2. Compares the scope's slice of the blueprint with the scope's slice of the export (Compare-PEState with the
       decisions), so items outside the scope can never read as Missing or Target-only.
    3. Saves a new Full-kind check: the latest Full check with the scope's records, NotChecked entries and findings
       replaced. Meta.ExportedAt stays the old full export time (the rest of the tenant was not re-read); Meta.PatchedFrom
       names the check it was built from and Meta.ScopeChecks records when each scope was last checked. Everything that
       reads the latest Full check (the GUI, rectify) sees one consistent state.
    A Full check must exist first. -ExportScript is a test seam: called with Components and OutputPath, returns the export
    folder.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Scope,

        [Parameter(Mandatory)]
        [string]$BlueprintName,

        [scriptblock]$ExportScript,

        [string]$TargetTenantId,

        # By default a scope whose types the blueprint holds no item of is refused: every object would read as Target-only.
        [switch]$AllowTypesNotInBlueprint,

        # Run although the pinned Microsoft365DSC is not the version the blueprint was built with.
        [switch]$AcceptModuleChange,

        # Which tenant to read (see Get-PETenant); the first tenant is 'master'.
        [ValidatePattern('(?-i)\A[a-z0-9][a-z0-9-]{0,39}\z')]
        [string]$Tenant = 'master',

        [string]$DataRoot
    )

    $root = Get-PEDataRoot -Override $DataRoot
    $definition = Get-PEScope -Name $Scope -DataRoot $root
    if (@($definition.Types).Count -eq 0)
    {
        throw "Scope '$Scope' lists no resource types."
    }
    $blueprint = Get-PEBlueprint -Name $BlueprintName -DataRoot $root
    Assert-PEModuleVersion -BlueprintName $BlueprintName -AcceptModuleChange:$AcceptModuleChange -DataRoot $root
    if (-not $AllowTypesNotInBlueprint)
    {
        $known = @(@($blueprint.Records) | ForEach-Object { [string]$_.ResourceType } | Sort-Object -Unique)
        $empty = @($definition.Types | Where-Object { $known -inotcontains $_ })
        if ($empty.Count -eq $definition.Types.Count)
        {
            throw "Blueprint '$BlueprintName' holds no item of $($empty -join ', '), so every object of the tenant would read as Target-only. Add the type to the blueprint, or pass -AllowTypesNotInBlueprint."
        }
    }
    $base = Get-PECheck -Latest -Kind Full -Tenant $Tenant -DataRoot $root
    if ([string]$base.BlueprintName -and [string]$base.BlueprintName -ne $BlueprintName)
    {
        throw "The latest Full check ($($base.CheckId)) is for blueprint '$($base.BlueprintName)', not '$BlueprintName'. Run a full check for '$BlueprintName' first."
    }

    # CheckId: sortable UTC timestamp, later than the base check and free.
    $moment = [datetime]::UtcNow
    while ($moment.ToString('yyyyMMdd-HHmmss') -le [string]$base.CheckId -or (Test-Path -LiteralPath (Join-Path $root ('checks\' + $moment.ToString('yyyyMMdd-HHmmss')))))
    {
        $moment = $moment.AddSeconds(1)
    }
    $checkId = $moment.ToString('yyyyMMdd-HHmmss')
    $outputPath = Join-Path $root ('exports\' + $checkId + '-scope-' + $definition.Name)

    if ($ExportScript)
    {
        $exportPath = [string](@(& $ExportScript @{ Components = [string[]]$definition.Types; OutputPath = $outputPath })[-1])
    }
    else
    {
        $tool = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'tools\Export-M365DscTenant.ps1'
        Invoke-PEExportToolProcess -ArgumentList ([string[]]@('-NoProfile', '-File', $tool, '-Role', 'Reader', '-Components', ($definition.Types -join ','), '-OutputPath', $outputPath) + [string[]]@($(if ($Tenant -ne 'master') { '-Tenant', $Tenant })))
        $exportPath = $outputPath
    }

    $exportFile = Find-PEExportFile -Path $exportPath
    $exportedAt = (Get-Item -LiteralPath $exportFile).LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $tenantId = $TargetTenantId
    if (-not $tenantId -and -not $ExportScript) { $tenantId = Get-PEReaderTenantId -Tenant $Tenant }
    if (-not $tenantId) { $tenantId = 'unknown' }

    $inScope = { param ($type, $key) Test-PEInScope -Scope $definition -ResourceType $type -Key $key }
    $typeOnly = { param ($type) Test-PEInScope -Scope ([pscustomobject]@{ Types = $definition.Types; Keys = @() }) -ResourceType $type -Key $null }

    # The scope's slice of the export, with the failure rules of a Full check.
    $records = @(Read-PEExport -Path $exportFile -TenantId $tenantId | ForEach-Object { ConvertTo-PENormalizedRecord -Record $_ -ExportedAt $exportedAt } |
            Where-Object { & $typeOnly $_.ResourceType })
    $logPath = Join-Path $exportPath 'export.log'
    $hasLog = Test-Path -LiteralPath $logPath -PathType Leaf
    $logWarnings = [System.Collections.Generic.List[string]]::new()
    $entries = if ($hasLog) { @(Read-PEExportLog -Path $logPath -Warnings $logWarnings) } else { @() }
    $notChecked = [System.Collections.Generic.List[object]]::new()
    $failed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $named = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries)
    {
        if (-not (& $typeOnly $entry.ResourceType)) { continue }
        [void]$named.Add([string]$entry.ResourceType)
        if ($entry.Status -in 'Failed', 'Incomplete')
        {
            [void]$failed.Add([string]$entry.ResourceType)
            $notChecked.Add([pscustomobject]@{ ResourceType = [string]$entry.ResourceType; Reason = $entry.Reason })
        }
    }
    $gapReason = if ($hasLog) { 'not in export log' } else { 'no export log' }
    foreach ($type in $definition.Types)
    {
        if (-not $named.Contains($type)) { $notChecked.Add([pscustomobject]@{ ResourceType = $type; Reason = $gapReason }) }
    }
    $records = @($records | Where-Object { -not $failed.Contains([string]$_.ResourceType) })

    # Compared against EVERY exported record of the scope's types (not only the pattern matches), so a rename out of the key
    # pattern is still paired with its missing original; findings about unrelated items outside the pattern are dropped below.
    $targetRecords = @($records | Where-Object { & $inScope $_.ResourceType $_.Key })
    $target = New-PEState -Records $records -NotChecked @($notChecked) -Meta @{ TenantId = $tenantId; ExportedAt = $exportedAt; Source = $exportPath }
    $scopedBlueprint = New-PEState -Records @(@($blueprint.Records) | Where-Object { & $inScope $_.ResourceType $_.Key }) `
        -NotChecked @(@($blueprint.NotChecked) | Where-Object { $null -ne $_ -and (& $typeOnly ([string]$_.ResourceType)) }) -Meta @{ TenantId = (Get-PEMetaValue -Meta $blueprint.Meta -Name 'TenantId') }
    $decisions = @(Get-PEDecision -DataRoot $root -Tenant $Tenant)
    $scopeFindings = @(Compare-PEState -Blueprint $scopedBlueprint -Target $target -Decisions $decisions | Where-Object {
            (& $inScope ([string]$_.ResourceType) ([string]$_.Key)) -or $_.Kind -eq 'PossibleRename' -or $_.Kind -in 'NotChecked', 'NotAvailable', 'Excluded', 'Unkeyed'
        })
    $touched = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($finding in $scopeFindings) { [void]$touched.Add(("$($finding.ResourceType)|$($finding.Key)")) }

    # Fold into the latest Full check: everything of the scope goes, the new slice comes.
    $keptFindings = @(@($base.Findings) | Where-Object { -not ((& $inScope ([string]$_.ResourceType) ([string]$_.Key)) -or ((& $typeOnly ([string]$_.ResourceType)) -and $touched.Contains("$($_.ResourceType)|$($_.Key)"))) })
    $keptRecords = @(@($base.State.Records) | Where-Object { -not (& $inScope ([string]$_.ResourceType) ([string]$_.Key)) })
    $keptNotChecked = @(@($base.State.NotChecked) | Where-Object { $null -ne $_ -and -not (& $typeOnly ([string]$_.ResourceType)) })
    $meta = [ordered]@{}
    foreach ($property in $base.State.Meta.PSObject.Properties) { $meta[$property.Name] = $property.Value }
    $scopeChecks = [ordered]@{}
    if ($meta.Contains('ScopeChecks') -and $null -ne $meta['ScopeChecks'])
    {
        foreach ($property in $meta['ScopeChecks'].PSObject.Properties) { $scopeChecks[$property.Name] = $property.Value }
    }
    $scopeChecks[$definition.Name] = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $meta['ScopeChecks'] = $scopeChecks
    $meta['PatchedFrom'] = [string]$base.CheckId

    $document = [ordered]@{}
    foreach ($property in $base.PSObject.Properties) { $document[$property.Name] = $property.Value }
    $document['CheckId'] = $checkId
    $document['Findings'] = @(@($keptFindings) + @($scopeFindings))
    $document['State'] = [ordered]@{ Records = @(@($keptRecords) + @($targetRecords)); NotChecked = @(@($keptNotChecked) + @($notChecked)); Meta = $meta }
    $document['Scope'] = $definition.Name
    $document['LogWarnings'] = @($logWarnings)
    Write-PEJsonNew -Path (Join-Path $root "checks\$checkId\result.json") -InputObject $document

    $drift = @($scopeFindings | Where-Object { $_.State -eq 'Open' -and $_.Kind -in 'Missing', 'Changed', 'TargetOnly', 'PossibleRename', 'Ambiguous' })
    [pscustomobject]@{
        Scope      = $definition.Name
        CheckId    = $checkId
        BasedOn    = [string]$base.CheckId
        Items      = @($scopedBlueprint.Records).Count
        Findings   = $scopeFindings
        Drifted    = $drift.Count
        NotChecked = @($notChecked).Count
        Path       = $exportPath
    }
}
