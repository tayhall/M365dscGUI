BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force

    function New-TestRecord
    {
        param ([string]$Key, [hashtable]$Props = @{})
        $p = [ordered]@{ DisplayName = $Key }
        foreach ($k in $Props.Keys) { $p[$k] = $Props[$k] }
        [pscustomobject]@{ ResourceType = 'AADGroup'; Key = $Key; Workload = 'Entra ID'; TenantId = 't'; Properties = $p }
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

Describe 'Compare-PEState -Subset' {
    It 'ignores target records the blueprint does not define' {
        $blueprint = New-TestState -Records @((New-TestRecord -Key 'g1'))
        $target = New-TestState -Records @((New-TestRecord -Key 'g1'), (New-TestRecord -Key 'g2'))
        @(Compare-PEState -Blueprint $blueprint -Target $target -Subset).Count | Should -Be 0
        @(Compare-PEState -Blueprint $blueprint -Target $target | Where-Object Kind -EQ 'TargetOnly').Count | Should -Be 1
    }

    It 'ignores properties the blueprint does not state' {
        $blueprint = New-TestState -Records @((New-TestRecord -Key 'g1' -Props @{ Description = 'a' }))
        $target = New-TestState -Records @((New-TestRecord -Key 'g1' -Props @{ Description = 'a'; Visibility = 'Public' }))
        @(Compare-PEState -Blueprint $blueprint -Target $target -Subset).Count | Should -Be 0
        @(Compare-PEState -Blueprint $blueprint -Target $target).Count | Should -Be 1
    }

    It 'still reports a stated property that differs' {
        $blueprint = New-TestState -Records @((New-TestRecord -Key 'g1' -Props @{ Description = 'a' }))
        $target = New-TestState -Records @((New-TestRecord -Key 'g1' -Props @{ Description = 'b'; Visibility = 'Public' }))
        $findings = @(Compare-PEState -Blueprint $blueprint -Target $target -Subset)
        $findings.Count | Should -Be 1
        $findings[0].Kind | Should -Be 'Changed'
        @($findings[0].Differences | ForEach-Object Property) | Should -Be @('Description')
    }

    It 'reports a defined item the tenant lacks as Missing' {
        $blueprint = New-TestState -Records @((New-TestRecord -Key 'g1'), (New-TestRecord -Key 'g2'))
        $target = New-TestState -Records @((New-TestRecord -Key 'g1'))
        $findings = @(Compare-PEState -Blueprint $blueprint -Target $target -Subset)
        $findings.Count | Should -Be 1
        $findings[0].Kind | Should -Be 'Missing'
        $findings[0].Key | Should -Be 'g2'
    }

    It 'reports duplicate target keys of a defined item as Ambiguous' {
        $blueprint = New-TestState -Records @((New-TestRecord -Key 'g1'))
        $target = New-TestState -Records @((New-TestRecord -Key 'g1'), (New-TestRecord -Key 'g1'))
        $findings = @(Compare-PEState -Blueprint $blueprint -Target $target -Subset)
        $findings.Count | Should -Be 1
        $findings[0].Kind | Should -Be 'Ambiguous'
    }

    It 'does not count an empty stated string as different from an absent property' {
        $blueprint = New-TestState -Records @((New-TestRecord -Key 'g1' -Props @{ Description = '' }))
        $target = New-TestState -Records @((New-TestRecord -Key 'g1'))
        @(Compare-PEState -Blueprint $blueprint -Target $target -Subset).Count | Should -Be 0
    }

    It 'accepts a target state read back from JSON, whose Meta is an object' {
        $blueprint = New-TestState -Records @((New-TestRecord -Key 'g1' -Props @{ Description = 'a' }))
        $saved = New-TestState -Records @((New-TestRecord -Key 'g1' -Props @{ Description = 'b' })) | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $saved.Meta.GetType().Name | Should -Be 'PSCustomObject'
        @(Compare-PEState -Blueprint $blueprint -Target $saved -Subset)[0].Kind | Should -Be 'Changed'
    }
}