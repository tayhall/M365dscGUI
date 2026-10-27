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
        # A fake export: the mini export (optionally with the CA policy disabled) and a log naming both types.
        param ([string]$Root, [switch]$CaDisabled, [string]$LogText, [switch]$RichSales)
        $folder = Join-Path $Root ('export-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        $text = Get-Content -LiteralPath $script:Mini -Raw
        if ($RichSales) { $text = $text.Replace('DisplayName           = "Sales";', 'DisplayName           = "Sales"; Description = "d"; Visibility = "Private"; Classification = "c"; Theme = "t"; Owner = "o";') }
        if ($CaDisabled) { $text = $text.Replace('State                 = "enabled";', 'State                 = "disabled";') }
        [System.IO.File]::WriteAllText((Join-Path $folder 'export.ps1'), $text)
        [System.IO.File]::WriteAllText((Join-Path $folder 'export.log'), $(if ($LogText) { $LogText } else { $script:Log }), [System.Text.UTF8Encoding]::new($false))
        return $folder
    }
}

Describe 'Scopes' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-scope-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Temp | Out-Null
    }

    AfterEach {
        Remove-Item $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'stores, replaces and removes scopes' {
        @(Get-PEScope -DataRoot $script:Temp).Count | Should -Be 0
        Set-PEScope -Name 'ca' -Types 'AADConditionalAccessPolicy' -Description 'CA policies' -DataRoot $script:Temp | Out-Null
        Set-PEScope -Name 'roles' -Types 'AADGroup' -Keys 'Role-*', 'Admin*' -DataRoot $script:Temp | Out-Null
        @(Get-PEScope -DataRoot $script:Temp).Name | Should -Be @('ca', 'roles')
        (Get-PEScope -Name 'roles' -DataRoot $script:Temp).Keys | Should -Be @('Role-*', 'Admin*')
        Set-PEScope -Name 'CA' -Types 'AADConditionalAccessPolicy', 'AADNamedLocationPolicy' -DataRoot $script:Temp | Out-Null
        @(Get-PEScope -DataRoot $script:Temp).Count | Should -Be 2
        (Get-PEScope -Name 'ca' -DataRoot $script:Temp).Types | Should -Be @('AADConditionalAccessPolicy', 'AADNamedLocationPolicy')
        Remove-PEScope -Name 'ca' -DataRoot $script:Temp
        @(Get-PEScope -DataRoot $script:Temp).Name | Should -Be @('roles')
    }

    It 'treats every DSC resource name as a scope of its own, and a defined scope of that name wins' {
        if (@(& (Get-Module PolicyEngine) { Get-PEKnownResourceType }).Count -eq 0) { Set-ItResult -Skipped -Because 'Microsoft365DSC is not installed'; return }
        $group = Get-PEScope -Name 'aadgroup' -DataRoot $script:Temp
        $group.Name | Should -Be 'AADGroup'
        $group.Types | Should -Be @('AADGroup')
        @($group.Keys).Count | Should -Be 0
        @(Get-PEScope -DataRoot $script:Temp).Count | Should -Be 0   # listing shows only defined scopes
        Set-PEScope -Name 'AADGroup' -Types 'AADGroup' -Keys 'sg-*' -DataRoot $script:Temp | Out-Null
        (Get-PEScope -Name 'AADGroup' -DataRoot $script:Temp).Keys | Should -Be @('sg-*')
    }

    It 'refuses unsafe names and types, and an unknown scope' {
        { Set-PEScope -Name 'bad name' -Types 'AADGroup' -DataRoot $script:Temp } | Should -Throw
        { Set-PEScope -Name 'ok' -Types 'AAD Group;calc' -DataRoot $script:Temp } | Should -Throw
        { Get-PEScope -Name 'nope' -DataRoot $script:Temp } | Should -Throw '*not found*'
    }
}

Describe 'Invoke-PEScopeCheck' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-scope-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Temp | Out-Null
        # Blueprint: the mini export's records plus a CA policy that no export has.
        $records = @(InModuleScope PolicyEngine -Parameters @{ F = $script:Mini } {
                Read-PEExport -Path $F -TenantId 'tenant-1' | ForEach-Object { ConvertTo-PENormalizedRecord -Record $_ }
            })
        $gone = [pscustomobject]@{ ResourceType = 'AADConditionalAccessPolicy'; Key = 'Gone CA'; Workload = 'Entra ID'; Properties = [ordered]@{ DisplayName = 'Gone CA'; State = 'enabled' } }
        $state = InModuleScope PolicyEngine -Parameters @{ R = @($records + $gone) } {
            New-PEState -Records $R -NotChecked @() -Meta @{ TenantId = 'tenant-1'; ExportedAt = '2026-10-01T00:00:00Z' }
        }
        Initialize-PEBlueprint -Name 'main' -State $state -DataRoot $script:Temp | Out-Null
        # The base Full check: the enabled CA policy.
        $folder = New-ExportFolder -Root $script:Temp
        $script:Base = Invoke-PEFullCheck -BlueprintName 'main' -ExportScript { $folder }.GetNewClosure() -TargetTenantId 'tenant-1' -DataRoot $script:Temp
        Set-PEScope -Name 'ca' -Types 'AADConditionalAccessPolicy' -DataRoot $script:Temp | Out-Null
        Start-Sleep -Milliseconds 1100
    }

    AfterEach {
        Remove-Item $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 're-reads only the scope, replaces its findings and keeps the rest of the latest Full check' {
        $folder = New-ExportFolder -Root $script:Temp -CaDisabled
        $result = Invoke-PEScopeCheck -Scope 'ca' -BlueprintName 'main' -ExportScript { $folder }.GetNewClosure() -TargetTenantId 'tenant-1' -DataRoot $script:Temp
        $result.BasedOn | Should -Be $script:Base.CheckId
        $result.Drifted | Should -Be 2
        ($result.Findings | Where-Object Kind -EQ 'Changed').Key | Should -Be 'Require MFA'
        ($result.Findings | Where-Object Kind -EQ 'Missing').Key | Should -Be 'Gone CA'

        $merged = Get-PECheck -Latest -Kind Full -DataRoot $script:Temp
        $merged.CheckId | Should -Be $result.CheckId
        $merged.State.Meta.PatchedFrom | Should -Be $script:Base.CheckId
        $merged.State.Meta.ScopeChecks.ca | Should -Not -BeNullOrEmpty
        $merged.State.Meta.ExportedAt | Should -Be (Get-PECheck -CheckId $script:Base.CheckId -DataRoot $script:Temp).State.Meta.ExportedAt
        # Findings outside the scope are exactly the base's.
        $outside = @($merged.Findings | Where-Object ResourceType -NE 'AADConditionalAccessPolicy')
        $baseOutside = @($script:Base.Findings | Where-Object ResourceType -NE 'AADConditionalAccessPolicy')
        $outside.Count | Should -Be $baseOutside.Count
        # The CA record now holds the disabled state.
        (@($merged.State.Records | Where-Object { $_.ResourceType -eq 'AADConditionalAccessPolicy' -and $_.Key -eq 'Require MFA' })).Properties.State | Should -Be 'disabled'
    }

    It 'a key pattern narrows both the blueprint and the export to matching items' {
        Set-PEScope -Name 'mfa' -Types 'AADConditionalAccessPolicy' -Keys 'Require*' -DataRoot $script:Temp | Out-Null
        $folder = New-ExportFolder -Root $script:Temp -CaDisabled
        $result = Invoke-PEScopeCheck -Scope 'mfa' -BlueprintName 'main' -ExportScript { $folder }.GetNewClosure() -TargetTenantId 'tenant-1' -DataRoot $script:Temp
        @($result.Findings).Count | Should -Be 1
        $result.Findings[0].Key | Should -Be 'Require MFA'
        # 'Gone CA' is outside the pattern, so its Missing finding from the base check stays as it was.
        $merged = Get-PECheck -Latest -Kind Full -DataRoot $script:Temp
        @($merged.Findings | Where-Object { $_.Key -eq 'Gone CA' -and $_.Kind -eq 'Missing' }).Count | Should -Be 1
    }

    It 'a type the export log never mentions is NotChecked, never Missing' {
        $folder = New-ExportFolder -Root $script:Temp -LogText "Exporting Microsoft 365 configuration for Components: AADGroup`n[1/1] Extracting [AADGroup] using {CertificateThumbprint}...✅`n✅ Export completed successfully.`n"
        $result = Invoke-PEScopeCheck -Scope 'ca' -BlueprintName 'main' -ExportScript { $folder }.GetNewClosure() -TargetTenantId 'tenant-1' -DataRoot $script:Temp
        @($result.Findings | Where-Object Kind -EQ 'Missing').Count | Should -Be 0
        @($result.Findings | Where-Object Kind -EQ 'NotChecked').Count | Should -Be 1
        $result.NotChecked | Should -Be 1
    }

    It 'a key pattern still pairs a rename whose new name is outside the pattern' {
        # Blueprint has 'Sales Team'; the export has the same group as 'Sales' (outside the pattern 'Sales Team').
        $richFolder = New-ExportFolder -Root $script:Temp -RichSales
        $sales = @(InModuleScope PolicyEngine -Parameters @{ F = (Join-Path $richFolder 'export.ps1') } {
                Read-PEExport -Path $F -TenantId 'tenant-1' | ForEach-Object { ConvertTo-PENormalizedRecord -Record $_ } | Where-Object { $_.ResourceType -eq 'AADGroup' -and $_.Key -eq 'Sales' }
            })[0]
        $old = [pscustomobject]@{ ResourceType = 'AADGroup'; Key = 'Sales Team'; Workload = 'Entra ID'; Properties = [ordered]@{} }
        foreach ($property in $sales.Properties.GetEnumerator()) { $old.Properties[$property.Key] = $property.Value }
        $old.Properties['DisplayName'] = 'Sales Team'
        $state = InModuleScope PolicyEngine -Parameters @{ R = @($old) } {
            New-PEState -Records $R -NotChecked @() -Meta @{ TenantId = 'tenant-1'; ExportedAt = '2026-10-01T00:00:00Z' }
        }
        Initialize-PEBlueprint -Name 'renames' -State $state -DataRoot $script:Temp | Out-Null
        $folder = $richFolder
        Invoke-PEFullCheck -BlueprintName 'renames' -ExportScript { $folder }.GetNewClosure() -TargetTenantId 'tenant-1' -DataRoot $script:Temp | Out-Null
        Start-Sleep -Milliseconds 1100
        Set-PEScope -Name 'team' -Types 'AADGroup' -Keys 'Sales Team' -DataRoot $script:Temp | Out-Null
        $result = Invoke-PEScopeCheck -Scope 'team' -BlueprintName 'renames' -ExportScript { $folder }.GetNewClosure() -TargetTenantId 'tenant-1' -DataRoot $script:Temp
        ($result.Findings | Where-Object Key -EQ 'Sales Team').Kind | Should -Be 'PossibleRename'
        ($result.Findings | Where-Object Key -EQ 'Sales').Kind | Should -Be 'PossibleRename'
        @($result.Findings | Where-Object { $_.Key -eq 'Finance' }).Count | Should -Be 0
        # The merged check holds each half once.
        $merged = Get-PECheck -Latest -Kind Full -DataRoot $script:Temp
        @($merged.Findings | Where-Object { $_.Key -eq 'Sales' }).Count | Should -Be 1
    }
    It 'checks a DSC resource name without defining a scope' {
        if (@(& (Get-Module PolicyEngine) { Get-PEKnownResourceType }).Count -eq 0) { Set-ItResult -Skipped -Because 'Microsoft365DSC is not installed'; return }
        $folder = New-ExportFolder -Root $script:Temp -CaDisabled
        $result = Invoke-PEScopeCheck -Scope 'AADConditionalAccessPolicy' -BlueprintName 'main' -ExportScript { $folder }.GetNewClosure() -TargetTenantId 'tenant-1' -DataRoot $script:Temp
        $result.Scope | Should -Be 'AADConditionalAccessPolicy'
        $result.Drifted | Should -Be 2
        (Get-PECheck -Latest -Kind Full -DataRoot $script:Temp).State.Meta.ScopeChecks.AADConditionalAccessPolicy | Should -Not -BeNullOrEmpty
    }

    It 'refuses a scope whose types the blueprint has no item of, unless allowed' {
        Set-PEScope -Name 'locations' -Types 'AADNamedLocationPolicy' -DataRoot $script:Temp | Out-Null
        { Invoke-PEScopeCheck -Scope 'locations' -BlueprintName 'main' -DataRoot $script:Temp } | Should -Throw '*holds no item of AADNamedLocationPolicy*'
    }
    It 'two scope checks accumulate in ScopeChecks' {
        Set-PEScope -Name 'groups' -Types 'AADGroup' -DataRoot $script:Temp | Out-Null
        $folder = New-ExportFolder -Root $script:Temp
        Invoke-PEScopeCheck -Scope 'ca' -BlueprintName 'main' -ExportScript { $folder }.GetNewClosure() -TargetTenantId 'tenant-1' -DataRoot $script:Temp | Out-Null
        Start-Sleep -Milliseconds 1100
        Invoke-PEScopeCheck -Scope 'groups' -BlueprintName 'main' -ExportScript { $folder }.GetNewClosure() -TargetTenantId 'tenant-1' -DataRoot $script:Temp | Out-Null
        $merged = Get-PECheck -Latest -Kind Full -DataRoot $script:Temp
        @($merged.State.Meta.ScopeChecks.PSObject.Properties.Name | Sort-Object) | Should -Be @('ca', 'groups')
    }

    It 'throws without a Full check, for an unknown scope and for another blueprint' {
        { Invoke-PEScopeCheck -Scope 'nope' -BlueprintName 'main' -DataRoot $script:Temp } | Should -Throw '*not found*'
        $empty = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-scope-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $empty | Out-Null
        try
        {
            Copy-Item (Join-Path $script:Temp 'blueprints') $empty -Recurse
            Set-PEScope -Name 'ca' -Types 'AADConditionalAccessPolicy' -DataRoot $empty | Out-Null
            { Invoke-PEScopeCheck -Scope 'ca' -BlueprintName 'main' -DataRoot $empty } | Should -Throw '*No Full check*'
        }
        finally { Remove-Item $empty -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
