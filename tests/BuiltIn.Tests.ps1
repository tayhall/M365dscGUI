BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:GlobalAdmin = '62e90394-69f5-4237-9190-012177145e10'
    $script:CustomId = 'aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb'

    function New-Role
    {
        param ([string]$Name, [string]$TemplateId, [string[]]$Permissions, [string]$Description = 'd')
        [pscustomobject]@{ ResourceType = 'AADRoleDefinition'; Key = $Name; Workload = 'Entra ID'; Properties = [ordered]@{ DisplayName = $Name; TemplateId = $TemplateId; RolePermissions = $Permissions; Description = $Description } }
    }

    function New-State
    {
        param ([object[]]$Records)
        InModuleScope PolicyEngine -Parameters @{ R = $Records } {
            New-PEState -Records $R -NotChecked @() -Meta @{ TenantId = 't'; ExportedAt = '2026-10-22T00:00:00Z' }
        }
    }
}

Describe 'Built-in resources' {
    It 'lists the built-in Entra roles and includes Global Administrator' {
        $ids = (Import-PowerShellDataFile "$PSScriptRoot\..\src\PolicyEngine\Data\BuiltInResources.psd1").AADRoleDefinition.Ids
        $ids.Count | Should -BeGreaterThan 100
        $ids[$script:GlobalAdmin] | Should -Be 'Global Administrator'
    }

    It 'does not compare the permissions of a built-in role' {
        $blueprint = New-State @((New-Role -Name 'Global Administrator' -TemplateId $script:GlobalAdmin -Permissions @('a', 'b', 'c')))
        $target = New-State @((New-Role -Name 'Global Administrator' -TemplateId $script:GlobalAdmin -Permissions @('a', 'b')))
        @(Compare-PEState -Blueprint $blueprint -Target $target).Count | Should -Be 0
    }

    It 'still compares everything else of a built-in role' {
        $blueprint = New-State @((New-Role -Name 'Global Administrator' -TemplateId $script:GlobalAdmin -Permissions @('a') -Description 'old'))
        $target = New-State @((New-Role -Name 'Global Administrator' -TemplateId $script:GlobalAdmin -Permissions @('b') -Description 'new'))
        $findings = @(Compare-PEState -Blueprint $blueprint -Target $target)
        $findings.Count | Should -Be 1
        ($findings[0].Differences | ForEach-Object Property) | Should -Be @('Description')
    }

    It 'compares a custom role (an id Microsoft does not list) in full' {
        $blueprint = New-State @((New-Role -Name 'Helpdesk Lite' -TemplateId $script:CustomId -Permissions @('a', 'b')))
        $target = New-State @((New-Role -Name 'Helpdesk Lite' -TemplateId $script:CustomId -Permissions @('a')))
        $findings = @(Compare-PEState -Blueprint $blueprint -Target $target)
        $findings.Count | Should -Be 1
        ($findings[0].Differences | ForEach-Object Property) | Should -Be @('RolePermissions')
    }

    It 'does not trust the id alone: a custom role that carries a built-in templateId under another name is compared in full' {
        $blueprint = New-State @((New-Role -Name 'Sneaky Admin' -TemplateId $script:GlobalAdmin -Permissions @('a')))
        $target = New-State @((New-Role -Name 'Sneaky Admin' -TemplateId $script:GlobalAdmin -Permissions @('a', 'microsoft.directory/users/allProperties/allTasks')))
        $findings = @(Compare-PEState -Blueprint $blueprint -Target $target)
        $findings.Count | Should -Be 1
        ($findings[0].Differences | ForEach-Object Property) | Should -Be @('RolePermissions')
    }

    It 'matches the built-in name exactly, not loosely' {
        $blueprint = New-State @((New-Role -Name 'global administrator' -TemplateId $script:GlobalAdmin -Permissions @('a')))
        $target = New-State @((New-Role -Name 'global administrator' -TemplateId $script:GlobalAdmin -Permissions @('b')))
        @(Compare-PEState -Blueprint $blueprint -Target $target).Count | Should -Be 1
    }

    It 'still reports a built-in role that is missing or new' {
        $blueprint = New-State @((New-Role -Name 'Global Administrator' -TemplateId $script:GlobalAdmin -Permissions @('a')))
        $target = New-State @()
        @(Compare-PEState -Blueprint $blueprint -Target $target).Kind | Should -Be @('Missing')
    }

    It 'does not compare the permissions of a built-in Intune role (flagged IsBuiltIn by the service), but does for a custom role' {
        function New-IntuneRole { param ([string]$Name, [string]$IsBuiltIn, [string[]]$Allowed) [pscustomobject]@{ ResourceType = 'IntuneRoleDefinition'; Key = $Name; Workload = 'Intune'; Properties = [ordered]@{ DisplayName = $Name; IsBuiltIn = $IsBuiltIn; AllowedResourceActions = $Allowed; Description = 'd' } } }
        # a built-in role that gained permissions: not drift
        $blueprint = New-State @((New-IntuneRole -Name 'Help Desk Operator' -IsBuiltIn 'True' -Allowed @('a')))
        $target = New-State @((New-IntuneRole -Name 'Help Desk Operator' -IsBuiltIn 'True' -Allowed @('a', 'b')))
        @(Compare-PEState -Blueprint $blueprint -Target $target).Count | Should -Be 0
        # same name but not flagged built-in (a custom role): compared in full
        $blueprint = New-State @((New-IntuneRole -Name 'Help Desk Operator' -IsBuiltIn 'False' -Allowed @('a')))
        $target = New-State @((New-IntuneRole -Name 'Help Desk Operator' -IsBuiltIn 'False' -Allowed @('a', 'b')))
        @(Compare-PEState -Blueprint $blueprint -Target $target).Count | Should -Be 1
        # a built-in role Microsoft added later is covered without any list
        $blueprint = New-State @((New-IntuneRole -Name 'A Role Added Next Year' -IsBuiltIn 'True' -Allowed @('a')))
        $target = New-State @((New-IntuneRole -Name 'A Role Added Next Year' -IsBuiltIn 'True' -Allowed @('a', 'b')))
        @(Compare-PEState -Blueprint $blueprint -Target $target).Count | Should -Be 0
    }

    It 'leaves other resource types alone' {
        InModuleScope PolicyEngine {
            $bag = [ordered]@{ DisplayName = 'x'; RolePermissions = @('a') }
            (Remove-PEBuiltInProperty -ResourceType 'AADGroup' -Properties $bag).Count | Should -Be 2
        }
    }
}
