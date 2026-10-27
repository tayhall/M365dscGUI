BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force

    function New-TestRecord
    {
        param ([string]$Key, [hashtable]$Props = @{})
        $p = [ordered]@{ DisplayName = $Key }
        foreach ($k in $Props.Keys) { $p[$k] = $Props[$k] }
        [pscustomobject]@{ ResourceType = 'AADGroup'; Key = $Key; Workload = 'Entra ID'; TenantId = 't'; Properties = $p }
    }

    function New-TestState
    {
        param ([object[]]$Records = @())
        & (Get-Module PolicyEngine) {
            param ($r)
            New-PEState -Records $r -NotChecked @() -Meta @{ TenantId = 't'; ExportedAt = '2026-10-21T01:02:03Z'; Source = 'test' }
        } $Records
    }

    function Get-TestHash
    {
        param ($Record)
        & (Get-Module PolicyEngine) { Get-PEDecisionHash -Record $args[0] } $Record
    }
}

Describe 'RiskAccepted decisions' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-risk-' + [guid]::NewGuid())
        $script:Standard = New-TestState -Records @((New-TestRecord -Key 'g1' -Props @{ Description = 'a'; Visibility = 'Private' }), (New-TestRecord -Key 'g2'))
        $script:Tenant = New-TestState -Records @((New-TestRecord -Key 'g1' -Props @{ Description = 'b'; Visibility = 'Public' }))
    }

    AfterEach {
        if (Test-Path $script:Temp) { Remove-Item $script:Temp -Recurse -Force }
    }

    It 'requires a tenant, a key, an approver and a reason' {
        { Set-PEDecision -Kind RiskAccepted -ResourceType AADGroup -Key g1 -ApprovedBy 'cio' -Reason 'r' -DataRoot $script:Temp } | Should -Throw '*requires -Tenant*'
        { Set-PEDecision -Kind RiskAccepted -ResourceType AADGroup -Tenant master -ApprovedBy 'cio' -Reason 'r' -DataRoot $script:Temp } | Should -Throw '*requires -Key*'
        { Set-PEDecision -Kind RiskAccepted -ResourceType AADGroup -Key g1 -Tenant master -Reason 'r' -DataRoot $script:Temp } | Should -Throw '*requires -ApprovedBy*'
        { Set-PEDecision -Kind RiskAccepted -ResourceType AADGroup -Key g1 -Tenant master -ApprovedBy 'cio' -Reason '' -DataRoot $script:Temp } | Should -Throw
    }

    It 'replaces an earlier acceptance of the same item' {
        Set-PEDecision -Kind RiskAccepted -ResourceType AADGroup -Key g1 -Tenant master -ApprovedBy 'cio' -Reason 'first' -DataRoot $script:Temp | Out-Null
        Set-PEDecision -Kind RiskAccepted -ResourceType AADGroup -Key g1 -Tenant master -ApprovedBy 'ciso' -Reason 'second' -DataRoot $script:Temp | Out-Null
        $list = @(Get-PEDecision -Kind RiskAccepted -DataRoot $script:Temp)
        $list.Count | Should -Be 1
        $list[0].ApprovedBy | Should -Be 'ciso'
    }

    It 'marks a Changed finding Accepted with who and why, and keeps it visible' {
        Set-PEDecision -Kind RiskAccepted -ResourceType AADGroup -Key g1 -Tenant master -ApprovedBy 'cio' -Reason 'legacy app needs it' -DataRoot $script:Temp | Out-Null
        $finding = @(Compare-PEState -Blueprint $script:Standard -Target $script:Tenant -Subset -Decisions @(Get-PEDecision -Tenant master -DataRoot $script:Temp) | Where-Object Key -EQ 'g1')
        $finding.Count | Should -Be 1
        $finding[0].Kind | Should -Be 'Changed'
        $finding[0].State | Should -Be 'Accepted'
        $finding[0].ApprovedBy | Should -Be 'cio'
        $finding[0].AcceptedReason | Should -Be 'legacy app needs it'
        @($finding[0].Differences).Count | Should -Be 2
    }

    It 'accepts one property and leaves the other difference open' {
        Set-PEDecision -Kind RiskAccepted -ResourceType AADGroup -Key g1 -Property Description -Tenant master -ApprovedBy 'cio' -Reason 'ok' -DataRoot $script:Temp | Out-Null
        $finding = @(Compare-PEState -Blueprint $script:Standard -Target $script:Tenant -Subset -Decisions @(Get-PEDecision -Tenant master -DataRoot $script:Temp) | Where-Object Key -EQ 'g1')[0]
        $finding.State | Should -Be 'Open'
        @($finding.Differences | ForEach-Object Property) | Should -Be @('Visibility')
        @($finding.AcceptedDifferences | ForEach-Object Property) | Should -Be @('Description')
    }

    It 'marks the item Accepted when every difference is an accepted property' {
        foreach ($property in 'Description', 'Visibility')
        {
            Set-PEDecision -Kind RiskAccepted -ResourceType AADGroup -Key g1 -Property $property -Tenant master -ApprovedBy 'cio' -Reason 'ok' -DataRoot $script:Temp | Out-Null
        }
        $finding = @(Compare-PEState -Blueprint $script:Standard -Target $script:Tenant -Subset -Decisions @(Get-PEDecision -Tenant master -DataRoot $script:Temp) | Where-Object Key -EQ 'g1')[0]
        $finding.State | Should -Be 'Accepted'
        @($finding.Differences).Count | Should -Be 0
    }

    It 'accepts a Missing item' {
        Set-PEDecision -Kind RiskAccepted -ResourceType AADGroup -Key g2 -Tenant master -ApprovedBy 'cio' -Reason 'not needed here' -DataRoot $script:Temp | Out-Null
        $finding = @(Compare-PEState -Blueprint $script:Standard -Target $script:Tenant -Subset -Decisions @(Get-PEDecision -Tenant master -DataRoot $script:Temp) | Where-Object Key -EQ 'g2')[0]
        $finding.Kind | Should -Be 'Missing'
        $finding.State | Should -Be 'Accepted'
    }

    It 'is for one tenant only' {
        Set-PEDecision -Kind RiskAccepted -ResourceType AADGroup -Key g1 -Tenant dev -ApprovedBy 'cio' -Reason 'dev only' -DataRoot $script:Temp | Out-Null
        $finding = @(Compare-PEState -Blueprint $script:Standard -Target $script:Tenant -Subset -Decisions @(Get-PEDecision -Tenant master -DataRoot $script:Temp) | Where-Object Key -EQ 'g1')[0]
        $finding.State | Should -Be 'Open'
    }

    It 'reopens an acceptance when the standard value changed' {
        $oldHash = Get-TestHash -Record $script:Standard.Records[0]
        Set-PEDecision -Kind RiskAccepted -ResourceType AADGroup -Key g1 -Tenant master -ApprovedBy 'cio' -Reason 'ok' -StandardHash $oldHash -DataRoot $script:Temp | Out-Null
        $unchanged = @(Compare-PEState -Blueprint $script:Standard -Target $script:Tenant -Subset -Decisions @(Get-PEDecision -Tenant master -DataRoot $script:Temp) | Where-Object Key -EQ 'g1')[0]
        $unchanged.State | Should -Be 'Accepted'
        $newer = New-TestState -Records @((New-TestRecord -Key 'g1' -Props @{ Description = 'a2'; Visibility = 'Private' }))
        $stale = @(Compare-PEState -Blueprint $newer -Target $script:Tenant -Subset -Decisions @(Get-PEDecision -Tenant master -DataRoot $script:Temp) | Where-Object Key -EQ 'g1')[0]
        $stale.State | Should -Be 'Open'
        $stale.Hint | Should -Be 'Accepted risk needs another look: the standard has changed.'
    }
}

Describe 'Set-PERiskAcceptance' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-riskset-' + [guid]::NewGuid())
        $state = New-TestState -Records @((New-TestRecord -Key 'g1' -Props @{ Description = 'a' }))
        Initialize-PEBlueprint -Name 'asd' -State $state -DataRoot $script:Temp | Out-Null
        $directory = & (Get-Module PolicyEngine) { Get-PEBlueprintDirectory -Name 'asd' -DataRoot $args[0] } $script:Temp
        ([ordered]@{ Kind = 'Standard'; Name = 'asd' } | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $directory 'standard.json')
    }

    AfterEach {
        if (Test-Path $script:Temp) { Remove-Item $script:Temp -Recurse -Force }
    }

    It 'records the acceptance with the hash of the standard record' {
        Set-PERiskAcceptance -Standard 'asd' -Tenant master -ResourceType AADGroup -Key g1 -ApprovedBy 'cio' -Reason 'legacy app' -DataRoot $script:Temp | Out-Null
        $decision = @(Get-PEDecision -Kind RiskAccepted -DataRoot $script:Temp)[0]
        $decision.ApprovedBy | Should -Be 'cio'
        $decision.Reason | Should -Be 'legacy app'
        $decision.Tenant | Should -Be 'master'
        $decision.StandardHash | Should -Be (Get-TestHash -Record (Get-PEBlueprint -Name 'asd' -DataRoot $script:Temp).Records[0])
    }

    It 'can be limited to one property the standard states' {
        Set-PERiskAcceptance -Standard 'asd' -Tenant master -ResourceType AADGroup -Key g1 -Property Description -ApprovedBy 'cio' -Reason 'ok' -DataRoot $script:Temp | Out-Null
        @(Get-PEDecision -Kind RiskAccepted -DataRoot $script:Temp)[0].Property | Should -Be 'Description'
    }

    It 'throws for an item the standard does not have' {
        { Set-PERiskAcceptance -Standard 'asd' -Tenant master -ResourceType AADGroup -Key nope -ApprovedBy 'cio' -Reason 'ok' -DataRoot $script:Temp } | Should -Throw "*has no item*"
    }

    It 'throws for a property the standard does not state' {
        { Set-PERiskAcceptance -Standard 'asd' -Tenant master -ResourceType AADGroup -Key g1 -Property Visibility -ApprovedBy 'cio' -Reason 'ok' -DataRoot $script:Temp } | Should -Throw "*does not state*"
    }

    It 'refuses a name that is not a standard' {
        Initialize-PEBlueprint -Name 'prod' -State (New-TestState -Records @((New-TestRecord -Key 'g1'))) -DataRoot $script:Temp | Out-Null
        { Set-PERiskAcceptance -Standard 'prod' -Tenant master -ResourceType AADGroup -Key g1 -ApprovedBy 'cio' -Reason 'ok' -DataRoot $script:Temp } | Should -Throw "*is not a standard*"
    }
}
