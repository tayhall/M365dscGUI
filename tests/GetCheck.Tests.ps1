BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force

    function New-TestCheck
    {
        param ([string]$Root, [string]$Id, [string]$Kind)
        $dir = Join-Path $Root "checks\$Id"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $doc = [ordered]@{
            CheckId  = $Id
            Kind     = $Kind
            Findings = @([ordered]@{ Kind = 'Missing'; ResourceType = 'AADGroup'; Key = "k-$Id" })
            State    = [ordered]@{ Records = @(); NotChecked = @(); Meta = [ordered]@{ TenantId = 't'; ExportedAt = '2026-10-22T08:00:00Z' } }
        }
        $doc | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $dir 'result.json') -Encoding utf8
    }
}

Describe 'Get-PECheck' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-getcheck-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Temp | Out-Null
        New-TestCheck -Root $script:Temp -Id '20261020-010000' -Kind 'Full'
        New-TestCheck -Root $script:Temp -Id '20261021-010000' -Kind 'Full'
        New-TestCheck -Root $script:Temp -Id '20261022-010000' -Kind 'Scan'
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'returns the saved document (Findings, State with Meta) by CheckId' {
        $check = Get-PECheck -CheckId '20261021-010000' -DataRoot $script:Temp
        $check.CheckId | Should -Be '20261021-010000'
        $check.Findings[0].Key | Should -Be 'k-20261021-010000'
        $check.State.Meta.TenantId | Should -Be 't'
    }

    It 'throws a clear error for a missing check' {
        { Get-PECheck -CheckId '20200101-000000' -DataRoot $script:Temp } | Should -Throw "*check '20200101-000000' not found*"
    }

    It 'rejects a CheckId that is not a timestamp (no path traversal)' {
        { Get-PECheck -CheckId '..\..\x' -DataRoot $script:Temp } | Should -Throw
    }

    It '-Latest returns the newest check of any kind' {
        (Get-PECheck -Latest -DataRoot $script:Temp).CheckId | Should -Be '20261022-010000'
    }

    It '-Latest -Kind Full never returns a Scan' {
        (Get-PECheck -Latest -Kind Full -DataRoot $script:Temp).CheckId | Should -Be '20261021-010000'
    }

    It '-Latest -Kind Scan returns the newest Scan' {
        (Get-PECheck -Latest -Kind Scan -DataRoot $script:Temp).CheckId | Should -Be '20261022-010000'
    }

    It '-CheckId with a different -Kind throws instead of returning the wrong kind' {
        { Get-PECheck -CheckId '20261022-010000' -Kind Full -DataRoot $script:Temp } | Should -Throw '*Scan*not Full*'
    }

    It '-Latest throws when no check of that kind exists' {
        Remove-Item (Join-Path $script:Temp 'checks\20261020-010000'), (Join-Path $script:Temp 'checks\20261021-010000') -Recurse
        { Get-PECheck -Latest -Kind Full -DataRoot $script:Temp } | Should -Throw '*No Full check found*'
    }

    It '-Latest throws when there is no checks folder' {
        { Get-PECheck -Latest -DataRoot (Join-Path $script:Temp 'empty') } | Should -Throw '*No check found*'
    }

    It 'skips folders without a result.json when looking for the latest' {
        New-Item -ItemType Directory -Path (Join-Path $script:Temp 'checks\20261023-010000') | Out-Null
        (Get-PECheck -Latest -DataRoot $script:Temp).CheckId | Should -Be '20261022-010000'
    }
}
