BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force

    function New-TestRecord
    {
        param ([string]$Key)
        [pscustomobject]@{ ResourceType = 'AADGroup'; Key = $Key; Workload = 'Entra ID'; TenantId = 't'; Properties = [ordered]@{ DisplayName = $Key } }
    }

    function New-TestState
    {
        param ([object[]]$Records = @())
        & (Get-Module PolicyEngine) {
            param ($r)
            New-PEState -Records $r -NotChecked @() -Meta @{ TenantId = 't'; ExportedAt = '2026-10-21T01:02:03Z'; Source = 'test' }
        } $Records
    }
}

Describe 'A standard is a read-only blueprint' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-std-' + [guid]::NewGuid())
        Initialize-PEBlueprint -Name 'asd' -State (New-TestState -Records @((New-TestRecord -Key 'g1'))) -DataRoot $script:Temp | Out-Null
        Initialize-PEBlueprint -Name 'prod' -State (New-TestState -Records @((New-TestRecord -Key 'g2'))) -DataRoot $script:Temp | Out-Null
        $directory = & (Get-Module PolicyEngine) { Get-PEBlueprintDirectory -Name 'asd' -DataRoot $args[0] } $script:Temp
        ([ordered]@{ Kind = 'Standard'; Name = 'asd' } | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $directory 'standard.json')
    }

    AfterEach {
        if (Test-Path $script:Temp) { Remove-Item $script:Temp -Recurse -Force }
    }

    It 'is recognised by Get-PEStandardInfo, an ordinary blueprint is not' {
        (& (Get-Module PolicyEngine) { Get-PEStandardInfo -Name 'asd' -DataRoot $args[0] } $script:Temp).Kind | Should -Be 'Standard'
        (& (Get-Module PolicyEngine) { Get-PEStandardInfo -Name 'prod' -DataRoot $args[0] } $script:Temp) | Should -BeNullOrEmpty
    }

    It 'refuses Approve-PEBlueprintChange' {
        { Approve-PEBlueprintChange -Name 'asd' -MasterState (New-TestState) -Accept @([pscustomobject]@{ Kind = 'Missing' }) -Reason 'x' -DataRoot $script:Temp } |
            Should -Throw "*Blueprint 'asd' is a standard (read-only)*"
    }

    It 'refuses Move-PEBlueprintItem into a standard but not out of one' {
        { Move-PEBlueprintItem -From 'prod' -To 'asd' -Item @([pscustomobject]@{ ResourceType = 'AADGroup'; Key = 'g2' }) -Reason 'x' -ExpectedVersion 1 -DataRoot $script:Temp } |
            Should -Throw '*is a standard (read-only)*'
        Move-PEBlueprintItem -From 'asd' -To 'prod' -Item @([pscustomobject]@{ ResourceType = 'AADGroup'; Key = 'g1' }) -Reason 'x' -ExpectedVersion 1 -DataRoot $script:Temp | Should -Be 2
    }

    It 'refuses Restore-PEBlueprintVersion' {
        { Restore-PEBlueprintVersion -Name 'asd' -Version 1 -Reason 'x' -DataRoot $script:Temp } | Should -Throw '*is a standard (read-only)*'
    }

    It 'refuses a full check and points to the standard check' {
        { Invoke-PEFullCheck -BlueprintName 'asd' -ExportScript { 'x' } -DataRoot $script:Temp } | Should -Throw '*Invoke-PEStandardCheck*'
    }

    It 'refuses a scope check' {
        { Invoke-PEScopeCheck -Scope 'AADGroup' -BlueprintName 'asd' -ExportScript { 'x' } -DataRoot $script:Temp } | Should -Throw '*is a standard (read-only)*'
    }

    It 'refuses Add-PEBlueprintType' {
        { Add-PEBlueprintType -Name 'asd' -Types 'AADGroup' -Reason 'x' -ExportScript { 'x' } -DataRoot $script:Temp } | Should -Throw '*is a standard (read-only)*'
    }

    It 'refuses Invoke-PERectify' {
        { Invoke-PERectify -Plan $null -Target Replica -BlueprintName 'asd' -DataRoot $script:Temp } | Should -Throw '*is a standard (read-only)*'
    }

    It 'refuses a standard in a tenant blueprint list' {
        { Set-PETenant -Slug 'dev' -Blueprints @('prod', 'asd') -DataRoot $script:Temp } | Should -Throw '*is a standard (read-only)*'
        { Set-PETenant -Slug 'dev' -Blueprints @('prod') -DataRoot $script:Temp } | Should -Not -Throw
    }
}
