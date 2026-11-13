BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..\pipelines\scripts\Invoke-PipelineTenantChanges.ps1'
    $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-ptc-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Temp | Out-Null

    # A stand-in for tools\Invoke-PETenantChanges.ps1 that records which parameters it was given, and a stand-in for Connect-PipelineTenant.ps1.
    $script:StubTool = Join-Path $script:Temp 'stub-tool.ps1'
    Set-Content $script:StubTool -Value @'
param ([string]$Tenant, [string]$PreviousExportPath, [string]$LatestExportPath, [string]$TargetTenantDomain, [string]$OutputPath,
    [string]$PreviousRun, [string]$LatestRun, [string]$PreviousName, [string]$LatestName, [string[]]$CompleteWorkload,
    [string]$ApplicationId, [string]$CertificateThumbprint, [string]$OrganizationName)
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$PSBoundParameters | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $OutputPath 'args.json')
$n = if ($env:PE_STUB_OPEN) { [int]$env:PE_STUB_OPEN } else { 2 }
"{ ""Revert"": { ""OpenFindings"": $n, ""ByKind"": ""TargetOnly=$n"", ""Manual"": 0 }, ""Promote"": { ""OpenFindings"": $n, ""ByKind"": ""Missing=$n"", ""Manual"": 0 } }" | Set-Content (Join-Path (New-Item -ItemType Directory -Force -Path (Join-Path $OutputPath $Tenant)).FullName 'summary.json')
'@
    $script:StubConnect = Join-Path $script:Temp 'stub-connect.ps1'
    Set-Content $script:StubConnect -Value "param (`$Environment, `$Role, [switch]`$ThumbprintOnly)`n'AABBCCDDEEFF00112233445566778899AABBCCDD'"

    function New-Config
    {
        param ([string]$Dev, [string]$PreProd)
        $folder = Join-Path $script:Temp ('config-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        Set-Content (Join-Path $folder 'Dev.psd1') -Value $Dev
        Set-Content (Join-Path $folder 'PreProd.psd1') -Value $PreProd
        $folder
    }
    $script:Guid = '11111111-2222-3333-4444-555555555555'
    $script:DevConfig = "@{ TenantDomain = 'contoso-dev.onmicrosoft.com'; OrganizationName = 'contoso-dev.onmicrosoft.com'; KeyVault = 'kv-dev'; ShortName = 'dev'; ReaderAppId = '$script:Guid'; WriterAppId = '$script:Guid' }"
    $script:PreProdConfig = "@{ TenantDomain = 'contoso-preprod.onmicrosoft.com'; KeyVault = 'kv-pp'; ShortName = 'pp'; ReaderAppId = '$script:Guid' }"

    function Invoke-Script
    {
        param ([string]$Tenant = 'Dev', [string]$Workload = 'Full', [string]$ConfigPath = (New-Config $script:DevConfig $script:PreProdConfig))
        $out = Join-Path $script:Temp ('out-' + [guid]::NewGuid().ToString('N'))
        $messages = & $script:Script -Tenant $Tenant -Workload $Workload -PreviousExportPath 'prev' -LatestExportPath 'latest' -OutputPath $out `
            -PreviousRun '101' -LatestRun '102' -PreviousName 'v8' -LatestName 'v9' -ConfigPath $ConfigPath `
            -ToolPath $script:StubTool -ConnectScript $script:StubConnect 6>&1 3>&1
        [pscustomobject]@{ Out = $out; Messages = @($messages | ForEach-Object { "$_" }); Args = (Get-Content (Join-Path $out 'args.json') -Raw | ConvertFrom-Json) }
    }
}

AfterAll { Remove-Item $script:Temp -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'pipelines\scripts\Invoke-PipelineTenantChanges.ps1' {
    It 'compiles the revert for a tenant with a Writer app, passing its identity and the Writer certificate thumbprint' {
        $r = Invoke-Script -Tenant Dev
        $r.Args.Tenant | Should -Be 'Dev'
        $r.Args.TargetTenantDomain | Should -Be 'contoso-dev.onmicrosoft.com'
        $r.Args.ApplicationId | Should -Be $script:Guid
        $r.Args.OrganizationName | Should -Be 'contoso-dev.onmicrosoft.com'
        $r.Args.CertificateThumbprint | Should -Be 'AABBCCDDEEFF00112233445566778899AABBCCDD'
        $r.Args.PreviousName | Should -Be 'v8'
        $r.Args.LatestRun | Should -Be '102'
    }

    It 'does not compile, and does not ask for a certificate, for a tenant with no Writer app' {
        $r = Invoke-Script -Tenant PreProd
        $r.Args.TargetTenantDomain | Should -Be 'contoso-preprod.onmicrosoft.com'
        $r.Args.PSObject.Properties.Name | Should -Not -Contain 'ApplicationId'
        $r.Args.PSObject.Properties.Name | Should -Not -Contain 'CertificateThumbprint'
    }

    It 'does not compile for a Writer app that still says CHANGE-ME' {
        $config = New-Config ($script:DevConfig -replace "WriterAppId = '[^']+'", "WriterAppId = 'CHANGE-ME'") $script:PreProdConfig
        (Invoke-Script -Tenant Dev -ConfigPath $config).Args.PSObject.Properties.Name | Should -Not -Contain 'ApplicationId'
    }

    It 'renames the run once, to what it compared, and warns with the counts' {
        $r = Invoke-Script
        @($r.Messages | Where-Object { $_ -match 'build\.updatebuildnumber' }).Count | Should -Be 1
        ($r.Messages | Where-Object { $_ -match 'build\.updatebuildnumber' }) | Should -Be '##vso[build.updatebuildnumber]Dev Full changes v8 to v9'
        ($r.Messages -join "`n") | Should -Match 'Changes: 2 open \(TargetOnly=2\)'
    }

    It 'compares only the chosen workload and names it in the run' {
        $r = Invoke-Script -Workload AAD
        $r.Args.CompleteWorkload | Should -Be 'AAD'
        ($r.Messages | Where-Object { $_ -match 'build\.updatebuildnumber' }) | Should -Be '##vso[build.updatebuildnumber]Dev AAD changes v8 to v9'
        (Invoke-Script -Workload Full).Args.CompleteWorkload | Should -Be 'AAD,Intune,EXO,Teams'
    }

    It 'does not raise a warning line when nothing changed' {
        $env:PE_STUB_OPEN = '0'
        try { $r = Invoke-Script } finally { Remove-Item Env:PE_STUB_OPEN }
        ($r.Messages -join "`n") | Should -Not -Match 'task\.logissue'
    }

    It 'refuses a workload that is not in the list' {
        { Invoke-Script -Workload Exchange } | Should -Throw '*Exchange*'
    }

    It 'stops when the tenant config has no usable TenantDomain' {
        $config = New-Config $script:DevConfig ($script:PreProdConfig -replace "contoso-preprod.onmicrosoft.com", 'CHANGE-ME')
        { Invoke-Script -Tenant PreProd -ConfigPath $config } | Should -Throw '*TenantDomain*'
    }
}
