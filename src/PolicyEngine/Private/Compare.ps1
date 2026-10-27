# Comparison helpers for Compare-PEState. Pure PowerShell; the hot paths (ConvertTo-PECanonicalValue,
# Get-PEPropertyDifference, Get-PESimilarityMap and the pair loop in Find-PERenameCandidate) are simple functions
# with the scalar cases inlined, because advanced-function calls dominate the cost at ~8,000 records per side.
#
# Value equality is defined by a canonical string form (ConvertTo-PECanonicalValue): two values are equal exactly
# when their canonical strings are equal (ordinal). The rules, chosen for Microsoft365DSC exports:
# - Empty values are all equal to $null: $null, '', an empty array, an empty hashtable or object, an object whose
#   members are all empty, and a collection whose elements are all empty (@($null, '') equals $null). A property
#   absent on one side therefore equals that property being empty on the other side, and a nested member that is
#   empty equals an absent member. A collection with an empty element next to a real one is NOT reduced:
#   @('x', $null) is the set {empty, 'x'} and does not equal 'x'.
# - Strings compare exactly (ordinal, case-sensitive, no trimming). Both sides come from the same DSC export parser,
#   so a case or whitespace change is a real change in the tenant.
# - Numbers compare by value across numeric types (Int32 1 equals Int64 1 and Double 1.0), because values read back
#   from JSON (decisions, stored blueprints) come back as Int64. A number never equals a string ('1' is not 1) and a
#   bool never equals a number or a string: types are kept strict apart from numeric width. A DateTime never equals
#   a date string, so stores must keep dates as strings (ConvertFrom-Json -DateKind String).
# - Arrays are sets: element order and duplicate elements are ignored, because DSC array properties (role lists,
#   included users, ...) are set-like. A one-element array equals its single element, as DSC treats 'x' and @('x')
#   the same for string[] parameters.
# - Dictionaries (DSC CIM instances parse to hashtables with a CIMInstance member), PSCustomObjects (the same data
#   after a JSON round trip) and real CimInstance objects compare member by member, recursively, with member names
#   matched case-insensitively and member order ignored.
# - Anything else compares by type name plus its invariant string form.
# - Record property names match case-insensitively. Record Properties may be an IDictionary (a fresh parse; PowerShell
#   hashtables and [ordered] dictionaries are case-insensitive) or a PSCustomObject (a state read back from JSON).
# - Unreadable values: the design says values DSC cannot read back (secrets) are never compared. The brief names no
#   unreadable marker or property list, and such properties (Credential, ApplicationSecret, CertificatePassword,
#   Password, ...) are removed by the ignore list in Data\IgnoredProperties.psd1, so no property is skipped here and no
#   'Unreadable' finding is produced yet.

# Rename detection compares every Missing record of a type with every TargetOnly record of that type. Above this many
# pairs (Missing x TargetOnly) for one type the similarity check is skipped: the records keep their Kind and get the
# hint below, so a mass change cannot make a check run for minutes. Script-scoped so tests can lower it.
$script:PERenameMaxPairs = 20000
$script:PERenameSkippedHint = 'Rename check skipped: too many candidates'

# Properties left out of rename similarity: Ensure is 'Present' on every exported record and says nothing about
# identity.
$script:PERenameIgnoredProperties = @('Ensure')

# Canonical form of an empty value.
$script:PEEmptyToken = 'null'

function ConvertTo-PECanonicalValue
{
    # Hot path: a simple (non-advanced) function. Callers and the loops below inline the scalar cases (null, string,
    # bool); keep those copies in step with the branches here.
    param
    (
        $Value
    )

    if ($null -eq $Value)
    {
        return 'null'
    }

    if ($Value -is [string])
    {
        if ($Value.Length -eq 0)
        {
            return 'null'
        }
        # Length-prefixed so separators inside a string can never collide with structure.
        return 's' + $Value.Length + ':' + $Value
    }

    if ($Value -is [bool])
    {
        if ($Value)
        {
            return 'b:1'
        }
        return 'b:0'
    }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [short] -or $Value -is [byte] -or
        $Value -is [sbyte] -or $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64] -or
        $Value -is [decimal])
    {
        # G29 drops trailing zeros of a decimal's scale, so 1 and 1.0m agree.
        return 'n:' + ([decimal]$Value).ToString('G29', [cultureinfo]::InvariantCulture)
    }

    if ($Value -is [double] -or $Value -is [single])
    {
        $d = [double]$Value
        if ([double]::IsFinite($d) -and [math]::Abs($d) -lt 7.9e28)
        {
            return 'n:' + ([decimal]$d).ToString('G29', [cultureinfo]::InvariantCulture)
        }
        return 'n:' + $d.ToString('R', [cultureinfo]::InvariantCulture)
    }

    if ($Value -is [System.Management.Automation.PSCustomObject] -or
        $Value.GetType().FullName -eq 'Microsoft.Management.Infrastructure.CimInstance')
    {
        $Value = ConvertTo-PEMemberDictionary -Value $Value
    }

    if ($Value -is [System.Collections.IDictionary])
    {
        $parts = [System.Collections.Generic.List[string]]::new()
        foreach ($name in $Value.get_Keys())
        {
            $v = $Value[$name]
            # Empty members are skipped: an empty member is the same as an absent one.
            if ($null -eq $v) { continue }
            elseif ($v -is [string]) { if ($v.Length -eq 0) { continue }; $c = 's' + $v.Length + ':' + $v }
            elseif ($v -is [bool]) { if ($v) { $c = 'b:1' } else { $c = 'b:0' } }
            else { $c = ConvertTo-PECanonicalValue $v; if ($c -ceq 'null') { continue } }
            $lower = ([string]$name).ToLowerInvariant()
            $parts.Add('k' + $lower.Length + ':' + $lower + '=' + $c)
        }
        if ($parts.Count -eq 0)
        {
            # An empty hashtable or object, or one whose members are all empty.
            return 'null'
        }
        $parts.Sort([System.StringComparer]::Ordinal)
        return 'h{' + ($parts -join ';') + '}'
    }

    if ($Value -is [System.Collections.IEnumerable])
    {
        # Set semantics: SortedSet orders the canonical elements and drops duplicates. An empty collection, or one
        # whose elements are all empty, collapses to 'null'; a one-element set equals its element.
        $set = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($v in $Value)
        {
            if ($null -eq $v) { $c = 'null' }
            elseif ($v -is [string]) { if ($v.Length -eq 0) { $c = 'null' } else { $c = 's' + $v.Length + ':' + $v } }
            elseif ($v -is [bool]) { if ($v) { $c = 'b:1' } else { $c = 'b:0' } }
            else { $c = ConvertTo-PECanonicalValue $v }
            [void]$set.Add($c)
        }
        if ($set.Count -eq 0)
        {
            return 'null'
        }
        if ($set.Count -eq 1)
        {
            return $set.Min
        }
        return 'a[' + ($set -join ',') + ']'
    }

    $typeName = $Value.GetType().FullName
    $text = [string]::Format([cultureinfo]::InvariantCulture, '{0}', $Value)
    return 'o' + $typeName.Length + ':' + $typeName + $text.Length + ':' + $text
}

function ConvertTo-PEMemberDictionary
{
    # PSCustomObject or CimInstance -> ordered dictionary of its members. A CimInstance gets its class name under
    # CIMInstance, matching the hashtable form the DSC parser produces.
    param
    (
        $Value
    )

    $result = [ordered]@{}
    if ($Value -is [System.Management.Automation.PSCustomObject])
    {
        foreach ($p in $Value.PSObject.Properties)
        {
            $result[$p.Name] = $p.Value
        }
    }
    else
    {
        $result['CIMInstance'] = $Value.CimSystemProperties.ClassName
        foreach ($p in $Value.CimInstanceProperties)
        {
            $result[$p.Name] = $p.Value
        }
    }
    return $result
}

function Test-PEValueEqual
{
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [AllowNull()]
        $A,

        [AllowNull()]
        $B
    )

    return (ConvertTo-PECanonicalValue $A) -ceq (ConvertTo-PECanonicalValue $B)
}

function Get-PEPropertyBag
{
    # A record's Properties as a case-insensitive IDictionary (a PSCustomObject from JSON is converted).
    param
    (
        $Record
    )

    $bag = $Record.Properties
    if ($null -eq $bag)
    {
        return [ordered]@{}
    }
    if ($bag -is [System.Collections.IDictionary])
    {
        return $bag
    }
    return ConvertTo-PEMemberDictionary -Value $bag
}

function Get-PEPropertyDifference
{
    # Property-level differences between two property bags (Get-PEPropertyBag), blueprint order first, as
    # [pscustomobject]@{Property; Blueprint; Target}. A property on one side only is a difference, with $null for the
    # absent side, unless its value is empty (then it equals the absent property). Hot path (once per matched key):
    # equal scalars are settled without building canonical strings.
    param
    (
        $Blueprint,

        $Target
    )

    $differences = [System.Collections.Generic.List[object]]::new()
    foreach ($name in $Blueprint.get_Keys())
    {
        $bv = $Blueprint[$name]
        $tv = $null
        if ($Target.Contains($name))
        {
            $tv = $Target[$name]
        }
        if ($bv -is [string] -and $tv -is [string])
        {
            if ([string]::Equals([string]$bv, [string]$tv, [System.StringComparison]::Ordinal)) { continue }
            if ($bv.Length -ne 0 -and $tv.Length -ne 0)
            {
                $differences.Add([pscustomobject]@{ Property = [string]$name; Blueprint = $bv; Target = $tv })
                continue
            }
        }
        elseif ($bv -is [bool] -and $tv -is [bool])
        {
            if ($bv -eq $tv) { continue }
            $differences.Add([pscustomobject]@{ Property = [string]$name; Blueprint = $bv; Target = $tv })
            continue
        }
        elseif ($null -eq $bv -and $null -eq $tv)
        {
            continue
        }
        if ((ConvertTo-PECanonicalValue $bv) -cne (ConvertTo-PECanonicalValue $tv))
        {
            $differences.Add([pscustomobject]@{ Property = [string]$name; Blueprint = $bv; Target = $tv })
        }
    }
    foreach ($name in $Target.get_Keys())
    {
        if ($Blueprint.Contains($name))
        {
            continue
        }
        $tv = $Target[$name]
        if ($null -eq $tv -or ($tv -is [string] -and $tv.Length -eq 0))
        {
            continue
        }
        if ((ConvertTo-PECanonicalValue $tv) -cne 'null')
        {
            $differences.Add([pscustomobject]@{ Property = [string]$name; Blueprint = $null; Target = $tv })
        }
    }
    return , $differences.ToArray()
}

function Get-PESimilarityMap
{
    # Property name -> canonical value for rename similarity, case-insensitive, leaving out empty values and the
    # properties in $script:PERenameIgnoredProperties. With empties left out, a property empty on both sides is
    # ignored, and a property empty on one side only counts in the union as unequal.
    param
    (
        $Record
    )

    $map = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $bag = Get-PEPropertyBag -Record $Record
    foreach ($name in $bag.get_Keys())
    {
        $name = [string]$name
        if ($script:PERenameIgnoredProperties -contains $name)
        {
            continue
        }
        $v = $bag[$name]
        if ($null -eq $v) { continue }
        elseif ($v -is [string]) { if ($v.Length -eq 0) { continue }; $c = 's' + $v.Length + ':' + $v }
        elseif ($v -is [bool]) { if ($v) { $c = 'b:1' } else { $c = 'b:0' } }
        else { $c = ConvertTo-PECanonicalValue $v; if ($c -ceq 'null') { continue } }
        $map[$name] = $c
    }
    return , $map
}

function Get-PESimilarity
{
    # Equal properties / union of property names, over two Get-PESimilarityMap maps. 0 when both are empty.
    # Find-PERenameCandidate inlines the same computation; keep them in step.
    param
    (
        $A,

        $B
    )

    $common = 0
    $equal = 0
    foreach ($name in $A.get_Keys())
    {
        if ($B.ContainsKey($name))
        {
            $common++
            if ($A[$name] -ceq $B[$name])
            {
                $equal++
            }
        }
    }
    $union = $A.get_Count() + $B.get_Count() - $common
    if ($union -eq 0)
    {
        return 0.0
    }
    return [double]$equal / $union
}

function Format-PERenameHint
{
    # 'Possible rename of k1, k2' in descending similarity (ties: key, ordinal), at most five keys plus ' and N more'.
    param
    (
        [System.Collections.Generic.List[object]]$Candidates
    )

    $sorted = [object[]]$Candidates.ToArray()
    $comparison = [System.Comparison[object]] {
        param ($x, $y)
        $c = $y.Similarity.CompareTo($x.Similarity)
        if ($c -ne 0) { return $c }
        return [string]::CompareOrdinal($x.Key, $y.Key)
    }
    [array]::Sort($sorted, $comparison)
    $shown = @($sorted | Select-Object -First 5 | ForEach-Object { $_.Key })
    $hint = 'Possible rename of ' + ($shown -join ', ')
    if ($sorted.Count -gt 5)
    {
        $hint += " and $($sorted.Count - 5) more"
    }
    return $hint
}

function Find-PERenameCandidate
{
    # Rename detection for one type. Every Missing x TargetOnly pair is scored; a record with at least one
    # counterpart of the opposite kind scoring >= Threshold gets a hint naming all such counterparts (no one-to-one
    # pairing: a similar TargetOnly must never stay removable). Returns
    # @{ Skipped; MissingHints; TargetHints } where the hint arrays run parallel to the inputs ($null = no candidate).
    # Skipped is $true, with no scoring, when the pair count exceeds $script:PERenameMaxPairs.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [object[]]$Missing,

        [Parameter(Mandatory)]
        [object[]]$TargetOnly,

        [Parameter(Mandatory)]
        [double]$Threshold
    )

    $missingHints = [string[]]::new($Missing.Count)
    $targetHints = [string[]]::new($TargetOnly.Count)
    if ($Missing.Count * $TargetOnly.Count -gt $script:PERenameMaxPairs)
    {
        return [pscustomobject]@{ Skipped = $true; MissingHints = $missingHints; TargetHints = $targetHints }
    }

    $missingMaps = [object[]]::new($Missing.Count)
    for ($i = 0; $i -lt $Missing.Count; $i++)
    {
        $missingMaps[$i] = Get-PESimilarityMap -Record $Missing[$i]
    }
    $targetMaps = [object[]]::new($TargetOnly.Count)
    for ($j = 0; $j -lt $TargetOnly.Count; $j++)
    {
        $targetMaps[$j] = Get-PESimilarityMap -Record $TargetOnly[$j]
    }
    $missingCandidates = [object[]]::new($Missing.Count)
    $targetCandidates = [object[]]::new($TargetOnly.Count)

    for ($i = 0; $i -lt $Missing.Count; $i++)
    {
        $a = $missingMaps[$i]
        for ($j = 0; $j -lt $TargetOnly.Count; $j++)
        {
            # Inlined Get-PESimilarity: this loop may run $script:PERenameMaxPairs times.
            $b = $targetMaps[$j]
            $common = 0
            $equal = 0
            foreach ($name in $a.get_Keys())
            {
                if ($b.ContainsKey($name))
                {
                    $common++
                    if ($a[$name] -ceq $b[$name])
                    {
                        $equal++
                    }
                }
            }
            $union = $a.get_Count() + $b.get_Count() - $common
            if ($union -eq 0)
            {
                continue
            }
            $similarity = [double]$equal / $union
            if ($similarity -lt $Threshold)
            {
                continue
            }
            if ($null -eq $missingCandidates[$i])
            {
                $missingCandidates[$i] = [System.Collections.Generic.List[object]]::new()
            }
            $missingCandidates[$i].Add([pscustomobject]@{ Key = [string]$TargetOnly[$j].Key; Similarity = $similarity })
            if ($null -eq $targetCandidates[$j])
            {
                $targetCandidates[$j] = [System.Collections.Generic.List[object]]::new()
            }
            $targetCandidates[$j].Add([pscustomobject]@{ Key = [string]$Missing[$i].Key; Similarity = $similarity })
        }
    }

    for ($i = 0; $i -lt $Missing.Count; $i++)
    {
        if ($null -ne $missingCandidates[$i])
        {
            $missingHints[$i] = Format-PERenameHint -Candidates $missingCandidates[$i]
        }
    }
    for ($j = 0; $j -lt $TargetOnly.Count; $j++)
    {
        if ($null -ne $targetCandidates[$j])
        {
            $targetHints[$j] = Format-PERenameHint -Candidates $targetCandidates[$j]
        }
    }
    return [pscustomobject]@{ Skipped = $false; MissingHints = $missingHints; TargetHints = $targetHints }
}

function Get-PEMatchKey
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$ResourceType,

        [Parameter(Mandatory)]
        [string]$Key
    )

    return $ResourceType.ToLowerInvariant() + '|' + $Key.ToLowerInvariant()
}

function Get-PERecordWorkload
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        $Record
    )

    if ($Record.PSObject.Properties['Workload'] -and $Record.Workload)
    {
        return [string]$Record.Workload
    }
    return Get-PEWorkload -ResourceType $Record.ResourceType
}

function New-PEFinding
{
    # Finding shape: Kind, ResourceType, Key, Workload, Differences (@{Property; Blueprint; Target}[]), Hint, State
    # ('Open' until an Unmanaged decision applies). Two extra properties carry the compared records so later steps
    # (Rectify, Task 10) can generate configuration without searching the states again:
    # - BlueprintRecord: the blueprint Record for this key (Missing, Changed, a PossibleRename built from a Missing
    #   record, a blueprint Unkeyed record); otherwise $null.
    # - TargetRecord: the target Record for this key (TargetOnly, Changed, a PossibleRename built from a TargetOnly
    #   record, a target Unkeyed record); otherwise $null.
    # Ambiguous, NotChecked, NotAvailable and Excluded findings carry neither: they must never be rectified.
    # - BlueprintCount / TargetCount: for Ambiguous findings, how many records on each side matched the key; for
    #   Excluded findings, how many records of the type each side has (integers; $null for every other Kind). They let
    #   the status report tell a blueprint-side Ambiguous finding (BlueprintCount > 0) from one that exists only in the
    #   target, without attaching records.
    # Kinds: Missing, Changed, TargetOnly, PossibleRename, Ambiguous, Unkeyed, NotChecked, NotAvailable, Excluded
    # (a type listed in Data\ExcludedTypes.psd1: one finding per type, Hint = the reason), and Unreadable (reserved;
    # not produced yet).
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [ValidateSet('Missing', 'Changed', 'TargetOnly', 'PossibleRename', 'Ambiguous', 'Unkeyed', 'NotChecked',
            'NotAvailable', 'Excluded', 'Unreadable')]
        [string]$Kind,

        [Parameter(Mandatory)]
        [string]$ResourceType,

        [AllowNull()]
        [string]$Key,

        [AllowNull()]
        [string]$Workload,

        [AllowNull()]
        [object[]]$Differences = @(),

        # Differences of properties excluded for the tenant (PropertyExcluded decisions): shown, not counted, never reverted.
        [AllowNull()]
        [object[]]$ExcludedDifferences = @(),

        [AllowNull()]
        [string]$Hint,

        [AllowNull()]
        $BlueprintRecord,

        [AllowNull()]
        $TargetRecord,

        [AllowNull()]
        [Nullable[int]]$BlueprintCount = $null,

        [AllowNull()]
        [Nullable[int]]$TargetCount = $null
    )

    [pscustomobject]@{
        Kind            = $Kind
        ResourceType    = $ResourceType
        Key             = $(if ([string]::IsNullOrEmpty($Key)) { $null } else { $Key })
        Workload        = $Workload
        Differences     = $(if ($null -eq $Differences) { @() } else { @($Differences) })
        ExcludedDifferences = $(if ($null -eq $ExcludedDifferences) { @() } else { @($ExcludedDifferences) })
        Hint            = $(if ([string]::IsNullOrEmpty($Hint)) { $null } else { $Hint })
        State           = 'Open'
        BlueprintRecord = $BlueprintRecord
        TargetRecord    = $TargetRecord
        BlueprintCount  = $BlueprintCount
        TargetCount     = $TargetCount
    }
}

function Get-PENotCheckedMap
{
    # ResourceType (case-insensitive) -> first entry's Reason. Accepts hashtables or objects with ResourceType/Reason.
    [CmdletBinding()]
    param
    (
        [AllowNull()]
        [object[]]$NotChecked
    )

    $map = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($NotChecked))
    {
        if ($null -eq $entry)
        {
            continue
        }
        $type = [string]$entry.ResourceType
        if ([string]::IsNullOrWhiteSpace($type) -or $map.ContainsKey($type))
        {
            continue
        }
        $map[$type] = [string]$entry.Reason
    }
    return , $map
}

function New-PEExclusionRuleContext
{
    # What a record rule needs to know about the whole state, computed once per state and rule.
    # KeepCustomRoleEntries: the names (case-insensitive) of the custom management roles of the state, i.e. its
    # EXOManagementRole records with a non-empty Parent (a custom role is always derived from a parent role).
    param
    (
        [string]$Rule,

        [object[]]$Records
    )

    switch ($Rule)
    {
        'KeepCustomRoleEntries'
        {
            $roles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($record in @($Records))
            {
                if ($null -eq $record -or [string]$record.ResourceType -ine 'EXOManagementRole')
                {
                    continue
                }
                $bag = Get-PEPropertyBag -Record $record
                $parent = if ($bag.Contains('Parent')) { [string]$bag['Parent'] } else { '' }
                if ([string]::IsNullOrWhiteSpace($parent))
                {
                    continue
                }
                $name = if ($bag.Contains('Name') -and -not [string]::IsNullOrWhiteSpace([string]$bag['Name'])) { [string]$bag['Name'] } else { [string]$record.Key }
                if (-not [string]::IsNullOrWhiteSpace($name))
                {
                    [void]$roles.Add($name)
                }
            }
            return , $roles
        }
        default
        {
            throw "ExcludedTypes.psd1: unknown RecordRule '$Rule'."
        }
    }
}

function Test-PERecordKeptByRule
{
    # Whether a record of a type with a RecordRule stays compared (not excluded).
    # KeepCustomRoleEntries (EXOManagementRoleEntry): an entry is kept when its role, the part of Identity (the record
    # key) before the first '\', is a custom role of the same state; entries of built-in roles are excluded.
    param
    (
        [string]$Rule,

        $Context,

        $Record
    )

    switch ($Rule)
    {
        'KeepCustomRoleEntries'
        {
            $identity = [string]$Record.Key
            if ([string]::IsNullOrWhiteSpace($identity))
            {
                $bag = Get-PEPropertyBag -Record $Record
                $identity = if ($bag.Contains('Identity')) { [string]$bag['Identity'] } else { '' }
            }
            $slash = $identity.IndexOf('\')
            if ($slash -le 0)
            {
                return $false
            }
            return $Context.Contains($identity.Substring(0, $slash))
        }
        default
        {
            throw "ExcludedTypes.psd1: unknown RecordRule '$Rule'."
        }
    }
}

function Select-PEComparedRecord
{
    # Splits a state's records by the exclusion map (Get-PEExcludedTypeMap, possibly reduced): returns
    # @{ Kept = object[]; ExcludedCounts = Dictionary[type, int] }. A type without a RecordRule is excluded whole; a type
    # with one keeps the records its rule keeps (evaluated against this state's own records).
    [CmdletBinding()]
    param
    (
        [AllowNull()]
        [object[]]$Records,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.Dictionary[string, object]]$Excluded
    )

    $kept = [System.Collections.Generic.List[object]]::new()
    $counts = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $contexts = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($record in @($Records))
    {
        if ($null -eq $record)
        {
            continue
        }
        $type = [string]$record.ResourceType
        $entry = $null
        if ($Excluded.Count -eq 0 -or -not $Excluded.TryGetValue($type, [ref]$entry))
        {
            $kept.Add($record)
            continue
        }
        if ($entry.RecordRule)
        {
            $context = $null
            if (-not $contexts.TryGetValue($entry.RecordRule, [ref]$context))
            {
                $context = New-PEExclusionRuleContext -Rule $entry.RecordRule -Records $Records
                $contexts[$entry.RecordRule] = $context
            }
            if (Test-PERecordKeptByRule -Rule $entry.RecordRule -Context $context -Record $record)
            {
                $kept.Add($record)
                continue
            }
        }
        $current = 0
        [void]$counts.TryGetValue($type, [ref]$current)
        $counts[$type] = $current + 1
    }
    return [pscustomobject]@{ Kept = $kept.ToArray(); ExcludedCounts = $counts }
}

function Get-PERecordIndex
{
    # Groups keyed records by match key (type and key, lower-cased). Records of skipped types are ignored; records
    # without a key become Unkeyed findings.
    [CmdletBinding()]
    param
    (
        [AllowNull()]
        [object[]]$Records,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$SkipTypes,

        [Parameter(Mandatory)]
        [ValidateSet('Blueprint', 'Target')]
        [string]$Side,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Findings
    )

    $index = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new([System.StringComparer]::Ordinal)
    foreach ($record in @($Records))
    {
        if ($null -eq $record)
        {
            continue
        }
        $type = [string]$record.ResourceType
        if ($SkipTypes.Contains($type))
        {
            continue
        }
        $key = [string]$record.Key
        if ([string]::IsNullOrWhiteSpace($key))
        {
            $finding = New-PEFinding -Kind 'Unkeyed' -ResourceType $type -Key $null -Workload (Get-PERecordWorkload -Record $record) -Hint "$Side record has no key; it cannot be matched"
            if ($Side -eq 'Blueprint')
            {
                $finding.BlueprintRecord = $record
            }
            else
            {
                $finding.TargetRecord = $record
            }
            $Findings.Add($finding)
            continue
        }
        # Same form as Get-PEMatchKey, inlined because this runs once per record.
        $matchKey = $type.ToLowerInvariant() + '|' + $key.ToLowerInvariant()
        if (-not $index.ContainsKey($matchKey))
        {
            $index[$matchKey] = [System.Collections.Generic.List[object]]::new()
        }
        $index[$matchKey].Add($record)
    }
    return , $index
}

function Test-PECrossTenant
{
    # True when a target tenant is a different tenant from the one a blueprint was taken from, so properties that belong to
    # one tenant (Data\IgnoredProperties.psd1, TenantBound) cannot match. Both ids must be known and differ (case-insensitive);
    # an unknown id ('unknown', empty) means "not known to be another tenant" and the properties are compared.
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [AllowNull()]
        [AllowEmptyString()]
        [string]$BlueprintTenantId,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$TargetTenantId
    )

    foreach ($id in $BlueprintTenantId, $TargetTenantId)
    {
        if ([string]::IsNullOrWhiteSpace($id) -or $id -eq 'unknown')
        {
            return $false
        }
    }
    return ($BlueprintTenantId.Trim() -ne $TargetTenantId.Trim())
}

function Get-PETenantShortName
{
    # The first label of a tenant domain ('contoso' of 'contoso.onmicrosoft.com'), or '' when the id names no
    # domain (a GUID, 'unknown', empty): such an id cannot be found in a value.
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [AllowNull()]
        [AllowEmptyString()]
        [string]$TenantId
    )

    if ([string]::IsNullOrWhiteSpace($TenantId) -or $TenantId.IndexOf('.') -lt 1) { return '' }
    return $TenantId.Trim().Split('.')[0]
}

function Convert-PETenantName
{
    # A copy of a property value with one tenant's own short name replaced by another's, in every string at any depth
    # (arrays, dictionaries, PSCustomObjects and CimInstances are rebuilt; scalars other than strings are returned as
    # they are). The name is replaced only where it is the tenant's own label of a Microsoft tenant host:
    # <name>[-admin|-my|...].sharepoint.com, <name>.onmicrosoft.com or <name>.mail.onmicrosoft.com, so never in a custom
    # domain, a path or free text. It matches case-insensitively, and the replacement takes the case of what it replaces
    # when that was all lower or all upper case.
    param
    (
        $Value,

        [string]$From,

        [string]$To
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [string])
    {
        $pattern = '(?<![A-Za-z0-9])' + [regex]::Escape($From) + '(?=(?:-[A-Za-z0-9]+)?\.(?:mail\.)?(?:sharepoint|onmicrosoft)\.com(?![A-Za-z0-9-]|\.[A-Za-z0-9]))'
        return [regex]::Replace($Value, $pattern, { param ($m) if ($m.Value -ceq $m.Value.ToUpperInvariant() -and $m.Value -cne $m.Value.ToLowerInvariant()) { $To.ToUpperInvariant() } elseif ($m.Value -ceq $m.Value.ToLowerInvariant()) { $To.ToLowerInvariant() } else { $To } }.GetNewClosure(), 'IgnoreCase')
    }
    if ($Value -is [System.Collections.IDictionary])
    {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) { $copy[$key] = Convert-PETenantName -Value $Value[$key] -From $From -To $To }
        return $copy
    }
    if ($Value -is [System.Management.Automation.PSCustomObject] -or $Value -is [Microsoft.Management.Infrastructure.CimInstance])
    {
        return (Convert-PETenantName -Value (ConvertTo-PEMemberDictionary -Value $Value) -From $From -To $To)
    }
    if ($Value -is [System.Collections.IEnumerable])
    {
        return , @(foreach ($element in $Value) { Convert-PETenantName -Value $element -From $From -To $To })
    }
    return $Value
}

function Remove-PETenantNameDifference
{
    # Drops the differences that exist only because the target is another tenant: the target's value, with its own tenant's
    # short name replaced by the blueprint tenant's, equals the blueprint's. Differences left (a value that still differs, or
    # one with nothing to replace) are returned as they were, with the target's original value.
    param
    (
        $Difference,

        [string]$BlueprintName,

        [string]$TargetName
    )

    return , @(foreach ($d in @($Difference))
        {
            if ($null -ne $d.Target -and $null -ne $d.Blueprint)
            {
                $translated = Convert-PETenantName -Value $d.Target -From $TargetName -To $BlueprintName
                if ((ConvertTo-PECanonicalValue $translated) -ceq (ConvertTo-PECanonicalValue $d.Blueprint)) { continue }
            }
            $d
        })
}
