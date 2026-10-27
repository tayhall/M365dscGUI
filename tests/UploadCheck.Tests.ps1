BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Dir = Join-Path $PSScriptRoot 'fixtures\upload'

    function Get-UploadFile
    {
        param ([string[]]$Name)
        foreach ($n in $Name) { [pscustomobject]@{ Name = $n; Text = Get-Content -LiteralPath (Join-Path $script:Dir $n) -Raw } }
    }

    function New-OwnBlueprint
    {
        # The tenant's own blueprint 'acme': the fixtures' records plus one EXO type that no fixture holds.
        param ([string]$Root)
        $records = @(InModuleScope PolicyEngine -Parameters @{ D = $script:Dir } {
                foreach ($name in 'entra.ps1', 'exchange.ps1')
                {
                    Read-PEExport -Path (Join-Path $D $name) -TenantId 'acme.example' | ForEach-Object { ConvertTo-PENormalizedRecord -Record $_ }
                }
            })
        $records += [pscustomobject]@{ ResourceType = 'EXOMailTips'; Key = 'default'; Workload = 'Exchange Online'; TenantId = 'acme.example'; Properties = [ordered]@{ Identity = 'default' } }
        $state = InModuleScope PolicyEngine -Parameters @{ R = $records } {
            New-PEState -Records $R -NotChecked @() -Meta @{ TenantId = 'acme.example'; ExportedAt = '2026-10-01T00:00:00Z' }
        }
        Initialize-PEBlueprint -Name 'acme' -State $state -DataRoot $Root | Out-Null
        Set-PETenant -Slug 'acme' -Blueprints @('main', 'acme') -DataRoot $Root | Out-Null
    }

    function New-MainBlueprint
    {
        # The master blueprint 'main': the fixtures' records, EXOMailTips and -Extra records, taken from tenant m.example.
        param ([string]$Root, [object[]]$Extra = @())
        $records = @(InModuleScope PolicyEngine -Parameters @{ D = $script:Dir } {
                foreach ($name in 'entra.ps1', 'exchange.ps1')
                {
                    Read-PEExport -Path (Join-Path $D $name) -TenantId 'm.example' | ForEach-Object { ConvertTo-PENormalizedRecord -Record $_ }
                }
            })
        $records += [pscustomobject]@{ ResourceType = 'EXOMailTips'; Key = 'default'; Workload = 'Exchange Online'; TenantId = 'm.example'; Properties = [ordered]@{ Identity = 'default' } }
        $records += $Extra
        $state = InModuleScope PolicyEngine -Parameters @{ R = $records } {
            New-PEState -Records $R -NotChecked @() -Meta @{ TenantId = 'm.example'; ExportedAt = '2026-10-01T00:00:00Z' }
        }
        Initialize-PEBlueprint -Name 'main' -State $state -DataRoot $Root | Out-Null
    }
}

Describe 'New-PEUploadCheck' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Temp | Out-Null
        Set-PETenant -Slug 'acme' -Offline -DataRoot $script:Temp | Out-Null
    }

    AfterEach {
        if (Test-Path $script:Temp) { Remove-Item $script:Temp -Recurse -Force }
    }

    It 'refuses a file of another version and leaves checks and the tenant alone' {
        $files = @(Get-UploadFile 'entra.ps1', 'other-version.ps1')
        { New-PEUploadCheck -Tenant 'acme' -File $files -TenantDomain 'acme.example' -DataRoot $script:Temp } | Should -Throw '*other-version.ps1*'
        @(Get-ChildItem (Join-Path $script:Temp 'checks') -ErrorAction SilentlyContinue).Count | Should -Be 0
        (Get-PETenant -Slug 'acme' -DataRoot $script:Temp).TenantId | Should -Be ''
    }

    It 'turns an Entra and Exchange upload into a Full check with both workloads' {
        $result = New-PEUploadCheck -Tenant 'acme' -File @(Get-UploadFile 'entra.ps1', 'exchange.ps1') -TenantDomain 'acme.example' -DataRoot $script:Temp
        $check = Get-PECheck -Latest -Kind Full -Tenant 'acme' -DataRoot $script:Temp
        $check.CheckId | Should -Be $result.CheckId
        $check.State.Meta.Source | Should -Be 'Uploaded'
        $check.State.Meta.TenantId | Should -Be 'acme.example'
        $check.State.Meta.ModuleVersion | Should -Not -BeNullOrEmpty
        $check.State.Meta.ExportedAt | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$'
        @($check.State.Meta.Workloads.PSObject.Properties.Name | Sort-Object) | Should -Be @('Entra ID', 'Exchange Online')
        $check.State.Meta.Workloads.'Entra ID'.Source | Should -Be 'Uploaded'
        $check.State.Meta.Workloads.'Entra ID'.At | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$'
        @($result.Workloads | Sort-Object) | Should -Be @('Entra ID', 'Exchange Online')
        (Get-PETenant -Slug 'acme' -DataRoot $script:Temp).TenantId | Should -Be 'acme.example'
        Test-Path (Join-Path $script:Temp "exports\$($result.CheckId)\export.log") | Should -BeFalse
    }

    It 'is readable by Initialize-PETenantBlueprint -FromCheck when the tenant has no blueprint yet' {
        $result = New-PEUploadCheck -Tenant 'acme' -File @(Get-UploadFile 'entra.ps1') -TenantDomain 'acme.example' -DataRoot $script:Temp
        (Get-PECheck -CheckId $result.CheckId -DataRoot $script:Temp).BlueprintName | Should -BeNullOrEmpty
        @($result.Findings).Count | Should -Be 0
        Initialize-PETenantBlueprint -Slug 'acme' -MasterBlueprint 'main' -FromCheck -DataRoot $script:Temp | Should -Be 'acme'
        @((Get-PEBlueprint -Name 'acme' -DataRoot $script:Temp).Records).Count | Should -Be 2
    }

    It 'marks types of a workload that was not uploaded NotChecked, never Missing' {
        New-OwnBlueprint -Root $script:Temp
        $result = New-PEUploadCheck -Tenant 'acme' -File @(Get-UploadFile 'entra.ps1') -DataRoot $script:Temp -TenantDomain 'acme.example'
        @($result.Findings | Where-Object Kind -eq 'Missing').Count | Should -Be 0
        $check = Get-PECheck -CheckId $result.CheckId -DataRoot $script:Temp
        @($check.State.NotChecked | Where-Object { $_.ResourceType -eq 'EXOAcceptedDomain' }).Reason | Should -Be 'workload not uploaded'
    }

    It 'marks a type with no records NotChecked unless the workload is complete' {
        New-OwnBlueprint -Root $script:Temp
        $files = @(Get-UploadFile 'entra.ps1', 'exchange.ps1')
        $result = New-PEUploadCheck -Tenant 'acme' -File $files -DataRoot $script:Temp -TenantDomain 'acme.example'
        @($result.Findings | Where-Object { $_.Kind -eq 'Missing' -and $_.ResourceType -eq 'EXOMailTips' }).Count | Should -Be 0
        $check = Get-PECheck -CheckId $result.CheckId -DataRoot $script:Temp
        @($check.State.NotChecked | Where-Object { $_.ResourceType -eq 'EXOMailTips' }).Reason | Should -Be 'no records in the upload and no export log'

        Start-Sleep -Seconds 1
        $complete = New-PEUploadCheck -Tenant 'acme' -File $files -CompleteWorkload 'Exchange Online' -DataRoot $script:Temp
        @($complete.Findings | Where-Object { $_.Kind -eq 'Missing' -and $_.ResourceType -eq 'EXOMailTips' }).Count | Should -Be 1
    }

    It 'rejects a -CompleteWorkload that is not in the upload' {
        { New-PEUploadCheck -Tenant 'acme' -File @(Get-UploadFile 'entra.ps1') -CompleteWorkload 'Teams' -TenantDomain 'acme.example' -DataRoot $script:Temp } | Should -Throw '*Teams*'
        @(Get-ChildItem (Join-Path $script:Temp 'checks') -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'folds a second upload into the first, keeping the workloads it does not contain' {
        New-OwnBlueprint -Root $script:Temp
        $first = New-PEUploadCheck -Tenant 'acme' -File @(Get-UploadFile 'entra.ps1', 'exchange.ps1') -DataRoot $script:Temp -TenantDomain 'acme.example'
        $before = Get-PECheck -CheckId $first.CheckId -DataRoot $script:Temp
        Start-Sleep -Seconds 2
        $second = New-PEUploadCheck -Tenant 'acme' -File @(Get-UploadFile 'entra.ps1') -DataRoot $script:Temp
        $after = Get-PECheck -CheckId $second.CheckId -DataRoot $script:Temp
        $after.State.Meta.PatchedFrom | Should -Be $first.CheckId
        $after.State.Meta.Workloads.'Exchange Online'.At | Should -Be $before.State.Meta.Workloads.'Exchange Online'.At
        $after.State.Meta.Workloads.'Entra ID'.At | Should -Not -Be $before.State.Meta.Workloads.'Entra ID'.At
        @($after.State.Records | Where-Object ResourceType -eq 'EXOAcceptedDomain').Count | Should -Be 1
        @($after.State.Records | Where-Object ResourceType -eq 'AADGroup').Count | Should -Be 2
        @($second.Findings | Where-Object Kind -eq 'Missing').Count | Should -Be 0
    }

    It 'treats a workload of a check without Meta.Workloads as Live at Meta.ExportedAt' {
        New-OwnBlueprint -Root $script:Temp
        $record = [pscustomobject]@{ ResourceType = 'EXOAcceptedDomain'; Key = 'old.example'; Workload = 'Exchange Online'; TenantId = 'acme.example'; Properties = [ordered]@{ Identity = 'old.example' } }
        $state = InModuleScope PolicyEngine -Parameters @{ R = $record } {
            New-PEState -Records @($R) -NotChecked @() -Meta @{ TenantId = 'acme.example'; ExportedAt = '2026-10-01T00:00:00Z' }
        }
        InModuleScope PolicyEngine -Parameters @{ S = $state; R = $script:Temp } {
            Write-PEJsonNew -Path (Join-Path $R 'checks\20261001-000000\result.json') -InputObject ([ordered]@{ CheckId = '20261001-000000'; Kind = 'Full'; TenantSlug = 'acme'; BlueprintName = 'acme'; Findings = @(); State = $S })
        }
        $result = New-PEUploadCheck -Tenant 'acme' -File @(Get-UploadFile 'entra.ps1') -DataRoot $script:Temp -TenantDomain 'acme.example'
        $check = Get-PECheck -CheckId $result.CheckId -DataRoot $script:Temp
        $check.State.Meta.PatchedFrom | Should -Be '20261001-000000'
        $check.State.Meta.Workloads.'Exchange Online'.Source | Should -Be 'Live'
        $check.State.Meta.Workloads.'Exchange Online'.At | Should -Be '2026-10-01T00:00:00Z'
    }

    It 'refuses a tenant that is not offline' {
        Set-PETenant -Slug 'live' -DataRoot $script:Temp | Out-Null
        { New-PEUploadCheck -Tenant 'live' -File @(Get-UploadFile 'entra.ps1') -TenantDomain 'live.example' -DataRoot $script:Temp } | Should -Throw '*offline*'
    }

    It 'asks for the tenant domain when none is given or stored' {
        { New-PEUploadCheck -Tenant 'acme' -File @(Get-UploadFile 'entra.ps1') -DataRoot $script:Temp } | Should -Throw '*TenantDomain*'
        @(Get-ChildItem (Join-Path $script:Temp 'checks') -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'warns about an instance in two files and keeps one record' {
        $files = @(Get-UploadFile 'entra.ps1') + @([pscustomobject]@{ Name = 'entra-again.ps1'; Text = (Get-UploadFile 'entra.ps1').Text })
        $result = New-PEUploadCheck -Tenant 'acme' -File $files -DataRoot $script:Temp -TenantDomain 'acme.example'
        @($result.Warnings).Count | Should -BeGreaterThan 0
        $result.Warnings[0] | Should -BeLike '*entra-again.ps1*'
        $check = Get-PECheck -CheckId $result.CheckId -DataRoot $script:Temp
        @($check.State.Records | Where-Object ResourceType -eq 'AADGroup').Count | Should -Be 2
    }

    It 'treats a tenant that follows only the master blueprint as having no own blueprint' {
        Set-PETenant -Slug 'acme' -Blueprints @('main') -DataRoot $script:Temp | Out-Null
        $result = New-PEUploadCheck -Tenant 'acme' -File @(Get-UploadFile 'entra.ps1') -TenantDomain 'acme.example' -DataRoot $script:Temp
        (Get-PECheck -CheckId $result.CheckId -DataRoot $script:Temp).BlueprintName | Should -BeNullOrEmpty
        @($result.Findings).Count | Should -Be 0
        Initialize-PETenantBlueprint -Slug 'acme' -MasterBlueprint 'main' -FromCheck -DataRoot $script:Temp | Should -Be 'acme'
    }

    It 'compares against the own blueprint when it is the last one the tenant follows' {
        New-OwnBlueprint -Root $script:Temp
        $result = New-PEUploadCheck -Tenant 'acme' -File @(Get-UploadFile 'entra.ps1') -TenantDomain 'acme.example' -DataRoot $script:Temp
        (Get-PECheck -CheckId $result.CheckId -DataRoot $script:Temp).BlueprintName | Should -Be 'acme'
    }

    It 'leaves no export folder, no check and no TenantId behind when the comparison fails' {
        New-OwnBlueprint -Root $script:Temp
        Mock -ModuleName PolicyEngine Compare-PEState { throw 'compare failed' }
        { New-PEUploadCheck -Tenant 'acme' -File @(Get-UploadFile 'entra.ps1') -TenantDomain 'acme.example' -DataRoot $script:Temp } | Should -Throw '*compare failed*'
        @(Get-ChildItem (Join-Path $script:Temp 'exports') -ErrorAction SilentlyContinue).Count | Should -Be 0
        @(Get-ChildItem (Join-Path $script:Temp 'checks') -ErrorAction SilentlyContinue).Count | Should -Be 0
        (Get-PETenant -Slug 'acme' -DataRoot $script:Temp).TenantId | Should -Be ''
    }

    It 'marks a blueprint type of a kept workload NotChecked when the earlier check never read it' {
        # main holds the fixtures' records and an Exchange sharing policy that no fixture holds. The own blueprint is seeded from
        # an Entra and Exchange upload (no sharing policy), the policy is moved into it (v2), then Entra alone is uploaded: Exchange
        # is kept from the earlier check, which was made against v1 and never read EXOSharingPolicy.
        New-MainBlueprint -Root $script:Temp -Extra ([pscustomobject]@{ ResourceType = 'EXOSharingPolicy'; Key = 'Default Sharing Policy'; Workload = 'Exchange Online'; TenantId = 'm.example'; Properties = [ordered]@{ Name = 'Default Sharing Policy'; Enabled = $true; Ensure = 'Present' } })
        Set-PETenant -Slug 'acme' -Blueprints @('main') -DataRoot $script:Temp | Out-Null
        New-PEUploadCheck -Tenant 'acme' -File @(Get-UploadFile 'entra.ps1', 'exchange.ps1') -TenantDomain 'acme.example' -DataRoot $script:Temp | Out-Null
        Initialize-PETenantBlueprint -Slug 'acme' -MasterBlueprint 'main' -FromCheck -DataRoot $script:Temp | Out-Null
        Start-Sleep -Seconds 1
        New-PEUploadCheck -Tenant 'acme' -File @(Get-UploadFile 'entra.ps1', 'exchange.ps1') -DataRoot $script:Temp | Out-Null
        Move-PEBlueprintItem -From 'main' -To 'acme' -Item @([pscustomobject]@{ ResourceType = 'EXOSharingPolicy'; Key = 'Default Sharing Policy' }) -Reason 'wanted' -ExpectedVersion 1 -DataRoot $script:Temp | Should -Be 2
        Start-Sleep -Seconds 1
        $result = New-PEUploadCheck -Tenant 'acme' -File @(Get-UploadFile 'entra.ps1') -DataRoot $script:Temp
        @($result.Findings | Where-Object { $_.Kind -eq 'Missing' -and $_.ResourceType -eq 'EXOSharingPolicy' }).Count | Should -Be 0
        $check = Get-PECheck -CheckId $result.CheckId -DataRoot $script:Temp
        $check.BlueprintVersion | Should -Be 2
        @($check.State.NotChecked | Where-Object { $_.ResourceType -eq 'EXOSharingPolicy' }).Count | Should -Be 1
        # What the earlier check did read stays as it was: its accepted domain is kept, and nothing of it is NotChecked.
        @($check.State.Records | Where-Object ResourceType -EQ 'EXOAcceptedDomain').Count | Should -Be 1
        @($check.State.NotChecked | Where-Object { $_.ResourceType -eq 'EXOAcceptedDomain' }).Count | Should -Be 0
    }

    It 'marks a type the own blueprint gained after the earlier check NotChecked when its workload is kept' {
        # The same, with the sharing policy added to the own blueprint directly: no layer held it when the earlier check was made.
        New-MainBlueprint -Root $script:Temp
        Set-PETenant -Slug 'acme' -Blueprints @('main') -DataRoot $script:Temp | Out-Null
        New-PEUploadCheck -Tenant 'acme' -File @(Get-UploadFile 'entra.ps1', 'exchange.ps1') -TenantDomain 'acme.example' -DataRoot $script:Temp | Out-Null
        Initialize-PETenantBlueprint -Slug 'acme' -MasterBlueprint 'main' -FromCheck -DataRoot $script:Temp | Out-Null
        Start-Sleep -Seconds 1
        New-PEUploadCheck -Tenant 'acme' -File @(Get-UploadFile 'entra.ps1', 'exchange.ps1') -DataRoot $script:Temp | Out-Null
        $policy = [pscustomobject]@{ ResourceType = 'EXOSharingPolicy'; Key = 'Default Sharing Policy'; Workload = 'Exchange Online'; TenantId = 'acme.example'; Properties = [ordered]@{ Name = 'Default Sharing Policy'; Enabled = $true; Ensure = 'Present' } }
        $wanted = InModuleScope PolicyEngine -Parameters @{ R = @(@((Get-PEBlueprint -Name 'acme' -DataRoot $script:Temp).Records) + $policy) } {
            New-PEState -Records $R -NotChecked @() -Meta @{ TenantId = 'acme.example'; ExportedAt = '2026-10-01T00:00:00Z' }
        }
        $changes = @(Get-PEBlueprintChange -Name 'acme' -MasterState $wanted -DataRoot $script:Temp)
        Approve-PEBlueprintChange -Name 'acme' -MasterState $wanted -Accept $changes -Reason 'wanted' -DataRoot $script:Temp | Should -Be 2
        Start-Sleep -Seconds 1
        $result = New-PEUploadCheck -Tenant 'acme' -File @(Get-UploadFile 'entra.ps1') -DataRoot $script:Temp
        @($result.Findings | Where-Object { $_.Kind -eq 'Missing' -and $_.ResourceType -eq 'EXOSharingPolicy' }).Count | Should -Be 0
        $check = Get-PECheck -CheckId $result.CheckId -DataRoot $script:Temp
        @($check.State.NotChecked | Where-Object { $_.ResourceType -eq 'EXOSharingPolicy' }).Reason | Should -Be 'not read by the earlier check'
        @($check.State.NotChecked | Where-Object { $_.ResourceType -eq 'EXOAcceptedDomain' }).Count | Should -Be 0
    }

    It 'marks the types of every layer the tenant follows NotChecked when their workload was not uploaded' {
        # main holds Entra and Exchange; the own blueprint is seeded from an Entra-only upload, so it has no Exchange type.
        New-MainBlueprint -Root $script:Temp
        Set-PETenant -Slug 'acme' -Blueprints @('main') -DataRoot $script:Temp | Out-Null
        New-PEUploadCheck -Tenant 'acme' -File @(Get-UploadFile 'entra.ps1') -TenantDomain 'acme.example' -DataRoot $script:Temp | Out-Null
        Initialize-PETenantBlueprint -Slug 'acme' -MasterBlueprint 'main' -FromCheck -DataRoot $script:Temp | Out-Null
        Start-Sleep -Seconds 1
        $result = New-PEUploadCheck -Tenant 'acme' -File @(Get-UploadFile 'entra.ps1') -DataRoot $script:Temp
        $check = Get-PECheck -CheckId $result.CheckId -DataRoot $script:Temp
        @($check.State.NotChecked | Where-Object { $_.ResourceType -eq 'EXOAcceptedDomain' }).Reason | Should -Be 'workload not uploaded'
        @($check.State.NotChecked | Where-Object { $_.ResourceType -eq 'EXOMailTips' }).Reason | Should -Be 'workload not uploaded'
    }

    It 'leaves no check behind when the tenant domain cannot be stored after the check was written' {
        Mock -ModuleName PolicyEngine Set-PETenant { throw 'registry locked' }
        { New-PEUploadCheck -Tenant 'acme' -File @(Get-UploadFile 'entra.ps1') -TenantDomain 'acme.example' -DataRoot $script:Temp } | Should -Throw '*registry locked*'
        @(Get-ChildItem (Join-Path $script:Temp 'checks') -ErrorAction SilentlyContinue).Count | Should -Be 0
        @(Get-ChildItem (Join-Path $script:Temp 'exports') -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'lets a read error of the earlier check propagate' {
        New-PEUploadCheck -Tenant 'acme' -File @(Get-UploadFile 'entra.ps1') -TenantDomain 'acme.example' -DataRoot $script:Temp | Out-Null
        Mock -ModuleName PolicyEngine Get-PECheck { throw 'disk unreadable' }
        { New-PEUploadCheck -Tenant 'acme' -File @(Get-UploadFile 'entra.ps1') -DataRoot $script:Temp } | Should -Throw '*disk unreadable*'
    }
}
