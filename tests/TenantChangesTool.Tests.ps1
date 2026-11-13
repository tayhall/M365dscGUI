BeforeAll {
    $script:Tool = Join-Path $PSScriptRoot '..\tools\Invoke-PETenantChanges.ps1'
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures\upload'

    function New-ExportCopy
    {
        param ([string]$Fixture, [string]$Log = '')
        $folder = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-tc-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Fixtures $Fixture) -Destination (Join-Path $folder 'export.ps1')
        Set-Content -LiteralPath (Join-Path $folder 'export.log') -Value $Log -Encoding utf8
        $folder
    }
    function Invoke-Tool
    {
        param ([string]$Previous = 'entra.ps1', [string]$Latest = 'entra-plus-group.ps1', [string]$Log = '')
        $out = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-tc-out-' + [guid]::NewGuid().ToString('N'))
        $messages = & $script:Tool -Tenant 'Dev' -PreviousExportPath (New-ExportCopy $Previous $Log) -LatestExportPath (New-ExportCopy $Latest $Log) `
            -TargetTenantDomain 'contoso-dev.onmicrosoft.com' -OutputPath $out -PreviousRun '101' -LatestRun '102' `
            -PreviousName 'v8' -LatestName 'v9' -CompleteWorkload 'AAD' 6>&1 3>$null
        [pscustomobject]@{ Out = (Join-Path $out 'Dev'); Messages = @($messages | ForEach-Object { "$_" }) }
    }
}

Describe 'tools\Invoke-PETenantChanges.ps1' {
    It 'writes the revert folder and the promote configuration for one new group' {
        $r = Invoke-Tool
        Test-Path (Join-Path $r.Out 'Revert\summary.json') | Should -BeTrue
        (Get-Content (Join-Path $r.Out 'Revert\Removals.ps1') -Raw) | Should -Match 'Support'
        (Get-Content (Join-Path $r.Out 'Promote\Changes.ps1') -Raw) | Should -Match 'Support'
        Test-Path (Join-Path $r.Out 'Promote\Removals.ps1') | Should -BeFalse
    }

    It 'says No changes, writes no configuration and no MOF, and does not fail, for identical exports' {
        $r = Invoke-Tool -Previous 'entra.ps1' -Latest 'entra.ps1'
        ($r.Messages -join "`n") | Should -Match 'No changes'
        Test-Path (Join-Path $r.Out 'Promote\Changes.ps1') | Should -BeFalse
        Test-Path (Join-Path $r.Out 'Promote\Removals.ps1') | Should -BeFalse
        Test-Path (Join-Path $r.Out 'Revert\Changes.ps1') | Should -BeFalse
        @(Get-ChildItem $r.Out -Recurse -Filter *.mof) | Should -BeNullOrEmpty
    }

    It 'records the tenant, both export names and both run ids in summary.json and in the revert summary' {
        $r = Invoke-Tool
        foreach ($file in 'summary.json', 'Revert\summary.json')
        {
            $summary = Get-Content (Join-Path $r.Out $file) -Raw | ConvertFrom-Json
            $summary.Tenant | Should -Be 'Dev'
            $summary.PreviousRun | Should -Be '101'
            $summary.LatestRun | Should -Be '102'
            $summary.PreviousName | Should -Be 'v8'
            $summary.LatestName | Should -Be 'v9'
        }
        $top = Get-Content (Join-Path $r.Out 'summary.json') -Raw | ConvertFrom-Json
        $top.Revert.OpenFindings | Should -Be 1
        $top.Promote.OpenFindings | Should -Be 1
    }

    It 'prints what was compared as its first line' {
        (Invoke-Tool).Messages[0] | Should -Be 'Dev changes: v8 -> v9'
    }

    It 'never compiles the promote configuration' {
        $r = Invoke-Tool
        @(Get-ChildItem $r.Out -Recurse -Filter *.mof) | Should -BeNullOrEmpty
        Test-Path (Join-Path $r.Out 'MOF') | Should -BeFalse
        Test-Path (Join-Path $r.Out 'work-promote') | Should -BeFalse
    }

    It 'refuses an export made with another Microsoft365DSC version, with the cause and the fix' {
        { Invoke-Tool -Previous 'other-version.ps1' } | Should -Throw '*made with another Microsoft365DSC version*Take a fresh export*'
    }
}

Describe 'tools\Invoke-PETenantChanges.ps1 report' {
    BeforeAll { Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force }

    It 'writes Report.html with both run ids, the export names as labels and the tenant slug dev-changes' {
        $r = Invoke-Tool
        $html = [System.IO.File]::ReadAllText((Join-Path $r.Out 'Report.html'))
        $json = [regex]::Match($html, '(?s)<script type="application/json" id="report-data">(.*?)</script>').Groups[1].Value
        $data = $json | ConvertFrom-Json
        $data.Meta.Tenant | Should -Be 'dev-changes'
        $data.Meta.Source.Run | Should -Be '101'
        $data.Meta.Target.Run | Should -Be '102'
        $html | Should -Match 'Dev v8'
        $html | Should -Match 'Dev v9'
        Test-Path (Join-Path $r.Out 'drift-report.html') | Should -BeFalse
    }

    It 'makes a list that the approved apply for dev refuses' {
        $source = New-ExportCopy 'entra.ps1'
        $list = New-PEApprovedList -Tenant 'dev-changes' -ApprovedBy 'andrew' -ModuleVersion '2.26.1104.1' `
            -Item @(@{ Action = 'Create'; ResourceType = 'AADGroup'; Key = 'Finance'; ExcludedProperties = @() }) `
            -Source @{ Run = '101'; ExportedAt = '2026-11-03T10:00:00Z'; Fingerprint = (Get-PEExportFingerprint -Path $source) } `
            -Target @{ Run = '102'; ExportedAt = '2026-11-03T10:00:00Z'; Fingerprint = (Get-PEExportFingerprint -Path $source) }
        $listPath = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-tc-list-' + [guid]::NewGuid().ToString('N') + '.json')
        Save-PEApprovedList -List $list -Path $listPath
        { & (Join-Path $PSScriptRoot '..\tools\Invoke-PEApprovedBuild.ps1') -ListPath $listPath -SourceExportPath $source -TargetExportPath $source `
            -TargetTenantDomain 'contoso-dev.onmicrosoft.com' -OutputPath (Join-Path ([System.IO.Path]::GetTempPath()) 'pe-tc-never') -NoCompile } |
            Should -Throw "*tenant 'dev-changes'*"
    }
}

Describe 'components an export could not read are not changes' {
    BeforeAll {
        # The same failed component in both exports, as the real export log writes it.
        $script:FailedLog = "[1/2] Extracting [AADFilteringPolicy] using {CertificateThumbprint}...`u{274C}`n    An error occurred while exporting resource {AADFilteringPolicy}: Forbidden: Authentication failed with status code 403 (Forbidden).`n"
    }

    It 'counts nothing and says No changes when only the unreadable component differs from nothing, and lists it as not compared' {
        $r = Invoke-Tool -Previous 'entra.ps1' -Latest 'entra.ps1' -Log $script:FailedLog
        $summary = Get-Content (Join-Path $r.Out 'summary.json') -Raw | ConvertFrom-Json
        $summary.Revert.OpenFindings | Should -Be 0
        $summary.Promote.OpenFindings | Should -Be 0
        $summary.Revert.NotCompared | Should -BeGreaterThan 0
        ($r.Messages -join "`n") | Should -Match 'No changes'
        ($r.Messages -join "`n") | Should -Match 'not compared'
        Test-Path (Join-Path $r.Out 'Promote\Changes.ps1') | Should -BeFalse
    }

    It 'counts only the new group when a component is unreadable in both exports' {
        $r = Invoke-Tool -Previous 'entra.ps1' -Latest 'entra-plus-group.ps1' -Log $script:FailedLog
        $summary = Get-Content (Join-Path $r.Out 'summary.json') -Raw | ConvertFrom-Json
        $summary.Revert.OpenFindings | Should -Be 1
        $summary.Revert.ByKind | Should -Be 'TargetOnly=1'
        $summary.Revert.NotCompared | Should -BeGreaterThan 0
        $summary.Promote.OpenFindings | Should -Be 1
        ($r.Messages -join "`n") | Should -Match 'Changes: 1 open \(TargetOnly=1\)'
    }
}
