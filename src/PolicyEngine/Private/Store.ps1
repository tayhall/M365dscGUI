function Resolve-PEDefaultDataRoot
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [string]$StartPath = $PSScriptRoot
    )

    # Walk up to the repo root (the folder holding src\PolicyEngine\PolicyEngine.psd1 or .git)
    # instead of counting parents. No side effects.
    $dir = $StartPath
    while ($dir)
    {
        if ((Test-Path -LiteralPath (Join-Path $dir 'src\PolicyEngine\PolicyEngine.psd1')) -or
            (Test-Path -LiteralPath (Join-Path $dir '.git')))
        {
            return (Join-Path $dir 'data')
        }
        $dir = Split-Path -Parent $dir
    }

    throw "Could not locate the repository root (looked for src\PolicyEngine\PolicyEngine.psd1 or .git above '$StartPath')."
}

function Get-PEDataRoot
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [string]$Override
    )

    if ($Override)
    {
        $root = $Override
    }
    else
    {
        $root = Resolve-PEDefaultDataRoot
    }

    if (-not (Test-Path -LiteralPath $root -PathType Container))
    {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }

    return $root
}

function Write-PEJson
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$InputObject
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container))
    {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $json = ConvertTo-Json -InputObject $InputObject -Depth 20
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Read-PEJson
{
    [CmdletBinding()]
    [OutputType([object])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20 -DateKind String
}

function Write-PEJsonNew
{
    # Like Write-PEJson, but fails if the file already exists, so immutable files are written once. The content goes to
    # a unique *.tmp file in the same folder first and is then moved into place without overwrite, so the final path
    # only ever exists with complete content.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$InputObject
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container))
    {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (Test-Path -LiteralPath $Path)
    {
        throw "File already exists, refusing to overwrite: $Path"
    }

    $json = ConvertTo-Json -InputObject $InputObject -Depth 20
    $temp = '{0}.{1}.tmp' -f $Path, [guid]::NewGuid().ToString('N')
    try
    {
        [System.IO.File]::WriteAllText($temp, $json, [System.Text.UTF8Encoding]::new($false))
        try
        {
            Move-PEFileNoOverwrite -Source $temp -Destination $Path
        }
        catch [System.IO.IOException]
        {
            if (Test-Path -LiteralPath $Path)
            {
                throw "File already exists, refusing to overwrite: $Path"
            }
            throw
        }
    }
    finally
    {
        if (Test-Path -LiteralPath $temp)
        {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-PETextNew
{
    # Text counterpart of Write-PEJsonNew: fails if the file exists; written to a unique temp file and moved into place
    # without overwrite. UTF-8, with a byte order mark when -Bom (scripts with non-ASCII text).
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,

        [switch]$Bom
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container))
    {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (Test-Path -LiteralPath $Path)
    {
        throw "File already exists, refusing to overwrite: $Path"
    }

    $temp = '{0}.{1}.tmp' -f $Path, [guid]::NewGuid().ToString('N')
    try
    {
        [System.IO.File]::WriteAllText($temp, $Text, [System.Text.UTF8Encoding]::new([bool]$Bom))
        try
        {
            Move-PEFileNoOverwrite -Source $temp -Destination $Path
        }
        catch [System.IO.IOException]
        {
            if (Test-Path -LiteralPath $Path)
            {
                throw "File already exists, refusing to overwrite: $Path"
            }
            throw
        }
    }
    finally
    {
        if (Test-Path -LiteralPath $temp)
        {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Move-PEFileNoOverwrite
{
    # File.Move never overwrites: it throws an IOException if the destination exists. A separate function so tests can
    # observe the state of the folder at the moment of the move.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    [System.IO.File]::Move($Source, $Destination)
}
function Get-PEReaderTenantId
{
    # TenantId of the Reader app registration of a tenant (the tenant the export runs against), or $null if unavailable.
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [string]$Tenant = 'master'
    )

    $path = Get-PEAppInfoPath -Role Reader -Tenant $Tenant
    if (-not (Test-Path -LiteralPath $path -PathType Leaf))
    {
        return $null
    }
    try
    {
        $info = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        return [string]$info.TenantId
    }
    catch
    {
        return $null
    }
}
