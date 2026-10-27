BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
}

Describe 'types whose own Id is the DSC key' {
    It 'keep their Id when records are normalised, other types still lose it' {
        InModuleScope PolicyEngine {
            $policy = [pscustomobject]@{ ResourceType = 'AADPermissionGrantPolicy'; Workload = 'Entra ID'; TenantId = 't'; Properties = [ordered]@{ Id = 'microsoft-user-default-legacy'; DisplayName = 'Legacy policy' } }
            $group = [pscustomobject]@{ ResourceType = 'AADGroup'; Workload = 'Entra ID'; TenantId = 't'; Properties = [ordered]@{ Id = 'aaaaaaaa-0000-0000-0000-000000000001'; DisplayName = 'Sales' } }
            (ConvertTo-PENormalizedRecord -Record $policy -ExportedAt $null).Properties.Contains('Id') | Should -BeTrue
            (ConvertTo-PENormalizedRecord -Record $group -ExportedAt $null).Properties.Contains('Id') | Should -BeFalse
        }
    }

    It 'take the Id the target has for the same key, and keep their own when it has none' {
        InModuleScope PolicyEngine {
            $record = [pscustomobject]@{ ResourceType = 'IntuneDeviceEnrollmentPlatformRestriction'; Key = 'All users'; Workload = 'Intune'; TenantId = 't'; Properties = [ordered]@{ Id = 'master-guid'; DisplayName = 'All users' } }
            $found = Resolve-PEOwnId -Record $record -Resolver { param ($type, $key) 'target-guid' }
            (Get-PEPropertyBag -Record $found)['Id'] | Should -Be 'target-guid'
            (Get-PEPropertyBag -Record $record)['Id'] | Should -Be 'master-guid'
            $none = Resolve-PEOwnId -Record $record -Resolver { param ($type, $key) $null }
            [object]::ReferenceEquals($none, $record) | Should -BeTrue
            $other = [pscustomobject]@{ ResourceType = 'AADGroup'; Key = 'G'; Properties = [ordered]@{ DisplayName = 'G' } }
            [object]::ReferenceEquals((Resolve-PEOwnId -Record $other -Resolver { 'x' }), $other) | Should -BeTrue
        }
    }
}

Describe 'New-PEOwnIdResolver' {
    It 'exports the type from the target once and answers by key, case-insensitively' {
        Mock -ModuleName PolicyEngine Invoke-PEDeltaExportTool { 'D:\fake\export' }
        Mock -ModuleName PolicyEngine Find-PEExportFile { 'D:\fake\export\export.ps1' }
        Mock -ModuleName PolicyEngine Read-PEExport {
            @(
                [pscustomobject]@{ ResourceType = 'AADPermissionGrantPolicy'; Properties = [ordered]@{ Id = 'id-one'; DisplayName = 'One' } },
                [pscustomobject]@{ ResourceType = 'AADPermissionGrantPolicy'; Properties = [ordered]@{ Id = 'id-two'; DisplayName = 'Two' } }
            )
        }
        $answers = InModuleScope PolicyEngine {
            $r = New-PEOwnIdResolver -Tenant contoso
            @($r.Resolve('AADPermissionGrantPolicy', 'One'), $r.Resolve('AADPermissionGrantPolicy', 'TWO'), $r.Resolve('AADPermissionGrantPolicy', 'Missing'))
        }
        $answers[0] | Should -Be 'id-one'
        $answers[1] | Should -Be 'id-two'
        $answers[2] | Should -BeNullOrEmpty
        Should -Invoke -ModuleName PolicyEngine Invoke-PEDeltaExportTool -Times 1 -Exactly -ParameterFilter { $Tenant -eq 'contoso' -and $Components -contains 'AADPermissionGrantPolicy' }
    }
}

Describe 'Intune assignments across tenants' {
    BeforeAll {
        function New-Assignment($name, $groupId) { [ordered]@{ groupDisplayName = $name; groupId = $groupId; intent = 'required'; dataType = '#microsoft.graph.groupAssignmentTarget' } }
        function New-App($assignment, $tenant) {
            [pscustomobject]@{ Records = @([pscustomobject]@{ ResourceType = 'IntuneMobileAppsStoreApp'; Key = 'App'; Workload = 'Intune'; TenantId = $null; Properties = [ordered]@{ DisplayName = 'App'; Assignments = @($assignment) } }); NotChecked = @(); Meta = @{ TenantId = $tenant } }
        }
    }

    It 'compare the group name, not the group id, when the tenants differ' {
        $blueprint = New-App (New-Assignment 'sg-Sales' 'master-group-guid') 'prod'
        @(Compare-PEState -Blueprint $blueprint -Target (New-App (New-Assignment 'sg-Sales' 'dev-group-guid') 'dev')).Count | Should -Be 0
        @(Compare-PEState -Blueprint $blueprint -Target (New-App (New-Assignment 'sg-Other' 'dev-group-guid') 'dev')).Count | Should -Be 1
    }

    It 'still compare the group id against the tenant the blueprint came from' {
        $blueprint = New-App (New-Assignment 'sg-Sales' 'master-group-guid') 'prod'
        @(Compare-PEState -Blueprint $blueprint -Target (New-App (New-Assignment 'sg-Sales' 'other-guid') 'prod')).Count | Should -Be 1
    }
}
