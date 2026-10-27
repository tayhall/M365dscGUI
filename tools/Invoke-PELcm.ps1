<#
.SYNOPSIS
    Applies or tests one compiled Microsoft365DSC configuration through the Local Configuration Manager (Windows PowerShell 5.1).

.DESCRIPTION
    Called by Invoke-PEApply.ps1 (PowerShell 7), because Start-DscConfiguration and Test-DscConfiguration only run in Windows
    PowerShell 5.1 and need an elevated session (Microsoft365DSC: docs/user-guide/get-started/deploying-configurations.md and
    powershell7-support.md). The LCM relays every resource call into a PowerShell 7 session; the resources themselves run on 7.
    Prints one JSON line: { Error, Overall (a test's overall result, when known), Detailed (false when a test returned no per-resource lists),
    InDesiredState: [resource id], NotInDesiredState: [{ ResourceId, Error }] }.
    -Mode Apply: Start-DscConfiguration -Wait -Force, then Get-DscConfigurationStatus; afterwards the configuration is removed from
    the LCM (Remove-DscConfigurationDocument), because the LCM would otherwise keep re-testing the tenant on its own schedule.
    -Mode Test: Test-DscConfiguration -ReferenceConfiguration, nothing is applied or stored.
    This file must stay 5.1 compatible (no ternary, no ?.).
#>
[CmdletBinding()]
param
(
    [Parameter(Mandatory)]
    [string]$MofPath,

    [Parameter(Mandatory)]
    [ValidateSet('Apply', 'Test')]
    [string]$Mode
)

$ErrorActionPreference = 'Stop'
$errorText = $null
$inDesired = @()
$notInDesired = @()
$overall = $null
$detailed = $true
try
{
    if ($Mode -eq 'Test')
    {
        # -ReferenceConfiguration cannot be combined with -Detailed (separate parameter sets), so the result is whatever this form returns:
        # a plain True/False, or an object with the per-resource lists. The caller is told which one it got.
        $state = Test-DscConfiguration -ReferenceConfiguration $MofPath
        if ($state -is [bool] -or $state -is [string])
        {
            $overall = ([string]$state -eq 'True')
        }
        else
        {
            if ($state.PSObject.Properties['InDesiredState']) { $overall = [bool]$state.InDesiredState }
            if ($state.PSObject.Properties['ResourcesInDesiredState'])
            {
                $detailed = $true
                $inDesired = @($state.ResourcesInDesiredState)
                $notInDesired = @($state.ResourcesNotInDesiredState)
            }
        }    }
    else
    {
        try
        {
            Start-DscConfiguration -Path (Split-Path -Parent $MofPath) -Wait -Force | Out-Null
        }
        catch
        {
            # A failed resource also surfaces here; the status below says which one.
            $errorText = $_.Exception.Message
        }
        $state = Get-DscConfigurationStatus
        $inDesired = @($state.ResourcesInDesiredState)
        $notInDesired = @($state.ResourcesNotInDesiredState)
    }
}
catch
{
    $errorText = $_.Exception.Message
}
finally
{
    if ($Mode -eq 'Apply')
    {
        foreach ($stage in 'Current', 'Pending', 'Previous')
        {
            try { Remove-DscConfigurationDocument -Stage $stage -Force } catch { }
        }
    }
}

$output = [ordered]@{
    Error             = $errorText
    Overall           = $overall
    Detailed          = $detailed
    InDesiredState    = @($inDesired | Where-Object { $_ } | ForEach-Object { [string]$_.ResourceId })
    NotInDesiredState = @($notInDesired | Where-Object { $_ } | ForEach-Object { [ordered]@{ ResourceId = [string]$_.ResourceId; Error = $(if ($_.Error) { [string]$_.Error } else { $null }) } })
}
ConvertTo-Json -InputObject $output -Compress -Depth 5
