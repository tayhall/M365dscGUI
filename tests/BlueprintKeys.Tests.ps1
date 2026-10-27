BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Cat = 'AADEntitlementManagementAccessPackageCatalog'
    $script:Pol = 'AADEntitlementManagementAccessPackageAssignmentPolicy'
}

Describe 'Update-PEBlueprintKeys' {
    BeforeEach {
        $script:Temp = Join-Path ([IO.Path]::GetTempPath()) ('pe-keys-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Temp | Out-Null
        $records = @(
            [pscustomobject]@{ ResourceType = $script:Pol; Key = 'Initial Policy'; Workload = 'Entra ID'; TenantId = 't'; Properties = [ordered]@{ AccessPackageId = 'Pack A'; DisplayName = 'Initial Policy'; Ensure = 'Present' } },
            [pscustomobject]@{ ResourceType = $script:Cat; Key = 'General'; Workload = 'Entra ID'; TenantId = 't'; Properties = [ordered]@{ DisplayName = 'General'; Ensure = 'Present' } }
        )
        $state = InModuleScope PolicyEngine -Parameters @{ Records = $records } { New-PEState -Records $Records -NotChecked @() -Meta @{ TenantId = 't'; ExportedAt = '2026-10-23T00:00:00Z' } }
        Initialize-PEBlueprint -Name 'main' -State $state -DataRoot $script:Temp | Out-Null
    }
    AfterEach { Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'writes one new version that re-keys only the records whose key moved, and nothing the second time' {
        (Update-PEBlueprintKeys -Name 'main' -Reason 'keys' -DataRoot $script:Temp -DryRun | ForEach-Object { $_.Key }) | Should -Be @('Pack A | Initial Policy')
        Update-PEBlueprintKeys -Name 'main' -Reason 'keys' -DataRoot $script:Temp | Should -Be 2
        $latest = Get-PEBlueprint -Name 'main' -DataRoot $script:Temp
        @($latest.Records | ForEach-Object { $_.Key }) | Should -Be @('Pack A | Initial Policy', 'General')
        $null -eq (Update-PEBlueprintKeys -Name 'main' -Reason 'keys' -DataRoot $script:Temp) | Should -BeTrue
        (Get-PEBlueprint -Name 'main' -Version 1 -DataRoot $script:Temp).Records[0].Key | Should -Be 'Initial Policy'
    }
}

Describe 'Get-PEKeyPartFromRecordKey' {
    It 'gives back the key property the key map builds the Key from, from a single or a composite key' {
        InModuleScope PolicyEngine {
            Get-PEKeyPartFromRecordKey -ResourceType 'AADAuthenticationMethodPolicyEmail' -Key 'Email' -Property 'Id' | Should -Be 'Email'
            Get-PEKeyPartFromRecordKey -ResourceType 'AADEntitlementManagementAccessPackageAssignmentPolicy' -Key 'Pack A | Initial Policy' -Property 'AccessPackageId' | Should -Be 'Pack A'
            Get-PEKeyPartFromRecordKey -ResourceType 'AADEntitlementManagementAccessPackageAssignmentPolicy' -Key 'Pack A | Initial Policy' -Property 'DisplayName' | Should -Be 'Initial Policy'
            Get-PEKeyPartFromRecordKey -ResourceType 'AADEntitlementManagementAccessPackageAssignmentPolicy' -Key 'A \| B | Initial Policy' -Property 'AccessPackageId' | Should -Be 'A | B'
        }
    }

    It 'gives nothing for a property the Key is not built from, or a type without a key override' {
        InModuleScope PolicyEngine {
            Get-PEKeyPartFromRecordKey -ResourceType 'AADEntitlementManagementAccessPackageAssignmentPolicy' -Key 'Pack A | Initial Policy' -Property 'Id' | Should -BeNullOrEmpty
            Get-PEKeyPartFromRecordKey -ResourceType 'AADGroup' -Key 'Sales' -Property 'Id' | Should -BeNullOrEmpty
        }
    }
}