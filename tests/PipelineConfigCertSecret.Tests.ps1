BeforeAll {
    $script:Scripts = Join-Path $PSScriptRoot '..\pipelines\scripts'
    function New-ConfigFolder
    {
        param ([string]$ExtraLines = '')
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-cfg-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        Set-Content (Join-Path $dir 'Dev.psd1') -Value "@{ TenantDomain = 'dev.onmicrosoft.com'; KeyVault = 'my-vault'; ShortName = 'dev'; ReaderAppId = '11111111-2222-3333-4444-555555555555'; WriterAppId = '11111111-2222-3333-4444-555555555556'`n$ExtraLines }"
        $dir
    }
}

Describe 'the certificate secret name in the config' {
    It 'accepts ReaderCertSecret and WriterCertSecret' {
        $dir = New-ConfigFolder "ReaderCertSecret = 'my-reader-cert'; WriterCertSecret = 'my-writer-cert'"
        $c = & (Join-Path $script:Scripts 'Get-PipelineConfig.ps1') -Environment Dev -ConfigPath $dir
        $c.ReaderCertSecret | Should -Be 'my-reader-cert'
    }

    It 'refuses a secret name Key Vault would not allow' {
        $dir = New-ConfigFolder "ReaderCertSecret = 'bad name; x'"
        { & (Join-Path $script:Scripts 'Get-PipelineConfig.ps1') -Environment Dev -ConfigPath $dir } | Should -Throw '*ReaderCertSecret*'
    }

    It 'reads the configured secret from the vault, and <ShortName>-Cert-<Role> when none is configured' {
        Mock Get-AzContext { $null }
        Mock Get-AzKeyVaultSecret { $null }
        $run = {
            param ($Folder)
            $text = ''
            try { $text = (& (Join-Path $script:Scripts 'Connect-PipelineTenant.ps1') -Environment Dev -Role Reader -ThumbprintOnly -ConfigPath $Folder 6>&1 | ForEach-Object { "$_" }) -join "`n" } catch { $text = $_.Exception.Message }
            $text
        }
        (& $run (New-ConfigFolder "ReaderCertSecret = 'my-reader-cert'")) | Should -Match "secret 'my-reader-cert'"
        (& $run (New-ConfigFolder)) | Should -Match "secret 'dev-Cert-Reader'"
    }

    It 'reads a Prod config like the other tenants' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-cfg-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        Set-Content (Join-Path $dir 'Prod.psd1') -Value "@{ TenantDomain = 'prod.onmicrosoft.com'; KeyVault = 'prod-vault'; ShortName = 'prod'; ReaderAppId = '11111111-2222-3333-4444-555555555555' }"
        $c = & (Join-Path $script:Scripts 'Get-PipelineConfig.ps1') -Environment Prod -ConfigPath $dir
        $c.KeyVault | Should -Be 'prod-vault'
    }
}
