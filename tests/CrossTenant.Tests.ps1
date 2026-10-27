BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    function New-Rec($type, $key, $props) { [pscustomobject]@{ ResourceType = $type; Key = $key; Workload = 'W'; TenantId = $null; Properties = $props } }
    function New-St($records, $tenantId) { [pscustomobject]@{ Records = @($records); NotChecked = @(); Meta = @{ TenantId = $tenantId } } }
}

Describe 'Test-PECrossTenant' {
    It 'is true only when both ids are known and differ' {
        InModuleScope PolicyEngine {
            Test-PECrossTenant -BlueprintTenantId 'prod.onmicrosoft.com' -TargetTenantId 'dev.onmicrosoft.com' | Should -BeTrue
            # (the case of a domain is not a different tenant)
            Test-PECrossTenant -BlueprintTenantId 'Prod.onmicrosoft.com' -TargetTenantId 'prod.onmicrosoft.com' | Should -BeFalse
            Test-PECrossTenant -BlueprintTenantId 'prod.onmicrosoft.com' -TargetTenantId 'prod.onmicrosoft.com' | Should -BeFalse
            Test-PECrossTenant -BlueprintTenantId 'prod.onmicrosoft.com' -TargetTenantId 'unknown' | Should -BeFalse
            Test-PECrossTenant -BlueprintTenantId '' -TargetTenantId 'dev.onmicrosoft.com' | Should -BeFalse
        }
    }
}

Describe 'Compare-PEState and tenant-bound properties' {
    BeforeEach {
        $script:Bp = { param ($tenant) New-St @(
                (New-Rec 'AADServicePrincipal' 'Box' ([ordered]@{ DisplayName = 'Box'; ObjectID = 'aaa'; AccountEnabled = $true })),
                (New-Rec 'AADApplication' 'Box' ([ordered]@{ DisplayName = 'Box'; AppId = '1'; Api = [ordered]@{ Oauth2PermissionScopes = @([ordered]@{ id = 'x'; value = 'user_impersonation' }) }; KeyCredentials = @('k1') })),
                (New-Rec 'EXORoleGroup' 'Org Mgmt' ([ordered]@{ Name = 'Org Mgmt'; Members = @('alice') }))) $tenant }
        $script:Tg = { param ($tenant, $scope = 'y', $keys = 'k1', $members = 'alice', $enabled = $true) New-St @(
                (New-Rec 'AADServicePrincipal' 'Box' ([ordered]@{ DisplayName = 'Box'; ObjectID = 'bbb'; AccountEnabled = $enabled })),
                (New-Rec 'AADApplication' 'Box' ([ordered]@{ DisplayName = 'Box'; AppId = '2'; Api = [ordered]@{ Oauth2PermissionScopes = @([ordered]@{ id = $scope; value = 'user_impersonation' }) }; KeyCredentials = @($keys) })),
                (New-Rec 'EXORoleGroup' 'Org Mgmt' ([ordered]@{ Name = 'Org Mgmt'; Members = @($members) }))) $tenant }
    }

    It 'compares generated ids against the tenant the blueprint came from' {
        $f = @(Compare-PEState -Blueprint (& $script:Bp 'prod') -Target (& $script:Tg 'prod'))
        @($f | Where-Object ResourceType -eq 'AADServicePrincipal').Count | Should -Be 1
        @($f | Where-Object ResourceType -eq 'AADApplication').Count | Should -Be 1
    }

    It 'leaves them out for another tenant, detected from Meta.TenantId' {
        $f = @(Compare-PEState -Blueprint (& $script:Bp 'prod') -Target (& $script:Tg 'dev'))
        $f.Count | Should -Be 0
    }

    It 'honours -CrossTenant Yes and No over the ids' {
        @(Compare-PEState -Blueprint (& $script:Bp 'prod') -Target (& $script:Tg 'prod') -CrossTenant Yes).Count | Should -Be 0
        @(Compare-PEState -Blueprint (& $script:Bp 'prod') -Target (& $script:Tg 'dev') -CrossTenant No).Count | Should -BeGreaterThan 0
    }

    It 'still reports real differences in another tenant, but not the app''s own keys' {
        $f = @(Compare-PEState -Blueprint (& $script:Bp 'prod') -Target (& $script:Tg 'dev' -keys 'k2' -members 'mallory' -enabled $false))
        ($f | Where-Object ResourceType -eq 'AADServicePrincipal').Differences.Property | Should -Be @('AccountEnabled')
        # an app's certificate keys are made per tenant, so another tenant can never match them
        @($f | Where-Object ResourceType -eq 'AADApplication').Count | Should -Be 0
        # (the members of a role group are data about users and are not compared at all; see Data\IgnoredProperties.psd1)
        @($f | Where-Object ResourceType -eq 'EXORoleGroup').Count | Should -Be 0
    }
}

Describe 'Compare-PEState and the tenant''s own domain name' {
    BeforeAll {
        $script:Sp = { param ($urls) New-Rec 'AADServicePrincipal' 'SPFx' ([ordered]@{ DisplayName = 'SPFx'; ReplyUrls = @($urls) }) }
    }

    It 'does not report a value that differs only by the tenant''s own domain name' {
        $bp = New-St @(& $script:Sp @('https://prod-admin.sharepoint.com/_forms/x', 'brk-multihub://prod.sharepoint.com', 'https://login.example.com/y')) 'Prod.onmicrosoft.com'
        $tg = New-St @(& $script:Sp @('https://dev-admin.sharepoint.com/_forms/x', 'brk-multihub://dev.sharepoint.com', 'https://login.example.com/y')) 'dev.onmicrosoft.com'
        @(Compare-PEState -Blueprint $bp -Target $tg).Count | Should -Be 0
    }

    It 'still reports the property, with the original values, when anything else in it differs' {
        $bp = New-St @(& $script:Sp @('https://prod-admin.sharepoint.com/_forms/x')) 'prod.onmicrosoft.com'
        $tg = New-St @(& $script:Sp @('https://dev-admin.sharepoint.com/_forms/x', 'https://evil.example.com/cb')) 'dev.onmicrosoft.com'
        $f = @(Compare-PEState -Blueprint $bp -Target $tg)
        $f.Count | Should -Be 1
        $f[0].Differences.Property | Should -Be @('ReplyUrls')
        @($f[0].Differences[0].Target) | Should -Contain 'https://dev-admin.sharepoint.com/_forms/x'
    }

    It 'does not rewrite anything for the tenant the blueprint came from' {
        $bp = New-St @(& $script:Sp @('https://prod-admin.sharepoint.com/x')) 'prod.onmicrosoft.com'
        $tg = New-St @(& $script:Sp @('https://dev-admin.sharepoint.com/x')) 'prod.onmicrosoft.com'
        @(Compare-PEState -Blueprint $bp -Target $tg).Count | Should -Be 1
    }

    It 'does nothing when a tenant id is a GUID, because it names no domain' {
        $bp = New-St @(& $script:Sp @('https://prod-admin.sharepoint.com/x')) '11111111-1111-1111-1111-111111111111'
        $tg = New-St @(& $script:Sp @('https://dev-admin.sharepoint.com/x')) 'dev.onmicrosoft.com'
        @(Compare-PEState -Blueprint $bp -Target $tg).Count | Should -Be 1
    }

    It 'leaves out where an Exchange object sits in the directory and the IRM licensing location for another tenant' {
        $bp = New-St @(
            (New-Rec 'EXOMailContact' 'Bob' ([ordered]@{ Name = 'Bob'; OrganizationalUnit = 'nampr16a016.prod.outlook.com/Microsoft Exchange Hosted Organizations/$OrganizationName' })),
            (New-Rec 'EXOIRMConfiguration' '(singleton)' ([ordered]@{ LicensingLocation = 'https://37407767-f041-4cdd-a41f-3eea691d422e.rms.na.aadrm.com/_wmcs/licensing'; AzureRMSLicensingEnabled = $true }))) 'prod.onmicrosoft.com'
        $tg = New-St @(
            (New-Rec 'EXOMailContact' 'Bob' ([ordered]@{ Name = 'Bob'; OrganizationalUnit = 'ausp282a013.prod.outlook.com/Microsoft Exchange Hosted Organizations/$OrganizationName' })),
            (New-Rec 'EXOIRMConfiguration' '(singleton)' ([ordered]@{ LicensingLocation = 'https://7180475e-a5e3-4170-9b14-4a38a07f9b8a.rms.ap.aadrm.com/_wmcs/licensing'; AzureRMSLicensingEnabled = $true }))) 'dev.onmicrosoft.com'
        @(Compare-PEState -Blueprint $bp -Target $tg).Count | Should -Be 0
        $tg2 = New-St @((New-Rec 'EXOIRMConfiguration' '(singleton)' ([ordered]@{ LicensingLocation = 'https://7180475e-a5e3-4170-9b14-4a38a07f9b8a.rms.ap.aadrm.com/_wmcs/licensing'; AzureRMSLicensingEnabled = $false }))) 'dev.onmicrosoft.com'
        $f = @(Compare-PEState -Blueprint $bp -Target $tg2 | Where-Object ResourceType -eq 'EXOIRMConfiguration')
        $f[0].Differences.Property | Should -Be @('AzureRMSLicensingEnabled')
    }
}

Describe 'Compare-PEState tenant name translation stays inside Microsoft tenant hosts' {
    BeforeAll {
        $script:Sp = { param ($urls) New-Rec 'AADServicePrincipal' 'SPFx' ([ordered]@{ DisplayName = 'SPFx'; ReplyUrls = @($urls) }) }
    }

    It 'does not translate the name in a custom domain, a path or free text' {
        $bp = New-St @(& $script:Sp @('https://prod.example.com/cb', 'https://login.example.com/prod')) 'prod.onmicrosoft.com'
        $tg = New-St @(& $script:Sp @('https://dev.example.com/cb', 'https://login.example.com/dev')) 'dev.onmicrosoft.com'
        @(Compare-PEState -Blueprint $bp -Target $tg).Count | Should -Be 1
    }

    It 'does not translate a Microsoft-looking name inside another domain' {
        $bp = New-St @(& $script:Sp @('https://prod.sharepoint.com.example.com/x')) 'prod.onmicrosoft.com'
        $tg = New-St @(& $script:Sp @('https://dev.sharepoint.com.example.com/x')) 'dev.onmicrosoft.com'
        @(Compare-PEState -Blueprint $bp -Target $tg).Count | Should -Be 1
    }

    It 'translates the onmicrosoft.com domain and a user in it' {
        $bp = New-St @(& $script:Sp @('alice@prod.onmicrosoft.com', 'https://prod-my.sharepoint.com/x')) 'prod.onmicrosoft.com'
        $tg = New-St @(& $script:Sp @('alice@dev.onmicrosoft.com', 'https://dev-my.sharepoint.com/x')) 'dev.onmicrosoft.com'
        @(Compare-PEState -Blueprint $bp -Target $tg).Count | Should -Be 0
    }

    It 'never replaces a name with nothing when only the target names a domain' {
        $bp = New-St @(& $script:Sp @('https://-admin.sharepoint.com/x')) '11111111-1111-1111-1111-111111111111'
        $tg = New-St @(& $script:Sp @('https://dev-admin.sharepoint.com/x')) 'dev.onmicrosoft.com'
        @(Compare-PEState -Blueprint $bp -Target $tg).Count | Should -Be 1
    }
}

Describe 'Compare-PEState and role groups' {
    It 'does not compare the members of an Exchange or Security and Compliance role group' {
        $bp = New-St @(
            (New-Rec 'EXORoleGroup' 'Help Desk' ([ordered]@{ Name = 'Help Desk'; Members = @('LynneR@$OrganizationName'); Roles = @('Reset Password') })),
            (New-Rec 'SCRoleGroupMember' 'eDiscovery' ([ordered]@{ Name = 'eDiscovery'; Members = @('alice') }))) 'prod.onmicrosoft.com'
        $tg = New-St @(
            (New-Rec 'EXORoleGroup' 'Help Desk' ([ordered]@{ Name = 'Help Desk'; Members = @(); Roles = @('Reset Password') })),
            (New-Rec 'SCRoleGroupMember' 'eDiscovery' ([ordered]@{ Name = 'eDiscovery'; Members = @('bob') }))) 'dev.onmicrosoft.com'
        @(Compare-PEState -Blueprint $bp -Target $tg).Count | Should -Be 0
        # also within one tenant: a member list is data about users, not configuration
        @(Compare-PEState -Blueprint $bp -Target $tg -CrossTenant No).Count | Should -Be 0
    }

    It 'compares the roles of a role group as a set: order does not matter, a different role does' {
        $mk = { param ($roles) New-St @((New-Rec 'EXORoleGroup' 'Help Desk' ([ordered]@{ Name = 'Help Desk'; Roles = $roles }))) 'prod.onmicrosoft.com' }
        @(Compare-PEState -Blueprint (& $mk @('Reset Password', 'User Options', 'View-Only Recipients')) -Target (& $mk @('View-Only Recipients', 'Reset Password', 'User Options'))).Count | Should -Be 0
        $f = @(Compare-PEState -Blueprint (& $mk @('Reset Password', 'User Options')) -Target (& $mk @('Reset Password', 'Mail Recipients')))
        $f.Count | Should -Be 1
        $f[0].Differences.Property | Should -Be @('Roles')
    }
}

Describe 'Compare-PEState and the keys of an app in the tenant it came from' {
    It 'still reports a changed key against the tenant the blueprint was taken from' {
        $bp = New-St @((New-Rec 'AADApplication' 'Box' ([ordered]@{ DisplayName = 'Box'; KeyCredentials = @('k1') }))) 'prod.onmicrosoft.com'
        $tg = New-St @((New-Rec 'AADApplication' 'Box' ([ordered]@{ DisplayName = 'Box'; KeyCredentials = @('k1', 'rogue') }))) 'prod.onmicrosoft.com'
        $f = @(Compare-PEState -Blueprint $bp -Target $tg)
        $f.Count | Should -Be 1
        $f[0].Differences.Property | Should -Be @('KeyCredentials')
    }
}