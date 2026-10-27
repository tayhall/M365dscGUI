function Get-PEExportFileVersion
{
    # The Microsoft365DSC version an export file was written with: the '# Generated with Microsoft365DSC version' line that
    # Export-M365DSCConfiguration puts first (a leading byte order mark is tolerated). The Import-DscResource -ModuleVersion in the file must agree with it, otherwise the
    # file was edited or put together by hand and its version cannot be trusted.
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Text
    )

    $header = [regex]::Match($Text, '(?m)\A\uFEFF?#[ \t]*Generated with Microsoft365DSC version[ \t]+(?<v>[0-9][0-9.]*)[ \t]*\r?$')
    if (-not $header.Success)
    {
        throw "The file has no '# Generated with Microsoft365DSC version' first line, so it does not look like an export of Microsoft365DSC."
    }
    $version = $header.Groups['v'].Value
    $import = [regex]::Match($Text, "(?m)^\s*Import-DscResource\b.*-ModuleVersion\s+['""]?(?<v>[0-9][0-9.]*)")
    if ($import.Success -and $import.Groups['v'].Value -ne $version)
    {
        throw "The file says it was generated with Microsoft365DSC $version, but its Import-DscResource uses $($import.Groups['v'].Value)."
    }
    return $version
}

function Assert-PEUploadVersion
{
    # Throws unless every uploaded file was exported with the pinned Microsoft365DSC version; the message lists every offending
    # file. Stores nothing.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [object[]]$File
    )

    $pinned = Get-PEPinnedVersion -Name Microsoft365DSC
    $problems = foreach ($item in $File)
    {
        try { $version = Get-PEExportFileVersion -Text $item.Text }
        catch
        {
            "$($item.Name): $($_.Exception.Message)"
            continue
        }
        if ($version -ne $pinned)
        {
            "$($item.Name) was exported with Microsoft365DSC $version, but this installation is pinned to $pinned. Export again with $pinned."
        }
    }
    if ($problems)
    {
        throw ($problems -join ' ')
    }
}

function Write-PEUploadStage
{
    # Writes the uploaded files into Path as ONE export folder (export.ps1): the first file is written as it is, the others are
    # merged into it with Merge-PEExportPart. Each file is staged as export.ps1 in a temporary folder next to Path, whatever its
    # name. Uploads have no export.log, and none is created. Returns a warning for every resource instance name that is in more
    # than one file (the merged export then holds it more than once; New-PEUploadCheck keeps one record per type and key, the
    # later one). The caller owns Path and removes it when
    # this throws.
    [CmdletBinding()]
    [OutputType([string[]])]
    param
    (
        [Parameter(Mandatory)]
        [object[]]$File,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $blockPattern = '(?m)^[ ]{8}(?<type>[A-Za-z0-9]+) "(?<instance>[^"]*)"[ ]*\r?$'
    $texts = [string[]]@($File | ForEach-Object { $_.Text -replace '\A\uFEFF', '' })
    $warnings = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    for ($i = 0; $i -lt $File.Count; $i++)
    {
        $name = $File[$i].Name
        if ($texts[$i] -notmatch '(?m)^[ ]{4}Node localhost\r?\n[ ]{4}\{\r?$')
        {
            throw "$name is not in the layout Microsoft365DSC writes (no 'Node localhost' block)."
        }
        $blocks = @([regex]::Matches($texts[$i], $blockPattern))
        if ($blocks.Count -eq 0)
        {
            throw "$name holds no resources."
        }
        foreach ($match in $blocks)
        {
            $type = $match.Groups['type'].Value
            $instance = $match.Groups['instance'].Value
            $key = "$type `"$instance`""
            if ($seen.ContainsKey($key))
            {
                $first = $seen[$key]
                # Records are de-duplicated by type and key (New-PEUploadCheck), not by instance name: say only what is certain.
                $warnings.Add("$type $instance is in $($File[$first].Name) (file $($first + 1)) and in $name (file $($i + 1)). Records with the same type and key count once, and the later file's one is kept.")
            }
            else
            {
                $seen[$key] = $i
            }
        }
    }

    $utf8 = [System.Text.UTF8Encoding]::new($false)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $Path 'export.ps1'), $texts[0], $utf8)
    $parent = Split-Path -Parent (Resolve-Path -LiteralPath $Path).Path
    for ($i = 1; $i -lt $File.Count; $i++)
    {
        $part = Join-Path $parent ('upload-part-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $part | Out-Null
        try
        {
            [System.IO.File]::WriteAllText((Join-Path $part 'export.ps1'), $texts[$i], $utf8)
            try { Merge-PEExportPart -Path $Path -PartPath $part }
            catch { throw "$($File[$i].Name) could not be merged: $($_.Exception.Message)" }
        }
        finally
        {
            Remove-PEExportPart -PartPath $part | Out-Null
        }
    }
    return [string[]]$warnings.ToArray()
}
