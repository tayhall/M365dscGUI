$script:PEWorkloads = $null

function Get-PEWorkloadDefinition
{
    # The supported workloads from Data\Workloads.psd1 (Prefix, Name, Default). One place for the prefix rule: the label of a
    # resource type, the default export set and the resources the apps need permissions for all read it.
    [CmdletBinding()]
    param ()

    if ($null -eq $script:PEWorkloads)
    {
        $data = Import-PowerShellDataFile -Path (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'Data') 'Workloads.psd1')
        $script:PEWorkloads = @($data.Workloads)
    }
    return $script:PEWorkloads
}

function Get-PEWorkload
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$ResourceType
    )

    foreach ($workload in @(Get-PEWorkloadDefinition))
    {
        if ($ResourceType.StartsWith($workload.Prefix, [System.StringComparison]::OrdinalIgnoreCase))
        {
            return [string]$workload.Name
        }
    }
    return 'Other'
}

function Get-PEDefaultWorkload
{
    # Prefixes exported by a full check unless -Workloads says otherwise.
    [CmdletBinding()]
    [OutputType([string[]])]
    param ()

    return [string[]]@(Get-PEWorkloadDefinition | Where-Object { $_.Default } | ForEach-Object { $_.Prefix })
}

function Get-PEWorkloadPattern
{
    # Regular expression on a DSC resource name that selects every supported workload (the resources the apps are sized for).
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    return '^(' + ((Get-PEWorkloadDefinition | ForEach-Object { $_.Prefix }) -join '|') + ')'
}

function Get-PEOwnProcessPrefix
{
    # Prefixes of the workloads that must be exported in a process of their own (Data\Workloads.psd1, OwnProcess).
    [CmdletBinding()]
    [OutputType([string[]])]
    param ()

    return [string[]]@(Get-PEWorkloadDefinition | Where-Object { $_.ContainsKey('OwnProcess') -and $_.OwnProcess } | ForEach-Object { $_.Prefix })
}
