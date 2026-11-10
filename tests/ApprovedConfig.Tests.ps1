BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures\upload'
    $script:Fp = ('a' * 64)

    function New-ExportCopy
    {
        param ([string]$Fixture)
        $folder = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-ac-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Fixtures $Fixture) -Destination (Join-Path $folder 'export.ps1')
        Set-Content -LiteralPath (Join-Path $folder 'export.log') -Value '' -Encoding utf8
        $folder
    }
    function New-List
    {
        param ([object[]]$Item)
        $side = { param ($run) @{ Run = $run; ExportedAt = '2026-11-03T10:00:00Z'; Fingerprint = $script:Fp } }
        New-PEApprovedList -Tenant 'dev' -ApprovedBy 'andrew' -Source (& $side '1') -Target (& $side '2') -Item $Item -ModuleVersion '2.26.1104.1'
    }
    function Get-Approved
    {
        param ([object[]]$Item, [string]$Target = 'entra-drift.ps1')
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-ac-root-' + [guid]::NewGuid().ToString('N'))
        New-PEApprovedConfig -List (New-List $Item) -SourceExportPath (New-ExportCopy 'entra.ps1') -TargetExportPath (New-ExportCopy $Target) `
            -TargetTenantDomain 'contoso-dev.onmicrosoft.com' -DataRoot $root -CompleteWorkload 'AAD' -WarningAction SilentlyContinue
    }
    function Item { param ($Action, $Key, [string[]]$Excluded = @()) @{ Action = $Action; ResourceType = 'AADGroup'; Key = $Key; ExcludedProperties = $Excluded } }
}

Describe 'New-PEApprovedConfig outcomes that need no generation' {
    It 'is NoActionRequired for every item when Dev already matches' {
        $r = Get-Approved @((Item Create 'Finance'), (Item Update 'Sales'), (Item Remove 'Marketing')) -Target 'entra.ps1'
        @($r.Items.Outcome | Select-Object -Unique) | Should -Be @('NoActionRequired')
        @($r.Configs).Count | Should -Be 0
    }

    It 'skips a Remove of an object PreProd also has' {
        $r = Get-Approved @((Item Remove 'Finance')) -Target 'entra.ps1'
        $r.Items[0].Outcome | Should -Be 'Skipped'
        $r.Items[0].Reason | Should -BeLike '*PreProd*'
    }

    It 'skips a Create that exists but differs' {
        $r = Get-Approved @((Item Create 'Sales'))
        $r.Items[0].Outcome | Should -Be 'Skipped'
        $r.Items[0].Reason | Should -BeLike '*differs*'
    }

    It 'skips an Update whose object is gone' {
        $r = Get-Approved @((Item Update 'Finance'))
        $r.Items[0].Outcome | Should -Be 'Skipped'
        $r.Items[0].Reason | Should -BeLike '*no longer exists*'
    }

    It 'skips an item the comparison cannot match to one object' {
        $r = Get-Approved @((Item Create 'Nobody'))
        $r.Items[0].Outcome | Should -Be 'Skipped'
    }

    It 'keeps Dev''s value for an excluded property, so an Update of only that property needs no action' {
        $r = Get-Approved @((Item Update 'Sales' -Excluded @('MailNickname')))
        $r.Items[0].Outcome | Should -Be 'NoActionRequired'
    }

    It 'returns one row per approved item, in the order of the list' {
        $r = Get-Approved @((Item Remove 'Marketing'), (Item Create 'Finance'), (Item Update 'Sales'))
        @($r.Items.Key) | Should -Be @('Marketing', 'Finance', 'Sales')
    }
}

Describe 'New-PEApprovedConfig generation' -Tag 'Slow' {
    It 'creates, updates and removes only the approved items' {
        $r = Get-Approved @((Item Create 'Finance'), (Item Update 'Sales'), (Item Remove 'Marketing'))
        @($r.Items.Outcome | Select-Object -Unique) | Should -Be @('ToApply')
        $changes = @($r.Configs | Where-Object Phase -EQ 'Changes')
        $removals = @($r.Configs | Where-Object Phase -EQ 'Removals')
        $changes.Count | Should -Be 1
        $removals.Count | Should -Be 1
        $changes[0].ResourceType | Should -Be 'AADGroup'
        $changes[0].ItemCount | Should -Be 2
        $changes[0].Text | Should -BeLike '*Finance*'
        $changes[0].Text | Should -BeLike '*Sales*'
        $changes[0].Text | Should -Not -BeLikeExactly '*AADGroup-Marketing*'
        $removals[0].Text | Should -BeLike '*Marketing*'
        $removals[0].Text | Should -Not -BeLikeExactly '*AADGroup-Finance*'
        @($r.Configs.Phase) | Should -Be @('Changes', 'Removals')
    }

    It 'does not plan a group that is not in the list' {
        $r = Get-Approved @((Item Create 'Finance'))
        @($r.Configs).Count | Should -Be 1
        $r.Configs[0].Text | Should -Not -BeLikeExactly '*AADGroup-Sales*'
        $r.Configs[0].Text | Should -Not -BeLikeExactly '*AADGroup-Marketing*'
    }

    It 'names each configuration after its type and phase' {
        $r = Get-Approved @((Item Create 'Finance'), (Item Remove 'Marketing'))
        @($r.Configs.ConfigurationName) | Should -Be @('PE_AADGroup_Changes', 'PE_AADGroup_Removals')
        $r.Configs[0].Text | Should -BeLike '*Configuration PE_AADGroup_Changes*'
    }

    It 'fills ResourceId for ToApply items, in the form the LCM reports' {
        $r = Get-Approved @((Item Create 'Finance'), (Item Update 'Sales'))
        foreach ($row in $r.Items)
        {
            $row.ResourceId | Should -Match '\A\[AADGroup\]\S+\z'
            $row.ResourceId | Should -BeLike "*$($row.Key)*"
        }
    }

    It 'names the configuration of each ToApply item, and none for the others' {
        $r = Get-Approved @((Item Create 'Finance'), (Item Remove 'Marketing'), (Item Create 'Sales'))
        ($r.Items | Where-Object Key -eq 'Finance').ConfigurationName | Should -Be 'PE_AADGroup_Changes'
        ($r.Items | Where-Object Key -eq 'Marketing').ConfigurationName | Should -Be 'PE_AADGroup_Removals'
        ($r.Items | Where-Object Key -eq 'Sales').ConfigurationName | Should -BeNullOrEmpty
    }

    It 'marks an engine refusal NotGenerated with the engine''s message and generates the rest' {
        Mock -ModuleName PolicyEngine New-PERectifyPlan { throw 'refused for the test' } -ParameterFilter { $Action -eq 'Update' }
        $r = Get-Approved @((Item Create 'Finance'), (Item Update 'Sales'))
        ($r.Items | Where-Object Key -eq 'Sales').Outcome | Should -Be 'NotGenerated'
        ($r.Items | Where-Object Key -eq 'Sales').Reason | Should -Be 'refused for the test'
        ($r.Items | Where-Object Key -eq 'Finance').Outcome | Should -Be 'ToApply'
        @($r.Configs).Count | Should -Be 1
    }
}

Describe 'New-PEApprovedConfig when the generator returns no text' {
    It 'marks the items NotGenerated instead of leaving them ToApply with no configuration' {
        Mock -ModuleName PolicyEngine ConvertTo-PEDscConfig { '' }
        $r = Get-Approved @((Item Create 'Finance'))
        $r.Items[0].Outcome | Should -Be 'NotGenerated'
        $r.Items[0].Reason | Should -BeLike '*no configuration*'
        @($r.Configs).Count | Should -Be 0
    }
}
