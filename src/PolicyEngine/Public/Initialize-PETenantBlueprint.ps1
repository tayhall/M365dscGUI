function Initialize-PETenantBlueprint
{
    <#
    .SYNOPSIS
    Gives a replica tenant its own blueprint, named after the tenant: a copy of the master blueprint's latest version, or with -FromCheck the tenant as its latest Full check read it.

    .DESCRIPTION
    The tenant then follows two blueprints (Blueprints = master blueprint, own blueprint) and its checks, promotes and
    reverts work against its own. Returns the new blueprint's name. Does nothing when the tenant already has it. The
    master tenant follows the master blueprint alone, so it cannot have one.

    -FromCheck starts the blueprint from the tenant's own latest Full check instead of the master blueprint, so the
    blueprint is a baseline of what the tenant has and the master layer shows how far the tenant is from the master.
    It throws when the tenant has no Full check. To move a tenant blueprint that already exists onto its latest check,
    promote the differences (Approve-PEBlueprintChange).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Slug,

        [Parameter(Mandatory)]
        [string]$MasterBlueprint,

        [switch]$FromCheck,

        [string]$DataRoot
    )

    if ($Slug -eq 'master')
    {
        throw 'The master tenant follows the master blueprint and has no blueprint of its own.'
    }
    if ($Slug -ieq $MasterBlueprint)
    {
        throw "The tenant's own blueprint would be named '$Slug', the same folder as the master blueprint '$MasterBlueprint' (names are not case-sensitive on Windows). Name the master blueprint differently."
    }
    $tenant = Get-PETenant -Slug $Slug -DataRoot $DataRoot
    $directory = Get-PEBlueprintDirectory -Name $Slug -DataRoot $DataRoot
    if (@(Get-PEBlueprintVersionNumber -Directory $directory).Count -eq 0)
    {
        if ($FromCheck)
        {
            # The saved check holds the state as JSON; a State needs Meta as a hashtable.
            $state = (Get-PECheck -Latest -Kind Full -Tenant $Slug -DataRoot $DataRoot).State
            $meta = @{}
            foreach ($property in $state.Meta.PSObject.Properties) { $meta[$property.Name] = $property.Value }
            $source = New-PEState -Records @($state.Records) -NotChecked @($state.NotChecked) -Meta $meta
        }
        else
        {
            $source = Get-PEBlueprint -Name $MasterBlueprint -DataRoot $DataRoot
        }
        Initialize-PEBlueprint -Name $Slug -State $source -DataRoot $DataRoot | Out-Null
    }
    if (@($tenant.Blueprints) -join '|' -ne "$MasterBlueprint|$Slug")
    {
        Set-PETenant -Slug $Slug -Blueprints @($MasterBlueprint, $Slug) -DataRoot $DataRoot | Out-Null
    }
    return $Slug
}
