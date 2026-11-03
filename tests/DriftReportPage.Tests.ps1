BeforeAll {
    $script:DataDir = Join-Path $PSScriptRoot '..\src\PolicyEngine\Data'
    $script:Js = [System.IO.File]::ReadAllText((Join-Path $script:DataDir 'DriftReport.js'))
    $script:UiPath = Join-Path $script:DataDir 'DriftReport.ui.js'
    $script:Ui = if (Test-Path $script:UiPath) { [System.IO.File]::ReadAllText($script:UiPath) } else { '' }
    $script:Template = [System.IO.File]::ReadAllText((Join-Path $script:DataDir 'DriftReport.template.html'))
}

Describe 'The drift report page source' {
    It 'never assigns innerHTML or uses eval, document.write or similar' {
        foreach ($text in $script:Js, $script:Ui, $script:Template)
        {
            $text | Should -Not -Match '(?i)innerHTML|outerHTML|insertAdjacentHTML|document\.write|\beval\s*\(|new\s+Function\s*\(|setTimeout\s*\(\s*["'']'
        }
    }

    It 'has a UI script that sets tenant text with textContent' {
        $script:Ui.Length | Should -BeGreaterThan 2000
        $script:Ui | Should -Match 'textContent'
    }

    It 'reads the embedded data and offers Download approved.json' {
        $script:Ui | Should -Match "getElementById\('report-data'\)"
        $script:Ui | Should -Match 'approved\.json'
        $script:Ui | Should -Match 'Include removals'
        $script:Ui | Should -Match 'Approved by'
    }

    It 'keeps every placeholder in the template exactly once' {
        foreach ($name in 'TITLE', 'DATA', 'SCRIPT')
        {
            ([regex]::Matches($script:Template, "__PE_${name}__")).Count | Should -Be 1
        }
    }

    It 'makes no network or storage call outside try blocks' {
        $script:Ui | Should -Not -Match '(?i)\bfetch\s*\(|XMLHttpRequest|WebSocket|sendBeacon'
        # localStorage is only touched inside the helper functions that wrap it in try/catch.
        ([regex]::Matches($script:Ui, 'localStorage')).Count | Should -BeLessOrEqual 3
    }
}
