function Get-PEDecisionPath
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [string]$DataRoot
    )

    return Join-Path (Get-PEDataRoot -Override $DataRoot) 'decisions.json'
}

function Read-PEDecisionList
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Path
    )

    # ConvertFrom-Json yields a bare object for a one-element array, so always re-wrap.
    $raw = Read-PEJson -Path $Path
    if ($null -eq $raw)
    {
        return , @()
    }
    # ConvertFrom-Json turns ISO timestamps into DateTime; keep At as a string.
    $list = foreach ($item in @($raw))
    {
        if ($item.At -is [datetime])
        {
            $item.At = $item.At.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        }
        $item
    }
    return , @($list)
}

# Matching is deliberately case-insensitive on ResourceType, Key and Property. Compare-PEState matches objects
# case-insensitively and reports keys that differ only by case as Ambiguous (never offered for Remove), so a
# decision cannot authorise a different object.
function Test-PEDecisionMatch
{
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory)]
        $Decision,

        [Parameter(Mandatory)]
        [string]$Kind,

        [Parameter(Mandatory)]
        [string]$ResourceType,

        [string]$Key,

        [string]$Property,

        [string]$Tenant
    )

    return ($Decision.Kind -eq $Kind) -and
        ([string]$Decision.ResourceType -ieq $ResourceType) -and
        ([string]$Decision.Key -ieq $Key) -and
        ([string]$Decision.Property -ieq $Property) -and
        ([string]$Decision.Tenant -ceq [string]$Tenant)
}
