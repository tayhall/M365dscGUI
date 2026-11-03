BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Tool = Join-Path $PSScriptRoot '..\tools\Initialize-PEGuiFromExport.ps1'
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures\upload\entra.ps1'

    function New-ExportFolder
    {
        # A folder named 'Dev' holding the fixture as export.ps1, optionally with an empty export.log and a ConfigurationData.psd1.
        param ([string]$Parent, [switch]$Log, [string]$Organization)
        $folder = Join-Path $Parent 'Dev'
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Copy-Item -LiteralPath $script:Fixture -Destination (Join-Path $folder 'export.ps1')
        if ($Log) { Set-Content -LiteralPath (Join-Path $folder 'export.log') -Value '' }
        if ($Organization) { Set-Content -LiteralPath (Join-Path $folder 'ConfigurationData.psd1') -Value "@{ AllNodes = @(@{ NodeName = 'localhost' }); NonNodeData = @{ OrganizationName = '$Organization'; TenantId = '$Organization' } }" }
        $folder
    }
}

Describe 'Initialize-PEGuiFromExport' {
    It 'creates the GUI data from an export folder and the tenant domain' {
        $folder = New-ExportFolder -Parent $TestDrive -Log
        $root = Join-Path $TestDrive 'data1'
        & $script:Tool -ExportPath $folder -TenantDomain 'contoso-dev.onmicrosoft.com' -DataRoot $root | Out-Null
        Test-Path (Join-Path $root 'gui\index.json') | Should -BeTrue
        (Get-PETenant -Slug 'dev' -DataRoot $root).Offline | Should -BeTrue
        (InModuleScope PolicyEngine -Parameters @{ Root = $root } { @(Get-PEBlueprintVersionNumber -Directory (Get-PEBlueprintDirectory -Name 'dev-blueprint' -DataRoot $Root)).Count }) | Should -Be 1
    }

    It 'works when only export.ps1 was copied (no export.log)' {
        $folder = New-ExportFolder -Parent (Join-Path $TestDrive 'nolog')
        $root = Join-Path $TestDrive 'data2'
        { & $script:Tool -ExportPath $folder -TenantDomain 'contoso-dev.onmicrosoft.com' -DataRoot $root | Out-Null } | Should -Not -Throw
        Test-Path (Join-Path $root 'gui\index.json') | Should -BeTrue
    }

    It 'reads the tenant domain from ConfigurationData.psd1 when -TenantDomain is not given' {
        $folder = New-ExportFolder -Parent (Join-Path $TestDrive 'cfg') -Log -Organization 'fromfile.onmicrosoft.com'
        $root = Join-Path $TestDrive 'data3'
        & $script:Tool -ExportPath $folder -DataRoot $root | Out-Null
        (Get-PETenant -Slug 'dev' -DataRoot $root).TenantId | Should -Be 'fromfile.onmicrosoft.com'
    }

    It 'needs only the export folder: with no domain it uses a placeholder and says so' {
        $folder = New-ExportFolder -Parent (Join-Path $TestDrive 'nodomain') -Log
        $root = Join-Path $TestDrive 'data4'
        & $script:Tool -ExportPath $folder -DataRoot $root -WarningVariable warned -WarningAction SilentlyContinue | Out-Null
        (Get-PETenant -Slug 'dev' -DataRoot $root).TenantId | Should -Be 'dev.invalid'
        ($warned -join ' ') | Should -BeLike '*placeholder*'
        Test-Path (Join-Path $root 'gui\index.json') | Should -BeTrue
    }

    It 'refuses a folder without export.ps1' {
        $empty = Join-Path $TestDrive 'empty'
        New-Item -ItemType Directory -Path $empty | Out-Null
        { & $script:Tool -ExportPath $empty -TenantDomain 'x.onmicrosoft.com' -DataRoot (Join-Path $TestDrive 'data5') } | Should -Throw '*export.ps1*'
    }

    It 'run again with a newer export: keeps the blueprint and adds a snapshot' {
        $folder = New-ExportFolder -Parent (Join-Path $TestDrive 'again') -Log
        $root = Join-Path $TestDrive 'data6'
        & $script:Tool -ExportPath $folder -TenantDomain 'contoso-dev.onmicrosoft.com' -DataRoot $root | Out-Null
        $firstChecks = @(Get-ChildItem (Join-Path $root 'checks') -Directory).Count
        Start-Sleep -Seconds 1
        & $script:Tool -ExportPath $folder -TenantDomain 'contoso-dev.onmicrosoft.com' -DataRoot $root | Out-Null
        (InModuleScope PolicyEngine -Parameters @{ Root = $root } { @(Get-PEBlueprintVersionNumber -Directory (Get-PEBlueprintDirectory -Name 'dev-blueprint' -DataRoot $Root)).Count }) | Should -Be 1
        @(Get-ChildItem (Join-Path $root 'checks') -Directory).Count | Should -BeGreaterThan $firstChecks
    }

    It 'honours -DisplayName' {
        $folder = New-ExportFolder -Parent (Join-Path $TestDrive 'named') -Log
        $root = Join-Path $TestDrive 'data7'
        & $script:Tool -ExportPath $folder -TenantDomain 'contoso-dev.onmicrosoft.com' -DisplayName 'Contoso Dev' -DataRoot $root | Out-Null
        (Get-PETenant -Slug 'dev' -DataRoot $root).DisplayName | Should -Be 'Contoso Dev'
    }
}
