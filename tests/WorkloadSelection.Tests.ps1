BeforeAll {
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    $script:selector = Join-Path $repoRoot 'pipelines\scripts\Get-WorkloadSelection.ps1'

    function script:Clear-WorkloadEnv
    {
        foreach ($name in @([Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -like 'PE_WL_*' }))
        {
            Remove-Item -LiteralPath "Env:$name"
        }
    }
}

Describe 'Get-WorkloadSelection.ps1' {
    BeforeEach {
        $script:saved = @{}
        foreach ($name in @([Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -like 'PE_WL_*' }))
        {
            $script:saved[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        Clear-WorkloadEnv
        $script:list = Join-Path $TestDrive 'Workloads.psd1'
        Set-Content -LiteralPath $script:list -Value "@{ Workloads = @( @{ Prefix = 'B1' }, @{ Prefix = 'A2' }, @{ Prefix = 'C3' } ) }"
    }
    AfterEach {
        Clear-WorkloadEnv
        foreach ($name in $script:saved.Keys) { Set-Item -LiteralPath "Env:$name" -Value $script:saved[$name] }
    }

    It 'returns the ticked prefixes in Workloads.psd1 order' {
        $env:PE_WL_C3 = 'True'
        $env:PE_WL_B1 = 'True'
        & $selector -WorkloadsPath $list | Should -Be 'B1,C3'
    }

    It 'reads True case-insensitively and ignores any other value' {
        $env:PE_WL_B1 = 'true'
        $env:PE_WL_A2 = 'False'
        $env:PE_WL_C3 = 'yes'
        & $selector -WorkloadsPath $list | Should -Be 'B1'
    }

    It 'throws when nothing is ticked' {
        $env:PE_WL_B1 = 'False'
        { & $selector -WorkloadsPath $list } | Should -Throw 'No workload is ticked. Tick at least one workload.'
    }

    It 'returns an empty string with -AllowNone' {
        $result = & $selector -WorkloadsPath $list -AllowNone
        $result | Should -BeOfType [string]
        $result | Should -Be ''
    }

    It 'ignores PE_WL_ variables that are not in the workload list' {
        $env:PE_WL_Nope = 'True'
        $env:PE_WL_A2 = 'True'
        & $selector -WorkloadsPath $list | Should -Be 'A2'
    }

    It 'picks up a workload added to the list without any other change' {
        $env:PE_WL_D4 = 'True'
        Set-Content -LiteralPath $list -Value "@{ Workloads = @( @{ Prefix = 'B1' }, @{ Prefix = 'D4' } ) }"
        & $selector -WorkloadsPath $list | Should -Be 'D4'
    }

    It 'uses the repo Workloads.psd1 by default' {
        $env:PE_WL_AAD = 'True'
        & $selector | Should -Be 'AAD'
    }
}

Describe 'Invoke-PipelineExport.ps1 workload picker' {
    BeforeEach {
        $script:savedPicker = $env:PE_WORKLOAD
        Remove-Item Env:PE_WORKLOAD -ErrorAction SilentlyContinue

        # A copy of the script in a temp tree whose connect, disconnect and export steps are stubs that write marker lines.
        $script:tree = Join-Path $TestDrive 'repo'
        $scripts = New-Item -ItemType Directory -Path (Join-Path $tree 'pipelines\scripts') -Force
        New-Item -ItemType Directory -Path (Join-Path $tree 'tools'), (Join-Path $tree 'src\PolicyEngine\Data') -Force | Out-Null
        Copy-Item (Join-Path $repoRoot 'pipelines\scripts\Invoke-PipelineExport.ps1'), (Join-Path $repoRoot 'pipelines\scripts\Resolve-WorkloadChoice.ps1') -Destination $scripts
        Copy-Item (Join-Path $repoRoot 'src\PolicyEngine\Data\Workloads.psd1') -Destination (Join-Path $tree 'src\PolicyEngine\Data')
        Set-Content (Join-Path $scripts 'Connect-PipelineTenant.ps1') 'param($Environment, $Role) "CONNECT"'
        Set-Content (Join-Path $scripts 'Disconnect-PipelineTenant.ps1') 'param($Slug, $Role) "DISCONNECT"'
        Set-Content (Join-Path $tree 'tools\Export-M365DscTenant.ps1') 'param($Role, $Tenant, $Workloads, $OutputPath) "EXPORT:$Workloads"'
        $script:exportScript = Join-Path $scripts 'Invoke-PipelineExport.ps1'
    }
    AfterEach { if ($null -eq $script:savedPicker) { Remove-Item Env:PE_WORKLOAD -ErrorAction SilentlyContinue } else { $env:PE_WORKLOAD = $script:savedPicker } }

    It 'exports the one workload the picker names' {
        $env:PE_WORKLOAD = 'AAD'
        (@(& $exportScript -Environment Dev -OutputPath (Join-Path $TestDrive 'out'))) | Should -Contain 'EXPORT:AAD'
    }

    It 'exports every default workload for Full, and for no picker at all' {
        $env:PE_WORKLOAD = 'Full'
        (@(& $exportScript -Environment Dev -OutputPath (Join-Path $TestDrive 'out'))) | Should -Contain 'EXPORT:AAD,Intune,EXO,Teams'
        Remove-Item Env:PE_WORKLOAD
        (@(& $exportScript -Environment Dev -OutputPath (Join-Path $TestDrive 'out'))) | Should -Contain 'EXPORT:AAD,Intune,EXO,Teams'
    }

    It 'stops before it connects to the tenant when the picker is not a workload' {
        $env:PE_WORKLOAD = 'Exchange'
        $out = @()
        $thrown = $null
        try { $out = @(& $exportScript -Environment Dev -OutputPath (Join-Path $TestDrive 'out')) } catch { $thrown = $_ }
        $thrown.Exception.Message | Should -Match 'Exchange.*Full, AAD'
        ($out -join ' ') | Should -Not -Match 'CONNECT|EXPORT'
    }

    It 'lets a typed -Workloads win over the picker' {
        $env:PE_WORKLOAD = 'AAD'
        (@(& $exportScript -Environment Dev -Workloads 'EXO,SC' -OutputPath (Join-Path $TestDrive 'out'))) | Should -Contain 'EXPORT:EXO,SC'
    }
}

Describe 'Invoke-PipelineCompare.ps1 workload selection' {
    BeforeEach {
        $script:saved = @{}
        foreach ($name in @([Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -like 'PE_WL_*' }))
        {
            $script:saved[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        Clear-WorkloadEnv

        # The compare script in a temp tree with stubs that echo the complete-workload list they receive.
        $script:tree = Join-Path $TestDrive 'repo'
        $scripts = New-Item -ItemType Directory -Path (Join-Path $tree 'pipelines\scripts') -Force
        New-Item -ItemType Directory -Path (Join-Path $tree 'tools'), (Join-Path $tree 'src\PolicyEngine\Data') -Force | Out-Null
        Copy-Item (Join-Path $repoRoot 'pipelines\scripts\Invoke-PipelineCompare.ps1'), $selector -Destination $scripts
        Copy-Item (Join-Path $repoRoot 'src\PolicyEngine\Data\Workloads.psd1') -Destination (Join-Path $tree 'src\PolicyEngine\Data')
        Set-Content (Join-Path $scripts 'Get-PipelineConfig.ps1') '[pscustomobject]@{ TenantDomain = ''d.example''; OrganizationName = ''d.example''; WriterAppId = ''x'' }'
        Set-Content (Join-Path $scripts 'Connect-PipelineTenant.ps1') 'param($Environment, $Role, [switch]$ThumbprintOnly) ''THUMB'''
        Set-Content (Join-Path $tree 'tools\Invoke-PEPipelineCompare.ps1') @'
param($SourceExportPath, $TargetExportPath, $OutputPath, $TargetTenantDomain, $CompleteWorkload, $MofLayout, [switch]$Compile, $ApplicationId, $CertificateThumbprint, $OrganizationName)
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
Set-Content (Join-Path $OutputPath 'complete.txt') ('[' + $CompleteWorkload + ']')
'{"OpenFindings":0,"ByKind":"","Manual":0}' | Set-Content (Join-Path $OutputPath 'summary.json')
'@
        $script:compareScript = Join-Path $scripts 'Invoke-PipelineCompare.ps1'
        $script:outDir = Join-Path $TestDrive 'cmp'
    }
    AfterEach {
        Clear-WorkloadEnv
        foreach ($name in $script:saved.Keys) { Set-Item -LiteralPath "Env:$name" -Value $script:saved[$name] }
    }

    It 'treats the ticked boxes as complete' {
        $env:PE_WL_AAD = 'True'
        $env:PE_WL_EXO = 'True'
        $env:PE_WL_Intune = 'False'
        & $compareScript -SourceExportPath a -TargetExportPath b -OutputPath $outDir 3>$null 6>$null
        Get-Content (Join-Path $outDir 'complete.txt') -Raw | Should -Match '\A\[AAD,EXO\]'
    }

    It 'treats nothing as complete when the boxes exist but none is ticked' {
        $env:PE_WL_AAD = 'False'
        & $compareScript -SourceExportPath a -TargetExportPath b -OutputPath $outDir 3>$null 6>$null
        Get-Content (Join-Path $outDir 'complete.txt') -Raw | Should -Match '\A\[\]'
    }

    It 'keeps the old default when there is no PE_WL_ variable at all (manual run)' {
        & $compareScript -SourceExportPath a -TargetExportPath b -OutputPath $outDir 3>$null 6>$null
        Get-Content (Join-Path $outDir 'complete.txt') -Raw | Should -Match '\A\[AAD,Intune,EXO,Teams\]'
    }

    It 'lets a typed -CompleteWorkloads win over the ticked boxes' {
        $env:PE_WL_AAD = 'True'
        & $compareScript -SourceExportPath a -TargetExportPath b -OutputPath $outDir -CompleteWorkloads 'Teams' 3>$null 6>$null
        Get-Content (Join-Path $outDir 'complete.txt') -Raw | Should -Match '\A\[Teams\]'
    }
}
