# Microsoft365DSC resource schemas, read from the pinned module's SchemaDefinition.json (one entry per MOF class:
# ClassName plus Parameters with Name, Option (Key, Required, Write, Read) and CIMType). Used by
# ConvertTo-PEDscConfig to check resource types, property names, key/required properties, Ensure and nested CIM
# class names before a configuration is generated.

$script:PEDscSchema = $null

function Get-PEDscModuleFile
{
    # A data file of the pinned Microsoft365DSC version (SchemaDefinition.json, ResourcePermissions.json), searched in PSModulePath
    # (explicit version: an older 1.x is installed system-wide). Throws when the pinned version is not installed.
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Name
    )

    $version = Get-PEPinnedVersion -Name Microsoft365DSC
    foreach ($dir in @($env:PSModulePath -split [System.IO.Path]::PathSeparator))
    {
        if ([string]::IsNullOrWhiteSpace($dir))
        {
            continue
        }
        $path = Join-Path (Join-Path (Join-Path $dir Microsoft365DSC) $version) $Name
        if (Test-Path -LiteralPath $path -PathType Leaf)
        {
            return $path
        }
    }
    throw "Microsoft365DSC $version is not installed ($Name not found in PSModulePath)."
}

function Get-PEDscSchema
{
    # Class name (case-insensitive) -> Dictionary of parameter name (case-insensitive) -> Option. Cached.
    [CmdletBinding()]
    param ()

    if ($null -eq $script:PEDscSchema)
    {
        $entries = Get-Content -LiteralPath (Get-PEDscModuleFile -Name SchemaDefinition.json) -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10
        $schema = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.Dictionary[string, string]]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in @($entries))
        {
            $parameters = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($parameter in @($entry.Parameters))
            {
                if ($null -ne $parameter -and -not [string]::IsNullOrWhiteSpace([string]$parameter.Name))
                {
                    $parameters[[string]$parameter.Name] = [string]$parameter.Option
                }
            }
            $schema[[string]$entry.ClassName] = $parameters
        }
        $script:PEDscSchema = $schema
    }
    return , $script:PEDscSchema
}

function Get-PEDscResourceSchema
{
    # Parameters (name -> Option) of the DSC resource named ResourceType (class MSFT_<ResourceType>), or $null.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$ResourceType
    )

    $schema = Get-PEDscSchema
    $className = 'MSFT_' + $ResourceType
    if ($schema.ContainsKey($className))
    {
        return , $schema[$className]
    }
    return $null
}

function Test-PEDscClass
{
    # True when Name is a CIM class known to the pinned Microsoft365DSC schema.
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Name
    )

    return (Get-PEDscSchema).ContainsKey($Name)
}
