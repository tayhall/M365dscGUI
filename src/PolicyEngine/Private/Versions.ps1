$script:PEPinnedVersions = $null

function Get-PEPinnedVersion
{
    # Pinned module version from Data\Versions.psd1 (Microsoft365DSC, MicrosoftGraphAuthentication).
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [ValidateSet('Microsoft365DSC', 'MicrosoftGraphAuthentication')]
        [string]$Name
    )

    if ($null -eq $script:PEPinnedVersions)
    {
        $script:PEPinnedVersions = Import-PowerShellDataFile -Path (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'Data') 'Versions.psd1')
    }
    $version = [string]$script:PEPinnedVersions[$Name]
    if ([string]::IsNullOrWhiteSpace($version))
    {
        throw "No pinned version for $Name in Data\Versions.psd1."
    }
    return $version
}