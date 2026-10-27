BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    function New-Rec($type, $key, $props) { [pscustomobject]@{ ResourceType = $type; Key = $key; Workload = 'Security and Compliance'; TenantId = $null; Properties = $props } }
    function New-St($records, $tenantId) { [pscustomobject]@{ Records = @($records); NotChecked = @(); Meta = @{ TenantId = $tenantId } } }
    function New-Exclusion($property = 'Priority', $key = $null, $tenant = 'contoso')
    {
        [pscustomobject]@{ Kind = 'PropertyExcluded'; ResourceType = 'SCDLPCompliancePolicy'; Key = $key; Property = $property; Value = $null; Tenant = $tenant }
    }
}

Describe 'Compare-PEState and PropertyExcluded decisions' {
    BeforeEach {
        $names = 'GDPR', 'Teams', 'Devices', 'Financial', 'Copilot'
        $script:Bp = New-St @($names | ForEach-Object { New-Rec 'SCDLPCompliancePolicy' $_ ([ordered]@{ Name = $_; Mode = 'Enable'; Priority = 1 }) }) 'prod'
        $script:Tg = { param ($mode = 'Enable') New-St @($names | ForEach-Object { New-Rec 'SCDLPCompliancePolicy' $_ ([ordered]@{ Name = $_; Mode = $mode; Priority = 4 }) }) 'dev' }
    }

    It 'shows Priority as drift when nothing is excluded' {
        $f = @(Compare-PEState -Blueprint $script:Bp -Target (& $script:Tg))
        $f.Count | Should -Be 5
        @($f | Where-Object State -eq 'Open').Count | Should -Be 5
        $f[0].ExcludedDifferences.Count | Should -Be 0
    }

    It 'a type-wide exclusion keeps the differences visible and stops them counting' {
        $f = @(Compare-PEState -Blueprint $script:Bp -Target (& $script:Tg) -Decisions @(New-Exclusion))
        $f.Count | Should -Be 5
        foreach ($x in $f)
        {
            $x.State | Should -Be 'Unmanaged'
            $x.Differences.Count | Should -Be 0
            @($x.ExcludedDifferences.Property) | Should -Contain 'Priority'
            $x.ExcludedDifferences[0].Blueprint | Should -Be 1
            $x.ExcludedDifferences[0].Target | Should -Be 4
        }
        $status = @(Get-PEStatus -Blueprint $script:Bp -Findings $f)
        $status[0].Drifted | Should -Be 0
        $status[0].Unmanaged | Should -Be 5
    }

    It 'an item-level exclusion covers that item only (key matches case-insensitively)' {
        $f = @(Compare-PEState -Blueprint $script:Bp -Target (& $script:Tg) -Decisions @(New-Exclusion -key 'gdpr'))
        @($f | Where-Object State -eq 'Unmanaged').Count | Should -Be 1
        @($f | Where-Object State -eq 'Unmanaged')[0].Key | Should -Be 'GDPR'
        @($f | Where-Object State -eq 'Open').Count | Should -Be 4
    }

    It 'a mixed finding stays drift and lists both kinds' {
        $f = @(Compare-PEState -Blueprint $script:Bp -Target (& $script:Tg 'TestWithoutNotifications') -Decisions @(New-Exclusion))
        $f.Count | Should -Be 5
        $f[0].State | Should -Be 'Open'
        @($f[0].Differences.Property) | Should -Be @('Mode')
        @($f[0].ExcludedDifferences.Property) | Should -Be @('Priority')
    }

    It 'an exclusion without a tenant, for another property or for a property that does not differ changes nothing' {
        $none = @(Compare-PEState -Blueprint $script:Bp -Target (& $script:Tg) -Decisions @((New-Exclusion -tenant $null)))
        @($none | Where-Object State -eq 'Open').Count | Should -Be 5
        $other = @(Compare-PEState -Blueprint $script:Bp -Target (& $script:Tg) -Decisions @((New-Exclusion -property 'Mode'), (New-Exclusion -property 'Nope' -key 'Missing item')))
        @($other | Where-Object State -eq 'Open').Count | Should -Be 5
        @($other[0].Differences.Property) | Should -Contain 'Priority'
    }

    It 'without decisions the findings carry an empty ExcludedDifferences' {
        $f = @(Compare-PEState -Blueprint $script:Bp -Target $script:Bp)
        $f.Count | Should -Be 0
    }
}

Describe 'PropertyExcluded decisions per tenant' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-' + [guid]::NewGuid())
    }

    AfterEach {
        if (Test-Path $script:Temp) { Remove-Item $script:Temp -Recurse -Force }
    }

    It 'a decision for contoso is passed to contoso only' {
        Set-PEDecision -Kind PropertyExcluded -ResourceType 'SCDLPCompliancePolicy' -Property 'Priority' -Tenant 'contoso' -Reason 'order is local' -DataRoot $script:Temp | Out-Null
        $bp = New-St @(New-Rec 'SCDLPCompliancePolicy' 'GDPR' ([ordered]@{ Name = 'GDPR'; Priority = 1 })) 'prod'
        $tg = New-St @(New-Rec 'SCDLPCompliancePolicy' 'GDPR' ([ordered]@{ Name = 'GDPR'; Priority = 4 })) 'dev'
        $forContoso = @(Compare-PEState -Blueprint $bp -Target $tg -Decisions @(Get-PEDecision -Tenant 'contoso' -DataRoot $script:Temp))
        $forOther = @(Compare-PEState -Blueprint $bp -Target $tg -Decisions @(Get-PEDecision -Tenant 'other' -DataRoot $script:Temp))
        $forContoso[0].State | Should -Be 'Unmanaged'
        $forOther[0].State | Should -Be 'Open'
        @($forOther[0].Differences.Property) | Should -Contain 'Priority'
    }
}
