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

    function Get-TestVersion
    {
        param ([string]$Name, [string]$Root)
        & (Get-Module PolicyEngine) { @(Get-PEBlueprintVersionNumber -Directory (Get-PEBlueprintDirectory -Name $args[0] -DataRoot $args[1])) } $Name $Root
    }
}

Describe 'Moving items between blueprints' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-move-' + [guid]::NewGuid())
        # prod and dev differ: g1 changed, g3 only in dev, g4 only in prod, g2 equal.
        Initialize-PEBlueprint -Name 'prod' -State (New-TestState -Records @((New-TestRecord -Key 'g1' -Props @{ Description = 'one' }), (New-TestRecord -Key 'g2'), (New-TestRecord -Key 'g4'))) -DataRoot $script:Temp | Out-Null
        Initialize-PEBlueprint -Name 'dev' -State (New-TestState -Records @((New-TestRecord -Key 'g1' -Props @{ Description = 'two' }), (New-TestRecord -Key 'g2'), (New-TestRecord -Key 'g3'))) -DataRoot $script:Temp | Out-Null
        $script:Item = { param ($key) [pscustomobject]@{ ResourceType = 'AADGroup'; Key = $key } }
    }

    AfterEach {
        if (Test-Path $script:Temp) { Remove-Item $script:Temp -Recurse -Force }
    }

    It 'previews every difference when no item is named, as added, changed and removed in the target' {
        $rows = @(Get-PEBlueprintMovePreview -From 'prod' -To 'dev' -DataRoot $script:Temp)
        ($rows | Where-Object Key -EQ 'g4').Op | Should -Be 'Added'
        ($rows | Where-Object Key -EQ 'g1').Op | Should -Be 'Changed'
        ($rows | Where-Object Key -EQ 'g3').Op | Should -Be 'Removed'
        @($rows | Where-Object Key -EQ 'g2').Count | Should -Be 0
    }

    It 'pulls an item that only the master blueprint has into the tenant blueprint and leaves the master alone' {
        Move-PEBlueprintItem -From 'prod' -To 'dev' -Item (& $script:Item 'g4') -Reason 'catch up' -ExpectedVersion 1 -DataRoot $script:Temp | Should -Be 2
        @((Get-PEBlueprint -Name 'dev' -DataRoot $script:Temp).Records | ForEach-Object Key | Sort-Object) | Should -Be @('g1', 'g2', 'g3', 'g4')
        @(Get-TestVersion -Name 'prod' -Root $script:Temp) | Should -Be @(1)
        ((Get-PEBlueprint -Name 'dev' -DataRoot $script:Temp).Records | Where-Object Key -EQ 'g1').Properties.Description | Should -Be 'two'
    }

    It 'promotes a changed item up so the master blueprint takes the tenant values' {
        Move-PEBlueprintItem -From 'dev' -To 'prod' -Item (& $script:Item 'g1') -Reason 'kept' -ExpectedVersion 1 -DataRoot $script:Temp | Should -Be 2
        ((Get-PEBlueprint -Name 'prod' -DataRoot $script:Temp).Records | Where-Object Key -EQ 'g1').Properties.Description | Should -Be 'two'
    }

    It 'removes from the target an item the source lacks, and the preview says Removed' {
        @(Get-PEBlueprintMovePreview -From 'dev' -To 'prod' -Item (& $script:Item 'g4') -DataRoot $script:Temp).Op | Should -Be 'Removed'
        Move-PEBlueprintItem -From 'dev' -To 'prod' -Item (& $script:Item 'g4') -Reason 'dropped' -ExpectedVersion 1 -DataRoot $script:Temp | Out-Null
        @((Get-PEBlueprint -Name 'prod' -DataRoot $script:Temp).Records | ForEach-Object Key) | Should -Not -Contain 'g4'
    }

    It 'refuses a stale target version and writes nothing' {
        { Move-PEBlueprintItem -From 'prod' -To 'dev' -Item (& $script:Item 'g4') -Reason 'x' -ExpectedVersion 0 -DataRoot $script:Temp } | Should -Throw '*changed since*'
        @(Get-TestVersion -Name 'dev' -Root $script:Temp) | Should -Be @(1)
    }

    It 'treats blueprint names that differ only in case as the same blueprint' {
        { Move-PEBlueprintItem -From 'prod' -To 'PROD' -Item (& $script:Item 'g4') -Reason 'x' -ExpectedVersion 1 -DataRoot $script:Temp } | Should -Throw '*same blueprint*'
    }

    It 'refuses when the source blueprint changed after the review and writes nothing' {
        { Move-PEBlueprintItem -From 'prod' -To 'dev' -Item (& $script:Item 'g4') -Reason 'x' -ExpectedVersion 1 -ExpectedSourceVersion 0 -DataRoot $script:Temp } | Should -Throw '*prod*changed since*'
        @(Get-TestVersion -Name 'dev' -Root $script:Temp) | Should -Be @(1)
        Move-PEBlueprintItem -From 'prod' -To 'dev' -Item (& $script:Item 'g4') -Reason 'x' -ExpectedVersion 1 -ExpectedSourceVersion 1 -DataRoot $script:Temp | Should -Be 2
    }

    It 'refuses an item that is not a difference, and a missing reason' {
        { Move-PEBlueprintItem -From 'prod' -To 'dev' -Item (& $script:Item 'g2') -Reason 'x' -ExpectedVersion 1 -DataRoot $script:Temp } | Should -Throw '*is not a difference*'
        { Move-PEBlueprintItem -From 'prod' -To 'dev' -Item (& $script:Item 'g4') -Reason '' -ExpectedVersion 1 -DataRoot $script:Temp } | Should -Throw
        @(Get-TestVersion -Name 'dev' -Root $script:Temp) | Should -Be @(1)
    }
}
