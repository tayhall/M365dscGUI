BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures\asd-mini'

    function Import-TestStandard
    {
        param ([string]$Path = $script:Fixture, [string]$SourceVersion = 'v1.4.0', [string]$Root)
        Import-PEStandard -Name 'asd' -Path $Path -SourceName 'ASD Blueprint for Secure Cloud' -SourceUrl 'https://example.test/asd' `
            -SourceVersion $SourceVersion -Attribution 'ASD, CC BY 4.0' -DataRoot $Root -WarningAction SilentlyContinue 6>$null
    }
}

Describe 'Importing a standard from DSC files' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-import-' + [guid]::NewGuid())
    }

    AfterEach {
        if (Test-Path $script:Temp) { Remove-Item $script:Temp -Recurse -Force }
    }

    It 'imports the clean items and counts the rest as not covered' {
        $result = Import-TestStandard -Root $script:Temp
        $result.Total | Should -Be 5
        $result.Covered | Should -Be 2
        $result.NotCovered | Should -Be 3
        $result.ByReason['Placeholder'] | Should -Be 1
        $result.ByReason['UnknownProperty'] | Should -Be 2
        $result.Version | Should -Be 1
        @((Get-PEBlueprint -Name 'asd' -DataRoot $script:Temp).Records | ForEach-Object ResourceType | Sort-Object) | Should -Be @('AADNamedLocationPolicy', 'TeamsMessagingPolicy')
    }

    It 'strips connection settings and tenant ids' {
        Import-TestStandard -Root $script:Temp | Out-Null
        foreach ($record in (Get-PEBlueprint -Name 'asd' -DataRoot $script:Temp).Records)
        {
            foreach ($name in 'ApplicationId', 'CertificateThumbprint', 'TenantId')
            {
                $record.Properties.PSObject.Properties.Name | Should -Not -Contain $name
            }
        }
    }

    It 'puts provenance on every stored record' {
        Import-TestStandard -Root $script:Temp | Out-Null
        foreach ($record in (Get-PEBlueprint -Name 'asd' -DataRoot $script:Temp).Records)
        {
            $record.Provenance.Standard | Should -Be 'asd'
            $record.Provenance.SourceVersion | Should -Be 'v1.4.0'
            $record.Provenance.ControlId | Should -BeNullOrEmpty
        }
    }

    It 'writes standard.json and a coverage list for the version' {
        Import-TestStandard -Root $script:Temp | Out-Null
        $info = Get-PEStandard -Name 'asd' -DataRoot $script:Temp
        $info.SourceName | Should -Be 'ASD Blueprint for Secure Cloud'
        $info.License | Should -Be 'CC BY 4.0'
        $info.Versions[0].SourceVersion | Should -Be 'v1.4.0'
        $info.Versions[0].Covered | Should -Be 2
        $rows = @(Get-PEStandardCoverage -Name 'asd' -DataRoot $script:Temp)
        $rows.Count | Should -Be 3
        ($rows | Where-Object Reason -EQ 'Placeholder').ResourceType | Should -Be 'AADConditionalAccessPolicy'
        ($rows | Where-Object ResourceType -EQ 'AADAuthorizationPolicy').Detail | Should -BeLike '*DefaultUserRoleAllowedToCreateApps*'
    }

    It 'refuses to import the same source version twice' {
        Import-TestStandard -Root $script:Temp | Out-Null
        { Import-TestStandard -Root $script:Temp } | Should -Throw '*already imported*'
        @((Get-PEStandard -Name 'asd' -DataRoot $script:Temp).Versions).Count | Should -Be 1
    }

    It 'imports a newer source version as the next blueprint version and reports what changed' {
        Import-TestStandard -Root $script:Temp | Out-Null
        $copy = Join-Path $script:Temp 'v2files'
        Copy-Item -LiteralPath $script:Fixture -Destination $copy -Recurse
        $entra = Join-Path $copy 'Entra.txt'
        (Get-Content -LiteralPath $entra -Raw).Replace('CountriesAndRegions               = @("AU");', 'CountriesAndRegions               = @("AU","NZ");') | Set-Content -LiteralPath $entra -NoNewline
        $teams = Join-Path $copy 'Teams.txt'
        (Get-Content -LiteralPath $teams -Raw) -replace '(?s)        TeamsMessagingPolicy "TeamsMessagingPolicy-Global"\r?\n        \{.*?\r?\n        \}\r?\n', '' | Set-Content -LiteralPath $teams -NoNewline
        $result = Import-TestStandard -Path $copy -SourceVersion 'v1.5.0' -Root $script:Temp
        $result.Version | Should -Be 2
        $result.Changed | Should -Be 1
        $result.Removed | Should -Be 1
        $result.Added | Should -Be 0
        $rows = @(Get-PEStandardChange -Name 'asd' -FromVersion 1 -ToVersion 2 -DataRoot $script:Temp)
        ($rows | Where-Object Op -EQ 'Changed').ResourceType | Should -Be 'AADNamedLocationPolicy'
        ($rows | Where-Object Op -EQ 'Removed').ResourceType | Should -Be 'TeamsMessagingPolicy'
    }

    It 'reads files with the .txt extension and a byte-order mark' {
        # Teams.txt in the fixture starts with a byte-order mark and every fixture file is .txt; both import above.
        [byte[]]$head = Get-Content -LiteralPath (Join-Path $script:Fixture 'Teams.txt') -AsByteStream -TotalCount 3
        ($head -join ',') | Should -Be '239,187,191'
        (Import-TestStandard -Root $script:Temp).Total | Should -BeGreaterThan 0
    }

    It 'names the file it cannot parse and writes nothing' {
        $copy = Join-Path $script:Temp 'broken'
        New-Item -ItemType Directory -Path $copy | Out-Null
        Set-Content -LiteralPath (Join-Path $copy 'NotAConfig.txt') -Value 'Write-Host "hello"'
        { Import-TestStandard -Path $copy -Root $script:Temp } | Should -Throw '*NotAConfig.txt*'
        @(Get-PEStandard -Name 'asd' -DataRoot $script:Temp).Count | Should -Be 0
    }

    It 'never runs the files' {
        $copy = Join-Path $script:Temp 'evil'
        Copy-Item -LiteralPath $script:Fixture -Destination $copy -Recurse
        $marker = Join-Path $script:Temp 'pwned.txt'
        Add-Content -LiteralPath (Join-Path $copy 'Entra.txt') -Value "New-Item -ItemType File -Path '$marker'"
        Import-TestStandard -Path $copy -Root $script:Temp | Out-Null
        Test-Path -LiteralPath $marker | Should -BeFalse
    }
}
