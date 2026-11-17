BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..\pipelines\scripts\Test-PipelineSignIn.ps1'
    . (Join-Path $PSScriptRoot '..\tools\PEAppPath.ps1')
    function Connect-MgGraph { param ($ClientId, $TenantId, $CertificateThumbprint, [switch]$NoWelcome) }
    function Disconnect-MgGraph { }
    function Get-MgContext { }
    $script:Info = Get-PEAppInfoPath -Role Reader -Tenant 'pesignintest'
}
AfterAll { Remove-Item (Split-Path $script:Info -Parent) -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'pipelines\scripts\Test-PipelineSignIn.ps1' {
    It 'says so when there is no app details file' {
        $out = (& $script:Script -Environment Dev -Role Writer 6>&1 | ForEach-Object { "$_" }) -join "`n"
        if (Test-Path (Get-PEAppInfoPath -Role Writer -Tenant 'dev')) { Set-ItResult -Skipped -Because 'a real dev Writer file exists on this machine'; return }
        $out | Should -Match 'No app details file'
    }
}
