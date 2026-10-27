BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Mini = Join-Path $PSScriptRoot 'fixtures\mini-export.ps1'
    $script:LogFixture = Join-Path $PSScriptRoot 'fixtures\export-log.txt'
}

Describe 'Module source parses' {
    It 'every module and tool script parses without errors' {
        $root = Join-Path $PSScriptRoot '..'
        $files = @(Get-ChildItem (Join-Path $root 'src\PolicyEngine') -Recurse -Filter '*.ps1') + @(Get-Item (Join-Path $root 'tools\New-PEBlueprint.ps1'))
        foreach ($file in $files)
        {
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
            @($errors).Count | Should -Be 0 -Because $file.FullName
        }
    }

    It 'imports the module in a fresh process with no errors' {
        $manifest = Join-Path $PSScriptRoot '..\src\PolicyEngine\PolicyEngine.psd1'
        $output = & pwsh -NoProfile -Command "`$ErrorActionPreference = 'Stop'; Import-Module '$manifest' -Force; `$Error.Count" 2>&1
        $LASTEXITCODE | Should -Be 0
        [string]@($output)[-1] | Should -Be '0'
        Get-Command New-PEStateFromExport -Module PolicyEngine | Should -Not -BeNullOrEmpty
    }
}

Describe 'New-PEStateFromExport' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Temp | Out-Null
        Copy-Item $script:Mini (Join-Path $script:Temp 'export.ps1')
    }

    AfterEach {
        Remove-Item $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'reads the records, normalised, with the tenant id given' {
        Copy-Item $script:LogFixture (Join-Path $script:Temp 'export.log')
        $state = New-PEStateFromExport -Path $script:Temp -TenantId 'tenant-1'
        @($state.Records | Where-Object ResourceType -eq 'AADGroup').Count | Should -Be 3
        @($state.Records | Where-Object ResourceType -eq 'AADConditionalAccessPolicy').Count | Should -Be 1
        $state.Records[0].TenantId | Should -Be 'tenant-1'
        # Ignored properties (ids, credentials) are removed by normalisation.
        foreach ($record in $state.Records)
        {
            $record.Properties.Keys | Should -Not -Contain 'CertificateThumbprint'
        }
    }

    It 'puts failed components in NotChecked with the reason' {
        Copy-Item $script:LogFixture (Join-Path $script:Temp 'export.log')
        $state = New-PEStateFromExport -Path $script:Temp -TenantId 'tenant-1'
        @($state.NotChecked).Count | Should -Be 1
        $state.NotChecked[0].ResourceType | Should -Be 'EXOFocusedInbox'
        $state.NotChecked[0].Reason | Should -BeLike '*not recognized*'
    }

    It 'records the source, export time and log status in Meta' {
        Copy-Item $script:LogFixture (Join-Path $script:Temp 'export.log')
        $state = New-PEStateFromExport -Path $script:Temp -TenantId 'tenant-1'
        $state.Meta.Source | Should -Be $script:Temp
        $state.Meta.ExportLog | Should -Be 'present'
        $state.Meta.ExportedAt | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
        $state.Meta.TenantId | Should -Be 'tenant-1'
    }

    It 'throws without export.log unless -AllowMissingLog' {
        { New-PEStateFromExport -Path $script:Temp -TenantId 'tenant-1' } | Should -Throw '*No export.log*'
        $state = New-PEStateFromExport -Path $script:Temp -TenantId 'tenant-1' -AllowMissingLog
        $state.Meta.ExportLog | Should -Be 'missing'
        @($state.Records).Count | Should -BeGreaterThan 0
    }

    It 'drops records of a failed component' {
        $log = Get-Content $script:LogFixture -Raw
        # Make AADGroup the failed component: its records must not reach the state.
        $log = $log -replace '(?m)^    \|---\[2/2\] Finance✅', "    |---[2/2] Finance❌`n    An error occurred while exporting resource {AADGroup}: boom"
        Set-Content -LiteralPath (Join-Path $script:Temp 'export.log') -Value $log -NoNewline
        $state = New-PEStateFromExport -Path $script:Temp -TenantId 'tenant-1'
        $state.NotChecked.ResourceType | Should -Contain 'AADGroup'
        @($state.Records | Where-Object ResourceType -eq 'AADGroup').Count | Should -Be 0
    }

    It 'a blueprint built from it compares aligned with a full check of the same export' {
        Copy-Item $script:LogFixture (Join-Path $script:Temp 'export.log')
        $state = New-PEStateFromExport -Path $script:Temp -TenantId 'tenant-1'
        $data = Join-Path $script:Temp 'data'
        Initialize-PEBlueprint -Name 'bp' -State $state -DataRoot $data | Should -Be 1
        $folder = $script:Temp
        $result = Invoke-PEFullCheck -BlueprintName 'bp' -ExportScript { $folder }.GetNewClosure() -TargetTenantId 'tenant-1' -DataRoot $data
        @($result.Findings | Where-Object Kind -in 'Missing', 'Changed', 'TargetOnly', 'PossibleRename').Count | Should -Be 0
        @($result.Findings | Where-Object { $_.ResourceType -eq 'EXOFocusedInbox' -and $_.Kind -eq 'Missing' }).Count | Should -Be 0
    }
}
