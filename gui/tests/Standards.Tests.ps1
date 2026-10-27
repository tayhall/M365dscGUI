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
        Invoke-Model "S.headlineText($($script:H))" | Should -Be '"Compared 87 of 133 settings"'
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

Describe 'PEStandards selection list' -Skip:(-not (Get-Command node -ErrorAction SilentlyContinue)) {
    BeforeAll {
        $script:Entries = @"
[
  {t:'master',standard:'asd',itemId:'A~1',action:'Adopt'},
  {t:'master',standard:'asd',itemId:'A~2',action:'Adopt'},
  {t:'master',standard:'asd',itemId:'B~1',action:'AcceptRisk',approvedBy:'cio',why:'x'},
  {t:'master',standard:'asd',itemId:'B~2',action:'AcceptRisk',approvedBy:'cio',why:'y',properties:['P1']},
  {t:'dev',standard:'asd',itemId:'A~1',action:'Adopt'}
]
"@
    }

    It 'gives a standards entry and a Drift review entry for the same item different identities' {
        Invoke-Model "S.queueIdentity({t:'master',itemId:'A~1'}) !== S.queueIdentity({t:'master',standard:'asd',itemId:'A~1'})" | Should -Be 'true'
        Invoke-Model "S.queueIdentity({t:'master',standard:'asd',itemId:'A~1'}) !== S.queueIdentity({t:'master',standard:'nist',itemId:'A~1'})" | Should -Be 'true'
        Invoke-Model "S.queueIdentity({t:'master',standard:'asd',itemId:'A~1'}) === S.queueIdentity({t:'master',standard:'asd',itemId:'A~1',action:'Adopt'})" | Should -Be 'true'
    }

    It 'groups entries by action, tenant and standard, keeping the order they were picked in' {
        Invoke-Model "S.groupStandardEntries($($script:Entries)).map(g => [g.action, g.tenantId, g.standard, g.items.length])" |
            Should -Be '[["Adopt","master","asd",2],["AcceptRisk","master","asd",2],["Adopt","dev","asd",1]]'
        Invoke-Model "S.groupStandardEntries($($script:Entries))[0].items.map(i => i.itemId)" | Should -Be '["A~1","A~2"]'
        Invoke-Model "S.groupStandardEntries([])" | Should -Be '[]'
    }

    It 'leaves entries of the Drift review out of the standards groups' {
        Invoke-Model "S.groupStandardEntries([{t:'master',itemId:'A~1',action:'Promote'}])" | Should -Be '[]'
    }

    It 'sends who approved and why with each Accept risk item, and the properties only for a partial selection' {
        Invoke-Model "S.groupStandardEntries($($script:Entries))[1].items" |
            Should -Be '[{"itemId":"B~1","approvedBy":"cio","why":"x"},{"itemId":"B~2","approvedBy":"cio","why":"y","properties":["P1"]}]'
        Invoke-Model "S.groupStandardEntries($($script:Entries))[0].items[0]" | Should -Be '{"itemId":"A~1"}'
    }
}

Describe 'PEStandards Accept risk dialog' -Skip:(-not (Get-Command node -ErrorAction SilentlyContinue)) {
    It 'asks for who approved it and why, ignoring blanks and spaces' {
        Invoke-Model "S.riskDialogProblem({approvedBy:'',why:'x',differing:['P']})" | Should -Be '"Say who approved it."'
        Invoke-Model "S.riskDialogProblem({approvedBy:'   ',why:'x',differing:['P']})" | Should -Be '"Say who approved it."'
        Invoke-Model "S.riskDialogProblem({approvedBy:'cio',why:'  ',differing:['P']})" | Should -Be '"Say why."'
        Invoke-Model "S.riskDialogProblem({approvedBy:'cio',why:'ok',differing:['P']})" | Should -Be '""'
    }

    It 'needs at least one setting ticked when the item has several that differ' {
        Invoke-Model "S.riskDialogProblem({approvedBy:'a',why:'b',differing:['P','Q'],ticked:[]})" | Should -Be '"Tick at least one setting."'
        Invoke-Model "S.riskDialogProblem({approvedBy:'a',why:'b',differing:['P','Q'],ticked:['Q']})" | Should -Be '""'
        Invoke-Model "S.riskDialogProblem({approvedBy:'a',why:'b',differing:[],ticked:[]})" | Should -Be '""'
    }

    It 'accepts the whole item when every setting is ticked or only one differs, and only the ticked ones otherwise' {
        Invoke-Model "S.riskProperties({differing:['P','Q'],ticked:['P','Q']})" | Should -Be '[]'
        Invoke-Model "S.riskProperties({differing:['P'],ticked:['P']})" | Should -Be '[]'
        Invoke-Model "S.riskProperties({differing:['P','Q'],ticked:['Q']})" | Should -Be '["Q"]'
        Invoke-Model "S.riskProperties({differing:['P','Q','R'],ticked:['R','P']})" | Should -Be '["R","P"]'
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
