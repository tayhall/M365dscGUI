BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures\upload'
    $script:FpA = ('a' * 64)
    $script:FpB = ('b' * 64)

    function New-ExportCopy
    {
        param ([string]$Fixture)
        $folder = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-rd-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Fixtures $Fixture) -Destination (Join-Path $folder 'export.ps1')
        Set-Content -LiteralPath (Join-Path $folder 'export.log') -Value '' -Encoding utf8
        $folder
    }
    function Get-Comparison
    {
        param ([string]$Target = 'entra-drift.ps1')
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-rd-root-' + [guid]::NewGuid().ToString('N'))
        Invoke-PEExportComparison -SourceExportPath (New-ExportCopy 'entra.ps1') -TargetExportPath (New-ExportCopy $Target) `
            -TargetTenantDomain 'contoso-dev.onmicrosoft.com' -DataRoot $root -CompleteWorkload 'AAD' -WarningAction SilentlyContinue
    }
    function Get-Data
    {
        param ([object]$Comparison, [string]$FpSource = $script:FpA, [string]$FpTarget = $script:FpB, [hashtable]$Extra = @{})
        Get-PEDriftReportData -Comparison $Comparison -Tenant 'dev' @Extra `
            -Source @{ Run = '101'; ExportedAt = '2026-11-03T10:00:00Z'; Fingerprint = $FpSource } `
            -Target @{ Run = '102'; ExportedAt = '2026-11-03T10:05:00Z'; Fingerprint = $FpTarget }
    }
    $script:Cmp = Get-Comparison
}

Describe 'Get-PEDriftReportData' {
    It 'lists Create Finance, Update Sales and Remove Marketing' {
        $d = Get-Data $script:Cmp
        @($d.Items.Id) | Should -Be @('Create|AADGroup|Finance', 'Remove|AADGroup|Marketing', 'Update|AADGroup|Sales')
        ($d.Items | Where-Object Approvable -eq $false).Count | Should -Be 0
    }

    It 'shows the differing property with both values' {
        $d = Get-Data $script:Cmp
        $sales = $d.Items | Where-Object Key -eq 'Sales'
        @($sales.Differences).Count | Should -Be 1
        $sales.Differences[0].Property | Should -Be 'MailNickname'
        $sales.Differences[0].PreProd | Should -BeOfType [string]
        $sales.Differences[0].Dev | Should -BeOfType [string]
        $sales.Differences[0].Dev | Should -Not -Be $sales.Differences[0].PreProd
    }

    It 'counts approvable items per action and keeps Matching honest' {
        $d = Get-Data $script:Cmp
        $d.Totals.Create | Should -Be 1
        $d.Totals.Update | Should -Be 1
        $d.Totals.Remove | Should -Be 1
        $d.Totals.CannotApprove | Should -Be 0
        $sourceRecords = @($script:Cmp.SourceState.Records).Count
        $d.Totals.Matching | Should -Be ($sourceRecords - 2)
    }

    It 'has every record matching when nothing differs' {
        $same = Get-Comparison -Target 'entra.ps1'
        $d = Get-Data $same
        @($d.Items).Count | Should -Be 0
        $d.Totals.Matching | Should -Be @($same.SourceState.Records).Count
        $d.Totals.Total | Should -Be @($same.SourceState.Records).Count
    }

    It 'marks an item the engine refuses as not approvable with its reason' {
        Mock -ModuleName PolicyEngine New-PERectifyPlan { throw "refused for test`nsecond line" } -ParameterFilter { @($Findings)[0].Key -eq 'Sales' }
        Mock -ModuleName PolicyEngine New-PERectifyPlan { [pscustomobject]@{ Action = $Action } } -ParameterFilter { @($Findings)[0].Key -ne 'Sales' }
        $d = Get-Data $script:Cmp
        $sales = $d.Items | Where-Object Key -eq 'Sales'
        $sales.Approvable | Should -BeFalse
        $sales.Reason | Should -Be 'refused for test'
        ($d.Items | Where-Object Key -eq 'Finance').Approvable | Should -BeTrue
        $d.Totals.CannotApprove | Should -Be 1
        $d.Totals.Update | Should -Be 0
    }

    It 'gives a non-actionable kind no action' {
        $cmp = Get-Comparison
        $ambiguous = [pscustomobject]@{ Kind = 'Ambiguous'; ResourceType = 'AADGroup'; Key = 'Dup'; Workload = 'Entra ID'; State = 'Open'
            Hint = 'Key matches 2 blueprint and 2 target records'; Differences = @(); BlueprintCount = 2; TargetCount = 2 }
        $cmp = [pscustomobject]@{ Findings = @($cmp.Findings + $ambiguous); Check = $cmp.Check; Blueprint = $cmp.Blueprint; DataRoot = $cmp.DataRoot; SourceState = $cmp.SourceState }
        $d = Get-Data $cmp
        $dup = $d.Items | Where-Object Key -eq 'Dup'
        $dup.Action | Should -BeNullOrEmpty
        $dup.Approvable | Should -BeFalse
        $dup.Reason | Should -BeLike 'Key matches*'
        $dup.Id | Should -Be 'Ambiguous|AADGroup|Dup'
        $d.Totals.CannotApprove | Should -Be 1
    }

    It 'cuts a long value' {
        $cmp = Get-Comparison
        $long = 'x' * 10000
        $cmp.Findings | Where-Object { $_.Kind -eq 'Changed' } | ForEach-Object { $_.Differences[0].Target = $long }
        $d = Get-Data $cmp -Extra @{ MaxValueLength = 50 }
        $dev = ($d.Items | Where-Object Key -eq 'Sales').Differences[0].Dev
        $dev.Length | Should -BeLessOrEqual 51
        $dev | Should -BeLike '*…'
    }

    It 'does not embed matching resources' {
        @((Get-Data $script:Cmp).Items).Count | Should -Be 3
    }

    It 'ReportId is stable for the same fingerprints and changes with either one' {
        $a = (Get-Data $script:Cmp).Meta.ReportId
        $a | Should -Match '\A[0-9a-f]{64}\z'
        (Get-Data $script:Cmp).Meta.ReportId | Should -Be $a
        (Get-Data $script:Cmp -FpSource ('c' * 64)).Meta.ReportId | Should -Not -Be $a
        (Get-Data $script:Cmp -FpTarget ('c' * 64)).Meta.ReportId | Should -Not -Be $a
    }

    It 'carries the meta an approved list needs' {
        $m = (Get-Data $script:Cmp).Meta
        $m.Tenant | Should -Be 'dev'
        $m.Source.Run | Should -Be '101'
        $m.Target.Fingerprint | Should -Be $script:FpB
        $m.ModuleVersion | Should -Match '\A\d+(\.\d+){1,3}\z'
    }
}
