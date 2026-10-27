BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Mini = Join-Path $PSScriptRoot 'fixtures\mini-export.ps1'
    $script:Log = @'
Exporting Microsoft 365 configuration for Components: AADGroup, AADConditionalAccessPolicy

Starting export in sequential mode...
[1/2] Extracting [AADGroup] using {CertificateThumbprint}...
    |---[1/2] Sales✅
    |---[2/2] Finance✅
[2/2] Extracting [AADConditionalAccessPolicy] using {CertificateThumbprint}...
    |---[1/1] Require MFA✅
⌛ Export took {5 seconds} for {3 instances}
Successful exports: {2}
Failed exports: {0}
✅ Export completed successfully.
'@

    function New-ExportFolder
    {
        param ([string]$Root, [string]$LogText)
        $folder = Join-Path $Root ('export-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        Copy-Item $script:Mini (Join-Path $folder 'export.ps1')
        [System.IO.File]::WriteAllText((Join-Path $folder 'export.log'), $(if ($LogText) { $LogText } else { $script:Log }), [System.Text.UTF8Encoding]::new($false))
        return $folder
    }
}

Describe 'Add-PEBlueprintType' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-addtype-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Temp | Out-Null
        $group = [pscustomobject]@{ ResourceType = 'AADGroup'; Key = 'Sales'; Workload = 'Entra ID'; Properties = [ordered]@{ DisplayName = 'Sales' } }
        $state = InModuleScope PolicyEngine -Parameters @{ R = @($group) } {
            New-PEState -Records $R -NotChecked @() -Meta @{ TenantId = 'tenant-1'; ExportedAt = '2026-10-01T00:00:00Z' }
        }
        Initialize-PEBlueprint -Name 'main' -State $state -DataRoot $script:Temp | Out-Null
        $folder = New-ExportFolder -Root $script:Temp
        $script:Fake = { $folder }.GetNewClosure()
    }

    AfterEach {
        Remove-Item $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'adds the items of a new type as a new version and leaves the other types alone' {
        $result = Add-PEBlueprintType -Name 'main' -Types 'AADConditionalAccessPolicy' -Reason 'add CA' -ExportScript $script:Fake -TargetTenantId 'tenant-1' -DataRoot $script:Temp
        $result.Version | Should -Be 2
        $result.Added.ResourceType | Should -Be @('AADConditionalAccessPolicy')
        $result.Added[0].Items | Should -Be 1
        $blueprint = Get-PEBlueprint -Name 'main' -DataRoot $script:Temp
        @($blueprint.Records | Where-Object ResourceType -EQ 'AADConditionalAccessPolicy').Count | Should -Be 1
        @($blueprint.Records | Where-Object ResourceType -EQ 'AADGroup').Count | Should -Be 1
        (Get-Content (Join-Path $script:Temp 'blueprints\main\changes\v0002.json') -Raw | ConvertFrom-Json).Reason | Should -Be 'add CA'
    }

    It 'refuses a type the blueprint already holds unless allowed, and then adds only what is missing' {
        { Add-PEBlueprintType -Name 'main' -Types 'AADGroup' -Reason 'x' -ExportScript $script:Fake -TargetTenantId 'tenant-1' -DataRoot $script:Temp } | Should -Throw '*already holds items of AADGroup*'
        $result = Add-PEBlueprintType -Name 'main' -Types 'AADGroup' -AllowExistingTypes -Reason 'x' -ExportScript $script:Fake -TargetTenantId 'tenant-1' -DataRoot $script:Temp
        # Sales exists; Finance is duplicated in the export (Ambiguous), so nothing can be added.
        $result.Version | Should -BeNullOrEmpty
        $result.Skipped[0].Ambiguous | Should -BeGreaterThan 0
    }

    It 'with -WhatIf exports and reports but writes no version' {
        $result = Add-PEBlueprintType -Name 'main' -Types 'AADConditionalAccessPolicy' -Reason 'x' -ExportScript $script:Fake -TargetTenantId 'tenant-1' -DataRoot $script:Temp -WhatIf
        $result.Added[0].Items | Should -Be 1
        $result.Version | Should -BeNullOrEmpty
        @(Get-ChildItem (Join-Path $script:Temp 'blueprints\main') -Filter 'v*.json').Count | Should -Be 1
    }

    It 'reports a type that did not export and adds nothing for it' {
        $folder = New-ExportFolder -Root $script:Temp -LogText "Exporting Microsoft 365 configuration for Components: AADConditionalAccessPolicy`n[1/1] Extracting [AADConditionalAccessPolicy] using {CertificateThumbprint}...`n    |---[1/1] Require MFA❌`n    An error occurred while exporting resource {AADConditionalAccessPolicy}: 403 forbidden`n❌ Export completed with errors.`n"
        $result = Add-PEBlueprintType -Name 'main' -Types 'AADConditionalAccessPolicy' -Reason 'x' -ExportScript { $folder }.GetNewClosure() -TargetTenantId 'tenant-1' -DataRoot $script:Temp -WarningAction SilentlyContinue
        $result.Version | Should -BeNullOrEmpty
        $result.NotChecked[0].ResourceType | Should -Be 'AADConditionalAccessPolicy'
    }

    It 'refuses names that are not DSC resource types' {
        { Add-PEBlueprintType -Name 'main' -Types 'NotARealResource' -Reason 'x' -ExportScript $script:Fake -DataRoot $script:Temp } | Should -Throw
    }
}
