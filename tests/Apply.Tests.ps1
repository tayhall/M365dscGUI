BeforeAll {
    . "$PSScriptRoot\..\tools\PEApply.Common.ps1"

    $script:Thumb = 'ABCDEF0123456789ABCDEF0123456789ABCDEF01'
    $script:AppId = '11111111-2222-3333-4444-555555555555'
    $script:Tenant = 'contoso.onmicrosoft.com'
    $script:Pin = '2.26.1021.1'
    $script:AppPath = Join-Path $TestDrive 'Writer.json'
    @{ Role = 'Writer'; TenantId = $script:Tenant; ApplicationId = $script:AppId; Thumbprint = $script:Thumb } |
        ConvertTo-Json | Set-Content -LiteralPath $script:AppPath
    $script:App = Get-PEApplyApp -Role Writer -Path $script:AppPath
    $script:Types = [System.Collections.Generic.HashSet[string]]::new([string[]]@('AADGroup', 'AADUser'), [System.StringComparer]::Ordinal)

    # Safety net: no test can reach the modules, the compiler or a tenant unless it mocks these itself.
    Mock Invoke-PELcm { throw 'safety net: Invoke-PELcm is not mocked in this test' }
    Mock Test-PEApplyElevated { $true }
    Mock Invoke-PEApplyCompile { throw 'safety net: Invoke-PEApplyCompile is not mocked in this test' }
    Mock Import-PEApplyModules { }
    Mock Resolve-PETenantGuid { '22222222-3333-4444-5555-666666666666' }
    Mock Get-PEApplyResourceTypes { , $script:Types }

    function New-TestConfig
    {
        param ([string]$Path, [int]$Blocks = 1)

        $body = foreach ($i in 1..$Blocks)
        {
            @"
        AADGroup 'G$i'
        {
            DisplayName     = 'PE-TEST-$i';
            MailNickname    = 'petest$i';
            SecurityEnabled = `$true;
            MailEnabled     = `$false;
        }
"@
        }
        @"
Configuration PETest
{
    Import-DscResource -ModuleName 'Microsoft365DSC' -ModuleVersion '2.26.1021.1'

    Node localhost
    {
$($body -join "`n")
    }
}
"@ | Set-Content -LiteralPath $Path
        $Path
    }

    function New-TestResource
    {
        param ([string]$Id = '[AADGroup]G1', [hashtable]$Properties, [string[]]$DependsOn = @(), [string]$Type = 'AADGroup',
            [string]$ModuleName = 'Microsoft365DSC', [string]$ModuleVersion = '2.26.1021.1')

        if (-not $Properties)
        {
            $Properties = @{ DisplayName = 'PE-TEST-1'; TenantId = $script:Tenant; ApplicationId = $script:AppId; CertificateThumbprint = $script:Thumb }
        }
        [pscustomobject]@{
            ResourceId   = $Id
            ResourceType = $Type
            Module       = @{ ModuleName = $ModuleName; ModuleVersion = $ModuleVersion }
            Properties   = $Properties
            DependsOn    = $DependsOn
        }
    }

    function Assert-TestMof
    {
        param ([object[]]$Resources, [int]$ConfigCount = 1, [int]$Expected = -1)

        Assert-PEMofResource -Resources $Resources -App $script:App -ConfigResourceCount $ConfigCount -ExpectedResourceCount $Expected `
            -ModuleVersion $script:Pin -ResourceTypes $script:Types
    }
}

Describe 'Safety net' {
    It 'fails a test that forgets to mock the LCM call' {
        { Invoke-PELcm -MofPath x -Mode Apply } | Should -Throw '*safety net*'
        { Invoke-PEApplyCompile -ConfigPath x -ConfigurationDataPath y -ConfigurationName z -OutputPath o -Engine Standard } | Should -Throw '*safety net*'
    }
}

Describe 'Get-PEApplyApp and Assert-PEApplyRole' {
    It 'reads the app JSON' {
        $script:App.TenantId | Should -Be $script:Tenant
        $script:App.Thumbprint | Should -Be $script:Thumb
        $script:App.Role | Should -Be 'Writer'
    }

    It 'refuses an app JSON with an invalid thumbprint' {
        $bad = Join-Path $TestDrive 'bad.json'
        @{ TenantId = $script:Tenant; ApplicationId = $script:AppId; Thumbprint = "x'; evil" } | ConvertTo-Json | Set-Content $bad
        { Get-PEApplyApp -Role Writer -Path $bad } | Should -Throw '*no valid Thumbprint*'
    }

    It 'allows the Reader app only for test-only runs' {
        { Assert-PEApplyRole -Role Reader -TestOnly $false } | Should -Throw '*only be used with -TestOnly*'
        { Assert-PEApplyRole -Role Reader -TestOnly $true } | Should -Not -Throw
        { Assert-PEApplyRole -Role Writer -TestOnly $false } | Should -Not -Throw
    }
}

Describe 'Script mode, output and exit code' {
    It 'maps -WhatIf (ShouldProcess declined) to test-only' {
        Resolve-PEApplyMode -TestOnly $false -ShouldProcess { $false } | Should -BeTrue
        Resolve-PEApplyMode -TestOnly $false -ShouldProcess { $true } | Should -BeFalse
    }

    It 'never asks ShouldProcess when -TestOnly is given' {
        Resolve-PEApplyMode -TestOnly $true -ShouldProcess { throw 'must not be asked' } | Should -BeTrue
    }

    It 'returns exit code 0 for success and 2 for failure' {
        (Complete-PEApplyOutput -Result ([pscustomobject]@{ Success = $true })).ExitCode | Should -Be 0
        (Complete-PEApplyOutput -Result ([pscustomobject]@{ Success = $false })).ExitCode | Should -Be 2
    }

    It 'returns the object without -Json and compact redacted JSON with -Json' {
        $result = [pscustomobject]@{ Success = $false; Error = "bad $($script:Thumb.ToLowerInvariant())"; Resources = @() }
        (Complete-PEApplyOutput -Result $result -Thumbprint $script:Thumb).Output | Should -Be $result
        $json = (Complete-PEApplyOutput -Result $result -Json -Thumbprint $script:Thumb).Output
        $json | Should -BeOfType [string]
        $json | Should -Not -Match "`n"
        $json | Should -Not -Match $script:Thumb
        ($json | ConvertFrom-Json).Error | Should -Be 'bad <thumbprint>'
    }
}

Describe 'Protect-PEApplyText' {
    It 'replaces the thumbprint case-insensitively' {
        Protect-PEApplyText -Text "a $($script:Thumb) b $($script:Thumb.ToLowerInvariant())" -Thumbprint $script:Thumb | Should -Be 'a <thumbprint> b <thumbprint>'
    }

    It 'passes empty text and an empty thumbprint through' {
        Protect-PEApplyText -Text '' -Thumbprint $script:Thumb | Should -Be ''
        Protect-PEApplyText -Text 'x' -Thumbprint '' | Should -Be 'x'
    }
}

Describe 'Configuration data tenant guard' {
    It 'accepts the configuration data built from the app (round trip through a .psd1)' {
        $path = Join-Path $TestDrive 'cd.psd1'
        Set-Content -LiteralPath $path -Value (New-PEApplyConfigurationDataText -App $script:App)
        { Assert-PEApplyConfigurationData -Data (Import-PowerShellDataFile $path) -App $script:App } | Should -Not -Throw
    }

    It 'the generated configuration data sets OrganizationName to the app tenant domain (the generated config refers to it)' {
        $path = Join-Path $TestDrive 'cd-org.psd1'
        Set-Content -LiteralPath $path -Value (New-PEApplyConfigurationDataText -App $script:App)
        $data = Import-PowerShellDataFile $path
        $data.NonNodeData.OrganizationName | Should -BeExactly $script:Tenant
        $data.NonNodeData.TenantId | Should -BeExactly $script:Tenant
    }

    It 'compares the tenant case-insensitively' {
        $data = @{ NonNodeData = @{ TenantId = $script:Tenant.ToUpperInvariant(); ApplicationId = $script:AppId; CertificateThumbprint = $script:Thumb; OrganizationName = 'x' } }
        { Assert-PEApplyConfigurationData -Data $data -App $script:App } | Should -Not -Throw
    }

    It 'refuses a different <Name>' -ForEach @(
        @{ Name = 'TenantId'; Value = 'other.onmicrosoft.com' }
        @{ Name = 'ApplicationId'; Value = '99999999-2222-3333-4444-555555555555' }
        @{ Name = 'CertificateThumbprint'; Value = '0000000000000000000000000000000000000000' }
    ) {
        $nonNode = @{ TenantId = $script:Tenant; ApplicationId = $script:AppId; CertificateThumbprint = $script:Thumb; OrganizationName = 'x' }
        $nonNode[$Name] = $Value
        { Assert-PEApplyConfigurationData -Data @{ NonNodeData = $nonNode } -App $script:App } | Should -Throw "*NonNodeData.$Name does not match*"
    }

    It 'refuses configuration data without NonNodeData or OrganizationName' {
        { Assert-PEApplyConfigurationData -Data @{ AllNodes = @() } -App $script:App } | Should -Throw '*no NonNodeData*'
        $data = @{ NonNodeData = @{ TenantId = $script:Tenant; ApplicationId = $script:AppId; CertificateThumbprint = $script:Thumb } }
        { Assert-PEApplyConfigurationData -Data $data -App $script:App } | Should -Throw '*OrganizationName*'
    }
}

Describe 'Assert-PEApplyOutputPath' {
    BeforeAll {
        $script:FakeRepo = Join-Path $TestDrive 'fake-repo'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:FakeRepo 'data') | Out-Null
    }

    It 'refuses <Path>' -ForEach @(
        @{ Path = 'D:\Repo' }
        @{ Path = 'D:\Repo\' }
        @{ Path = 'D:\Repo\data\tmp' }
        @{ Path = 'd:\repo\Data' }
        @{ Path = 'D:\Repo\x\..\data' }
    ) {
        { Assert-PEApplyOutputPath -Path $Path -RepoRoot 'D:\Repo' } | Should -Throw '*inside the repository*'
    }

    It 'accepts <Path>' -ForEach @(
        @{ Path = 'D:\Repo2\x' }
        @{ Path = 'C:\Temp\x' }
    ) {
        { Assert-PEApplyOutputPath -Path $Path -RepoRoot 'D:\Repo' } | Should -Not -Throw
    }

    It 'refuses a \\?\ path to the repo' {
        { Assert-PEApplyOutputPath -Path "\\?\$($script:FakeRepo)\x" -RepoRoot $script:FakeRepo } | Should -Throw '*UNC or \\?\*'
    }

    It 'refuses a UNC path' {
        { Assert-PEApplyOutputPath -Path '\\localhost\D$\Repo\x' -RepoRoot 'D:\Repo' } | Should -Throw '*UNC*'
    }

    It 'refuses a junction outside the repo that points into it' -Skip:(-not $IsWindows) {
        $junction = Join-Path $env:TEMP ('pe-junction-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Junction -Path $junction -Target (Join-Path $script:FakeRepo 'data') | Out-Null
        try
        {
            { Assert-PEApplyOutputPath -Path $junction -RepoRoot $script:FakeRepo } | Should -Throw '*inside the repository*'
            { Assert-PEApplyOutputPath -Path (Join-Path $junction 'sub\deeper') -RepoRoot $script:FakeRepo } | Should -Throw '*inside the repository*'
        }
        finally
        {
            # Removes the junction only, not the target's contents.
            [System.IO.Directory]::Delete($junction)
        }
        Test-Path -LiteralPath (Join-Path $script:FakeRepo 'data') | Should -BeTrue
    }
}

Describe 'New-PEApplyWorkFolder' {
    It 'creates a folder only the current user can access, without inherited rules' -Skip:(-not $IsWindows) {
        $folder = New-PEApplyWorkFolder -Parent $TestDrive
        try
        {
            Split-Path $folder -Leaf | Should -Match '\APEApply-[0-9a-f]{32}\z'
            $acl = Get-Acl -LiteralPath $folder
            $acl.AreAccessRulesProtected | Should -BeTrue
            $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
            $rules.Count | Should -Be 1
            $rules[0].IdentityReference.Value | Should -Be ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
            $rules[0].IsInherited | Should -BeFalse
            $rules[0].AccessControlType | Should -Be 'Allow'
        }
        finally
        {
            Remove-Item -LiteralPath $folder -Recurse -Force
        }
    }
}

Describe 'Get-PEConfigResourceCount' -Tag 'Slow' {
    It 'counts the resource blocks inside Node' {
        $path = New-TestConfig -Path (Join-Path $TestDrive 'three.ps1') -Blocks 3
        Get-PEConfigResourceCount -Path $path | Should -Be 3
    }

    It 'refuses a script without a Node block' {
        $path = Join-Path $TestDrive 'nonode.ps1'
        "Configuration PETest`n{`n}`n" | Set-Content $path
        { Get-PEConfigResourceCount -Path $path } | Should -Throw '*no Node block*'
    }

    It 'refuses any statement outside the Configuration, for example one that broke out of a header comment' {
        $path = Join-Path $TestDrive 'broke-out.ps1'
        New-TestConfig -Path $path -Blocks 1 | Out-Null
        $text = (Get-Content $path -Raw)
        # A key with a line break ends the '#' comment line of an exported header; what follows is code.
        "# Update AADGroup 'x'`nInvoke-Expression 'Write-Host owned'`n# '`n" + $text | Set-Content $path
        { Get-PEConfigResourceCount -Path $path } | Should -Throw '*outside the Configuration*'
    }

    It 'accepts comment lines before the Configuration' {
        $path = Join-Path $TestDrive 'commented.ps1'
        New-TestConfig -Path $path -Blocks 2 | Out-Null
        "# header`n# more header`n" + (Get-Content $path -Raw) | Set-Content $path
        Get-PEConfigResourceCount -Path $path | Should -Be 2
    }

    It 'refuses other statements in a Node block' {
        $path = Join-Path $TestDrive 'odd.ps1'
        New-TestConfig -Path $path -Blocks 1 | Out-Null
        (Get-Content $path -Raw) -replace 'Node localhost\s*\{', "Node localhost`n    {`n        Write-Host 'x'" | Set-Content $path
        { Get-PEConfigResourceCount -Path $path } | Should -Throw '*Unexpected statement*'
    }
}

Describe 'Assert-PEMofResource' {
    It 'accepts matching credentials and counts' {
        { Assert-TestMof -Resources @(New-TestResource) -Expected 1 } | Should -Not -Throw
    }

    It 'compares the tenant case-insensitively' {
        $resource = New-TestResource
        $resource.Properties['TenantId'] = $script:Tenant.ToUpperInvariant()
        { Assert-TestMof -Resources @($resource) } | Should -Not -Throw
    }

    It 'refuses a MOF count different from the configuration blocks' {
        { Assert-TestMof -Resources @(New-TestResource) -ConfigCount 2 } | Should -Throw '*declares 2 resource blocks*'
    }

    It 'refuses a MOF count different from -ExpectedResourceCount' {
        { Assert-TestMof -Resources @(New-TestResource) -Expected 2 } | Should -Throw '*expected 2*'
    }

    It 'refuses an empty MOF' {
        { Assert-TestMof -Resources @() -ConfigCount 0 } | Should -Throw '*no resource instances*'
    }

    It 'refuses DependsOn' {
        { Assert-TestMof -Resources @(New-TestResource -DependsOn '[AADGroup]G0') } | Should -Throw '*DependsOn*'
    }

    It 'refuses an instance without any credential properties' {
        { Assert-TestMof -Resources @(New-TestResource -Properties @{ DisplayName = 'x' }) } | Should -Throw '*has no TenantId*'
    }

    It 'refuses an instance missing <Name>' -ForEach @(
        @{ Name = 'TenantId' }
        @{ Name = 'ApplicationId' }
        @{ Name = 'CertificateThumbprint' }
    ) {
        $resource = New-TestResource
        $resource.Properties.Remove($Name)
        { Assert-TestMof -Resources @($resource) } | Should -Throw "*has no $Name*"
    }

    It 'refuses an instance whose <Name> does not match the app' -ForEach @(
        @{ Name = 'TenantId'; Value = 'other.onmicrosoft.com' }
        @{ Name = 'ApplicationId'; Value = '99999999-2222-3333-4444-555555555555' }
        @{ Name = 'CertificateThumbprint'; Value = '0000000000000000000000000000000000000000' }
    ) {
        $resource = New-TestResource
        $resource.Properties[$Name] = $Value
        { Assert-TestMof -Resources @($resource) } | Should -Throw "*has a $Name that does not match*"
    }

    It 'refuses an instance carrying <Name>' -ForEach @(
        @{ Name = 'Credential' }
        @{ Name = 'ApplicationSecret' }
        @{ Name = 'CertificatePath' }
        @{ Name = 'CertificatePassword' }
        @{ Name = 'ManagedIdentity' }
        @{ Name = 'AccessTokens' }
        @{ Name = 'PsDscRunAsCredential' }
    ) {
        $resource = New-TestResource
        $resource.Properties[$Name] = 'x'
        { Assert-TestMof -Resources @($resource) } | Should -Throw "*carries $Name*"
    }

    It 'refuses an instance from another module' {
        { Assert-TestMof -Resources @(New-TestResource -ModuleName 'PSDscResources') } | Should -Throw "*from module 'PSDscResources'*"
    }

    It 'refuses an instance of another Microsoft365DSC version' {
        { Assert-TestMof -Resources @(New-TestResource -ModuleVersion '1.26.701.1') } | Should -Throw '*not the pinned*'
    }

    It 'refuses a resource class Microsoft365DSC does not export' {
        { Assert-TestMof -Resources @(New-TestResource -Type 'Script') } | Should -Throw '*not a Microsoft365DSC*'
    }

    It 'refuses when any one instance of several is bad' {
        $bad = New-TestResource -Id '[AADGroup]G2'
        $bad.Properties['CertificateThumbprint'] = '0000000000000000000000000000000000000000'
        { Assert-TestMof -Resources @((New-TestResource), $bad) -ConfigCount 2 } | Should -Throw '*G2*CertificateThumbprint*'
    }
}

Describe 'ConvertTo-PEApplyRow' {
    BeforeAll {
        $script:Two = @((New-TestResource -Id '[AADGroup]G1'), (New-TestResource -Id '[AADGroup]G2'))
    }

    It 'reports Applied for what the LCM left in the desired state, Failed with its error for the rest, in MOF order' {
        $lcm = [pscustomobject]@{ Error = 'x'; InDesiredState = @('[aadgroup]g1'); NotInDesiredState = @([pscustomobject]@{ ResourceId = '[AADGroup]G2'; Error = "Request_BadRequest $($script:Thumb)" }) }
        $rows = @(ConvertTo-PEApplyRow -Resource $script:Two -Lcm $lcm -Thumbprint $script:Thumb)
        @($rows.Status) | Should -Be @('Applied', 'Failed')
        $rows[1].Error | Should -Be 'Request_BadRequest <thumbprint>'
        $rows[0].Error | Should -BeNullOrEmpty
    }

    It 'reports NotRun for a resource the LCM never mentioned' {
        $lcm = [pscustomobject]@{ Error = $null; InDesiredState = @('[AADGroup]G1'); NotInDesiredState = @() }
        @((ConvertTo-PEApplyRow -Resource $script:Two -Lcm $lcm).Status) | Should -Be @('Applied', 'NotRun')
    }

    It 'reports InDesiredState and WouldChange for a test, never Failed' {
        $lcm = [pscustomobject]@{ Error = $null; InDesiredState = @('[AADGroup]G1'); NotInDesiredState = @([pscustomobject]@{ ResourceId = '[AADGroup]G2'; Error = 'ignored' }) }
        $rows = @(ConvertTo-PEApplyRow -Resource $script:Two -Lcm $lcm -TestOnly)
        @($rows.Status) | Should -Be @('InDesiredState', 'WouldChange')
        $rows[1].Error | Should -BeNullOrEmpty
    }
}
Describe 'ConvertTo-PEApplyRow for a test that returned only True or False' {
    It 'reports every resource InDesiredState when the whole configuration is, WouldChange otherwise' {
        $two = @((New-TestResource -Id '[AADGroup]G1'), (New-TestResource -Id '[AADGroup]G2'))
        @((ConvertTo-PEApplyRow -Resource $two -Lcm ([pscustomobject]@{ Error = $null; Overall = $true; Detailed = $false; InDesiredState = @(); NotInDesiredState = @() }) -TestOnly).Status) | Should -Be @('InDesiredState', 'InDesiredState')
        @((ConvertTo-PEApplyRow -Resource $two -Lcm ([pscustomobject]@{ Error = $null; Overall = $false; Detailed = $false; InDesiredState = @(); NotInDesiredState = @() }) -TestOnly).Status) | Should -Be @('WouldChange', 'WouldChange')
    }
}
Describe 'Invoke-PEApply' {
    BeforeEach {
        $script:Parent = Join-Path $TestDrive ('out-' + [guid]::NewGuid().ToString('N'))
        $script:Repo = Join-Path $TestDrive 'repo'
        $script:Config = Join-Path $TestDrive 'config.ps1'
        Set-Content -LiteralPath $script:Config -Value '# parsed by the mocked Get-PEConfigResourceCount'
        $script:Common = @{
            ConfigPath            = $script:Config
            ConfigurationName     = 'PETest'
            RepoRoot              = $script:Repo
            OutputPath            = $script:Parent
            ModuleVersion         = $script:Pin
            AppInfoPath           = $script:AppPath
            ExpectedResourceCount = 2
        }
        $script:Resources = @(
            (New-TestResource -Id '[AADGroup]G1'),
            (New-TestResource -Id '[AADGroup]G2')
        )
        Mock Get-PEConfigResourceCount { 2 }
        Mock Invoke-PEApplyCompile {
            New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
            $mof = Join-Path $OutputPath 'localhost.mof'
            Set-Content -LiteralPath $mof -Value 'fake mof with thumbprint'
            $script:SeenWork = Split-Path $OutputPath -Parent
            $script:SeenData = $ConfigurationDataPath
            $mof
        }
        Mock Get-PEMofResource { $script:Resources }
        Mock Invoke-PELcm { [pscustomobject]@{ Error = $null; InDesiredState = @('[AADGroup]G1', '[AADGroup]G2'); NotInDesiredState = @() } }
    }

    It 'leaves no work folder after a successful apply' {
        $result = Invoke-PEApply @script:Common
        $result.Success | Should -BeTrue
        $result.ResourceCount | Should -Be 2
        $result.ExpectedResourceCount | Should -Be 2
        @($result.Resources.Status) | Should -Be @('Applied', 'Applied')
        $script:SeenData | Should -BeLike (Join-Path $script:SeenWork 'ConfigurationData.psd1')
        $result.OutputFolder | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:SeenWork | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Parent -Filter 'PEApply-*').Count | Should -Be 0
    }

    It 'requires -ExpectedResourceCount for a real apply' {
        $arguments = $script:Common.Clone()
        $arguments.Remove('ExpectedResourceCount')
        { Invoke-PEApply @arguments } | Should -Throw '*-ExpectedResourceCount is required*'
        Should -Invoke Invoke-PEApplyCompile -Times 0 -Exactly
        { Invoke-PEApply @arguments -TestOnly } | Should -Not -Throw
    }

    It 'leaves no work folder when a guard throws after the compile' {
        $script:Resources = @((New-TestResource -Id '[AADGroup]G1' -DependsOn 'x'), (New-TestResource -Id '[AADGroup]G2'))
        { Invoke-PEApply @script:Common } | Should -Throw '*DependsOn*'
        Should -Invoke Invoke-PELcm -Times 0 -Exactly
        @(Get-ChildItem -LiteralPath $script:Parent -Filter 'PEApply-*').Count | Should -Be 0
    }

    It 'refuses a MOF instance for another tenant before any Test' {
        $script:Resources[1].Properties['TenantId'] = 'other.onmicrosoft.com'
        { Invoke-PEApply @script:Common } | Should -Throw '*G2*TenantId that does not match*'
        Should -Invoke Invoke-PELcm -Times 0 -Exactly
    }

    It 'leaves no work folder after a compile failure, and redacts the thumbprint' {
        Mock Invoke-PEApplyCompile { throw "The member NoSuchProperty is not valid ($($script:Thumb))" }
        $result = Invoke-PEApply @script:Common
        $result.Success | Should -BeFalse
        $result.Error | Should -Be 'Compile failed: The member NoSuchProperty is not valid (<thumbprint>)'
        $result.OutputFolder | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $script:Parent -Filter 'PEApply-*').Count | Should -Be 0
    }

    It 'redacts the thumbprint from a guard exception' {
        Mock Get-PEMofResource { throw "cannot read MOF with CertificateThumbprint = $($script:Thumb)" }
        { Invoke-PEApply @script:Common } | Should -Throw 'cannot read MOF with CertificateThumbprint = <thumbprint>'
    }

    It 'keeps the work folder with -KeepOutput' {
        $result = Invoke-PEApply @script:Common -KeepOutput -WarningVariable warnings -WarningAction SilentlyContinue
        $result.OutputFolder | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $result.MofPath | Should -BeTrue
        "$warnings" | Should -BeLike "*$($result.OutputFolder)*"
        Remove-Item -LiteralPath $result.OutputFolder -Recurse -Force
    }

    It 'reports the kept folder with -KeepOutput after a compile failure' {
        Mock Invoke-PEApplyCompile { throw 'compile broke' }
        $result = Invoke-PEApply @script:Common -KeepOutput -WarningAction SilentlyContinue
        $result.Success | Should -BeFalse
        $result.OutputFolder | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $result.OutputFolder | Should -BeTrue
        Remove-Item -LiteralPath $result.OutputFolder -Recurse -Force
    }

    It 'names the kept folder in the exception with -KeepOutput after a guard throw' {
        $script:Resources = @((New-TestResource -Id '[AADGroup]G1' -DependsOn 'x'), (New-TestResource -Id '[AADGroup]G2'))
        $message = $null
        try
        {
            Invoke-PEApply @script:Common -KeepOutput -WarningAction SilentlyContinue
        }
        catch
        {
            $message = $_.Exception.Message
        }
        $match = [regex]::Match([string]$message, 'DependsOn.*work folder kept: (.+PEApply-[0-9a-f]{32})\)')
        $match.Success | Should -BeTrue
        $kept = $match.Groups[1].Value
        Test-Path -LiteralPath $kept | Should -BeTrue
        Remove-Item -LiteralPath $kept -Recurse -Force
    }

    It 'only tests with -TestOnly (the LCM is asked for a Test, never an Apply)' {
        Mock Invoke-PELcm { [pscustomobject]@{ Error = $null; InDesiredState = @(); NotInDesiredState = @([pscustomobject]@{ ResourceId = '[AADGroup]G1'; Error = $null }, [pscustomobject]@{ ResourceId = '[AADGroup]G2'; Error = $null }) } }
        $result = Invoke-PEApply @script:Common -TestOnly
        $result.Success | Should -BeTrue
        $result.TestOnly | Should -BeTrue
        @($result.Resources.Status) | Should -Be @('WouldChange', 'WouldChange')
        Should -Invoke Invoke-PELcm -Times 1 -Exactly -ParameterFilter { $Mode -eq 'Test' }
        Should -Invoke Invoke-PELcm -Times 0 -Exactly -ParameterFilter { $Mode -eq 'Apply' }
    }

    It 'refuses to run without an elevated session, before compiling' {
        Mock Test-PEApplyElevated { $false }
        { Invoke-PEApply @script:Common } | Should -Throw '*elevated*'
        Should -Invoke Invoke-PELcm -Times 0 -Exactly
    }

    It 'does not prompt or skip its own folder operations under -Confirm or -WhatIf preferences' {
        $ConfirmPreference = 'Low'
        $WhatIfPreference = $true
        $result = Invoke-PEApply @script:Common -TestOnly
        $result.Success | Should -BeTrue
        @(Get-ChildItem -LiteralPath $script:Parent -Filter 'PEApply-*').Count | Should -Be 0
    }

    It 'refuses the Reader app without -TestOnly before compiling' {
        $readerPath = Join-Path $TestDrive 'Reader.json'
        Copy-Item $script:AppPath $readerPath
        $arguments = $script:Common.Clone()
        $arguments['Role'] = 'Reader'
        $arguments['AppInfoPath'] = $readerPath
        { Invoke-PEApply @arguments } | Should -Throw '*only be used with -TestOnly*'
        Should -Invoke Invoke-PEApplyCompile -Times 0 -Exactly
    }

    It 'refuses configuration data for another tenant before compiling' {
        $path = Join-Path $TestDrive 'other.psd1'
        "@{ NonNodeData = @{ TenantId = 'other.onmicrosoft.com'; ApplicationId = '$script:AppId'; CertificateThumbprint = '$script:Thumb'; OrganizationName = 'x' } }" | Set-Content $path
        { Invoke-PEApply @script:Common -ConfigurationDataPath $path } | Should -Throw '*TenantId does not match*'
        Should -Invoke Invoke-PEApplyCompile -Times 0 -Exactly
    }

    It 'refuses an output path inside the repo' {
        $arguments = $script:Common.Clone()
        $arguments['OutputPath'] = Join-Path $script:Repo 'tmp'
        { Invoke-PEApply @arguments } | Should -Throw '*inside the repository*'
        Should -Invoke Invoke-PEApplyCompile -Times 0 -Exactly
    }

    It 'refuses a MOF whose count differs from -ExpectedResourceCount before any Test' {
        { Invoke-PEApply @script:Common -ExpectedResourceCount 3 } | Should -Throw '*expected 3*'
        Should -Invoke Invoke-PELcm -Times 0 -Exactly
    }

    It 'reports PartiallyApplied when one resource applied and the next failed' {
        Mock Invoke-PELcm { [pscustomobject]@{ Error = 'The SendConfigurationApply function did not succeed.'; InDesiredState = @('[AADGroup]G1'); NotInDesiredState = @([pscustomobject]@{ ResourceId = '[AADGroup]G2'; Error = "Request_BadRequest $($script:Thumb)" }) } }
        $result = Invoke-PEApply @script:Common
        $result.Success | Should -BeFalse
        $result.PartiallyApplied | Should -BeTrue
        @($result.Resources.Status) | Should -Be @('Applied', 'Failed')
        $result.Resources[1].Error | Should -Be 'Request_BadRequest <thumbprint>'
        @(Get-ChildItem -LiteralPath $script:Parent -Filter 'PEApply-*').Count | Should -Be 0
    }

    It 'treats a resource the LCM never reported as not applied' {
        Mock Invoke-PELcm { [pscustomobject]@{ Error = $null; InDesiredState = @('[AADGroup]G1'); NotInDesiredState = @() } }
        $result = Invoke-PEApply @script:Common
        $result.Success | Should -BeFalse
        @($result.Resources.Status) | Should -Be @('Applied', 'NotRun')
    }}
