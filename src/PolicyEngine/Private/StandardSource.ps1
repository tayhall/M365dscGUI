function Get-PEStandardSource
{
    # The entry of Data\StandardSources.psd1 for a standard, or throws for one this engine does not know.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Standard
    )

    $sources = Import-PowerShellDataFile -Path (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'Data') 'StandardSources.psd1')
    if (-not $sources.ContainsKey($Standard))
    {
        throw "Unknown standard '$Standard' (known: $((@($sources.Keys) | Sort-Object) -join ', '))."
    }
    return $sources[$Standard]
}

function Invoke-PEGit
{
    # Runs git and returns ExitCode and Output; the seam (-Git on the standard release commands) replaces this in tests.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $output = & git @Arguments 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output | ForEach-Object { [string]$_ }) }
}

function Assert-PEReleaseTag
{
    # A release tag reaches git, so it must look like vX.Y.Z and nothing else (no option, no second command).
    [CmdletBinding()]
    param
    (
        [AllowEmptyString()]
        [string]$Tag
    )

    if ($Tag -cnotmatch '\Av[0-9]+\.[0-9]+\.[0-9]+\z')
    {
        throw "Release tag '$Tag' is not of the form vX.Y.Z."
    }
}
