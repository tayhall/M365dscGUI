BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Mini = Join-Path $PSScriptRoot 'fixtures\mini-export.ps1'
    $script:Log = @'
Exporting Microsoft 365 configuration for Components: AADGroup, AADConditionalAccessPolicy

Starting export in sequential mode...
[1/2] Extracting [AADGroup] using {CertificateThumbprint}...
    |---[1/2] Sales✅
    |---[2/2] Finance✅
[2/2] Extracting [AADConditionalAccessPolicy] using {CertificateThumbprint}...
    |---[1/1] Require MFA✅
⌛ Export took {5 seconds} for {3 instances}
Successful exports: {2}
Failed exports: {0}
✅ Export completed successfully.
'@

    function New-ExportFolder
    {
        param ([string]$Root, [switch]$CaDisabled)
        $folder = Join-Path $Root ('export-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        $text = Get-Content -LiteralPath $script:Mini -Raw
        if ($CaDisabled) { $text = $text.Replace('State                 = "enabled";', 'State                 = "disabled";') }
        [System.IO.File]::WriteAllText((Join-Path $folder 'export.ps1'), $text)
        [System.IO.File]::WriteAllText((Join-Path $folder 'export.log'), $script:Log, [System.Text.UTF8Encoding]::new($false))
        return $folder
    }
}

Describe 'Tenant app files' {
    It 'keeps the first tenant where the registration tool wrote it and gives every other tenant a folder' {
        $master = & (Get-Module PolicyEngine) { Get-PEAppInfoPath -Role Reader }
        $master | Should -Be (Join-Path $HOME '.m365dsc-policy\M365DSC-Policy-Reader.json')
        $dev = & (Get-Module PolicyEngine) { Get-PEAppInfoPath -Role Writer -Tenant 'dev' }
        $dev | Should -Be (Join-Path $HOME '.m365dsc-policy\dev\M365DSC-Policy-Writer.json')
    }

    It 'refuses a tenant name that could point somewhere else' {
        foreach ($bad in '..', '..\x', 'a/b', 'UPPER', '')
        {
            { & (Get-Module PolicyEngine) { param ($t) Get-PEAppInfoPath -Role Reader -Tenant $t } $bad } | Should -Throw
        }
    }

    It 'passes the tenant to the export tool and leaves the default command line alone' {
        $default = @(& (Get-Module PolicyEngine) { Get-PEExportToolArgument -Workloads 'AAD' -OutputPath 'C:\out' })
        $default | Should -Not -Contain '-Tenant'
        $dev = @(& (Get-Module PolicyEngine) { Get-PEExportToolArgument -Workloads 'AAD' -OutputPath 'C:\out' -Tenant 'dev' })
        $i = [array]::IndexOf($dev, '-Tenant')
        $i | Should -BeGreaterThan 0
        $dev[$i + 1] | Should -Be 'dev'
    }
}

Describe 'Tenant registry' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-tenants-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Temp | Out-Null
    }

    AfterEach {
        Remove-Item $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'always has a master, even before anything is registered' {
        $tenants = @(Get-PETenant -DataRoot $script:Temp)
        $tenants[0].Slug | Should -Be 'master'
        $tenants[0].Role | Should -Be 'Master'
    }

    It 'registers replicas, updates them and removes them, but never the master' {
        Set-PETenant -Slug 'dev' -DisplayName 'Dev tenant' -TenantId 'contoso-dev.onmicrosoft.com' -DataRoot $script:Temp | Out-Null
        Set-PETenant -Slug 'test' -DataRoot $script:Temp | Out-Null
        (Get-PETenant -Slug 'dev' -DataRoot $script:Temp).Role | Should -Be 'Replica'
        (Get-PETenant -Slug 'dev' -DataRoot $script:Temp).TenantId | Should -Be 'contoso-dev.onmicrosoft.com'
        Set-PETenant -Slug 'dev' -DisplayName 'Dev (renamed)' -DataRoot $script:Temp | Out-Null
        $dev = Get-PETenant -Slug 'dev' -DataRoot $script:Temp
        $dev.DisplayName | Should -Be 'Dev (renamed)'
        $dev.TenantId | Should -Be 'contoso-dev.onmicrosoft.com'
        @(Get-PETenant -DataRoot $script:Temp).Slug | Should -Be @('master', 'dev', 'test')
        Remove-PETenant -Slug 'test' -DataRoot $script:Temp
        @(Get-PETenant -DataRoot $script:Temp).Slug | Should -Be @('master', 'dev')
        { Remove-PETenant -Slug 'master' -DataRoot $script:Temp } | Should -Throw '*master*'
        { Get-PETenant -Slug 'nope' -DataRoot $script:Temp } | Should -Throw '*not registered*'
    }

    It 'marks a tenant offline, keeps that when it is updated, and defaults to online' {
        Set-PETenant -Slug 'pre' -Offline -DataRoot $script:Temp | Out-Null
        Set-PETenant -Slug 'dev' -DataRoot $script:Temp | Out-Null
        (Get-PETenant -Slug 'pre' -DataRoot $script:Temp).Offline | Should -BeTrue
        (Get-PETenant -Slug 'dev' -DataRoot $script:Temp).Offline | Should -BeFalse
        (Get-PETenant -Slug 'master' -DataRoot $script:Temp).Offline | Should -BeFalse
        Set-PETenant -Slug 'pre' -DisplayName 'x' -DataRoot $script:Temp | Out-Null
        (Get-PETenant -Slug 'pre' -DataRoot $script:Temp).Offline | Should -BeTrue
    }

    It 'clears the offline flag only when -Offline:$false is given explicitly' {
        Set-PETenant -Slug 'pre' -Offline -DataRoot $script:Temp | Out-Null
        Set-PETenant -Slug 'pre' -DisplayName 'kept' -DataRoot $script:Temp | Out-Null
        (Get-PETenant -Slug 'pre' -DataRoot $script:Temp).Offline | Should -BeTrue
        Set-PETenant -Slug 'pre' -Offline:$false -DataRoot $script:Temp | Out-Null
        (Get-PETenant -Slug 'pre' -DataRoot $script:Temp).Offline | Should -BeFalse
    }

    It 'never lets the master be offline' {
        { Set-PETenant -Slug 'master' -Offline -DataRoot $script:Temp } | Should -Throw '*master*'
    }

    It 'reads a tenants.json written before the Offline property as online' {
        '[{"Slug":"old","Role":"Replica","DisplayName":"Old","TenantId":"","Blueprints":[]}]' | Set-Content -LiteralPath (Join-Path $script:Temp 'tenants.json') -Encoding utf8
        (Get-PETenant -Slug 'old' -DataRoot $script:Temp).Offline | Should -BeFalse
    }

    It 'keeps decisions per tenant: one for every tenant, one for dev only' {
        Set-PEDecision -Kind Unmanaged -ResourceType AADGroup -Key 'Everywhere' -Reason 'all' -DataRoot $script:Temp | Out-Null
        Set-PEDecision -Kind Unmanaged -ResourceType AADGroup -Key 'DevOnly' -Reason 'dev' -Tenant 'dev' -DataRoot $script:Temp | Out-Null
        Set-PEDecision -Kind Unmanaged -ResourceType AADGroup -Key 'DevOnly' -Reason 'master too' -Tenant 'master' -DataRoot $script:Temp | Out-Null
        @(Get-PEDecision -Tenant 'dev' -DataRoot $script:Temp | ForEach-Object Reason | Sort-Object) | Should -Be @('all', 'dev')
        @(Get-PEDecision -Tenant 'master' -DataRoot $script:Temp | ForEach-Object Reason | Sort-Object) | Should -Be @('all', 'master too')
        @(Get-PEDecision -DataRoot $script:Temp).Count | Should -Be 3
        Remove-PEDecision -Kind Unmanaged -ResourceType AADGroup -Key 'DevOnly' -Tenant 'dev' -DataRoot $script:Temp
        @(Get-PEDecision -Tenant 'dev' -DataRoot $script:Temp | ForEach-Object Reason | Sort-Object) | Should -Be @('all')
        @(Get-PEDecision -Tenant 'master' -DataRoot $script:Temp | ForEach-Object Reason).Count | Should -Be 2
    }
}

Describe 'Checks per tenant' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-tenants-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Temp | Out-Null
        $records = @(InModuleScope PolicyEngine -Parameters @{ F = $script:Mini } {
                Read-PEExport -Path $F -TenantId 'tenant-1' | ForEach-Object { ConvertTo-PENormalizedRecord -Record $_ }
            })
        $state = InModuleScope PolicyEngine -Parameters @{ R = $records } {
            New-PEState -Records $R -NotChecked @() -Meta @{ TenantId = 'tenant-1'; ExportedAt = '2026-10-01T00:00:00Z' }
        }
        Initialize-PEBlueprint -Name 'main' -State $state -DataRoot $script:Temp | Out-Null
    }

    AfterEach {
        Remove-Item $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'a check records its tenant and the latest check is looked up per tenant' {
        $masterFolder = New-ExportFolder -Root $script:Temp
        $master = Invoke-PEFullCheck -BlueprintName 'main' -ExportScript { $masterFolder }.GetNewClosure() -TargetTenantId 'tenant-1' -DataRoot $script:Temp
        Start-Sleep -Milliseconds 1100
        $devFolder = New-ExportFolder -Root $script:Temp -CaDisabled
        $dev = Invoke-PEFullCheck -BlueprintName 'main' -Tenant 'dev' -ExportScript { $devFolder }.GetNewClosure() -TargetTenantId 'tenant-dev' -DataRoot $script:Temp
        (Get-PECheck -CheckId $dev.CheckId -DataRoot $script:Temp).TenantSlug | Should -Be 'dev'
        (Get-PECheck -Latest -Kind Full -DataRoot $script:Temp).CheckId | Should -Be $master.CheckId
        (Get-PECheck -Latest -Kind Full -Tenant 'dev' -DataRoot $script:Temp).CheckId | Should -Be $dev.CheckId
        # the dev tenant differs from the blueprint in the CA state; the master does not
        @($dev.Findings | Where-Object { $_.Kind -eq 'Changed' -and $_.ResourceType -eq 'AADConditionalAccessPolicy' }).Count | Should -Be 1
        @($master.Findings | Where-Object { $_.Kind -eq 'Changed' -and $_.ResourceType -eq 'AADConditionalAccessPolicy' }).Count | Should -Be 0
        { Get-PECheck -Latest -Kind Full -Tenant 'other' -DataRoot $script:Temp } | Should -Throw "*tenant 'other'*"
    }

    It 'a check written before tenants existed belongs to the master' {
        $folder = New-ExportFolder -Root $script:Temp
        $check = Invoke-PEFullCheck -BlueprintName 'main' -ExportScript { $folder }.GetNewClosure() -TargetTenantId 'tenant-1' -DataRoot $script:Temp
        $path = Join-Path $script:Temp "checks\$($check.CheckId)\result.json"
        $json = Get-Content $path -Raw | ConvertFrom-Json
        $json.PSObject.Properties.Remove('TenantSlug')
        $json | ConvertTo-Json -Depth 30 | Set-Content $path
        (Get-PECheck -Latest -Kind Full -Tenant 'master' -DataRoot $script:Temp).CheckId | Should -Be $check.CheckId
        { Get-PECheck -Latest -Kind Full -Tenant 'dev' -DataRoot $script:Temp } | Should -Throw
    }

    It 'a scope check of the dev tenant folds into the latest check of the dev tenant only' {
        $masterFolder = New-ExportFolder -Root $script:Temp
        $master = Invoke-PEFullCheck -BlueprintName 'main' -ExportScript { $masterFolder }.GetNewClosure() -TargetTenantId 'tenant-1' -DataRoot $script:Temp
        Start-Sleep -Milliseconds 1100
        $devFolder = New-ExportFolder -Root $script:Temp -CaDisabled
        $dev = Invoke-PEFullCheck -BlueprintName 'main' -Tenant 'dev' -ExportScript { $devFolder }.GetNewClosure() -TargetTenantId 'tenant-dev' -DataRoot $script:Temp
        Start-Sleep -Milliseconds 1100
        Set-PEScope -Name 'ca' -Types 'AADConditionalAccessPolicy' -DataRoot $script:Temp | Out-Null
        $scope = Invoke-PEScopeCheck -Scope 'ca' -BlueprintName 'main' -Tenant 'dev' -ExportScript { $devFolder }.GetNewClosure() -TargetTenantId 'tenant-dev' -DataRoot $script:Temp
        $scope.BasedOn | Should -Be $dev.CheckId
        (Get-PECheck -CheckId $scope.CheckId -DataRoot $script:Temp).TenantSlug | Should -Be 'dev'
        (Get-PECheck -Latest -Kind Full -DataRoot $script:Temp).CheckId | Should -Be $master.CheckId
    }

    It 'adding blueprint types is refused for a replica' {
        Set-PETenant -Slug 'dev' -DataRoot $script:Temp | Out-Null
        { Add-PEBlueprintType -Name 'main' -Types 'AADNamedLocationPolicy' -Reason 'x' -Tenant 'dev' -ExportScript { throw 'must not export' } -DataRoot $script:Temp } | Should -Throw '*replica*'
    }
}

Describe 'Test-PEAppOwnership (an application is reused only when this tool recorded creating it)' {
    BeforeAll {
        $script:Admin = 'admin-object-id'
        $script:Recorded = 'app-object-id-1'
        function Test-Owner
        {
            param ($Id = 'app-object-id-1', $Keys = @([pscustomobject]@{ displayName = 'CN=x' }), $Secrets = @(), $Owners = @(), $Federated = @(), $RecordedId = 'app-object-id-1')
            $app = [pscustomobject]@{ id = $Id; keyCredentials = @($Keys); passwordCredentials = @($Secrets) }
            & (Get-Module PolicyEngine) { param ($a, $r, $o, $f, $m) Test-PEAppOwnership -Application $a -RecordedObjectId $r -Owners $o -FederatedCredentials $f -AdminObjectId $m } $app $RecordedId $Owners $Federated $script:Admin
        }
    }

    It 'accepts the recorded application with one key, no secret, no federated credential and no foreign owner' {
        Test-Owner | Should -BeNullOrEmpty
        Test-Owner -Owners @([pscustomobject]@{ id = $script:Admin }) | Should -BeNullOrEmpty
    }

    It 'refuses an application with the right name that this tool did not record, however it looks' {
        Test-Owner -Id 'someone-elses-app' | Should -BeLike '*no record of creating it*'
        Test-Owner -RecordedId '' | Should -BeLike '*no record of creating it*'
        Test-Owner -RecordedId $null | Should -BeLike '*no record of creating it*'
    }

    It 'refuses a recorded application that has since gained a secret, a second or missing key, a federated credential or another owner' {
        Test-Owner -Secrets @([pscustomobject]@{ hint = 'abc' }) | Should -BeLike '*client secret*'
        Test-Owner -Keys @([pscustomobject]@{ displayName = 'a' }, [pscustomobject]@{ displayName = 'b' }) | Should -BeLike '*exactly one certificate*'
        Test-Owner -Keys @() | Should -BeLike '*exactly one certificate*'
        Test-Owner -Federated @([pscustomobject]@{ name = 'github' }) | Should -BeLike '*federated credential*'
        Test-Owner -Owners @([pscustomobject]@{ id = $script:Admin }, [pscustomobject]@{ id = 'someone-else' }) | Should -BeLike '*1 owner(s) other than*'
    }
}

Describe 'Test-PEServicePrincipalOwnership' {
    BeforeAll {
        function Test-Sp
        {
            param ($Keys = @(), $Secrets = @(), $Owners = @())
            $sp = [pscustomobject]@{ id = 'sp'; keyCredentials = @($Keys); passwordCredentials = @($Secrets) }
            & (Get-Module PolicyEngine) { param ($s, $o) Test-PEServicePrincipalOwnership -ServicePrincipal $s -Owners $o -AdminObjectId 'admin' } $sp $Owners
        }
    }

    It 'accepts a service principal with no credentials and no foreign owner' {
        Test-Sp | Should -BeNullOrEmpty
        Test-Sp -Owners @([pscustomobject]@{ id = 'admin' }) | Should -BeNullOrEmpty
    }

    It 'refuses one with its own secret or certificate, or another owner' {
        Test-Sp -Secrets @([pscustomobject]@{ hint = 'x' }) | Should -BeLike '*client secret*'
        Test-Sp -Keys @([pscustomobject]@{ displayName = 'x' }) | Should -BeLike '*certificate*'
        Test-Sp -Owners @([pscustomobject]@{ id = 'other' }) | Should -BeLike '*owner(s) other than*'
    }
}