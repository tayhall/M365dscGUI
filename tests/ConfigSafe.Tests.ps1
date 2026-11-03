BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
}

Describe 'ConvertTo-PEDscConfigSafe' {
    BeforeEach {
        InModuleScope PolicyEngine {
            Mock ConvertTo-PEDscConfig {
                if (@($Plan.Key) -contains 'bad') { throw 'bad is refused' }
                'TEXT:' + (@($Plan.Key) -join ',')
            }
            function script:New-Entry { param ([string]$Key) [pscustomobject]@{ Plan = [pscustomobject]@{ Key = $Key }; Finding = [pscustomobject]@{ Key = $Key }; Action = 'Create' } }
        }
    }

    It 'returns text for all entries when none is refused' {
        InModuleScope PolicyEngine {
            $r = ConvertTo-PEDscConfigSafe -Entry @((New-Entry 'a'), (New-Entry 'b'), (New-Entry 'c')) -ConfigurationName 'PE_X' -Target Replica
            $r.Text | Should -Be 'TEXT:a,b,c'
            @($r.Refused).Count | Should -Be 0
        }
    }

    It 'refuses only the entry that fails and generates the rest' {
        InModuleScope PolicyEngine {
            $r = ConvertTo-PEDscConfigSafe -Entry @((New-Entry 'a'), (New-Entry 'bad'), (New-Entry 'c')) -ConfigurationName 'PE_X' -Target Replica
            $r.Text | Should -Be 'TEXT:a,c'
            @($r.Refused).Count | Should -Be 1
            $r.Refused[0].Reason | Should -Be 'bad is refused'
            $r.Refused[0].Entry.Plan.Key | Should -Be 'bad'
            Should -Invoke ConvertTo-PEDscConfig -ParameterFilter { (@($Plan.Key) -join ',') -eq 'a,c' } -Times 1 -Exactly
        }
    }

    It 'returns null text when every entry is refused' {
        InModuleScope PolicyEngine {
            $r = ConvertTo-PEDscConfigSafe -Entry @((New-Entry 'bad'), (New-Entry 'bad')) -ConfigurationName 'PE_X' -Target Replica
            $r.Text | Should -BeNullOrEmpty
            @($r.Refused).Count | Should -Be 2
        }
    }

    It 'returns null text and nothing refused for no entries' {
        InModuleScope PolicyEngine {
            $r = ConvertTo-PEDscConfigSafe -Entry @() -ConfigurationName 'PE_X' -Target Replica
            $r.Text | Should -BeNullOrEmpty
            @($r.Refused).Count | Should -Be 0
        }
    }

    It 'keeps the order of the entries that pass' {
        InModuleScope PolicyEngine {
            $r = ConvertTo-PEDscConfigSafe -Entry @((New-Entry 'z'), (New-Entry 'bad'), (New-Entry 'a'), (New-Entry 'm')) -ConfigurationName 'PE_X' -Target Replica
            $r.Text | Should -Be 'TEXT:z,a,m'
        }
    }
}

Describe 'New-PERectifyPlanSafe' {
    BeforeEach {
        $global:PEPlanCalls = 0
        InModuleScope PolicyEngine {
            Mock New-PERectifyPlan {
                $global:PEPlanCalls++
                if (@($Findings).Key -contains 'bad') { throw "bad is refused`nsecond line" }
                @($Findings | ForEach-Object { [pscustomobject]@{ Action = $Action; ResourceType = $_.ResourceType; Key = $_.Key } })
            }
            function script:New-F { param ([string]$Key) [pscustomobject]@{ Kind = 'Missing'; ResourceType = 'AADGroup'; Key = $Key } }
        }
    }
    AfterEach { Remove-Variable -Name PEPlanCalls -Scope Global -ErrorAction SilentlyContinue }

    It 'plans all findings of an action in one call when none is refused, in their order' {
        InModuleScope PolicyEngine {
            $r = New-PERectifyPlanSafe -Finding @((New-F 'a'), (New-F 'b'), (New-F 'c')) -Action Create -Source ([pscustomobject]@{}) -Blueprint ([pscustomobject]@{})
            @($r.Planned.Finding.Key) | Should -Be @('a', 'b', 'c')
            @($r.Planned.Plan.Key) | Should -Be @('a', 'b', 'c')
            @($r.Planned.Action | Select-Object -Unique) | Should -Be @('Create')
            @($r.Refused).Count | Should -Be 0
            $global:PEPlanCalls | Should -Be 1
        }
    }

    It 'finds the refused finding, gives its message on one line and plans the rest' {
        InModuleScope PolicyEngine {
            $r = New-PERectifyPlanSafe -Finding @((New-F 'a'), (New-F 'bad'), (New-F 'c')) -Action Create -Source ([pscustomobject]@{}) -Blueprint ([pscustomobject]@{})
            @($r.Planned.Finding.Key) | Should -Be @('a', 'c')
            @($r.Refused).Count | Should -Be 1
            $r.Refused[0].Finding.Key | Should -Be 'bad'
            $r.Refused[0].Reason | Should -Be 'bad is refused'
        }
    }

    It 'needs far fewer calls than findings when one is refused' {
        InModuleScope PolicyEngine {
            $findings = @(1..40 | ForEach-Object { New-F "k$_" }) + (New-F 'bad')
            $r = New-PERectifyPlanSafe -Finding $findings -Action Create -Source ([pscustomobject]@{}) -Blueprint ([pscustomobject]@{})
            @($r.Planned).Count | Should -Be 40
            @($r.Refused).Count | Should -Be 1
            $global:PEPlanCalls | Should -BeLessThan 25
        }
    }

    It 'passes the decisions on and returns nothing for no findings' {
        InModuleScope PolicyEngine {
            $r = New-PERectifyPlanSafe -Finding @() -Action Remove -Source ([pscustomobject]@{}) -Blueprint ([pscustomobject]@{})
            @($r.Planned).Count | Should -Be 0
            $global:PEPlanCalls | Should -Be 0
            $d = [pscustomobject]@{ Kind = 'Remove'; ResourceType = 'AADGroup'; Key = 'a' }
            New-PERectifyPlanSafe -Finding @((New-F 'a')) -Action Remove -Source ([pscustomobject]@{}) -Blueprint ([pscustomobject]@{}) -Decision @($d) | Out-Null
            Should -Invoke New-PERectifyPlan -ParameterFilter { @($Decisions).Count -eq 1 -and $Action -eq 'Remove' } -Times 1 -Exactly
        }
    }
}
