# Helpers of Invoke-PERoundTrip.

function Test-PEElevated
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    $principal = [System.Security.Principal.WindowsPrincipal]::new([System.Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-PERoundTripTool
{
    # tools\Invoke-PEApply.ps1 -TestOnly with the Reader app of the tenant, in a child pwsh with a timeout (nothing is applied). Returns the tool's
    # result object (see ConvertFrom-PEApplyToolOutput); a timeout is returned as a failed result.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$ConfigurationName,

        [string]$Tenant = 'master',

        [ValidateRange(1, 720)]
        [int]$TimeoutMinutes = 90
    )

    $tool = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'tools\Invoke-PEApply.ps1'
    $arguments = @('-NoProfile', '-NonInteractive', '-File', $tool, '-ConfigPath', $ConfigPath, '-ConfigurationName', $ConfigurationName, '-TestOnly', '-Role', 'Reader', '-Json')
    if ($Tenant -ne 'master')
    {
        $arguments += @('-AppInfoPath', (Get-PEAppInfoPath -Role Reader -Tenant $Tenant))
    }
    $run = Invoke-PEChildProcess -FilePath (Get-PERectifyPwshPath) -ArgumentList $arguments -TimeoutSeconds ($TimeoutMinutes * 60)
    if ($run.TimedOut)
    {
        return [pscustomobject]@{ Success = $false; TimedOut = $true; Error = "The test did not finish within $TimeoutMinutes minutes; its process tree was killed."; Resources = @() }
    }
    return (ConvertFrom-PEApplyToolOutput -Lines $run.StdOut -ErrorLines $run.StdErr -ExitCode $run.ExitCode)
}
