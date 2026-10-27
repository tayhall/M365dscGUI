BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Mini = Join-Path $PSScriptRoot 'fixtures\mini-export.ps1'
    $script:LogFixture = Join-Path $PSScriptRoot 'fixtures\export-log.txt'

    function New-TestRecord
    {
        param ([string]$Type, [string]$Key, [hashtable]$Props = @{})
        $p = [ordered]@{ Identity = $Key }
        foreach ($k in $Props.Keys) { $p[$k] = $Props[$k] }
        [pscustomobject]@{ ResourceType = $Type; Key = $Key; Workload = 'Exchange Online'; TenantId = 'tenant-1'; Properties = $p }
    }

    function New-ExportFolder
    {
        # A fake export: the mini export plus (optionally) the fixture log.
        param ([string]$Root, [switch]$NoLog)
        $folder = Join-Path $Root ('export-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        Copy-Item $script:Mini (Join-Path $folder 'export.ps1')
        if (-not $NoLog)
        {
            Copy-Item $script:LogFixture (Join-Path $folder 'export.log')
        }
        return $folder
    }
}

Describe 'Invoke-PEFullCheck' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Temp | Out-Null
        # Blueprint: the mini export's records, plus one record per EXO type from the fixture log.
        $records = @(InModuleScope PolicyEngine -Parameters @{ F = $script:Mini } {
                Read-PEExport -Path $F -TenantId 'tenant-1' | ForEach-Object { ConvertTo-PENormalizedRecord -Record $_ }
            })
        $records += New-TestRecord -Type 'EXOFocusedInbox' -Key 'default'
        $records += New-TestRecord -Type 'EXOAcceptedDomain' -Key 'contoso.com'
        $state = InModuleScope PolicyEngine -Parameters @{ R = $records } {
            New-PEState -Records $R -NotChecked @() -Meta @{ TenantId = 'tenant-1'; ExportedAt = '2026-10-01T00:00:00Z' }
        }
        Initialize-PEBlueprint -Name 'main' -State $state -DataRoot $script:Temp | Out-Null
        $script:ExportFolder = New-ExportFolder -Root $script:Temp
        $folder = $script:ExportFolder
        $script:Fake = { $folder }.GetNewClosure()
    }

    AfterEach {
        if (Test-Path $script:Temp)
        {
            Remove-Item $script:Temp -Recurse -Force
        }
    }

    It 'puts failed components in NotChecked and not in Missing' {
        # The fixture log's failing component (EXOFocusedInbox) is also in Data\ExcludedTypes.psd1; with no exclusions
        # it must be a plain NotChecked finding.
        Mock -ModuleName PolicyEngine Get-PEExcludedTypeMap { , [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase) }
        $result = Invoke-PEFullCheck -BlueprintName 'main' -ExportScript $script:Fake -DataRoot $script:Temp
        $result.State.NotChecked.ResourceType | Should -Contain 'EXOFocusedInbox'
        ($result.State.NotChecked | Where-Object ResourceType -eq 'EXOFocusedInbox').Reason | Should -BeLike '*not recognized*'
        @($result.Findings | Where-Object { $_.ResourceType -eq 'EXOFocusedInbox' -and $_.Kind -eq 'Missing' }).Count | Should -Be 0
        @($result.Findings | Where-Object { $_.ResourceType -eq 'EXOFocusedInbox' -and $_.Kind -eq 'NotChecked' }).Count | Should -Be 1
    }

    It 'reports a failed component that is also an excluded type as Excluded only (Excluded wins over NotChecked)' {
        $result = Invoke-PEFullCheck -BlueprintName 'main' -ExportScript $script:Fake -DataRoot $script:Temp
        $result.State.NotChecked.ResourceType | Should -Contain 'EXOFocusedInbox'
        @($result.Findings | Where-Object { $_.ResourceType -eq 'EXOFocusedInbox' }).Kind | Should -Be @('Excluded')
    }

    It 'a component that exported with no instances makes its blueprint records Missing' {
        $result = Invoke-PEFullCheck -BlueprintName 'main' -ExportScript $script:Fake -DataRoot $script:Temp
        $missing = @($result.Findings | Where-Object { $_.ResourceType -eq 'EXOAcceptedDomain' -and $_.Kind -eq 'Missing' })
        $missing.Count | Should -Be 1
        $result.State.NotChecked.ResourceType | Should -Not -Contain 'EXOAcceptedDomain'
    }

    It 'writes result.json with findings, the target state and the export time' {
        $result = Invoke-PEFullCheck -BlueprintName 'main' -ExportScript $script:Fake -DataRoot $script:Temp
        $result.CheckId | Should -Match '^\d{8}-\d{6}$'
        $file = Join-Path $script:Temp "checks\$($result.CheckId)\result.json"
        Test-Path $file | Should -BeTrue
        $saved = Get-Content $file -Raw | ConvertFrom-Json -Depth 20 -DateKind String
        $saved.Kind | Should -Be 'Full'
        $saved.BlueprintName | Should -Be 'main'
        $saved.BlueprintVersion | Should -Be 1
        $saved.Path | Should -Be $script:ExportFolder
        $saved.Findings.Count | Should -Be $result.Findings.Count
        $saved.State.Records.Count | Should -Be 4
        $saved.State.Meta.TenantId | Should -Not -BeNullOrEmpty
        $saved.State.Meta.ExportedAt | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
        $saved.State.NotChecked[0].ResourceType | Should -Be 'EXOFocusedInbox'
    }

    It 'does not store ignored properties such as ids and credentials in the state' {
        $result = Invoke-PEFullCheck -BlueprintName 'main' -ExportScript $script:Fake -DataRoot $script:Temp
        $text = Get-Content (Join-Path $script:Temp "checks\$($result.CheckId)\result.json") -Raw
        $text | Should -Not -Match '11111111-1111-1111-1111-111111111111'
    }

    It 'two checks in the same second get different CheckIds' {
        $a = Invoke-PEFullCheck -BlueprintName 'main' -ExportScript $script:Fake -DataRoot $script:Temp
        $b = Invoke-PEFullCheck -BlueprintName 'main' -ExportScript $script:Fake -DataRoot $script:Temp
        $b.CheckId | Should -Not -Be $a.CheckId
        $b.CheckId | Should -BeGreaterThan $a.CheckId
    }

    Context 'without an export log' {
        BeforeEach {
            $script:NoLogFolder = New-ExportFolder -Root $script:Temp -NoLog
            $folder = $script:NoLogFolder
            $script:FakeNoLog = { $folder }.GetNewClosure()
        }

        It 'records types the blueprint has and the export lacks as NotChecked, not Missing' {
            $result = Invoke-PEFullCheck -BlueprintName 'main' -ExportScript $script:FakeNoLog -DataRoot $script:Temp
            foreach ($type in 'EXOFocusedInbox', 'EXOAcceptedDomain')
            {
                $entry = $result.State.NotChecked | Where-Object ResourceType -eq $type
                $entry.Reason | Should -Be 'no export log'
                @($result.Findings | Where-Object { $_.ResourceType -eq $type -and $_.Kind -eq 'Missing' }).Count | Should -Be 0
            }
            $result.State.Meta.ExportLog | Should -Be 'missing'
        }

        It 'still compares types that have records in the export' {
            $result = Invoke-PEFullCheck -BlueprintName 'main' -ExportScript $script:FakeNoLog -DataRoot $script:Temp
            $result.State.NotChecked.ResourceType | Should -Not -Contain 'AADGroup'
        }
    }

    It 'stamps the target with its own tenant id, never the blueprint tenant id' {
        $result = Invoke-PEFullCheck -BlueprintName 'main' -ExportScript $script:Fake -DataRoot $script:Temp -TargetTenantId 'target-tenant'
        $result.State.Meta.TenantId | Should -Be 'target-tenant'
        @($result.State.Records.TenantId | Sort-Object -Unique) | Should -Be @('target-tenant')
        $saved = Get-Content (Join-Path $script:Temp "checks\$($result.CheckId)\result.json") -Raw | ConvertFrom-Json -Depth 20
        $saved.State.Meta.TenantId | Should -Be 'target-tenant'
        $saved.State.Meta.TenantId | Should -Not -Be 'tenant-1'
    }

    It 'uses unknown when the target tenant id is not available' {
        $result = Invoke-PEFullCheck -BlueprintName 'main' -ExportScript $script:Fake -DataRoot $script:Temp
        $result.State.Meta.TenantId | Should -Be 'unknown'
    }

    It 'has no Role parameter (checks are Reader-only)' {
        (Get-Command Invoke-PEFullCheck).Parameters.Keys | Should -Not -Contain 'Role'
    }

    It 'puts an Incomplete component in NotChecked with the incomplete reason' {
        $log = Join-Path $script:ExportFolder 'export.log'
        [System.IO.File]::WriteAllText($log, "[1/2] Extracting [AADGroup] using {Cert}...`r`n[2/2] Extracting [EXOFocusedInbox] using {Cert}...`r`n")
        $result = Invoke-PEFullCheck -BlueprintName 'main' -ExportScript $script:Fake -DataRoot $script:Temp
        foreach ($type in 'AADGroup', 'EXOFocusedInbox')
        {
            ($result.State.NotChecked | Where-Object ResourceType -eq $type).Reason | Should -Be 'export log incomplete'
        }
    }

    It 'stores log warnings in result.json as LogWarnings' {
        $log = Join-Path $script:ExportFolder 'export.log'
        [System.IO.File]::WriteAllText($log, "[1/2] Extracting [AADGroup] using {Cert}...`r`n[2/2] Extracting [EXOFocusedInbox] using {Cert}...`r`n    An error occurred while exporting resource {AADGroup}: forged`r`n")
        $result = Invoke-PEFullCheck -BlueprintName 'main' -ExportScript $script:Fake -DataRoot $script:Temp
        @($result.LogWarnings).Count | Should -Be 1
        $saved = Get-Content (Join-Path $script:Temp "checks\$($result.CheckId)\result.json") -Raw | ConvertFrom-Json -Depth 20
        @($saved.LogWarnings)[0] | Should -BeLike "*'AADGroup'*"
        ($result.State.NotChecked | Where-Object ResourceType -eq 'AADGroup').Reason | Should -Be 'export log incomplete'
    }

    It 'never stores CertificatePassword or ApplicationSecret values' {
        $text = (Get-Content $script:Mini -Raw).Replace('DisplayName           = "Sales";', 'DisplayName           = "Sales";' + "`n            CertificatePassword   = `"hunter2-secret`";`n            ApplicationSecret     = `"s3cr3t-value`";")
        $text | Should -BeLike '*hunter2-secret*'
        [System.IO.File]::WriteAllText((Join-Path $script:ExportFolder 'export.ps1'), $text)
        $result = Invoke-PEFullCheck -BlueprintName 'main' -ExportScript $script:Fake -DataRoot $script:Temp
        $json = Get-Content (Join-Path $script:Temp "checks\$($result.CheckId)\result.json") -Raw
        $json | Should -Not -Match 'hunter2-secret|s3cr3t-value|CertificatePassword|ApplicationSecret'
    }

    It 'fails when the export folder has no export file' {
        $empty = Join-Path $script:Temp 'empty'
        New-Item -ItemType Directory -Path $empty | Out-Null
        $script:EmptyFolder = $empty
        { Invoke-PEFullCheck -BlueprintName 'main' -ExportScript { $script:EmptyFolder } -DataRoot $script:Temp } | Should -Throw '*export file*'
    }
}
