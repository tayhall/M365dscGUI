BeforeAll {
    $script:Tool = Join-Path $PSScriptRoot '..\tools\Invoke-PEPipelineCompare.ps1'
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures\upload'

    function New-ExportCopy
    {
        param ([string]$Fixture)
        $folder = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-noise-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Fixtures $Fixture) -Destination (Join-Path $folder 'export.ps1')
        Set-Content -LiteralPath (Join-Path $folder 'export.log') -Value '' -Encoding utf8
        $folder
    }
    # Both sides are the same tenant: the previous export is "expected" (source), the latest is the "target".
    function Invoke-SameTenantCompare
    {
        param ([string]$Source, [string]$Target)
        $out = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-noise-out-' + [guid]::NewGuid().ToString('N'))
        & $script:Tool -SourceExportPath (New-ExportCopy $Source) -TargetExportPath (New-ExportCopy $Target) `
            -TargetTenantDomain 'contoso-dev.onmicrosoft.com' -OutputPath $out -CompleteWorkload 'AAD' 6>$null 3>$null | Out-Null
        [pscustomobject]@{
            Out     = $out
            Summary = Get-Content (Join-Path $out 'summary.json') -Raw | ConvertFrom-Json
        }
    }
}

Describe 'same-tenant compare of two exports' {
    It 'finds nothing when the two exports are the same' {
        $r = Invoke-SameTenantCompare 'entra.ps1' 'entra.ps1'
        $r.Summary.OpenFindings | Should -Be 0
        Test-Path (Join-Path $r.Out 'Changes.ps1') | Should -BeFalse
        Test-Path (Join-Path $r.Out 'Removals.ps1') | Should -BeFalse
    }

    It 'finds nothing when the exports differ only in volatile content (order, comments, blank lines, trailing spaces)' {
        $r = Invoke-SameTenantCompare 'entra.ps1' 'entra-noisy.ps1'
        $r.Summary.OpenFindings | Should -Be 0
        Test-Path (Join-Path $r.Out 'Changes.ps1') | Should -BeFalse
        Test-Path (Join-Path $r.Out 'Removals.ps1') | Should -BeFalse
    }

    It 'finds exactly the one new group, as a Remove, in the revert direction (previous expected, latest target)' {
        $r = Invoke-SameTenantCompare 'entra.ps1' 'entra-plus-group.ps1'
        $r.Summary.OpenFindings | Should -Be 1
        $r.Summary.ByKind | Should -Be 'TargetOnly=1'
        (Get-Content (Join-Path $r.Out 'Removals.ps1') -Raw) | Should -Match 'Support'
        Test-Path (Join-Path $r.Out 'Changes.ps1') | Should -BeFalse
    }

    It 'finds exactly the one new group, as a Create, in the promote direction (latest expected, previous target)' {
        $r = Invoke-SameTenantCompare 'entra-plus-group.ps1' 'entra.ps1'
        $r.Summary.OpenFindings | Should -Be 1
        $r.Summary.ByKind | Should -Be 'Missing=1'
        (Get-Content (Join-Path $r.Out 'Changes.ps1') -Raw) | Should -Match 'Support'
        Test-Path (Join-Path $r.Out 'Removals.ps1') | Should -BeFalse
    }
}
