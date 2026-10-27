# Logic behind tools\Register-PESchedule.ps1, kept free of side effects so tests can run it. Everything that touches
# the Windows Task Scheduler lives in the *-PETask* wrapper functions at the bottom; tests mock those.

function ConvertTo-PEQuotedPath
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($Path -match '\s')
    {
        return ('"{0}"' -f $Path)
    }
    return $Path
}

function Get-PEScheduleDefinition
{
    <#
    .SYNOPSIS
    Builds the task definition (a plain object) of the daily full check for a blueprint. Does not register anything.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param
    (
        [Parameter(Mandatory)]
        [string]$BlueprintName,

        [ValidatePattern('\A([01][0-9]|2[0-3]):[0-5][0-9]\z')]
        [string]$FullCheckAt = '02:00',

        [Parameter(Mandatory)]
        [string]$PwshPath,

        [Parameter(Mandatory)]
        [string]$ToolsPath
    )

    $full = ConvertTo-PEQuotedPath -Path (Join-Path $ToolsPath 'Invoke-PEFullCheck.ps1')
    $execute = ConvertTo-PEQuotedPath -Path $PwshPath

    [pscustomobject]@{
        FullCheck = [pscustomobject]@{
            TaskName           = "PE-FullCheck-$BlueprintName"
            Execute            = $execute
            Argument           = "-NoProfile -File $full -BlueprintName $BlueprintName"
            Trigger            = 'Daily'
            RepeatEvery        = $null
            At                 = $FullCheckAt
            ExecutionTimeLimit = [timespan]::FromHours(4)
        }
    }
}

function Invoke-PESchedule
{
    <#
    .SYNOPSIS
    Registers (or updates) the full-check task for a blueprint, or removes it with -Unregister (which also removes the
    PE-QuickScan-<blueprint> task an earlier version registered).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param
    (
        [Parameter(Mandatory)]
        [string]$BlueprintName,

        [ValidatePattern('\A([01][0-9]|2[0-3]):[0-5][0-9]\z')]
        [string]$FullCheckAt = '02:00',

        [switch]$Unregister,

        [Parameter(Mandatory)]
        [string]$PwshPath,

        [Parameter(Mandatory)]
        [string]$ToolsPath
    )

    if ($Unregister)
    {
        # No blueprint check: tasks of a deleted blueprint must still be removable. The name only forms task names.
        if ($BlueprintName -notmatch '\A[A-Za-z0-9][A-Za-z0-9._-]*\z')
        {
            throw "Invalid blueprint name '$BlueprintName'."
        }
    }
    else
    {
        # Get-PEBlueprint validates the name with the engine's own rule and throws if no version exists.
        $null = Get-PEBlueprint -Name $BlueprintName -Version 'latest'
    }

    $definition = Get-PEScheduleDefinition -BlueprintName $BlueprintName -FullCheckAt $FullCheckAt -PwshPath $PwshPath -ToolsPath $ToolsPath

    if ($Unregister -and $PSCmdlet.ShouldProcess("PE-QuickScan-$BlueprintName", 'Unregister scheduled task'))
    {
        Unregister-PETask -TaskName "PE-QuickScan-$BlueprintName"
    }
    foreach ($task in @($definition.FullCheck))
    {
        if ($Unregister)
        {
            if ($PSCmdlet.ShouldProcess($task.TaskName, 'Unregister scheduled task'))
            {
                Unregister-PETask -TaskName $task.TaskName
            }
        }
        elseif ($PSCmdlet.ShouldProcess($task.TaskName, 'Register scheduled task'))
        {
            Register-PETask -Definition $task
            [pscustomobject]@{
                TaskName    = $task.TaskName
                NextRunTime = Get-PETaskNextRun -TaskName $task.TaskName
                CommandLine = "$($task.Execute) $($task.Argument)"
            }
        }
    }
}

function Register-PETask
{
    # Thin wrapper over the Task Scheduler: current user, interactive logon only, never two instances of one task.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [pscustomobject]$Definition
    )

    $action = New-ScheduledTaskAction -Execute $Definition.Execute -Argument $Definition.Argument
    if ($Definition.Trigger -eq 'Daily')
    {
        $trigger = New-ScheduledTaskTrigger -Daily -At $Definition.At
    }
    else
    {
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval $Definition.RepeatEvery
    }
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit $Definition.ExecutionTimeLimit `
        -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive

    # -Force replaces a task of the same name, so a re-run updates instead of duplicating.
    $null = Register-ScheduledTask -TaskName $Definition.TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Principal $principal -Force
}

function Unregister-PETask
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$TaskName
    )

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
    {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
}

function Get-PETaskNextRun
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$TaskName
    )

    (Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue).NextRunTime
}

function Get-PEScopeTaskDefinition
{
    <#
    .SYNOPSIS
    The task definition (a plain object) that runs one scope check for a blueprint: PE-Scope-<blueprint>-<scope>, either
    repeating every -EveryMinutes or daily at -DailyAt. Does not register anything.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param
    (
        [Parameter(Mandatory)]
        [string]$BlueprintName,

        [Parameter(Mandatory)]
        [ValidatePattern('\A[A-Za-z0-9][A-Za-z0-9_-]{0,40}\z')]
        [string]$Scope,

        [ValidateRange(5, 1440)]
        [int]$EveryMinutes,

        [ValidatePattern('\A([01][0-9]|2[0-3]):[0-5][0-9]\z')]
        [string]$DailyAt,

        [Parameter(Mandatory)]
        [string]$PwshPath,

        [Parameter(Mandatory)]
        [string]$ToolsPath
    )

    if ($BlueprintName -notmatch '\A[A-Za-z0-9][A-Za-z0-9._-]*\z')
    {
        throw "Invalid blueprint name '$BlueprintName'."
    }
    $hasEvery = $PSBoundParameters.ContainsKey('EveryMinutes')
    $hasDaily = $PSBoundParameters.ContainsKey('DailyAt')
    if ($hasEvery -eq $hasDaily)
    {
        throw 'Give exactly one of -EveryMinutes and -DailyAt.'
    }
    $script = ConvertTo-PEQuotedPath -Path (Join-Path $ToolsPath 'Invoke-PEScopeCheck.ps1')
    [pscustomobject]@{
        TaskName           = "PE-Scope-$BlueprintName-$Scope"
        Execute            = (ConvertTo-PEQuotedPath -Path $PwshPath)
        Argument           = "-NoProfile -File $script -BlueprintName $BlueprintName -Scope $Scope"
        Trigger            = $(if ($hasDaily) { 'Daily' } else { 'Repeat' })
        RepeatEvery        = $(if ($hasEvery) { [timespan]::FromMinutes($EveryMinutes) } else { $null })
        At                 = $(if ($hasDaily) { $DailyAt } else { $null })
        ExecutionTimeLimit = [timespan]::FromHours(1)
    }
}

function Invoke-PEScopeSchedule
{
    <#
    .SYNOPSIS
    Registers (or updates) the scheduled task of a scope check, or removes it with -Unregister.
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

        [switch]$Unregister,

        [Parameter(Mandatory)]
        [string]$PwshPath,

        [Parameter(Mandatory)]
        [string]$ToolsPath
    )

    $arguments = @{ BlueprintName = $BlueprintName; Scope = $Scope; PwshPath = $PwshPath; ToolsPath = $ToolsPath }
    if ($Unregister)
    {
        # The name only forms the task name; tasks of a deleted scope must still be removable.
        $arguments.EveryMinutes = 30
    }
    else
    {
        $null = Get-PEBlueprint -Name $BlueprintName -Version 'latest'
        $null = Get-PEScope -Name $Scope
        foreach ($name in 'EveryMinutes', 'DailyAt')
        {
            if ($PSBoundParameters.ContainsKey($name)) { $arguments[$name] = $PSBoundParameters[$name] }
        }
    }
    $task = Get-PEScopeTaskDefinition @arguments
    if ($Unregister)
    {
        if ($PSCmdlet.ShouldProcess($task.TaskName, 'Unregister scheduled task')) { Unregister-PETask -TaskName $task.TaskName }
    }
    elseif ($PSCmdlet.ShouldProcess($task.TaskName, 'Register scheduled task'))
    {
        Register-PETask -Definition $task
        [pscustomobject]@{ TaskName = $task.TaskName; NextRunTime = Get-PETaskNextRun -TaskName $task.TaskName; CommandLine = "$($task.Execute) $($task.Argument)" }
    }
}
