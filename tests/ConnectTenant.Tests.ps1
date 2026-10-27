BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:AppId = '11111111-2222-3333-4444-555555555555'
    $script:Thumb = 'AABBCCDDEEFF00112233445566778899AABBCCDD'
}

Describe 'Connect-PETenant' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-connect-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Temp | Out-Null
        # keep the app files out of the real profile
        $script:RealHome = $HOME
        $env:PE_TEST_APPDIR = $script:Temp
        Mock -ModuleName PolicyEngine Get-PEAppInfoPath { Join-Path $env:PE_TEST_APPDIR "$Tenant-$Role.json" }
        Mock -ModuleName PolicyEngine Test-PETenantAppConnection { }
        Mock -CommandName Test-Path -ModuleName PolicyEngine -ParameterFilter { $LiteralPath -like 'Cert:\*' } { $true }
    }

    AfterEach {
        Remove-Item Env:\PE_TEST_APPDIR -ErrorAction SilentlyContinue
        Remove-Item $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'writes the app files and registers the tenant as a replica after proving the Reader works' {
        Connect-PETenant -Slug 'dev' -TenantId 'contoso-dev.onmicrosoft.com' -DisplayName 'Contoso Dev' -ReaderApplicationId $script:AppId -ReaderThumbprint $script:Thumb `
            -WriterApplicationId '66666666-2222-3333-4444-555555555555' -WriterThumbprint $script:Thumb -DataRoot $script:Temp | Out-Null
        Should -Invoke -ModuleName PolicyEngine Test-PETenantAppConnection -Times 1 -ParameterFilter { $ApplicationId -eq $script:AppId -and $TenantId -eq 'contoso-dev.onmicrosoft.com' }
        $reader = Get-Content (Join-Path $script:Temp 'dev-Reader.json') -Raw | ConvertFrom-Json
        $reader.ApplicationId | Should -Be $script:AppId
        $reader.TenantId | Should -Be 'contoso-dev.onmicrosoft.com'
        $reader.Thumbprint | Should -Be $script:Thumb
        Test-Path (Join-Path $script:Temp 'dev-Writer.json') | Should -BeTrue
        $tenant = Get-PETenant -Slug 'dev' -DataRoot $script:Temp
        $tenant.Role | Should -Be 'Replica'
        $tenant.DisplayName | Should -Be 'Contoso Dev'
    }

    It 'a tenant with only a Reader can be checked but has no Writer file' {
        Connect-PETenant -Slug 'readonly' -TenantId 'x.onmicrosoft.com' -ReaderApplicationId $script:AppId -ReaderThumbprint $script:Thumb -DataRoot $script:Temp | Out-Null
        Test-Path (Join-Path $script:Temp 'readonly-Reader.json') | Should -BeTrue
        Test-Path (Join-Path $script:Temp 'readonly-Writer.json') | Should -BeFalse
    }

    It 'refuses bad input and a half-given Writer, and writes nothing' {
        { Connect-PETenant -Slug 'Bad Slug' -TenantId 'x.onmicrosoft.com' -ReaderApplicationId $script:AppId -ReaderThumbprint $script:Thumb } | Should -Throw
        { Connect-PETenant -Slug 'dev' -TenantId 'x.onmicrosoft.com' -ReaderApplicationId 'not-a-guid' -ReaderThumbprint $script:Thumb } | Should -Throw
        { Connect-PETenant -Slug 'dev' -TenantId 'x.onmicrosoft.com' -ReaderApplicationId $script:AppId -ReaderThumbprint 'short' } | Should -Throw
        { Connect-PETenant -Slug 'dev' -TenantId 'x.onmicrosoft.com' -ReaderApplicationId $script:AppId -ReaderThumbprint $script:Thumb -WriterApplicationId $script:AppId -DataRoot $script:Temp } | Should -Throw '*both*'
        @(Get-ChildItem $script:Temp -Filter '*.json').Count | Should -Be 0
    }

    It 'does not register a tenant whose Reader cannot sign in' {
        Mock -ModuleName PolicyEngine Test-PETenantAppConnection { throw 'AADSTS700027: certificate not found' }
        { Connect-PETenant -Slug 'dev' -TenantId 'x.onmicrosoft.com' -ReaderApplicationId $script:AppId -ReaderThumbprint $script:Thumb -DataRoot $script:Temp } | Should -Throw '*AADSTS700027*'
        @(Get-ChildItem $script:Temp -Filter '*.json').Count | Should -Be 0
    }

    It 'refuses a certificate that is not on this machine' {
        Mock -CommandName Test-Path -ModuleName PolicyEngine -ParameterFilter { $LiteralPath -like 'Cert:\*' } { $false }
        { Connect-PETenant -Slug 'dev' -TenantId 'x.onmicrosoft.com' -ReaderApplicationId $script:AppId -ReaderThumbprint $script:Thumb -DataRoot $script:Temp } | Should -Throw '*No certificate*'
    }
}

Describe 'Get-PETenantSetupScript' {
    It 'is built from DSC commands only and names the steps DSC does not do' {
        $text = Get-PETenantSetupScript
        $text | Should -Match 'Get-M365DSCCompiledPermissionList'
        $text | Should -Match 'Update-M365DSCAzureAdApplication'
        $text | Should -Match 'RequiredVersion 2\.\d+'
        $text | Should -Match 'admin consent'
        $text | Should -Match 'Global Reader'
        $text | Should -Match 'Connect-PETenant'
        $text | Should -Match '\{slug\}'
    }
}
