BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Tool = Join-Path $PSScriptRoot '..\tools\Invoke-PEApprovedBuild.ps1'
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures'

    function New-ExportCopy
    {
        param ([string]$Fixture, [string]$Log = '')
        $folder = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-ab-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Fixtures "upload\$Fixture") -Destination (Join-Path $folder 'export.ps1')
        Set-Content -LiteralPath (Join-Path $folder 'export.log') -Value $Log -Encoding utf8
        $folder
    }

    # Builds a world: two export folders, a list pinned to them, an output folder path that must stay empty when a guard stops the run.
    function New-World
    {
        param ([string]$SourceLog = '', [string]$TargetLog = '', [datetime]$TargetExportedAt = [datetime]::UtcNow, [string]$Tenant = 'dev', [object[]]$Item, [switch]$WrongTargetFingerprint)
        if (-not $Item) { $Item = @(@{ Action = 'Create'; ResourceType = 'AADGroup'; Key = 'Finance'; ExcludedProperties = @() }) }
        $source = New-ExportCopy 'entra.ps1' $SourceLog
        $target = New-ExportCopy 'entra-drift.ps1' $TargetLog
        $targetFp = if ($WrongTargetFingerprint) { 'f' * 64 } else { Get-PEExportFingerprint -Path $target }
        $list = New-PEApprovedList -Tenant $Tenant -ApprovedBy 'andrew' -ModuleVersion '2.26.1021.1' -Item $Item `
            -Source @{ Run = '101'; ExportedAt = '2026-11-03T10:00:00Z'; Fingerprint = (Get-PEExportFingerprint -Path $source) } `
            -Target @{ Run = '102'; ExportedAt = $TargetExportedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); Fingerprint = $targetFp }
        $listPath = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-ab-list-' + [guid]::NewGuid().ToString('N') + '.json')
        Save-PEApprovedList -List $list -Path $listPath
        [pscustomobject]@{ Source = $source; Target = $target; ListPath = $listPath; Out = (Join-Path ([System.IO.Path]::GetTempPath()) ('pe-ab-out-' + [guid]::NewGuid().ToString('N'))) }
    }
    function Invoke-Build
    {
        param ($World, [int]$MaxAgeDays = 7)
        $messages = & $script:Tool -ListPath $World.ListPath -SourceExportPath $World.Source -TargetExportPath $World.Target `
            -TargetTenantDomain 'contoso-dev.onmicrosoft.com' -OutputPath $World.Out -MaxAgeDays $MaxAgeDays -NoCompile 6>&1 3>$null
        @($messages | ForEach-Object { "$_" })
    }
    function Assert-Stopped
    {
        param ([scriptblock]$Run, [string]$Pattern, $World)
        $thrown = $null
        try { & $Run | Out-Null } catch { $thrown = $_.Exception.Message }
        $thrown | Should -Not -BeNullOrEmpty
        $thrown | Should -Match $Pattern
        (Test-Path -LiteralPath $World.Out) -and @(Get-ChildItem -LiteralPath $World.Out -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0 | Should -BeFalse
    }
}

Describe 'tools\Invoke-PEApprovedBuild.ps1 run-level guards' {
    It 'stops on a Dev export that is not the one the list names (fingerprint) and writes nothing' {
        $w = New-World -WrongTargetFingerprint
        Assert-Stopped { Invoke-Build $w } 'fingerprint' $w
    }

    It 'stops on an incomplete export and names the failed component' {
        $log = Get-Content (Join-Path $script:Fixtures 'export-log.txt') -Raw
        $w = New-World -TargetLog $log
        Assert-Stopped { Invoke-Build $w } 'EXOFocusedInbox' $w
    }

    It 'stops on a Graph shortfall line' {
        $w = New-World -SourceLog "WARNING: [/deviceManagement/configurationPolicies] Graph reported 100 items but only 0 were returned (100% shortfall).`n"
        Assert-Stopped { Invoke-Build $w } 'Graph reported 100 items but only 0' $w
    }

    It 'stops when an export has no export.log' {
        $w = New-World
        Remove-Item -LiteralPath (Join-Path $w.Target 'export.log')
        Assert-Stopped { Invoke-Build $w } 'export\.log' $w
    }

    It 'stops when the Dev export is older than MaxAgeDays' {
        $w = New-World -TargetExportedAt ([datetime]::UtcNow.AddDays(-30))
        Assert-Stopped { Invoke-Build $w } 'older than|days old' $w
    }

    It 'stops when the list is for another tenant than the one this pipeline applies to' {
        $w = New-World -Tenant 'contoso'
        Assert-Stopped { Invoke-Build $w } "tenant 'contoso'" $w
    }
}

Describe 'tools\Invoke-PEApprovedBuild.ps1 output' -Tag 'Slow' {
    It 'accepts a Dev export within MaxAgeDays' {
        $w = New-World -TargetExportedAt ([datetime]::UtcNow.AddDays(-6))
        { Invoke-Build $w } | Should -Not -Throw
    }

    It 'writes outcomes, summary and one script per type and phase' {
        $w = New-World -Item @(
            @{ Action = 'Create'; ResourceType = 'AADGroup'; Key = 'Finance'; ExcludedProperties = @() }
            @{ Action = 'Remove'; ResourceType = 'AADGroup'; Key = 'Marketing'; ExcludedProperties = @() })
        Invoke-Build $w | Out-Null
        $files = @(Get-ChildItem -LiteralPath $w.Out -File | ForEach-Object Name | Sort-Object)
        $files | Should -Contain 'outcomes.json'
        $files | Should -Contain 'summary.json'
        $files | Should -Contain '01-AADGroup-Changes.ps1'
        $files | Should -Contain '02-AADGroup-Removals.ps1'
        $outcomes = Get-Content (Join-Path $w.Out 'outcomes.json') -Raw | ConvertFrom-Json
        @($outcomes | Where-Object Outcome -EQ 'ToApply').Count | Should -Be 2
        (Get-Content (Join-Path $w.Out '01-AADGroup-Changes.ps1') -Raw) | Should -BeLike '*Configuration PE_AADGroup_Changes*'
    }

    It 'summary lines show per type and action counts, and the outcome totals add up to the approved items' {
        $w = New-World -Item @(
            @{ Action = 'Create'; ResourceType = 'AADGroup'; Key = 'Finance'; ExcludedProperties = @() }
            @{ Action = 'Update'; ResourceType = 'AADGroup'; Key = 'Sales'; ExcludedProperties = @() }
            @{ Action = 'Create'; ResourceType = 'AADGroup'; Key = 'Sales'; ExcludedProperties = @() })
        $messages = Invoke-Build $w
        $summary = Get-Content (Join-Path $w.Out 'summary.json') -Raw | ConvertFrom-Json
        @($summary.Lines) | Should -Contain 'Create 2 AADGroup'
        @($summary.Lines) | Should -Contain 'Update 1 AADGroup'
        ($messages -join "`n") | Should -Match 'Create 2 AADGroup'
        $total = $summary.Totals.ToApply + $summary.Totals.NoActionRequired + $summary.Totals.Skipped + $summary.Totals.NotGenerated
        $total | Should -Be 3
        $summary.Totals.Skipped | Should -Be 1
    }
}
