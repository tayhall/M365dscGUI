# User principal names in user sets, turned into object ids for the tenant a Revert applies to (Data\IdentityReferences.psd1).
$script:PEUserSetPaths = $null

function Get-PEUserSetPath
{
    # The dotted paths (Data\IdentityReferences.psd1) of the user sets of a resource type; nothing for other types.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$ResourceType
    )

    if ($null -eq $script:PEUserSetPaths)
    {
        $data = Import-PowerShellDataFile -Path (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'Data') 'IdentityReferences.psd1')
        $map = [System.Collections.Generic.Dictionary[string, string[]]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($type in $data.UserSets.get_Keys())
        {
            $map[[string]$type] = [string[]]@($data.UserSets[$type])
        }
        $script:PEUserSetPaths = $map
    }
    if ($script:PEUserSetPaths.ContainsKey($ResourceType))
    {
        $script:PEUserSetPaths[$ResourceType]
    }
}

function Resolve-PEUserReference
{
    # A copy of the record in which every singleUser set named by Data\IdentityReferences.psd1 whose Id is not already a GUID has the
    # object id the resolver returns for it (a user principal name goes in, an id or $null comes out). A user the resolver does not
    # find keeps its name, so DSC fails on it as before. Returns the record itself when its type has no user sets.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        $Record,

        [Parameter(Mandatory)]
        [scriptblock]$Resolver
    )

    $paths = @(Get-PEUserSetPath -ResourceType ([string]$Record.ResourceType))
    if ($paths.Count -eq 0)
    {
        return $Record
    }
    $copy = Copy-PEFrozenRecord -Record $Record
    $bag = Get-PEPropertyBag -Record $copy
    foreach ($path in $paths)
    {
        $nodes = @($bag)
        foreach ($segment in $path.Split('.'))
        {
            $next = [System.Collections.Generic.List[object]]::new()
            foreach ($node in $nodes)
            {
                foreach ($element in @($node))
                {
                    if ($element -is [System.Collections.IDictionary])
                    {
                        foreach ($name in @($element.get_Keys()))
                        {
                            if ([string]$name -ieq $segment)
                            {
                                foreach ($child in @($element[$name]))
                                {
                                    $next.Add($child)
                                }
                            }
                        }
                    }
                }
            }
            $nodes = $next.ToArray()
        }
        foreach ($userSet in $nodes)
        {
            if ($userSet -isnot [System.Collections.IDictionary])
            {
                continue
            }
            $kind = $null
            $idName = $null
            foreach ($name in @($userSet.get_Keys()))
            {
                if ([string]$name -ieq 'odataType') { $kind = [string]$userSet[$name] }
                if ([string]$name -ieq 'Id') { $idName = $name }
            }
            if ($kind -ine '#microsoft.graph.singleUser' -or $null -eq $idName)
            {
                continue
            }
            $current = [string]$userSet[$idName]
            if ([string]::IsNullOrWhiteSpace($current) -or [guid]::TryParse($current, [ref][guid]::Empty))
            {
                continue
            }
            $resolved = & $Resolver $current
            if (-not [string]::IsNullOrWhiteSpace([string]$resolved))
            {
                $userSet[$idName] = [string]$resolved
            }
        }
    }
    return $copy
}

function New-PEUserIdResolver
{
    # A resolver for Resolve-PEUserReference: looks a user principal name up in a tenant with its Reader app (exactly one match on the
    # part before the @, as DSC's own lookup does) and remembers the answers. It connects on first use; call Close() when done.
    # Returns an object with the methods Resolve(upn) and Close().
    [CmdletBinding()]
    param
    (
        [string]$Tenant = 'master'
    )

    $resolver = [pscustomobject]@{ App = Get-PEReaderApp -Tenant $Tenant; Connected = $false; Cache = @{} }
    $resolver | Add-Member -MemberType ScriptMethod -Name Resolve -Value {
        param ([string]$UserPrincipalName)
        $local = $UserPrincipalName.Split('@')[0]
        if ($this.Cache.ContainsKey($local))
        {
            return $this.Cache[$local]
        }
        if (-not $this.Connected)
        {
            Connect-PEGraph -App $this.App
            $this.Connected = $true
        }
        $escaped = [uri]::EscapeDataString("startswith(userPrincipalName,'$($local -replace "'", "''")@')")
        $found = @((Invoke-PEGraphPage -Uri "https://graph.microsoft.com/v1.0/users?`$filter=$escaped&`$select=id").value)
        $id = $null
        if ($found.Count -eq 1)
        {
            $id = [string]$found[0].id
        }
        $this.Cache[$local] = $id
        return $id
    }
    $resolver | Add-Member -MemberType ScriptMethod -Name Close -Value {
        if ($this.Connected)
        {
            Disconnect-PEGraph
            $this.Connected = $false
        }
    }
    return $resolver
}

$script:PEOwnIdTypes = $null

function Test-PEOwnIdType
{
    # True for a type whose own Id is kept in its records and swapped for the target's when a Revert goes to another tenant (Data\IdentityReferences.psd1, OwnIds).
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory)]
        [string]$ResourceType
    )

    if ($null -eq $script:PEOwnIdTypes)
    {
        $data = Import-PowerShellDataFile -Path (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'Data') 'IdentityReferences.psd1')
        $script:PEOwnIdTypes = [System.Collections.Generic.HashSet[string]]::new([string[]]@($data.OwnIds), [System.StringComparer]::OrdinalIgnoreCase)
    }
    return $script:PEOwnIdTypes.Contains($ResourceType)
}

function Resolve-PEOwnId
{
    # A copy of the record with the Id the resolver finds for its type and key in the target tenant; the record itself when its type is not an
    # OwnId type or the resolver finds nothing (the blueprint's Id is then sent as it is).
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        $Record,

        [Parameter(Mandatory)]
        [scriptblock]$Resolver
    )

    if (-not (Test-PEOwnIdType -ResourceType ([string]$Record.ResourceType)))
    {
        return $Record
    }
    $found = & $Resolver ([string]$Record.ResourceType) ([string]$Record.Key)
    if ([string]::IsNullOrWhiteSpace([string]$found))
    {
        return $Record
    }
    $copy = Copy-PEFrozenRecord -Record $Record
    $bag = Get-PEPropertyBag -Record $copy
    $bag['Id'] = [string]$found
    return $copy
}

function New-PEOwnIdResolver
{
    # Looks the Id of an object up in a tenant by its type and key with DSC's own export of the type (Reader app, the whole type, once per type,
    # remembered): the raw export still holds Id. Returns an object with the methods Resolve(type, key) and Close(); nothing is connected.
    [CmdletBinding()]
    param
    (
        [string]$Tenant = 'master'
    )

    $resolver = [pscustomobject]@{ Tenant = $Tenant; Maps = @{} }
    $resolver | Add-Member -MemberType ScriptMethod -Name Resolve -Value {
        param ([string]$ResourceType, [string]$Key)
        if (-not $this.Maps.ContainsKey($ResourceType))
        {
            $map = @{}
            $folder = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-ownid-' + [guid]::NewGuid().ToString('N'))
            try
            {
                $path = Invoke-PEDeltaExportTool -Components @($ResourceType) -Filters @{} -OutputPath $folder -Tenant $this.Tenant
                foreach ($raw in @(Read-PEExport -Path (Find-PEExportFile -Path ([string]@($path)[-1]))))
                {
                    if ([string]$raw.ResourceType -ine $ResourceType) { continue }
                    $recordKey = Get-PEResourceKey -ResourceType $ResourceType -Properties $raw.Properties
                    if ($recordKey -and $raw.Properties['Id'])
                    {
                        $map[(Get-PEMatchKey -ResourceType $ResourceType -Key $recordKey)] = [string]$raw.Properties['Id']
                    }
                }
            }
            finally
            {
                Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
            }
            $this.Maps[$ResourceType] = $map
        }
        $matchKey = Get-PEMatchKey -ResourceType $ResourceType -Key $Key
        if ($this.Maps[$ResourceType].ContainsKey($matchKey)) { return $this.Maps[$ResourceType][$matchKey] }
        return $null
    }
    $resolver | Add-Member -MemberType ScriptMethod -Name Close -Value { }
    return $resolver
}