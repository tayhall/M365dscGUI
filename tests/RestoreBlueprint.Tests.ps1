BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force

    function New-TestRecord
    {
        param ([string]$Type = 'AADGroup', [string]$Key, [hashtable]$Props = @{})
        $p = [ordered]@{ DisplayName = $Key }
        foreach ($k in $Props.Keys) { $p[$k] = $Props[$k] }
        [pscustomobject]@{ ResourceType = $Type; Key = $Key; Workload = 'Entra ID'; TenantId = 't'; Properties = $p }
    }

    function New-TestState
    {
        param ([object[]]$Records = @())
        & (Get-Module PolicyEngine) {
            param ($r)
            New-PEState -Records $r -NotChecked @() -Meta @{ TenantId = 't'; ExportedAt = '2026-10-21T01:02:03Z'; Source = 'test' }
        } $Records
    }

    # Records a new version from a state, the way a Promote does.
    function Add-TestVersion
    {
        param ([object]$State, [string]$Reason)
        $changes = @(Get-PEBlueprintChange -Name 'main' -MasterState $State -DataRoot $script:Temp | Where-Object { $_.Kind -in 'Missing', 'TargetOnly', 'Changed' })
        Approve-PEBlueprintChange -Name 'main' -MasterState $State -Accept $changes -Reason $Reason -DataRoot $script:Temp | Out-Null
    }
}

Describe 'Restore-PEBlueprintVersion' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-restore-' + [guid]::NewGuid())
        # v1: g1 (one), g2.  v2: g1 changed, g2 removed, g3 added.  v3: g4 added.
        Initialize-PEBlueprint -Name 'main' -State (New-TestState -Records @((New-TestRecord -Key 'g1' -Props @{ Description = 'one' }), (New-TestRecord -Key 'g2'))) -DataRoot $script:Temp | Out-Null
        Add-TestVersion -State (New-TestState -Records @((New-TestRecord -Key 'g1' -Props @{ Description = 'two' }), (New-TestRecord -Key 'g3'))) -Reason 'second'
        Add-TestVersion -State (New-TestState -Records @((New-TestRecord -Key 'g1' -Props @{ Description = 'two' }), (New-TestRecord -Key 'g3'), (New-TestRecord -Key 'g4'))) -Reason 'third'
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'writes a new version that is a copy of the old one and keeps every version in between' {
        $r = Restore-PEBlueprintVersion -Name 'main' -Version 1 -Reason 'back to the start' -DataRoot $script:Temp
        $r.Version | Should -Be 4
        $r.RestoredFrom | Should -Be 1
        $r.Items.Key | Should -Contain 'g2'
        $records = (Get-PEBlueprint -Name 'main' -DataRoot $script:Temp).Records
        @($records.Key | Sort-Object) | Should -Be @('g1', 'g2')
        ($records | Where-Object Key -EQ 'g1').Properties.Description | Should -Be 'one'
        @((Get-PEBlueprint -Name 'main' -Version 3 -DataRoot $script:Temp).Records).Count | Should -Be 3
        @(Get-ChildItem (Join-Path $script:Temp 'blueprints\main') -Filter 'v*.json').Count | Should -Be 4
        (Get-PEBlueprint -Name 'main' -DataRoot $script:Temp).Meta.Version | Should -Be 4
    }

    It 'records the version it came from in the change record, with what was added, removed and changed' {
        Restore-PEBlueprintVersion -Name 'main' -Version 1 -Reason 'back to the start' -DataRoot $script:Temp | Out-Null
        $change = Get-Content (Join-Path $script:Temp 'blueprints\main\changes\v0004.json') -Raw | ConvertFrom-Json
        $change.RestoredFrom | Should -Be 1
        $change.Reason | Should -Be 'back to the start'
        ($change.Changes | Where-Object Key -EQ 'g2').Kind | Should -Be 'Missing'
        ($change.Changes | Where-Object Key -EQ 'g3').Kind | Should -Be 'TargetOnly'
        ($change.Changes | Where-Object Key -EQ 'g4').Kind | Should -Be 'TargetOnly'
        ($change.Changes | Where-Object Key -EQ 'g1').Kind | Should -Be 'Changed'
    }

    It 'restores one item only and leaves every other item as it is' {
        $r = Restore-PEBlueprintVersion -Name 'main' -Version 1 -Item @([pscustomobject]@{ ResourceType = 'AADGroup'; Key = 'g1' }) -Reason 'one item' -DataRoot $script:Temp
        $r.Items.Key | Should -Be @('g1')
        $records = (Get-PEBlueprint -Name 'main' -DataRoot $script:Temp).Records
        @($records.Key | Sort-Object) | Should -Be @('g1', 'g3', 'g4')
        ($records | Where-Object Key -EQ 'g1').Properties.Description | Should -Be 'one'
    }

    It 'restoring an item the old version did not have removes it, and one it had adds it back' {
        Restore-PEBlueprintVersion -Name 'main' -Version 1 -Item @([pscustomobject]@{ ResourceType = 'AADGroup'; Key = 'g4' }) -Reason 'drop g4' -DataRoot $script:Temp | Out-Null
        Restore-PEBlueprintVersion -Name 'main' -Version 1 -Item @([pscustomobject]@{ ResourceType = 'AADGroup'; Key = 'g2' }) -Reason 'g2 back' -DataRoot $script:Temp | Out-Null
        @((Get-PEBlueprint -Name 'main' -DataRoot $script:Temp).Records.Key | Sort-Object) | Should -Be @('g1', 'g2', 'g3')
    }

    It 'refuses the current version, an unknown version, and an item that is already as it was' {
        { Restore-PEBlueprintVersion -Name 'main' -Version 3 -Reason 'x' -DataRoot $script:Temp } | Should -Throw '*already the current version*'
        { Restore-PEBlueprintVersion -Name 'main' -Version 9 -Reason 'x' -DataRoot $script:Temp } | Should -Throw '*no version 9*'
        { Restore-PEBlueprintVersion -Name 'main' -Version 2 -Item @([pscustomobject]@{ ResourceType = 'AADGroup'; Key = 'g1' }) -Reason 'x' -DataRoot $script:Temp } | Should -Throw '*does not differ*'
        @(Get-ChildItem (Join-Path $script:Temp 'blueprints\main') -Filter 'v*.json').Count | Should -Be 3 -Because 'a refused restore writes nothing'
    }
}
