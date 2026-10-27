BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Mini = Join-Path $PSScriptRoot 'fixtures\mini-export.ps1'

    function New-State
    {
        param ([object[]]$Records = @())
        InModuleScope PolicyEngine -Parameters @{ R = $Records } {
            New-PEState -Records $R -NotChecked @() -Meta @{ TenantId = 't'; ExportedAt = '2026-10-22T00:00:00Z' }
        }
    }
}

Describe 'Module version guard' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-guard-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Temp | Out-Null
        $group = [pscustomobject]@{ ResourceType = 'AADGroup'; Key = 'Sales'; Workload = 'Entra ID'; Properties = [ordered]@{ DisplayName = 'Sales' } }
        Initialize-PEBlueprint -Name 'main' -State (New-State @($group)) -DataRoot $script:Temp | Out-Null
        $script:ModuleFile = Join-Path $script:Temp 'blueprints\main\module.json'
        $script:Pin = (Import-PowerShellDataFile "$PSScriptRoot\..\src\PolicyEngine\Data\Versions.psd1").Microsoft365DSC
    }

    AfterEach {
        Remove-Item $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'a new blueprint records the pinned version' {
        (Get-Content $script:ModuleFile -Raw | ConvertFrom-Json).ModuleVersion | Should -Be $script:Pin
        $status = Get-PEModuleStatus -BlueprintName 'main' -DataRoot $script:Temp
        $status.Match | Should -BeTrue
        $status.Pin | Should -Be $script:Pin
    }

    It 'a check refuses to run when the blueprint was built with another version, and says how to re-baseline' {
        $record = Get-Content $script:ModuleFile -Raw | ConvertFrom-Json
        $record.ModuleVersion = '2.25.0.1'
        $record | ConvertTo-Json | Set-Content $script:ModuleFile
        (Get-PEModuleStatus -BlueprintName 'main' -DataRoot $script:Temp).Match | Should -BeFalse
        { Invoke-PEFullCheck -BlueprintName 'main' -ExportScript { throw 'must not export' } -DataRoot $script:Temp } | Should -Throw "*built with Microsoft365DSC 2.25.0.1*pinned version is $($script:Pin)*Set-PEBlueprintModule*"
        { Invoke-PEScopeCheck -Scope 'AADGroup' -BlueprintName 'main' -ExportScript { throw 'must not export' } -DataRoot $script:Temp } | Should -Throw '*built with Microsoft365DSC 2.25.0.1*'
        { Add-PEBlueprintType -Name 'main' -Types 'AADNamedLocationPolicy' -Reason 'x' -ExportScript { throw 'must not export' } -DataRoot $script:Temp } | Should -Throw '*built with Microsoft365DSC 2.25.0.1*'
    }

    It '-AcceptModuleChange runs with a warning, and Set-PEBlueprintModule re-baselines and keeps the previous version' {
        $record = Get-Content $script:ModuleFile -Raw | ConvertFrom-Json
        $record.ModuleVersion = '2.25.0.1'
        $record | ConvertTo-Json | Set-Content $script:ModuleFile
        $folder = Join-Path $script:Temp 'export'
        New-Item -ItemType Directory -Path $folder | Out-Null
        Copy-Item $script:Mini (Join-Path $folder 'export.ps1')
        $warnings = @()
        Invoke-PEFullCheck -BlueprintName 'main' -ExportScript { $folder }.GetNewClosure() -TargetTenantId 't' -AcceptModuleChange -DataRoot $script:Temp -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
        ($warnings -join ' ') | Should -BeLike '*continuing because -AcceptModuleChange*'
        (Get-PECheck -Latest -Kind Full -DataRoot $script:Temp).State.Meta.ModuleVersion | Should -Be $script:Pin
        $after = Set-PEBlueprintModule -Name 'main' -Reason 'upgraded to the pin' -DataRoot $script:Temp
        $after.Match | Should -BeTrue
        (Get-Content $script:ModuleFile -Raw | ConvertFrom-Json).Previous | Should -Be '2.25.0.1'
    }

    It 'a blueprint with no recorded version only warns' {
        Remove-Item $script:ModuleFile
        (Get-PEModuleStatus -BlueprintName 'main' -DataRoot $script:Temp).Match | Should -BeNullOrEmpty
        $warning = $null
        InModuleScope PolicyEngine -Parameters @{ Root = $script:Temp } {
            Assert-PEModuleVersion -BlueprintName 'main' -DataRoot $Root -WarningVariable w -WarningAction SilentlyContinue
            $w -join ' ' | Should -BeLike "*no recorded Microsoft365DSC version*Set-PEBlueprintModule*"
        }
    }
}

Describe 'Key taken from the DSC resource schema' {
    It 'keys a resource with no usual name by the [Key] properties its schema declares' {
        if (@(& (Get-Module PolicyEngine) { Get-PEKnownResourceType }).Count -eq 0) { Set-ItResult -Skipped -Because 'Microsoft365DSC is not installed'; return }
        InModuleScope PolicyEngine {
            $record = [pscustomobject]@{ ResourceType = 'AADEntitlementManagementRoleAssignment'; Key = $null; Workload = 'Entra ID'; Properties = [ordered]@{ Principal = 'alice@example.com'; RoleDefinition = 'Catalog owner' } }
            Get-PEResourceKey -ResourceType 'AADEntitlementManagementRoleAssignment' -Properties $record.Properties | Should -Be 'alice@example.com | Catalog owner'
            Get-PEResourceKey -ResourceType 'AADEntitlementManagementRoleAssignment' -Properties ([ordered]@{ Principal = 'alice@example.com' }) | Should -BeNullOrEmpty
        }
    }

    It 'does not change a type that already has a key from the usual names' {
        if (@(& (Get-Module PolicyEngine) { Get-PEKnownResourceType }).Count -eq 0) { Set-ItResult -Skipped -Because 'Microsoft365DSC is not installed'; return }
        InModuleScope PolicyEngine {
            Get-PEResourceKey -ResourceType 'AADGroup' -Properties ([ordered]@{ DisplayName = 'Sales'; MailNickname = 'sales' }) | Should -Be 'Sales'
        }
    }
}
