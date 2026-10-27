BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures\asd-mini'

    function New-TestState
    {
        param ([object[]]$Records = @())
        & (Get-Module PolicyEngine) {
            param ($r)
            New-PEState -Records $r -NotChecked @() -Meta @{ TenantId = 't'; ExportedAt = '2026-10-21T01:02:03Z'; Source = 'test' }
        } $Records
    }
}

Describe 'Promoting from a standard' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-promote-' + [guid]::NewGuid())
        Import-PEStandard -Name 'asd' -Path $script:Fixture -SourceName 'ASD' -SourceUrl 'https://example.test' -SourceVersion 'v1.4.0' -DataRoot $script:Temp -WarningAction SilentlyContinue 6>$null | Out-Null
        $standardRecords = @((Get-PEBlueprint -Name 'asd' -DataRoot $script:Temp).Records)
        $script:Location = @($standardRecords | Where-Object ResourceType -EQ 'AADNamedLocationPolicy')[0]
        $script:Messaging = @($standardRecords | Where-Object ResourceType -EQ 'TeamsMessagingPolicy')[0]
        # The user's blueprint already holds the named location, with another country list and a property the standard does not state.
        $own = [pscustomobject]@{
            ResourceType = 'AADNamedLocationPolicy'; Key = $script:Location.Key; Workload = 'Entra ID'; TenantId = 't'
            Properties   = [ordered]@{ DisplayName = $script:Location.Key; CountriesAndRegions = @('FJ'); IsTrusted = $true }
        }
        Initialize-PEBlueprint -Name 'prod' -State (New-TestState -Records @($own)) -DataRoot $script:Temp | Out-Null
        $script:Item = { param ($record) [pscustomobject]@{ ResourceType = $record.ResourceType; Key = $record.Key } }
    }

    AfterEach {
        if (Test-Path $script:Temp) { Remove-Item $script:Temp -Recurse -Force }
    }

    It 'adds a new item with its provenance' {
        Copy-PEStandardItem -Standard 'asd' -To 'prod' -Item (& $script:Item $script:Messaging) -Reason 'adopt messaging' -ExpectedVersion 1 -DataRoot $script:Temp | Should -Be 2
        $added = @((Get-PEBlueprint -Name 'prod' -DataRoot $script:Temp).Records | Where-Object ResourceType -EQ 'TeamsMessagingPolicy')[0]
        $added.Provenance.Standard | Should -Be 'asd'
        $added.Provenance.SourceVersion | Should -Be 'v1.4.0'
        $added.Properties.AllowGiphy | Should -Be $script:Messaging.Properties.AllowGiphy
    }

    It 'merges into an existing item: stated properties are taken, other properties are kept' {
        Copy-PEStandardItem -Standard 'asd' -To 'prod' -Item (& $script:Item $script:Location) -Reason 'adopt location' -ExpectedVersion 1 -DataRoot $script:Temp | Should -Be 2
        $merged = @((Get-PEBlueprint -Name 'prod' -DataRoot $script:Temp).Records | Where-Object ResourceType -EQ 'AADNamedLocationPolicy')[0]
        @($merged.Properties.CountriesAndRegions) | Should -Be @($script:Location.Properties.CountriesAndRegions)
        $merged.Properties.IsTrusted | Should -BeTrue
        $merged.Provenance.Standard | Should -Be 'asd'
    }

    It 'copies every standard item with -All' {
        Copy-PEStandardItem -Standard 'asd' -To 'prod' -All -Reason 'adopt all' -ExpectedVersion 1 -DataRoot $script:Temp | Should -Be 2
        @((Get-PEBlueprint -Name 'prod' -DataRoot $script:Temp).Records | ForEach-Object ResourceType | Sort-Object) | Should -Be @('AADNamedLocationPolicy', 'TeamsMessagingPolicy')
    }

    It 'leaves the standard unchanged and removes nothing from the blueprint' {
        Copy-PEStandardItem -Standard 'asd' -To 'prod' -Item (& $script:Item $script:Messaging) -Reason 'x' -ExpectedVersion 1 -DataRoot $script:Temp | Out-Null
        @((Get-PEBlueprint -Name 'asd' -DataRoot $script:Temp).Records).Count | Should -Be 2
        @((Get-PEStandard -Name 'asd' -DataRoot $script:Temp).Versions).Count | Should -Be 1
        @((Get-PEBlueprint -Name 'prod' -DataRoot $script:Temp).Records | Where-Object ResourceType -EQ 'AADNamedLocationPolicy').Count | Should -Be 1
    }

    It 'refuses a standard as the target' {
        { Copy-PEStandardItem -Standard 'asd' -To 'asd' -All -Reason 'x' -ExpectedVersion 1 -DataRoot $script:Temp } | Should -Throw '*is a standard (read-only)*'
    }

    It 'refuses a name that is not a standard as the source' {
        { Copy-PEStandardItem -Standard 'prod' -To 'prod' -All -Reason 'x' -ExpectedVersion 1 -DataRoot $script:Temp } | Should -Throw "*is not a standard*"
    }

    It 'refuses an item the standard does not have' {
        { Copy-PEStandardItem -Standard 'asd' -To 'prod' -Item ([pscustomobject]@{ ResourceType = 'AADGroup'; Key = 'nope' }) -Reason 'x' -ExpectedVersion 1 -DataRoot $script:Temp } | Should -Throw '*has no item*'
    }

    It 'refuses when the blueprint has moved on since it was reviewed' {
        Copy-PEStandardItem -Standard 'asd' -To 'prod' -Item (& $script:Item $script:Messaging) -Reason 'x' -ExpectedVersion 1 -DataRoot $script:Temp | Out-Null
        { Copy-PEStandardItem -Standard 'asd' -To 'prod' -Item (& $script:Item $script:Location) -Reason 'x' -ExpectedVersion 1 -DataRoot $script:Temp } | Should -Throw '*has changed since the review*'
    }

    It 'reports adoption, and still counts an adopted item after the blueprint edited it' {
        $before = @(Get-PEStandardAdoption -Standard 'asd' -Blueprint 'prod' -DataRoot $script:Temp)
        @($before | Where-Object Adopted).Count | Should -Be 0
        Copy-PEStandardItem -Standard 'asd' -To 'prod' -Item (& $script:Item $script:Messaging) -Reason 'x' -ExpectedVersion 1 -DataRoot $script:Temp | Out-Null
        $after = @(Get-PEStandardAdoption -Standard 'asd' -Blueprint 'prod' -DataRoot $script:Temp)
        ($after | Where-Object ResourceType -EQ 'TeamsMessagingPolicy').Adopted | Should -BeTrue
        ($after | Where-Object ResourceType -EQ 'TeamsMessagingPolicy').SourceVersion | Should -Be 'v1.4.0'
        ($after | Where-Object ResourceType -EQ 'AADNamedLocationPolicy').Adopted | Should -BeFalse

        # The blueprint edits the adopted item (a new version through the normal writer); the provenance travels with the record.
        $current = Get-PEBlueprint -Name 'prod' -DataRoot $script:Temp
        $record = @($current.Records | Where-Object ResourceType -EQ 'TeamsMessagingPolicy')[0]
        $record.Properties.AllowGiphy = -not [bool]$record.Properties.AllowGiphy
        $state = New-TestState -Records @($current.Records)
        $changes = @(Get-PEBlueprintChange -Name 'prod' -MasterState $state -DataRoot $script:Temp)
        $changes.Count | Should -Be 1
        Approve-PEBlueprintChange -Name 'prod' -MasterState $state -Accept $changes -Reason 'local edit' -DataRoot $script:Temp | Should -Be 3
        $edited = @(Get-PEStandardAdoption -Standard 'asd' -Blueprint 'prod' -DataRoot $script:Temp)
        ($edited | Where-Object ResourceType -EQ 'TeamsMessagingPolicy').Adopted | Should -BeTrue
    }
}