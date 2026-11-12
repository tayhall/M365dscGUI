BeforeAll {
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    $script:namer = Join-Path $repoRoot 'pipelines\scripts\Get-ExportRunName.ps1'
    $script:date = [datetime]::SpecifyKind([datetime]'2026-11-10', 'Utc')

    function script:Clear-WorkloadEnv
    {
        foreach ($name in @([Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -like 'PE_WL_*' }))
        {
            Remove-Item -LiteralPath "Env:$name"
        }
    }
}

Describe 'Get-ExportRunName.ps1' {
    It 'calls a selection of every default workload FULL, in Workloads.psd1 order joined with +' {
        & $namer -Environment Dev -Workloads 'Teams,EXO,Intune,AAD' -RunDate $date | Should -Be 'Dev FULL AAD+Intune+EXO+Teams 2026-11-10'
    }

    It 'calls a selection that adds SC to every default workload FULL' {
        & $namer -Environment PreProd -Workloads 'AAD,Intune,EXO,Teams,SC' -RunDate $date | Should -Be 'PreProd FULL AAD+Intune+EXO+Teams+SC 2026-11-10'
    }

    It 'calls only SC PARTIAL' {
        & $namer -Environment PreProd -Workloads 'SC' -RunDate ([datetime]::SpecifyKind([datetime]'2026-11-12', 'Utc')) | Should -Be 'PreProd PARTIAL SC 2026-11-12'
    }

    It 'calls AAD and Teams PARTIAL' {
        & $namer -Environment Dev -Workloads 'Teams,AAD' -RunDate $date | Should -Be 'Dev PARTIAL AAD+Teams 2026-11-10'
    }

    It 'calls the defaults minus one PARTIAL' {
        & $namer -Environment Dev -Workloads 'AAD,Intune,EXO' -RunDate $date | Should -Be 'Dev PARTIAL AAD+Intune+EXO 2026-11-10'
    }

    It 'uses the calendar day of an injected date whatever its Kind, so the result does not depend on the time zone' {
        foreach ($kind in 'Utc', 'Unspecified', 'Local')
        {
            $noon = [datetime]::SpecifyKind([datetime]'2026-11-10T12:00:00', $kind)
            $midnight = [datetime]::SpecifyKind([datetime]'2026-11-10T00:00:00', $kind)
            & $namer -Environment Dev -Workloads 'SC' -RunDate $noon | Should -Be 'Dev PARTIAL SC 2026-11-10'
            if ($kind -ne 'Local') { & $namer -Environment Dev -Workloads 'SC' -RunDate $midnight | Should -Be 'Dev PARTIAL SC 2026-11-10' }
        }
    }

    It 'uses today''s UTC date by default' {
        & $namer -Environment Dev -Workloads 'SC' | Should -Be "Dev PARTIAL SC $([datetime]::UtcNow.ToString('yyyy-MM-dd'))"
    }

    It 'gives every combination of the five workloads a name a build number accepts' {
        $prefixes = @((Import-PowerShellDataFile (Join-Path $repoRoot 'src\PolicyEngine\Data\Workloads.psd1')).Workloads.Prefix)
        $prefixes.Count | Should -Be 5
        foreach ($mask in 1..([math]::Pow(2, $prefixes.Count) - 1))
        {
            $chosen = @(for ($i = 0; $i -lt $prefixes.Count; $i++) { if ($mask -band (1 -shl $i)) { $prefixes[$i] } })
            foreach ($environment in 'Dev', 'PreProd')
            {
                $name = & $namer -Environment $environment -Workloads ($chosen -join ',') -RunDate $date
                $name | Should -Match '\A[A-Za-z0-9 +-]+\z'
            }
        }
    }
}

Describe 'Invoke-PipelineExport.ps1 run name' {
    BeforeEach {
        $script:saved = @{}
        foreach ($name in @([Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -like 'PE_WL_*' }))
        {
            $script:saved[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $script:savedTfBuild = $env:TF_BUILD
        Clear-WorkloadEnv

        $script:tree = Join-Path $TestDrive 'repo'
        $scripts = New-Item -ItemType Directory -Path (Join-Path $tree 'pipelines\scripts') -Force
        New-Item -ItemType Directory -Path (Join-Path $tree 'tools'), (Join-Path $tree 'src\PolicyEngine\Data') -Force | Out-Null
        Copy-Item (Join-Path $repoRoot 'pipelines\scripts\Invoke-PipelineExport.ps1'), (Join-Path $repoRoot 'pipelines\scripts\Get-WorkloadSelection.ps1'), $namer -Destination $scripts
        Copy-Item (Join-Path $repoRoot 'src\PolicyEngine\Data\Workloads.psd1') -Destination (Join-Path $tree 'src\PolicyEngine\Data')
        Set-Content (Join-Path $scripts 'Connect-PipelineTenant.ps1') 'param($Environment, $Role) "CONNECT"'
        Set-Content (Join-Path $scripts 'Disconnect-PipelineTenant.ps1') 'param($Slug, $Role) "DISCONNECT"'
        Set-Content (Join-Path $tree 'tools\Export-M365DscTenant.ps1') 'param($Role, $Tenant, $Workloads, $OutputPath) "EXPORT:$Workloads"'
        $script:exportScript = Join-Path $scripts 'Invoke-PipelineExport.ps1'
        $script:today = [datetime]::UtcNow.ToString('yyyy-MM-dd')
    }
    AfterEach {
        Clear-WorkloadEnv
        foreach ($name in $script:saved.Keys) { Set-Item -LiteralPath "Env:$name" -Value $script:saved[$name] }
        if ($null -eq $script:savedTfBuild) { Remove-Item Env:TF_BUILD -ErrorAction SilentlyContinue } else { $env:TF_BUILD = $script:savedTfBuild }
    }

    It 'prints the build number command before connecting when running in Azure DevOps' {
        $env:TF_BUILD = 'True'
        $env:PE_WL_AAD = 'True'
        $env:PE_WL_Teams = 'True'
        $out = @(& $exportScript -Environment Dev -OutputPath (Join-Path $TestDrive 'out') 6>&1 | ForEach-Object { "$_" })
        $line = "##vso[build.updatebuildnumber]Dev PARTIAL AAD+Teams $today"
        $out | Should -Contain $line
        [array]::IndexOf($out, $line) | Should -BeLessThan ([array]::IndexOf($out, 'CONNECT'))
    }

    It 'labels a typed -Workloads list the same way, in Workloads.psd1 order' {
        $env:TF_BUILD = 'True'
        $out = @(& $exportScript -Environment PreProd -Workloads 'Teams,EXO,Intune,AAD' -OutputPath (Join-Path $TestDrive 'out') 6>&1 | ForEach-Object { "$_" })
        $out | Should -Contain "##vso[build.updatebuildnumber]PreProd FULL AAD+Intune+EXO+Teams $today"
        $out | Should -Contain 'EXPORT:Teams,EXO,Intune,AAD'
    }

    It 'prints nothing of the kind when TF_BUILD is not set' {
        Remove-Item Env:TF_BUILD -ErrorAction SilentlyContinue
        $env:PE_WL_AAD = 'True'
        $out = @(& $exportScript -Environment Dev -OutputPath (Join-Path $TestDrive 'out') 6>&1 | ForEach-Object { "$_" })
        ($out -join ' ') | Should -Not -Match '##vso'
        $out | Should -Contain 'EXPORT:AAD'
    }

    It 'never prints it when nothing is ticked' {
        $env:TF_BUILD = 'True'
        $out = @()
        $thrown = $null
        try { $out = @(& $exportScript -Environment Dev -OutputPath (Join-Path $TestDrive 'out') 6>&1 | ForEach-Object { "$_" }) } catch { $thrown = $_ }
        $thrown.Exception.Message | Should -Match 'No workload is ticked'
        ($out -join ' ') | Should -Not -Match '##vso|CONNECT'
    }

    It 'warns and still exports when the run name cannot be built' {
        $env:TF_BUILD = 'True'
        $env:PE_WL_AAD = 'True'
        Set-Content (Join-Path $tree 'pipelines\scripts\Get-ExportRunName.ps1') 'throw ''namer broke'''
        $out = @(& $exportScript -Environment Dev -OutputPath (Join-Path $TestDrive 'out') 3>&1 6>&1 | ForEach-Object { "$_" })
        ($out -join ' ') | Should -Match 'Run name not set: namer broke'
        ($out -join ' ') | Should -Not -Match '##vso'
        $out | Should -Contain 'EXPORT:AAD'
    }

    It 'still stops when nothing is ticked even though the run name is guarded' {
        $env:TF_BUILD = 'True'
        Set-Content (Join-Path $tree 'pipelines\scripts\Get-ExportRunName.ps1') 'throw ''namer broke'''
        { & $exportScript -Environment Dev -OutputPath (Join-Path $TestDrive 'out') } | Should -Throw 'No workload is ticked*'
    }
}
