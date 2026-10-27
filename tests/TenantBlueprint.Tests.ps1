BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force

    function New-TestRecord
    {
        param ([string]$Key, [string]$Type = 'AADGroup')
        [pscustomobject]@{ ResourceType = $Type; Key = $Key; Workload = 'Entra ID'; TenantId = 't'; Properties = [ordered]@{ DisplayName = $Key } }
    }

    function Get-TestVersion
    {
        param ([string]$Name, [string]$Root)
        & (Get-Module PolicyEngine) { @(Get-PEBlueprintVersionNumber -Directory (Get-PEBlueprintDirectory -Name $args[0] -DataRoot $args[1])) } $Name $Root
    }

    function New-TestState
    {
        param ([object[]]$Records = @())
        & (Get-Module PolicyEngine) {
            param ($r)
            New-PEState -Records $r -NotChecked @() -Meta @{ TenantId = 't'; ExportedAt = '2026-10-21T01:02:03Z'; Source = 'test' }
        } $Records
    }
}

Describe 'Tenant blueprint layers' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-' + [guid]::NewGuid())
        Initialize-PEBlueprint -Name 'prod' -State (New-TestState -Records @((New-TestRecord -Key 'g1'), (New-TestRecord -Key 'g2'))) -DataRoot $script:Temp | Out-Null
        Set-PETenant -Slug 'dev' -DisplayName 'Dev' -TenantId 'dev.onmicrosoft.com' -DataRoot $script:Temp | Out-Null
    }

    AfterEach {
        if (Test-Path $script:Temp) { Remove-Item $script:Temp -Recurse -Force }
    }

    It 'reads a tenant with no stored list as the master blueprint alone' {
        (Get-PETenant -Slug 'dev' -DataRoot $script:Temp).Blueprints | Should -BeNullOrEmpty
        $layers = & (Get-Module PolicyEngine) { Get-PETenantBlueprint -Tenant 'dev' -MasterBlueprint 'prod' -DataRoot $args[0] } $script:Temp
        @($layers) | Should -Be @('prod')
    }

    It 'creates the tenant blueprint as a copy of the latest master version and records the list' {
        Initialize-PETenantBlueprint -Slug 'dev' -MasterBlueprint 'prod' -DataRoot $script:Temp | Should -Be 'dev'
        @((Get-PETenant -Slug 'dev' -DataRoot $script:Temp).Blueprints) | Should -Be @('prod', 'dev')
        $copy = Get-PEBlueprint -Name 'dev' -DataRoot $script:Temp
        @($copy.Records | ForEach-Object Key | Sort-Object) | Should -Be @('g1', 'g2')
        @(Get-TestVersion -Name 'dev' -Root $script:Temp) | Should -Be @(1)
    }

    It 'does nothing the second time' {
        Initialize-PETenantBlueprint -Slug 'dev' -MasterBlueprint 'prod' -DataRoot $script:Temp | Out-Null
        Initialize-PETenantBlueprint -Slug 'dev' -MasterBlueprint 'prod' -DataRoot $script:Temp | Should -Be 'dev'
        @(Get-TestVersion -Name 'dev' -Root $script:Temp) | Should -Be @(1)
        @((Get-PETenant -Slug 'dev' -DataRoot $script:Temp).Blueprints) | Should -Be @('prod', 'dev')
    }

    It 'refuses a tenant whose slug is the master blueprint name, in any letter case' {
        { Initialize-PETenantBlueprint -Slug 'prod' -MasterBlueprint 'Prod' -DataRoot $script:Temp } | Should -Throw '*master blueprint*'
    }

    It 'with -FromCheck starts the tenant blueprint from the tenant''s own latest Full check, not from the master blueprint' {
        $dir = Join-Path $script:Temp 'checks\20261025-104007'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [ordered]@{
            CheckId = '20261025-104007'; Kind = 'Full'; TenantSlug = 'dev'
            Findings = @()
            State = [ordered]@{
                Records    = @((New-TestRecord -Key 'g2'), (New-TestRecord -Key 'g3'))
                NotChecked = @()
                Meta       = [ordered]@{ TenantId = 'dev.onmicrosoft.com'; ExportedAt = '2026-10-25T10:40:00Z'; Source = 'dev export' }
            }
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $dir 'result.json') -Encoding utf8

        Initialize-PETenantBlueprint -Slug 'dev' -MasterBlueprint 'prod' -FromCheck -DataRoot $script:Temp | Should -Be 'dev'
        @((Get-PETenant -Slug 'dev' -DataRoot $script:Temp).Blueprints) | Should -Be @('prod', 'dev')
        $own = Get-PEBlueprint -Name 'dev' -DataRoot $script:Temp
        @($own.Records | ForEach-Object Key | Sort-Object) | Should -Be @('g2', 'g3')
        $own.Meta['TenantId'] | Should -Be 'dev.onmicrosoft.com'
        @(Get-TestVersion -Name 'dev' -Root $script:Temp) | Should -Be @(1)
    }

    It 'with -FromCheck refuses a tenant that has no Full check yet and creates nothing' {
        { Initialize-PETenantBlueprint -Slug 'dev' -MasterBlueprint 'prod' -FromCheck -DataRoot $script:Temp } | Should -Throw '*No Full check*'
        @(Get-TestVersion -Name 'dev' -Root $script:Temp) | Should -BeNullOrEmpty
        (Get-PETenant -Slug 'dev' -DataRoot $script:Temp).Blueprints | Should -BeNullOrEmpty
    }

    It 'refuses the master tenant' {
        { Initialize-PETenantBlueprint -Slug 'master' -MasterBlueprint 'prod' -DataRoot $script:Temp } | Should -Throw '*master*'
    }

    It 'keeps the list when only the display name changes' {
        Initialize-PETenantBlueprint -Slug 'dev' -MasterBlueprint 'prod' -DataRoot $script:Temp | Out-Null
        Set-PETenant -Slug 'dev' -DisplayName 'Robs tenant' -DataRoot $script:Temp | Out-Null
        $t = Get-PETenant -Slug 'dev' -DataRoot $script:Temp
        $t.DisplayName | Should -Be 'Robs tenant'
        @($t.Blueprints) | Should -Be @('prod', 'dev')
        $t.TenantId | Should -Be 'dev.onmicrosoft.com'
    }

    Context 'Migration script' {
        BeforeEach {
            Set-PETenant -Slug 'qa' -DisplayName 'QA' -TenantId 'qa.onmicrosoft.com' -DataRoot $script:Temp | Out-Null
            $script:Tool = Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'tools' 'Initialize-PETenantBlueprints.ps1')
        }

        It 'changes nothing under -WhatIf' {
            $result = @(& $script:Tool -MasterBlueprint 'prod' -DataRoot $script:Temp -WhatIf)
            @($result | ForEach-Object Action) | Should -Be @('WouldCreate', 'WouldCreate')
            @((Get-PETenant -Slug 'dev' -DataRoot $script:Temp).Blueprints) | Should -BeNullOrEmpty
            @(Get-TestVersion -Name 'dev' -Root $script:Temp) | Should -BeNullOrEmpty
        }

        It 'gives every replica its own blueprint, leaves the master tenant alone, and does nothing the second time' {
            $first = @(& $script:Tool -MasterBlueprint 'prod' -DataRoot $script:Temp)
            @($first | ForEach-Object Slug | Sort-Object) | Should -Be @('dev', 'qa')
            @($first | ForEach-Object Action | Sort-Object -Unique) | Should -Be @('Created')
            foreach ($slug in 'dev', 'qa')
            {
                @((Get-PETenant -Slug $slug -DataRoot $script:Temp).Blueprints) | Should -Be @('prod', $slug)
                @(Get-TestVersion -Name $slug -Root $script:Temp) | Should -Be @(1)
            }
            @((Get-PETenant -Slug 'master' -DataRoot $script:Temp).Blueprints) | Should -BeNullOrEmpty
            $second = @(& $script:Tool -MasterBlueprint 'prod' -DataRoot $script:Temp)
            @($second | ForEach-Object Action | Sort-Object -Unique) | Should -Be @('Skipped')
            @(Get-TestVersion -Name 'dev' -Root $script:Temp) | Should -Be @(1)
        }
    }
}

