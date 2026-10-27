BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    . "$PSScriptRoot\..\tools\PEApply.Common.ps1"
}

Describe 'the tenant GUID the export writes into values' {
    It 'is rendered as the $TenantGuid variable, a separate operand like $OrganizationName' {
        InModuleScope PolicyEngine {
            ConvertTo-PEDscStringLiteral -Value 'Ids$($ConfigurationData.NonNodeData.TenantGuid)_x' | Should -BeExactly '(-join @(''Ids'', $TenantGuid, ''_x''))'
            ConvertTo-PEDscStringLiteral -Value '$($ConfigurationData.NonNodeData.TenantGuid)' | Should -BeExactly '(-join @($TenantGuid))'
            ConvertTo-PEDscStringLiteral -Value 'a@$OrganizationName/$($ConfigurationData.NonNodeData.TenantGuid)' | Should -BeExactly '(-join @(''a@'', $OrganizationName, ''/'', $TenantGuid))'
            ConvertTo-PEDscStringLiteral -Value 'plain' | Should -BeExactly '''plain'''
        }
    }
}

Describe 'Resolve-PETenantGuid' {
    It 'passes a GUID through and resolves a domain from the public OpenID metadata' {
        Resolve-PETenantGuid -TenantId 'F6676BAB-AD26-4AA1-8470-6907E9D18502' | Should -Be 'f6676bab-ad26-4aa1-8470-6907e9d18502'
        Mock Invoke-RestMethod { [pscustomobject]@{ issuer = 'https://login.microsoftonline.com/F6676BAB-AD26-4AA1-8470-6907E9D18502/v2.0' } }
        Resolve-PETenantGuid -TenantId 'contoso.onmicrosoft.com' | Should -Be 'f6676bab-ad26-4aa1-8470-6907e9d18502'
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -like '*contoso.onmicrosoft.com*openid-configuration' } -Times 1
    }

    It 'gives nothing when the metadata cannot be read' {
        Mock Invoke-RestMethod { throw 'offline' }
        Resolve-PETenantGuid -TenantId 'contoso.onmicrosoft.com' | Should -BeNullOrEmpty
    }
}