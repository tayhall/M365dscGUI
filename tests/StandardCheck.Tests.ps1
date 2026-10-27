BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures\asd-mini'
    . "$PSScriptRoot\StandardTestHelper.ps1"
}

Describe 'Invoke-PEStandardCheck' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-stdcheck-' + [guid]::NewGuid())
        Import-PEStandard -Name 'asd' -Path $script:Fixture -SourceName 'ASD' -SourceUrl 'https://example.test' -SourceVersion 'v1.4.0' -DataRoot $script:Temp -WarningAction SilentlyContinue 6>$null | Out-Null
        $script:Seen = $null
    }

    AfterEach {
        if (Test-Path $script:Temp) { Remove-Item $script:Temp -Recurse -Force }
    }

    It 'exports only the workloads the standard covers' {
        $folder = New-TenantExport -Root $script:Temp
        $holder = [pscustomobject]@{ Workloads = $null }
        $export = { param ($Arguments) $holder.Workloads = $Arguments.Workloads; $folder }.GetNewClosure()
        Invoke-PEStandardCheck -StandardName 'asd' -ExportScript $export -TargetTenantId 'tenant-1' -DataRoot $script:Temp | Out-Null
        @($holder.Workloads | Sort-Object) | Should -Be @('AAD', 'Teams')
    }

    It 'reports a changed item and a missing item, and ignores tenant objects the standard does not define' {
        $folder = New-TenantExport -Root $script:Temp -Countries '@("AU","NZ")'
        $export = { $folder }.GetNewClosure()
        $result = Invoke-PEStandardCheck -StandardName 'asd' -ExportScript $export -TargetTenantId 'tenant-1' -DataRoot $script:Temp
        @($result.Findings | Where-Object Kind -EQ 'Changed' | ForEach-Object ResourceType) | Should -Be @('AADNamedLocationPolicy')
        @($result.Findings | Where-Object Kind -EQ 'Missing' | ForEach-Object ResourceType) | Should -Be @('TeamsMessagingPolicy')
        @($result.Findings | Where-Object Kind -EQ 'TargetOnly').Count | Should -Be 0
    }

    It 'reports nothing when the tenant matches what the standard states' {
        $folder = New-TenantExport -Root $script:Temp
        $export = { $folder }.GetNewClosure()
        $result = Invoke-PEStandardCheck -StandardName 'asd' -ExportScript $export -TargetTenantId 'tenant-1' -DataRoot $script:Temp
        @($result.Findings | Where-Object Kind -EQ 'Changed').Count | Should -Be 0
    }

    It 'counts coverage per run: total, covered and checked' {
        $folder = New-TenantExport -Root $script:Temp
        $export = { $folder }.GetNewClosure()
        $result = Invoke-PEStandardCheck -StandardName 'asd' -ExportScript $export -TargetTenantId 'tenant-1' -DataRoot $script:Temp
        $result.Coverage.Total | Should -Be 5
        $result.Coverage.Covered | Should -Be 2
        $result.Coverage.Checked | Should -Be 2
        $result.Coverage.NotReadable | Should -Be 0
        $result.Coverage.NotCovered['Placeholder'] | Should -Be 1
        $result.Coverage.NotCovered['UnknownProperty'] | Should -Be 2
        $result.Coverage.ByWorkload['Teams'].Total | Should -Be 2
        $result.Coverage.ByWorkload['Teams'].Checked | Should -Be 1
    }

    It 'treats a type the export log marks failed as not readable, not Missing' {
        $folder = New-TenantExport -Root $script:Temp -TeamsFails
        $export = { $folder }.GetNewClosure()
        $result = Invoke-PEStandardCheck -StandardName 'asd' -ExportScript $export -TargetTenantId 'tenant-1' -DataRoot $script:Temp
        @($result.Findings | Where-Object Kind -EQ 'Missing').Count | Should -Be 0
        @($result.Findings | Where-Object Kind -EQ 'NotChecked' | ForEach-Object ResourceType) | Should -Contain 'TeamsMessagingPolicy'
        $result.Coverage.NotReadable | Should -Be 1
        $result.Coverage.Checked | Should -Be 1
    }

    It 'saves a Standard check that a Full-kind lookup does not return' {
        $folder = New-TenantExport -Root $script:Temp
        $export = { $folder }.GetNewClosure()
        $result = Invoke-PEStandardCheck -StandardName 'asd' -ExportScript $export -TargetTenantId 'tenant-1' -DataRoot $script:Temp
        $saved = Get-PECheck -CheckId $result.CheckId -DataRoot $script:Temp
        $saved.Kind | Should -Be 'Standard'
        $saved.StandardName | Should -Be 'asd'
        $saved.SourceVersion | Should -Be 'v1.4.0'
        (Get-PECheck -Latest -Kind Standard -DataRoot $script:Temp).CheckId | Should -Be $result.CheckId
        { Get-PECheck -Latest -Kind Full -DataRoot $script:Temp } | Should -Throw '*No Full check found*'
    }

    It 'applies a Noise decision like a full check' {
        $folder = New-TenantExport -Root $script:Temp -Countries '@("AU","NZ")'
        $export = { $folder }.GetNewClosure()
        Set-PEDecision -Kind Noise -ResourceType AADNamedLocationPolicy -Property CountriesAndRegions -Value @('AU', 'NZ') -Reason 'accepted noise' -DataRoot $script:Temp
        $result = Invoke-PEStandardCheck -StandardName 'asd' -ExportScript $export -TargetTenantId 'tenant-1' -DataRoot $script:Temp
        @($result.Findings | Where-Object Kind -EQ 'Changed').Count | Should -Be 0
    }

    It 'shows an accepted risk as Accepted on the next check, with who approved it' {
        $folder = New-TenantExport -Root $script:Temp -Countries '@("AU","NZ")'
        $export = { $folder }.GetNewClosure()
        Set-PERiskAcceptance -Standard 'asd' -Tenant master -ResourceType AADNamedLocationPolicy -Key 'Allowed Countries' -ApprovedBy 'cio' -Reason 'NZ staff' -DataRoot $script:Temp | Out-Null
        $result = Invoke-PEStandardCheck -StandardName 'asd' -ExportScript $export -TargetTenantId 'tenant-1' -DataRoot $script:Temp
        $finding = @($result.Findings | Where-Object ResourceType -EQ 'AADNamedLocationPolicy')[0]
        $finding.State | Should -Be 'Accepted'
        $finding.ApprovedBy | Should -Be 'cio'
    }

    It 'ignores a risk accepted against another standard' {
        $folder = New-TenantExport -Root $script:Temp -Countries '@("AU","NZ")'
        $export = { $folder }.GetNewClosure()
        Set-PEDecision -Kind RiskAccepted -ResourceType AADNamedLocationPolicy -Key 'Allowed Countries' -Tenant master -ApprovedBy 'cio' -Reason 'other' -Standard 'nist' -DataRoot $script:Temp | Out-Null
        $result = Invoke-PEStandardCheck -StandardName 'asd' -ExportScript $export -TargetTenantId 'tenant-1' -DataRoot $script:Temp
        (@($result.Findings | Where-Object ResourceType -EQ 'AADNamedLocationPolicy')[0]).State | Should -Be 'Open'
    }
    It 'refuses a name that is not a standard' {
        Initialize-PEBlueprint -Name 'prod' -State (& (Get-Module PolicyEngine) { New-PEState -Records @() -NotChecked @() -Meta @{ TenantId = 't' } }) -DataRoot $script:Temp | Out-Null
        { Invoke-PEStandardCheck -StandardName 'prod' -ExportScript { 'x' } -DataRoot $script:Temp } | Should -Throw "*'prod' is not a standard*"
    }
}
