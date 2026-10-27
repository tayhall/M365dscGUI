BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures\asd-mini'
    . "$PSScriptRoot\StandardTestHelper.ps1"
}

Describe 'Invoke-PEStandardCheck' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-stdcheck-' + [guid]::NewGuid())
        Import-PEStandard -Name 'asd' -Path $script:Fixture -SourceName 'ASD' -SourceUrl 'https://example.test' -SourceVersion 'v1.4.0' -DataRoot $script:Temp -WarningAction SilentlyContinue 6>$null | Out-Null
        # The tenant's blueprint has the named location with AU and NZ, no Teams policy, and an object the standard does not define.
        New-TestTenantBlueprint -Root $script:Temp
        $script:Location = { param ($result) @($result.Findings | Where-Object ResourceType -EQ 'AADNamedLocationPolicy')[0] }
    }

    AfterEach {
        if (Test-Path $script:Temp) { Remove-Item $script:Temp -Recurse -Force }
    }

    It 'compares the tenant''s blueprint with the standard: a changed item, a missing item, and nothing the standard does not define' {
        $result = Invoke-PEStandardCheck -StandardName 'asd' -BlueprintName 'main' -DataRoot $script:Temp
        @($result.Findings | Where-Object Kind -EQ 'Changed' | ForEach-Object ResourceType) | Should -Be @('AADNamedLocationPolicy')
        @($result.Findings | Where-Object Kind -EQ 'Missing' | ForEach-Object ResourceType) | Should -Be @('TeamsMessagingPolicy')
        @($result.Findings | Where-Object Kind -EQ 'TargetOnly').Count | Should -Be 0
        $result.BlueprintName | Should -Be 'main'
        $result.BlueprintVersion | Should -Be 1
    }

    It 'reads nothing from the tenant' {
        (Get-Command Invoke-PEStandardCheck).Parameters.ContainsKey('ExportScript') | Should -BeFalse
        Invoke-PEStandardCheck -StandardName 'asd' -BlueprintName 'main' -DataRoot $script:Temp | Out-Null
        Test-Path (Join-Path $script:Temp 'exports') | Should -BeFalse
    }

    It 'reports nothing for a setting the blueprint already states as the standard does' {
        New-TestTenantBlueprint -Root $script:Temp -Name 'aligned' -Countries @('AU')
        $result = Invoke-PEStandardCheck -StandardName 'asd' -BlueprintName 'aligned' -DataRoot $script:Temp
        @($result.Findings | Where-Object Kind -EQ 'Changed').Count | Should -Be 0
    }

    It 'counts coverage: total, covered and checked' {
        $result = Invoke-PEStandardCheck -StandardName 'asd' -BlueprintName 'main' -DataRoot $script:Temp
        $result.Coverage.Total | Should -Be 5
        $result.Coverage.Covered | Should -Be 2
        $result.Coverage.Checked | Should -Be 2
        $result.Coverage.NotReadable | Should -Be 0
        $result.Coverage.NotCovered['Placeholder'] | Should -Be 1
        $result.Coverage.NotCovered['UnknownProperty'] | Should -Be 2
        $result.Coverage.ByWorkload['Teams'].Total | Should -Be 2
        $result.Coverage.ByWorkload['Teams'].Checked | Should -Be 1
    }

    It 'treats a type the blueprint has no data for as not readable, not Missing' {
        New-TestTenantBlueprint -Root $script:Temp -Name 'partial' -TeamsNotChecked
        $result = Invoke-PEStandardCheck -StandardName 'asd' -BlueprintName 'partial' -DataRoot $script:Temp
        @($result.Findings | Where-Object Kind -EQ 'Missing').Count | Should -Be 0
        @($result.Findings | Where-Object Kind -EQ 'NotChecked' | ForEach-Object ResourceType) | Should -Contain 'TeamsMessagingPolicy'
        $result.Coverage.NotReadable | Should -Be 1
        $result.Coverage.Checked | Should -Be 1
    }

    It 'compares the tenant''s own blueprint, and the master blueprint for a tenant with none' {
        New-TestTenantBlueprint -Root $script:Temp -Name 'dev' -Countries @('AU')
        Set-PETenant -Slug 'dev' -DisplayName 'Dev' -TenantId 'dev.onmicrosoft.com' -Blueprints @('main', 'dev') -DataRoot $script:Temp | Out-Null
        Set-PETenant -Slug 'plain' -DisplayName 'Plain' -TenantId 'plain.onmicrosoft.com' -DataRoot $script:Temp | Out-Null
        $dev = Invoke-PEStandardCheck -StandardName 'asd' -BlueprintName 'main' -Tenant dev -DataRoot $script:Temp
        $dev.BlueprintName | Should -Be 'dev'
        @($dev.Findings | Where-Object Kind -EQ 'Changed').Count | Should -Be 0
        $plain = Invoke-PEStandardCheck -StandardName 'asd' -BlueprintName 'main' -Tenant plain -DataRoot $script:Temp
        $plain.BlueprintName | Should -Be 'main'
        @($plain.Findings | Where-Object Kind -EQ 'Changed').Count | Should -Be 1
    }

    It 'works for an offline tenant, which is never read' {
        Set-PETenant -Slug 'off' -DisplayName 'Offline' -TenantId 'off.onmicrosoft.com' -Offline -DataRoot $script:Temp | Out-Null
        $result = Invoke-PEStandardCheck -StandardName 'asd' -BlueprintName 'main' -Tenant off -DataRoot $script:Temp
        $result.BlueprintName | Should -Be 'main'
        @($result.Findings).Count | Should -BeGreaterThan 0
    }

    It 'saves a Standard check that a Full-kind lookup does not return, and that can be found by standard' {
        $result = Invoke-PEStandardCheck -StandardName 'asd' -BlueprintName 'main' -DataRoot $script:Temp
        $saved = Get-PECheck -CheckId $result.CheckId -DataRoot $script:Temp
        $saved.Kind | Should -Be 'Standard'
        $saved.StandardName | Should -Be 'asd'
        $saved.SourceVersion | Should -Be 'v1.4.0'
        $saved.BlueprintName | Should -Be 'main'
        $saved.CheckedAt | Should -Not -BeNullOrEmpty
        (Get-PECheck -Latest -Kind Standard -DataRoot $script:Temp).CheckId | Should -Be $result.CheckId
        (Get-PECheck -Latest -Kind Standard -Standard asd -DataRoot $script:Temp).CheckId | Should -Be $result.CheckId
        { Get-PECheck -Latest -Kind Standard -Standard nist -DataRoot $script:Temp } | Should -Throw "*No Standard check found for standard 'nist'*"
        { Get-PECheck -Latest -Kind Full -DataRoot $script:Temp } | Should -Throw '*No Full check found*'
    }

    It 'applies a Noise decision like a full check' {
        Set-PEDecision -Kind Noise -ResourceType AADNamedLocationPolicy -Property CountriesAndRegions -Value @('AU', 'NZ') -Reason 'accepted noise' -DataRoot $script:Temp
        $result = Invoke-PEStandardCheck -StandardName 'asd' -BlueprintName 'main' -DataRoot $script:Temp
        @($result.Findings | Where-Object Kind -EQ 'Changed').Count | Should -Be 0
    }

    It 'shows an accepted risk as Accepted on the next check, with who approved it' {
        Set-PERiskAcceptance -Standard 'asd' -Tenant master -ResourceType AADNamedLocationPolicy -Key 'Allowed Countries' -ApprovedBy 'cio' -Reason 'NZ staff' -DataRoot $script:Temp | Out-Null
        $finding = & $script:Location (Invoke-PEStandardCheck -StandardName 'asd' -BlueprintName 'main' -DataRoot $script:Temp)
        $finding.State | Should -Be 'Accepted'
        $finding.ApprovedBy | Should -Be 'cio'
    }

    It 'shows the item open again after the acceptance is removed, and ignores a risk accepted against another standard' {
        Set-PERiskAcceptance -Standard 'asd' -Tenant master -ResourceType AADNamedLocationPolicy -Key 'Allowed Countries' -ApprovedBy 'cio' -Reason 'x' -DataRoot $script:Temp | Out-Null
        Remove-PEDecision -Kind RiskAccepted -ResourceType AADNamedLocationPolicy -Key 'Allowed Countries' -Tenant master -DataRoot $script:Temp
        (& $script:Location (Invoke-PEStandardCheck -StandardName 'asd' -BlueprintName 'main' -DataRoot $script:Temp)).State | Should -Be 'Open'
        Set-PEDecision -Kind RiskAccepted -ResourceType AADNamedLocationPolicy -Key 'Allowed Countries' -Tenant master -ApprovedBy 'cio' -Reason 'other' -Standard 'nist' -DataRoot $script:Temp | Out-Null
        (& $script:Location (Invoke-PEStandardCheck -StandardName 'asd' -BlueprintName 'main' -DataRoot $script:Temp)).State | Should -Be 'Open'
    }

    It 'shows the setting as matching once the blueprint has adopted it' {
        $item = [pscustomobject]@{ ResourceType = 'AADNamedLocationPolicy'; Key = 'Allowed Countries' }
        Copy-PEStandardItem -Standard 'asd' -To 'main' -Item $item -Reason 'adopt' -ExpectedVersion 1 -DataRoot $script:Temp | Out-Null
        $result = Invoke-PEStandardCheck -StandardName 'asd' -BlueprintName 'main' -DataRoot $script:Temp
        @($result.Findings | Where-Object ResourceType -EQ 'AADNamedLocationPolicy').Count | Should -Be 0
        $result.BlueprintVersion | Should -Be 2
    }

    It 'refuses a name that is not a standard' {
        { Invoke-PEStandardCheck -StandardName 'main' -BlueprintName 'main' -DataRoot $script:Temp } | Should -Throw "*'main' is not a standard*"
    }
}
