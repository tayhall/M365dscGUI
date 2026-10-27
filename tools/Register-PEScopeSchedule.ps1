<#
.SYNOPSIS
    Registers a Windows scheduled task that runs one scope check for a blueprint, or removes it.
.DESCRIPTION
    Creates PE-Scope-<blueprint>-<scope>: repeating every -EveryMinutes or daily at -DailyAt (give exactly one). Runs
    pwsh.exe -NoProfile -File tools\Invoke-PEScopeCheck.ps1 as the current user, only while that user is logged on, one
    instance at a time, with a one hour limit. A Full check must exist before the first run. Re-running updates the task.
.EXAMPLE
    pwsh -NoProfile -File tools\Register-PEScopeSchedule.ps1 -BlueprintName test -Scope ca-policies -EveryMinutes 60
.EXAMPLE
    pwsh -NoProfile -File tools\Register-PEScopeSchedule.ps1 -BlueprintName test -Scope ca-policies -Unregister
#>
[CmdletBinding(SupportsShouldProcess)]
param
(
    [Parameter(Mandatory)]
    [string]$BlueprintName,

    [Parameter(Mandatory)]
    [string]$Scope,

    [ValidateRange(5, 1440)]
    [int]$EveryMinutes,

    [ValidatePattern('\A([01][0-9]|2[0-3]):[0-5][0-9]\z')]
    [string]$DailyAt,

    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PESchedule.Common.ps1')
Import-Module (Join-Path $PSScriptRoot '..\src\PolicyEngine\PolicyEngine.psd1') -Force -WarningAction SilentlyContinue

$arguments = @{
    BlueprintName = $BlueprintName
    Scope         = $Scope
    Unregister    = $Unregister
    PwshPath      = (Get-Process -Id $PID).Path
    ToolsPath     = $PSScriptRoot
    WhatIf        = $WhatIfPreference
}
foreach ($name in 'EveryMinutes', 'DailyAt')
{
    if ($PSBoundParameters.ContainsKey($name)) { $arguments[$name] = $PSBoundParameters[$name] }
}
Invoke-PEScopeSchedule @arguments | Format-List
