BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures\upload'

    function New-ExportCopy
    {
        param ([string]$Fixture)
        $folder = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-cmp-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Fixtures $Fixture) -Destination (Join-Path $folder 'export.ps1')
        Set-Content -LiteralPath (Join-Path $folder 'export.log') -Value '' -Encoding utf8
        $folder
    }
    function Invoke-Fixture
    {
        param ([object[]]$Decision = @())
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-cmp-root-' + [guid]::NewGuid().ToString('N'))
        Invoke-PEExportComparison -SourceExportPath (New-ExportCopy 'entra.ps1') -TargetExportPath (New-ExportCopy 'entra-drift.ps1') `
            -TargetTenantDomain 'contoso-dev.onmicrosoft.com' -DataRoot $root -CompleteWorkload 'AAD' -Decision $Decision -WarningAction SilentlyContinue
    }
}

Describe 'Invoke-PEExportComparison' {
    It 'finds the missing, target-only and changed group' {
        $r = Invoke-Fixture
        $open = @($r.Findings | Where-Object { $_.State -eq 'Open' -and $_.ResourceType -eq 'AADGroup' })
        ($open | Where-Object Kind -eq 'Missing').Key | Should -Be 'Finance'
        ($open | Where-Object Kind -eq 'TargetOnly').Key | Should -Be 'Marketing'
        $changed = $open | Where-Object Kind -eq 'Changed'
        $changed.Key | Should -Be 'Sales'
        @($changed.Differences.Property) | Should -Be @('MailNickname')
        $open.Count | Should -Be 3
    }

    It 'returns the pieces the callers need' {
        $r = Invoke-Fixture
        $r.PSObject.Properties.Name | Should -Contain 'Check'
        $r.PSObject.Properties.Name | Should -Contain 'Blueprint'
        $r.PSObject.Properties.Name | Should -Contain 'DataRoot'
        @($r.SourceState.Records).Count | Should -BeGreaterThan 0
    }

    It 'passes decisions through' {
        $decision = [pscustomobject]@{ Kind = 'PropertyExcluded'; Tenant = 'target'; ResourceType = 'AADGroup'; Key = 'Sales'; Property = 'MailNickname' }
        $r = Invoke-Fixture -Decision @($decision)
        $withDifferences = @($r.Findings | Where-Object { $_.Kind -eq 'Changed' -and $_.Key -eq 'Sales' -and @($_.Differences).Count -gt 0 })
        $withDifferences.Count | Should -Be 0
        # The other two findings are untouched.
        @($r.Findings | Where-Object { $_.State -eq 'Open' -and $_.Kind -in 'Missing', 'TargetOnly' }).Count | Should -Be 2
    }
}
