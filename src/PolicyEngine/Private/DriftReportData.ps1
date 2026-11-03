# Helpers for Get-PEDriftReportData (presentation of the engine's findings; no comparison happens here).

function Get-PEReportPropertyMap
{
    # The properties of a record as an ordered name -> value map (the record holds a dictionary or an object); empty for no record.
    param ([object]$Record)

    $map = [ordered]@{}
    if ($null -eq $Record -or $null -eq $Record.Properties) { return $map }
    $properties = $Record.Properties
    if ($properties -is [System.Collections.IDictionary])
    {
        foreach ($key in $properties.Keys) { $map[[string]$key] = $properties[$key] }
    }
    else
    {
        foreach ($member in $properties.PSObject.Properties) { $map[$member.Name] = $member.Value }
    }
    $map
}

function Get-PEReportPropertyName
{
    # The property names of a list of differences (case-insensitive set).
    param ([object[]]$Difference)

    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($d in @($Difference | Where-Object { $null -ne $_ })) { [void]$set.Add([string]$d.Property) }
    , $set
}
