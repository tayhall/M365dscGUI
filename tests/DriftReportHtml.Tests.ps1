BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force

    function New-TestData
    {
        param ([string]$Key = 'Finance')
        [pscustomobject]@{
            Meta   = [pscustomobject]@{
                Tenant = 'dev'; ModuleVersion = '2.26.1021.1'; GeneratedUtc = '2026-11-03T11:00:00Z'; ReportId = ('c' * 64)
                Source = [pscustomobject]@{ Run = '101'; ExportedAt = '2026-11-03T10:00:00Z'; Fingerprint = ('a' * 64) }
                Target = [pscustomobject]@{ Run = '102'; ExportedAt = '2026-11-03T10:05:00Z'; Fingerprint = ('b' * 64) }
            }
            Totals = [pscustomobject]@{ Total = 2; Matching = 1; Create = 1; Update = 0; Remove = 0; CannotApprove = 0 }
            Items  = @([pscustomobject]@{ Id = "Create|AADGroup|$Key"; Action = 'Create'; Kind = 'Missing'; ResourceType = 'AADGroup'; Key = $Key
                    Workload = 'Entra ID'; Approvable = $true; Reason = ''; Differences = @() })
        }
    }
    function New-OutPath { Join-Path ([System.IO.Path]::GetTempPath()) ('pe-html-' + [guid]::NewGuid().ToString('N') + '.html') }
}

Describe 'New-PEDriftReportHtml' {
    It 'writes a single file with no external references' {
        $path = New-PEDriftReportHtml -Data (New-TestData) -Path (New-OutPath)
        $html = [System.IO.File]::ReadAllText($path)
        $html | Should -Not -Match '(?i)(src|href)\s*=\s*["'']?\s*(https?:)?//'
        $html | Should -Not -Match '(?i)<link\b'
        $html | Should -Not -Match '(?i)@import'
        $html | Should -Not -Match '(?i)url\(\s*["'']?https?:'
        $html | Should -Match '<script type="application/json" id="report-data">'
        $html | Should -Not -Match '__PE_'
    }

    It 'writes UTF-8 without a BOM and LF line endings' {
        $path = New-PEDriftReportHtml -Data (New-TestData) -Path (New-OutPath)
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes[0] | Should -Not -Be 0xEF
        [System.Text.Encoding]::UTF8.GetString($bytes) | Should -Not -Match "`r"
    }

    It 'embeds the data and nothing breaks the script block' {
        $evil = '</script><img src=x onerror=alert(1)><!-- &'
        $path = New-PEDriftReportHtml -Data (New-TestData -Key $evil) -Path (New-OutPath)
        $html = [System.IO.File]::ReadAllText($path)
        ([regex]::Matches($html, '(?i)<script\b')).Count | Should -Be 2
        ([regex]::Matches($html, '(?i)</script>')).Count | Should -Be 2
        $html | Should -Not -Match '(?i)<img src=x'
        $json = [regex]::Match($html, '(?s)<script type="application/json" id="report-data">(.*?)</script>').Groups[1].Value
        ($json | ConvertFrom-Json).Items[0].Key | Should -Be $evil
    }

    It 'escapes U+2028 and U+2029 in the data' {
        $path = New-PEDriftReportHtml -Data (New-TestData -Key ("a" + [char]0x2028 + "b" + [char]0x2029)) -Path (New-OutPath)
        $html = [System.IO.File]::ReadAllText($path)
        $html.Contains([string][char]0x2028) | Should -BeFalse
        $html.Contains([string][char]0x2029) | Should -BeFalse
    }

    It 'puts the title in the page, encoded' {
        $path = New-PEDriftReportHtml -Data (New-TestData) -Path (New-OutPath) -Title 'A <b>& "C"'
        $html = [System.IO.File]::ReadAllText($path)
        $html | Should -Match '<title>A &lt;b&gt;&amp; &quot;C&quot;</title>'
    }

    It 'does not overwrite' {
        $path = New-PEDriftReportHtml -Data (New-TestData) -Path (New-OutPath)
        { New-PEDriftReportHtml -Data (New-TestData) -Path $path } | Should -Throw '*already exists*'
    }

    It 'refuses a Data object without Items' {
        { New-PEDriftReportHtml -Data ([pscustomobject]@{ Meta = 1; Totals = 1 }) -Path (New-OutPath) } | Should -Throw '*Items*'
    }
}
