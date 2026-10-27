BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures\asd-mini'
    . "$PSScriptRoot\StandardTestHelper.ps1"
}

Describe 'Standard checks for the GUI' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-stdgui-' + [guid]::NewGuid())
        Import-PEStandard -Name 'asd' -Path $script:Fixture -SourceName 'ASD' -SourceUrl 'https://example.test' -SourceVersion 'v1.4.0' -DataRoot $script:Temp -WarningAction SilentlyContinue 6>$null | Out-Null
        # The named location differs (Changed) and the Teams policy is missing.
        $folder = New-TenantExport -Root $script:Temp -Countries '@("AU","NZ")'
        $export = { $folder }.GetNewClosure()
        $script:First = Invoke-PEStandardCheck -StandardName 'asd' -ExportScript $export -TargetTenantId 'tenant-1' -DataRoot $script:Temp
        $script:Location = { param ($result) @($result.Findings | Where-Object ResourceType -EQ 'AADNamedLocationPolicy')[0] }
    }

    AfterEach {
        if (Test-Path $script:Temp) { Remove-Item $script:Temp -Recurse -Force }
    }

    Context 'Get-PECheck -Standard' {
        It 'returns the latest check of that standard only' {
            (Get-PECheck -Latest -Kind Standard -Standard 'asd' -DataRoot $script:Temp).CheckId | Should -Be $script:First.CheckId
            { Get-PECheck -Latest -Kind Standard -Standard 'nist' -DataRoot $script:Temp } | Should -Throw "*No Standard check found for standard 'nist'*"
        }
    }

    Context 'Update-PEStandardCheck' {
        It 'saves a patched check in which a newly accepted risk shows as Accepted' {
            Set-PERiskAcceptance -Standard 'asd' -Tenant master -ResourceType AADNamedLocationPolicy -Key 'Allowed Countries' -ApprovedBy 'cio' -Reason 'NZ staff' -DataRoot $script:Temp | Out-Null
            $newId = Update-PEStandardCheck -Tenant master -StandardName 'asd' -DataRoot $script:Temp
            $newId | Should -BeGreaterThan $script:First.CheckId
            $updated = Get-PECheck -CheckId $newId -DataRoot $script:Temp
            $updated.Kind | Should -Be 'Standard'
            (& $script:Location $updated).State | Should -Be 'Accepted'
            $updated.State.Meta.PatchedFrom | Should -Be $script:First.CheckId
            $updated.Coverage.Checked | Should -Be $script:First.Coverage.Checked
            (Get-PECheck -Latest -Kind Standard -Standard 'asd' -DataRoot $script:Temp).CheckId | Should -Be $newId
        }

        It 'leaves the earlier check as it was' {
            Set-PERiskAcceptance -Standard 'asd' -Tenant master -ResourceType AADNamedLocationPolicy -Key 'Allowed Countries' -ApprovedBy 'cio' -Reason 'x' -DataRoot $script:Temp | Out-Null
            Update-PEStandardCheck -Tenant master -StandardName 'asd' -DataRoot $script:Temp | Out-Null
            (& $script:Location (Get-PECheck -CheckId $script:First.CheckId -DataRoot $script:Temp)).State | Should -Be 'Open'
        }

        It 'shows the item as open again after the acceptance is removed' {
            Set-PERiskAcceptance -Standard 'asd' -Tenant master -ResourceType AADNamedLocationPolicy -Key 'Allowed Countries' -ApprovedBy 'cio' -Reason 'x' -DataRoot $script:Temp | Out-Null
            Update-PEStandardCheck -Tenant master -StandardName 'asd' -DataRoot $script:Temp | Out-Null
            Remove-PEDecision -Kind RiskAccepted -ResourceType AADNamedLocationPolicy -Key 'Allowed Countries' -Tenant master -DataRoot $script:Temp
            $newId = Update-PEStandardCheck -Tenant master -StandardName 'asd' -DataRoot $script:Temp
            (& $script:Location (Get-PECheck -CheckId $newId -DataRoot $script:Temp)).State | Should -Be 'Open'
        }

        It 'ignores a risk accepted against another standard' {
            Set-PEDecision -Kind RiskAccepted -ResourceType AADNamedLocationPolicy -Key 'Allowed Countries' -Tenant master -ApprovedBy 'cio' -Reason 'other' -Standard 'nist' -DataRoot $script:Temp | Out-Null
            $newId = Update-PEStandardCheck -Tenant master -StandardName 'asd' -DataRoot $script:Temp
            (& $script:Location (Get-PECheck -CheckId $newId -DataRoot $script:Temp)).State | Should -Be 'Open'
        }

        It 'throws when the tenant has no check of the standard' {
            { Update-PEStandardCheck -Tenant dev -StandardName 'asd' -DataRoot $script:Temp } | Should -Throw '*No Standard check*'
        }
    }
}
