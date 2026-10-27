$script:PEKeyMap = $null
$script:PEIgnoredProperties = $null
$script:PEIgnoredPaths = $null
$script:PEExcludedTypes = $null

function Get-PEKeyMap
{
    [CmdletBinding()]
    param ()

    if ($null -eq $script:PEKeyMap)
    {
        $script:PEKeyMap = Import-PowerShellDataFile -Path (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'Data') 'KeyMap.psd1')
    }
    return $script:PEKeyMap
}

function Get-PEIgnoredProperties
{
    [CmdletBinding()]
    param ()

    if ($null -eq $script:PEIgnoredProperties)
    {
        $script:PEIgnoredProperties = Import-PowerShellDataFile -Path (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'Data') 'IgnoredProperties.psd1')
    }
    return $script:PEIgnoredProperties
}

function Get-PEIgnoredPath
{
    # The path entries of IgnoredProperties.psd1 (Global and ByType) that apply to a type, as
    # [pscustomobject]@{ Segments = string[]; When = $null | 'PastExport' }. A path entry is a dotted string
    # ('ScheduleInfo.startDateTime') or a hashtable @{ Path = '<path>'; When = 'PastExport' } (a conditional entry, which
    # may also be a single top-level name). Plain names without a dot are paths too when they are listed for this type
    # (ByType), so a state or blueprint stored before the name was listed does not report it as Changed; plain Global
    # names are not (ConvertTo-PENormalizedRecord drops them directly). Empty when the type has none. Cached per type
    # (case-insensitive). An empty segment ('A..b'), a hashtable without Path, or an unknown When is a data error and throws.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ResourceType,

        # The TenantBound section instead of Global/ByType; its plain names are paths too (they are applied at compare time,
        # not by ConvertTo-PENormalizedRecord).
        [switch]$TenantBound
    )

    if ($null -eq $script:PEIgnoredPaths)
    {
        $script:PEIgnoredPaths = [System.Collections.Generic.Dictionary[string, object[]]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }
    $cacheKey = if ($TenantBound) { 'tenant-bound|' + $ResourceType } else { $ResourceType }
    $cached = $null
    if ($script:PEIgnoredPaths.TryGetValue($cacheKey, [ref]$cached))
    {
        return , $cached
    }

    $ignored = Get-PEIgnoredProperties
    if ($TenantBound)
    {
        $ignored = if ($ignored.ContainsKey('TenantBound')) { $ignored.TenantBound } else { @{ Global = @(); ByType = @{} } }
    }
    $entries = @($ignored.Global)
    $globalCount = $entries.Count
    if ($ignored.ByType.ContainsKey($ResourceType))
    {
        $entries += @($ignored.ByType[$ResourceType])
    }
    $paths = [System.Collections.Generic.List[object]]::new()
    $position = -1
    foreach ($entry in $entries)
    {
        $position++
        $when = $null
        if ($entry -is [System.Collections.IDictionary])
        {
            $text = [string]$entry['Path']
            $when = [string]$entry['When']
            if ([string]::IsNullOrWhiteSpace($text))
            {
                throw 'IgnoredProperties.psd1: a conditional entry has no Path.'
            }
            if ([string]::IsNullOrWhiteSpace($when))
            {
                $when = $null
            }
            elseif ($when -ne 'PastExport')
            {
                throw "IgnoredProperties.psd1: unknown condition When = '$when' for '$text' (supported: PastExport)."
            }
        }
        else
        {
            $text = [string]$entry
            if (-not $text.Contains('.') -and -not $TenantBound -and $position -lt $globalCount)
            {
                continue
            }
        }
        $segments = $text.Split('.')
        foreach ($segment in $segments)
        {
            if ([string]::IsNullOrWhiteSpace($segment))
            {
                throw "IgnoredProperties.psd1: invalid property path '$text' (empty segment)."
            }
        }
        $paths.Add([pscustomobject]@{ Segments = [string[]]$segments; When = $when })
    }
    $result = $paths.ToArray()
    $script:PEIgnoredPaths[$cacheKey] = $result
    return , $result
}

function Get-PEIgnoredName
{
    # The plain (top-level, unconditional) names among ignore entries: strings without a dot. Dotted strings and
    # conditional hashtable entries are paths (Get-PEIgnoredPath).
    param
    (
        [object[]]$Entries
    )

    foreach ($entry in @($Entries))
    {
        if ($entry -is [string] -and -not $entry.Contains('.'))
        {
            $entry
        }
    }
}

function ConvertTo-PEDateTimeOffset
{
    # A DateTimeOffset from a DateTime, DateTimeOffset or an invariant date string (no offset = UTC); $null when the
    # value is empty or cannot be parsed.
    param
    (
        $Value
    )

    if ($null -eq $Value)
    {
        return $null
    }
    if ($Value -is [System.DateTimeOffset])
    {
        return $Value
    }
    if ($Value -is [datetime])
    {
        $d = if ($Value.Kind -eq 'Unspecified') { [datetime]::SpecifyKind($Value, 'Utc') } else { $Value }
        return [System.DateTimeOffset]::new($d)
    }
    $text = [string]$Value
    $parsed = [System.DateTimeOffset]::MinValue
    if (-not [string]::IsNullOrWhiteSpace($text) -and
        [System.DateTimeOffset]::TryParse($text, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed))
    {
        return $parsed
    }
    return $null
}

function Test-PEIgnoreCondition
{
    # Whether a conditional path may remove this value. PastExport (Microsoft365DSC's IgnoreWhenPast): the value is
    # empty, or a date at or before the record's export time. A future or unparseable date is kept.
    param
    (
        [string]$When,

        $Value,

        $ExportedAt
    )

    if ($When -ne 'PastExport')
    {
        return $true
    }
    if ($null -eq $Value -or ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)))
    {
        return $true
    }
    $date = ConvertTo-PEDateTimeOffset -Value $Value
    if ($null -eq $date)
    {
        return $false
    }
    return $date -le $ExportedAt
}

function Test-PEEmptyAfterRemoval
{
    # A container left by a path removal is empty when it has no members, or only the DSC parser's CIMInstance class
    # name (which carries no setting).
    param
    (
        [System.Collections.IDictionary]$Dictionary
    )

    foreach ($name in $Dictionary.get_Keys())
    {
        if (-not ([string]$name -ieq 'CIMInstance'))
        {
            return $false
        }
    }
    return $true
}

function Remove-PEPathCore
{
    # Removes the member at $Segments[$Index..] from $Value without modifying it. Returns
    # @{ Found; Value; Empty }: Found is $false (and Value the original) when the path does not exist, runs into a
    # scalar, or the condition ($When, see Test-PEIgnoreCondition) keeps the value; otherwise Value is a copy of every
    # container on the way (dictionaries become ordered dictionaries, PSCustomObjects stay PSCustomObjects, a
    # CimInstance becomes its member dictionary) and Empty says the removal left this object empty, so its parent
    # OBJECT drops it. Arrays apply the same segment to each element and keep every element, emptied or not, so the
    # array's length and order still compare; an array is never Empty.
    param
    (
        $Value,

        [string[]]$Segments,

        [int]$Index,

        [string]$When,

        $ExportedAt
    )

    $notFound = [pscustomobject]@{ Found = $false; Value = $Value; Empty = $false }
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType])
    {
        return $notFound
    }

    $isObject = $Value -is [System.Management.Automation.PSCustomObject]
    $members = $null
    if ($isObject -or $Value.GetType().FullName -eq 'Microsoft.Management.Infrastructure.CimInstance')
    {
        $members = ConvertTo-PEMemberDictionary -Value $Value
    }
    elseif ($Value -is [System.Collections.IDictionary])
    {
        $members = $Value
    }

    if ($null -ne $members)
    {
        $segment = $Segments[$Index]
        $match = $null
        foreach ($name in $members.get_Keys())
        {
            if ([string]$name -ieq $segment)
            {
                $match = $name
                break
            }
        }
        if ($null -eq $match)
        {
            return $notFound
        }

        $dropMember = $true
        $newChild = $null
        if ($Index -lt $Segments.Count - 1)
        {
            $child = Remove-PEPathCore -Value $members[$match] -Segments $Segments -Index ($Index + 1) -When $When -ExportedAt $ExportedAt
            if (-not $child.Found)
            {
                return $notFound
            }
            $dropMember = $child.Empty
            $newChild = $child.Value
        }
        elseif (-not (Test-PEIgnoreCondition -When $When -Value $members[$match] -ExportedAt $ExportedAt))
        {
            return $notFound
        }

        $copy = [ordered]@{}
        foreach ($name in $members.get_Keys())
        {
            if ([object]::Equals($name, $match))
            {
                if (-not $dropMember)
                {
                    $copy[$name] = $newChild
                }
                continue
            }
            $copy[$name] = $members[$name]
        }
        $empty = Test-PEEmptyAfterRemoval -Dictionary $copy
        $result = if ($isObject) { [pscustomobject]$copy } else { $copy }
        return [pscustomobject]@{ Found = $true; Value = $result; Empty = $empty }
    }

    if ($Value -is [System.Collections.IEnumerable])
    {
        $found = $false
        $elements = [System.Collections.Generic.List[object]]::new()
        foreach ($element in $Value)
        {
            $child = Remove-PEPathCore -Value $element -Segments $Segments -Index $Index -When $When -ExportedAt $ExportedAt
            if ($child.Found)
            {
                $found = $true
                # Kept even when emptied: dropping it would hide a change in the number of elements.
                $elements.Add($child.Value)
            }
            else
            {
                $elements.Add($element)
            }
        }
        if (-not $found)
        {
            return $notFound
        }
        return [pscustomobject]@{ Found = $true; Value = $elements.ToArray(); Empty = $false }
    }

    return $notFound
}

function Remove-PEIgnoredPath
{
    # Applies the ignore paths of a type (Get-PEIgnoredPath) to a property bag and returns the bag: the same object
    # when no path applies, otherwise a new ordered dictionary (the input is never modified). A top-level property
    # whose object value a removal leaves empty is dropped. Property names and path segments match case-insensitively.
    # Conditional (When = PastExport) paths need -ExportedAt (the export time of the state the record comes from); with
    # no usable -ExportedAt they are not applied at all.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ResourceType,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Properties,

        [AllowNull()]
        $ExportedAt,

        # Apply the TenantBound paths (Get-PEIgnoredPath -TenantBound) instead of the ignore paths.
        [switch]$TenantBound
    )

    $paths = Get-PEIgnoredPath -ResourceType $ResourceType -TenantBound:$TenantBound
    if ($paths.Count -eq 0)
    {
        return $Properties
    }
    $exportTime = ConvertTo-PEDateTimeOffset -Value $ExportedAt
    $result = $Properties
    foreach ($path in $paths)
    {
        if ($path.When -and $null -eq $exportTime)
        {
            continue
        }
        $outcome = Remove-PEPathCore -Value $result -Segments $path.Segments -Index 0 -When $path.When -ExportedAt $exportTime
        if ($outcome.Found)
        {
            # Remove-PEPathCore copied the top level into an ordered dictionary; an emptied record keeps an empty bag.
            $result = $outcome.Value
        }
    }
    return $result
}

function Get-PEExcludedTypeMap
{
    # ResourceType (case-insensitive) -> [pscustomobject]@{ Reason; RecordRule }, from Data\ExcludedTypes.psd1. An entry
    # is a reason string (the whole type is excluded) or @{ Reason = '...'; RecordRule = '<rule>' } (only the records the
    # rule does not keep are excluded; see Test-PERecordKeptByRule). Returns a new dictionary on every call, so a caller
    # may remove types from it (Compare-PEState -IncludeTypes).
    [CmdletBinding()]
    param ()

    if ($null -eq $script:PEExcludedTypes)
    {
        $script:PEExcludedTypes = Import-PowerShellDataFile -Path (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'Data') 'ExcludedTypes.psd1')
    }
    $map = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($type in $script:PEExcludedTypes.Types.get_Keys())
    {
        $entry = $script:PEExcludedTypes.Types[$type]
        if ($entry -is [System.Collections.IDictionary])
        {
            $rule = [string]$entry['RecordRule']
            $map[[string]$type] = [pscustomobject]@{ Reason = [string]$entry['Reason']; RecordRule = $(if ($rule) { $rule } else { $null }) }
        }
        else
        {
            $map[[string]$type] = [pscustomobject]@{ Reason = [string]$entry; RecordRule = $null }
        }
    }
    return , $map
}

function Get-PEKeyPart
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        $Properties,

        [Parameter(Mandatory)]
        [string]$Name
    )

    # Both Hashtable and OrderedDictionary expose Contains(); string keys compare case-insensitively.
    if (-not $Properties.Contains($Name))
    {
        return $null
    }
    $value = $Properties[$Name]
    # Arrays are never identities; skip them rather than joining.
    if ($null -eq $value -or $value -is [System.Collections.IEnumerable] -and $value -isnot [string])
    {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace([string]$value))
    {
        return $null
    }
    # Stored as exported; case-insensitive comparison is the matcher's job.
    return [string]$value
}

function Get-PEResourceKey
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$ResourceType,

        [Parameter(Mandatory)]
        $Properties
    )

    $map = Get-PEKeyMap
    # Hashtable literals from psd1 are case-insensitive, so the type lookup is too.
    # One-per-tenant types keyed by the tenant's own GUID get a fixed key so they match across tenants.
    if ($map.Singletons -contains $ResourceType)
    {
        return '(singleton)'
    }

    $hasOverride = $map.Overrides.ContainsKey($ResourceType)
    $candidates = if ($hasOverride) { @($map.Overrides[$ResourceType]) } else { @($map.Default) }

    # An override with several properties is a composite key: every part is required, escaped ('\' -> '\\', '|' -> '\|'), then joined with ' | '.
    if ($hasOverride -and $candidates.Count -gt 1)
    {
        $parts = [System.Collections.Generic.List[string]]::new()
        foreach ($name in $candidates)
        {
            $part = Get-PEKeyPart -Properties $Properties -Name $name
            if ($null -eq $part)
            {
                return $null
            }
            # Escape inside each part so no tuple of parts can produce the same joined key as another.
            $parts.Add($part.Replace('\', '\\').Replace('|', '\|'))
        }
        return ($parts -join ' | ')
    }

    foreach ($name in $candidates)
    {
        $part = Get-PEKeyPart -Properties $Properties -Name $name
        if ($null -ne $part)
        {
            return $part
        }
    }

    # Tenant-wide settings resources are keyed only by IsSingleInstance ('Yes'); give them a fixed key.
    if ($Properties.Contains('IsSingleInstance') -and [string]$Properties['IsSingleInstance'] -eq 'Yes')
    {
        return '(singleton)'
    }

    # No override and none of the usual names: use the key the DSC resource itself declares ([Key] properties in the
    # pinned module's schema), so a resource added by a module update is keyed without a code change. Id is never used
    # (it is the tenant's own GUID and is stripped from records); parts are sorted so the key does not depend on the
    # schema's order. Every part must be present, otherwise the record stays unkeyed.
    if (-not $hasOverride)
    {
        $schema = $null
        try { $schema = Get-PEDscResourceSchema -ResourceType $ResourceType } catch { $schema = $null }
        if ($null -ne $schema)
        {
            $keyNames = @($schema.Keys | Where-Object { $schema[$_] -eq 'Key' -and $_ -ine 'Id' -and $_ -ine 'IsSingleInstance' } | Sort-Object)
            if ($keyNames.Count -gt 0)
            {
                $parts = [System.Collections.Generic.List[string]]::new()
                foreach ($name in $keyNames)
                {
                    $part = Get-PEKeyPart -Properties $Properties -Name $name
                    if ($null -eq $part) { return $null }
                    $parts.Add($part.Replace('\', '\\').Replace('|', '\|'))
                }
                return ($parts -join ' | ')
            }
        }
    }
    return $null
}

function Get-PEKeyPartFromRecordKey
{
    # The value of one key property, read back from a record's own Key. Id (and every other name on the global ignore list) is removed from a
    # record, but when the key map builds the Key from that property (a single property, or one part of a composite ' | ' key) the value is
    # still in the Key: DSC needs it as a [Key] when the record is rendered into a configuration. $null when the key map does not build the
    # Key from that property.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$ResourceType,

        [Parameter(Mandatory)]
        [string]$Key,

        [Parameter(Mandatory)]
        [string]$Property
    )

    $map = Get-PEKeyMap
    if (-not $map.Overrides.ContainsKey($ResourceType))
    {
        return $null
    }
    $names = @($map.Overrides[$ResourceType])
    $position = -1
    for ($i = 0; $i -lt $names.Count; $i++)
    {
        if ([string]$names[$i] -ieq $Property) { $position = $i }
    }
    if ($position -lt 0)
    {
        return $null
    }
    if ($names.Count -eq 1)
    {
        return $Key
    }
    # Split on the unescaped ' | ' the composite key was joined with ('\' and '|' are escaped inside each part).
    $parts = [System.Collections.Generic.List[string]]::new()
    $current = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $Key.Length; $i++)
    {
        $c = $Key[$i]
        if ($c -eq '\' -and $i + 1 -lt $Key.Length)
        {
            [void]$current.Append($Key[$i + 1])
            $i++
        }
        elseif ($c -eq ' ' -and $i + 2 -lt $Key.Length -and $Key[$i + 1] -eq '|' -and $Key[$i + 2] -eq ' ')
        {
            $parts.Add($current.ToString())
            [void]$current.Clear()
            $i += 2
        }
        else
        {
            [void]$current.Append($c)
        }
    }
    $parts.Add($current.ToString())
    if ($parts.Count -ne $names.Count)
    {
        return $null
    }
    return $parts[$position]
}
function ConvertTo-PENormalizedRecord
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        $Record,

        # The export time of the state the record belongs to (Meta.ExportedAt). Conditional ignore paths
        # (When = 'PastExport') are applied only when it is given.
        [AllowNull()]
        $ExportedAt
    )

    $ignored = Get-PEIgnoredProperties
    $skip = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in (Get-PEIgnoredName -Entries $ignored.Global))
    {
        [void]$skip.Add($name)
    }
    if ($ignored.ByType.ContainsKey($Record.ResourceType))
    {
        foreach ($name in (Get-PEIgnoredName -Entries $ignored.ByType[$Record.ResourceType]))
        {
            [void]$skip.Add($name)
        }
    }

    # A type whose own Id is the DSC key keeps its Id (Data\IdentityReferences.psd1, OwnIds).
    if (Test-PEOwnIdType -ResourceType ([string]$Record.ResourceType))
    {
        [void]$skip.Remove('Id')
    }

    # Key is derived from the original properties, before the ignore list (which includes Id) is applied.
    $key = Get-PEResourceKey -ResourceType $Record.ResourceType -Properties $Record.Properties

    # Values are copied by reference: nested CIM instances and arrays pass through unchanged, except along a dotted
    # ignore path, where Remove-PEIgnoredPath copies the containers it changes (the input record is never modified).
    $properties = [ordered]@{}
    # get_Keys(): a property literally named 'Keys' would shadow the .Keys member on the property bag.
    foreach ($name in $Record.Properties.get_Keys())
    {
        if (-not $skip.Contains($name))
        {
            $properties[$name] = $Record.Properties[$name]
        }
    }
    $properties = Remove-PEIgnoredPath -ResourceType $Record.ResourceType -Properties $properties -ExportedAt $ExportedAt

    # TenantId is record metadata, not a comparison input; it is kept as-is on the top-level record.
    [pscustomobject]@{
        ResourceType = $Record.ResourceType
        Key          = $key
        Workload     = $Record.Workload
        TenantId     = $(if ($Record.PSObject.Properties['TenantId']) { $Record.TenantId } else { $null })
        Properties   = $properties
    }
}

function New-PEState
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Records,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$NotChecked,

        [Parameter(Mandatory)]
        [hashtable]$Meta
    )

    # Records are stored as given; callers normalise them with ConvertTo-PENormalizedRecord first.
    [pscustomobject]@{
        Records    = @($Records)
        NotChecked = @($NotChecked)
        Meta       = $Meta
    }
}
