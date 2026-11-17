BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..\pipelines\scripts\Invoke-PipelineCompare.ps1'

    # Stand-ins for the scripts that touch tenants: each one records the arguments it got in <name>.args next to it.
    function New-Rig
    {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-cmp-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $dir 'config') | Out-Null
        $config = @{
            Dev     = "@{ TenantDomain = 'dev.onmicrosoft.com'; OrganizationName = 'dev.onmicrosoft.com'; KeyVault = 'dev-vault'; ShortName = 'dev'; ReaderAppId = '11111111-2222-3333-4444-555555555551'; WriterAppId = '11111111-2222-3333-4444-555555555552' }"
            PreProd = "@{ TenantDomain = 'preprod.onmicrosoft.com'; KeyVault = 'pre-vault'; ShortName = 'pre'; ReaderAppId = '11111111-2222-3333-4444-555555555553' }"
            Prod    = "@{ TenantDomain = 'prod.onmicrosoft.com'; KeyVault = 'prod-vault'; ShortName = 'prod'; ReaderAppId = '11111111-2222-3333-4444-555555555554' }"
        }
        foreach ($name in $config.Keys) { Set-Content (Join-Path $dir "config\$name.psd1") -Value $config[$name] }
        $record = '$args -join " " | Set-Content (Join-Path $PSScriptRoot ($MyInvocation.MyCommand.Name + ".args"))'
        Set-Content (Join-Path $dir 'connect.ps1') -Value ($record + "`n'ABABABABABABABABABABABABABABABABABABABAB'")
        Set-Content (Join-Path $dir 'compare.ps1') -Value ($record + "`n" + '$out = $args[$args.IndexOf("-OutputPath") + 1]; New-Item -ItemType Directory -Force $out | Out-Null; ''{"OpenFindings":2,"ByKind":"x","Manual":0}'' | Set-Content (Join-Path $out "summary.json")')
        Set-Content (Join-Path $dir 'report.ps1') -Value $record
        $dir
    }
    function Invoke-Compare
    {
        param ([string]$Rig, [hashtable]$Arguments = @{})
        $env:PE_TEST_HOOKS = '1'
        $out = Join-Path $Rig 'out'
        try
        {
            & $script:Script -SourceExportPath 'S' -TargetExportPath 'T' -OutputPath $out -PreProdRun '101' -DevRun '102' `
                -ConfigPath (Join-Path $Rig 'config') -ConnectScript (Join-Path $Rig 'connect.ps1') -CompareTool (Join-Path $Rig 'compare.ps1') -ReportTool (Join-Path $Rig 'report.ps1') @Arguments 6>&1 3>&1 | Out-Null
        }
        finally { Remove-Item Env:PE_TEST_HOOKS -ErrorAction SilentlyContinue }
        $out
    }
    function Get-Args { param ([string]$Rig, [string]$Name) $f = Join-Path $Rig "$Name.ps1.args"; if (Test-Path $f) { (Get-Content $f -Raw) } else { $null } }
}

Describe 'pipelines\scripts\Invoke-PipelineCompare.ps1 source and target tenant' {
    It 'the default call is PreProd to Dev: reads the Writer certificate, compiles, and builds an approvable report' {
        $rig = New-Rig
        $null = Invoke-Compare $rig
        (Get-Args $rig 'connect') | Should -Match '-Environment Dev -Role Writer -ThumbprintOnly'
        (Get-Args $rig 'compare') | Should -Match '-Compile'
        (Get-Args $rig 'compare') | Should -Match 'ABABABABAB'
        (Get-Args $rig 'report') | Should -Match '-SourceRun 101 -TargetRun 102'
        (Get-Args $rig 'report') | Should -Not -Match 'ReadOnlyReason'
    }

    It 'Prod to PreProd reads no certificate, runs no MOF compare, and builds a read-only report with its own summary' {
        $rig = New-Rig
        $out = Invoke-Compare $rig @{ SourceTenant = 'Prod'; TargetTenant = 'PreProd' }
        (Get-Args $rig 'connect') | Should -BeNullOrEmpty
        (Get-Args $rig 'compare') | Should -BeNullOrEmpty
        $report = Get-Args $rig 'report'
        $report | Should -Match '-ReadOnlyReason Read-only comparison'
        $report | Should -Match '-SourceLabel Prod'
        $report | Should -Match '-TargetLabel PreProd'
        $report | Should -Match '-TargetTenantDomain preprod\.onmicrosoft\.com'
        $summary = Get-Content (Join-Path $out 'summary.json') -Raw | ConvertFrom-Json
        $summary.SourceTenant | Should -Be 'Prod'
        $summary.TargetTenant | Should -Be 'PreProd'
        $summary.SourceExportRun | Should -Be '101'
        $summary.TargetExportRun | Should -Be '102'
    }

    It 'Prod to Dev is read-only too: no Writer certificate and no MOF compare' {
        $rig = New-Rig
        $null = Invoke-Compare $rig @{ SourceTenant = 'Prod'; TargetTenant = 'Dev' }
        (Get-Args $rig 'connect') | Should -BeNullOrEmpty
        (Get-Args $rig 'compare') | Should -BeNullOrEmpty
        (Get-Args $rig 'report') | Should -Match 'ReadOnlyReason'
    }

    It 'with -Workload AAD only AAD is complete, in the compare, the report and the summary (PreProd to Dev)' {
        $rig = New-Rig
        $out = Invoke-Compare $rig @{ Workload = 'AAD' }
        (Get-Args $rig 'compare') | Should -Match '-CompleteWorkload AAD\b(?!,)'
        (Get-Args $rig 'report') | Should -Match '-CompleteWorkload AAD\b(?!,)'
        (Get-Content (Join-Path $out 'summary.json') -Raw | ConvertFrom-Json).Workload | Should -Be 'AAD'
    }

    It 'with -Workload AAD the read-only report is complete for AAD only and the summary names the workload' {
        $rig = New-Rig
        $out = Invoke-Compare $rig @{ SourceTenant = 'Prod'; TargetTenant = 'PreProd'; Workload = 'AAD' }
        (Get-Args $rig 'report') | Should -Match '-CompleteWorkload AAD\b(?!,)'
        (Get-Content (Join-Path $out 'summary.json') -Raw | ConvertFrom-Json).Workload | Should -Be 'AAD'
    }

    It 'with Full (the default) the complete workloads are still the default list' {
        $rig = New-Rig
        $out = Invoke-Compare $rig
        (Get-Args $rig 'compare') | Should -Match '-CompleteWorkload AAD,Intune,EXO,Teams'
        (Get-Content (Join-Path $out 'summary.json') -Raw | ConvertFrom-Json).Workload | Should -Be 'Full'
    }

    It 'refuses a workload that is not letters and digits' {
        $rig = New-Rig
        { Invoke-Compare $rig @{ Workload = 'AAD; x' } } | Should -Throw
    }

    It 'the same tenant on both sides stops and names Tenant changes, before anything runs' {
        $rig = New-Rig
        { Invoke-Compare $rig @{ SourceTenant = 'Dev'; TargetTenant = 'Dev' } } | Should -Throw '*Tenant changes*'
        (Get-Args $rig 'report') | Should -BeNullOrEmpty
    }

    It 'refuses the test hooks unless PE_TEST_HOOKS is 1' {
        $rig = New-Rig
        { & $script:Script -SourceExportPath 'S' -TargetExportPath 'T' -OutputPath (Join-Path $rig 'o') -ConfigPath (Join-Path $rig 'config') } | Should -Throw '*test hooks*'
    }
}
