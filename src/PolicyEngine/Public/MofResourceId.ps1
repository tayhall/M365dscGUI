function Get-PEMofResourceId
{
    <#
    .SYNOPSIS
    The DSC resource ids (for example [AADGroup]AADGroup-Finance) of the instances in a compiled MOF.

    .DESCRIPTION
    Reads the ResourceID of every resource instance, as Microsoft365DSC's own build wrote it; this is the id the Local Configuration
    Manager reports for the resource, so it is what an apply result must be matched against. -Path is a MOF file or a folder holding one.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Path
    )

    $files = if (Test-Path -LiteralPath $Path -PathType Container) { @(Get-ChildItem -LiteralPath $Path -Filter '*.mof' -File) }
    elseif (Test-Path -LiteralPath $Path -PathType Leaf) { @(Get-Item -LiteralPath $Path) }
    else { @() }
    if ($files.Count -eq 0) { throw "No MOF found at $Path." }
    foreach ($file in $files)
    {
        foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($file.FullName), '(?m)^\s*ResourceID\s*=\s*"([^"]+)"\s*;'))
        {
            $m.Groups[1].Value
        }
    }
}

function Test-PEResourceIdInMof
{
    <#
    .SYNOPSIS
    Returns the expected resource ids that the compiled MOF does not contain (nothing when all are there; case does not matter).

    .DESCRIPTION
    A pre-flight check: the apply result is matched to approved items by resource id, so an id we expect but the MOF does not have means
    the result could never be matched. Better to know before Dev is touched.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param
    (
        [AllowEmptyCollection()]
        [string[]]$ExpectedId = @(),

        [Parameter(Mandatory)]
        [string]$Path
    )

    $have = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @(Get-PEMofResourceId -Path $Path)) { [void]$have.Add($id) }
    foreach ($id in $ExpectedId) { if (-not $have.Contains($id)) { $id } }
}
