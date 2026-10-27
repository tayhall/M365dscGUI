BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force

    # Recognisable app identifiers injected through Get-PERectifyRedaction; they must never come back.
    $script:FakeThumb = 'C0FFEE00C0FFEE00C0FFEE00C0FFEE00C0FFEE00'
    $script:FakeAppId = 'deadbeef-1111-2222-3333-444455556666'

    function New-TestGroup
    {
        param
        (
            [string]$Name,
            [string]$Description = "About $Name"
        )

        [pscustomobject]@{
            ResourceType = 'AADGroup'
            Key          = $Name
            Workload     = 'Entra ID'
            Properties   = [ordered]@{
                DisplayName     = $Name
                MailNickname    = ($Name -replace '[^A-Za-z0-9]', '').ToLowerInvariant() + 'nick'
                SecurityEnabled = $true
                MailEnabled     = $false
                Description     = $Description
                Ensure          = 'Present'
            }
        }
    }

    function New-TestState
    {
        param
        (
            [object[]]$Records = @(),
            [hashtable]$Meta = @{ TenantId = 'dev.onmicrosoft.com'; ExportedAt = '2026-10-21T10:00:00Z'; Source = 'full check' }
        )

        & (Get-Module PolicyEngine) {
            param ($r, $m)
            New-PEState -Records $r -NotChecked @() -Meta $m
        } $Records $Meta
    }

    function New-TestRemoveDecision
    {
        param ([string]$Key)

        [pscustomobject]@{ Kind = 'Remove'; ResourceType = 'AADGroup'; Key = $Key; Property = $null; Value = $null; Reason = 'test'; At = '2026-10-21T00:00:00.000Z' }
    }

    function New-TestApplyResult
    {
        # The shape tools\Invoke-PEApply.ps1 -Json emits.
        param
        (
            [string[]]$Types,
            [string]$Status = 'Applied',
            [bool]$Success = $true
        )

        $resources = for ($i = 0; $i -lt $Types.Count; $i++)
        {
            [pscustomobject]@{
                ResourceId = "[$($Types[$i])]$($Types[$i])-$i"; ResourceType = $Types[$i]; Status = $Status
                InDesiredStateBefore = $false; SetInvoked = $true; RebootRequired = $false; InDesiredStateAfter = $true; Seconds = 1; Error = $null
            }
        }
        [pscustomobject]@{
            Success = $Success; TestOnly = $false; PartiallyApplied = $false; ResourceCount = $Types.Count; ExpectedResourceCount = $Types.Count
            OutputFolder = $null; MofPath = $null; CompileSeconds = 1; ApplySeconds = 1; Error = $null; Resources = @($resources)
        }
    }

    function Initialize-TestData
    {
        # A temp data root with blueprint 'main' (version 1: Sales, HR) and the check of a target (Sales edited,
        # DevOnly) against it, read back exactly as a user would get them.
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-rectify-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Temp | Out-Null
        $state = New-TestState -Meta @{ TenantId = 'prod.onmicrosoft.com'; ExportedAt = '2026-10-20T08:00:00Z'; Source = 'full check' } -Records @(
            (New-TestGroup -Name 'Sales' -Description 'Sales team'),
            (New-TestGroup -Name 'HR' -Description 'People team')
        )
        Initialize-PEBlueprint -Name 'main' -State $state -DataRoot $script:Temp | Out-Null
        $script:Blueprint = Get-PEBlueprint -Name 'main' -DataRoot $script:Temp
        $script:Target = New-TestState -Records @(
            (New-TestGroup -Name 'Sales' -Description 'Sales team (edited)'),
            (New-TestGroup -Name 'DevOnly' -Description 'Built in Dev')
        )
        $script:Findings = @(Compare-PEState -Blueprint $script:Blueprint -Target $script:Target)
        $script:PlanArgs = @{ Source = $script:Target; Blueprint = $script:Blueprint }
    }

    function New-TestPlan
    {
        param ([ValidateSet('Create', 'Update', 'Remove', 'Promote', 'CreateUpdate')][string]$Kind)

        switch ($Kind)
        {
            'Create' { @(New-PERectifyPlan -Findings @($script:Findings | Where-Object Kind -EQ 'Missing') -Action Create @PlanArgs) }
            'Update' { @(New-PERectifyPlan -Findings @($script:Findings | Where-Object Kind -EQ 'Changed') -Action Update @PlanArgs) }
            'Remove' { @(New-PERectifyPlan -Findings @($script:Findings | Where-Object Kind -EQ 'TargetOnly') -Action Remove @PlanArgs -Decisions @(New-TestRemoveDecision -Key 'DevOnly')) }
            'Promote' { @(New-PERectifyPlan -Findings @($script:Findings | Where-Object Kind -EQ 'TargetOnly') -Action Promote @PlanArgs) }
            'CreateUpdate'
            {
                @(New-PERectifyPlan -Findings @($script:Findings | Where-Object Kind -EQ 'Missing') -Action Create @PlanArgs) +
                @(New-PERectifyPlan -Findings @($script:Findings | Where-Object Kind -EQ 'Changed') -Action Update @PlanArgs)
            }
        }
    }

    function Get-TestAuditFolders
    {
        @(Get-ChildItem -LiteralPath (Join-Path $script:Temp 'audit') -Directory -ErrorAction SilentlyContinue)
    }
}

Describe 'Invoke-PERectify preconditions (nothing generated, saved or applied)' {
    BeforeEach {
        Initialize-TestData
        $script:ApplyCalls = 0
        $script:RecheckCalls = 0
        $script:Apply = { param ($ConfigPath, $ExpectedResourceCount) $script:ApplyCalls++; New-TestApplyResult -Types @('AADGroup') }
        $script:Recheck = { param ($Items) $script:RecheckCalls++; @() }
        $script:Seams = @{ ApplyScript = $script:Apply; RecheckScript = $script:Recheck; DataRoot = $script:Temp; BlueprintName = 'main' }
        Mock -ModuleName PolicyEngine Get-PERectifyRedaction { , [string[]]@($script:FakeThumb, $script:FakeAppId) }
        Mock -ModuleName PolicyEngine Get-PERectifyWriterApp { [pscustomobject]@{ Role = 'Writer'; TenantId = 'dev.onmicrosoft.com'; ApplicationId = $script:FakeAppId; Thumbprint = $script:FakeThumb } }
        Mock -ModuleName PolicyEngine ConvertTo-PEDscConfig { throw 'safety net: a precondition test reached ConvertTo-PEDscConfig' }
    }

    AfterEach {
        $script:ApplyCalls | Should -Be 0
        $script:RecheckCalls | Should -Be 0
        @(Get-TestAuditFolders).Count | Should -Be 0
        Remove-Item $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'an empty plan throws' {
        { Invoke-PERectify -Plan @() -Target Replica @Seams } | Should -Throw '*empty*'
        { Invoke-PERectify -Plan @($null) -Target Replica @Seams } | Should -Throw '*empty*'
    }

    It 'a hand-built item throws' {
        $item = (New-TestPlan -Kind Create)[0] | Select-Object *
        { Invoke-PERectify -Plan @($item) -Target Replica @Seams } | Should -Throw '*not produced by New-PERectifyPlan*'
    }

    It 'Promote without -ConfirmMasterWrite throws, naming the item' {
        { Invoke-PERectify -Plan (New-TestPlan -Kind Promote) -Target Replica -Reason 'r' @Seams } | Should -Throw "*Promote*ConfirmMasterWrite*Promote AADGroup 'DevOnly'*"
        { Invoke-PERectify -Plan (New-TestPlan -Kind Promote) -Target Master -Reason 'r' @Seams } | Should -Throw "*ConfirmMasterWrite*Promote AADGroup 'DevOnly'*"
    }

    It 'Target Master without -ConfirmMasterWrite throws' {
        { Invoke-PERectify -Plan (New-TestPlan -Kind Create) -Target Master @Seams } | Should -Throw "*Target Master*ConfirmMasterWrite*Create AADGroup 'HR'*"
    }

    It 'Promote without -Reason throws' {
        { Invoke-PERectify -Plan (New-TestPlan -Kind Promote) -Target Master -ConfirmMasterWrite @Seams } | Should -Throw '*-Reason*'
        { Invoke-PERectify -Plan (New-TestPlan -Kind Promote) -Target Master -ConfirmMasterWrite -Reason '  ' @Seams } | Should -Throw '*-Reason*'
    }

    It 'Remove on the master needs -ConfirmMasterWrite like every master write' {
        { Invoke-PERectify -Plan (New-TestPlan -Kind Remove) -Target Master @Seams } | Should -Throw '*ConfirmMasterWrite*'
    }

    It 'a blueprint version created between plan and apply throws before any apply' {
        $plan = New-TestPlan -Kind Create
        $master = New-TestState -Records @(@($script:Blueprint.Records) + @(New-TestGroup -Name 'Extra')) -Meta @{ ExportedAt = '2026-10-21T12:00:00Z' }
        $accept = @(Get-PEBlueprintChange -Name 'main' -MasterState $master -DataRoot $script:Temp | Where-Object Kind -EQ 'Missing')
        Approve-PEBlueprintChange -Name 'main' -MasterState $master -Accept $accept -Reason 'bump' -DataRoot $script:Temp | Should -Be 2
        { Invoke-PERectify -Plan $plan -Target Replica @Seams } | Should -Throw '*blueprint changed since the plan was made; re-run the check*version 1*latest is 2*'
    }

    It 'a plan from another tenant than the Writer app''s is refused' {
        Mock -ModuleName PolicyEngine Get-PERectifyWriterApp { [pscustomobject]@{ Role = 'Writer'; TenantId = 'prod.onmicrosoft.com'; ApplicationId = 'x'; Thumbprint = 'y' } }
        { Invoke-PERectify -Plan (New-TestPlan -Kind Create) -Target Replica @Seams } | Should -Throw "*planned from tenant 'dev.onmicrosoft.com'*Writer app applies to 'prod.onmicrosoft.com'*"
    }

    It 'a plan whose check state has an unknown tenant is refused' {
        $source = New-TestState -Records $script:Target.Records -Meta @{ TenantId = 'unknown'; ExportedAt = '2026-10-21T10:00:00Z'; Source = 'delta' }
        $plan = @(New-PERectifyPlan -Findings @($script:Findings | Where-Object Kind -EQ 'Missing') -Action Create -Source $source -Blueprint $script:Blueprint)
        { Invoke-PERectify -Plan $plan -Target Replica @Seams } | Should -Throw '*no known tenant*'
        $source = New-TestState -Records $script:Target.Records -Meta @{ ExportedAt = '2026-10-21T10:00:00Z'; Source = 'delta' }
        $plan = @(New-PERectifyPlan -Findings @($script:Findings | Where-Object Kind -EQ 'Missing') -Action Create -Source $source -Blueprint $script:Blueprint)
        { Invoke-PERectify -Plan $plan -Target Replica @Seams } | Should -Throw '*no known tenant*'
    }
    It 'a plan made against another blueprint throws' {
        $other = New-TestState -Meta @{ ExportedAt = '2026-09-01T00:00:00Z' } -Records @(New-TestGroup -Name 'HR' -Description 'People team')
        Initialize-PEBlueprint -Name 'other' -State $other -DataRoot $script:Temp | Out-Null
        $arguments = $script:Seams.Clone()
        $arguments['BlueprintName'] = 'other'
        { Invoke-PERectify -Plan (New-TestPlan -Kind Create) -Target Replica @arguments } | Should -Throw '*blueprint changed since the plan was made*'
    }
}

Describe 'Invoke-PERectify' -Tag 'Slow' {
    BeforeEach {
        Initialize-TestData
        $script:ApplyCalls = [System.Collections.Generic.List[object]]::new()
        $script:RecheckCalls = [System.Collections.Generic.List[object]]::new()
        $script:ApplyResult = $null
        $script:RecheckResult = @()
        $script:Apply = {
            param ([string]$ConfigPath, [int]$ExpectedResourceCount, [string]$ConfigurationName)
            $folder = Split-Path -Parent $ConfigPath
            $script:ApplyCalls.Add([pscustomobject]@{
                    ConfigPath            = $ConfigPath
                    ExpectedResourceCount = $ExpectedResourceCount
                    ConfigurationName     = $ConfigurationName
                    ConfigExists          = (Test-Path -LiteralPath $ConfigPath -PathType Leaf)
                    PlanExists            = (Test-Path -LiteralPath (Join-Path $folder 'plan.json') -PathType Leaf)
                    WhoExists             = (Test-Path -LiteralPath (Join-Path $folder 'who.txt') -PathType Leaf)
                })
            if ($script:ApplyResult -is [scriptblock]) { & $script:ApplyResult } else { $script:ApplyResult }
        }
        $script:Recheck = {
            param ($Items)
            $script:RecheckCalls.Add(@($Items))
            if ($script:RecheckResult -is [scriptblock]) { & $script:RecheckResult } else { $script:RecheckResult }
        }
        $script:Seams = @{ ApplyScript = $script:Apply; RecheckScript = $script:Recheck; DataRoot = $script:Temp; BlueprintName = 'main'; User = 'tester' }
        Mock -ModuleName PolicyEngine Get-PERectifyRedaction { , [string[]]@($script:FakeThumb, $script:FakeAppId) }
        Mock -ModuleName PolicyEngine Get-PERectifyWriterApp { [pscustomobject]@{ Role = 'Writer'; TenantId = 'DEV.onmicrosoft.com'; ApplicationId = $script:FakeAppId; Thumbprint = $script:FakeThumb } }
        Mock -ModuleName PolicyEngine Invoke-PERectifyApplyTool { throw 'safety net: the real apply tool must not run in tests' }
        Mock -ModuleName PolicyEngine Invoke-PERectifyRecheck { throw 'safety net: the real recheck must not run in tests' }
    }

    AfterEach {
        Remove-Item $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'saves the audit before the apply runs and passes the plan count' {
        $plan = New-TestPlan -Kind CreateUpdate
        $script:ApplyResult = New-TestApplyResult -Types @('AADGroup', 'AADGroup')
        $result = Invoke-PERectify -Plan $plan -Target Replica @Seams
        $script:ApplyCalls.Count | Should -Be 1
        $call = $script:ApplyCalls[0]
        $call.ConfigExists | Should -BeTrue
        $call.PlanExists | Should -BeTrue
        $call.WhoExists | Should -BeTrue
        $call.ExpectedResourceCount | Should -Be 2
        $call.ConfigurationName | Should -Be 'PERectify'
        $call.ConfigPath | Should -Be (Join-Path $result.AuditPath 'config.ps1')
        $result.Applied | Should -BeTrue
        $result.PartiallyApplied | Should -BeFalse
        $null -eq $result.RecheckFindings | Should -BeFalse -Because 'a clean recheck is @(), not $null'
        $result.RecheckFindings.Count | Should -Be 0
        $script:RecheckCalls.Count | Should -Be 1
        $result.BlueprintVersionCreated | Should -BeNullOrEmpty
        (Get-Content (Join-Path $result.AuditPath 'plan.json') -Raw | ConvertFrom-Json).User | Should -Be 'tester'
        $summary = Get-Content (Join-Path $result.AuditPath 'result.json') -Raw | ConvertFrom-Json
        $summary.Applied | Should -BeTrue
    }

    It 'with -WhatIf generates and saves the audit but calls neither apply nor recheck' {
        $info = $null
        $result = Invoke-PERectify -Plan (New-TestPlan -Kind Create) -Target Replica @Seams -WhatIf -InformationVariable info
        $script:ApplyCalls.Count | Should -Be 0
        $script:RecheckCalls.Count | Should -Be 0
        $result.Applied | Should -BeFalse
        $result.AuditPath | Should -Exist
        Join-Path $result.AuditPath 'config.ps1' | Should -Exist
        Join-Path $result.AuditPath 'plan.json' | Should -Exist
        $result.RecheckFindings | Should -BeNullOrEmpty
        ($info | Out-String) | Should -Match "(?s)Preview \(nothing applied\).*Create AADGroup 'HR'"
    }

    It 'a result with the wrong resource count is not Applied' {
        $script:ApplyResult = New-TestApplyResult -Types @('AADGroup', 'AADGroup')
        $result = Invoke-PERectify -Plan (New-TestPlan -Kind Create) -Target Replica @Seams -WarningAction SilentlyContinue
        $result.Applied | Should -BeFalse
        $result.PartiallyApplied | Should -BeTrue -Because 'rows were Applied, so the tenant changed'
        ($result.Warnings -join ' ') | Should -Match '2 resources for 1 plan items'
        $script:RecheckCalls.Count | Should -Be 0
        $result.RecheckFindings | Should -BeNullOrEmpty
    }

    It 'a result with the wrong resource types is not Applied' {
        $script:ApplyResult = New-TestApplyResult -Types @('AADUser', 'AADGroup')
        $result = Invoke-PERectify -Plan (New-TestPlan -Kind CreateUpdate) -Target Replica @Seams -WarningAction SilentlyContinue
        $result.Applied | Should -BeFalse
        ($result.Warnings -join ' ') | Should -Match 'resource types'
        $script:RecheckCalls.Count | Should -Be 0
    }

    It 'a test-only or NotRun result is not Applied' {
        $script:ApplyResult = New-TestApplyResult -Types @('AADGroup') -Status 'WouldChange'
        $script:ApplyResult.TestOnly = $true
        $result = Invoke-PERectify -Plan (New-TestPlan -Kind Create) -Target Replica @Seams -WarningAction SilentlyContinue
        $result.Applied | Should -BeFalse
        $result.PartiallyApplied | Should -BeFalse
    }

    It 'a failed apply returns Applied false with PartiallyApplied from the tool, keeps the audit folder and skips the recheck' {
        $script:ApplyResult = New-TestApplyResult -Types @('AADGroup', 'AADGroup') -Success $false
        $script:ApplyResult.Resources[1].Status = 'Failed'
        $script:ApplyResult.Resources[1].Error = 'Request_BadRequest: mailNickname'
        $script:ApplyResult.PartiallyApplied = $true
        $script:ApplyResult.Error = 'One or more resources failed: [AADGroup]AADGroup-1'
        $warnings = $null
        $result = Invoke-PERectify -Plan (New-TestPlan -Kind CreateUpdate) -Target Replica @Seams -WarningVariable warnings -WarningAction SilentlyContinue
        $result.Applied | Should -BeFalse
        $result.PartiallyApplied | Should -BeTrue
        $result.AuditPath | Should -Exist
        Join-Path $result.AuditPath 'config.ps1' | Should -Exist
        $result.ApplyResult.Resources[1].Error | Should -Be 'Request_BadRequest: mailNickname'
        $script:RecheckCalls.Count | Should -Be 0
        $result.RecheckFindings | Should -BeNullOrEmpty
        ($warnings -join ' ') | Should -Match 'recheck was skipped'
        (Get-Content (Join-Path $result.AuditPath 'result.json') -Raw | ConvertFrom-Json).Applied | Should -BeFalse
    }

    It 'an apply that throws returns Applied false, PartiallyApplied unknown, and keeps the audit folder' {
        $script:ApplyResult = { throw 'child process crashed' }
        $result = Invoke-PERectify -Plan (New-TestPlan -Kind Create) -Target Replica @Seams -WarningAction SilentlyContinue
        $result.Applied | Should -BeFalse
        $result.PartiallyApplied | Should -BeNullOrEmpty
        $result.AuditPath | Should -Exist
        ($result.Warnings -join ' ') | Should -Match 'child process crashed'
        $script:RecheckCalls.Count | Should -Be 0
    }

    It 'after a successful apply the recheck runs for the same keys and its findings are returned' {
        $plan = @(New-TestPlan -Kind CreateUpdate) + @(New-TestPlan -Kind Remove)
        $script:ApplyResult = New-TestApplyResult -Types @('AADGroup', 'AADGroup', 'AADGroup')
        $finding = [pscustomobject]@{ Kind = 'Changed'; ResourceType = 'AADGroup'; Key = 'Sales'; Differences = @([pscustomobject]@{ Property = 'Description'; Blueprint = 'a'; Target = 'b' }) }
        $script:RecheckResult = @($finding)
        $result = Invoke-PERectify -Plan $plan -Target Replica @Seams -WarningAction SilentlyContinue
        $script:RecheckCalls.Count | Should -Be 1
        $items = $script:RecheckCalls[0]
        @($items | ForEach-Object { "$($_.Action) $($_.ResourceType) $($_.Key)" } | Sort-Object) | Should -Be @('Create AADGroup HR', 'Remove AADGroup DevOnly', 'Update AADGroup Sales')
        ($items | Where-Object Key -EQ 'HR').Record.Properties['Description'] | Should -Be 'People team'
        $result.Applied | Should -BeTrue
        @($result.RecheckFindings).Count | Should -Be 1
        $result.RecheckFindings[0].Key | Should -Be 'Sales'
        $summary = Get-Content (Join-Path $result.AuditPath 'result.json') -Raw
        $summary | Should -Match '"ChangedProperties"'
        $summary | Should -Not -Match '"Blueprint"\s*:\s*"a"' -Because 'result.json keeps property names, not values'
    }

    It 'a recheck that throws does not mask a successful apply' {
        $script:ApplyResult = New-TestApplyResult -Types @('AADGroup')
        $script:RecheckResult = { throw 'Reader export throttled' }
        $result = Invoke-PERectify -Plan (New-TestPlan -Kind Create) -Target Replica @Seams -WarningAction SilentlyContinue
        $result.Applied | Should -BeTrue
        $result.RecheckFindings | Should -BeNullOrEmpty
        ($result.Warnings -join ' ') | Should -Match 'apply succeeded but the recheck failed: Reader export throttled'
    }

    It 'Promote (v1: master = replica, so the apply is a no-op) creates exactly one blueprint version with only the promoted item' {
        $script:ApplyResult = New-TestApplyResult -Types @('AADGroup') -Status 'InDesiredState'
        $result = Invoke-PERectify -Plan (New-TestPlan -Kind Promote) -Target Master -ConfirmMasterWrite -Reason 'built in Dev first' @Seams
        $result.Applied | Should -BeTrue
        $result.BlueprintVersionCreated | Should -Be 2
        $result.Warnings.Count | Should -Be 0
        $script:RecheckCalls.Count | Should -Be 1
        $folder = Join-Path $script:Temp 'blueprints\main'
        @(Get-ChildItem $folder -Filter 'v*.json' | ForEach-Object Name | Sort-Object) | Should -Be @('v0001.json', 'v0002.json')
        $v2 = Get-PEBlueprint -Name 'main' -Version 2 -DataRoot $script:Temp
        @($v2.Records.Key | Sort-Object) | Should -Be @('DevOnly', 'HR', 'Sales')
        ($v2.Records | Where-Object Key -EQ 'DevOnly').Properties.Description | Should -Be 'Built in Dev'
        ($v2.Records | Where-Object Key -EQ 'Sales').Properties.Description | Should -Be 'Sales team'
        $change = Get-Content (Join-Path $folder 'changes\v0002.json') -Raw | ConvertFrom-Json
        $change.Reason | Should -Be 'built in Dev first'
        @($change.Changes).Count | Should -Be 1
        $change.Changes[0].Kind | Should -Be 'Missing'
        $change.Changes[0].Key | Should -Be 'DevOnly'
    }

    It 'Promote records the export time of the plan source as MasterExportedAt in the change record' {
        $script:ApplyResult = New-TestApplyResult -Types @('AADGroup') -Status 'InDesiredState'
        $result = Invoke-PERectify -Plan (New-TestPlan -Kind Promote) -Target Master -ConfirmMasterWrite -Reason 'r' @Seams
        $result.BlueprintVersionCreated | Should -Be 2
        $change = Get-Content (Join-Path $script:Temp 'blueprints\main\changes\v0002.json') -Raw | ConvertFrom-Json -DateKind String
        $change.MasterExportedAt | Should -Be '2026-10-21T10:00:00Z'
    }

    It 'a blueprint written before Meta.Version existed (no Meta.Version in v0001) still counts as version 1 for Rectify' {
        $file = Join-Path $script:Temp 'blueprints\main\v0001.json'
        $document = Get-Content $file -Raw | ConvertFrom-Json -Depth 20
        $document.Meta.PSObject.Properties.Remove('Version')
        $document | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $file -Encoding utf8
        $legacy = Get-PEBlueprint -Name 'main' -DataRoot $script:Temp
        $legacy.Meta.Keys | Should -Not -Contain 'Version'
        $script:PlanArgs = @{ Source = $script:Target; Blueprint = $legacy }
        $plan = New-TestPlan -Kind Create
        $plan[0].SourceIdentity.BlueprintVersion | Should -BeNullOrEmpty
        $script:ApplyResult = New-TestApplyResult -Types @('AADGroup')
        $result = Invoke-PERectify -Plan $plan -Target Replica @Seams
        $result.Applied | Should -BeTrue
    }

    It 'a blueprint written now has Meta.Version 1 and the plan records version 1' {
        $script:Blueprint.Meta.Version | Should -Be 1
        (New-TestPlan -Kind Create)[0].SourceIdentity.BlueprintVersion | Should -Be 1
    }
    It 'Promote with a recheck finding does not update the blueprint and warns' {
        $script:ApplyResult = New-TestApplyResult -Types @('AADGroup') -Status 'InDesiredState'
        $script:RecheckResult = @([pscustomobject]@{ Kind = 'Changed'; ResourceType = 'AADGroup'; Key = 'DevOnly'; Differences = @() })
        $result = Invoke-PERectify -Plan (New-TestPlan -Kind Promote) -Target Master -ConfirmMasterWrite -Reason 'r' @Seams -WarningAction SilentlyContinue
        $result.Applied | Should -BeTrue
        $result.BlueprintVersionCreated | Should -BeNullOrEmpty
        ($result.Warnings -join ' ') | Should -Match 'out of step'
        @(Get-ChildItem (Join-Path $script:Temp 'blueprints\main') -Filter 'v*.json').Count | Should -Be 1
    }

    It 'a failed blueprint update after Promote keeps Applied true and warns that master and blueprint are out of step' {
        Mock -ModuleName PolicyEngine Approve-PEBlueprintChange { throw 'disk full' }
        $script:ApplyResult = New-TestApplyResult -Types @('AADGroup') -Status 'InDesiredState'
        $result = Invoke-PERectify -Plan (New-TestPlan -Kind Promote) -Target Master -ConfirmMasterWrite -Reason 'r' @Seams -WarningAction SilentlyContinue
        $result.Applied | Should -BeTrue
        $result.BlueprintVersionCreated | Should -BeNullOrEmpty
        ($result.Warnings -join ' ') | Should -Match "master and the blueprint are now out of step for: AADGroup 'DevOnly'.*disk full.*Approve-PEBlueprintChange"
        $result.AuditPath | Should -Exist
    }

    It 'returns no thumbprint or application id, in the result, the warnings or result.json' {
        $script:ApplyResult = New-TestApplyResult -Types @('AADGroup') -Success $false
        $script:ApplyResult.Resources[0].Status = 'Failed'
        $script:ApplyResult.Resources[0].Error = "Certificate $($script:FakeThumb.ToLowerInvariant()) for app $($script:FakeAppId) was rejected"
        $script:ApplyResult.Error = "One or more resources failed (app $($script:FakeAppId.ToUpperInvariant()))"
        $result = Invoke-PERectify -Plan (New-TestPlan -Kind Create) -Target Replica @Seams -WarningAction SilentlyContinue
        $files = @(Get-ChildItem $result.AuditPath -File | ForEach-Object { Get-Content $_.FullName -Raw })
        $files.Count | Should -Be 5 -Because 'plan.json, config.ps1, who.txt, apply-started.txt and result.json'
        $text = (@($result | ConvertTo-Json -Depth 12) + $files) -join "`n"
        $text | Should -Not -Match $script:FakeThumb
        $text | Should -Not -Match $script:FakeAppId
        $text | Should -Match '<redacted>'

        $script:ApplyResult = New-TestApplyResult -Types @('AADGroup')
        $script:RecheckResult = { throw "export as $($script:FakeAppId) with $($script:FakeThumb) failed" }
        $result = Invoke-PERectify -Plan (New-TestPlan -Kind Create) -Target Replica @Seams -WarningAction SilentlyContinue
        ($result | ConvertTo-Json -Depth 12) | Should -Not -Match "$($script:FakeThumb)|$($script:FakeAppId)"
    }
    It 'a plan is single-use: a second real apply throws, while -WhatIf and failed preconditions do not consume it' {
        $plan = New-TestPlan -Kind Create
        $script:ApplyResult = New-TestApplyResult -Types @('AADGroup')
        (Invoke-PERectify -Plan $plan -Target Replica @Seams -WhatIf -InformationAction SilentlyContinue).Applied | Should -BeFalse
        { Invoke-PERectify -Plan $plan -Target Master @Seams } | Should -Throw '*ConfirmMasterWrite*'
        (Invoke-PERectify -Plan $plan -Target Replica @Seams).Applied | Should -BeTrue
        $script:ApplyCalls.Count | Should -Be 1
        { Invoke-PERectify -Plan $plan -Target Replica @Seams } | Should -Throw '*plan already applied; make a new plan*'
        { ConvertTo-PEDscConfig -Plan $plan -ConfigurationName 'C' -Target Replica } | Should -Throw '*not produced by New-PERectifyPlan*'
        $script:ApplyCalls.Count | Should -Be 1
        (Invoke-PERectify -Plan (New-TestPlan -Kind Create) -Target Replica @Seams).Applied | Should -BeTrue -Because 'a new plan for the same finding is fine'
    }

    It 'a plan is consumed even when the apply fails' {
        $plan = New-TestPlan -Kind Create
        $script:ApplyResult = { throw 'boom' }
        (Invoke-PERectify -Plan $plan -Target Replica @Seams -WarningAction SilentlyContinue).Applied | Should -BeFalse
        { Invoke-PERectify -Plan $plan -Target Replica @Seams } | Should -Throw '*plan already applied*'
    }

    It 'refuses to launch when the saved config.ps1 was changed after the audit was written' {
        $plan = New-TestPlan -Kind Create
        $script:ApplyResult = New-TestApplyResult -Types @('AADGroup')
        # Get-PERectifyRedaction runs right after Save-PEAudit: tamper with the saved file there.
        Mock -ModuleName PolicyEngine Get-PERectifyRedaction {
            $folder = Get-ChildItem (Join-Path $script:Temp 'audit') -Directory | Select-Object -First 1
            Add-Content -LiteralPath (Join-Path $folder.FullName 'config.ps1') -Value '# appended'
            , [string[]]@()
        }
        { Invoke-PERectify -Plan $plan -Target Replica @Seams } | Should -Throw '*does not match plan.json*nothing was applied*'
        $script:ApplyCalls.Count | Should -Be 0
        $folder = (Get-TestAuditFolders)[0].FullName
        Join-Path $folder 'apply-started.txt' | Should -Not -Exist
        Mock -ModuleName PolicyEngine Get-PERectifyRedaction { , [string[]]@() }
        (Invoke-PERectify -Plan $plan -Target Replica @Seams).Applied | Should -BeTrue -Because 'the refused run did not consume the plan'
    }

    It 'writes an apply-started marker before a real apply, and result.json tells a preview from a real run' {
        $script:ApplyResult = New-TestApplyResult -Types @('AADGroup')
        $preview = Invoke-PERectify -Plan (New-TestPlan -Kind Create) -Target Replica @Seams -WhatIf -InformationAction SilentlyContinue
        Join-Path $preview.AuditPath 'apply-started.txt' | Should -Not -Exist
        (Get-Content (Join-Path $preview.AuditPath 'result.json') -Raw | ConvertFrom-Json).Preview | Should -BeTrue
        $script:ApplyResult = {
            $folder = Split-Path -Parent $script:ApplyCalls[-1].ConfigPath
            $script:MarkerSeen = Test-Path -LiteralPath (Join-Path $folder 'apply-started.txt')
            New-TestApplyResult -Types @('AADGroup')
        }
        $real = Invoke-PERectify -Plan (New-TestPlan -Kind Create) -Target Replica @Seams
        $script:MarkerSeen | Should -BeTrue
        (Get-Content (Join-Path $real.AuditPath 'result.json') -Raw | ConvertFrom-Json).Preview | Should -BeFalse
    }

    It 'a failure while processing the apply result becomes Applied false with a warning, never a throw' {
        Mock -ModuleName PolicyEngine Test-PERectifyApplyResult { throw 'unexpected shape' }
        $script:ApplyResult = New-TestApplyResult -Types @('AADGroup')
        $result = Invoke-PERectify -Plan (New-TestPlan -Kind Create) -Target Replica @Seams -WarningAction SilentlyContinue
        $result.Applied | Should -BeFalse
        $result.PartiallyApplied | Should -BeNullOrEmpty
        ($result.Warnings -join ' ') | Should -Match 'could not be processed: unexpected shape'
        Join-Path $result.AuditPath 'result.json' | Should -Exist
        $script:RecheckCalls.Count | Should -Be 0
    }
    It 'with -WarningAction Stop a failed apply still returns its result and writes result.json' {
        $script:ApplyResult = { throw 'boom' }
        $result = Invoke-PERectify -Plan (New-TestPlan -Kind Create) -Target Replica @Seams -WarningAction Stop
        $result.Applied | Should -BeFalse
        ($result.Warnings -join ' ') | Should -Match 'boom'
        (Get-Content (Join-Path $result.AuditPath 'result.json') -Raw | ConvertFrom-Json).Applied | Should -BeFalse
    }

    It 'when consuming the plan fails, the apply-started marker is removed and nothing runs' {
        Mock -ModuleName PolicyEngine Complete-PERectifyPlanUse { throw 'registry broken' }
        $script:ApplyResult = New-TestApplyResult -Types @('AADGroup')
        { Invoke-PERectify -Plan (New-TestPlan -Kind Create) -Target Replica @Seams } | Should -Throw '*nothing was applied*registry broken*'
        $script:ApplyCalls.Count | Should -Be 0
        Join-Path (Get-TestAuditFolders)[0].FullName 'apply-started.txt' | Should -Not -Exist
    }

    It 'a result without a known outcome is reported as an UNKNOWN apply state' {
        $script:ApplyResult = [pscustomobject]@{ Success = $false; PartiallyApplied = $null; Error = 'ended without a result'; Resources = @(); StdErr = '{"error":"graph"}' }
        $result = Invoke-PERectify -Plan (New-TestPlan -Kind Create) -Target Replica @Seams -WarningAction SilentlyContinue
        $result.Applied | Should -BeFalse
        $result.PartiallyApplied | Should -BeNullOrEmpty
        ($result.Warnings -join ' ') | Should -Match 'APPLY STATE UNKNOWN'
        ($result.Warnings -join ' ') | Should -Match 'stderr: \{"error":"graph"\}'
    }
}

Describe 'Invoke-PERectifyRecheck (the default recheck)' {
    BeforeAll {
        function New-ExportText
        {
            # A Microsoft365DSC-shaped export holding the given AADGroup records.
            param ([object[]]$Groups)

            $blocks = foreach ($group in $Groups)
            {
                $p = $group.Properties
                @"
        AADGroup "AADGroup-$([guid]::NewGuid().ToString('N'))"
        {
            ApplicationId         = `$ConfigurationData.NonNodeData.ApplicationId;
            CertificateThumbprint = `$ConfigurationData.NonNodeData.CertificateThumbprint;
            Description           = "$($p.Description)";
            DisplayName           = "$($p.DisplayName)";
            Ensure                = "Present";
            Id                    = "$([guid]::NewGuid())";
            MailEnabled           = `$False;
            MailNickname          = "$($p.MailNickname)";
            SecurityEnabled       = `$True;
            TenantId              = `$ConfigurationData.NonNodeData.TenantId;
        }
"@
            }
            @"
Configuration delta-export
{
    Import-DscResource -ModuleName 'Microsoft365DSC' -ModuleVersion '2.26.1021.1'
    Node localhost
    {
$($blocks -join "`n")
    }
}
"@
        }

        function New-ExportLogText
        {
            param ([string[]]$Names)

            $check = [string][char]0x2705
            if ($Names.Count -eq 0)
            {
                return "[1/1] Extracting [AADGroup] using {CertificateThumbprint}...$check`r`n"
            }
            $lines = @('[1/1] Extracting [AADGroup] using {CertificateThumbprint}...')
            for ($i = 1; $i -le $Names.Count; $i++)
            {
                $line = "    |---[$i/$($Names.Count)] $($Names[$i - 1])"
                if ($i -eq $Names.Count) { $line += $check }
                $lines += $line
            }
            return ($lines -join "`r`n") + "`r`n"
        }

        function New-TestItem
        {
            param ([string]$Action, $Record)

            [pscustomobject]@{ Action = $Action; ResourceType = $Record.ResourceType; Key = $Record.Key; Workload = 'Entra ID'; Record = $Record }
        }
    }

    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-recheck-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Temp | Out-Null
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        # What the (fake) tenant holds now.
        $script:Tenant = @(
            (New-TestGroup -Name 'Sales' -Description 'Sales team'),
            (New-TestGroup -Name 'HR' -Description 'People team (drifted)'),
            (New-TestGroup -Name 'Leftover' -Description 'x')
        )
        $script:Fake = {
            param ([string[]]$Components, [hashtable]$Filters, [string]$OutputPath)
            $script:Calls.Add([pscustomobject]@{ Components = $Components; Filters = $Filters })
            $groups = @($script:Tenant)
            if ($Filters.Count -gt 0)
            {
                $name = ([regex]::Match($Filters['AADGroup'], "eq '(.*)'$")).Groups[1].Value.Replace("''", "'")
                $groups = @($groups | Where-Object Key -EQ $name)
            }
            New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $OutputPath 'export.ps1'), (New-ExportText -Groups $groups))
            [System.IO.File]::WriteAllText((Join-Path $OutputPath 'export.log'), (New-ExportLogText -Names @($groups.Key)))
            $OutputPath
        }
        Mock -ModuleName PolicyEngine Test-PEResourceFilterSupport {
            $map = [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($t in $ResourceType) { $map[$t] = $true }
            return , $map
        }
    }

    AfterEach {
        Remove-Item $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Remove items are rechecked with a whole-type export (no filter); a key still present is a finding' {
        $items = @(
            (New-TestItem -Action Remove -Record (New-TestGroup -Name 'Leftover' -Description 'x')),
            (New-TestItem -Action Remove -Record (New-TestGroup -Name 'Gone' -Description 'x'))
        )
        $findings = InModuleScope PolicyEngine -Parameters @{ I = $items; E = $script:Fake; D = $script:Temp } {
            param ($I, $E, $D)
            @(Invoke-PERectifyRecheck -Items $I -ExportScript $E -DataRoot $D)
        }
        $script:Calls.Count | Should -Be 1
        $script:Calls[0].Filters.Count | Should -Be 0
        Should -Invoke -ModuleName PolicyEngine Test-PEResourceFilterSupport -Times 0 -Exactly
        @($findings).Count | Should -Be 1
        $findings[0].Kind | Should -Be 'TargetOnly'
        $findings[0].Key | Should -Be 'Leftover'
    }

    It 'Create, Update and Promote items are re-exported by key and compared with the planned record' {
        $items = @(
            (New-TestItem -Action Update -Record (New-TestGroup -Name 'Sales' -Description 'Sales team')),
            (New-TestItem -Action Create -Record (New-TestGroup -Name 'HR' -Description 'People team'))
        )
        $findings = InModuleScope PolicyEngine -Parameters @{ I = $items; E = $script:Fake; D = $script:Temp } {
            param ($I, $E, $D)
            @(Invoke-PERectifyRecheck -Items $I -ExportScript $E -DataRoot $D)
        }
        $script:Calls.Count | Should -Be 2
        @($script:Calls | ForEach-Object { $_.Filters['AADGroup'] } | Sort-Object) | Should -Be @("DisplayName eq 'HR'", "DisplayName eq 'Sales'")
        @($findings).Count | Should -Be 1
        $findings[0].Kind | Should -Be 'Changed'
        $findings[0].Key | Should -Be 'HR'
        @($findings[0].Differences.Property) | Should -Be @('Description')
    }

    It 'a clean recheck returns no findings' {
        $items = @(New-TestItem -Action Update -Record (New-TestGroup -Name 'Sales' -Description 'Sales team'))
        $findings = InModuleScope PolicyEngine -Parameters @{ I = $items; E = $script:Fake; D = $script:Temp } {
            param ($I, $E, $D)
            @(Invoke-PERectifyRecheck -Items $I -ExportScript $E -DataRoot $D)
        }
        @($findings).Count | Should -Be 0
    }
    It 'compares the planned types even when Data\ExcludedTypes.psd1 lists them' {
        $planned = [pscustomobject]@{ ResourceType = 'EXOMailboxSettings'; Key = 'm1'; Workload = 'Exchange Online'; Properties = [ordered]@{ Identity = 'm1'; TimeZone = 'A' } }
        Mock -ModuleName PolicyEngine Export-PEDelta {
            [pscustomobject]@{
                Records    = @([pscustomobject]@{ ResourceType = 'EXOMailboxSettings'; Key = 'm1'; Workload = 'Exchange Online'; Properties = [ordered]@{ Identity = 'm1'; TimeZone = 'B' } })
                NotChecked = @()
                Meta       = @{}
            }
        }
        $items = @([pscustomobject]@{ Action = 'Update'; ResourceType = 'EXOMailboxSettings'; Key = 'm1'; Workload = 'Exchange Online'; Record = $planned })
        $findings = InModuleScope PolicyEngine -Parameters @{ I = $items; D = $script:Temp } {
            param ($I, $D)
            @(Invoke-PERectifyRecheck -Items $I -DataRoot $D)
        }
        @($findings).Count | Should -Be 1
        $findings[0].Kind | Should -Be 'Changed'
        @($findings[0].Differences.Property) | Should -Be @('TimeZone')
    }

    It 'applies the accepted-noise decisions of the data root, as a check would' {
        Set-PEDecision -Kind Noise -ResourceType AADGroup -Key 'HR' -Property 'Description' -Value 'People team (drifted)' -Reason 'test' -DataRoot $script:Temp | Out-Null
        $items = @(New-TestItem -Action Create -Record (New-TestGroup -Name 'HR' -Description 'People team'))
        $findings = InModuleScope PolicyEngine -Parameters @{ I = $items; E = $script:Fake; D = $script:Temp } {
            param ($I, $E, $D)
            @(Invoke-PERectifyRecheck -Items $I -ExportScript $E -DataRoot $D)
        }
        @($findings).Count | Should -Be 0
    }
}

Describe 'ConvertFrom-PEApplyToolOutput' {
    It 'takes the last JSON line after warning lines (exit code 0)' {
        $json = '{"Success":true,"PartiallyApplied":false,"Resources":[{"ResourceId":"[AADGroup]G","ResourceType":"AADGroup","Status":"Applied"}]}'
        $result = InModuleScope PolicyEngine -Parameters @{ L = @('WARNING: something', '{"not":"this"}', $json, '') } {
            param ($L)
            ConvertFrom-PEApplyToolOutput -Lines $L -ExitCode 0
        }
        $result.Success | Should -BeTrue
        $result.Resources[0].Status | Should -Be 'Applied'
    }

    It 'a guard error (exit code 1, no JSON) is a failure with nothing applied' {
        $result = InModuleScope PolicyEngine { ConvertFrom-PEApplyToolOutput -Lines @('OutputPath is inside the repository') -ExitCode 1 }
        $result.Success | Should -BeFalse
        $result.PartiallyApplied | Should -BeFalse
        $result.Error | Should -Match 'exit code 1.*inside the repository'
    }

    It 'no JSON with another exit code leaves PartiallyApplied unknown' {
        $result = InModuleScope PolicyEngine { ConvertFrom-PEApplyToolOutput -Lines @() -ExitCode -1 }
        $result.Success | Should -BeFalse
        $result.PartiallyApplied | Should -BeNullOrEmpty
    }

    It 'JSON on stderr after the real stdout JSON never replaces the result' {
        $real = '{"Success":false,"PartiallyApplied":true,"Error":"One or more resources failed","Resources":[{"ResourceType":"AADGroup","Status":"Applied"},{"ResourceType":"AADGroup","Status":"Failed"}]}'
        $fake = '{"Success":false,"PartiallyApplied":false,"Resources":[],"error":{"code":"Request_BadRequest"}}'
        $result = InModuleScope PolicyEngine -Parameters @{ O = @('WARNING: a', $real); E = @($fake, '{') } {
            param ($O, $E)
            ConvertFrom-PEApplyToolOutput -Lines $O -ErrorLines $E -ExitCode 2
        }
        $result.PartiallyApplied | Should -BeTrue
        @($result.Resources).Count | Should -Be 2
        $result.StdErr | Should -Match 'Request_BadRequest'
    }

    It 'a pretty-printed ''{'' line on stdout after the result is skipped; the last real result line wins' {
        $real = '{"Success":true,"PartiallyApplied":false,"Error":null,"Resources":[{"ResourceType":"AADGroup","Status":"Applied"}]}'
        $result = InModuleScope PolicyEngine -Parameters @{ O = @('WARNING: one', $real, 'WARNING: two', '{', '  "error": "x"', '}') } {
            param ($O)
            ConvertFrom-PEApplyToolOutput -Lines $O -ExitCode 0
        }
        $result.Success | Should -BeTrue
        $result.Resources[0].Status | Should -Be 'Applied'
    }

    It 'stdout with warnings interleaved and a JSON object without the result fields is not taken' {
        $real = '{"Success":true,"PartiallyApplied":false,"Error":null,"Resources":[]}'
        $result = InModuleScope PolicyEngine -Parameters @{ O = @('WARNING: a', $real, 'WARNING: b', '{"code":"x"}') } {
            param ($O)
            ConvertFrom-PEApplyToolOutput -Lines $O -ExitCode 0
        }
        $result.Success | Should -BeTrue
        $result.PSObject.Properties['code'] | Should -BeNullOrEmpty
    }

    It 'no result with exit code 2 (or 0) is an UNKNOWN apply state; exit code 1 means nothing ran' {
        foreach ($code in 2, 0)
        {
            $result = InModuleScope PolicyEngine -Parameters @{ C = $code } { param ($C) ConvertFrom-PEApplyToolOutput -Lines @('WARNING: x') -ErrorLines @('{"error":"graph"}') -ExitCode $C }
            $result.Success | Should -BeFalse
            $result.PartiallyApplied | Should -BeNullOrEmpty
            $result.Error | Should -Match 'UNKNOWN'
            $result.StdErr | Should -Match 'graph'
        }
        $result = InModuleScope PolicyEngine { ConvertFrom-PEApplyToolOutput -Lines @() -ErrorLines @('guard: OutputPath inside the repository') -ExitCode 1 }
        $result.PartiallyApplied | Should -BeFalse
        $result.Error | Should -Match 'refused before applying anything'
    }
    It 'a JSON result that disagrees with the exit code is a failure' {
        $result = InModuleScope PolicyEngine { ConvertFrom-PEApplyToolOutput -Lines @('{"Success":true,"Error":null,"Resources":[]}') -ExitCode 2 }
        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'exited with code 2'
    }
}

Describe 'Invoke-PERectify with the default apply (child process mocked)' -Tag 'Slow' {
    BeforeEach {
        Initialize-TestData
        Mock -ModuleName PolicyEngine Get-PERectifyRedaction { , [string[]]@() }
        Mock -ModuleName PolicyEngine Get-PERectifyWriterApp { [pscustomobject]@{ Role = 'Writer'; TenantId = 'dev.onmicrosoft.com'; ApplicationId = 'a'; Thumbprint = 'b' } }
        Mock -ModuleName PolicyEngine Invoke-PERectifyRecheck { throw 'safety net: the real recheck must not run in tests' }
    }

    AfterEach {
        Remove-Item $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'a timed-out apply is Applied false, PartiallyApplied unknown, with a prominent warning and result.json' {
        Mock -ModuleName PolicyEngine Invoke-PEChildProcess {
            $script:ChildCall = [pscustomobject]@{ FilePath = $FilePath; ArgumentList = $ArgumentList; TimeoutSeconds = $TimeoutSeconds }
            [pscustomobject]@{ ProcessId = 1; ExitCode = $null; StdOut = [string[]]@(); StdErr = [string[]]@(); TimedOut = $true }
        }
        $result = Invoke-PERectify -Plan (New-TestPlan -Kind Create) -Target Replica -BlueprintName 'main' -DataRoot $script:Temp -WarningAction SilentlyContinue
        $script:ChildCall.TimeoutSeconds | Should -Be ((10 + 3 * 1) * 60)
        $script:ChildCall.FilePath | Should -Be (Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }))
        @($script:ChildCall.ArgumentList) | Should -Contain '-Json'
        $i = [array]::IndexOf([string[]]$script:ChildCall.ArgumentList, '-Role')
        $script:ChildCall.ArgumentList[$i + 1] | Should -Be 'Writer'
        $result.Applied | Should -BeFalse
        $result.PartiallyApplied | Should -BeNullOrEmpty
        $result.ApplyResult.TimedOut | Should -BeTrue
        ($result.Warnings -join ' ') | Should -Match "APPLY STATE UNKNOWN.*13 minutes.*$([regex]::Escape($result.AuditPath))"
        (Get-Content (Join-Path $result.AuditPath 'result.json') -Raw | ConvertFrom-Json).Applied | Should -BeFalse
    }

    It '-ApplyTimeoutMinutes overrides the default and the tool output is parsed from the last JSON line' {
        Mock -ModuleName PolicyEngine Invoke-PEChildProcess {
            $script:ChildCall = [pscustomobject]@{ TimeoutSeconds = $TimeoutSeconds }
            $json = '{"Success":true,"TestOnly":false,"PartiallyApplied":false,"Error":null,"Resources":[{"ResourceId":"[AADGroup]AADGroup-HR","ResourceType":"AADGroup","Status":"Applied"}]}'
            [pscustomobject]@{ ProcessId = 1; ExitCode = 0; StdOut = [string[]]@('WARNING: x', $json); StdErr = [string[]]@(); TimedOut = $false }
        }
        $result = Invoke-PERectify -Plan (New-TestPlan -Kind Create) -Target Replica -BlueprintName 'main' -DataRoot $script:Temp -ApplyTimeoutMinutes 2 -RecheckScript { param ($Items) @() }
        $script:ChildCall.TimeoutSeconds | Should -Be 120
        $result.Applied | Should -BeTrue
    }
}

Describe 'Invoke-PEChildProcess' {
    It 'kills a child that outlives the timeout (process tree) and reports TimedOut' {
        $pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $run = InModuleScope PolicyEngine -Parameters @{ P = $pwsh } {
            param ($P)
            Invoke-PEChildProcess -FilePath $P -ArgumentList @('-NoProfile', '-Command', 'Write-Output started; Start-Sleep 600') -TimeoutSeconds 1
        }
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 60
        $run.TimedOut | Should -BeTrue
        $run.ExitCode | Should -BeNullOrEmpty
        Get-Process -Id $run.ProcessId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'returns the exit code and the output lines of a child that finishes' {
        $pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
        $run = InModuleScope PolicyEngine -Parameters @{ P = $pwsh } {
            param ($P)
            Invoke-PEChildProcess -FilePath $P -ArgumentList @('-NoProfile', '-Command', "Write-Output 'a b'; [Console]::Error.WriteLine('err'); Write-Output '{`"x`":1}'; exit 2") -TimeoutSeconds 120
        }
        $run.TimedOut | Should -BeFalse
        $run.ExitCode | Should -Be 2
        $run.StdOut | Should -Contain 'a b'
        $run.StdOut | Should -Contain '{"x":1}'
        $run.StdOut | Should -Not -Contain 'err'
        $run.StdErr | Should -Contain 'err'
    }
}