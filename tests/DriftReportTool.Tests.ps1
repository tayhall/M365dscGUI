BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Tool = Join-Path $PSScriptRoot '..\tools\New-PEDriftReport.ps1'
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures\upload'

    function New-ExportCopy
    {
        param ([string]$Fixture)
        $folder = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-tool-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Fixtures $Fixture) -Destination (Join-Path $folder 'export.ps1')
        Set-Content -LiteralPath (Join-Path $folder 'export.log') -Value '' -Encoding utf8
        $folder
    }
    function Invoke-Tool
    {
        param ([string]$SourceRun = '101', [string]$TargetRun = '102', [string]$Out)
        if (-not $Out) { $Out = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-tool-out-' + [guid]::NewGuid().ToString('N')) }
        $messages = & $script:Tool -SourceExportPath (New-ExportCopy 'entra.ps1') -TargetExportPath (New-ExportCopy 'entra-drift.ps1') `
            -TargetTenantDomain 'contoso-dev.onmicrosoft.com' -OutputPath $Out -SourceRun $SourceRun -TargetRun $TargetRun -CompleteWorkload 'AAD' 6>&1 3>$null
        [pscustomobject]@{ Out = $Out; Messages = @($messages | ForEach-Object { "$_" }) }
    }
}

Describe 'tools\New-PEDriftReport.ps1' {
    It 'writes drift-report.html and prints the counts' {
        $r = Invoke-Tool
        $html = Join-Path $r.Out 'drift-report.html'
        Test-Path $html | Should -BeTrue
        ($r.Messages -join "`n") | Should -Match 'Drift report: 3 items, 3 approvable'
    }

    It 'embeds the same three actionable items the comparison tool finds, with the run ids and fingerprints' {
        $r = Invoke-Tool
        $html = [System.IO.File]::ReadAllText((Join-Path $r.Out 'drift-report.html'))
        $json = [regex]::Match($html, '(?s)<script type="application/json" id="report-data">(.*?)</script>').Groups[1].Value
        $data = $json | ConvertFrom-Json
        @($data.Items.Id | Sort-Object) | Should -Be @('Create|AADGroup|Finance', 'Remove|AADGroup|Marketing', 'Update|AADGroup|Sales')
        $data.Meta.Source.Run | Should -Be '101'
        $data.Meta.Target.Run | Should -Be '102'
        $data.Meta.Source.Fingerprint | Should -Match '\A[0-9a-f]{64}\z'
        $data.Meta.Source.Fingerprint | Should -Not -Be $data.Meta.Target.Fingerprint
        $data.Meta.Tenant | Should -Be 'dev'
    }

    It 'leaves no work folder behind' {
        $r = Invoke-Tool
        Get-ChildItem -LiteralPath $r.Out | ForEach-Object Name | Should -Be @('drift-report.html')
    }

    It 'refuses a non-numeric run id' {
        { Invoke-Tool -SourceRun '12a' } | Should -Throw
        { Invoke-Tool -TargetRun 'latest' } | Should -Throw
    }

    It 'is called by the Compare pipeline script only when both run ids are numeric' {
        $script = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\pipelines\scripts\Invoke-PipelineCompare.ps1') -Raw
        $script | Should -Match 'New-PEDriftReport\.ps1'
        $script.Contains('-match ''\A\d{1,12}\z''') | Should -BeTrue
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$null, [ref]$errors)
        $errors.Count | Should -Be 0
    }

    It 'does not fail the Compare pipeline when the optional report cannot be built' {
        $script = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\pipelines\scripts\Invoke-PipelineCompare.ps1') -Raw
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$null, [ref]$null)
        $try = $ast.FindAll({ param ($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $true) |
            Where-Object { $_.Body.Extent.Text -match 'New-PEDriftReport\.ps1' }
        @($try).Count | Should -Be 1
        $try[0].CatchClauses[0].Body.Extent.Text | Should -Match 'task\.logissue type=warning'
    }

    It 'uses the labels and tenant it is given in the page and the list' {
        $out = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-tool-out-' + [guid]::NewGuid().ToString('N'))
        & $script:Tool -SourceExportPath (New-ExportCopy 'entra.ps1') -TargetExportPath (New-ExportCopy 'entra-drift.ps1') `
            -TargetTenantDomain 'contoso-dev.onmicrosoft.com' -OutputPath $out -SourceRun 1 -TargetRun 2 -CompleteWorkload 'AAD' `
            -SourceLabel 'master' -TargetLabel 'contoso' -Tenant 'contoso' 6>&1 3>$null | Out-Null
        $html = [System.IO.File]::ReadAllText((Join-Path $out 'drift-report.html'))
        $html | Should -Match '<title>Drift report: master to contoso</title>'
        $data = [regex]::Match($html, '(?s)<script type="application/json" id="report-data">(.*?)</script>').Groups[1].Value | ConvertFrom-Json
        $data.Meta.Tenant | Should -Be 'contoso'
        $data.Meta.SourceLabel | Should -Be 'master'
    }

    It 'refuses a tenant that is not a slug' {
        { & $script:Tool -SourceExportPath x -TargetExportPath y -TargetTenantDomain z -OutputPath o -SourceRun 1 -TargetRun 2 -Tenant 'Dev Tenant' } | Should -Throw
    }
}

