BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    Import-Module "$PSScriptRoot\..\gui\PEGui.psm1" -Force

    function New-TestRecord
    {
        param ([string]$Type = 'AADGroup', [string]$Key, [hashtable]$Props = @{}, [string]$Workload = 'Entra ID')
        $p = [ordered]@{ DisplayName = $Key; MailNickname = ($Key -replace '[^A-Za-z0-9]', '').ToLowerInvariant() + 'nick'; SecurityEnabled = $true; MailEnabled = $false; Description = "About $Key"; Ensure = 'Present' }
        foreach ($k in $Props.Keys) { $p[$k] = $Props[$k] }
        [pscustomobject]@{ ResourceType = $Type; Key = $Key; Workload = $Workload; Properties = $p }
    }

    function New-TestState
    {
        param ([object[]]$Records = @())
        & (Get-Module PolicyEngine) {
            param ($r)
            New-PEState -Records $r -NotChecked @() -Meta @{ TenantId = 't'; ExportedAt = '2026-10-21T01:02:03Z'; Source = 'test' }
        } $Records
    }

    function Send-Request
    {
        param ([hashtable]$Body)
        $reply = Invoke-PEGuiApi -DataRoot $script:Gui -Method POST -Path '/api/requests' -Body ([pscustomobject]$Body)
        $reply.StatusCode | Should -Be 201 -Because $reply.Json
        ($reply.Json | ConvertFrom-Json).jobId
    }

    function Get-TestVersion
    {
        param ([string]$Name, [string]$Root)
        & (Get-Module PolicyEngine) { @(Get-PEBlueprintVersionNumber -Directory (Get-PEBlueprintDirectory -Name $args[0] -DataRoot $args[1])) } $Name $Root
    }

    function Add-ReplicaCheck
    {
        # Registers replica 'dev' with its own blueprint 'dev' and a stored Full check of it against that blueprint.
        param ([object[]]$OwnRecords, [object[]]$TenantRecords)
        Set-PETenant -Slug 'dev' -DisplayName 'Dev' -TenantId 'dev.onmicrosoft.com' -DataRoot $script:Temp | Out-Null
        Initialize-PEBlueprint -Name 'dev' -State (New-TestState -Records $OwnRecords) -DataRoot $script:Temp | Out-Null
        Set-PETenant -Slug 'dev' -Blueprints @('main', 'dev') -DataRoot $script:Temp | Out-Null
        $state = New-TestState -Records $TenantRecords
        $findings = @(Compare-PEState -Blueprint (Get-PEBlueprint -Name 'dev' -DataRoot $script:Temp) -Target $state)
        $directory = Join-Path (Join-Path $script:Temp 'checks') '20261021-030000'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        [ordered]@{ CheckId = '20261021-030000'; Kind = 'Full'; TenantSlug = 'dev'; BlueprintName = 'dev'; BlueprintVersion = 1; Findings = $findings; State = $state } |
            ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $directory 'result.json') -Encoding utf8
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
    }

    function Get-TestJob
    {
        param ($Id)
        Get-Content -LiteralPath (Join-Path $script:Gui "activity\$Id.json") -Raw | ConvertFrom-Json -DateKind String
    }
}

Describe 'Invoke-PEGuiRequest' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-guireq-' + [guid]::NewGuid())
        $script:Gui = Join-Path $script:Temp 'gui'
        Initialize-PEBlueprint -Name 'main' -State (New-TestState -Records @((New-TestRecord -Key 'Sales' -Props @{ Description = 'one' }), (New-TestRecord -Key 'Finance'))) -DataRoot $script:Temp | Out-Null
        $target = New-TestState -Records @((New-TestRecord -Key 'Sales' -Props @{ Description = 'two' }), (New-TestRecord -Key 'Finance'), (New-TestRecord -Key 'Extra'))
        $findings = @(Compare-PEState -Blueprint (Get-PEBlueprint -Name 'main' -DataRoot $script:Temp) -Target $target)
        $directory = Join-Path $script:Temp 'checks\20261021-020000'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        [ordered]@{ CheckId = '20261021-020000'; Kind = 'Full'; BlueprintName = 'main'; BlueprintVersion = 1; Findings = $findings; State = $target } |
            ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $directory 'result.json') -Encoding utf8
        # Generating the revert previews costs about 5 s; the Describe below covers them.
        Mock -ModuleName PolicyEngine Get-PEGuiRevertConfig { @{ Wrapper = $null; Items = @{} } }
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'queues a job that is not a mock job and leaves it alone until the worker runs' {
        $id = Send-Request @{ action = 'Exclude'; tenantId = 'master'; reason = 'retired'; items = @(@{ itemId = 'AADGroup~Extra' }) }
        (Get-TestJob $id).status | Should -Be 'Queued'
        (Get-TestJob $id).mock | Should -BeFalse
    }

    It 'excludes a target-only item as an Unmanaged decision' {
        $id = Send-Request @{ action = 'Exclude'; tenantId = 'master'; reason = 'retired'; items = @(@{ itemId = 'AADGroup~Extra' }) }
        (Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui).Processed | Should -Be 1
        (Get-TestJob $id).status | Should -Be 'Succeeded'
        @(Get-PEDecision -Kind Unmanaged -DataRoot $script:Temp).Key | Should -Contain 'Extra'
        $exclusions = Get-Content (Join-Path $script:Gui 'exclusions.json') -Raw | ConvertFrom-Json
        $exclusions.unmanaged[0].itemId | Should -Be 'AADGroup~Extra'
        @(Get-Content (Join-Path $script:Gui 'activity\active.json') -Raw | ConvertFrom-Json).Count | Should -Be 0
    }

    It 'records a noise rule for one property' {
        $id = Send-Request @{ action = 'ExcludeProperty'; tenantId = 'master'; reason = 'noisy'; items = @(@{ itemId = 'AADGroup~Sales'; property = 'Description' }) }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        (Get-TestJob $id).status | Should -Be 'Succeeded'
        $rule = @(Get-PEDecision -Kind Noise -DataRoot $script:Temp)[0]
        $rule.Property | Should -Be 'Description'
        $rule.Value | Should -Be 'two'
    }

    It 'promotes a master change into a new blueprint version without touching a tenant' {
        $id = Send-Request @{ action = 'Promote'; tenantId = 'master'; reason = 'agreed'; items = @(@{ itemId = 'AADGroup~Sales' }) }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $job = Get-TestJob $id
        $job.status | Should -Be 'Succeeded' -Because $job.result
        $job.result | Should -BeLike 'Blueprint v2 recorded*No tenant was changed*'
        $sales = (Get-PEBlueprint -Name 'main' -DataRoot $script:Temp).Records | Where-Object Key -EQ 'Sales'
        $sales.Properties.Description | Should -Be 'two'
        (Get-Content (Join-Path $script:Gui 'index.json') -Raw | ConvertFrom-Json).blueprint.version | Should -Be 2
    }

    It 'a Promote compares just the promoted items with the new version again, so they leave the latest check without reading the tenant' {
        $before = Get-PECheck -Latest -Kind Full -DataRoot $script:Temp
        @($before.Findings | Where-Object { $_.Key -eq 'Sales' -and $_.Kind -eq 'Changed' }).Count | Should -Be 1
        $otherBefore = @($before.Findings | Where-Object { $_.Key -ne 'Sales' }).Count
        $id = Send-Request @{ action = 'Promote'; tenantId = 'master'; reason = 'agreed'; items = @(@{ itemId = 'AADGroup~Sales' }) }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $job = Get-TestJob $id
        $job.status | Should -Be 'Succeeded' -Because $job.result
        $job.result | Should -BeLike '*compared with it again*'
        $after = Get-PECheck -Latest -Kind Full -DataRoot $script:Temp
        $after.CheckId | Should -Not -Be $before.CheckId
        $after.State.Meta.PatchedFrom | Should -Be $before.CheckId
        @($after.Findings | Where-Object { $_.Key -eq 'Sales' }).Count | Should -Be 0
        @($after.Findings | Where-Object { $_.Key -ne 'Sales' }).Count | Should -Be $otherBefore
        @($after.State.Records).Count | Should -Be @($before.State.Records).Count
    }

    It 'restores an earlier version of the master blueprint as a new version, keeps the history, and shows it as a restore in the version list' {
        $promote = Send-Request @{ action = 'Promote'; tenantId = 'master'; reason = 'agreed'; items = @(@{ itemId = 'AADGroup~Sales' }) }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        (Get-TestJob $promote).status | Should -Be 'Succeeded'
        ((Get-PEBlueprint -Name 'main' -DataRoot $script:Temp).Records | Where-Object Key -EQ 'Sales').Properties.Description | Should -Be 'two'

        $id = Send-Request @{ action = 'RevertBlueprint'; targetVersion = 1; reason = 'undo the promote' }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $job = Get-TestJob $id
        $job.status | Should -Be 'Succeeded' -Because $job.result
        $job.result | Should -BeLike "Blueprint 'main' v3 recorded as a copy of v1*versions in between are kept*No tenant was changed*"
        ((Get-PEBlueprint -Name 'main' -DataRoot $script:Temp).Records | Where-Object Key -EQ 'Sales').Properties.Description | Should -Be 'one'
        (Get-PEBlueprint -Name 'main' -Version 2 -DataRoot $script:Temp).Meta.Version | Should -Be 2
        $versions = @(Get-Content (Join-Path $script:Gui 'blueprint\versions.json') -Raw | ConvertFrom-Json)
        $versions.version | Should -Be @(1, 2, 3)
        $versions[2].source | Should -Be 'Revert'
        $versions[2].revertTo | Should -Be 1
    }

    It 'restores one item of an earlier version only' {
        $promote = Send-Request @{ action = 'Promote'; tenantId = 'master'; reason = 'agreed'; items = @(@{ itemId = 'AADGroup~Sales' }) }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $id = Send-Request @{ action = 'RevertBlueprint'; targetVersion = 1; reason = 'one item'; items = @(@{ itemId = 'AADGroup~Sales' }) }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $job = Get-TestJob $id
        $job.status | Should -Be 'Succeeded' -Because $job.result
        $job.result | Should -BeLike "*recorded as a copy of item 'Sales' of v1*"
        ((Get-PEBlueprint -Name 'main' -DataRoot $script:Temp).Records | Where-Object Key -EQ 'Sales').Properties.Description | Should -Be 'one'
        @((Get-PEBlueprint -Name 'main' -DataRoot $script:Temp).Records).Count | Should -Be @((Get-PEBlueprint -Name 'main' -Version 1 -DataRoot $script:Temp).Records).Count
    }

    It 'Accept needs the master-write confirmation' {
        $id = Send-Request @{ action = 'Accept'; tenantId = 'master'; reason = ''; confirmedMasterWrite = $true; items = @(@{ itemId = 'AADGroup~Sales' }) }
        $path = Join-Path $script:Gui "requests"
        $file = Get-ChildItem $path | Select-Object -First 1
        $json = Get-Content $file.FullName -Raw | ConvertFrom-Json
        $json.confirmedMasterWrite = $false
        $json | ConvertTo-Json -Depth 10 | Set-Content $file.FullName
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        (Get-TestJob $id).status | Should -Be 'Failed'
        (Get-TestJob $id).result | Should -BeLike '*master-write confirmation*'
    }

    It 'Accept restores the tenant to the blueprint and saves a patched check' {
        Mock -ModuleName PolicyEngine Get-PERectifyRedaction { , [string[]]@() }
        Mock -ModuleName PolicyEngine Get-PERectifyWriterApp { [pscustomobject]@{ Role = 'Writer'; TenantId = 't'; ApplicationId = 'a'; Thumbprint = 'b' } }
        $apply = {
            param ($ConfigPath, $ExpectedResourceCount)
            [pscustomobject]@{
                Success = $true; TestOnly = $false; PartiallyApplied = $false; ResourceCount = 2; ExpectedResourceCount = 2; OutputFolder = $null; MofPath = $null; CompileSeconds = 1; ApplySeconds = 1; Error = $null
                Resources = @(0, 1 | ForEach-Object { [pscustomobject]@{ ResourceId = "[AADGroup]g$_"; ResourceType = 'AADGroup'; Status = 'Applied'; InDesiredStateBefore = $false; SetInvoked = $true; RebootRequired = $false; InDesiredStateAfter = $true; Seconds = 1; Error = $null } })
            }
        }
        $id = Send-Request @{ action = 'Accept'; tenantId = 'master'; reason = ''; confirmedMasterWrite = $true; items = @(@{ itemId = 'AADGroup~Sales' }, @{ itemId = 'AADGroup~Extra' }) }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui -ApplyScript $apply -RecheckScript { param ($Items) @() } | Out-Null
        $job = Get-TestJob $id
        $job.status | Should -Be 'Succeeded' -Because $job.result
        $job.config | Should -Match 'AADGroup'
        $new = Get-PECheck -Latest -Kind Full -DataRoot $script:Temp
        $new.CheckId | Should -Not -Be '20261021-020000'
        $new.State.Meta.PatchedFrom | Should -Be '20261021-020000'
        @($new.State.Records | Where-Object Key -EQ 'Extra').Count | Should -Be 0
        ($new.State.Records | Where-Object Key -EQ 'Sales').Properties.Description | Should -Be 'one'
        @($new.Findings | Where-Object { $_.Key -in 'Sales', 'Extra' }).Count | Should -Be 0
        $findings = Get-Content (Join-Path $script:Gui 'tenants\master\findings.json') -Raw | ConvertFrom-Json
        @($findings).Count | Should -Be 0
        @(Get-PEDecision -Kind Remove -DataRoot $script:Temp).Key | Should -Contain 'Extra'
    }

    It 'Accept that the re-check does not confirm fails and leaves the check alone' {
        Mock -ModuleName PolicyEngine Get-PERectifyRedaction { , [string[]]@() }
        Mock -ModuleName PolicyEngine Get-PERectifyWriterApp { [pscustomobject]@{ Role = 'Writer'; TenantId = 't'; ApplicationId = 'a'; Thumbprint = 'b' } }
        $apply = {
            param ($ConfigPath, $ExpectedResourceCount)
            [pscustomobject]@{
                Success = $true; TestOnly = $false; PartiallyApplied = $false; ResourceCount = 1; ExpectedResourceCount = 1; OutputFolder = $null; MofPath = $null; CompileSeconds = 1; ApplySeconds = 1; Error = $null
                Resources = @([pscustomobject]@{ ResourceId = '[AADGroup]g'; ResourceType = 'AADGroup'; Status = 'Applied'; InDesiredStateBefore = $false; SetInvoked = $true; RebootRequired = $false; InDesiredStateAfter = $true; Seconds = 1; Error = $null })
            }
        }
        $id = Send-Request @{ action = 'Accept'; tenantId = 'master'; reason = ''; confirmedMasterWrite = $true; items = @(@{ itemId = 'AADGroup~Sales' }) }
        $dirty = { param ($Items) @([pscustomobject]@{ Kind = 'Changed'; ResourceType = 'AADGroup'; Key = 'Sales'; Differences = @() }) }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui -ApplyScript $apply -RecheckScript $dirty | Out-Null
        (Get-TestJob $id).status | Should -Be 'Failed'
        (Get-TestJob $id).result | Should -BeLike '*re-read did not confirm*'
        (Get-PECheck -Latest -Kind Full -DataRoot $script:Temp).CheckId | Should -Be '20261021-020000'
    }

    It 'Recheck runs a full check scoped to the blueprint types and refreshes the data before the job finishes' {
        Mock -ModuleName PolicyEngine Invoke-PEFullCheck { $script:FullCheckArgs = $PSBoundParameters }
        $id = Send-Request @{ action = 'Recheck'; tenantId = 'master' }
        $second = Invoke-PEGuiApi -DataRoot $script:Gui -Method POST -Path '/api/requests' -Body ([pscustomobject]@{ action = 'Recheck'; tenantId = 'master' })
        $second.StatusCode | Should -Be 400
        $second.Json | Should -BeLike '*already running*'
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $job = Get-TestJob $id
        $job.status | Should -Be 'Succeeded' -Because $job.result
        $job.result | Should -BeLike 'Snapshot taken of 1 resource type(s)*2 drifted item(s)*'
        Should -Invoke -ModuleName PolicyEngine Invoke-PEFullCheck -Times 1 -ParameterFilter { $BlueprintName -eq 'main' -and @($Workloads) -contains 'AADGroup' -and $AcceptModuleChange }
    }

    It 'ReviewModule is refused while every blueprint matches the installed module, and records the pin for those that do not' {
        $reply = Invoke-PEGuiApi -DataRoot $script:Gui -Method POST -Path '/api/requests' -Body ([pscustomobject]@{ action = 'ReviewModule' })
        $reply.StatusCode | Should -Be 400
        $moduleFile = Join-Path $script:Temp 'blueprints\main\module.json'
        $record = Get-Content $moduleFile -Raw | ConvertFrom-Json
        $record.ModuleVersion = '2.25.0.1'
        $record | ConvertTo-Json | Set-Content $moduleFile
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $id = Send-Request @{ action = 'ReviewModule' }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $job = Get-TestJob $id
        $job.status | Should -Be 'Succeeded' -Because $job.result
        $job.result | Should -BeLike '*recorded for blueprint main*No tenant was changed*'
        (Get-PEModuleStatus -BlueprintName 'main' -DataRoot $script:Temp).Match | Should -BeTrue
        (Get-Content $moduleFile -Raw | ConvertFrom-Json).Previous | Should -Be '2.25.0.1'
    }

    Context 'Cancelling a job' {
        BeforeEach {
            $script:Cancel = { param ($id) Invoke-PEGuiApi -DataRoot $script:Gui -Method POST -Path "/api/jobs/$id/cancel" -Body ([pscustomobject]@{}) }
            $script:SetJob = {
                param ($id, [hashtable]$Change)
                $path = Join-Path $script:Gui "activity\$id.json"
                $job = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -DateKind String
                foreach ($k in $Change.Keys) { $job[$k] = $Change[$k] }
                $job | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8
            }
            $script:Beat = { param ($processId, $at, $jobId) [ordered]@{ pid = $processId; at = $at.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); jobId = $jobId } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:Gui 'activity\worker.json') -Encoding utf8 }
            $script:Active = { @(Get-Content -LiteralPath (Join-Path $script:Gui 'activity\active.json') -Raw | ConvertFrom-Json -NoEnumerate) }
        }

        It 'cancels a queued job at once, takes it off the active list, and the worker then skips it' {
            Mock -ModuleName PolicyEngine Invoke-PEFullCheck { }
            $id = Send-Request @{ action = 'Recheck'; tenantId = 'master' }
            $reply = & $script:Cancel $id
            $reply.StatusCode | Should -Be 200 -Because $reply.Json
            (Get-TestJob $id).status | Should -Be 'Cancelled'
            (Get-TestJob $id).result | Should -BeLike '*before it started*'
            & $script:Active | Should -Not -Contain $id
            Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
            Should -Invoke -ModuleName PolicyEngine Invoke-PEFullCheck -Times 0
            (Get-TestJob $id).status | Should -Be 'Cancelled'
            (Send-Request @{ action = 'Recheck'; tenantId = 'master' }) | Should -Not -BeNullOrEmpty
        }

        It 'asks a live worker to stop a running Recheck; the worker stops it and the job ends Cancelled' {
            $id = Send-Request @{ action = 'Recheck'; tenantId = 'master' }
            $script:CancelReply = $null
            Mock -ModuleName PolicyEngine Invoke-PEFullCheck {
                # The user presses Cancel while the export runs; the worker's wait then stops the process and throws this.
                $script:CancelReply = & $script:Cancel 'J-1'
                throw [System.OperationCanceledException]::new('Cancelled by request.')
            }
            Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
            $script:CancelReply.StatusCode | Should -Be 200 -Because $script:CancelReply.Json
            ($script:CancelReply.Json | ConvertFrom-Json).status | Should -Be 'Running'
            $job = Get-TestJob $id
            $job.status | Should -Be 'Cancelled' -Because $job.result
            $job.result | Should -BeLike '*Cancelled*'
            & $script:Active | Should -Not -Contain $id
        }

        It 'marks a running job cancelled itself when no worker is alive (a stuck job)' {
            $id = Send-Request @{ action = 'Recheck'; tenantId = 'master' }
            & $script:SetJob $id @{ status = 'Running' }
            $reply = & $script:Cancel $id
            $reply.StatusCode | Should -Be 200 -Because $reply.Json
            (Get-TestJob $id).status | Should -Be 'Cancelled'
            (Get-TestJob $id).result | Should -BeLike '*worker was not running*'
            & $script:Active | Should -Not -Contain $id
        }

        It 'does the same when the worker that wrote the heartbeat is gone' {
            $id = Send-Request @{ action = 'Recheck'; tenantId = 'master' }
            & $script:SetJob $id @{ status = 'Running' }
            & $script:Beat 2147483000 ([datetime]::UtcNow)
            (& $script:Cancel $id).StatusCode | Should -Be 200
            (Get-TestJob $id).status | Should -Be 'Cancelled'
        }

        It 'treats a running job that no live worker is running as orphaned: a live worker busy with another job (or idle) cannot stop it' {
            $id = Send-Request @{ action = 'Recheck'; tenantId = 'master' }
            & $script:SetJob $id @{ status = 'Running' }
            [ordered]@{ pid = $PID; at = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); jobId = 'J-777' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:Gui 'activity\worker.json') -Encoding utf8
            $reply = & $script:Cancel $id
            $reply.StatusCode | Should -Be 200 -Because $reply.Json
            (Get-TestJob $id).status | Should -Be 'Cancelled'
            (Get-TestJob $id).result | Should -BeLike '*not running this job*'
        }

        It 'does not stop a running job that changes things; it explains why' {
            $id = Send-Request @{ action = 'Recheck'; tenantId = 'master' }
            & $script:SetJob $id @{ status = 'Running'; action = 'Accept' }
            & $script:Beat $PID ([datetime]::UtcNow) $id
            $reply = & $script:Cancel $id
            $reply.StatusCode | Should -Be 400
            $reply.Json | Should -BeLike '*half-done*'
            (Get-TestJob $id).status | Should -Be 'Running'
        }

        It 'refuses a job that has finished and an id that is not a job' {
            $id = Send-Request @{ action = 'Recheck'; tenantId = 'master' }
            & $script:SetJob $id @{ status = 'Succeeded' }
            $done = & $script:Cancel $id
            $done.StatusCode | Should -Be 400
            $done.Json | Should -BeLike '*already finished*'
            (& $script:Cancel 'J-9999').StatusCode | Should -Be 404
            (& $script:Cancel '..\x').StatusCode | Should -BeIn 400, 404
        }

        It 'leaves a job the server already marked Cancelled alone when a late worker finishes' {
            $id = Send-Request @{ action = 'Recheck'; tenantId = 'master' }
            Mock -ModuleName PolicyEngine Invoke-PEFullCheck {
                $path = Join-Path $script:Gui 'activity\J-1.json'
                $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -DateKind String
                $j.status = 'Cancelled'; $j.result = 'Cancelled: the worker was not running.'
                $j | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8
            }
            Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
            (Get-TestJob $id).status | Should -Be 'Cancelled'
        }

        It 'only a Recheck can be stopped: a job that changes things gets no cancel check and a stray cancel flag never turns its failure into Cancelled' {
            $id = Send-Request @{ action = 'RenameTenant'; tenantId = 'master'; displayName = 'New name' }
            & $script:SetJob $id @{ cancelRequested = $true }
            $global:PESeenCheck = 'unset'
            Mock -ModuleName PolicyEngine Set-PETenant { $global:PESeenCheck = & (Get-Module PolicyEngine) { $script:PEJobCancelCheck }; throw 'disk full' }
            Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
            $global:PESeenCheck | Should -BeNullOrEmpty
            $job = Get-TestJob $id
            $job.status | Should -Be 'Failed'
            $job.result | Should -BeLike '*disk full*'
        }

        It 'gives a Recheck a cancel check while it runs and takes it away afterwards' {
            $id = Send-Request @{ action = 'Recheck'; tenantId = 'master' }
            $global:PESeenCheck = $null
            Mock -ModuleName PolicyEngine Invoke-PEFullCheck { $global:PESeenCheck = & (Get-Module PolicyEngine) { $script:PEJobCancelCheck } }
            Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
            $global:PESeenCheck | Should -Not -BeNullOrEmpty
            & (Get-Module PolicyEngine) { $script:PEJobCancelCheck } | Should -BeNullOrEmpty
        }

        It 'shows that the worker is alive: it writes its process id and the time on every pass' {
            Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
            $beat = Get-Content -LiteralPath (Join-Path $script:Gui 'activity\worker.json') -Raw | ConvertFrom-Json -DateKind String
            $beat.pid | Should -Be $PID
            ([datetime]::Parse($beat.at, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)).ToUniversalTime() | Should -BeGreaterThan ([datetime]::UtcNow.AddMinutes(-2))
        }
    }
    It 'Recheck of a replica compares it with its own blueprint' {
        Add-ReplicaCheck -OwnRecords @((New-TestRecord -Key 'Sales' -Props @{ Description = 'one' }), (New-TestRecord -Key 'Finance')) -TenantRecords @((New-TestRecord -Key 'Sales' -Props @{ Description = 'two' }), (New-TestRecord -Key 'Finance'))
        Mock -ModuleName PolicyEngine Invoke-PEFullCheck { }
        $id = Send-Request @{ action = 'Recheck'; tenantId = 'dev' }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        (Get-TestJob $id).status | Should -Be 'Succeeded'
        Should -Invoke -ModuleName PolicyEngine Invoke-PEFullCheck -Times 1 -ParameterFilter { $Workloads -contains 'AADGroup' } -Because (Get-TestJob $id).result
        Should -Invoke -ModuleName PolicyEngine Invoke-PEFullCheck -Times 1 -ParameterFilter { $BlueprintName -eq 'dev' -and $Tenant -eq 'dev' }
    }

    It 'a snapshot of a replica with "use as blueprint" makes the tenant blueprint match the snapshot, leaves the master blueprint alone, and starts from no drift' {
        Mock -ModuleName PolicyEngine Invoke-PEFullCheck { }
        Add-ReplicaCheck -OwnRecords @((New-TestRecord -Key 'Sales' -Props @{ Description = 'one' }), (New-TestRecord -Key 'Finance')) -TenantRecords @((New-TestRecord -Key 'Sales' -Props @{ Description = 'two' }), (New-TestRecord -Key 'NewGroup'))
        Set-PEDecision -Kind Unmanaged -ResourceType 'AADGroup' -Key 'NewGroup' -Tenant 'dev' -Reason 'not ours' -DataRoot $script:Temp | Out-Null
        $id = Send-Request @{ action = 'Recheck'; tenantId = 'dev'; baseline = $true }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $job = Get-TestJob $id
        Should -Invoke -ModuleName PolicyEngine Invoke-PEFullCheck -Times 1 -ParameterFilter { -not $Workloads }
        $job.status | Should -Be 'Succeeded' -Because $job.result
        $job.result | Should -BeLike "*Blueprint 'dev' v2 recorded from this snapshot: 0 added, 1 changed, 1 removed*Left out: 1 excluded*The master blueprint is unchanged*"
        $own = (Get-PEBlueprint -Name 'dev' -DataRoot $script:Temp).Records
        ($own | Where-Object Key -EQ 'Sales').Properties.Description | Should -Be 'two'
        $own.Key | Should -Not -Contain 'Finance'
        $own.Key | Should -Not -Contain 'NewGroup' -Because 'an item excluded for this tenant is left out of the baseline'
        ((Get-PEBlueprint -Name 'main' -DataRoot $script:Temp).Records | Where-Object Key -EQ 'Sales').Properties.Description | Should -Be 'one'
        (Get-PEBlueprint -Name 'main' -DataRoot $script:Temp).Meta.Version | Should -Be 1
        $check = Get-PECheck -Latest -Kind Full -Tenant 'dev' -DataRoot $script:Temp
        $open = @($check.Findings | Where-Object { $_.State -eq 'Open' -and $_.Kind -in 'Missing', 'Changed', 'TargetOnly' })
        $open.Key | Should -Not -Contain 'Sales' -Because 'the changed item was taken into the blueprint'
        $open.Key | Should -Not -Contain 'Finance' -Because 'the removed item was taken into the blueprint'
    }

    It 'a snapshot without "use as blueprint" leaves the tenant blueprint as it was' {
        Mock -ModuleName PolicyEngine Invoke-PEFullCheck { }
        Add-ReplicaCheck -OwnRecords @((New-TestRecord -Key 'Sales' -Props @{ Description = 'one' })) -TenantRecords @((New-TestRecord -Key 'Sales' -Props @{ Description = 'two' }))
        $id = Send-Request @{ action = 'Recheck'; tenantId = 'dev' }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        (Get-TestJob $id).status | Should -Be 'Succeeded'
        Should -Invoke -ModuleName PolicyEngine Invoke-PEFullCheck -Times 1 -ParameterFilter { $Workloads -contains 'AADGroup' }
        (Get-PEBlueprint -Name 'dev' -DataRoot $script:Temp).Meta.Version | Should -Be 1
    }

    It '"use as blueprint" is refused for the master tenant and for a refresh of one scope' {
        $master = Invoke-PEGuiApi -DataRoot $script:Gui -Method POST -Path '/api/requests' -Body ([pscustomobject]@{ action = 'Recheck'; tenantId = 'master'; baseline = $true })
        $master.StatusCode | Should -Be 400
        $master.Json | Should -BeLike '*master tenant has no blueprint of its own*'
    }

    It 'Promote from a replica writes only the replica blueprint and applies nothing' {
        Add-ReplicaCheck -OwnRecords @((New-TestRecord -Key 'Sales' -Props @{ Description = 'one' }), (New-TestRecord -Key 'Finance')) -TenantRecords @((New-TestRecord -Key 'Sales' -Props @{ Description = 'two' }), (New-TestRecord -Key 'Finance'))
        $id = Send-Request @{ action = 'Promote'; tenantId = 'dev'; reason = 'try-out kept'; items = @(@{ itemId = 'AADGroup~Sales' }) }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $job = Get-TestJob $id
        $job.status | Should -Be 'Succeeded' -Because $job.result
        $job.result | Should -BeLike 'Blueprint v2 recorded*No tenant was changed*'
        ((Get-PEBlueprint -Name 'dev' -DataRoot $script:Temp).Records | Where-Object Key -EQ 'Sales').Properties.Description | Should -Be 'two'
        ((Get-PEBlueprint -Name 'main' -DataRoot $script:Temp).Records | Where-Object Key -EQ 'Sales').Properties.Description | Should -Be 'one'
        (Get-PEBlueprint -Name 'main' -DataRoot $script:Temp).Meta.Version | Should -Be 1
    }

    It 'Promote from a replica that has no blueprint of its own is refused, so the master blueprint is never written from a replica' {
        Set-PETenant -Slug 'dev' -DisplayName 'Dev' -TenantId 'dev.onmicrosoft.com' -DataRoot $script:Temp | Out-Null
        $state = New-TestState -Records @((New-TestRecord -Key 'Sales' -Props @{ Description = 'two' }), (New-TestRecord -Key 'Finance'))
        $findings = @(Compare-PEState -Blueprint (Get-PEBlueprint -Name 'main' -DataRoot $script:Temp) -Target $state)
        $directory = Join-Path (Join-Path $script:Temp 'checks') '20261021-030000'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        [ordered]@{ CheckId = '20261021-030000'; Kind = 'Full'; TenantSlug = 'dev'; BlueprintName = 'main'; BlueprintVersion = 1; Findings = $findings; State = $state } |
            ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $directory 'result.json') -Encoding utf8
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $reply = Invoke-PEGuiApi -DataRoot $script:Gui -Method POST -Path '/api/requests' -Body ([pscustomobject]@{ action = 'Promote'; tenantId = 'dev'; reason = 'r'; items = @([pscustomobject]@{ itemId = 'AADGroup~Sales' }) })
        $reply.StatusCode | Should -Be 400
        $reply.Json | Should -BeLike '*no blueprint of its own*'
        # The worker refuses it too, should a request file get past the preview.
        $request = [pscustomobject]@{ action = 'Promote'; tenantId = 'dev'; reason = 'r'; items = @([pscustomobject]@{ itemId = 'AADGroup~Sales'; resourceType = 'AADGroup'; key = 'Sales' }) }
        { & (Get-Module PolicyEngine) { param ($r, $root) Invoke-PEGuiRequestAction -Request $r -Job ([pscustomobject]@{ jobId = 'J-9' }) -BlueprintName 'main' -DataRoot $root -Role 'Replica' } $request $script:Temp } | Should -Throw '*no blueprint of its own*'
        @(Get-TestVersion -Name 'main' -Root $script:Temp) | Should -Be @(1)
    }

    Context 'Moves between blueprints' {
        BeforeEach {
            Add-ReplicaCheck -OwnRecords @((New-TestRecord -Key 'Sales' -Props @{ Description = 'devvalue' }), (New-TestRecord -Key 'Finance'), (New-TestRecord -Key 'DevOnly')) -TenantRecords @((New-TestRecord -Key 'Sales' -Props @{ Description = 'devvalue' }), (New-TestRecord -Key 'Finance'), (New-TestRecord -Key 'DevOnly'))
        }

        It 'updates the tenant blueprint from the master blueprint and writes no tenant' {
            $id = Send-Request @{ action = 'PullDown'; tenantId = 'dev'; reason = 'catch up'; items = @() }
            Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
            $job = Get-TestJob $id
            $job.status | Should -Be 'Succeeded' -Because $job.result
            $job.result | Should -BeLike "Blueprint v2 recorded in 'dev'*No tenant was changed*"
            $dev = Get-PEBlueprint -Name 'dev' -DataRoot $script:Temp
            ($dev.Records | Where-Object Key -EQ 'Sales').Properties.Description | Should -Be 'one'
            @($dev.Records | Where-Object Key -EQ 'DevOnly').Count | Should -Be 0
            @(Get-TestVersion -Name 'main' -Root $script:Temp) | Should -Be @(1)
        }

        It 'promotes a named item up into the master blueprint' {
            $id = Send-Request @{ action = 'PromoteUp'; tenantId = 'dev'; reason = 'make the cut'; items = @(@{ itemId = 'AADGroup~DevOnly' }) }
            Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
            $job = Get-TestJob $id
            $job.status | Should -Be 'Succeeded' -Because $job.result
            @((Get-PEBlueprint -Name 'main' -DataRoot $script:Temp).Records | ForEach-Object Key) | Should -Contain 'DevOnly'
            ((Get-PEBlueprint -Name 'main' -DataRoot $script:Temp).Records | Where-Object Key -EQ 'Sales').Properties.Description | Should -Be 'one'
            @(Get-TestVersion -Name 'dev' -Root $script:Temp) | Should -Be @(1)
        }

        It 'fails the job and writes nothing when the target blueprint changed after the review' {
            $id = Send-Request @{ action = 'PullDown'; tenantId = 'dev'; reason = 'catch up'; items = @() }
            Move-PEBlueprintItem -From 'main' -To 'dev' -Item ([pscustomobject]@{ ResourceType = 'AADGroup'; Key = 'Sales' }) -Reason 'someone else' -ExpectedVersion 1 -DataRoot $script:Temp | Out-Null
            Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
            $job = Get-TestJob $id
            $job.status | Should -Be 'Failed'
            $job.result | Should -BeLike '*changed since*'
            @(Get-TestVersion -Name 'dev' -Root $script:Temp) | Should -Be @(1, 2)
        }
    }

    It 'refuses to rename a tenant that is not registered, so a request file cannot create one' {
        $request = [pscustomobject]@{ action = 'RenameTenant'; tenantId = 'ghost'; displayName = 'Ghost' }
        { & (Get-Module PolicyEngine) { param ($r, $root) Invoke-PEGuiRequestAction -Request $r -Job ([pscustomobject]@{ jobId = 'J-9' }) -BlueprintName 'main' -DataRoot $root -Role 'Replica' } $request $script:Temp } | Should -Throw '*ghost*'
        @((Get-PETenant -DataRoot $script:Temp).Slug) | Should -Not -Contain 'ghost'
    }

    It 'refuses Promote from a replica onto the master blueprint even when its role is not known' {
        Set-PETenant -Slug 'dev' -DisplayName 'Dev' -TenantId 'dev.onmicrosoft.com' -DataRoot $script:Temp | Out-Null
        $request = [pscustomobject]@{ action = 'Promote'; tenantId = 'dev'; reason = 'r'; items = @([pscustomobject]@{ itemId = 'AADGroup~Sales'; resourceType = 'AADGroup'; key = 'Sales' }) }
        { & (Get-Module PolicyEngine) { param ($r, $root) Invoke-PEGuiRequestAction -Request $r -Job ([pscustomobject]@{ jobId = 'J-9' }) -BlueprintName 'MAIN' -DataRoot $root -Role '' } $request $script:Temp } | Should -Throw '*no blueprint of its own*'
    }

    It 'fails a blueprint move whose source blueprint changed after the review' {
        Add-ReplicaCheck -OwnRecords @((New-TestRecord -Key 'Sales' -Props @{ Description = 'devvalue' }), (New-TestRecord -Key 'Finance')) -TenantRecords @((New-TestRecord -Key 'Sales' -Props @{ Description = 'devvalue' }), (New-TestRecord -Key 'Finance'))
        $id = Send-Request @{ action = 'PullDown'; tenantId = 'dev'; reason = 'catch up'; items = @() }
        Initialize-PEBlueprint -Name 'x' -State (New-TestState -Records @((New-TestRecord -Key 'Sales' -Props @{ Description = 'devvalue' }))) -DataRoot $script:Temp | Out-Null
        Move-PEBlueprintItem -From 'dev' -To 'main' -Item ([pscustomobject]@{ ResourceType = 'AADGroup'; Key = 'Sales' }) -Reason 'someone else promoted' -ExpectedVersion 1 -DataRoot $script:Temp | Out-Null
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $job = Get-TestJob $id
        $job.status | Should -Be 'Failed'
        $job.result | Should -BeLike "*'main'*changed since*"
        @(Get-TestVersion -Name 'dev' -Root $script:Temp) | Should -Be @(1)
    }

    It 'Accept on a replica restores it to its own blueprint, not the master blueprint' {
        Mock -ModuleName PolicyEngine Get-PERectifyRedaction { , [string[]]@() }
        Mock -ModuleName PolicyEngine Get-PERectifyWriterApp { [pscustomobject]@{ Role = 'Writer'; TenantId = 't'; ApplicationId = 'a'; Thumbprint = 'b' } }
        $apply = {
            param ($ConfigPath, $ExpectedResourceCount)
            [pscustomobject]@{
                Success = $true; TestOnly = $false; PartiallyApplied = $false; ResourceCount = 1; ExpectedResourceCount = 1; OutputFolder = $null; MofPath = $null; CompileSeconds = 1; ApplySeconds = 1; Error = $null
                Resources = @([pscustomobject]@{ ResourceId = '[AADGroup]g0'; ResourceType = 'AADGroup'; Status = 'Applied'; InDesiredStateBefore = $false; SetInvoked = $true; RebootRequired = $false; InDesiredStateAfter = $true; Seconds = 1; Error = $null })
            }
        }
        Add-ReplicaCheck -OwnRecords @((New-TestRecord -Key 'Sales' -Props @{ Description = 'devvalue' }), (New-TestRecord -Key 'Finance')) -TenantRecords @((New-TestRecord -Key 'Sales' -Props @{ Description = 'two' }), (New-TestRecord -Key 'Finance'))
        $id = Send-Request @{ action = 'Accept'; tenantId = 'dev'; reason = ''; items = @(@{ itemId = 'AADGroup~Sales' }) }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui -ApplyScript $apply -RecheckScript { param ($Items) @() } | Out-Null
        $job = Get-TestJob $id
        $job.status | Should -Be 'Succeeded' -Because $job.result
        $job.config | Should -Match 'devvalue'
        $job.config | Should -Not -Match "'one'"
    }

    It 'offers no revert (Accept) for an offline tenant and refuses the request, but still offers Promote and Exclude' {
        Add-ReplicaCheck -OwnRecords @((New-TestRecord -Key 'Sales')) -TenantRecords @((New-TestRecord -Key 'Sales'), (New-TestRecord -Key 'Extra'))
        Set-PETenant -Slug 'dev' -Offline -DataRoot $script:Temp | Out-Null
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $extra = Get-PEGuiFinding -DataRoot $script:Gui -TenantId 'dev' | Where-Object itemId -EQ 'AADGroup~Extra'
        $extra.allowedActions | Should -Not -Contain 'Accept'
        $extra.allowedActions | Should -Contain 'Promote'
        $extra.allowedActions | Should -Contain 'Exclude'
        $reply = Invoke-PEGuiApi -DataRoot $script:Gui -Method POST -Path '/api/requests' -Body ([pscustomobject]@{ action = 'Accept'; tenantId = 'dev'; reason = ''; items = @(@{ itemId = 'AADGroup~Extra' }) })
        $reply.StatusCode | Should -Be 400
        $reply.Json | Should -BeLike '*Accept is not allowed*'
        Send-Request @{ action = 'Promote'; tenantId = 'dev'; reason = 'keep it'; items = @(@{ itemId = 'AADGroup~Extra' }) } | Should -Not -BeNullOrEmpty
    }

    It 'the engine refuses Accept for an offline tenant before it records any decision' {
        Add-ReplicaCheck -OwnRecords @((New-TestRecord -Key 'Sales')) -TenantRecords @((New-TestRecord -Key 'Sales'), (New-TestRecord -Key 'Extra'))
        Set-PETenant -Slug 'dev' -Offline -DataRoot $script:Temp | Out-Null
        $request = [pscustomobject]@{ action = 'Accept'; tenantId = 'dev'; reason = ''; items = @([pscustomobject]@{ resourceType = 'AADGroup'; key = 'Extra'; findingKind = 'TargetOnly' }) }
        { & (Get-Module PolicyEngine) { param ($r, $d) Invoke-PEGuiRequestAction -Request $r -Job ([pscustomobject]@{ jobId = 'J-1' }) -BlueprintName 'main' -DataRoot $d -Role 'Replica' } $request $script:Temp } |
            Should -Throw "Tenant 'dev' is offline: *Generate configuration*"
        @(Get-PEDecision -DataRoot $script:Temp -Tenant 'dev').Count | Should -Be 0
    }

    It 'a scope re-check goes to Invoke-PEScopeCheck and only known scopes are accepted' {
        Set-PEScope -Name 'groups' -Types 'AADGroup' -DataRoot $script:Temp | Out-Null
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        Mock -ModuleName PolicyEngine Invoke-PEScopeCheck { [pscustomobject]@{ Scope = $Scope; CheckId = '20261021-020100'; Items = 2; Drifted = 1; NotChecked = 0; Findings = @() } }
        $bad = Invoke-PEGuiApi -DataRoot $script:Gui -Method POST -Path '/api/requests' -Body ([pscustomobject]@{ action = 'Recheck'; tenantId = 'master'; scope = 'nope' })
        $bad.StatusCode | Should -Be 400
        $bad.Json | Should -BeLike "*Unknown scope 'nope'*"
        $id = Send-Request @{ action = 'Recheck'; tenantId = 'master'; scope = 'groups' }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $job = Get-TestJob $id
        $job.status | Should -Be 'Succeeded' -Because $job.result
        $job.result | Should -BeLike "Scope 'groups' refreshed*1 drifted*"
        Should -Invoke -ModuleName PolicyEngine Invoke-PEScopeCheck -Times 1 -ParameterFilter { $Scope -eq 'groups' -and $BlueprintName -eq 'main' }
    }
    It 'a resource type of the blueprint is accepted as a scope' {
        $reply = Invoke-PEGuiApi -DataRoot $script:Gui -Method POST -Path '/api/requests' -Body ([pscustomobject]@{ action = 'Recheck'; tenantId = 'master'; scope = 'AADGroup' })
        $reply.StatusCode | Should -Be 201 -Because $reply.Json
    }

    It 'Recheck is refused for an unknown tenant' {
        $reply = Invoke-PEGuiApi -DataRoot $script:Gui -Method POST -Path '/api/requests' -Body ([pscustomobject]@{ action = 'Recheck'; tenantId = 'nope' })
        $reply.StatusCode | Should -Be 400
    }

    It 'reverts a replica to the blueprint with its own Writer app, without the master-write confirmation, and leaves the master check alone' {
        Mock -ModuleName PolicyEngine Get-PERectifyRedaction { , [string[]]@() }
        Mock -ModuleName PolicyEngine Get-PERectifyWriterApp { [pscustomobject]@{ Role = 'Writer'; TenantId = 'dev-tenant'; ApplicationId = 'a'; Thumbprint = 'b' } }
        Set-PETenant -Slug 'dev' -DisplayName 'Dev' -DataRoot $script:Temp | Out-Null
        $blueprint = Get-PEBlueprint -Name 'main' -DataRoot $script:Temp
        $devTarget = & (Get-Module PolicyEngine) { param ($r) New-PEState -Records $r -NotChecked @() -Meta @{ TenantId = 'dev-tenant'; ExportedAt = '2026-10-21T02:00:00Z'; Source = 'x' } } @((New-TestRecord -Key 'Sales' -Props @{ Description = 'dev edit' }), (New-TestRecord -Key 'Finance'))
        $devFindings = @(Compare-PEState -Blueprint $blueprint -Target $devTarget)
        $directory = Join-Path $script:Temp 'checks\20261021-030000'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        [ordered]@{ CheckId = '20261021-030000'; Kind = 'Full'; TenantSlug = 'dev'; BlueprintName = 'main'; BlueprintVersion = 1; Findings = $devFindings; State = $devTarget } |
            ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $directory 'result.json') -Encoding utf8
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null

        # no confirmedMasterWrite: a replica does not need it
        $id = Send-Request @{ action = 'Accept'; tenantId = 'dev'; reason = ''; items = @(@{ itemId = 'AADGroup~Sales' }) }
        $apply = {
            param ($ConfigPath, $ExpectedResourceCount)
            [pscustomobject]@{
                Success = $true; TestOnly = $false; PartiallyApplied = $false; ResourceCount = 1; ExpectedResourceCount = 1; OutputFolder = $null; MofPath = $null; CompileSeconds = 1; ApplySeconds = 1; Error = $null
                Resources = @([pscustomobject]@{ ResourceId = '[AADGroup]g'; ResourceType = 'AADGroup'; Status = 'Applied'; InDesiredStateBefore = $false; SetInvoked = $true; RebootRequired = $false; InDesiredStateAfter = $true; Seconds = 1; Error = $null })
            }
        }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui -ApplyScript $apply -RecheckScript { param ($Items) @() } | Out-Null
        $job = Get-TestJob $id
        $job.status | Should -Be 'Succeeded' -Because $job.result
        Should -Invoke -ModuleName PolicyEngine Get-PERectifyWriterApp -ParameterFilter { $Tenant -eq 'dev' }
        # the dev check was patched; the master check is untouched
        (Get-PECheck -Latest -Kind Full -Tenant 'dev' -DataRoot $script:Temp).State.Meta.PatchedFrom | Should -Be '20261021-030000'
        (Get-PECheck -Latest -Kind Full -Tenant 'master' -DataRoot $script:Temp).CheckId | Should -Be '20261021-020000'
    }

    It 'an Exclude on a replica is recorded for that tenant only' {
        Set-PETenant -Slug 'dev' -DataRoot $script:Temp | Out-Null
        $blueprint = Get-PEBlueprint -Name 'main' -DataRoot $script:Temp
        $devTarget = & (Get-Module PolicyEngine) { param ($r) New-PEState -Records $r -NotChecked @() -Meta @{ TenantId = 'dev-tenant'; ExportedAt = '2026-10-21T02:00:00Z'; Source = 'x' } } @((New-TestRecord -Key 'Sales' -Props @{ Description = 'one' }), (New-TestRecord -Key 'Finance'), (New-TestRecord -Key 'DevExtra'))
        $directory = Join-Path $script:Temp 'checks\20261021-030000'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        [ordered]@{ CheckId = '20261021-030000'; Kind = 'Full'; TenantSlug = 'dev'; BlueprintName = 'main'; BlueprintVersion = 1; Findings = @(Compare-PEState -Blueprint $blueprint -Target $devTarget); State = $devTarget } |
            ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $directory 'result.json') -Encoding utf8
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $id = Send-Request @{ action = 'Exclude'; tenantId = 'dev'; reason = 'dev scratch'; items = @(@{ itemId = 'AADGroup~DevExtra' }) }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        (Get-TestJob $id).status | Should -Be 'Succeeded'
        @(Get-PEDecision -Tenant 'dev' -DataRoot $script:Temp | Where-Object Key -EQ 'DevExtra').Count | Should -Be 1
        @(Get-PEDecision -Tenant 'master' -DataRoot $script:Temp | Where-Object Key -EQ 'DevExtra').Count | Should -Be 0
    }
    It 'a replica can stop managing a Missing or Changed item; the master cannot, and the exclusion is for that tenant only' {
        Set-PETenant -Slug 'dev' -DataRoot $script:Temp | Out-Null
        $blueprint = Get-PEBlueprint -Name 'main' -DataRoot $script:Temp
        $devTarget = & (Get-Module PolicyEngine) { param ($r) New-PEState -Records $r -NotChecked @() -Meta @{ TenantId = 'dev-tenant'; ExportedAt = '2026-10-21T02:00:00Z'; Source = 'x' } } @((New-TestRecord -Key 'Sales' -Props @{ Description = 'dev wording' }))
        $directory = Join-Path $script:Temp 'checks\20261021-030000'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        [ordered]@{ CheckId = '20261021-030000'; Kind = 'Full'; TenantSlug = 'dev'; BlueprintName = 'main'; BlueprintVersion = 1; Findings = @(Compare-PEState -Blueprint $blueprint -Target $devTarget); State = $devTarget } |
            ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $directory 'result.json') -Encoding utf8
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null

        # the master's Sales is Changed: refused when the dialog is built
        $refused = Invoke-PEGuiApi -DataRoot $script:Gui -Method POST -Path '/api/requests' -Body ([pscustomobject]@{ action = 'Exclude'; tenantId = 'master'; reason = 'x'; items = @(@{ itemId = 'AADGroup~Sales' }) })
        $refused.StatusCode | Should -Be 400
        $refused.Json | Should -BeLike '*only a replica*'

        $id = Send-Request @{ action = 'Exclude'; tenantId = 'dev'; reason = 'dev specific'; items = @(@{ itemId = 'AADGroup~Finance' }, @{ itemId = 'AADGroup~Sales' }) }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        (Get-TestJob $id).status | Should -Be 'Succeeded' -Because (Get-TestJob $id).result
        @(Get-PEDecision -Tenant 'dev' -DataRoot $script:Temp | Where-Object Kind -EQ 'Unmanaged').Key | Should -Contain 'Finance'
        $afterDev = @(Compare-PEState -Blueprint $blueprint -Target $devTarget -Decisions @(Get-PEDecision -Tenant 'dev' -DataRoot $script:Temp))
        @($afterDev | Where-Object State -EQ 'Open').Count | Should -Be 0
        $afterMaster = @(Compare-PEState -Blueprint $blueprint -Target $devTarget -Decisions @(Get-PEDecision -Tenant 'master' -DataRoot $script:Temp))
        @($afterMaster | Where-Object State -EQ 'Open').Count | Should -BeGreaterThan 0
    }
    It 'registers a tenant from the Tenants page through the worker, and refuses bad details' {
        Mock -ModuleName PolicyEngine Connect-PETenant { }
        $connect = @{ slug = 'dev'; displayName = 'Contoso Dev'; tenantDomain = 'contoso-dev.onmicrosoft.com'; readerApplicationId = '11111111-2222-3333-4444-555555555555'; readerThumbprint = 'AABBCCDDEEFF00112233445566778899AABBCCDD'; writerApplicationId = ''; writerThumbprint = '' }
        foreach ($bad in @(@{ slug = 'master' }, @{ slug = 'Bad Slug' }, @{ tenantDomain = 'x y' }, @{ readerApplicationId = 'nope' }, @{ readerThumbprint = 'short' }, @{ writerApplicationId = '11111111-2222-3333-4444-555555555555' }))
        {
            $try = $connect.Clone()
            foreach ($key in $bad.Keys) { $try[$key] = $bad[$key] }
            $reply = Invoke-PEGuiApi -DataRoot $script:Gui -Method POST -Path '/api/requests' -Body ([pscustomobject]@{ action = 'ConnectTenant'; connect = [pscustomobject]$try })
            $reply.StatusCode | Should -Be 400 -Because ($bad.Keys -join ',')
        }
        $id = Send-Request @{ action = 'ConnectTenant'; connect = $connect }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $job = Get-TestJob $id
        $job.status | Should -Be 'Succeeded' -Because $job.result
        $job.result | Should -BeLike "*Tenant 'dev' registered as a replica*no Writer app*"
        Should -Invoke -ModuleName PolicyEngine Connect-PETenant -Times 1 -ParameterFilter { $Slug -eq 'dev' -and $TenantId -eq 'contoso-dev.onmicrosoft.com' -and -not $PSBoundParameters.ContainsKey('WriterApplicationId') }
    }

    It 'renames a tenant and keeps its tenant id and blueprints; no tenant is written to' {
        Set-PETenant -Slug 'dev' -DisplayName 'Dev' -TenantId 'dev.onmicrosoft.com' -Blueprints @('main', 'dev') -DataRoot $script:Temp | Out-Null
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $id = Send-Request @{ action = 'RenameTenant'; tenantId = 'dev'; displayName = 'Robs tenant' }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $job = Get-TestJob $id
        $job.status | Should -Be 'Succeeded' -Because $job.result
        $t = Get-PETenant -Slug 'dev' -DataRoot $script:Temp
        $t.DisplayName | Should -Be 'Robs tenant'
        $t.TenantId | Should -Be 'dev.onmicrosoft.com'
        @($t.Blueprints) | Should -Be @('main', 'dev')
        ((Get-Content (Join-Path $script:Gui 'index.json') -Raw | ConvertFrom-Json).tenants | Where-Object tenantId -EQ 'dev').displayName | Should -Be 'Robs tenant'
    }

    It 'refuses a rename to an empty, blank or over-long name, or of an unknown tenant, and keeps the stored name' {
        Set-PETenant -Slug 'dev' -DisplayName 'Dev' -TenantId 'dev.onmicrosoft.com' -DataRoot $script:Temp | Out-Null
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        foreach ($try in @(@{ tenantId = 'dev'; displayName = ''; message = 'A name is required.' }, @{ tenantId = 'dev'; displayName = '   '; message = 'A name is required.' }, @{ tenantId = 'dev'; displayName = ('x' * 81); message = 'longer than 80 characters' }, @{ tenantId = 'nobody'; displayName = 'Name'; message = '*nobody*' }))
        {
            $reply = Invoke-PEGuiApi -DataRoot $script:Gui -Method POST -Path '/api/requests' -Body ([pscustomobject]@{ action = 'RenameTenant'; tenantId = $try.tenantId; displayName = $try.displayName })
            $reply.StatusCode | Should -Be 400 -Because "$($try.tenantId) '$($try.displayName)'"
            $reply.Json | Should -BeLike "*$($try.message.Trim('*'))*"
        }
        (Get-PETenant -Slug 'dev' -DataRoot $script:Temp).DisplayName | Should -Be 'Dev'
    }

    It 'serves the DSC setup script for the Tenants page' {
        $reply = Invoke-PEGuiApi -DataRoot $script:Gui -Method GET -Path '/api/tenant-setup'
        $reply.StatusCode | Should -Be 200
        ($reply.Json | ConvertFrom-Json).script | Should -Match 'Update-M365DSCAzureAdApplication'
    }
    It 'fails a job whose request file is missing' {
        $id = Send-Request @{ action = 'Exclude'; tenantId = 'master'; reason = 'retired'; items = @(@{ itemId = 'AADGroup~Extra' }) }
        Get-ChildItem (Join-Path $script:Gui 'requests') | Remove-Item
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        (Get-TestJob $id).status | Should -Be 'Failed'
        (Get-TestJob $id).result | Should -BeLike '*not found*'
    }

    It 'leaves mock jobs alone' {
        $path = Join-Path $script:Gui 'activity'
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        [ordered]@{ jobId = 'J-9'; requestId = 'x'; status = 'Queued'; mock = $true } | ConvertTo-Json | Set-Content (Join-Path $path 'J-9.json')
        (Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui).Processed | Should -Be 0
        (Get-TestJob 'J-9').status | Should -Be 'Queued'
    }
}

Describe 'Revert preview in the dialog' -Tag 'Slow' {
    BeforeAll {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-guirev-' + [guid]::NewGuid())
        $script:Gui = Join-Path $script:Temp 'gui'
        Initialize-PEBlueprint -Name 'main' -State (New-TestState -Records @((New-TestRecord -Key 'Sales' -Props @{ Description = 'one' }), (New-TestRecord -Key 'Finance'), (New-TestRecord -Key 'Gone'))) -DataRoot $script:Temp | Out-Null
        $target = New-TestState -Records @((New-TestRecord -Key 'Sales' -Props @{ Description = 'two' }), (New-TestRecord -Key 'Finance'), (New-TestRecord -Key 'Extra'))
        $findings = @(Compare-PEState -Blueprint (Get-PEBlueprint -Name 'main' -DataRoot $script:Temp) -Target $target)
        $directory = Join-Path $script:Temp 'checks\20261021-020000'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        [ordered]@{ CheckId = '20261021-020000'; Kind = 'Full'; BlueprintName = 'main'; BlueprintVersion = 1; Findings = $findings; State = $target } |
            ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $directory 'result.json') -Encoding utf8
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
    }

    AfterAll {
        Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'stores the generated block with each revertable item' {
        $sales = Get-Content (Join-Path $script:Gui 'tenants\master\items\AADGroup~Sales.json') -Raw | ConvertFrom-Json
        $sales.revert.action | Should -Be 'Update'
        $sales.revert.block | Should -Match "Description\s*=\s*'About Sales'|Description\s*=\s*'one'"
        $extra = Get-Content (Join-Path $script:Gui 'tenants\master\items\AADGroup~Extra.json') -Raw | ConvertFrom-Json
        $extra.revert.action | Should -Be 'Remove'
        $extra.revert.block | Should -Match "Ensure\s*=\s*'Absent'"
    }

    It 'shows exactly that configuration in the Revert preview' {
        $body = [pscustomobject]@{ action = 'Accept'; tenantId = 'master'; reason = 'x'; confirmedMasterWrite = $true; items = @(@{ itemId = 'AADGroup~Sales' }, @{ itemId = 'AADGroup~Extra' }, @{ itemId = 'AADGroup~Gone' }) }
        $reply = Invoke-PEGuiApi -DataRoot $script:Gui -Method POST -Path '/api/requests/preview' -Body $body
        $preview = $reply.Json | ConvertFrom-Json
        $preview.valid | Should -BeTrue -Because $reply.Json
        $preview.config | Should -Match 'Resource instances: 3'
        $preview.config | Should -Match "AADGroup 'AADGroup-Sales'"
        $preview.config | Should -Match "Ensure\s*=\s*'Absent'"
        $preview.config | Should -Match "Ensure\s*=\s*'Present'"
        $preview.config | Should -Not -Match 'Preview of'
        $preview.config | Should -Match 'Import-DscResource'
    }

    It 'gives a configuration the apply tool counts correctly once it is saved as an exported file (header comment, renamed configuration)' {
        . (Join-Path (Split-Path $PSScriptRoot) 'tools/PEApply.Common.ps1')
        $body = [pscustomobject]@{ action = 'Accept'; tenantId = 'master'; reason = 'x'; confirmedMasterWrite = $true; items = @(@{ itemId = 'AADGroup~Sales' }, @{ itemId = 'AADGroup~Extra' }) }
        $preview = (Invoke-PEGuiApi -DataRoot $script:Gui -Method POST -Path '/api/requests/preview' -Body $body).Json | ConvertFrom-Json
        $expected = [int]([regex]::Match($preview.config, 'Resource instances: (\d+)').Groups[1].Value)
        $file = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-export-' + [guid]::NewGuid() + '.ps1')
        try
        {
            $text = "# Revert configuration exported from the Drift Engine GUI.`n#   Update AADGroup 'Sales'`n" + ($preview.config -replace '(?m)^Configuration \S+', 'Configuration PE_masterEntraID') + "`n"
            Set-Content -LiteralPath $file -Value $text -Encoding utf8
            $expected | Should -Be 2
            Get-PEConfigResourceCount -Path $file | Should -Be $expected
            $text | Should -Match '(?m)^Configuration PE_masterEntraID\s*$'
        }
        finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'UploadSnapshot' {
    BeforeAll {
        $script:Fixtures = Join-Path $PSScriptRoot 'fixtures\upload'
        function Get-UploadBody
        {
            param ([string[]]$Name, [hashtable]$Override = @{})
            $body = @{
                action = 'UploadSnapshot'; tenantId = 'acme'; tenantDomain = 'acme.example'; completeWorkloads = @(); saveAsBlueprint = $true
                newTenant = @{ slug = 'acme'; displayName = 'Acme' }
                files = @($Name | ForEach-Object { @{ name = $_; text = (Get-Content -LiteralPath (Join-Path $script:Fixtures $_) -Raw) } })
            }
            foreach ($k in $Override.Keys) { $body[$k] = $Override[$k] }
            $body
        }
    }

    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-guiup-' + [guid]::NewGuid())
        $script:Gui = Join-Path $script:Temp 'gui'
        Initialize-PEBlueprint -Name 'main' -State (New-TestState -Records @((New-TestRecord -Key 'Sales'))) -DataRoot $script:Temp | Out-Null
        # The master's own check, so the GUI data can be exported before any upload.
        $masterState = New-TestState -Records @((New-TestRecord -Key 'Sales'))
        $masterDir = Join-Path $script:Temp 'checks\20261021-020000'
        New-Item -ItemType Directory -Path $masterDir -Force | Out-Null
        [ordered]@{ CheckId = '20261021-020000'; Kind = 'Full'; BlueprintName = 'main'; BlueprintVersion = 1; Findings = @(); State = $masterState } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $masterDir 'result.json') -Encoding utf8
        Mock -ModuleName PolicyEngine Get-PEGuiRevertConfig { @{ Wrapper = $null; Items = @{} } }
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'registers a new offline tenant, stores a check and seeds its own blueprint from the first upload' {
        $id = Send-Request (Get-UploadBody 'entra.ps1', 'exchange.ps1')
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $job = Get-TestJob $id
        $job.status | Should -Be 'Succeeded' -Because $job.result
        $job.result | Should -BeLike 'Snapshot uploaded (check *): 0 drifted item(s), * type(s) not checked.*'
        $tenant = Get-PETenant -Slug 'acme' -DataRoot $script:Temp
        $tenant.Offline | Should -BeTrue
        $tenant.DisplayName | Should -Be 'Acme'
        $tenant.TenantId | Should -Be 'acme.example'
        @($tenant.Blueprints) | Should -Be @('main', 'acme')
        $check = Get-PECheck -Latest -Kind Full -Tenant 'acme' -DataRoot $script:Temp
        $check.BlueprintName | Should -Be 'acme'
        (Get-PEBlueprint -Name 'acme' -DataRoot $script:Temp).Records.Count | Should -BeGreaterThan 0
    }

    It 'says the tenant and first check were stored when seeding the blueprint fails afterwards' {
        Mock -ModuleName PolicyEngine Initialize-PETenantBlueprint { throw 'seed boom' }
        $id = Send-Request (Get-UploadBody 'entra.ps1')
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $job = Get-TestJob $id
        $job.status | Should -Be 'Failed'
        $job.result | Should -BeLike "*tenant 'acme' was registered*its check *stored*blueprint could not be seeded*seed boom*"
        @(Get-PETenant -DataRoot $script:Temp | Where-Object Slug -EQ 'acme').Count | Should -Be 1
    }

    It 'without saveAsBlueprint the tenant keeps following the master blueprint and the check is compared with it' {
        $id = Send-Request (Get-UploadBody 'entra.ps1' -Override @{ saveAsBlueprint = $false })
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        (Get-TestJob $id).status | Should -Be 'Succeeded' -Because (Get-TestJob $id).result
        @((Get-PETenant -Slug 'acme' -DataRoot $script:Temp).Blueprints) | Should -Be @('main')
        (Get-PECheck -Latest -Kind Full -Tenant 'acme' -DataRoot $script:Temp).BlueprintName | Should -Be 'main'
    }

    It 'a file of another version fails the job with both versions and leaves no tenant registered' {
        $id = Send-Request (Get-UploadBody 'entra.ps1', 'other-version.ps1')
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $job = Get-TestJob $id
        $job.status | Should -Be 'Failed'
        $job.result | Should -BeLike '*other-version.ps1*'
        @(Get-PETenant -DataRoot $script:Temp | Where-Object Slug -EQ 'acme').Count | Should -Be 0
    }

    It 'refuses a new tenant whose slug the registry already holds, and keeps that tenant as it was' {
        Set-PETenant -Slug 'acme' -DisplayName 'Real' -DataRoot $script:Temp | Out-Null
        $id = Send-Request (Get-UploadBody 'entra.ps1')
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        (Get-TestJob $id).status | Should -Be 'Failed'
        (Get-TestJob $id).result | Should -BeLike '*already*'
        (Get-PETenant -Slug 'acme' -DataRoot $script:Temp).DisplayName | Should -Be 'Real'
    }

    It 'uploads a newer export for an existing offline tenant that has its own blueprint' {
        $id = Send-Request (Get-UploadBody 'entra.ps1')
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        (Get-TestJob $id).status | Should -Be 'Succeeded'
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $again = Send-Request (Get-UploadBody 'entra.ps1' -Override @{ newTenant = $null; saveAsBlueprint = $false })
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        (Get-TestJob $again).status | Should -Be 'Succeeded' -Because (Get-TestJob $again).result
    }

    It 'a tenant that is not offline cannot be uploaded to' {
        Set-PETenant -Slug 'live' -DisplayName 'Live' -DataRoot $script:Temp | Out-Null
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $id = Send-Request (Get-UploadBody 'entra.ps1' -Override @{ tenantId = 'live'; newTenant = $null })
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        (Get-TestJob $id).status | Should -Be 'Failed'
        (Get-TestJob $id).result | Should -BeLike '*not offline*'
    }

    It 'Recheck of an offline tenant fails early with the offline message' {
        Set-PETenant -Slug 'acme' -Offline -Blueprints @('main') -DataRoot $script:Temp | Out-Null
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $id = Send-Request @{ action = 'Recheck'; tenantId = 'acme' }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $job = Get-TestJob $id
        $job.status | Should -Be 'Failed'
        $job.result | Should -BeLike "*Tenant 'acme' is offline: upload a newer export instead."
    }
}

Describe 'GenerateConfig' {
    BeforeAll {
        # The shape ConvertTo-PEDscConfig gives (Split-PEDscConfigText counts the blocks), with a marker for the text.
        function New-FakeConfig
        {
            param ([string]$Name, [string[]]$Key)
            $blocks = ($Key | ForEach-Object { "        AADGroup 'AADGroup-$_'`n        {`n            DisplayName = '$_';`n        }" }) -join "`n"
            "# MARKER-$Name`nConfiguration $Name`n{`n    Node localhost`n    {`n$blocks`n    }`n}`n"
        }
    }

    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-guigen-' + [guid]::NewGuid())
        $script:Gui = Join-Path $script:Temp 'gui'
        Initialize-PEBlueprint -Name 'main' -State (New-TestState -Records @((New-TestRecord -Key 'Sales'))) -DataRoot $script:Temp | Out-Null
        $masterDir = Join-Path $script:Temp 'checks\20261021-020000'
        New-Item -ItemType Directory -Path $masterDir -Force | Out-Null
        [ordered]@{ CheckId = '20261021-020000'; Kind = 'Full'; BlueprintName = 'main'; BlueprintVersion = 1; Findings = @(); State = (New-TestState -Records @((New-TestRecord -Key 'Sales'))) } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $masterDir 'result.json') -Encoding utf8
        Mock -ModuleName PolicyEngine Get-PEGuiRevertConfig { @{ Wrapper = $null; Items = @{} } }
        Add-ReplicaCheck -OwnRecords @((New-TestRecord -Key 'Sales'), (New-TestRecord -Key 'Gone')) -TenantRecords @((New-TestRecord -Key 'Sales'), (New-TestRecord -Key 'Extra'))
        # The tenant id the stored check names (New-TestState), so the generator accepts the check as this tenant's.
        Set-PETenant -Slug 'dev' -Offline -TenantId 't' -DataRoot $script:Temp | Out-Null
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'writes Changes.ps1, Removals.ps1 and Manual.json for the job and says how many items each holds; the job holds no configuration text' {
        Mock -ModuleName PolicyEngine New-PEOfflineConfig {
            [pscustomobject]@{
                Changes = (New-FakeConfig 'PE_Changes' 'Gone', 'Sales'); Removals = (New-FakeConfig 'PE_Removals' 'Extra'); CheckId = '20261021-030000'; BlueprintName = 'dev'
                Manual = @([pscustomobject]@{ ResourceType = 'AADGroup'; Key = 'Hidden'; Action = 'Create'; Reason = 'Refusing to embed property Members' })
            }
        }
        $id = Send-Request @{ action = 'GenerateConfig'; tenantId = 'dev' }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        Should -Invoke -ModuleName PolicyEngine New-PEOfflineConfig -Times 1 -Exactly -ParameterFilter { $Tenant -ceq 'dev' -and $DataRoot -eq $script:Temp }
        $job = Get-TestJob $id
        $job.status | Should -Be 'Succeeded' -Because $job.result
        $job.result | Should -Be "Configuration generated from check 20261021-030000 against blueprint 'dev': 2 item(s) in Changes.ps1, 1 in Removals.ps1 (run it after the changes), 1 item(s) need manual action. Nothing was written to a tenant."
        $job.files.changes | Should -Be 2
        $job.files.removals | Should -Be 1
        $job.files.manual | Should -Be 1
        $job.config | Should -BeNullOrEmpty
        $folder = Join-Path $script:Gui "configs\$id"
        Get-Content (Join-Path $folder 'Changes.ps1') -Raw | Should -BeLike '# MARKER-PE_Changes*'
        Get-Content (Join-Path $folder 'Removals.ps1') -Raw | Should -BeLike '# MARKER-PE_Removals*'
        $manual = @(Get-Content (Join-Path $folder 'Manual.json') -Raw | ConvertFrom-Json)
        $manual.Count | Should -Be 1
        $manual[0].Key | Should -Be 'Hidden'
        $manual[0].Reason | Should -Be 'Refusing to embed property Members'
        # The text stays in the files: not in the job, not in the request.
        Get-Content (Join-Path $script:Gui "activity\$id.json") -Raw | Should -Not -Match 'MARKER'
        (Get-ChildItem (Join-Path $script:Gui 'requests') | Get-Content -Raw) | Should -Not -Match 'MARKER'
    }

    It 'writes no Removals.ps1 when there is nothing to remove, and always an array in Manual.json' {
        Mock -ModuleName PolicyEngine New-PEOfflineConfig { [pscustomobject]@{ Changes = (New-FakeConfig 'PE_Changes' 'Gone'); Removals = $null; Manual = @(); CheckId = '20261021-030000'; BlueprintName = 'dev' } }
        $id = Send-Request @{ action = 'GenerateConfig'; tenantId = 'dev' }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $job = Get-TestJob $id
        $job.status | Should -Be 'Succeeded' -Because $job.result
        $job.result | Should -BeLike '*1 item(s) in Changes.ps1, nothing to remove, 0 item(s) need manual action.*'
        $job.files.removals | Should -Be 0
        $folder = Join-Path $script:Gui "configs\$id"
        Test-Path (Join-Path $folder 'Changes.ps1') | Should -BeTrue
        Test-Path (Join-Path $folder 'Removals.ps1') | Should -BeFalse
        (Get-Content (Join-Path $folder 'Manual.json') -Raw).Trim() | Should -Be '[]'
    }

    It 'says so when the blueprint version it compared with is not the one the check was made against' {
        Mock -ModuleName PolicyEngine New-PEOfflineConfig { [pscustomobject]@{ Changes = (New-FakeConfig 'PE_Changes' 'Gone'); Removals = $null; Manual = @(); CheckId = '20261021-030000'; BlueprintName = 'dev'; BlueprintVersion = 3; CheckBlueprintVersion = 2 } }
        $id = Send-Request @{ action = 'GenerateConfig'; tenantId = 'dev' }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $job = Get-TestJob $id
        $job.status | Should -Be 'Succeeded' -Because $job.result
        $job.result | Should -BeLike "Configuration generated from check 20261021-030000 against blueprint 'dev': *. Compared with blueprint 'dev' v3; the check was made against v2."
    }

    It 'says how many target-only items were not removed because the blueprint has no records of their type' {
        Mock -ModuleName PolicyEngine New-PEOfflineConfig {
            [pscustomobject]@{
                Changes = $null; Removals = $null; CheckId = '20261021-030000'; BlueprintName = 'dev'; NoBlueprintTypeCount = 2
                Manual = @(
                    [pscustomobject]@{ ResourceType = 'EXOAcceptedDomain'; Key = 'a.example'; Action = 'Remove'; Reason = "type 'EXOAcceptedDomain' has no records in the blueprint" },
                    [pscustomobject]@{ ResourceType = 'EXOAcceptedDomain'; Key = 'b.example'; Action = 'Remove'; Reason = "type 'EXOAcceptedDomain' has no records in the blueprint" })
            }
        }
        $id = Send-Request @{ action = 'GenerateConfig'; tenantId = 'dev' }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $job = Get-TestJob $id
        $job.status | Should -Be 'Succeeded' -Because $job.result
        $job.result | Should -BeLike "*2 item(s) need manual action. 2 of them exist only in the tenant, of a type with no records in the blueprint, so they are not removed. Nothing was written to a tenant."
    }

    It 'fails the job and leaves no files when the configuration cannot be generated' {
        Mock -ModuleName PolicyEngine New-PEOfflineConfig { throw "Tenant 'dev' has no blueprint of its own." }
        $id = Send-Request @{ action = 'GenerateConfig'; tenantId = 'dev' }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $job = Get-TestJob $id
        $job.status | Should -Be 'Failed'
        $job.result | Should -BeLike '*no blueprint of its own*'
        Test-Path (Join-Path $script:Gui "configs\$id") | Should -BeFalse
    }

    It 'never overwrites the files of a job' {
        Mock -ModuleName PolicyEngine New-PEOfflineConfig { [pscustomobject]@{ Changes = (New-FakeConfig 'PE_Changes' 'Gone'); Removals = $null; Manual = @(); CheckId = '20261021-030000'; BlueprintName = 'dev' } }
        $id = Send-Request @{ action = 'GenerateConfig'; tenantId = 'dev' }
        $existing = Join-Path $script:Gui "configs\$id\Changes.ps1"
        New-Item -ItemType Directory -Force -Path (Split-Path $existing) | Out-Null
        Set-Content -LiteralPath $existing -Value 'older'
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        (Get-TestJob $id).status | Should -Be 'Failed'
        (Get-Content -LiteralPath $existing -Raw).Trim() | Should -Be 'older'
    }

    It 'generates the real files in the worker and writes nothing to a tenant, a blueprint, a check or the decisions' -Tag 'Slow' {
        $checks = @(Get-ChildItem (Join-Path $script:Temp 'checks') -Directory).Count
        $versions = @(Get-TestVersion -Name 'dev' -Root $script:Temp)
        $id = Send-Request @{ action = 'GenerateConfig'; tenantId = 'dev' }
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $job = Get-TestJob $id
        $job.status | Should -Be 'Succeeded' -Because $job.result
        $folder = Join-Path $script:Gui "configs\$id"
        $changes = Join-Path $folder 'Changes.ps1'
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($changes, [ref]$null, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
        Get-Content $changes -Raw | Should -Match "DisplayName\s+= 'Gone';"
        Get-Content (Join-Path $folder 'Removals.ps1') -Raw | Should -Match "Ensure\s+= 'Absent';"
        @(Get-ChildItem (Join-Path $script:Temp 'checks') -Directory).Count | Should -Be $checks
        @(Get-TestVersion -Name 'dev' -Root $script:Temp) | Should -Be $versions
        @(Get-PEDecision -DataRoot $script:Temp).Count | Should -Be 0
        Test-Path (Join-Path $script:Temp 'audit') | Should -BeFalse
    }
}
