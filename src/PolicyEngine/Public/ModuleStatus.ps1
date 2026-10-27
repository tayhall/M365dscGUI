function Get-PEModuleStatus
{
    <#
    .SYNOPSIS
    Says whether the pinned Microsoft365DSC version (Data\Versions.psd1) is the one the blueprint was built with.

    .DESCRIPTION
    Returns Pin, BlueprintVersion (the version recorded in blueprints\<name>\module.json, $null for a blueprint created
    before the guard), Match ($true, $false or $null for unknown), SetAt and Reason. Full checks, scope checks, adding
    types and rectify refuse to run on a mismatch (see Assert-PEModuleVersion).
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$BlueprintName,

        [string]$DataRoot
    )

    $null = Get-PEBlueprint -Name $BlueprintName -Version 'latest' -DataRoot $DataRoot
    Get-PEModuleState -BlueprintName $BlueprintName -DataRoot $DataRoot
}

function Set-PEBlueprintModule
{
    <#
    .SYNOPSIS
    Records the pinned Microsoft365DSC version as the one the blueprint is built with.

    .DESCRIPTION
    Run it once for a blueprint made before the guard existed, and after a deliberate re-baseline following a version
    change (run a check with -AcceptModuleChange, review the drift it shows, Promote what is expected). The previous
    version and the reason are kept in module.json.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Reason,

        [string]$DataRoot
    )

    $null = Get-PEBlueprint -Name $Name -Version 'latest' -DataRoot $DataRoot
    $state = Get-PEModuleState -BlueprintName $Name -DataRoot $DataRoot
    $record = [ordered]@{
        ModuleVersion = $state.Pin
        Previous      = $state.BlueprintVersion
        SetAt         = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        SetBy         = $(if ($env:USERNAME) { $env:USERNAME } else { [System.Environment]::UserName })
        Reason        = $Reason
    }
    if ($PSCmdlet.ShouldProcess("blueprint '$Name'", "Record Microsoft365DSC $($state.Pin) as its version"))
    {
        Write-PEJson -Path (Get-PEBlueprintModulePath -Name $Name -DataRoot $DataRoot) -InputObject $record
    }
    Get-PEModuleState -BlueprintName $Name -DataRoot $DataRoot
}
