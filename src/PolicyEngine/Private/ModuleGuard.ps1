function Get-PEBlueprintModulePath
{
    # blueprints\<name>\module.json: the Microsoft365DSC version the blueprint was built with. Kept next to the immutable
    # version files, not inside them, so it can be re-stamped after a deliberate re-baseline.
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,

        [string]$DataRoot
    )

    return Join-Path (Get-PEBlueprintDirectory -Name $Name -DataRoot $DataRoot) 'module.json'
}

function Get-PEModuleState
{
    # Pin (Data\Versions.psd1), the version recorded for the blueprint, and whether they match. Match is $null when the
    # blueprint has no recorded version (created before this guard).
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$BlueprintName,

        [string]$DataRoot
    )

    $pin = Get-PEPinnedVersion -Name Microsoft365DSC
    $record = Read-PEJson -Path (Get-PEBlueprintModulePath -Name $BlueprintName -DataRoot $DataRoot)
    $recorded = if ($null -ne $record) { [string]$record.ModuleVersion } else { $null }
    [pscustomobject]@{
        Pin              = $pin
        BlueprintVersion = $recorded
        Match            = $(if ($recorded) { $recorded -eq $pin } else { $null })
        SetAt            = $(if ($null -ne $record) { [string]$record.SetAt } else { $null })
        Reason           = $(if ($null -ne $record) { [string]$record.Reason } else { $null })
    }
}

function Assert-PEModuleVersion
{
    # The pinned Microsoft365DSC must be the version the blueprint was built with: a newer module can rename or drop
    # properties and add resources, which would show as drift that nobody caused. Throws on a mismatch unless
    # -AcceptModuleChange (then it only warns, so the effect of an upgrade can be reviewed as drift and promoted). A
    # blueprint with no recorded version only warns.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$BlueprintName,

        [switch]$AcceptModuleChange,

        [string]$DataRoot
    )

    $state = Get-PEModuleState -BlueprintName $BlueprintName -DataRoot $DataRoot
    if ($null -eq $state.Match)
    {
        Write-Warning "Blueprint '$BlueprintName' has no recorded Microsoft365DSC version. If it was built with the pinned $($state.Pin), run Set-PEBlueprintModule -Name $BlueprintName -Reason '...' once."
        return
    }
    if ($state.Match)
    {
        return
    }
    $message = "Blueprint '$BlueprintName' was built with Microsoft365DSC $($state.BlueprintVersion) but the pinned version is $($state.Pin). Properties and resources can differ between versions, so results would show drift nobody caused. Re-baseline: run a check with -AcceptModuleChange, review the drift it shows, Promote what is expected, then run Set-PEBlueprintModule -Name $BlueprintName -Reason '...'."
    if (-not $AcceptModuleChange)
    {
        throw $message
    }
    Write-Warning "$message (continuing because -AcceptModuleChange was given)"
}
