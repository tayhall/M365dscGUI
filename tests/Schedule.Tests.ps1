BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    . "$PSScriptRoot\..\tools\PESchedule.Common.ps1"
    $script:Pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
    $script:Tools = 'D:\My Repo\tools'
}

Describe 'Get-PEScheduleDefinition' {
    BeforeAll {
        $script:Def = Get-PEScheduleDefinition -BlueprintName 'test' -PwshPath $script:Pwsh -ToolsPath $script:Tools
    }

    It 'names the task PE-FullCheck-<name>' {
        $script:Def.FullCheck.TaskName | Should -Be 'PE-FullCheck-test'
    }

    It 'builds the exact command line, quoting paths with spaces' {
        $script:Def.FullCheck.Execute | Should -Be '"C:\Program Files\PowerShell\7\pwsh.exe"'
        $script:Def.FullCheck.Argument | Should -Be '-NoProfile -File "D:\My Repo\tools\Invoke-PEFullCheck.ps1" -BlueprintName test'
    }

    It 'leaves paths without spaces unquoted' {
        $d = Get-PEScheduleDefinition -BlueprintName 'x' -PwshPath 'C:\pwsh.exe' -ToolsPath 'D:\r\tools'
        $d.FullCheck.Execute | Should -Be 'C:\pwsh.exe'
        $d.FullCheck.Argument | Should -Be '-NoProfile -File D:\r\tools\Invoke-PEFullCheck.ps1 -BlueprintName x'
    }

    It 'runs the full check daily at 02:00 by default' {
        $script:Def.FullCheck.Trigger | Should -Be 'Daily'
        $script:Def.FullCheck.At | Should -Be '02:00'
    }

    It 'honors a custom time and sets the time limit' {
        $d = Get-PEScheduleDefinition -BlueprintName 'x' -FullCheckAt '23:59' -PwshPath 'p' -ToolsPath 't'
        $d.FullCheck.At | Should -Be '23:59'
        $d.FullCheck.ExecutionTimeLimit | Should -Be ([timespan]::FromHours(4))
    }

    It 'rejects the time <At>' -ForEach @(@{ At = '24:00' }, @{ At = '2:00' }, @{ At = '02:60' }, @{ At = 'noon' }) {
        { Get-PEScheduleDefinition -BlueprintName 'x' -FullCheckAt $At -PwshPath 'p' -ToolsPath 't' } | Should -Throw
    }
}

Describe 'Invoke-PESchedule' {
    BeforeEach {
        Mock Register-PETask {}
        Mock Unregister-PETask {}
        Mock Get-PETaskNextRun { [datetime]'2026-10-22 02:00' }
        Mock Get-PEBlueprint {}
        $script:Common = @{ PwshPath = 'C:\pwsh.exe'; ToolsPath = 'D:\r\tools' }
    }

    It 'registers the full-check task and reports its name, next run and command line' {
        $out = @(Invoke-PESchedule -BlueprintName 'test' @script:Common)
        Should -Invoke Register-PETask -Times 1 -Exactly
        $out.TaskName | Should -Be @('PE-FullCheck-test')
        $out[0].NextRunTime | Should -Be ([datetime]'2026-10-22 02:00')
        $out[0].CommandLine | Should -Be 'C:\pwsh.exe -NoProfile -File D:\r\tools\Invoke-PEFullCheck.ps1 -BlueprintName test'
    }

    It 'refuses when the blueprint does not exist and registers nothing' {
        Mock Get-PEBlueprint { throw "Blueprint 'nope' not found" }
        { Invoke-PESchedule -BlueprintName 'nope' @script:Common } | Should -Throw '*not found*'
        Should -Invoke Register-PETask -Times 0 -Exactly
    }

    It '-Unregister removes the full-check task and the quick-scan task of an earlier version, without checking the blueprint' {
        Invoke-PESchedule -BlueprintName 'test' -Unregister @script:Common
        Should -Invoke Unregister-PETask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'PE-QuickScan-test' }
        Should -Invoke Unregister-PETask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'PE-FullCheck-test' }
        Should -Invoke Get-PEBlueprint -Times 0 -Exactly
        Should -Invoke Register-PETask -Times 0 -Exactly
    }

    It '-WhatIf changes nothing' {
        Invoke-PESchedule -BlueprintName 'test' -WhatIf @script:Common
        Invoke-PESchedule -BlueprintName 'test' -Unregister -WhatIf @script:Common
        Should -Invoke Register-PETask -Times 0 -Exactly
        Should -Invoke Unregister-PETask -Times 0 -Exactly
    }
}

Describe 'Invoke-PESchedule with the real engine validation' {
    BeforeEach {
        Mock Register-PETask {}
    }

    It 'throws for an invalid name' {
        { Invoke-PESchedule -BlueprintName '..\evil' -PwshPath 'p' -ToolsPath 't' } | Should -Throw '*Invalid blueprint name*'
        Should -Invoke Register-PETask -Times 0 -Exactly
    }

    It 'throws for a blueprint that does not exist' {
        { Invoke-PESchedule -BlueprintName 'no-such-blueprint-xyz' -PwshPath 'p' -ToolsPath 't' } | Should -Throw '*not found*'
        Should -Invoke Register-PETask -Times 0 -Exactly
    }
}

Describe 'Get-PEScopeTaskDefinition' {
    It 'names the task PE-Scope-<blueprint>-<scope> and builds the command line' {
        $d = Get-PEScopeTaskDefinition -BlueprintName 'test' -Scope 'ca-policies' -EveryMinutes 60 -PwshPath $script:Pwsh -ToolsPath $script:Tools
        $d.TaskName | Should -Be 'PE-Scope-test-ca-policies'
        $d.Argument | Should -Be '-NoProfile -File "D:\My Repo\tools\Invoke-PEScopeCheck.ps1" -BlueprintName test -Scope ca-policies'
        $d.Trigger | Should -Be 'Repeat'
        $d.RepeatEvery | Should -Be ([timespan]::FromMinutes(60))
        $d.ExecutionTimeLimit | Should -Be ([timespan]::FromHours(1))
    }

    It 'runs daily when given -DailyAt' {
        $d = Get-PEScopeTaskDefinition -BlueprintName 'test' -Scope 'roles' -DailyAt '06:30' -PwshPath 'p' -ToolsPath 't'
        $d.Trigger | Should -Be 'Daily'
        $d.At | Should -Be '06:30'
    }

    It 'needs exactly one of -EveryMinutes and -DailyAt, and a safe scope name' {
        { Get-PEScopeTaskDefinition -BlueprintName 'test' -Scope 'a' -PwshPath 'p' -ToolsPath 't' } | Should -Throw '*exactly one*'
        { Get-PEScopeTaskDefinition -BlueprintName 'test' -Scope 'a' -EveryMinutes 10 -DailyAt '01:00' -PwshPath 'p' -ToolsPath 't' } | Should -Throw '*exactly one*'
        { Get-PEScopeTaskDefinition -BlueprintName 'test' -Scope 'a b; calc' -EveryMinutes 10 -PwshPath 'p' -ToolsPath 't' } | Should -Throw
    }
}

Describe 'Invoke-PEScopeSchedule' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-sched-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Temp | Out-Null
    }

    AfterEach {
        Remove-Item $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'registers through the task wrapper and unregisters without checking the scope exists' {
        Mock Register-PETask { }
        Mock Get-PETaskNextRun { [datetime]'2026-10-23T06:30:00' }
        Mock Unregister-PETask { }
        Mock Get-PEBlueprint { [pscustomobject]@{} }
        Mock Get-PEScope { [pscustomobject]@{ Name = 'roles' } }
        Invoke-PEScopeSchedule -BlueprintName 'test' -Scope 'roles' -DailyAt '06:30' -PwshPath 'p' -ToolsPath 't' | Out-Null
        Should -Invoke Register-PETask -Times 1 -ParameterFilter { $Definition.TaskName -eq 'PE-Scope-test-roles' }
        Invoke-PEScopeSchedule -BlueprintName 'test' -Scope 'gone' -Unregister -PwshPath 'p' -ToolsPath 't'
        Should -Invoke Unregister-PETask -Times 1 -ParameterFilter { $TaskName -eq 'PE-Scope-test-gone' }
    }
}
