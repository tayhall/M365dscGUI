# Types a Revert is refused for (Data\RevertBlocked.psd1).
$script:PERevertBlocks = $null

function Get-PERevertBlock
{
    # The reason a Revert of this resource type is refused, or $null when it is not blocked.
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ResourceType
    )

    if ($null -eq $script:PERevertBlocks)
    {
        $data = Import-PowerShellDataFile -Path (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'Data') 'RevertBlocked.psd1')
        $script:PERevertBlocks = @($data.Rules)
    }
    foreach ($rule in $script:PERevertBlocks)
    {
        if ($ResourceType -match [string]$rule.Pattern)
        {
            return [string]$rule.Reason
        }
    }
    return $null
}
