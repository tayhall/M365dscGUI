BeforeAll {
    $script:Tool = Join-Path $PSScriptRoot '..\tools\Invoke-PETenantChanges.ps1'
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures\upload'

    function New-ExportCopy
    {
        param ([string]$Fixture)
        $folder = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-tc-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Fixtures $Fixture) -Destination (Join-Path $folder 'export.ps1')
        Set-Content -LiteralPath (Join-Path $folder 'export.log') -Value '' -Encoding utf8
        $folder
    }
    function Invoke-Tool
    {
        param ([string]$Previous = 'entra.ps1', [string]$Latest = 'entra-plus-group.ps1')
        $out = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-tc-out-' + [guid]::NewGuid().ToString('N'))
        $messages = & $script:Tool -Tenant 'Dev' -PreviousExportPath (New-ExportCopy $Previous) -LatestExportPath (New-ExportCopy $Latest) `
            -TargetTenantDomain 'contoso-dev.onmicrosoft.com' -OutputPath $out -PreviousRun '101' -LatestRun '102' `
            -PreviousName 'v8' -LatestName 'v9' -CompleteWorkload 'AAD' 6>&1 3>$null
        [pscustomobject]@{ Out = $out; Messages = @($messages | ForEach-Object { "$_" }) }
    }
}

Describe 'tools\Invoke-PETenantChanges.ps1' {
    It 'writes the revert folder and the promote configuration for one new group' {
        $r = Invoke-Tool
        Test-Path (Join-Path $r.Out 'Revert\summary.json') | Should -BeTrue
        (Get-Content (Join-Path $r.Out 'Revert\Removals.ps1') -Raw) | Should -Match 'Support'
        (Get-Content (Join-Path $r.Out 'DevChanges.ps1') -Raw) | Should -Match 'Support'
        Test-Path (Join-Path $r.Out 'DevRemovals.ps1') | Should -BeFalse
    }

    It 'says No changes, writes no configuration and no MOF, and does not fail, for identical exports' {
        $r = Invoke-Tool -Previous 'entra.ps1' -Latest 'entra.ps1'
        ($r.Messages -join "`n") | Should -Match 'No changes'
        Test-Path (Join-Path $r.Out 'DevChanges.ps1') | Should -BeFalse
        Test-Path (Join-Path $r.Out 'DevRemovals.ps1') | Should -BeFalse
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
