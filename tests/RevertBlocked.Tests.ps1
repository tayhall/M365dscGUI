BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    Import-Module "$PSScriptRoot\..\gui\PEGui.psm1" -Force
    function New-St($records) { [pscustomobject]@{ Records = @($records); NotChecked = @(); Meta = @{ TenantId = 'contoso.onmicrosoft.com'; ExportedAt = '2026-10-24T00:00:00Z' } } }
    function New-Rec($type, $key, $props) { [pscustomobject]@{ ResourceType = $type; Key = $key; Workload = 'W'; TenantId = $null; Properties = $props } }
}

Describe 'Get-PERevertBlock' {
    It 'gives the reason for a Security and Compliance type and nothing for others' {
        InModuleScope PolicyEngine {
            Get-PERevertBlock -ResourceType 'SCComplianceTag' | Should -BeLike '*7563*'
            Get-PERevertBlock -ResourceType 'SCDLPCompliancePolicy' | Should -Not -BeNullOrEmpty
            Get-PERevertBlock -ResourceType 'AADGroup' | Should -BeNullOrEmpty
            Get-PERevertBlock -ResourceType 'EXOTransportRule' | Should -BeNullOrEmpty
        }
    }
}

Describe 'a plan for a blocked type' {
    BeforeAll {
        $script:Blueprint = New-St @((New-Rec 'SCComplianceTag' 'Confidential' ([ordered]@{ Name = 'Confidential'; Ensure = 'Present' })))
        $script:Target = New-St @()
        $script:Finding = @(Compare-PEState -Blueprint $script:Blueprint -Target $script:Target -WarningAction SilentlyContinue)[0]
    }

    It 'refuses Create with the reason' {
        { New-PERectifyPlan -Findings @($script:Finding) -Action Create -Source $script:Target -Blueprint $script:Blueprint } | Should -Throw '*Refusing Create for SCComplianceTag*7563*'
    }

    It 'does not refuse on that ground for Promote' {
        $message = try { New-PERectifyPlan -Findings @($script:Finding) -Action Promote -Source $script:Target -Blueprint $script:Blueprint | Out-Null; '' } catch { $_.Exception.Message }
        $message | Should -Not -BeLike '*7563*'
    }
}

Describe 'the GUI actions for a finding the engine will not revert' {
    It 'drops Revert and keeps Promote and Exclude, and says why when Revert is asked for' {
        InModuleScope PEGui {
            $blocked = [pscustomobject]@{ state = 'Open'; kind = 'Missing'; revertBlocked = 'cannot be applied' }
            $normal = [pscustomobject]@{ state = 'Open'; kind = 'Missing'; revertBlocked = $null }
            (Get-PEGuiAllowedAction -Finding $blocked) -join ',' | Should -Be 'Promote,Exclude'
            (Get-PEGuiAllowedAction -Finding $normal) -join ',' | Should -Be 'Accept,Promote,Exclude'
            (Get-PEGuiAllowedAction -Finding ([pscustomobject]@{ state = 'Open'; kind = 'Changed'; revertBlocked = 'x' })) -join ',' | Should -Be 'Promote,Exclude,ExcludeProperty'
        }
    }
}
