BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
}

Describe 'Decisions store' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-' + [guid]::NewGuid())
    }

    AfterEach {
        if (Test-Path $script:Temp)
        {
            Remove-Item $script:Temp -Recurse -Force
        }
    }

    It 'Set-PEDecision persists and Get-PEDecision returns it' {
        $d = Set-PEDecision -Kind Unmanaged -ResourceType 'AADUser' -Key 'a@b.com' -Reason 'service acct' -DataRoot $script:Temp
        $d.Kind | Should -Be 'Unmanaged'
        Test-Path (Join-Path $script:Temp 'decisions.json') | Should -BeTrue
        $got = @(Get-PEDecision -DataRoot $script:Temp)
        $got.Count | Should -Be 1
        $got[0].ResourceType | Should -Be 'AADUser'
        $got[0].Key | Should -Be 'a@b.com'
        $got[0].Reason | Should -Be 'service acct'
    }

    It 'Get-PEDecision returns an empty array when nothing is stored' {
        $got = @(Get-PEDecision -DataRoot $script:Temp)
        $got.Count | Should -Be 0
    }

    It 'Get-PEDecision works with a single stored decision' {
        Set-PEDecision -Kind Remove -ResourceType 'AADGroup' -Key 'g1' -Reason 'obsolete' -DataRoot $script:Temp | Out-Null
        $got = @(Get-PEDecision -DataRoot $script:Temp)
        $got.Count | Should -Be 1
        $remove = @(Get-PEDecision -Kind Remove -DataRoot $script:Temp)
        $remove.Count | Should -Be 1
        $noise = @(Get-PEDecision -Kind Noise -DataRoot $script:Temp)
        $noise.Count | Should -Be 0
    }

    It 'Unmanaged and Remove ignore a supplied Property' {
        $d = Set-PEDecision -Kind Unmanaged -ResourceType 'T' -Key 'k' -Property 'P' -Reason 'r' -DataRoot $script:Temp
        $d.Property | Should -BeNullOrEmpty
        Set-PEDecision -Kind Unmanaged -ResourceType 'T' -Key 'k' -Property 'Q' -Reason 'r2' -DataRoot $script:Temp | Out-Null
        $got = @(Get-PEDecision -DataRoot $script:Temp)
        $got.Count | Should -Be 1
        $got[0].Property | Should -BeNullOrEmpty
    }

    It 'Whitespace-only Key or Property throws' {
        { Set-PEDecision -Kind Unmanaged -ResourceType 'T' -Key '  ' -Reason 'r' -DataRoot $script:Temp } | Should -Throw
        { Set-PEDecision -Kind Noise -ResourceType 'T' -Property '  ' -Value 1 -Reason 'r' -DataRoot $script:Temp } | Should -Throw
    }

    It 'Setting the same decision twice does not duplicate it' {
        Set-PEDecision -Kind Noise -ResourceType 'AADPolicy' -Property 'X' -Value 'a' -Reason 'r1' -DataRoot $script:Temp | Out-Null
        Set-PEDecision -Kind Noise -ResourceType 'aadpolicy' -Property 'x' -Value 'b' -Reason 'r2' -DataRoot $script:Temp | Out-Null
        $got = @(Get-PEDecision -DataRoot $script:Temp)
        $got.Count | Should -Be 1
        $got[0].Value | Should -Be 'b'
        $got[0].Reason | Should -Be 'r2'
    }

    It 'Noise without Property or Value throws' {
        { Set-PEDecision -Kind Noise -ResourceType 'T' -Value 1 -Reason 'r' -DataRoot $script:Temp } | Should -Throw
        { Set-PEDecision -Kind Noise -ResourceType 'T' -Property 'P' -Reason 'r' -DataRoot $script:Temp } | Should -Throw
    }

    It 'Noise accepts a Value of $false or 0' {
        Set-PEDecision -Kind Noise -ResourceType 'T' -Property 'P1' -Value $false -Reason 'r' -DataRoot $script:Temp | Out-Null
        Set-PEDecision -Kind Noise -ResourceType 'T' -Property 'P2' -Value 0 -Reason 'r' -DataRoot $script:Temp | Out-Null
        $got = @(Get-PEDecision -Kind Noise -DataRoot $script:Temp)
        $got.Count | Should -Be 2
        ($got | Where-Object Property -eq 'P1').Value | Should -BeFalse
        ($got | Where-Object Property -eq 'P2').Value | Should -Be 0
    }

    It 'Unmanaged without Key throws' {
        { Set-PEDecision -Kind Unmanaged -ResourceType 'T' -Reason 'r' -DataRoot $script:Temp } | Should -Throw
        { Set-PEDecision -Kind Remove -ResourceType 'T' -Reason 'r' -DataRoot $script:Temp } | Should -Throw
    }

    It 'Reason is mandatory' {
        { Set-PEDecision -Kind Unmanaged -ResourceType 'T' -Key 'k' -Reason '' -DataRoot $script:Temp } | Should -Throw
    }

    It 'Remove-PEDecision deletes only the matching decision' {
        Set-PEDecision -Kind Unmanaged -ResourceType 'T' -Key 'k1' -Reason 'r' -DataRoot $script:Temp | Out-Null
        Set-PEDecision -Kind Unmanaged -ResourceType 'T' -Key 'k2' -Reason 'r' -DataRoot $script:Temp | Out-Null
        Set-PEDecision -Kind Remove -ResourceType 'T' -Key 'k1' -Reason 'r' -DataRoot $script:Temp | Out-Null
        Remove-PEDecision -Kind Unmanaged -ResourceType 't' -Key 'K1' -DataRoot $script:Temp
        $got = @(Get-PEDecision -DataRoot $script:Temp)
        $got.Count | Should -Be 2
        ($got | Where-Object { $_.Kind -eq 'Unmanaged' }).Key | Should -Be 'k2'
        ($got | Where-Object { $_.Kind -eq 'Remove' }).Key | Should -Be 'k1'
    }

    It 'Remove-PEDecision on a missing decision does not throw' {
        { Remove-PEDecision -Kind Unmanaged -ResourceType 'T' -Key 'nope' -DataRoot $script:Temp } | Should -Not -Throw
    }

    It 'every decision records a timestamp and reason' {
        Set-PEDecision -Kind Unmanaged -ResourceType 'T' -Key 'k' -Reason 'because' -DataRoot $script:Temp | Out-Null
        $all = @(Get-PEDecision -DataRoot $script:Temp)
        $d = $all[0]
        $d.Reason | Should -Be 'because'
        $d.At | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$'
    }
}

Describe 'PropertyExcluded decisions' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-' + [guid]::NewGuid())
    }

    AfterEach {
        if (Test-Path $script:Temp)
        {
            Remove-Item $script:Temp -Recurse -Force
        }
    }

    It 'requires a tenant' {
        { Set-PEDecision -Kind PropertyExcluded -ResourceType 'SCDLPCompliancePolicy' -Property 'Priority' -Reason 'r' -DataRoot $script:Temp } | Should -Throw '*requires -Tenant*'
    }

    It 'requires a property' {
        { Set-PEDecision -Kind PropertyExcluded -ResourceType 'SCDLPCompliancePolicy' -Tenant 'contoso' -Reason 'r' -DataRoot $script:Temp } | Should -Throw '*requires -Property*'
    }

    It 'keeps a type-wide and an item-level exclusion apart, and one per identity' {
        Set-PEDecision -Kind PropertyExcluded -ResourceType 'SCDLPCompliancePolicy' -Property 'Priority' -Tenant 'contoso' -Reason 'a' -DataRoot $script:Temp | Out-Null
        Set-PEDecision -Kind PropertyExcluded -ResourceType 'SCDLPCompliancePolicy' -Property 'Priority' -Tenant 'contoso' -Key 'GDPR' -Reason 'b' -DataRoot $script:Temp | Out-Null
        Set-PEDecision -Kind PropertyExcluded -ResourceType 'SCDLPCompliancePolicy' -Property 'Priority' -Tenant 'contoso' -Reason 'again' -DataRoot $script:Temp | Out-Null
        $got = @(Get-PEDecision -Kind PropertyExcluded -DataRoot $script:Temp)
        $got.Count | Should -Be 2
        @($got | Where-Object { -not $_.Key })[0].Reason | Should -Be 'again'
        $got[0].Value | Should -BeNullOrEmpty
    }

    It 'is returned for its own tenant only' {
        Set-PEDecision -Kind PropertyExcluded -ResourceType 'SCDLPCompliancePolicy' -Property 'Priority' -Tenant 'contoso' -Reason 'a' -DataRoot $script:Temp | Out-Null
        @(Get-PEDecision -Kind PropertyExcluded -Tenant 'contoso' -DataRoot $script:Temp).Count | Should -Be 1
        @(Get-PEDecision -Kind PropertyExcluded -Tenant 'other' -DataRoot $script:Temp).Count | Should -Be 0
    }

    It 'Remove-PEDecision with a key removes only the item-level one' {
        Set-PEDecision -Kind PropertyExcluded -ResourceType 'SCDLPCompliancePolicy' -Property 'Priority' -Tenant 'contoso' -Reason 'a' -DataRoot $script:Temp | Out-Null
        Set-PEDecision -Kind PropertyExcluded -ResourceType 'SCDLPCompliancePolicy' -Property 'Priority' -Tenant 'contoso' -Key 'GDPR' -Reason 'b' -DataRoot $script:Temp | Out-Null
        Remove-PEDecision -Kind PropertyExcluded -ResourceType 'SCDLPCompliancePolicy' -Property 'Priority' -Tenant 'contoso' -Key 'GDPR' -DataRoot $script:Temp
        $left = @(Get-PEDecision -Kind PropertyExcluded -DataRoot $script:Temp)
        $left.Count | Should -Be 1
        $left[0].Key | Should -BeNullOrEmpty
    }
}
