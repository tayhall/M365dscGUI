BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force

    function New-TestRecord
    {
        param ($Type, $Key)
        [pscustomobject]@{ ResourceType = $Type; Key = $Key; Workload = (InModuleScope PolicyEngine { param ($t) Get-PEWorkload -ResourceType $t } -Parameters @{ t = $Type }); Properties = @{} }
    }

    function New-TestFinding
    {
        param ($Kind, $Type, $Key, $State = 'Open', $Workload = $null, [switch]$Target, $BlueprintCount = $null)
        $bp = if ($Target -or $Kind -in 'TargetOnly', 'NotChecked', 'NotAvailable', 'Ambiguous') { $null } else { [pscustomobject]@{ Key = $Key } }
        [pscustomobject]@{ BlueprintRecord = $bp; Kind = $Kind; ResourceType = $Type; Key = $Key; Workload = $Workload; State = $State; BlueprintCount = $BlueprintCount }
    }

    function New-TestBlueprint
    {
        param ($Records)
        [pscustomobject]@{ Records = @($Records) }
    }
}

Describe 'Get-PEStatus' {
    It 'all-aligned workload shows Aligned equals Total' {
        $bp = New-TestBlueprint @((New-TestRecord 'AADUser' 'a'), (New-TestRecord 'AADUser' 'b'))
        $s = @(Get-PEStatus -Blueprint $bp -Findings @())
        $s.Count | Should -Be 1
        $s[0].Workload | Should -Be 'Entra ID'
        $s[0].Total | Should -Be 2
        $s[0].Aligned | Should -Be 2
        $s[0].Drifted | Should -Be 0
    }

    It 'Missing and Changed count as Drifted' {
        $bp = New-TestBlueprint @((New-TestRecord 'AADUser' 'a'), (New-TestRecord 'AADUser' 'b'), (New-TestRecord 'AADUser' 'c'))
        $f = @((New-TestFinding Missing 'AADUser' 'a' -Workload 'Entra ID'), (New-TestFinding Changed 'AADUser' 'b' -Workload 'Entra ID'))
        $s = @(Get-PEStatus -Blueprint $bp -Findings $f)
        $s[0].Drifted | Should -Be 2
        $s[0].Aligned | Should -Be 1
    }

    It 'counts a record with two findings once' {
        $bp = New-TestBlueprint @((New-TestRecord 'AADUser' 'a'), (New-TestRecord 'AADUser' 'b'))
        $f = @((New-TestFinding Changed 'AADUser' 'a'), (New-TestFinding Ambiguous 'AADUser' 'a'))
        $s = @(Get-PEStatus -Blueprint $bp -Findings $f)
        $s[0].Drifted | Should -Be 1
        $s[0].Aligned | Should -Be 1
    }

    It 'TargetOnly is Drifted and in its own column, but does not reduce Aligned' {
        $bp = New-TestBlueprint @((New-TestRecord 'AADUser' 'a'))
        $f = @((New-TestFinding TargetOnly 'AADUser' 'x'))
        $s = @(Get-PEStatus -Blueprint $bp -Findings $f)
        $s[0].Drifted | Should -Be 1
        $s[0].TargetOnly | Should -Be 1
        $s[0].Aligned | Should -Be 1
    }

    It 'Unmanaged TargetOnly is excluded from Drifted and counted under Unmanaged' {
        $bp = New-TestBlueprint @((New-TestRecord 'AADUser' 'a'))
        $f = @((New-TestFinding TargetOnly 'AADUser' 'x' -State 'Unmanaged'))
        $s = @(Get-PEStatus -Blueprint $bp -Findings $f)
        $s[0].Drifted | Should -Be 0
        $s[0].Unmanaged | Should -Be 1
        $s[0].Aligned | Should -Be 1
    }

    It 'Unkeyed records are counted and not shown as aligned' {
        $bp = New-TestBlueprint @((New-TestRecord 'IntuneX' $null), (New-TestRecord 'IntuneX' $null))
        $f = @((New-TestFinding Unkeyed 'IntuneX' $null))
        $s = @(Get-PEStatus -Blueprint $bp -Findings $f)
        $s[0].Unkeyed | Should -Be 1
        $s[0].Aligned | Should -Be 1
    }

    It 'NotChecked counts distinct types, deriving the workload when missing' {
        $bp = New-TestBlueprint @((New-TestRecord 'AADUser' 'a'))
        $f = @((New-TestFinding NotChecked 'TeamsFoo' $null), (New-TestFinding NotAvailable 'TeamsFoo' $null), (New-TestFinding NotChecked 'TeamsBar' $null))
        $s = @(Get-PEStatus -Blueprint $bp -Findings $f)
        $t = $s | Where-Object Workload -eq 'Teams'
        $t.NotChecked | Should -Be 2
        $t.Total | Should -Be 0
    }

    It 'blueprint records of a NotChecked type are not Aligned' {
        $bp = New-TestBlueprint @((New-TestRecord 'AADUser' 'a'))
        $s = @(Get-PEStatus -Blueprint $bp -Findings @((New-TestFinding NotChecked 'AADUser' $null)))
        $s[0].Aligned | Should -Be 0
        $s[0].NotChecked | Should -Be 1
    }

    It 'mixed drifted, not checked and aligned records' {
        $bp = New-TestBlueprint @((New-TestRecord 'AADUser' 'a'), (New-TestRecord 'AADUser' 'b'), (New-TestRecord 'AADGroup' 'g'), (New-TestRecord 'AADGroup' 'h'), (New-TestRecord 'AADApplication' 'z'))
        $f = @((New-TestFinding Missing 'AADUser' 'a'), (New-TestFinding NotAvailable 'AADGroup' $null))
        $s = @(Get-PEStatus -Blueprint $bp -Findings $f)
        $s[0].Total | Should -Be 5
        $s[0].Drifted | Should -Be 1
        $s[0].Aligned | Should -Be 2
        $s[0].NotChecked | Should -Be 1
    }

    It 'blueprint-side Ambiguous reduces Aligned by the blueprint records it covers' {
        $bp = New-TestBlueprint @((New-TestRecord 'AADUser' 'a'), (New-TestRecord 'AADUser' 'A'), (New-TestRecord 'AADUser' 'b'), (New-TestRecord 'AADUser' 'c'))
        $s = @(Get-PEStatus -Blueprint $bp -Findings @((New-TestFinding Ambiguous 'AADUser' 'a' -BlueprintCount 2)))
        $s[0].Drifted | Should -Be 1
        $s[0].Aligned | Should -Be 2
    }

    It 'target-side Ambiguous is Drifted but does not reduce Aligned' {
        $bp = New-TestBlueprint @((New-TestRecord 'AADUser' 'a'))
        $s = @(Get-PEStatus -Blueprint $bp -Findings @((New-TestFinding Ambiguous 'AADUser' 'x' -BlueprintCount 0)))
        $s[0].Drifted | Should -Be 1
        $s[0].Aligned | Should -Be 1
    }

    It 'target-side Unkeyed is in the Unkeyed column but does not reduce Aligned' {
        $bp = New-TestBlueprint @((New-TestRecord 'AADUser' 'a'))
        $s = @(Get-PEStatus -Blueprint $bp -Findings @((New-TestFinding Unkeyed 'AADUser' $null -Target)))
        $s[0].Unkeyed | Should -Be 1
        $s[0].Aligned | Should -Be 1
    }

    It 'Unmanaged Unkeyed is shown under Unmanaged' {
        $bp = New-TestBlueprint @((New-TestRecord 'AADUser' 'a'))
        $s = @(Get-PEStatus -Blueprint $bp -Findings @((New-TestFinding Unkeyed 'AADUser' $null -State Unmanaged)))
        $s[0].Unmanaged | Should -Be 1
        $s[0].Unkeyed | Should -Be 0
    }

    It 'accepts null and empty Findings' {
        $bp = New-TestBlueprint @((New-TestRecord 'AADUser' 'a'))
        @(Get-PEStatus -Blueprint $bp -Findings $null)[0].Aligned | Should -Be 1
        @(Get-PEStatus -Blueprint $bp -Findings @())[0].Aligned | Should -Be 1
        @(Get-PEStatus -Blueprint $bp -Findings @($null))[0].Aligned | Should -Be 1
    }

    It 'workloads with no records are omitted' {
        $bp = New-TestBlueprint @((New-TestRecord 'AADUser' 'a'))
        $s = @(Get-PEStatus -Blueprint $bp -Findings @())
        $s.Count | Should -Be 1
        $s.Workload | Should -Not -Contain 'Intune'
    }

    It 'records of an Excluded type are not counted in Total, Aligned or Drifted; the type is counted under Excluded' {
        $bp = New-TestBlueprint @((New-TestRecord 'EXOManagementRoleEntry' 'r1'), (New-TestRecord 'EXOManagementRoleEntry' 'r2'), (New-TestRecord 'EXOMailboxSettings' 'm'), (New-TestRecord 'EXOAcceptedDomain' 'd'), (New-TestRecord 'EXOAcceptedDomain' 'e'))
        $f = @(
            (New-TestFinding Excluded 'EXOManagementRoleEntry' $null -Target),
            (New-TestFinding Excluded 'exomailboxsettings' $null -Target),
            (New-TestFinding Excluded 'EXOMailboxPermission' $null -Target),
            (New-TestFinding Changed 'EXOAcceptedDomain' 'd')
        )
        $s = @(Get-PEStatus -Blueprint $bp -Findings $f)
        $s.Count | Should -Be 1
        $s[0].Workload | Should -Be 'Exchange Online'
        $s[0].Total | Should -Be 2
        $s[0].Aligned | Should -Be 1
        $s[0].Drifted | Should -Be 1
        $s[0].NotChecked | Should -Be 0
        $s[0].Excluded | Should -Be 3
    }

    It 'a workload with only excluded types is shown with Total 0' {
        $bp = New-TestBlueprint @((New-TestRecord 'AADUser' 'a'), (New-TestRecord 'EXOMailboxSettings' 'm'))
        $s = @(Get-PEStatus -Blueprint $bp -Findings @((New-TestFinding Excluded 'EXOMailboxSettings' $null -Workload 'Exchange Online' -Target)))
        $exo = $s | Where-Object Workload -eq 'Exchange Online'
        $exo.Total | Should -Be 0
        $exo.Aligned | Should -Be 0
        $exo.Excluded | Should -Be 1
        ($s | Where-Object Workload -eq 'Entra ID').Excluded | Should -Be 0
    }

    It 'EXOManagementRoleEntry: entries of custom roles are counted, entries of built-in roles are not' {
        $role = [pscustomobject]@{ ResourceType = 'EXOManagementRole'; Key = 'Custom'; Workload = 'Exchange Online'; Properties = @{ Name = 'Custom'; Parent = 'contoso\Mail Recipients' } }
        $bp = New-TestBlueprint @($role, (New-TestRecord 'EXOManagementRoleEntry' 'Custom\Get-Mailbox'), (New-TestRecord 'EXOManagementRoleEntry' 'Mail Recipients\Set-Mailbox'), (New-TestRecord 'EXOManagementRoleEntry' 'Mail Recipients\Get-User'))
        $f = @((New-TestFinding Excluded 'EXOManagementRoleEntry' $null -Target), (New-TestFinding Changed 'EXOManagementRoleEntry' 'Custom\Get-Mailbox'))
        $s = @(Get-PEStatus -Blueprint $bp -Findings $f)
        $s[0].Total | Should -Be 2
        $s[0].Drifted | Should -Be 1
        $s[0].Aligned | Should -Be 1
        $s[0].Excluded | Should -Be 1
    }

    It 'records of an excluded type are counted normally when the findings have no Excluded finding (compare run with -IncludeTypes)' {
        $bp = New-TestBlueprint @((New-TestRecord 'EXOMailboxSettings' 'm'), (New-TestRecord 'EXOMailboxSettings' 'n'))
        $s = @(Get-PEStatus -Blueprint $bp -Findings @((New-TestFinding Changed 'EXOMailboxSettings' 'm')))
        $s[0].Total | Should -Be 2
        $s[0].Aligned | Should -Be 1
        $s[0].Excluded | Should -Be 0
    }

    It 'sorts workloads Entra ID, Intune, Exchange Online, Teams, Other' {
        $bp = New-TestBlueprint @((New-TestRecord 'Foo' 'a'), (New-TestRecord 'TeamsX' 'a'), (New-TestRecord 'EXOX' 'a'), (New-TestRecord 'IntuneX' 'a'), (New-TestRecord 'AADUser' 'a'))
        (Get-PEStatus -Blueprint $bp -Findings @()).Workload -join ',' | Should -Be 'Entra ID,Intune,Exchange Online,Teams,Other'
    }
}

Describe 'Format-PEStatus' {
    BeforeAll {
        $bp = New-TestBlueprint @((New-TestRecord 'AADUser' 'a'))
        $script:Status = @(Get-PEStatus -Blueprint $bp -Findings @())
    }

    It 'prints the age of the last full check' {
        $when = [datetime]::UtcNow.AddHours(-3).AddMinutes(-12)
        $text = Format-PEStatus -Status $script:Status -LastFullCheck $when
        $text | Should -Match 'Entra ID'
        $lines = $text -split "`r?`n"
        $lines[-1] | Should -Match '^Last full check: 3 h 1\d min ago \(\d{4}-\d\d-\d\d \d\d:\d\d UTC\)$'
    }

    It 'treats an Unspecified datetime as UTC' {
        $when = [datetime]::SpecifyKind([datetime]::UtcNow.AddHours(-2), 'Unspecified')
        $lines = (Format-PEStatus -Status $script:Status -LastFullCheck $when) -split "`r?`n"
        $lines[-1] | Should -Match '^Last full check: 2 h \d+ min ago|^Last full check: 1 h 5\d min ago'
    }

    It 'labels the NotChecked column as types' {
        (Format-PEStatus -Status $script:Status) | Should -Match 'NotChecked \(types\)'
    }

    It 'shows the Excluded column as types' {
        (Format-PEStatus -Status $script:Status) | Should -Match 'Excluded \(types\)'
    }

    It 'says never when no full check is supplied' {
        $lines = (Format-PEStatus -Status $script:Status) -split "`r?`n"
        $lines[-1] | Should -Be 'Last full check: never'
    }

    It 'marks a check older than 36 h as stale' {
        $lines = (Format-PEStatus -Status $script:Status -LastFullCheck ([datetime]::UtcNow.AddHours(-40))) -split "`r?`n"
        $lines[-1] | Should -Match ' - STALE$'
    }
}
