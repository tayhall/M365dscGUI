function Update-PECheckForItems
{
    # After a Promote: compares just the promoted items of the tenant's latest Full check with the blueprint version the Promote wrote, using
    # the records the check already holds (the tenant is not read again), and saves the result as a new check that keeps everything else of
    # the base check. Without it the promoted items stay listed as drift until the next check. Returns the new check id, or $null when the
    # latest Full check is of another blueprint.
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Tenant,

        [Parameter(Mandatory)]
        [string]$BlueprintName,

        # Anything with ResourceType and Key.
        [Parameter(Mandatory)]
        [object[]]$Item,

        [string]$DataRoot
    )

    $root = Get-PEDataRoot -Override $DataRoot
    $base = Get-PECheck -Latest -Kind Full -Tenant $Tenant -DataRoot $root
    if ([string]$base.BlueprintName -and [string]$base.BlueprintName -ine $BlueprintName)
    {
        return $null
    }
    $blueprint = Get-PEBlueprint -Name $BlueprintName -DataRoot $root

    $wanted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $Item) { [void]$wanted.Add(("$($entry.ResourceType)|$($entry.Key)")) }
    $isWanted = { param ($thing) $wanted.Contains(("$($thing.ResourceType)|$($thing.Key)")) }

    $targetMeta = @{}
    foreach ($property in $base.State.Meta.PSObject.Properties) { $targetMeta[$property.Name] = $property.Value }
    $scopedBlueprint = New-PEState -Records @(@($blueprint.Records) | Where-Object { & $isWanted $_ }) -NotChecked @() -Meta @{
        TenantId   = (Get-PEMetaValue -Meta $blueprint.Meta -Name 'TenantId')
        ExportedAt = (Get-PEMetaValue -Meta $blueprint.Meta -Name 'ExportedAt')
    }
    $scopedTarget = New-PEState -Records @(@($base.State.Records) | Where-Object { & $isWanted $_ }) -NotChecked @() -Meta $targetMeta
    $decisions = @(Get-PEDecision -DataRoot $root -Tenant $Tenant)
    $recompared = @(Compare-PEState -Blueprint $scopedBlueprint -Target $scopedTarget -Decisions $decisions | Where-Object { & $isWanted $_ })

    # CheckId: sortable UTC timestamp, later than the base check and free.
    $moment = [datetime]::UtcNow
    while ($moment.ToString('yyyyMMdd-HHmmss') -le [string]$base.CheckId -or (Test-Path -LiteralPath (Join-Path $root ('checks\' + $moment.ToString('yyyyMMdd-HHmmss')))))
    {
        $moment = $moment.AddSeconds(1)
    }
    $checkId = $moment.ToString('yyyyMMdd-HHmmss')

    $meta = [ordered]@{}
    foreach ($property in $base.State.Meta.PSObject.Properties) { $meta[$property.Name] = $property.Value }
    $meta['PatchedFrom'] = [string]$base.CheckId

    $document = [ordered]@{}
    foreach ($property in $base.PSObject.Properties) { $document[$property.Name] = $property.Value }
    $document['CheckId'] = $checkId
    $document['Findings'] = @(@(@($base.Findings) | Where-Object { -not (& $isWanted $_) }) + @($recompared))
    $document['State'] = [ordered]@{ Records = @($base.State.Records); NotChecked = @($base.State.NotChecked); Meta = $meta }
    Write-PEJsonNew -Path (Join-Path $root "checks\$checkId\result.json") -InputObject $document
    return $checkId
}
