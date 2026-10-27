function Get-PEBuiltInResource
{
    # Data\BuiltInResources.psd1: per resource type, the built-in objects (by id) whose Microsoft-controlled properties are
    # not compared. Returns a hashtable keyed by resource type, each value with KeyProperty, NameProperty, RequireProperties,
    # IgnoreProperties and Ids (a case-insensitive map of id to the built-in object's name; empty for a type that is recognised by
    # RequireProperties alone, such as Intune roles flagged IsBuiltIn).
    [CmdletBinding()]
    param ()

    if ($null -eq $script:PEBuiltInResources)
    {
        $data = Import-PowerShellDataFile -Path (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'Data') 'BuiltInResources.psd1')
        $map = @{}
        foreach ($type in $data.Keys)
        {
            $entry = $data[$type]
            $ids = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            if ($entry.ContainsKey('Ids')) { foreach ($id in $entry.Ids.Keys) { $ids[[string]$id] = [string]$entry.Ids[$id] } }
            $require = @{}
            if ($entry.ContainsKey('RequireProperties')) { foreach ($name in $entry.RequireProperties.Keys) { $require[[string]$name] = [string]$entry.RequireProperties[$name] } }
            $map[[string]$type] = [pscustomobject]@{ KeyProperty = [string]$entry.KeyProperty; NameProperty = [string]$entry.NameProperty; RequireProperties = $require; IgnoreProperties = [string[]]@($entry.IgnoreProperties); Ids = $ids }
        }
        $script:PEBuiltInResources = $map
    }
    return $script:PEBuiltInResources
}

function Remove-PEBuiltInProperty
{
    # For a record of a type in BuiltInResources.psd1 whose id is listed AND whose name is the one listed for that id (or, for a
    # type with no Ids, that has every RequireProperties value), returns the property bag without the properties Microsoft
    # controls; any other record, or a type without an entry, gets the same bag back unchanged. The id alone is not enough: a
    # custom role can be created with any templateId.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ResourceType,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Properties
    )

    $rule = (Get-PEBuiltInResource)[$ResourceType]
    if ($null -eq $rule)
    {
        return $Properties
    }
    if ($rule.Ids.Count -gt 0)
    {
        $id = $null
        $displayName = $null
        foreach ($name in $Properties.Keys)
        {
            if ([string]$name -ieq $rule.KeyProperty) { $id = [string]$Properties[$name] }
            if ([string]$name -ieq $rule.NameProperty) { $displayName = [string]$Properties[$name] }
        }
        $listedName = $null
        if ([string]::IsNullOrEmpty($id) -or -not $rule.Ids.TryGetValue($id, [ref]$listedName) -or $displayName -cne $listedName)
        {
            return $Properties
        }
    }
    elseif ($rule.RequireProperties.Count -eq 0)
    {
        return $Properties
    }
    # Some types also need a server-set flag (Intune: IsBuiltIn = True) on the record itself.
    foreach ($required in $rule.RequireProperties.Keys)
    {
        $actual = $null
        foreach ($name in $Properties.Keys) { if ([string]$name -ieq $required) { $actual = [string]$Properties[$name]; break } }
        if ($actual -ine $rule.RequireProperties[$required]) { return $Properties }
    }
    $result = [ordered]@{}
    foreach ($name in $Properties.Keys)
    {
        if ($rule.IgnoreProperties -inotcontains [string]$name) { $result[$name] = $Properties[$name] }
    }
    return $result
}
