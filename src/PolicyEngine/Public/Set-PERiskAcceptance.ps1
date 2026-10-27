function Set-PERiskAcceptance
{
    <#
    .SYNOPSIS
    Records that the difference between a tenant and one item of a standard is accepted: who approved it and why.

    .DESCRIPTION
    Writes a RiskAccepted decision (Set-PEDecision) for one tenant and one item of the latest version of the standard, or one property of
    it. It remembers a hash of the standard's record, so when a newer version of the standard changes the item the acceptance is shown as
    needing another look. The tool is not a record of risk: this is the lightweight note that lets a difference be set aside on purpose.
    Remove it with Remove-PEDecision -Kind RiskAccepted.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Standard,

        [Parameter(Mandatory)]
        [ValidatePattern('(?-i)\A[a-z0-9][a-z0-9-]{0,39}\z')]
        [string]$Tenant,

        [Parameter(Mandatory)]
        [string]$ResourceType,

        [Parameter(Mandatory)]
        [string]$Key,

        # Accept only this property of the item (it must be one the standard states).
        [string]$Property,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ApprovedBy,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Reason,

        [string]$DataRoot
    )

    if ($null -eq (Get-PEStandardInfo -Name $Standard -DataRoot $DataRoot))
    {
        throw "'$Standard' is not a standard (import one with Import-PEStandard)."
    }
    $record = @((Get-PEBlueprint -Name $Standard -DataRoot $DataRoot).Records | Where-Object { [string]$_.ResourceType -ieq $ResourceType -and [string]$_.Key -ieq $Key })[0]
    if ($null -eq $record)
    {
        throw "Standard '$Standard' has no item $ResourceType '$Key'."
    }
    if ($Property -and (Get-PEPropertyBag -Record $record).get_Keys() -inotcontains $Property)
    {
        throw "Standard '$Standard' does not state the property '$Property' of $ResourceType '$Key'."
    }

    $arguments = @{
        Kind         = 'RiskAccepted'
        ResourceType = [string]$record.ResourceType
        Key          = [string]$record.Key
        Tenant       = $Tenant
        ApprovedBy   = $ApprovedBy
        Reason       = $Reason
        StandardHash = (Get-PEDecisionHash -Record $record)
        DataRoot     = $DataRoot
    }
    if ($Property)
    {
        $arguments['Property'] = $Property
    }
    Set-PEDecision @arguments
}
