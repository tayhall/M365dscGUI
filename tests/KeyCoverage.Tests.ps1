# Evaluated at discovery so -Skip can use it.
$script:ExportPath = Join-Path $PSScriptRoot '..\data\exports\first-full-reader\full-export.ps1'
$script:HasExport = Test-Path -LiteralPath $script:ExportPath

BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force

    $script:ExportPath = Join-Path $PSScriptRoot '..\data\exports\first-full-reader\full-export.ps1'
    $script:HasExport = Test-Path -LiteralPath $script:ExportPath

    # Types whose remaining Ambiguous groups are real duplicates in the data (see docs/key-coverage.md).
    # tools/Measure-PEKeyCoverage.ps1 prints the live list under 'Ambiguous allow-list'.
    $script:AmbiguousAllowList = @('EXOManagementRoleEntry')

    if ($script:HasExport)
    {
        # Parse once; Read-PEExport is the slow step.
        $script:Records = & (Get-Module PolicyEngine) {
            param ($Path)
            @(Read-PEExport -Path $Path 3>$null | ForEach-Object { ConvertTo-PENormalizedRecord -Record $_ })
        } $script:ExportPath

        $script:AmbiguousTypes = @(foreach ($group in ($script:Records | Where-Object { $_.Key } | Group-Object ResourceType))
            {
                if (@($group.Group | Group-Object Key | Where-Object Count -gt 1).Count -gt 0)
                {
                    $group.Name
                }
            })
    }
}

Describe 'Composite keys' {
    It 'joins the parts of a string[] override with " | " in the order given' {
        InModuleScope PolicyEngine {
            Get-PEResourceKey -ResourceType 'TeamsChannel' -Properties @{ DisplayName = 'General'; TeamName = 'SOC Team' } | Should -Be 'SOC Team | General'
        }
    }

    It 'keeps different part tuples apart when a part contains the separator' {
        InModuleScope PolicyEngine {
            $first = Get-PEResourceKey -ResourceType 'TeamsChannel' -Properties @{ TeamName = 'a | b'; DisplayName = 'c' }
            $second = Get-PEResourceKey -ResourceType 'TeamsChannel' -Properties @{ TeamName = 'a'; DisplayName = 'b | c' }
            $first | Should -Not -Be $second
            $first | Should -Be 'a \| b | c'
            $second | Should -Be 'a | b \| c'
        }
    }

    It 'escapes a backslash inside a composite part so it cannot fake an escaped separator' {
        InModuleScope PolicyEngine {
            $first = Get-PEResourceKey -ResourceType 'TeamsChannel' -Properties @{ TeamName = 'a\'; DisplayName = 'b' }
            $second = Get-PEResourceKey -ResourceType 'TeamsChannel' -Properties @{ TeamName = 'a'; DisplayName = '|b' }
            $first | Should -Be 'a\\ | b'
            $first | Should -Not -Be $second
        }
    }

    It 'leaves ordinary composite parts unchanged' {
        InModuleScope PolicyEngine {
            Get-PEResourceKey -ResourceType 'EXORecipientPermission' -Properties @{ Identity = 'Sales Team'; Trustee = 'ann@contoso.com' } | Should -Be 'Sales Team | ann@contoso.com'
            Get-PEResourceKey -ResourceType 'TeamsUser' -Properties @{ TeamName = 'SOC Team'; User = 'bob@contoso.com' } | Should -Be 'SOC Team | bob@contoso.com'
        }
    }

    It 'does not escape single-property keys or the singleton key' {
        InModuleScope PolicyEngine {
            Get-PEResourceKey -ResourceType 'AADGroup' -Properties @{ DisplayName = 'a | b\c' } | Should -Be 'a | b\c'
            Get-PEResourceKey -ResourceType 'EXOExternalInOutlook' -Properties @{ Identity = 'x | y' } | Should -Be '(singleton)'
        }
    }

    It 'is null when any listed part is empty' {
        InModuleScope PolicyEngine {
            Get-PEResourceKey -ResourceType 'TeamsChannel' -Properties @{ DisplayName = 'General'; TeamName = ' ' } | Should -BeNullOrEmpty
            Get-PEResourceKey -ResourceType 'TeamsChannel' -Properties @{ DisplayName = 'General' } | Should -BeNullOrEmpty
        }
    }

    It 'honours a string[] override from the key map' {
        InModuleScope PolicyEngine {
            $script:PEKeyMap = @{ Default = @('DisplayName'); Overrides = @{ FakeType = @('A', 'B', 'C') } }
            try
            {
                Get-PEResourceKey -ResourceType 'FakeType' -Properties @{ A = 'a'; B = 'b'; C = 'c' } | Should -Be 'a | b | c'
            }
            finally
            {
                $script:PEKeyMap = $null
            }
        }
    }

    It 'accepts a plain string override as a single property' {
        InModuleScope PolicyEngine {
            $script:PEKeyMap = @{ Default = @('DisplayName'); Overrides = @{ FakeType = 'A' } }
            try
            {
                Get-PEResourceKey -ResourceType 'FakeType' -Properties @{ A = 'a'; DisplayName = 'd' } | Should -Be 'a'
            }
            finally
            {
                $script:PEKeyMap = $null
            }
        }
    }

    It 'Singletons types always get (singleton), whatever their properties' {
        InModuleScope PolicyEngine {
            Get-PEResourceKey -ResourceType 'AADOrganizationCertificateBasedAuthConfiguration' -Properties @{ OrganizationId = '11111111-2222-3333-4444-555555555555' } | Should -Be '(singleton)'
            Get-PEResourceKey -ResourceType 'AADOrganizationCertificateBasedAuthConfiguration' -Properties @{ DisplayName = 'x' } | Should -Be '(singleton)'
            Get-PEResourceKey -ResourceType 'aadcrosstenantaccesspolicy' -Properties @{ DisplayName = 'CrossTenantAccessPolicy for 1' } | Should -Be '(singleton)'
            Get-PEResourceKey -ResourceType 'EXOExternalInOutlook' -Properties @{ Identity = '11111111-2222-3333-4444-555555555555' } | Should -Be '(singleton)'
        }
    }

    It 'handles a property literally named Keys or Count' {
        InModuleScope PolicyEngine {
            $record = [pscustomobject]@{
                ResourceType = 'AADGroup'
                Key          = $null
                Workload     = 'Entra ID'
                Properties   = [ordered]@{ DisplayName = 'Sales'; Keys = 'k'; Count = 3 }
            }
            $normalized = ConvertTo-PENormalizedRecord -Record $record
            $normalized.Key | Should -Be 'Sales'
            $normalized.Properties.Contains('Keys') | Should -BeTrue
            $normalized.Properties['Keys'] | Should -Be 'k'
            $normalized.Properties['Count'] | Should -Be 3
        }
    }
}

Describe 'Key coverage on the real export' {
    It 'leaves no record Unkeyed' -Skip:(-not $script:HasExport) {
        @($script:Records | Where-Object { [string]::IsNullOrEmpty($_.Key) }).Count | Should -Be 0
    }

    It 'only allows Ambiguous groups for types on the allow-list' -Skip:(-not $script:HasExport) {
        @($script:AmbiguousTypes | Where-Object { $_ -notin $script:AmbiguousAllowList }) | Should -BeNullOrEmpty
    }

    It 'has no stale allow-list entries (every listed type is still ambiguous)' -Skip:(-not $script:HasExport) {
        @($script:AmbiguousAllowList | Where-Object { $_ -notin $script:AmbiguousTypes }) | Should -BeNullOrEmpty
    }
}