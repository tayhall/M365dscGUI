function Set-PEDecision
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [ValidateSet('Unmanaged', 'Noise', 'Remove', 'PropertyExcluded', 'RiskAccepted')]
        [string]$Kind,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ResourceType,

        [string]$Key,

        [string]$Property,

        [object]$Value,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Reason,

        # The tenant the decision is for (a slug); empty means every tenant.
        [string]$Tenant,

        # RiskAccepted only: who approved leaving the difference, and a hash of the standard's record at that time (Get-PEDecisionHash), so a
        # later change to the standard reopens it.
        [string]$ApprovedBy,

        [string]$StandardHash,

        [string]$DataRoot
    )

    if ($Kind -eq 'RiskAccepted')
    {
        if ([string]::IsNullOrWhiteSpace($Tenant))
        {
            throw 'A RiskAccepted decision requires -Tenant.'
        }
        if ([string]::IsNullOrWhiteSpace($Key))
        {
            throw 'A RiskAccepted decision requires -Key.'
        }
        if ([string]::IsNullOrWhiteSpace($ApprovedBy))
        {
            throw 'A RiskAccepted decision requires -ApprovedBy.'
        }
    }
    elseif ($Kind -eq 'Noise')
    {
        if ([string]::IsNullOrWhiteSpace($Property))
        {
            throw 'A Noise decision requires -Property.'
        }
        if (-not $PSBoundParameters.ContainsKey('Value'))
        {
            throw 'A Noise decision requires -Value.'
        }
    }
    elseif ($Kind -eq 'PropertyExcluded')
    {
        # One property of a type (or of one item, with -Key) is not enforced in one tenant: the tenant is part of the decision.
        if ([string]::IsNullOrWhiteSpace($Property))
        {
            throw 'A PropertyExcluded decision requires -Property.'
        }
        if ([string]::IsNullOrWhiteSpace($Tenant))
        {
            throw 'A PropertyExcluded decision requires -Tenant.'
        }
    }
    elseif ([string]::IsNullOrWhiteSpace($Key))
    {
        throw "A $Kind decision requires -Key."
    }

    # Identity is (Kind, ResourceType, Key) for Unmanaged and Remove, so any supplied Property is ignored.
    if ($Kind -notin 'Noise', 'PropertyExcluded', 'RiskAccepted')
    {
        $Property = $null
    }

    $decision = [ordered]@{
        Kind         = $Kind
        ResourceType = $ResourceType
        Key          = $Key
        Property     = $Property
        Value        = $(if ($PSBoundParameters.ContainsKey('Value')) { $Value } else { $null })
        Reason       = $Reason
        Tenant       = $(if ($Tenant) { $Tenant } else { $null })
        At           = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    }
    if ($Kind -eq 'RiskAccepted')
    {
        $decision['ApprovedBy'] = $ApprovedBy
        $decision['StandardHash'] = $(if ($StandardHash) { $StandardHash } else { $null })
    }

    $path = Get-PEDecisionPath -DataRoot $DataRoot
    $list = Read-PEDecisionList -Path $path
    $kept = @($list | Where-Object {
            -not (Test-PEDecisionMatch -Decision $_ -Kind $Kind -ResourceType $ResourceType -Key $Key -Property $Property -Tenant $Tenant)
        })
    $all = @($kept) + @([pscustomobject]$decision)
    Write-PEJson -Path $path -InputObject $all

    return [pscustomobject]$decision
}

function Get-PEDecision
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param
    (
        [ValidateSet('Unmanaged', 'Noise', 'Remove', 'PropertyExcluded', 'RiskAccepted')]
        [string]$Kind,

        # With a tenant: the decisions for every tenant plus the ones for that tenant.
        [string]$Tenant,

        [string]$DataRoot
    )

    $list = Read-PEDecisionList -Path (Get-PEDecisionPath -DataRoot $DataRoot)
    if ($Kind)
    {
        $list = @($list | Where-Object { $_.Kind -eq $Kind })
    }
    if ($PSBoundParameters.ContainsKey('Tenant'))
    {
        $list = @($list | Where-Object { [string]::IsNullOrEmpty([string]$_.Tenant) -or [string]$_.Tenant -ceq $Tenant })
    }
    return @($list)
}

function Remove-PEDecision
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [ValidateSet('Unmanaged', 'Noise', 'Remove', 'PropertyExcluded', 'RiskAccepted')]
        [string]$Kind,

        [Parameter(Mandatory)]
        [string]$ResourceType,

        [string]$Key,

        [string]$Property,

        [string]$Tenant,

        [string]$DataRoot
    )

    $path = Get-PEDecisionPath -DataRoot $DataRoot
    $list = Read-PEDecisionList -Path $path
    $kept = @($list | Where-Object {
            -not (Test-PEDecisionMatch -Decision $_ -Kind $Kind -ResourceType $ResourceType -Key $Key -Property $Property -Tenant $Tenant)
        })
    if ($kept.Count -ne @($list).Count)
    {
        Write-PEJson -Path $path -InputObject $kept
    }
}
