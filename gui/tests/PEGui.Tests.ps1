BeforeAll {
    Import-Module "$PSScriptRoot/../PEGui.psm1" -Force
    $script:MockData = Resolve-Path "$PSScriptRoot/../mock-data"
    function New-TestDataRoot {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Item -Path $script:MockData -Destination $root -Recurse
        $root
    }
    function Get-TestFinding($Root, $Tenant, $Key) {
        Get-PEGuiFinding -DataRoot $Root -TenantId $Tenant | Where-Object key -EQ $Key | Select-Object -First 1
    }
}

Describe 'Reading view models' {
    BeforeAll { $root = New-TestDataRoot }

    It 'reads the index with both tenants' {
        $index = Get-PEGuiIndex -DataRoot $root
        $index.tenants.tenantId | Should -Be @('master', 'replica')
        $index.blueprint.version | Should -Be 7
    }

    It 'refuses an unknown tenant id' {
        { Get-PEGuiTenantStatus -DataRoot $root -TenantId 'nobody' } | Should -Throw '*Unknown tenant*'
    }

    It 'refuses a tenant id that tries to leave the data root' {
        { Get-PEGuiFinding -DataRoot $root -TenantId '../..' } | Should -Throw '*Unknown tenant*'
    }

    It 'refuses an item id that tries to leave the data root' {
        { Get-PEGuiItem -DataRoot $root -TenantId 'replica' -ItemId '../../index' } | Should -Throw '*Invalid item id*'
    }

    It 'returns an item by id' {
        $id = ConvertTo-PEGuiItemId -ResourceType 'IntuneDeviceConfigurationPolicyWindows10' -Key 'Baseline - Win10'
        $item = Get-PEGuiItem -DataRoot $root -TenantId 'replica' -ItemId $id
        $item.blueprint.PasswordMinimumLength | Should -Be 14
        $item.target.PasswordMinimumLength | Should -Be 8
    }

    It 'encodes item ids so they are safe in paths and URLs' {
        ConvertTo-PEGuiItemId -ResourceType 'AADGroup' -Key 'Guests - Partners' | Should -Be 'AADGroup~Guests%20-%20Partners'
        ConvertTo-PEGuiItemId -ResourceType 'AADGroup' -Key 'a/b' | Should -Be 'AADGroup~a%2Fb'
    }

    It 'returns activity newest first' {
        $jobs = Get-PEGuiActivity -DataRoot $root
        $jobs[0].jobId | Should -Be 'J-1043'
    }

    It 'never counts a not-checked component as aligned' {
        $intune = (Get-PEGuiTenantStatus -DataRoot $root -TenantId 'replica').workloads | Where-Object workload -EQ 'Intune'
        $intune.notChecked | Should -Be 1
        ($intune.types | Where-Object status -EQ 'NotChecked').resourceType | Should -Be 'IntuneSettingCatalogASRRulesPolicyWindows10'
    }
}

Describe 'Allowed actions' {
    BeforeAll { $root = New-TestDataRoot }

    It 'offers Accept, Promote and Exclude on <kind>' -ForEach @(
        @{ kind = 'Missing'; key = 'CA005 - Block high-risk sign-ins' }
        @{ kind = 'TargetOnly'; key = 'CA007 - Test MFA bypass' }
        @{ kind = 'PossibleRename'; key = 'Finance' }
    ) {
        $f = Get-TestFinding $root 'replica' $key
        $f.kind | Should -Be $kind
        $f.allowedActions | Should -Be @('Accept', 'Promote', 'Exclude')
    }

    It 'adds the noise action on Changed findings' {
        (Get-TestFinding $root 'replica' 'CA001 - Require MFA for admins').allowedActions | Should -Contain 'ExcludeProperty'
    }

    It 'offers nothing on <kind>' -ForEach @(
        @{ kind = 'Ambiguous' }, @{ kind = 'NotChecked' }, @{ kind = 'NotAvailable' }, @{ kind = 'Unkeyed' }, @{ kind = 'Unreadable' }
    ) {
        $f = Get-PEGuiFinding -DataRoot $root -TenantId 'replica' | Where-Object kind -EQ $kind | Select-Object -First 1
        @($f.allowedActions).Count | Should -Be 0
    }

    It 'offers only Unexclude on an unmanaged item' {
        (Get-TestFinding $root 'replica' 'Dev Sandbox').allowedActions | Should -Be @('Unexclude')
    }
}

Describe 'Request validation' {
    BeforeAll {
        $root = New-TestDataRoot
        $baseline = ConvertTo-PEGuiItemId 'IntuneDeviceConfigurationPolicyWindows10' 'Baseline - Win10'
        $sales = ConvertTo-PEGuiItemId 'AADGroup' 'Sales'
        $ca003 = ConvertTo-PEGuiItemId 'AADConditionalAccessPolicy' 'CA003 - Require compliant device'
    }

    It 'accepts a replica Accept without a reason and makes a config' {
        $p = Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'Accept'; tenantId = 'replica'; items = @(@{ itemId = $baseline }) }
        $p.valid | Should -BeTrue
        $p.writesMaster | Should -BeFalse
        $p.items[0].effect | Should -Be 'Update the replica to match the blueprint'
        $p.config | Should -Match "PasswordMinimumLength\s+= 14"
    }

    It 'rejects an action the finding does not allow' {
        $p = Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'Accept'; tenantId = 'replica'; items = @(@{ itemId = $sales }) }
        $p.valid | Should -BeFalse
        $p.errors[0] | Should -Match 'not allowed'
    }

    It 'previews promoting everything up as the changes it makes to the master blueprint, without writing a tenant' {
        $p = Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'PromoteUp'; tenantId = 'replica'; items = @(); reason = 'kept' }
        $p.valid | Should -BeTrue
        $p.writesMaster | Should -BeFalse
        $p.config | Should -BeNullOrEmpty
        $p.targetBlueprint | Should -Be 'prod'
        $p.targetVersion | Should -Be 7
        $p.blueprintName | Should -Be 'prod'
        $p.blueprintVersionAfter | Should -Be 8
        @($p.items).Count | Should -Be 2
        ($p.items | Where-Object key -EQ 'CA007 - Test MFA bypass').op | Should -Be 'Added'
        ($p.items | Where-Object key -EQ 'CA007 - Test MFA bypass').effect | Should -BeLike "*blueprint 'prod'*"
    }

    It 'previews updating the tenant blueprint from the master blueprint, and only the items named' {
        $all = Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'PullDown'; tenantId = 'replica'; items = @(); reason = 'catch up' }
        @($all.items).Count | Should -Be 3
        $all.targetBlueprint | Should -Be 'replica'
        $all.targetVersion | Should -Be 3
        $all.sourceVersion | Should -Be 7
        $all.blueprintVersionAfter | Should -Be 4
        ($all.items | Where-Object key -EQ 'Dev Sandbox').op | Should -Be 'Removed'
        $one = Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'PullDown'; tenantId = 'replica'; items = @(@{ itemId = (ConvertTo-PEGuiItemId 'AADGroup' 'Dev Sandbox') }); reason = 'catch up' }
        @($one.items).Count | Should -Be 1
        $one.valid | Should -BeTrue
    }

    It 'refuses a blueprint move without a reason, for an item that is not a difference, and for a tenant with one layer' {
        (Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'PullDown'; tenantId = 'replica'; items = @() }).errors | Should -Contain 'A reason is required for PullDown.'
        $bad = Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'PromoteUp'; tenantId = 'replica'; items = @(@{ itemId = (ConvertTo-PEGuiItemId 'AADGroup' 'Finance') }); reason = 'r' }
        $bad.valid | Should -BeFalse
        ($bad.errors -join ' ') | Should -BeLike '*is not a difference*'
        $one = Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'PromoteUp'; tenantId = 'master'; items = @(); reason = 'r' }
        $one.valid | Should -BeFalse
        ($one.errors -join ' ') | Should -BeLike '*one blueprint layer*'
        (Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'PullDown'; tenantId = 'nobody'; items = @(); reason = 'r' }).valid | Should -BeFalse
    }

    It 'saves the reviewed target version with a blueprint move' {
        $mine = New-TestDataRoot
        $r = New-PEGuiRequest -DataRoot $mine -Request @{ action = 'PullDown'; tenantId = 'replica'; items = @(); reason = 'catch up' }
        $r.created | Should -BeTrue
        $saved = Get-Content (Join-Path $mine "requests/$($r.requestId).json") -Raw | ConvertFrom-Json
        $saved.expectedVersion | Should -Be 3
        $saved.expectedSourceVersion | Should -Be 7
        $saved.action | Should -Be 'PullDown'
        @($saved.items).Count | Should -Be 3
    }

    It 'rejects an unknown action' {
        (Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'Delete'; tenantId = 'replica'; items = @(@{ itemId = $baseline }) }).valid | Should -BeFalse
    }

    It 'requires a reason for <action>' -ForEach @(@{ action = 'Exclude' }, @{ action = 'Promote' }) {
        $p = Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = $action; tenantId = 'replica'; items = @(@{ itemId = $baseline }); confirmedMasterWrite = $true }
        $p.errors | Should -Contain "A reason is required for $action."
    }

    It 'writes only the replica own blueprint for Promote from the replica, so no master confirm is needed' {
        $p = Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'Promote'; tenantId = 'replica'; items = @(@{ itemId = $baseline }); reason = 'r' }
        $p.writesMaster | Should -BeFalse
        $p.valid | Should -BeTrue
        $p.blueprintName | Should -Be 'replica'
        $p.blueprintVersionAfter | Should -Be 4
        $p.config | Should -BeNullOrEmpty
        $p.items[0].effect | Should -Not -Match 'master'
    }

    It 'requires the master confirm for Accept on the master' {
        $p = Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'Accept'; tenantId = 'master'; items = @(@{ itemId = $ca003 }) }
        $p.writesMaster | Should -BeTrue
        $p.valid | Should -BeFalse
    }

    It 'does not write to any tenant for Promote on the master' {
        $p = Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'Promote'; tenantId = 'master'; items = @(@{ itemId = $ca003 }); reason = 'r' }
        $p.valid | Should -BeTrue
        $p.writesMaster | Should -BeFalse
        $p.config | Should -BeNullOrEmpty
    }

    It 'takes a noise value from the finding, not the request' {
        $p = Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'ExcludeProperty'; tenantId = 'replica'; items = @(@{ itemId = $baseline; property = 'DefenderScanType'; value = 'anything' }); reason = 'noise' }
        $p.valid | Should -BeTrue
        $p.items[0].value | Should -Be 'quick'
    }

    It 'rejects a noise rule for a property that does not differ' {
        $p = Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'ExcludeProperty'; tenantId = 'replica'; items = @(@{ itemId = $baseline; property = 'FirewallEnabled' }); reason = 'noise' }
        $p.valid | Should -BeFalse
    }

    It 'previews a blueprint revert with the changes it makes' {
        $p = Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'RevertBlueprint'; targetVersion = 5; reason = 'undo' }
        $p.valid | Should -BeTrue
        $p.blueprintVersionAfter | Should -Be 8
        ($p.items | Where-Object key -EQ 'CA008 - Test policy').effect | Should -Be 'Added in the blueprint'
        ($p.items | Where-Object key -EQ 'Block executable attachments').effect | Should -Be 'Removed in the blueprint'
    }

    It 'rejects a revert to the current version' {
        (Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'RevertBlueprint'; targetVersion = 7; reason = 'x' }).valid | Should -BeFalse
    }

    It 'restores a single item' {
        $id = ConvertTo-PEGuiItemId 'EXOTransportRule' 'Block executable attachments'
        $p = Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'RevertBlueprint'; targetVersion = 6; reason = 'x'; items = @(@{ itemId = $id }) }
        $p.valid | Should -BeTrue
        @($p.items).Count | Should -Be 1
    }

    It 'brings back an existing noise rule and rejects an unknown one' {
        $ok = Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'Unexclude'; items = @(@{ resourceType = 'TeamsMeetingPolicy'; property = 'Description'; value = '' }) }
        $ok.valid | Should -BeTrue
        $bad = Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'Unexclude'; items = @(@{ resourceType = 'TeamsMeetingPolicy'; property = 'Description'; value = 'x' }) }
        $bad.valid | Should -BeFalse
    }
}

Describe 'Writing requests and mock jobs' {
    BeforeAll {
        $root = New-TestDataRoot
        $baseline = ConvertTo-PEGuiItemId 'IntuneDeviceConfigurationPolicyWindows10' 'Baseline - Win10'
        $t0 = [datetime]::new(2026, 10, 21, 12, 0, 0, [DateTimeKind]::Utc)
    }

    It 'writes nothing for an invalid request' {
        $r = New-PEGuiRequest -DataRoot $root -Request @{ action = 'Promote'; tenantId = 'replica'; items = @(@{ itemId = $baseline }); reason = '' } -Now $t0
        $r.created | Should -BeFalse
        Test-Path (Join-Path $root 'requests') | Should -BeFalse
    }

    It 'writes the request and a queued job, and records that no master is written' {
        $r = New-PEGuiRequest -DataRoot $root -Request @{ action = 'Promote'; tenantId = 'replica'; items = @(@{ itemId = $baseline }); reason = 'r' } -Now $t0
        $r.created | Should -BeTrue
        $r.jobId | Should -Be 'J-1044'
        $saved = Get-Content (Join-Path $root "requests/$($r.requestId).json") -Raw | ConvertFrom-Json
        $saved.confirmedMasterWrite | Should -BeFalse
        $saved.items[0].findingKind | Should -Be 'Changed'
        (Get-PEGuiActivity -DataRoot $root)[0].status | Should -Be 'Queued'
    }

    It 'runs then completes a mock job' {
        Update-PEGuiMockJob -DataRoot $root -Now $t0.AddSeconds(2)
        (Get-PEGuiActivity -DataRoot $root)[0].status | Should -Be 'Running'
        Update-PEGuiMockJob -DataRoot $root -Now $t0.AddSeconds(5)
        $job = (Get-PEGuiActivity -DataRoot $root)[0]
        $job.status | Should -Be 'Succeeded'
        $job.result | Should -Match 'Blueprint v4'
    }

    It 'leaves jobs the GUI did not queue alone' {
        Update-PEGuiMockJob -DataRoot $root -Now $t0.AddHours(1)
        ((Get-PEGuiActivity -DataRoot $root) | Where-Object jobId -EQ 'J-1043').status | Should -Be 'Running'
    }
}

Describe 'API dispatcher' {
    BeforeAll { $root = New-TestDataRoot }

    It 'answers <path> with 200' -ForEach @(
        @{ path = '/api/index' }, @{ path = '/api/resource-types' }, @{ path = '/api/blueprint' }, @{ path = '/api/exclusions' },
        @{ path = '/api/activity' }, @{ path = '/api/tenants/replica/status' }, @{ path = '/api/tenants/replica/findings' },
        @{ path = '/api/tenants/master/items' }
    ) {
        $r = Invoke-PEGuiApi -DataRoot $root -Method GET -Path $path
        $r.StatusCode | Should -Be 200
        { $r.Json | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'returns lists as a flat JSON array of objects' -ForEach @(@{ path = '/api/activity' }, @{ path = '/api/tenants/replica/items' }, @{ path = '/api/blueprint' }) {
        $parsed = (Invoke-PEGuiApi -DataRoot $root -Method GET -Path $path).Json | ConvertFrom-Json -NoEnumerate
        $parsed.GetType().Name | Should -Be 'Object[]'
        $parsed[0] | Should -BeOfType [pscustomobject]
    }

    It 'returns findings with allowed actions' {
        $list = (Invoke-PEGuiApi -DataRoot $root -Method GET -Path '/api/tenants/master/findings').Json | ConvertFrom-Json
        $list.Count | Should -BeGreaterThan 1
        ($list | Where-Object key -EQ 'Contractors').allowedActions | Should -Contain 'Promote'
    }

    It 'returns an item by query id' {
        $r = Invoke-PEGuiApi -DataRoot $root -Method GET -Path '/api/tenants/replica/item' -Query @{ id = 'AADGroup~Finance' }
        $r.StatusCode | Should -Be 200
        ($r.Json | ConvertFrom-Json).target.DisplayName | Should -Be 'Finance Team'
    }

    It 'answers 400 for an unknown tenant and 404 for an unknown route' {
        (Invoke-PEGuiApi -DataRoot $root -Method GET -Path '/api/tenants/nobody/status').StatusCode | Should -Be 400
        (Invoke-PEGuiApi -DataRoot $root -Method GET -Path '/api/nothing').StatusCode | Should -Be 404
    }

    It 'answers 400 with the reasons for an invalid request, and 201 for a valid one' {
        $bad = Invoke-PEGuiApi -DataRoot $root -Method POST -Path '/api/requests' -Body @{ action = 'Exclude'; tenantId = 'replica'; items = @(@{ itemId = 'AADGroup~Sales' }) }
        $bad.StatusCode | Should -Be 400
        ($bad.Json | ConvertFrom-Json).errors | Should -Not -BeNullOrEmpty
        $ok = Invoke-PEGuiApi -DataRoot $root -Method POST -Path '/api/requests' -Body @{ action = 'Exclude'; tenantId = 'replica'; items = @(@{ itemId = 'AADGroup~Finance' }); reason = 'test' }
        $ok.StatusCode | Should -Be 201
    }
}

Describe 'Edge cases from review' {
    BeforeAll {
        $baseline = ConvertTo-PEGuiItemId 'IntuneDeviceConfigurationPolicyWindows10' 'Baseline - Win10'
        $ca003 = ConvertTo-PEGuiItemId 'AADConditionalAccessPolicy' 'CA003 - Require compliant device'
    }

    It 'returns [] for empty lists, never [null]' {
        $root = New-TestDataRoot
        Set-Content (Join-Path $root 'tenants/master/findings.json') '[]'
        Remove-Item (Join-Path $root 'activity') -Recurse
        (Invoke-PEGuiApi -DataRoot $root -Method GET -Path '/api/tenants/master/findings').Json | Should -Be '[]'
        (Invoke-PEGuiApi -DataRoot $root -Method GET -Path '/api/activity').Json | Should -Be '[]'
        (Invoke-PEGuiApi -DataRoot $root -Method GET -Path '/api/activity/active').Json | Should -Be '[]'
    }

    It 'resolves a relative data root against the PowerShell location' {
        $root = New-TestDataRoot
        Push-Location (Split-Path $root)
        try { (Invoke-PEGuiApi -DataRoot (Split-Path $root -Leaf) -Method GET -Path '/api/index').StatusCode | Should -Be 200 }
        finally { Pop-Location }
    }

    It 'rejects a tenant id in the wrong case' {
        $root = New-TestDataRoot
        (Invoke-PEGuiApi -DataRoot $root -Method GET -Path '/api/tenants/MASTER/status').StatusCode | Should -Be 400
    }

    It 'compares by net change: added then removed is no change' {
        $root = New-TestDataRoot
        $v = Get-PEGuiBlueprintVersion -DataRoot $root
        $c = Compare-PEGuiBlueprintVersion -Versions $v -From 4 -To 6
        $c.key | Should -Not -Contain 'CA008 - Test policy'
        ($c | Where-Object key -EQ 'Students').op | Should -Be 'Changed'
        $back = Compare-PEGuiBlueprintVersion -Versions $v -From 7 -To 4
        $back.key | Should -Not -Contain 'CA008 - Test policy'
        ($back | Where-Object key -EQ 'Block executable attachments').op | Should -Be 'Removed'
    }

    It 'serves the findings against another blueprint layer, each offering only the blueprint update' {
        $root = New-TestDataRoot
        $r = Invoke-PEGuiApi -DataRoot $root -Method GET -Path '/api/tenants/replica/layer-findings' -Query @{ layer = 'prod' }
        $r.StatusCode | Should -Be 200
        $rows = @($r.Json | ConvertFrom-Json)
        $rows.Count | Should -Be 12
        $rows[0].layer | Should -Be 'prod'
        $rows[0].allowedActions | Should -Be @('PullDown')
    }

    It 'serves no findings for a layer that was not exported, and refuses a layer name that leaves the folder' {
        $root = New-TestDataRoot
        (Invoke-PEGuiApi -DataRoot $root -Method GET -Path '/api/tenants/replica/layer-findings' -Query @{ layer = 'nothing' }).Json | Should -Be '[]'
        (Invoke-PEGuiApi -DataRoot $root -Method GET -Path '/api/tenants/replica/layer-findings' -Query @{ layer = '../../index' }).StatusCode | Should -Be 400
        (Invoke-PEGuiApi -DataRoot $root -Method GET -Path '/api/tenants/replica/layer-findings').StatusCode | Should -Be 400
    }

    It 'serves the compare through the API' {
        $root = New-TestDataRoot
        $r = Invoke-PEGuiApi -DataRoot $root -Method GET -Path '/api/blueprint/compare' -Query @{ from = '4'; to = '6' }
        $r.StatusCode | Should -Be 200
        ($r.Json | ConvertFrom-Json).key | Should -Contain 'Students'
    }

    It 'gives each Promote its own blueprint version' {
        $root = New-TestDataRoot
        $a = New-PEGuiRequest -DataRoot $root -Request @{ action = 'Promote'; tenantId = 'replica'; items = @(@{ itemId = $baseline }); reason = 'r' }
        $b = New-PEGuiRequest -DataRoot $root -Request @{ action = 'Promote'; tenantId = 'master'; items = @(@{ itemId = $ca003 }); reason = 'r' }
        $c = New-PEGuiRequest -DataRoot $root -Request @{ action = 'Promote'; tenantId = 'replica'; items = @(@{ itemId = (ConvertTo-PEGuiItemId 'TeamsMessagingPolicy' 'Contractors') }); reason = 'r' }
        $jobs = Get-PEGuiActivity -DataRoot $root
        ($jobs | Where-Object jobId -EQ $a.jobId).blueprintVersionAfter | Should -Be 4
        ($jobs | Where-Object jobId -EQ $b.jobId).blueprintVersionAfter | Should -Be 8
        ($jobs | Where-Object jobId -EQ $c.jobId).blueprintVersionAfter | Should -Be 5
        (Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'RevertBlueprint'; targetVersion = 5; reason = 'x' }).blueprintVersionAfter | Should -Be 9
    }

    It 'gives every concurrent request its own job' {
        $root = New-TestDataRoot
        $module = Resolve-Path "$PSScriptRoot/../PEGui.psm1"
        $ids = 1..6 | ForEach-Object -ThrottleLimit 6 -Parallel {
            Import-Module $using:module
            (New-PEGuiRequest -DataRoot $using:root -Request @{ action = 'Exclude'; tenantId = 'replica'; items = @(@{ itemId = 'AADGroup~Finance' }); reason = "r$_" }).jobId
        }
        @($ids | Sort-Object -Unique).Count | Should -Be 6
        @(Get-PEGuiActiveJob -DataRoot $root).Count | Should -Be 6
    }

    It 'marks a rename Accept as destructive because it deletes the renamed item' {
        $root = New-TestDataRoot
        $p = Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'Accept'; tenantId = 'replica'; items = @(@{ itemId = 'AADGroup~Finance' }) }
        $p.destructive | Should -BeTrue
        $p.config | Should -Match "Ensure\s+= 'Absent'"
    }

    It 'shows no tenant configuration for a Promote, which only writes a blueprint' {
        $root = New-TestDataRoot
        $p = Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'Promote'; tenantId = 'replica'; items = @(@{ itemId = $baseline }); reason = 'r' }
        $p.config | Should -BeNullOrEmpty
    }

    It 'uses the resource type key property in a removal' {
        $root = New-TestDataRoot
        $id = ConvertTo-PEGuiItemId 'TeamsMessagingPolicy' 'Contractors'
        $p = Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'Accept'; tenantId = 'replica'; items = @(@{ itemId = $id }) }
        $p.config | Should -Match "Identity\s+= 'Contractors'"
        $p.config | Should -Not -Match 'DisplayName'
    }

    It 'says whether a reason is required' {
        $root = New-TestDataRoot
        (Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'Accept'; tenantId = 'replica'; items = @(@{ itemId = $baseline }) }).reasonRequired | Should -BeFalse
        (Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'Exclude'; tenantId = 'replica'; items = @(@{ itemId = $baseline }) }).reasonRequired | Should -BeTrue
    }

    It 'advances only active jobs and empties the active list when they finish' {
        $root = New-TestDataRoot
        $t0 = [datetime]::new(2026, 10, 21, 12, 0, 0, [DateTimeKind]::Utc)
        $r = New-PEGuiRequest -DataRoot $root -Request @{ action = 'Accept'; tenantId = 'replica'; items = @(@{ itemId = $baseline }) } -Now $t0
        Update-PEGuiMockJob -DataRoot $root -Now $t0.AddSeconds(5)
        ((Get-PEGuiActivity -DataRoot $root) | Where-Object jobId -EQ $r.jobId).status | Should -Be 'Succeeded'
        @(Get-PEGuiActiveJob -DataRoot $root).Count | Should -Be 0
    }
}

Describe 'UploadSnapshot requests' {
    BeforeAll {
        $root = New-TestDataRoot
        $file = @{ name = 'entra.ps1'; text = 'Configuration x {}' }
        function New-Upload ($Override = @{}) {
            $r = @{ action = 'UploadSnapshot'; tenantId = 'acme'; files = @($file); tenantDomain = 'acme.example'; completeWorkloads = @(); saveAsBlueprint = $false; newTenant = @{ slug = 'acme'; displayName = 'Acme' } }
            foreach ($k in $Override.Keys) { $r[$k] = $Override[$k] }
            $r
        }
    }

    It 'queues a valid upload for a new tenant and keeps the file text in the request' {
        $r = New-PEGuiRequest -DataRoot $root -Request (New-Upload)
        $r.created | Should -BeTrue -Because ($r.errors -join '; ')
        $saved = Get-Content -LiteralPath (Join-Path $root "requests/$($r.requestId).json") -Raw | ConvertFrom-Json
        $saved.action | Should -Be 'UploadSnapshot'
        $saved.files[0].name | Should -Be 'entra.ps1'
        $saved.newTenant.slug | Should -Be 'acme'
        $saved.tenantId | Should -Be 'acme'
    }

    It 'rejects <Name>' -ForEach @(
        @{ Name = 'no files'; Override = @{ files = @() }; Match = '*at least one file*' }
        @{ Name = 'a file without a name'; Override = @{ files = @(@{ text = 'x' }) }; Match = '*name*' }
        @{ Name = 'a file without text'; Override = @{ files = @(@{ name = 'a.ps1'; text = '' }) }; Match = '*text*' }
        @{ Name = 'a bad slug'; Override = @{ tenantId = 'Bad Slug'; newTenant = @{ slug = 'Bad Slug'; displayName = 'x' } }; Match = '*short name*' }
        @{ Name = 'the master as a new tenant'; Override = @{ tenantId = 'master'; newTenant = @{ slug = 'master'; displayName = 'x' } }; Match = '*master*' }
        @{ Name = 'a new tenant whose slug exists'; Override = @{ tenantId = 'replica'; newTenant = @{ slug = 'replica'; displayName = 'x' } }; Match = '*already*' }
        @{ Name = 'an unknown existing tenant'; Override = @{ tenantId = 'nobody'; newTenant = $null }; Match = '*nobody*' }
        @{ Name = 'a bad tenant domain'; Override = @{ tenantDomain = 'not a domain!' }; Match = '*tenant domain*' }
        @{ Name = 'a tenant domain with a trailing newline'; Override = @{ tenantDomain = "acme.example`n" }; Match = '*tenant domain*' }
        @{ Name = 'a short name with a trailing newline'; Override = @{ tenantId = "acme`n"; newTenant = @{ slug = "acme`n"; displayName = 'x' } }; Match = '*short name*' }
    ) {
        $r = New-PEGuiRequest -DataRoot $root -Request (New-Upload $Override)
        $r.created | Should -BeFalse
        ($r.errors -join '; ') | Should -BeLike $Match
    }

    It 'creates and reads back a request with 8 MB of file text intact' {
        $text = 'Configuration x {' + ([string][char]0xE9 * 4MB) + "`n" + ('a' * (4MB - 20)) + '}'
        $r = New-PEGuiRequest -DataRoot $root -Request (New-Upload @{ files = @(@{ name = 'big.ps1'; text = $text }) })
        $r.created | Should -BeTrue -Because ($r.errors -join '; ')
        $saved = Get-Content -LiteralPath (Join-Path $root "requests/$($r.requestId).json") -Raw | ConvertFrom-Json
        $saved.files[0].text | Should -BeExactly $text
    }

    It 'a queued upload can still be cancelled' {
        $r = New-PEGuiRequest -DataRoot $root -Request (New-Upload)
        (Stop-PEGuiJob -DataRoot $root -JobId $r.jobId).StatusCode | Should -Be 200
        (Get-Content -LiteralPath (Join-Path $root "activity/$($r.jobId).json") -Raw | ConvertFrom-Json).status | Should -Be 'Cancelled'
    }

    It 'a running upload cannot be cancelled' {
        $r = New-PEGuiRequest -DataRoot $root -Request (New-Upload)
        $path = Join-Path $root "activity/$($r.jobId).json"
        $job = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -DateKind String
        $job.status = 'Running'
        $job | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path
        (Stop-PEGuiJob -DataRoot $root -JobId $r.jobId).StatusCode | Should -Be 400
    }
}

Describe 'GenerateConfig requests and the configuration downloads' {
    BeforeAll {
        function Set-TestJob ($Root, $JobId, [hashtable]$Change) {
            $path = Join-Path $Root "activity/$JobId.json"
            $job = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -DateKind String
            foreach ($k in $Change.Keys) { $job | Add-Member -NotePropertyName $k -NotePropertyValue $Change[$k] -Force }
            $job | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path
        }
        function New-GeneratedJob ($Root, [switch]$NoRemovals) {
            # A finished GenerateConfig job and the files the worker writes for it.
            $r = New-PEGuiRequest -DataRoot $Root -Request @{ action = 'GenerateConfig'; tenantId = 'replica' }
            $r.created | Should -BeTrue -Because ($r.errors -join '; ')
            Set-TestJob $Root $r.jobId @{ status = 'Succeeded'; files = @{ changes = 1; removals = $(if ($NoRemovals) { 0 } else { 1 }); manual = 1 } }
            $folder = Join-Path $Root "configs/$($r.jobId)"
            New-Item -ItemType Directory -Force -Path $folder | Out-Null
            Set-Content -LiteralPath (Join-Path $folder 'Changes.ps1') -Value "Configuration PE_Changes`n{`n}" -Encoding utf8BOM
            if (-not $NoRemovals) { Set-Content -LiteralPath (Join-Path $folder 'Removals.ps1') -Value "Configuration PE_Removals`n{`n}" -Encoding utf8BOM }
            Set-Content -LiteralPath (Join-Path $folder 'Manual.json') -Value '[{"ResourceType":"AADGroup","Key":"Hidden","Action":"Create","Reason":"ignored/secret"}]' -Encoding utf8
            $r.jobId
        }
        function Get-Download ($Root, $JobId, $File) { Invoke-PEGuiApi -DataRoot $Root -Method GET -Path "/api/jobs/$JobId/config/$File" }
    }
    BeforeEach { $root = New-TestDataRoot }

    It 'queues a GenerateConfig job for a tenant with its own blueprint, with no items' {
        $r = New-PEGuiRequest -DataRoot $root -Request @{ action = 'GenerateConfig'; tenantId = 'replica' }
        $r.created | Should -BeTrue -Because ($r.errors -join '; ')
        $saved = Get-Content -LiteralPath (Join-Path $root "requests/$($r.requestId).json") -Raw | ConvertFrom-Json
        $saved.action | Should -Be 'GenerateConfig'
        $saved.tenantId | Should -Be 'replica'
        @($saved.items).Count | Should -Be 0
        $job = Get-Content -LiteralPath (Join-Path $root "activity/$($r.jobId).json") -Raw | ConvertFrom-Json
        $job.action | Should -Be 'GenerateConfig'
        $job.config | Should -BeNullOrEmpty
    }

    It 'refuses GenerateConfig for <Name>' -ForEach @(
        @{ Name = 'an unknown tenant'; TenantId = 'nobody'; Match = '*nobody*' }
        @{ Name = 'the master'; TenantId = 'master'; Match = '*master*blueprint*' }
        @{ Name = 'a tenant without a blueprint of its own'; TenantId = 'solo'; Match = '*no blueprint of its own*' }
    ) {
        $indexPath = Join-Path $root 'index.json'
        $index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
        $solo = [pscustomobject]@{ tenantId = 'solo'; role = 'Replica'; displayName = 'Solo'; offline = $true; layers = @([pscustomobject]@{ name = 'prod'; version = 7 }) }
        $index.tenants = @($index.tenants) + $solo
        $index | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $indexPath
        $r = New-PEGuiRequest -DataRoot $root -Request @{ action = 'GenerateConfig'; tenantId = $TenantId }
        $r.created | Should -BeFalse
        ($r.errors -join '; ') | Should -BeLike $Match
    }

    It 'serves Changes and Removals as plain text downloads named after the job' {
        $id = New-GeneratedJob $root
        $changes = Get-Download $root $id 'Changes'
        $changes.StatusCode | Should -Be 200
        $changes.Text | Should -BeLike 'Configuration PE_Changes*'
        [int]$changes.Text[0] | Should -Not -Be 0xFEFF
        $changes.ContentType | Should -Be 'text/plain'
        $changes.FileName | Should -Be "$id-Changes.ps1"
        $removals = Get-Download $root $id 'Removals'
        $removals.StatusCode | Should -Be 200
        $removals.Text | Should -BeLike 'Configuration PE_Removals*'
        $removals.FileName | Should -Be "$id-Removals.ps1"
    }

    It 'serves the manual list as JSON' {
        $id = New-GeneratedJob $root
        $manual = Get-Download $root $id 'Manual'
        $manual.StatusCode | Should -Be 200
        $manual.ContentType | Should -Be 'application/json'
        $manual.FileName | Should -Be "$id-Manual.json"
        $list = @($manual.Text | ConvertFrom-Json)
        $list[0].Key | Should -Be 'Hidden'
        $list[0].Reason | Should -Be 'ignored/secret'
    }

    It 'answers 404 for a file the job does not have' {
        $id = New-GeneratedJob $root -NoRemovals
        $r = Get-Download $root $id 'Removals'
        $r.StatusCode | Should -Be 404
        $r.PSObject.Properties['Text'] | Should -BeNullOrEmpty
    }

    It 'answers 404 for the file name <File>' -ForEach @(
        @{ File = 'Other' }, @{ File = 'changes' }, @{ File = 'Changes.ps1' }, @{ File = '..%2F..%2Findex' }, @{ File = 'Manual.json' }
    ) {
        $id = New-GeneratedJob $root
        $r = Get-Download $root $id $File
        $r.StatusCode | Should -Be 404
        $r.PSObject.Properties['Text'] | Should -BeNullOrEmpty
    }

    It 'answers 404 for a job id that is not one, and for a job that does not exist' -ForEach @(@{ JobId = 'J-x' }, @{ JobId = '..' }, @{ JobId = 'J-99999' }) {
        $r = Get-Download $root $JobId 'Changes'
        $r.StatusCode | Should -Be 404
        $r.PSObject.Properties['Text'] | Should -BeNullOrEmpty
    }

    It 'answers 404 for a real job id with a line break or a non-ASCII digit after it' {
        $id = New-GeneratedJob $root
        foreach ($bad in "$id`n", "$id$([char]0x0661)") {
            $r = Get-Download $root $bad 'Changes'
            $r.StatusCode | Should -Be 404 -Because "job id '$bad'"
            $r.PSObject.Properties['Text'] | Should -BeNullOrEmpty
        }
    }

    It 'answers 404 for a job of another action, even with files in its folder' {
        $id = New-GeneratedJob $root
        Set-TestJob $root $id @{ action = 'Recheck' }
        (Get-Download $root $id 'Changes').StatusCode | Should -Be 404
    }

    It 'answers 404 while the job has not finished' {
        $id = New-GeneratedJob $root
        Set-TestJob $root $id @{ status = 'Running' }
        (Get-Download $root $id 'Changes').StatusCode | Should -Be 404
    }

    It 'a running GenerateConfig cannot be cancelled' {
        $r = New-PEGuiRequest -DataRoot $root -Request @{ action = 'GenerateConfig'; tenantId = 'replica' }
        Set-TestJob $root $r.jobId @{ status = 'Running' }
        (Stop-PEGuiJob -DataRoot $root -JobId $r.jobId).StatusCode | Should -Be 400
    }

    It 'registers the download route in the server and writes a file reply as text with its own content type and name' {
        $server = Get-Content -LiteralPath "$PSScriptRoot/../server.ps1" -Raw
        $server | Should -Match "'/api/jobs/:jobId/config/:file'"
        $server | Should -Match "Set-PodeHeader -Name 'Content-Disposition'"
        $server | Should -Match 'Write-PodeTextResponse -Value \$r\.Text -ContentType \$r\.ContentType'
    }
}

Describe 'Tenant blueprint versions over the API' {
    BeforeEach {
        $script:Root = New-TestDataRoot
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Root 'blueprint\dev') | Out-Null
        ConvertTo-Json -InputObject @(@{ version = 2; at = '2026-10-22T00:00:00Z'; source = 'Accept'; revertTo = $null; reason = 'b'; changes = @() }, @{ version = 1; at = '2026-10-21T00:00:00Z'; source = 'Initial'; revertTo = $null; reason = 'a'; changes = @() }) -Depth 5 |
            Set-Content -LiteralPath (Join-Path $script:Root 'blueprint\dev\versions.json') -Encoding utf8
    }

    It 'returns the versions of a named tenant blueprint, oldest first, and the master ones without a name' {
        (Get-PEGuiBlueprintVersion -DataRoot $script:Root -Name 'dev').version | Should -Be @(1, 2)
        @(Get-PEGuiBlueprintVersion -DataRoot $script:Root).Count | Should -BeGreaterThan 0
        $r = Invoke-PEGuiApi -DataRoot $script:Root -Method GET -Path '/api/blueprint' -Query @{ name = 'dev' }
        $r.StatusCode | Should -Be 200
        @($r.Json | ConvertFrom-Json).Count | Should -Be 2
    }

    It 'returns nothing for a name that is not a blueprint name or has no file, and never reads outside the blueprint folder' {
        @(Get-PEGuiBlueprintVersion -DataRoot $script:Root -Name 'nope').Count | Should -Be 0
        @(Get-PEGuiBlueprintVersion -DataRoot $script:Root -Name '..\..\index').Count | Should -Be 0
        @(Get-PEGuiBlueprintVersion -DataRoot $script:Root -Name 'a/b').Count | Should -Be 0
    }
}
