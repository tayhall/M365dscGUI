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
