# Finding, fetching and importing a published release of a standard. The source of each standard is Data\StandardSources.psd1.
# -Git is a test seam: a scriptblock called with [string[]]$Arguments that returns an object with ExitCode and Output.

function Get-PEStandardLatestTag
{
    <#
    .SYNOPSIS
    The highest release tag (vX.Y.Z) of a standard's repository, from git ls-remote. Nothing is downloaded.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Standard,

        [scriptblock]$Git
    )

    $source = Get-PEStandardSource -Standard $Standard
    $result = if ($Git) { & $Git @('ls-remote', '--tags', $source.Repository, 'refs/tags/v*') } else { Invoke-PEGit -Arguments @('ls-remote', '--tags', $source.Repository, 'refs/tags/v*') }
    if ($result.ExitCode -ne 0)
    {
        throw "git ls-remote failed for $($source.Repository): $(@($result.Output) -join ' ')"
    }
    $tags = @(@($result.Output) | ForEach-Object { ([string]$_ -split "`t")[-1] -replace '\Arefs/tags/', '' } |
            Where-Object { $_ -cmatch '\Av[0-9]+\.[0-9]+\.[0-9]+\z' } | Sort-Object -Unique)
    if ($tags.Count -eq 0)
    {
        throw "No release tag (vX.Y.Z) found at $($source.Repository)."
    }
    return [string]@($tags | Sort-Object { [version]($_ -replace '\Av', '') })[-1]
}

function Save-PEStandardRelease
{
    <#
    .SYNOPSIS
    Fetches one release of a standard into data\sources\<standard>-<tag> (a sparse clone of the DSC folder only, which also keeps the
    Windows path limit out of the way), unless it is already there. Returns Standard, Tag, Path (the DSC folder), SourceName,
    SourceUrl and Attribution.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Standard,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Tag,

        [string]$DataRoot,

        [scriptblock]$Git
    )

    Assert-PEReleaseTag -Tag $Tag
    $source = Get-PEStandardSource -Standard $Standard
    $root = Get-PEDataRoot -Override $DataRoot
    $clone = Join-Path $root "sources\$Standard-$Tag"
    $run = { param ($arguments) if ($Git) { & $Git $arguments } else { Invoke-PEGit -Arguments $arguments } }
    if (-not (Test-Path -LiteralPath $clone))
    {
        New-Item -ItemType Directory -Path (Split-Path -Parent $clone) -Force | Out-Null
        $cloned = & $run @('clone', '--depth', '1', '--branch', $Tag, '--filter=blob:none', '--sparse', $source.Repository, $clone)
        if ($cloned.ExitCode -ne 0)
        {
            throw "git clone of $Tag failed: $(@($cloned.Output) -join ' ')"
        }
        $sparse = & $run @('-C', $clone, 'sparse-checkout', 'set', $source.DscPath)
        if ($sparse.ExitCode -ne 0)
        {
            throw "git sparse-checkout in $clone failed: $(@($sparse.Output) -join ' ')"
        }
    }
    [pscustomobject]@{
        Standard    = $Standard
        Tag         = $Tag
        Path        = Join-Path $clone ($source.DscPath -replace '/', '\')
        SourceName  = [string]$source.SourceName
        SourceUrl   = [string]$source.Url
        Attribution = [string]$source.Attribution
    }
}

function Import-PEStandardRelease
{
    <#
    .SYNOPSIS
    Fetches a release of a standard (the latest when no -Tag is given) and imports it with Import-PEStandard. Returns its summary.
    With -Path (a folder that already holds the DSC files) nothing is fetched; -Tag then names the version being imported.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Standard,

        [string]$Tag,

        [string]$Path,

        [string]$DataRoot,

        [scriptblock]$Git
    )

    if ($Path)
    {
        if (-not $Tag)
        {
            throw 'Importing from -Path needs -Tag (the version the files belong to).'
        }
        Assert-PEReleaseTag -Tag $Tag
        $source = Get-PEStandardSource -Standard $Standard
        return (Import-PEStandard -Name $Standard -Path $Path -SourceName $source.SourceName -SourceUrl $source.Url -SourceVersion $Tag -Attribution $source.Attribution -DataRoot $DataRoot)
    }
    if (-not $Tag)
    {
        $Tag = Get-PEStandardLatestTag -Standard $Standard -Git $Git
    }
    $release = Save-PEStandardRelease -Standard $Standard -Tag $Tag -DataRoot $DataRoot -Git $Git
    Import-PEStandard -Name $Standard -Path $release.Path -SourceName $release.SourceName -SourceUrl $release.SourceUrl -SourceVersion $release.Tag -Attribution $release.Attribution -DataRoot $DataRoot
}
