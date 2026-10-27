BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures\asd-mini'
    . "$PSScriptRoot\StandardTestHelper.ps1"

    function Read-Json
    {
        param ($Relative)
        Get-Content -LiteralPath (Join-Path $script:Gui $Relative) -Raw | ConvertFrom-Json -NoEnumerate -DateKind String
    }

    function Invoke-TestCheck
    {
        # The tenant's blueprint 'main' compared with the standard; -TeamsNotChecked compares a blueprint with no data for the Teams type.
        param ([switch]$TeamsNotChecked)
        $name = 'main'
        if ($TeamsNotChecked)
        {
            $name = 'partial'
            New-TestTenantBlueprint -Root $script:Temp -Name $name -TeamsNotChecked
        }
        Invoke-PEStandardCheck -StandardName 'asd' -BlueprintName $name -DataRoot $script:Temp
    }

    function Export-TestGui
    {
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui -WarningAction SilentlyContinue | Out-Null
    }
}

Describe 'Standards view models' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-guistd-' + [guid]::NewGuid())
        $script:Gui = Join-Path $script:Temp 'gui'
        $state = & (Get-Module PolicyEngine) { New-PEState -Records @() -NotChecked @() -Meta @{ TenantId = 't'; ExportedAt = '2026-10-21T01:02:03Z' } }
        # The master blueprint is the tenant's blueprint: the named location with AU and NZ, no Teams policy.
        New-TestTenantBlueprint -Root $script:Temp -Name 'main'
        # Export-PEGuiData needs one Full check to start from.
        $directory = Join-Path $script:Temp 'checks\20261021-020000'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        [ordered]@{ CheckId = '20261021-020000'; Kind = 'Full'; BlueprintName = 'main'; BlueprintVersion = 1; Findings = @(); State = $state } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $directory 'result.json') -Encoding utf8
        Import-PEStandard -Name 'asd' -Path $script:Fixture -SourceName 'ASD Blueprint for Secure Cloud' -SourceUrl 'https://example.test/asd' -SourceVersion 'v1.4.0' -Attribution 'ASD, CC BY 4.0' -DataRoot $script:Temp -WarningAction SilentlyContinue 6>$null | Out-Null
    }

    AfterEach {
        if (Test-Path $script:Temp) { Remove-Item $script:Temp -Recurse -Force }
    }

    It 'writes an empty standards index when there are no standards' {
        Remove-Item -LiteralPath (Join-Path $script:Temp 'blueprints\asd') -Recurse -Force
        Export-TestGui
        (Get-Content -LiteralPath (Join-Path $script:Gui 'standards/index.json') -Raw).Trim() | Should -Be '[]'
    }

    It 'describes the standard, its versions and its not-covered items' {
        Invoke-TestCheck | Out-Null
        Export-TestGui
        $index = @(Read-Json 'standards/index.json')
        $index.Count | Should -Be 1
        $index[0].name | Should -Be 'asd'
        $index[0].sourceName | Should -Be 'ASD Blueprint for Secure Cloud'
        $index[0].license | Should -Be 'CC BY 4.0'
        $index[0].latest.sourceVersion | Should -Be 'v1.4.0'
        $index[0].latest.covered | Should -Be 2
        $index[0].latestRelease | Should -BeNullOrEmpty
        $coverage = Read-Json 'standards/asd/coverage.json'
        $coverage.total | Should -Be 5
        $coverage.byReason.Placeholder | Should -Be 1
        $coverage.byReason.UnknownProperty | Should -Be 2
        @($coverage.rows).Count | Should -Be 3
        (@($coverage.rows) | Where-Object resourceType -EQ 'AADConditionalAccessPolicy').reason | Should -Be 'Placeholder'
    }

    It 'reads the latest release the worker found' {
        New-Item -ItemType Directory -Path (Join-Path $script:Temp 'sources') -Force | Out-Null
        '{"tag":"v1.5.0","checkedAt":"2026-10-27T10:00:00Z"}' | Set-Content -LiteralPath (Join-Path $script:Temp 'sources\asd-latest.json')
        Export-TestGui
        (@(Read-Json 'standards/index.json')[0]).latestRelease.tag | Should -Be 'v1.5.0'
    }

    It 'gives the selected tenant its headline, workloads and rows' {
        Invoke-TestCheck | Out-Null
        Export-TestGui
        $view = Read-Json 'tenants/master/standards/asd.json'
        $view.checked | Should -BeTrue
        $view.standardVersion | Should -Be 1
        $view.sourceVersion | Should -Be 'v1.4.0'
        $view.headline.total | Should -Be 5
        $view.headline.covered | Should -Be 2
        $view.headline.checked | Should -Be 2
        $view.headline.differ | Should -Be 2
        $view.headline.match | Should -Be 0
        @($view.rows).Count | Should -Be 2
        $location = @($view.rows | Where-Object resourceType -EQ 'AADNamedLocationPolicy')[0]
        $location.kind | Should -Be 'Changed'
        $location.status | Should -Be 'differs'
        # The Drift review lists these rows like any other drift, so they carry its state and first-seen fields.
        $location.state | Should -Be 'Open'
        $location.firstSeen | Should -Be $view.checkedAt
        $location.itemId | Should -Not -BeNullOrEmpty
        $location.differences[0].property | Should -Be 'CountriesAndRegions'
        @($location.differences[0].standard) | Should -Be @('AU')
        @($location.differences[0].blueprint) | Should -Be @('AU', 'NZ')
        @($location.allowedActions) | Should -Be @('Adopt', 'AcceptRisk')
        (@($view.rows | Where-Object resourceType -EQ 'TeamsMessagingPolicy')[0]).status | Should -Be 'missing'
        (@($view.byWorkload | Where-Object workload -EQ 'Teams')[0]).total | Should -Be 2
    }

    It 'always writes the lists of a row as arrays, also with one or no entry' {
        Invoke-TestCheck | Out-Null
        Export-TestGui
        $raw = Get-Content -LiteralPath (Join-Path $script:Gui 'tenants/master/standards/asd.json') -Raw
        $view = $raw | ConvertFrom-Json
        $changed = @($view.rows | Where-Object kind -EQ 'Changed')[0]
        $missing = @($view.rows | Where-Object kind -EQ 'Missing')[0]
        # One difference must still be a JSON array, or the page cannot loop over it.
        $raw | Should -Match '"differences":\s*\['
        $changed.differences -is [array] | Should -BeTrue
        $missing.differences -is [array] | Should -BeTrue
        $missing.acceptedDifferences -is [array] | Should -BeTrue
        $changed.allowedActions -is [array] | Should -BeTrue
        $view.byWorkload -is [array] | Should -BeTrue
        $view.rows -is [array] | Should -BeTrue
    }
    It 'never counts not covered or not readable items as matching' {
        Invoke-TestCheck -TeamsNotChecked | Out-Null
        Export-TestGui
        $view = Read-Json 'tenants/master/standards/asd.json'
        $h = $view.headline
        $h.notReadable | Should -Be 1
        $h.notCovered | Should -Be 3
        ($h.match + $h.differ + $h.accepted + $h.notReadable + $h.notCovered) | Should -Be $h.total
        @($view.rows | Where-Object resourceType -EQ 'TeamsMessagingPolicy').Count | Should -Be 0
        foreach ($row in @($view.byWorkload))
        {
            ($row.match + $row.differ + $row.accepted + $row.notReadable + $row.notCovered) | Should -Be $row.total
        }
    }

    It 'shows an accepted risk as accepted, with who and why' {
        Invoke-TestCheck | Out-Null
        Set-PERiskAcceptance -Standard 'asd' -Tenant master -ResourceType AADNamedLocationPolicy -Key 'Allowed Countries' -ApprovedBy 'cio' -Reason 'NZ staff' -DataRoot $script:Temp | Out-Null
        Invoke-TestCheck | Out-Null
        Export-TestGui
        $view = Read-Json 'tenants/master/standards/asd.json'
        $row = @($view.rows | Where-Object resourceType -EQ 'AADNamedLocationPolicy')[0]
        $row.status | Should -Be 'accepted'
        $row.state | Should -Be 'Accepted'
        $row.approvedBy | Should -Be 'cio'
        $row.acceptedReason | Should -Be 'NZ staff'
        @($row.allowedActions) | Should -Be @('RemoveRisk')
        $view.headline.accepted | Should -Be 1
        $view.headline.differ | Should -Be 1
        $view.blueprint.name | Should -Be 'main'
    }

    It 'shows an accepted risk whose standard changed as look again' {
        Invoke-TestCheck | Out-Null
        Set-PERiskAcceptance -Standard 'asd' -Tenant master -ResourceType AADNamedLocationPolicy -Key 'Allowed Countries' -ApprovedBy 'cio' -Reason 'NZ staff' -DataRoot $script:Temp | Out-Null
        $copy = Join-Path $script:Temp 'v2files'
        Copy-Item -LiteralPath $script:Fixture -Destination $copy -Recurse
        $entra = Join-Path $copy 'Entra.txt'
        (Get-Content -LiteralPath $entra -Raw).Replace('CountriesAndRegions               = @("AU");', 'CountriesAndRegions               = @("AU","FJ");') | Set-Content -LiteralPath $entra -NoNewline
        Import-PEStandard -Name 'asd' -Path $copy -SourceName 'ASD' -SourceUrl 'https://example.test' -SourceVersion 'v1.5.0' -DataRoot $script:Temp -WarningAction SilentlyContinue 6>$null | Out-Null
        # The old check is on version 1 of the standard: a newer version is imported.
        Export-TestGui
        (Read-Json 'tenants/master/standards/asd.json').newerVersionImported | Should -BeTrue
        Invoke-TestCheck | Out-Null
        Export-TestGui
        $view = Read-Json 'tenants/master/standards/asd.json'
        $view.newerVersionImported | Should -BeFalse
        $row = @($view.rows | Where-Object resourceType -EQ 'AADNamedLocationPolicy')[0]
        $row.status | Should -Be 'lookAgain'
        $row.hint | Should -BeLike '*needs another look*'
        @($row.allowedActions) | Should -Be @('Adopt', 'AcceptRisk', 'RemoveRisk')
        $view.headline.lookAgain | Should -Be 1
        $view.headline.differ | Should -Be 2
    }

    It 'shows an adopted setting as matching, and counts it as adopted' {
        Invoke-TestCheck | Out-Null
        Export-TestGui
        (Read-Json 'tenants/master/standards/asd.json').headline.match | Should -Be 0
        $teams = @((Get-PEBlueprint -Name 'asd' -DataRoot $script:Temp).Records | Where-Object ResourceType -EQ 'TeamsMessagingPolicy')[0]
        Copy-PEStandardItem -Standard 'asd' -To 'main' -Item ([pscustomobject]@{ ResourceType = $teams.ResourceType; Key = $teams.Key }) -Reason 'adopt' -ExpectedVersion 1 -DataRoot $script:Temp | Out-Null
        Invoke-TestCheck | Out-Null
        Export-TestGui
        $view = Read-Json 'tenants/master/standards/asd.json'
        @($view.rows | Where-Object resourceType -EQ 'TeamsMessagingPolicy').Count | Should -Be 0
        $view.headline.match | Should -Be 1
        $view.headline.differ | Should -Be 1
        $view.blueprint.version | Should -Be 2
        $view.adoption.blueprint | Should -Be 'main'
        $view.adoption.adopted | Should -Be 1
        $view.adoption.covered | Should -Be 2
    }
    It 'lists a tenant that has no check of the standard as not checked' {
        Set-PETenant -Slug 'dev' -DisplayName 'Dev' -TenantId 'dev.onmicrosoft.com' -DataRoot $script:Temp | Out-Null
        Invoke-TestCheck | Out-Null
        Export-TestGui
        $dev = Read-Json 'tenants/dev/standards/asd.json'
        $dev.checked | Should -BeFalse
        $dev.standard | Should -Be 'asd'
        $dev.tenantId | Should -Be 'dev'
    }

    It 'warns and carries on when one standard cannot be read' {
        Invoke-TestCheck | Out-Null
        Remove-Item -LiteralPath (Join-Path $script:Temp 'blueprints\asd\coverage') -Recurse -Force
        $warnings = @()
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
        ($warnings -join ' ') | Should -BeLike '*asd*'
        Test-Path (Join-Path $script:Gui 'index.json') | Should -BeTrue
        Test-Path (Join-Path $script:Gui 'standards/index.json') | Should -BeTrue
    }
}
