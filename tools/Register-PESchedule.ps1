<#
.SYNOPSIS
    Registers the Windows scheduled task that runs the full check for a blueprint, or removes it.
.DESCRIPTION
    Creates PE-FullCheck-<name> (daily at FullCheckAt). It runs
    pwsh.exe -NoProfile -File <repo>\tools\Invoke-PEFullCheck.ps1 -BlueprintName <name> as the current user, against the
    repository's data root. Re-running updates the existing task. Refuses if the blueprint does not exist. For a quicker
    check of one resource type or slice, see tools\Register-PEScopeSchedule.ps1.

    The tasks use LogonType Interactive: they run ONLY WHILE THE CURRENT USER IS LOGGED ON (StartWhenAvailable runs a
    missed trigger at the next logon). To run while logged off, change the task's principal in Task Scheduler to
    'Run whether user is logged on or not' (this stores credentials; the tasks read the Reader/Writer certificates
    from the user's profile, so keep the same account).

    MultipleInstances is IgnoreNew: a run is skipped while the previous run of the same task is still going. The time
    limit is 4 hours.
.PARAMETER Unregister
    Removes the task (and the PE-QuickScan-<name> task of an earlier version). Succeeds quietly if they do not exist.
.EXAMPLE
    pwsh -NoProfile -File tools\Register-PESchedule.ps1 -BlueprintName test -FullCheckAt 03:30
.EXAMPLE
    pwsh -NoProfile -File tools\Register-PESchedule.ps1 -BlueprintName test -Unregister
#>
[CmdletBinding(SupportsShouldProcess)]
param
(
    [Parameter(Mandatory)]
    [string]$BlueprintName,

    [ValidatePattern('\A([01][0-9]|2[0-3]):[0-5][0-9]\z')]
    [string]$FullCheckAt = '02:00',

    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PESchedule.Common.ps1')
Import-Module (Join-Path $PSScriptRoot '..\src\PolicyEngine\PolicyEngine.psd1') -Force -WarningAction SilentlyContinue

$arguments = @{
    BlueprintName = $BlueprintName
    FullCheckAt   = $FullCheckAt
    Unregister    = $Unregister
    PwshPath      = (Get-Process -Id $PID).Path
    ToolsPath     = $PSScriptRoot
    WhatIf        = $WhatIfPreference
}
Invoke-PESchedule @arguments | Format-List
