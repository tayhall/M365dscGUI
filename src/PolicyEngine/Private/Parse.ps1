function Read-PEExport
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$TenantId,

        # Ids of referenced parents ('<type>|<id>' -> Key, Data\References.psd1). Filled from this export and used to turn the GUID
        # references DSC exports into the parent's Key; pass the same dictionary to several calls to carry the ids across exports.
        [System.Collections.IDictionary]$ReferenceMap = @{}
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        throw "Export file not found: $Path"
    }

    Import-Module DSCParser -RequiredVersion 3.1.0.7 -ErrorAction Stop

    $objects = ConvertTo-DSCObject -Path $Path -ErrorAction Stop
    $records = foreach ($object in $objects)
    {
        $properties = [ordered]@{}
        # get_Keys(): a property literally named 'Keys' would shadow the .Keys member on the parsed hashtable.
        foreach ($name in $object.get_Keys())
        {
            if ($name -in 'ResourceName', 'ResourceInstanceName')
            {
                continue
            }
            $properties[$name] = $object[$name]
        }

        $type = [string]$object.ResourceName

        # TenantId is optional record metadata. It is not a key in Properties and is never compared.
        [pscustomobject]@{
            ResourceType = $type
            Key          = $null
            Workload     = Get-PEWorkload -ResourceType $type
            TenantId     = $TenantId
            Properties   = $properties
        }
    }
    $records = @($records)
    Resolve-PEReferenceGuid -Record $records -ReferenceMap $ReferenceMap
    $records
}
