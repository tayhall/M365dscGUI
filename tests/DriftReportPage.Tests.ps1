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

    It 'shows what was not compared apart from drift' {
        $script:Ui | Should -Match 'Not compared'
        $script:Ui | Should -Match 'NotCompared'
    }

    It 'takes the names of the two sides from the report data, not from fixed text' {
        $script:Ui | Should -Match 'SourceLabel'
        $script:Ui | Should -Match 'TargetLabel'
        $script:Ui | Should -Not -Match 'PreProd to Dev'
        $script:Ui | Should -Not -Match "'Dev now'"
    }

    It 'has an overview, a review by workload and a single-resource view, reached by the address after #' {
        foreach ($word in 'Overview', 'Review', 'hashchange', 'workloadTree', 'orderProps', 'routeToHash', 'parseRoute')
        {
            $script:Ui | Should -Match $word -Because "the page must use $word"
        }
        $script:Ui | Should -Match 'All properties'
        $script:Ui | Should -Match 'Workload'
    }

    It 'lets every level of the tree be collapsed and selected' {
        $script:Ui | Should -Match 'Expand all'
        $script:Ui | Should -Match 'Collapse all'
        $script:Ui | Should -Match 'selectAll'
        $script:Ui | Should -Match 'countSelected'
    }
}

