# Helpers for Public\Rectify.ps1: rendering record values as DSC configuration text, instance names, the clock, the
# safety check of generated text, and the registries that bind plan items and generated configurations to
# New-PERectifyPlan / ConvertTo-PEDscConfig.
#
# Why not DSCParser's ConvertFrom-DSCObject: in DSCParser 3.1.0.7 it writes every string in double quotes without
# escaping '$' ("O'Brien $x" stays an expandable string) and writes a string that starts with '$' as a bare
# expression, so a tenant value could become code in the generated configuration. Values are rendered here instead
# (see ConvertTo-PEDscStringLiteral), and the generated text is pure ASCII so that it means the same thing however the
# file is decoded: Windows PowerShell 5.1 reads a BOM-less file as the ANSI code page, where the UTF-8 bytes of U+00D1
# (C3 91) become U+00C3 U+2018, and U+2018 is a single-quote token that would end a literal.

# Matched with -cmatch; \z (not $) so a trailing newline never passes.
$script:PEIdentifierPattern = '\A[A-Za-z_][A-Za-z0-9_]*\z'
$script:PEResourceTypePattern = '\A[A-Za-z][A-Za-z0-9]*\z'
$script:PEInstanceNamePattern = '\A[A-Za-z0-9_.-]+\z'

# Size limits checked before any text is generated or parsed: very long values make the PowerShell parser and the DSC
# compiler slow, and deep enough expressions overflow their stacks (which cannot be caught).
$script:PEMaxStringLength = 131072
$script:PEMaxArrayElements = 2000

# The export writes the tenant's domain as this variable inside double-quoted strings ("admin@$OrganizationName") and
# DSCParser returns the text unexpanded, so a record value containing it must stay a variable reference.
$script:PEOrganizationToken = '$OrganizationName'
# The export also writes the tenant's GUID as $($ConfigurationData.NonNodeData.TenantGuid) (role management rule ids, group addresses, tab links): rendered as $TenantGuid.
$script:PEStringRunPattern = '(?<org>\$OrganizationName)|(?<guid>\$\(\$ConfigurationData\.NonNodeData\.TenantGuid\))|(?<lit>(?:(?!\$OrganizationName|\$\(\$ConfigurationData\.NonNodeData\.TenantGuid\))[\x20-\x7E])+)|(?<ch>[^\x20-\x7E]+)'

# Plan items issued by New-PERectifyPlan in this process: item object (by reference) -> @{ Fingerprint; Snapshot }.
# The snapshot is a frozen copy of everything ConvertTo-PEDscConfig renders and Save-PEAudit records, taken when the
# item is issued; the fingerprint is the strict hash of that snapshot. Both functions accept only registered items whose
# current content still has the same fingerprint, and then work ONLY from the stored snapshot, never from the item, so
# getters or ScriptProperties swapped in after validation cannot change what is rendered or audited. A hand-built item,
# a copy (Select-Object *) or an item read back from JSON is not registered. Entries go away with the items.
$script:PEPlanRegistry = [System.Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()

# Configurations returned by ConvertTo-PEDscConfig in this process: SHA-256 of the exact text -> list of registrations
# @{ Plan (sorted item fingerprints, joined); ConfigurationName; Target }. Several plans may produce identical text, so
# a hash keeps every registration. Only the most recent $script:PEConfigRegistryLimit registrations are kept (oldest
# dropped first); Save-PEAudit refuses a configuration whose registration has been dropped.
$script:PEConfigRegistryLimit = 100
$script:PEConfigRegistry = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new([System.StringComparer]::Ordinal)
$script:PEConfigRegistryOrder = [System.Collections.Generic.Queue[object]]::new()
# Text hashes whose registration was evicted (only used to explain a refusal).
$script:PEConfigEvicted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

# Upper bound on the generated configuration text, checked as resource blocks are added and before anything is parsed
# (a non-ASCII character costs about 14 characters of output, so many long values can reach gigabytes of parser memory).
$script:PEMaxConfigLength = 8MB

function Test-PEDscConfigEvicted
{
    # True when a registration of this exact text was evicted by the registry limit.
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Text
    )

    $hash = Get-PETextSha256 -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($Text))
    return $script:PEConfigEvicted.Contains($hash)
}

function Get-PEUtcNow
{
    # The clock, as a function so tests can mock it.
    [CmdletBinding()]
    [OutputType([datetime])]
    param ()

    return [datetime]::UtcNow
}

function Get-PETextSha256
{
    # Upper-case hex SHA-256 of a byte array.
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [byte[]]$Bytes
    )

    return [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($Bytes))
}

function Copy-PEFrozenValue
{
    # A deep copy of a record value, made once, so later changes to the caller's objects (or getters, ScriptProperties
    # and custom IDictionary indexers that return different values on each read) cannot change what is rendered.
    # Dictionaries, PSCustomObjects and CimInstances become [ordered] dictionaries (member order kept); collections
    # become object[] (element order kept); strings, numbers, booleans and enums are immutable and kept; anything else is
    # kept as is (the renderer refuses it).
    param
    (
        $Value
    )

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool] -or $Value -is [ValueType])
    {
        return , $Value
    }
    if ($Value -is [System.Management.Automation.PSCustomObject] -or
        $Value.GetType().FullName -eq 'Microsoft.Management.Infrastructure.CimInstance')
    {
        $Value = ConvertTo-PEMemberDictionary -Value $Value
    }
    if ($Value -is [System.Collections.IDictionary])
    {
        $copy = [ordered]@{}
        foreach ($name in @($Value.get_Keys()))
        {
            $copy[[string]$name] = Copy-PEFrozenValue $Value[$name]
        }
        return , $copy
    }
    if ($Value -is [System.Collections.IEnumerable])
    {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($element in $Value)
        {
            $list.Add((Copy-PEFrozenValue $element))
        }
        return , $list.ToArray()
    }
    return , $Value
}

function Copy-PEFrozenRecord
{
    # A frozen copy of a record: ResourceType, Key, Workload and deep-copied Properties (read once).
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        $Record
    )

    [pscustomobject]@{
        ResourceType = [string]$Record.ResourceType
        Key          = [string]$Record.Key
        Workload     = [string]$Record.Workload
        Properties   = Copy-PEFrozenValue (Get-PEPropertyBag -Record $Record)
    }
}

function ConvertTo-PEUtf16Bytes
{
    # The exact UTF-16 code units of a string as little-endian bytes, with no encoder: an encoder's replacement
    # fallback would turn every lone surrogate into U+FFFD.
    [CmdletBinding()]
    [OutputType([byte[]])]
    param
    (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $chars = $Text.ToCharArray()
    $bytes = [byte[]]::new($chars.Length * 2)
    [System.Buffer]::BlockCopy($chars, 0, $bytes, 0, $bytes.Length)
    return , $bytes
}

function Write-PEStrictValue
{
    # A strict serialisation, emitted piece by piece to Sink (a script block taking one string): unlike the comparison
    # canonical form it keeps types ('' is not $null, @() is not $null, 1 is not '1'), dictionary member order and array
    # element order. Pieces keep the whole value from ever being built as one string.
    param
    (
        $Value,

        [scriptblock]$Sink
    )

    if ($null -eq $Value)
    {
        & $Sink 'N'
        return
    }
    if ($Value -is [string])
    {
        & $Sink ('S' + $Value.Length + ':')
        & $Sink $Value
        return
    }
    if ($Value -is [bool])
    {
        if ($Value) { & $Sink 'B1' } else { & $Sink 'B0' }
        return
    }
    if ($Value -is [enum])
    {
        $text = $Value.ToString()
        & $Sink ('E' + $Value.GetType().FullName + ':' + $text.Length + ':' + $text)
        return
    }
    if ($Value -is [System.Management.Automation.PSCustomObject] -or
        $Value.GetType().FullName -eq 'Microsoft.Management.Infrastructure.CimInstance')
    {
        $Value = ConvertTo-PEMemberDictionary -Value $Value
    }
    if ($Value -is [System.Collections.IDictionary])
    {
        & $Sink 'H{'
        $first = $true
        foreach ($name in @($Value.get_Keys()))
        {
            if (-not $first) { & $Sink ';' }
            $first = $false
            Write-PEStrictValue ([string]$name) $Sink
            & $Sink '='
            Write-PEStrictValue $Value[$name] $Sink
        }
        & $Sink '}'
        return
    }
    if ($Value -is [System.Collections.IEnumerable])
    {
        & $Sink 'A['
        $first = $true
        foreach ($element in $Value)
        {
            if (-not $first) { & $Sink ',' }
            $first = $false
            Write-PEStrictValue $element $Sink
        }
        & $Sink ']'
        return
    }
    $text = [string]::Format([cultureinfo]::InvariantCulture, '{0}', $Value)
    if ($Value -is [double] -or $Value -is [single])
    {
        $text = ([double]$Value).ToString('R', [cultureinfo]::InvariantCulture)
    }
    & $Sink ('O' + $Value.GetType().FullName + ':' + $text.Length + ':' + $text)
}

function ConvertTo-PEStrictText
{
    # The strict serialisation (Write-PEStrictValue) as one string. Used by tests to compare records.
    param
    (
        $Value
    )

    $peStrictBuilder = [System.Text.StringBuilder]::new()
    Write-PEStrictValue $Value { param ($piece) [void]$peStrictBuilder.Append($piece) }
    return $peStrictBuilder.ToString()
}
function Get-PEPlanItemSnapshot
{
    # A frozen copy of everything ConvertTo-PEDscConfig renders and Save-PEAudit records for a plan item. Each member of
    # the item (Record, Record.Properties, Finding, Finding.Differences, SourceIdentity) is read exactly once.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        $Item
    )

    $record = $Item.Record
    $finding = $Item.Finding
    $identity = $Item.SourceIdentity

    $recordCopy = if ($null -eq $record) { $null } else { Copy-PEFrozenRecord -Record $record }
    $findingCopy = $null
    if ($null -ne $finding)
    {
        $differences = @(@($finding.Differences) | Where-Object { $null -ne $_ })
        $findingCopy = [pscustomobject]@{
            Kind              = [string]$finding.Kind
            State             = [string]$finding.State
            Hint              = $(if ($finding.Hint) { [string]$finding.Hint } else { $null })
            ChangedProperties = [string[]]@($differences | ForEach-Object { [string]$_.Property })
            DifferenceCount   = $differences.Count
        }
    }
    $identityCopy = $null
    if ($null -ne $identity)
    {
        $identityCopy = [pscustomobject]@{
            ExportedAt          = $(if ($identity.ExportedAt) { [string]$identity.ExportedAt } else { $null })
            TenantId            = $(if ($identity.TenantId) { [string]$identity.TenantId } else { $null })
            Source              = $(if ($identity.Source) { [string]$identity.Source } else { $null })
            BlueprintVersion    = $(if ($null -ne $identity.BlueprintVersion) { [int]$identity.BlueprintVersion } else { $null })
            BlueprintExportedAt = $(if ($identity.BlueprintExportedAt) { [string]$identity.BlueprintExportedAt } else { $null })
        }
    }

    [pscustomobject]@{
        Action            = [string]$Item.Action
        ResourceType      = [string]$Item.ResourceType
        Key               = [string]$Item.Key
        Workload          = [string]$Item.Workload
        ConfirmNotRenamed = [bool]$Item.ConfirmNotRenamed
        Record            = $recordCopy
        Finding           = $findingCopy
        SourceIdentity    = $identityCopy
    }
}

function Get-PEPlanSnapshotFingerprint
{
    # Strict hash of a snapshot (Get-PEPlanItemSnapshot).
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        $Snapshot
    )

    # Hashed incrementally over the exact UTF-16 code units of each piece: no giant string, and no encoder that could
    # map different lone surrogates to the same bytes.
    $peStrictHash = [System.Security.Cryptography.IncrementalHash]::CreateHash([System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try
    {
        Write-PEStrictValue $Snapshot { param ($piece) $peStrictHash.AppendData((ConvertTo-PEUtf16Bytes -Text $piece)) }
        return [System.Convert]::ToHexString($peStrictHash.GetHashAndReset())
    }
    finally
    {
        $peStrictHash.Dispose()
    }
}

function Get-PEStateIndex
{
    # Keyed records of a state by match key (Get-PEMatchKey) -> list of records.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        $State
    )

    $index = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new([System.StringComparer]::Ordinal)
    foreach ($record in @($State.Records))
    {
        if ($null -eq $record -or [string]::IsNullOrWhiteSpace([string]$record.Key) -or [string]::IsNullOrWhiteSpace([string]$record.ResourceType))
        {
            continue
        }
        $matchKey = Get-PEMatchKey -ResourceType ([string]$record.ResourceType) -Key ([string]$record.Key)
        if (-not $index.ContainsKey($matchKey))
        {
            $index[$matchKey] = [System.Collections.Generic.List[object]]::new()
        }
        $index[$matchKey].Add($record)
    }
    return , $index
}

function Register-PEPlanItem
{
    # Marks a plan item as issued by New-PERectifyPlan and stores its snapshot (tests register hand-built items through
    # InModuleScope).
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        $Item
    )

    $snapshot = Get-PEPlanItemSnapshot -Item $Item
    $entry = [pscustomobject]@{ Fingerprint = (Get-PEPlanSnapshotFingerprint -Snapshot $snapshot); Snapshot = $snapshot }
    $script:PEPlanRegistry.AddOrUpdate($Item, $entry)
}

function Assert-PEPlanItem
{
    # Throws unless Item was issued by New-PERectifyPlan in this process and has not been changed since. Returns the
    # registry entry (Fingerprint, Snapshot); callers use the stored snapshot only.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        $Item
    )

    $entry = $null
    if ($Item -isnot [System.Management.Automation.PSObject] -or -not $script:PEPlanRegistry.TryGetValue($Item, [ref]$entry))
    {
        throw "Plan item $($Item.Action) $($Item.ResourceType) '$($Item.Key)' was not produced by New-PERectifyPlan in this session."
    }
    $current = Get-PEPlanSnapshotFingerprint -Snapshot (Get-PEPlanItemSnapshot -Item $Item)
    if ($entry.Fingerprint -cne $current)
    {
        throw "Plan item $($Item.Action) $($Item.ResourceType) '$($Item.Key)' was changed after New-PERectifyPlan produced it."
    }
    return $entry
}

function Get-PEPlanSnapshotSet
{
    # Validates plan items and returns @{ Plan = sorted fingerprints joined (identifies the plan independent of item
    # order); Snapshots = the stored snapshots, in the given order }.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [object[]]$Items
    )

    $prints = [System.Collections.Generic.List[string]]::new()
    $snapshots = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $Items)
    {
        $entry = Assert-PEPlanItem -Item $item
        $prints.Add($entry.Fingerprint)
        $snapshots.Add($entry.Snapshot)
    }
    $prints.Sort([System.StringComparer]::Ordinal)
    [pscustomobject]@{ Plan = ($prints -join ','); Snapshots = $snapshots.ToArray() }
}

function Register-PEDscConfig
{
    # Records that ConvertTo-PEDscConfig returned Text for this plan, configuration name and target. Keeps every
    # registration per text hash, and only the most recent $script:PEConfigRegistryLimit registrations overall.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [string]$PlanFingerprint,

        [Parameter(Mandatory)]
        [string]$ConfigurationName,

        [Parameter(Mandatory)]
        [string]$Target
    )

    $hash = Get-PETextSha256 -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($Text))
    $entry = [pscustomobject]@{ Plan = $PlanFingerprint; ConfigurationName = $ConfigurationName; Target = $Target }
    if (-not $script:PEConfigRegistry.ContainsKey($hash))
    {
        $script:PEConfigRegistry[$hash] = [System.Collections.Generic.List[object]]::new()
    }
    $script:PEConfigRegistry[$hash].Add($entry)
    $script:PEConfigRegistryOrder.Enqueue([pscustomobject]@{ Hash = $hash; Entry = $entry })
    while ($script:PEConfigRegistryOrder.Count -gt $script:PEConfigRegistryLimit)
    {
        $oldest = $script:PEConfigRegistryOrder.Dequeue()
        # Remembered only to explain a later refusal; never to accept anything. Bounded like the registry itself.
        if ($script:PEConfigEvicted.Count -ge 10 * $script:PEConfigRegistryLimit)
        {
            $script:PEConfigEvicted.Clear()
        }
        [void]$script:PEConfigEvicted.Add($oldest.Hash)
        $list = $null
        if ($script:PEConfigRegistry.TryGetValue($oldest.Hash, [ref]$list))
        {
            [void]$list.Remove($oldest.Entry)
            if ($list.Count -eq 0)
            {
                [void]$script:PEConfigRegistry.Remove($oldest.Hash)
            }
        }
    }
}

function Get-PEDscConfigRegistration
{
    # The most recent registration of a configuration text generated from exactly this plan, or $null.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [string]$PlanFingerprint
    )

    $hash = Get-PETextSha256 -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($Text))
    $list = $null
    if (-not $script:PEConfigRegistry.TryGetValue($hash, [ref]$list))
    {
        return $null
    }
    for ($i = $list.Count - 1; $i -ge 0; $i--)
    {
        if ($list[$i].Plan -ceq $PlanFingerprint)
        {
            return $list[$i]
        }
    }
    return $null
}

function Assert-PEDscValueAst
{
    # Allowlist for a property value inside a resource block, exactly the forms the generator emits:
    # - 'single-quoted string', a number (optionally negated), $true, $false;
    # - $ConfigurationData.NonNodeData.<ApplicationId|TenantId|CertificateThumbprint>;
    # - (-join @(<elements>)) where each element is a 'single-quoted string', [char]<integer> or $OrganizationName;
    # - @() and @(<value> <value> ...) whose elements are allowed values;
    # - a CIM instance block ClassName{ Name = <value> ... } of a known Microsoft365DSC class.
    # Anything else throws.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        $Node,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($Node -is [System.Management.Automation.Language.PipelineAst])
    {
        if ($Node.PipelineElements.Count -ne 1 -or $Node.PipelineElements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst] -or
            $Node.PipelineElements[0].Redirections.Count -ne 0)
        {
            throw "Disallowed value at $Path`: $($Node.Extent.Text)"
        }
        Assert-PEDscValueAst -Node $Node.PipelineElements[0].Expression -Path $Path
        return
    }
    if ($Node -is [System.Management.Automation.Language.StringConstantExpressionAst])
    {
        if ($Node.StringConstantType -ne [System.Management.Automation.Language.StringConstantType]::SingleQuoted)
        {
            throw "Disallowed value at $Path`: $($Node.Extent.Text)"
        }
        return
    }
    if ($Node -is [System.Management.Automation.Language.ConstantExpressionAst])
    {
        if ($Node.Value -isnot [int] -and $Node.Value -isnot [long] -and $Node.Value -isnot [double] -and $Node.Value -isnot [decimal])
        {
            throw "Disallowed value at $Path`: $($Node.Extent.Text)"
        }
        return
    }
    if ($Node -is [System.Management.Automation.Language.UnaryExpressionAst] -and
        $Node.TokenKind -eq [System.Management.Automation.Language.TokenKind]::Minus -and
        $Node.Child -is [System.Management.Automation.Language.ConstantExpressionAst] -and
        $Node.Child -isnot [System.Management.Automation.Language.StringConstantExpressionAst])
    {
        Assert-PEDscValueAst -Node $Node.Child -Path $Path
        return
    }
    if ($Node -is [System.Management.Automation.Language.VariableExpressionAst])
    {
        if ($Node.Splatted -or [string]$Node.VariablePath.UserPath -notin 'true', 'false')
        {
            throw "Disallowed value at $Path`: $($Node.Extent.Text)"
        }
        return
    }
    if ($Node -is [System.Management.Automation.Language.MemberExpressionAst])
    {
        $inner = $Node.Expression
        if (-not $Node.Static -and $Node -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $Node.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            [string]$Node.Member.Value -cin 'ApplicationId', 'TenantId', 'CertificateThumbprint' -and
            $inner -is [System.Management.Automation.Language.MemberExpressionAst] -and $inner -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            -not $inner.Static -and $inner.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            [string]$inner.Member.Value -ceq 'NonNodeData' -and
            $inner.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
            [string]$inner.Expression.VariablePath.UserPath -ceq 'ConfigurationData')
        {
            return
        }
        throw "Disallowed value at $Path`: $($Node.Extent.Text)"
    }
    if ($Node -is [System.Management.Automation.Language.ArrayExpressionAst])
    {
        if ($null -ne $Node.SubExpression.Traps)
        {
            throw "Disallowed value at $Path`: $($Node.Extent.Text)"
        }
        $i = 0
        foreach ($statement in $Node.SubExpression.Statements)
        {
            Assert-PEDscValueAst -Node $statement -Path "$Path[$i]"
            $i++
        }
        return
    }
    if ($Node -is [System.Management.Automation.Language.ParenExpressionAst])
    {
        # (-join @(e1, e2, ...)) or (-join @(e1))
        $pipeline = $Node.Pipeline
        $unary = $null
        if ($pipeline -is [System.Management.Automation.Language.PipelineAst] -and $pipeline.PipelineElements.Count -eq 1 -and
            $pipeline.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst] -and
            $pipeline.PipelineElements[0].Redirections.Count -eq 0)
        {
            $unary = $pipeline.PipelineElements[0].Expression
        }
        if ($unary -isnot [System.Management.Automation.Language.UnaryExpressionAst] -or
            $unary.TokenKind -ne [System.Management.Automation.Language.TokenKind]::Join -or
            $unary.Child -isnot [System.Management.Automation.Language.ArrayExpressionAst] -or
            $null -ne $unary.Child.SubExpression.Traps -or $unary.Child.SubExpression.Statements.Count -ne 1)
        {
            throw "Disallowed value at $Path`: $($Node.Extent.Text)"
        }
        $inner = $unary.Child.SubExpression.Statements[0]
        if ($inner -isnot [System.Management.Automation.Language.PipelineAst] -or $inner.PipelineElements.Count -ne 1 -or
            $inner.PipelineElements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst] -or
            $inner.PipelineElements[0].Redirections.Count -ne 0)
        {
            throw "Disallowed value at $Path`: $($Node.Extent.Text)"
        }
        $expression = $inner.PipelineElements[0].Expression
        $elements = if ($expression -is [System.Management.Automation.Language.ArrayLiteralAst]) { $expression.Elements } else { @($expression) }
        foreach ($element in $elements)
        {
            $ok = ($element -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $element.StringConstantType -eq [System.Management.Automation.Language.StringConstantType]::SingleQuoted) -or
            ($element -is [System.Management.Automation.Language.VariableExpressionAst] -and -not $element.Splatted -and
                [string]$element.VariablePath.UserPath -cin 'OrganizationName', 'TenantGuid') -or
            ($element -is [System.Management.Automation.Language.ConvertExpressionAst] -and
                $element.Type.TypeName.FullName -ceq 'char' -and
                $element.Child -is [System.Management.Automation.Language.ConstantExpressionAst] -and
                $element.Child -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $element.Child.Value -is [int])
            if (-not $ok)
            {
                throw "Disallowed value at $Path`: $($element.Extent.Text)"
            }
        }
        return
    }
    if ($Node -is [System.Management.Automation.Language.DynamicKeywordStatementAst])
    {
        # A CIM instance: ClassName{ ... }
        $elements = $Node.CommandElements
        if ($elements.Count -ne 3 -or $elements[0] -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or
            [string]$elements[0].Value -cnotmatch $script:PEIdentifierPattern -or -not (Test-PEDscClass -Name ([string]$elements[0].Value)) -or
            $elements[2] -isnot [System.Management.Automation.Language.HashtableAst])
        {
            throw "Disallowed value at $Path`: $(($Node.Extent.Text -split "`n")[0])"
        }
        $className = [string]$elements[0].Value
        Assert-PEDscHashtableAst -Node $elements[2] -Path "$Path{$className}" -Parameters (Get-PEDscSchema)[$className]
        return
    }
    throw "Disallowed $($Node.GetType().Name) at $Path`: $(($Node.Extent.Text -split "`n")[0])"
}

function Assert-PEDscHashtableAst
{
    # A resource or CIM instance body: identifier = allowed value pairs. With -Parameters (the schema of the resource
    # or CIM class), every name must be one of its parameters; with -Refused, none of those names may appear.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.HashtableAst]$Node,

        [Parameter(Mandatory)]
        [string]$Path,

        [System.Collections.Generic.Dictionary[string, string]]$Parameters,

        [System.Collections.Generic.HashSet[string]]$Refused
    )

    foreach ($pair in $Node.KeyValuePairs)
    {
        $key = $pair.Item1
        if ($key -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or
            $key.StringConstantType -ne [System.Management.Automation.Language.StringConstantType]::BareWord -or
            [string]$key.Value -cnotmatch $script:PEIdentifierPattern)
        {
            throw "Disallowed property name at $Path`: $($key.Extent.Text)"
        }
        $name = [string]$key.Value
        if ($null -ne $Refused -and $Refused.Contains($name))
        {
            throw "Disallowed property name at $Path`: $name is never generated."
        }
        if ($PSBoundParameters.ContainsKey('Parameters') -and ($null -eq $Parameters -or -not $Parameters.ContainsKey($name)))
        {
            throw "Disallowed property name at $Path`: $name is not a parameter in the schema."
        }
        Assert-PEDscValueAst -Node $pair.Item2 -Path "$Path.$name"
    }
}

function Assert-PEDscConfigAst
{
    # The whole generated configuration, by allowlist: exactly
    #   Configuration <name> { param () ; $OrganizationName = $ConfigurationData.NonNodeData.OrganizationName ;
    #   Import-DscResource -ModuleName 'Microsoft365DSC' -ModuleVersion '<pinned>' ; Node localhost { <blocks> } }
    # where each block is <PlannedType> '<instance name>' { <allowed pairs> }, ExpectedBlocks of them.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.ScriptBlockAst]$Ast,

        [Parameter(Mandatory)]
        [System.Collections.Generic.HashSet[string]]$Types,

        [Parameter(Mandatory)]
        [int]$ExpectedBlocks,

        [Parameter(Mandatory)]
        [string]$ConfigurationName,

        [Parameter(Mandatory)]
        [string]$Decoding
    )

    $fail = { param ($what) throw "Generated configuration is not in the expected form ($Decoding): $what" }
    if ($null -ne $Ast.ScriptRequirements -or $Ast.UsingStatements.Count -ne 0)
    {
        & $fail '#requires and using statements are not generated'
    }
    $trap = $Ast.Find({ param ($n) $n -is [System.Management.Automation.Language.TrapStatementAst] }, $true)
    if ($null -ne $trap -or $null -ne $Ast.EndBlock.Traps)
    {
        & $fail 'trap statements are not generated'
    }
    if ($null -ne $Ast.ParamBlock -or $null -ne $Ast.BeginBlock -or $null -ne $Ast.ProcessBlock -or $null -ne $Ast.DynamicParamBlock -or
        $null -eq $Ast.EndBlock -or $Ast.EndBlock.Statements.Count -ne 1 -or
        $Ast.EndBlock.Statements[0] -isnot [System.Management.Automation.Language.ConfigurationDefinitionAst])
    {
        & $fail 'the script must contain exactly one Configuration'
    }
    $definition = $Ast.EndBlock.Statements[0]
    if ($definition.InstanceName -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $definition.InstanceName.StringConstantType -ne [System.Management.Automation.Language.StringConstantType]::BareWord -or
        [string]$definition.InstanceName.Value -cne $ConfigurationName)
    {
        & $fail "the configuration name must be $ConfigurationName, not $($definition.InstanceName.Extent.Text)"
    }
    # Never generated in a resource block: DSC common properties, and every ignored/secret property except the three
    # credential references the generator writes.
    $refused = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    # Only top-level ignored names are refused here; nested and conditional ignore paths (Data\IgnoredProperties.psd1)
    # are not checked inside the rendered property tree (normalisation already removed them from the records, and a
    # conditional path such as a future ScheduleInfo.startDateTime must be rendered).
    foreach ($name in @('DependsOn', 'PsDscRunAsCredential') + @(Get-PEIgnoredName -Entries (Get-PEIgnoredProperties).Global))
    {
        if ($name -notin 'ApplicationId', 'TenantId', 'CertificateThumbprint')
        {
            [void]$refused.Add($name)
        }
    }
    $body = $definition.Body.ScriptBlock
    if ($null -eq $body.ParamBlock -or $body.ParamBlock.Parameters.Count -ne 0 -or $body.ParamBlock.Attributes.Count -ne 0 -or
        $null -ne $body.BeginBlock -or $null -ne $body.ProcessBlock -or $null -ne $body.DynamicParamBlock -or
        $null -eq $body.EndBlock -or $null -ne $body.EndBlock.Traps -or $body.EndBlock.Statements.Count -ne 4)
    {
        & $fail 'the Configuration body must be param (), the $OrganizationName and $TenantGuid assignments, Import-DscResource and Node'
    }
    $statements = $body.EndBlock.Statements
    if ($statements[0] -isnot [System.Management.Automation.Language.AssignmentStatementAst] -or
        $statements[0].Extent.Text -cne '$OrganizationName = $ConfigurationData.NonNodeData.OrganizationName')
    {
        & $fail "unexpected statement: $($statements[0].Extent.Text)"
    }
    if ($statements[1] -isnot [System.Management.Automation.Language.AssignmentStatementAst] -or
        $statements[1].Extent.Text -cne '$TenantGuid = $ConfigurationData.NonNodeData.TenantGuid')
    {
        & $fail "unexpected statement: $($statements[1].Extent.Text)"
    }
    $import = "Import-DscResource -ModuleName 'Microsoft365DSC' -ModuleVersion '$(Get-PEPinnedVersion -Name Microsoft365DSC)'"
    if ($statements[2] -isnot [System.Management.Automation.Language.DynamicKeywordStatementAst] -or $statements[2].Extent.Text -cne $import)
    {
        & $fail "unexpected statement: $($statements[2].Extent.Text)"
    }
    $node = $statements[3]
    if ($node -isnot [System.Management.Automation.Language.DynamicKeywordStatementAst] -or $node.CommandElements.Count -ne 3 -or
        [string]$node.CommandElements[0].Value -cne 'Node' -or [string]$node.CommandElements[1].Value -cne 'localhost' -or
        $node.CommandElements[1].StringConstantType -ne [System.Management.Automation.Language.StringConstantType]::BareWord -or
        $node.CommandElements[2] -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst])
    {
        & $fail 'expected Node localhost { ... }'
    }
    $nodeBody = $node.CommandElements[2].ScriptBlock
    if ($null -ne $nodeBody.ParamBlock -or $null -ne $nodeBody.BeginBlock -or $null -ne $nodeBody.ProcessBlock -or
        $null -ne $nodeBody.DynamicParamBlock -or $null -eq $nodeBody.EndBlock -or $null -ne $nodeBody.EndBlock.Traps)
    {
        & $fail 'unexpected content in the Node block'
    }
    $count = 0
    foreach ($block in $nodeBody.EndBlock.Statements)
    {
        $elements = $block.CommandElements
        if ($block -isnot [System.Management.Automation.Language.DynamicKeywordStatementAst] -or $elements.Count -ne 3 -or
            $elements[0] -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or
            -not $Types.Contains([string]$elements[0].Value) -or
            $elements[1] -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or
            $elements[1].StringConstantType -ne [System.Management.Automation.Language.StringConstantType]::SingleQuoted -or
            [string]$elements[1].Value -cnotmatch $script:PEInstanceNamePattern -or
            $elements[2] -isnot [System.Management.Automation.Language.HashtableAst])
        {
            & $fail "unexpected statement in the Node block: $(($block.Extent.Text -split "`n")[0])"
        }
        $type = [string]$elements[0].Value
        $blockRefused = [System.Collections.Generic.HashSet[string]]::new($refused, [System.StringComparer]::OrdinalIgnoreCase)
        $ignoredByType = (Get-PEIgnoredProperties).ByType
        if ($ignoredByType.ContainsKey($type))
        {
            foreach ($name in (Get-PEIgnoredName -Entries $ignoredByType[$type]))
            {
                [void]$blockRefused.Add($name)
            }
        }
        # A name on the ignore list is still allowed where the key map builds the record's Key from it (Id of an authentication method policy):
        # it is the [Key] DSC needs, rebuilt from the Key (Get-PEKeyPartFromRecordKey).
        if (Test-PEOwnIdType -ResourceType $type)
        {
            [void]$blockRefused.Remove('Id')
        }
        $keyOverrides = (Get-PEKeyMap).Overrides
        if ($keyOverrides.ContainsKey($type))
        {
            foreach ($name in @($keyOverrides[$type]))
            {
                [void]$blockRefused.Remove([string]$name)
            }
        }
        Assert-PEDscHashtableAst -Node $elements[2] -Path "$type[$($elements[1].Value)]" -Parameters (Get-PEDscResourceSchema -ResourceType $type) -Refused $blockRefused
        $count++
    }
    if ($count -ne $ExpectedBlocks)
    {
        & $fail "$count resource blocks for $ExpectedBlocks plan items"
    }
}

function Test-PEDscConfigSafe
{
    # Defence in depth for the generated text: decodes its UTF-8 bytes as UTF-8 AND as Windows-1252 (how Windows
    # PowerShell 5.1 reads a file without a BOM) and requires, for each decoding: no parse errors; no command,
    # sub-expression or member invocation anywhere; and the exact allowlisted shape (Assert-PEDscConfigAst), with
    # ExpectedBlocks resource blocks of the planned types. Identical decodings (pure ASCII, the normal case) are parsed
    # once. Throws otherwise.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [string[]]$ResourceTypes,

        [Parameter(Mandatory)]
        [int]$ExpectedBlocks,

        [Parameter(Mandatory)]
        [string]$ConfigurationName
    )

    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
    $decodings = [ordered]@{
        'UTF-8'        = [System.Text.UTF8Encoding]::new($false).GetString($bytes)
        'Windows-1252' = [System.Text.Encoding]::GetEncoding(1252).GetString($bytes)
    }
    $types = [System.Collections.Generic.HashSet[string]]::new([string[]]$ResourceTypes, [System.StringComparer]::OrdinalIgnoreCase)
    $checked = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($name in $decodings.Keys)
    {
        $decoded = $decodings[$name]
        if (-not $checked.Add($decoded))
        {
            continue
        }
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($decoded, [ref]$tokens, [ref]$errors)
        if (@($errors).Count -gt 0)
        {
            throw "Generated configuration does not parse ($name): $((@($errors) | ForEach-Object { $_.Message }) -join '; ')"
        }
        $code = @($ast.FindAll({
                    param ($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -or
                    $node -is [System.Management.Automation.Language.SubExpressionAst] -or
                    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]
                }, $true))
        if ($code.Count -gt 0)
        {
            throw "Generated configuration contains code ($name): $($code[0].Extent.Text)"
        }
        Assert-PEDscConfigAst -Ast $ast -Types $types -ExpectedBlocks $ExpectedBlocks -ConfigurationName $ConfigurationName -Decoding $name
    }
}

function ConvertTo-PEDscStringLiteral
{
    # A PowerShell expression for the string Value, in pure ASCII and of constant nesting depth:
    # - a printable-ASCII value without the placeholder is one single-quoted literal ('abc', with "'" doubled);
    # - anything else is (-join @(<elements>)), a unary -join over a flat array literal whose elements are
    #   single-quoted printable-ASCII runs, [char]0xXXXX for every other character (non-ASCII letters, typographic
    #   quotes, each half of a surrogate pair, line breaks, tabs, controls) and $OrganizationName for the export's
    #   placeholder (a separate element, so no following character can extend the variable name).
    # A flat array keeps parsing and compilation linear in the value length (a chain of '+' builds an expression tree as
    # deep as the operand count and overflows the parser's stack on long values).
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    # Split into runs with one regex pass (a per-character PowerShell loop costs seconds on long values): the
    # placeholder, runs of printable ASCII that do not start the placeholder, and runs of other characters. Each run is
    # converted with single .NET calls.
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($Value, $script:PEStringRunPattern))
    {
        if ($match.Groups['org'].Success)
        {
            $parts.Add('$OrganizationName')
        }
        elseif ($match.Groups['guid'].Success)
        {
            $parts.Add('$TenantGuid')
        }
        elseif ($match.Groups['lit'].Success)
        {
            $parts.Add("'" + $match.Value.Replace("'", "''") + "'")
        }
        else
        {
            # The exact UTF-16 code units (no encoder: a lone surrogate must stay itself, not become U+FFFD), as
            # little-endian byte pairs in hex, swapped into one [char]0xXXXX element per unit.
            $hex = [System.Convert]::ToHexString((ConvertTo-PEUtf16Bytes -Text $match.Value))
            $parts.Add([regex]::Replace($hex, '([0-9A-F]{2})([0-9A-F]{2})', ', [char]0x$2$1').Substring(2))
        }
    }

    if ($parts.Count -eq 0)
    {
        return "''"
    }
    if ($parts.Count -eq 1 -and $parts[0].StartsWith("'"))
    {
        return $parts[0]
    }
    return '(-join @(' + ($parts -join ', ') + '))'
}

function Use-PEDscBudget
{
    # Charges Text to a rendering budget (see Format-PEDscValue) and returns it; throws once the budget is exhausted.
    param
    (
        $Budget,

        [string]$Text
    )

    if ($null -ne $Budget)
    {
        $Budget.Remaining -= $Text.Length
        if ($Budget.Remaining -lt 0)
        {
            $Budget.Exceeded = $true
            throw 'The configuration length budget is exhausted.'
        }
    }
    return $Text
}

function Format-PEDscValue
{
    # DSC configuration text for one property value. Path names the property for error messages; Indent is the
    # column of the line the value starts on (nested lines are indented relative to it). Supported: strings, booleans,
    # numbers, enums, collections (rendered as @(...), null elements dropped) and CIM instances (an IDictionary,
    # PSCustomObject or CimInstance with a CIMInstance class name, rendered as ClassName{ ... } with null members
    # omitted). Anything else (credentials, secure strings, dates, script blocks, dictionaries without a CIM class)
    # throws, so nothing is embedded that is not plain data.
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [AllowNull()]
        $Value,

        [Parameter(Mandatory)]
        [string]$Path,

        [int]$Indent = 0,

        # Optional remaining-length budget, an object with Remaining (characters) and Exceeded: every rendered scalar
        # is charged to it as soon as it is produced, and rendering stops (Exceeded = $true, throw) once it goes below
        # zero, so a huge value is never built in full.
        $Budget
    )

    if ($null -eq $Value)
    {
        throw "Internal error: null value for '$Path' must be omitted by the caller."
    }
    if ($Value -is [string])
    {
        if ($Value.Length -gt $script:PEMaxStringLength)
        {
            throw "Cannot render '$Path': the value is $($Value.Length) characters; the limit is $($script:PEMaxStringLength)."
        }
        return Use-PEDscBudget -Budget $Budget -Text (ConvertTo-PEDscStringLiteral -Value $Value)
    }
    if ($Value -is [bool])
    {
        if ($Value) { return Use-PEDscBudget -Budget $Budget -Text '$true' } else { return Use-PEDscBudget -Budget $Budget -Text '$false' }
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [short] -or $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64] -or $Value -is [decimal])
    {
        return Use-PEDscBudget -Budget $Budget -Text ([System.IFormattable]$Value).ToString($null, [cultureinfo]::InvariantCulture)
    }
    if ($Value -is [double] -or $Value -is [single])
    {
        $d = [double]$Value
        if (-not [double]::IsFinite($d))
        {
            throw "Cannot render the non-finite number in '$Path'."
        }
        return Use-PEDscBudget -Budget $Budget -Text $d.ToString('R', [cultureinfo]::InvariantCulture)
    }
    if ($Value -is [enum])
    {
        return Format-PEDscValue -Value $Value.ToString() -Path $Path -Indent $Indent -Budget $Budget
    }

    $pad = ' ' * ($Indent + 4)
    $close = ' ' * $Indent
    if ($Value -is [System.Management.Automation.PSCustomObject] -or
        $Value.GetType().FullName -eq 'Microsoft.Management.Infrastructure.CimInstance')
    {
        $Value = ConvertTo-PEMemberDictionary -Value $Value
    }
    if ($Value -is [System.Collections.IDictionary])
    {
        $className = $null
        foreach ($name in $Value.get_Keys())
        {
            if ([string]$name -ieq 'CIMInstance')
            {
                $className = [string]$Value[$name]
            }
        }
        if ([string]::IsNullOrWhiteSpace($className))
        {
            throw "Cannot render '$Path': a nested object without a CIM class name (CIMInstance) is not a DSC CIM instance."
        }
        if ($className -cnotmatch $script:PEIdentifierPattern -or -not (Test-PEDscClass -Name $className))
        {
            throw "Cannot render '$Path': '$className' is not a CIM class of Microsoft365DSC."
        }
        $classParameters = (Get-PEDscSchema)[$className]
        $members = [System.Collections.Generic.List[string]]::new()
        foreach ($name in $Value.get_Keys())
        {
            $memberName = [string]$name
            if ($memberName -ieq 'CIMInstance' -or $null -eq $Value[$name])
            {
                continue
            }
            if ($memberName -cnotmatch $script:PEIdentifierPattern)
            {
                throw "Cannot render '$Path': member name '$memberName' is not a valid identifier."
            }
            if (-not $classParameters.ContainsKey($memberName))
            {
                throw "Cannot render '$Path': '$memberName' is not a property of CIM class $className."
            }
            $members.Add($memberName)
        }
        $members.Sort([System.StringComparer]::OrdinalIgnoreCase)
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add($className + '{')
        foreach ($memberName in $members)
        {
            $text = Format-PEDscValue -Value $Value[$memberName] -Path "$Path.$memberName" -Indent ($Indent + 4) -Budget $Budget
            $lines.Add($pad + $memberName + ' = ' + $text)
        }
        $lines.Add($close + '}')
        return ($lines -join "`n")
    }
    if ($Value -is [System.Collections.IEnumerable])
    {
        $elements = [System.Collections.Generic.List[string]]::new()
        $index = 0
        foreach ($element in $Value)
        {
            if ($index -ge $script:PEMaxArrayElements)
            {
                throw "Cannot render '$Path': the array has more than $($script:PEMaxArrayElements) elements."
            }
            if ($null -ne $element)
            {
                $elements.Add($pad + (Format-PEDscValue -Value $element -Path "$Path[$index]" -Indent ($Indent + 4) -Budget $Budget))
            }
            $index++
        }
        if ($elements.Count -eq 0)
        {
            return '@()'
        }
        return "@(`n" + ($elements -join "`n") + "`n" + $close + ')'
    }

    throw "Cannot render '$Path': values of type $($Value.GetType().FullName) are not embedded in a configuration."
}

function Get-PEDscInstanceName
{
    # A unique (case-insensitive) resource instance name '<Type>-<sanitised key>': characters other than letters,
    # digits, '_', '.' and '-' become '-', the key part is cut to 80 characters, and a collision gets '-2', '-3', ...
    # Used tracks the names already given out.
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$ResourceType,

        [AllowNull()]
        [string]$Key,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$Used
    )

    $part = ([string]$Key) -replace '[^A-Za-z0-9_.-]+', '-'
    $part = $part.Trim('-')
    if ($part.Length -gt 80)
    {
        $part = $part.Substring(0, 80).TrimEnd('-')
    }
    if ($part.Length -eq 0)
    {
        $part = 'item'
    }
    $base = $ResourceType + '-' + $part
    $name = $base
    $n = 1
    while (-not $Used.Add($name))
    {
        $n++
        $name = $base + '-' + $n
    }
    return $name
}

function ConvertTo-PEAuditText
{
    # One line of plain text: control characters (including line and paragraph separators) become spaces.
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [AllowNull()]
        [string]$Text
    )

    return ([string]$Text) -replace '[\x00-\x1F\x7F\u0085\u2028\u2029]', ' '
}
