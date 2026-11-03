BeforeDiscovery {
    $script:NodeFound = [bool](Get-Command node -ErrorAction SilentlyContinue)
}

BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:JsDir = Join-Path $PSScriptRoot 'driftreport'
}

Describe 'The drift report page logic (Node)' -Skip:(-not $script:NodeFound) {
    It 'passes its own tests' {
        $output = & node --test (Join-Path $script:JsDir 'logic.test.mjs') 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    }

    It 'builds a list that Read-PEApprovedList accepts' {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-js-' + [guid]::NewGuid().ToString('N') + '.json')
        & node (Join-Path $script:JsDir 'emit-list.mjs') $path
        $LASTEXITCODE | Should -Be 0
        $list = Read-PEApprovedList -Path $path
        $list.Items.Count | Should -Be 7
        ($list.Items | Where-Object Key -eq 'Sales').ExcludedProperties | Should -Be @('MailNickname')
        ($list.Items | Where-Object Key -like 'Ünï*').Key | Should -Be 'Ünïcode "quoted" key'
    }

    It 'rejects the same list when a property value is added by hand' {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-js-' + [guid]::NewGuid().ToString('N') + '.json')
        & node (Join-Path $script:JsDir 'emit-list.mjs') $path
        $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -DateKind String
        $j.Items[0] | Add-Member -NotePropertyName Value -NotePropertyValue 'secret'
        $edited = $path + '.edited.json'
        [System.IO.File]::WriteAllText($edited, ($j | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
        { Read-PEApprovedList -Path $edited } | Should -Throw 'Approved list*unknown property*'
    }
}
