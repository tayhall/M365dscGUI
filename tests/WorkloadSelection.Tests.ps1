BeforeAll {
    $script:repoRoot = Split-Path $PSScriptRoot -Parent

    function script:Clear-WorkloadEnv
    {
        foreach ($name in @([Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -like 'PE_WL_*' }))
        {
            Remove-Item -LiteralPath "Env:$name"
        }
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
        Copy-Item (Join-Path $repoRoot 'pipelines\scripts\Invoke-PipelineCompare.ps1'), (Join-Path $repoRoot 'pipelines\scripts\Resolve-WorkloadChoice.ps1') -Destination $scripts
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

    It 'Full (and no picker at all) treats every default workload as complete' {
        & $compareScript -SourceExportPath a -TargetExportPath b -OutputPath $outDir 3>$null 6>$null
        Get-Content (Join-Path $outDir 'complete.txt') -Raw | Should -Match '\A\[AAD,Intune,EXO,Teams\]'
    }

    It 'one workload from the picker is the only complete one' {
        & $compareScript -SourceExportPath a -TargetExportPath b -OutputPath $outDir -Workload 'EXO' 3>$null 6>$null
        Get-Content (Join-Path $outDir 'complete.txt') -Raw | Should -Match '\A\[EXO\]'
    }

    It 'a workload that is not in the list stops the run, naming the choices' {
        { & $compareScript -SourceExportPath a -TargetExportPath b -OutputPath $outDir -Workload 'Nope' 3>$null 6>$null } | Should -Throw '*not one of*'
    }

    It 'ignores leftover PE_WL_ variables: the picker alone decides' {
        $env:PE_WL_AAD = 'False'
        & $compareScript -SourceExportPath a -TargetExportPath b -OutputPath $outDir 3>$null 6>$null
        Get-Content (Join-Path $outDir 'complete.txt') -Raw | Should -Match '\A\[AAD,Intune,EXO,Teams\]'
    }

    It 'lets a typed -CompleteWorkloads win over the picker' {
        & $compareScript -SourceExportPath a -TargetExportPath b -OutputPath $outDir -Workload 'AAD' -CompleteWorkloads 'Teams' 3>$null 6>$null
        Get-Content (Join-Path $outDir 'complete.txt') -Raw | Should -Match '\A\[Teams\]'
    }
}
