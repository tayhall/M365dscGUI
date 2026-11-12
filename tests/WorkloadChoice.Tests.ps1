BeforeAll {
    $script:Script = Join-Path (Split-Path $PSScriptRoot -Parent) 'pipelines\scripts\Resolve-WorkloadChoice.ps1'
    $script:List = Join-Path $TestDrive 'Workloads.psd1'
    Set-Content $script:List -Value @'
@{ Workloads = @(
    @{ Prefix = 'AAD'; Name = 'Entra ID'; Default = $true }
    @{ Prefix = 'EXO'; Name = 'Exchange Online'; Default = $true }
    @{ Prefix = 'SC'; Name = 'Security and Compliance'; Default = $false }
) }
'@
}

Describe 'pipelines\scripts\Resolve-WorkloadChoice.ps1' {
    It 'Full is every workload whose Default is true, in the order of the list, without the others' {
        & $script:Script -Choice Full -WorkloadsPath $script:List | Should -Be 'AAD,EXO'
    }

    It 'one workload prefix is that workload alone, including one that is not part of Full' {
        & $script:Script -Choice EXO -WorkloadsPath $script:List | Should -Be 'EXO'
        & $script:Script -Choice SC -WorkloadsPath $script:List | Should -Be 'SC'
    }

    It 'a blank choice is Full, the default of the picker' {
        & $script:Script -Choice '' -WorkloadsPath $script:List | Should -Be 'AAD,EXO'
    }

    It 'reads the choice from PE_WORKLOAD when -Choice is not given' {
        $env:PE_WORKLOAD = 'EXO'
        try { & $script:Script -WorkloadsPath $script:List | Should -Be 'EXO' } finally { Remove-Item Env:PE_WORKLOAD }
    }

    It 'refuses a name that is not in the list, naming what is allowed' {
        { & $script:Script -Choice Exchange -WorkloadsPath $script:List } | Should -Throw '*Exchange*Full, AAD, EXO, SC*'
        { & $script:Script -Choice aad -WorkloadsPath $script:List } | Should -Throw '*aad*'
    }

    It 'uses the repo Workloads.psd1 by default and knows Full' {
        (& $script:Script -Choice Full) | Should -Match '^AAD,'
    }
}
