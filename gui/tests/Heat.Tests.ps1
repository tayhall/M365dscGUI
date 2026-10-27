BeforeAll {
    $script:HeatJs = (Resolve-Path "$PSScriptRoot/../public/assets/heat.js" -ErrorAction SilentlyContinue).Path
    if (-not $script:HeatJs) { $script:HeatJs = (Join-Path $PSScriptRoot '../public/assets/heat.js') }
    $script:HeatJs = $script:HeatJs -replace '\\', '/'
    function script:Invoke-Heat([string]$Expression)
    {
        $code = "const H = require('$($script:HeatJs)'); process.stdout.write(JSON.stringify($Expression));"
        node -e $code
    }
}

Describe 'PEHeat.tone' -Skip:(-not (Get-Command node -ErrorAction SilentlyContinue)) {
    It 'is ok when nothing drifted' {
        Invoke-Heat "H.tone(0, 40, true)" | Should -Be '"ok"'
    }

    It 'steps up at 10% and 30% of managed items, inclusive' {
        Invoke-Heat "H.tone(4, 40, true)" | Should -Be '"w1"'
        Invoke-Heat "H.tone(5, 40, true)" | Should -Be '"w2"'
        Invoke-Heat "H.tone(12, 40, true)" | Should -Be '"w2"'
        Invoke-Heat "H.tone(13, 40, true)" | Should -Be '"w3"'
    }

    It 'never divides by zero when nothing is managed' {
        Invoke-Heat "H.tone(3, 0, true)" | Should -Be '"w3"'
        Invoke-Heat "H.tone(0, 0, true)" | Should -Be '"ok"'
    }

    It 'is nc when not checked, whatever the counts' {
        Invoke-Heat "H.tone(7, 40, false)" | Should -Be '"nc"'
    }
}

Describe 'PEHeat.countByWorkload' -Skip:(-not (Get-Command node -ErrorAction SilentlyContinue)) {
    It 'counts findings per listed workload, zero when none, and ignores unlisted workloads' {
        $expr = "H.countByWorkload([{workload:'Intune'},{workload:'Intune'},{workload:'Teams'},{workload:'Nope'}], ['Entra ID','Intune','Teams'])"
        Invoke-Heat $expr | Should -Be '{"Entra ID":0,"Intune":2,"Teams":1}'
    }
}
