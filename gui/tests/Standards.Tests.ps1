BeforeAll {
    $script:ModelJs = (Resolve-Path "$PSScriptRoot/../public/assets/standards-model.js" -ErrorAction SilentlyContinue).Path
    if (-not $script:ModelJs) { $script:ModelJs = (Join-Path $PSScriptRoot '../public/assets/standards-model.js') }
    $script:ModelJs = $script:ModelJs -replace '\\', '/'
    function script:Invoke-Model([string]$Expression)
    {
        $code = "const S = require('$($script:ModelJs)'); process.stdout.write(JSON.stringify($Expression));"
        node -e $code
    }
    $script:Rows = "[{status:'differs'},{status:'missing'},{status:'lookAgain'},{status:'accepted'},{status:'accepted'}]"
}

Describe 'PEStandards rows' -Skip:(-not (Get-Command node -ErrorAction SilentlyContinue)) {
    It 'statusOf keeps a known status and treats anything else as a difference' {
        Invoke-Model "S.statusOf({status:'accepted'})" | Should -Be '"accepted"'
        Invoke-Model "S.statusOf({status:'lookAgain'})" | Should -Be '"lookAgain"'
        Invoke-Model "S.statusOf({status:'surprise'})" | Should -Be '"differs"'
        Invoke-Model "S.statusOf({})" | Should -Be '"differs"'
    }

    It 'puts differing, missing and look-again rows in decide, accepted rows only in accepted, and every row in all' {
        Invoke-Model "S.filterRows($($script:Rows), 'decide').map(r => r.status)" | Should -Be '["differs","missing","lookAgain"]'
        Invoke-Model "S.filterRows($($script:Rows), 'accepted').map(r => r.status)" | Should -Be '["accepted","accepted"]'
        Invoke-Model "S.filterRows($($script:Rows), 'all').length" | Should -Be '5'
        Invoke-Model "S.filterRows($($script:Rows), 'nonsense').length" | Should -Be '3'
    }

    It 'counts each filter' {
        Invoke-Model "S.filterCounts($($script:Rows))" | Should -Be '{"decide":3,"accepted":2,"all":5}'
        Invoke-Model "S.filterCounts([])" | Should -Be '{"decide":0,"accepted":0,"all":0}'
    }
}

Describe 'PEStandards headline' -Skip:(-not (Get-Command node -ErrorAction SilentlyContinue)) {
    BeforeAll { $script:H = '{total:133,covered:91,checked:87,match:68,differ:13,accepted:6,lookAgain:1,notReadable:4,notCovered:42}' }

    It 'writes the headline and the sub line in the words of the mock-up' {
        Invoke-Model "S.headlineText($($script:H))" | Should -Be '"Checked 87 of 133 settings"'
        Invoke-Model "S.subText($($script:H))" | Should -Be '"68 match, 13 differ, 6 are accepted risks"'
        Invoke-Model "S.subText({match:1,differ:0,accepted:1})" | Should -Be '"1 match, 0 differ, 1 is an accepted risk"'
    }

    It 'splits the bar into match, differ, accepted, not readable and not covered, as percents of the total' {
        Invoke-Model "S.barSegments($($script:H)).map(s => [s.key, s.count, s.percent])" |
            Should -Be '[["match",68,51.1],["differ",13,9.8],["accepted",6,4.5],["notReadable",4,3],["notCovered",42,31.6]]'
    }

    It 'adds up to the whole bar and keeps not covered and not readable out of match' {
        Invoke-Model "S.barSegments($($script:H)).reduce((n, s) => n + s.percent, 0).toFixed(1)" | Should -Be '"100.0"'
        Invoke-Model "S.barSegments($($script:H)).find(s => s.key === 'match').count" | Should -Be '68'
    }

    It 'leaves out a segment with nothing in it, and has no bar for an empty standard' {
        Invoke-Model "S.barSegments({total:10,match:10,differ:0,accepted:0,notReadable:0,notCovered:0}).map(s => s.key)" | Should -Be '["match"]'
        Invoke-Model "S.barSegments({total:0,match:0,differ:0,accepted:0,notReadable:0,notCovered:0})" | Should -Be '[]'
    }
}

Describe 'PEStandards words and values' -Skip:(-not (Get-Command node -ErrorAction SilentlyContinue)) {
    It 'labels the reasons a setting is not covered' {
        Invoke-Model "S.reasonLabel('Placeholder')" | Should -Be '"Placeholder"'
        Invoke-Model "S.reasonLabel('UnknownProperty')" | Should -Be '"Unknown property"'
        Invoke-Model "S.reasonLabel('Unkeyed')" | Should -Be '"No key"'
        Invoke-Model "S.reasonLabel('Other')" | Should -Be '"Other"'
    }

    It 'shows a value as text' {
        Invoke-Model "S.valueText(['AU','NZ'])" | Should -Be '"AU, NZ"'
        Invoke-Model "S.valueText(true)" | Should -Be '"True"'
        Invoke-Model "S.valueText(false)" | Should -Be '"False"'
        Invoke-Model "S.valueText(null)" | Should -Be '"—"'
        Invoke-Model "S.valueText(2)" | Should -Be '"2"'
        Invoke-Model "S.valueText({a:1})" | Should -Be '"{\"a\":1}"'
        Invoke-Model "S.valueText([])" | Should -Be '"—"'
    }
}

Describe 'The server serves the Standards pages and routes' {
    BeforeAll { $script:Server = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\server.ps1') -Raw }

    It 'registers the standards API routes' {
        $script:Server | Should -Match "'/api/standards'"
        $script:Server | Should -Match "'/api/standards/:name/coverage'"
        $script:Server | Should -Match "'/api/tenants/:tenantId/standards/:name'"
    }

    It 'serves the app shell for each standards page, so a bookmark or a reload works' {
        $script:Server | Should -Match "'/standards'"
        $script:Server | Should -Match "'/standards/:name'"
        $script:Server | Should -Match "'/standards/:name/not-covered'"
    }
}
