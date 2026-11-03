# Validation of the approved list (see docs/superpowers/specs/2026-11-03-approved-drift-apply-design.md). Used by New-, Save- and
# Read-PEApprovedList so a list is held to the same rules wherever it comes from.

function Get-PEApprovedPropertyName
{
    param ([object]$Object)
    if ($Object -is [System.Collections.IDictionary]) { return @($Object.Keys | ForEach-Object { [string]$_ }) }
    @($Object.PSObject.Properties | ForEach-Object { $_.Name })
}

function Get-PEApprovedValue
{
    param ([object]$Object, [string]$Name)
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { $property.Value } else { $null }
}

function Get-PEApprovedCount
{
    # Counts per (ResourceType, Action), derived from the items; ordered by type, then Create, Update, Remove.
    param ([object[]]$Item)
    $actionOrder = @{ Create = 0; Update = 1; Remove = 2 }
    @($Item | Group-Object { "$($_.ResourceType)|$($_.Action)" } | ForEach-Object {
            [pscustomobject]@{ ResourceType = [string]$_.Group[0].ResourceType; Action = [string]$_.Group[0].Action; Count = [int]$_.Count }
        } | Sort-Object ResourceType, { $actionOrder[$_.Action] })
}

function Assert-PEApprovedList
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [object]$List,

        [Parameter(Mandatory)]
        [string]$Label
    )

    $fail = { param ($message) throw "Approved list ${Label}: $message" }
    $checkNames = {
        param ($object, [string[]]$allowed, [string]$where)
        $present = Get-PEApprovedPropertyName $object
        foreach ($name in $present)
        {
            if ($name -cnotin $allowed) { & $fail "unknown property '$name' in $where." }
        }
        foreach ($name in $allowed)
        {
            if ($name -cnotin $present) { & $fail "missing property '$name' in $where." }
        }
    }
    $isoUtc = '\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z'
    $control = '[\p{Cc}]'

    & $checkNames $List @('Format', 'CreatedUtc', 'ApprovedBy', 'Tenant', 'ModuleVersion', 'Source', 'Target', 'Items', 'Counts') 'the list'
    if ("$($List.Format)" -ne '1') { & $fail "Format must be 1 (found '$($List.Format)')." }
    if ([string]$List.CreatedUtc -cnotmatch $isoUtc) { & $fail 'CreatedUtc must be a UTC time like 2026-11-03T10:00:00Z.' }
    $approvedBy = [string]$List.ApprovedBy
    if ($approvedBy.Length -lt 1 -or $approvedBy.Length -gt 100 -or $approvedBy -match $control) { & $fail 'ApprovedBy must be 1 to 100 characters with no control characters.' }
    if ([string]$List.Tenant -cnotmatch '\A[a-z0-9][a-z0-9-]{0,39}\z') { & $fail "Tenant must be a lowercase slug (found '$($List.Tenant)')." }
    if ([string]$List.ModuleVersion -notmatch '\A\d+(\.\d+){1,3}\z') { & $fail "ModuleVersion looks wrong ('$($List.ModuleVersion)')." }

    foreach ($side in 'Source', 'Target')
    {
        $s = $List.$side
        if ($null -eq $s) { & $fail "$side is missing." }
        & $checkNames $s @('Run', 'ExportedAt', 'Fingerprint') $side
        if ([string](Get-PEApprovedValue $s 'Run') -notmatch '\A\d{1,12}\z') { & $fail "$side.Run must be digits (a pipeline run id)." }
        if ([string](Get-PEApprovedValue $s 'ExportedAt') -cnotmatch $isoUtc) { & $fail "$side.ExportedAt must be a UTC time like 2026-11-03T10:00:00Z." }
        if ([string](Get-PEApprovedValue $s 'Fingerprint') -cnotmatch '\A[0-9a-f]{64}\z') { & $fail "$side.Fingerprint must be 64 lowercase hex characters." }
    }

    $items = @($List.Items)
    if ($items.Count -eq 0) { & $fail 'Items is empty.' }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $items)
    {
        & $checkNames $item @('Action', 'ResourceType', 'Key', 'ExcludedProperties') 'an item'
        $action = [string](Get-PEApprovedValue $item 'Action')
        $type = [string](Get-PEApprovedValue $item 'ResourceType')
        $key = [string](Get-PEApprovedValue $item 'Key')
        if ($action -cnotin 'Create', 'Update', 'Remove') { & $fail "unknown Action '$action'." }
        if ($type -cnotmatch '\A[A-Za-z][A-Za-z0-9]*\z') { & $fail "bad ResourceType '$type'." }
        if ($key.Length -lt 1 -or $key.Length -gt 500 -or $key -match $control) { & $fail "bad Key for $type (1 to 500 characters, one line, no control characters)." }
        foreach ($property in @(Get-PEApprovedValue $item 'ExcludedProperties'))
        {
            if ([string]$property -cnotmatch '\A[A-Za-z0-9_.]+\z') { & $fail "bad excluded property name '$property' on $type '$key'." }
        }
        if (-not $seen.Add("$action|$type|$key")) { & $fail "$action $type '$key' is listed twice." }
    }

    $expected = @(Get-PEApprovedCount -Item $items | ForEach-Object { "$($_.ResourceType)|$($_.Action)|$($_.Count)" })
    $counts = @($List.Counts)
    foreach ($row in $counts) { & $checkNames $row @('ResourceType', 'Action', 'Count') 'a Counts row' }
    $actual = @($counts | ForEach-Object { "$($_.ResourceType)|$($_.Action)|$($_.Count)" })
    if (($expected -join ';') -cne ($actual -join ';')) { & $fail 'Counts does not match the items.' }
}
