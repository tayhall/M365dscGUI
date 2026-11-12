BeforeAll {
    $script:Apply = Join-Path $PSScriptRoot '..\pipelines\scripts\Invoke-PipelineApply.ps1'
    $script:Generator = Join-Path $PSScriptRoot '..\pipelines\scripts\New-PipelineYaml.ps1'

    # A report folder with a summary.json and a ConfigurationData.psd1 whose thumbprint is NOT valid: a run that gets past the tenant check
    # stops there, before anything connects to a tenant.
    function New-Report
    {
        param ([hashtable]$Summary)
        $folder = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-pat-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        $base = @{ MofLayout = 'Combined'; OpenFindings = 1; ByKind = 'TargetOnly=1'; GeneratedAtUtc = '2026-11-12 10:00' }
        foreach ($k in $Summary.Keys) { $base[$k] = $Summary[$k] }
        $base | ConvertTo-Json | Set-Content (Join-Path $folder 'summary.json')
        "@{ NonNodeData = @{ CertificateThumbprint = 'not-a-thumbprint' } }" | Set-Content (Join-Path $folder 'ConfigurationData.psd1')
        $folder
    }
    # The text the script wrote, and the error it stopped with.
    function Invoke-Apply
    {
        param ($Report, [switch]$RequireTenant)
        $lines = & {
            try { & $script:Apply -ReportPath $Report -Mode Test -RequireTenant:$RequireTenant }
            catch { "THROWN: $($_.Exception.Message)" }
        } *>&1
        @($lines | ForEach-Object { "$_" })
    }
}

Describe 'pipelines\scripts\Invoke-PipelineApply.ps1 tenant check' {
    It 'refuses a report of another tenant before anything is connected' {
        $out = (Invoke-Apply (New-Report @{ Tenant = 'PreProd' })) -join "`n"
        $out | Should -Match "THROWN: .*tenant 'PreProd'.*applies to Dev"
        $out | Should -Not -Match 'thumbprint'
    }

    It 'takes a report of Dev, and then goes on to the next check' {
        $out = (Invoke-Apply (New-Report @{ Tenant = 'Dev' })) -join "`n"
        $out | Should -Match 'No valid certificate thumbprint'
        $out | Should -Not -Match 'applies to Dev'
    }

    It 'takes a compare report that has no Tenant, as before' {
        $out = (Invoke-Apply (New-Report @{})) -join "`n"
        $out | Should -Match 'No valid certificate thumbprint'
    }

    It 'with -RequireTenant refuses a report that has no Tenant' {
        (Invoke-Apply (New-Report @{}) -RequireTenant) -join "`n" | Should -Match 'THROWN: .*has no tenant'
    }

    It 'with -RequireTenant takes a report of Dev' {
        (Invoke-Apply (New-Report @{ Tenant = 'Dev' }) -RequireTenant) -join "`n" | Should -Match 'No valid certificate thumbprint'
    }

    It 'says which two exports a tenant-changes report compares' {
        $out = (Invoke-Apply (New-Report @{ Tenant = 'Dev'; PreviousName = 'v8'; PreviousRun = '101'; LatestName = 'v9'; LatestRun = '102' })) -join "`n"
        $out | Should -Match 'Tenant changes of Dev: previous v8 \(run 101\), latest v9 \(run 102\)'
    }
}

Describe 'Apply-Dev.yaml and the tenant-changes revert' {
    BeforeAll {
        $settings = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-pat-set-' + [guid]::NewGuid().ToString('N') + '.psd1')
        Set-Content $settings -Value "@{ Pool = 'Agents'; DevServiceConnection = 'sc-dev'; PreProdServiceConnection = 'sc-preprod'; ExportPreProdPipelineId = '21'; ExportDevPipelineId = '22' }"
        $out = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-pat-out-' + [guid]::NewGuid().ToString('N'))
        & $script:Generator -SettingsPath $settings -OutputPath $out 6>&1 3>$null | Out-Null
        $script:Text = Get-Content (Join-Path $out 'Apply-Dev.yaml') -Raw
    }

    It 'is generated with every token filled and has both pipeline resources' {
        $script:Text | Should -Not -Match '__[A-Z][A-Z_]*__'
        $script:Text | Should -Match "(?s)pipeline: compare\s+source: 'M365DSC - Compare PreProd to Dev and build MOFs'"
        $script:Text | Should -Match "(?s)pipeline: tenantChanges\s+source: 'M365DSC - Tenant changes'"
    }

    It 'has a source parameter, Compare by default, that is chosen when the YAML is compiled' {
        $script:Text | Should -Match "(?s)- name: source\s+displayName: [^\r\n]+\s+type: string\s+default: Compare\s+values:\s+- Compare\s+- TenantChanges"
        $script:Text | Should -Match "if eq\(parameters\.source, 'TenantChanges'\)"
        $script:Text | Should -Match 'download: tenantChanges'
        $script:Text | Should -Match 'download: compare'
    }

    It 'applies the Revert folder of a tenant-changes run and requires its tenant, passing the choices as environment variables' {
        $script:Text | Should -Match "tenantChanges/TenantChanges/Revert"
        $script:Text | Should -Match "PE_REQUIRE_TENANT: 'True'"
        $script:Text | Should -Match "compare/DriftReport"
        $script:Text | Should -Match "PE_REQUIRE_TENANT: 'False'"
    }
}
