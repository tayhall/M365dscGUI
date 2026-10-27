BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    Import-Module DSCParser -RequiredVersion 3.1.0.7 -ErrorAction Stop

    function New-TestGroup
    {
        param
        (
            [string]$Name,
            [string]$Description = "About $Name",
            [System.Collections.IDictionary]$Extra = @{}
        )

        $props = [ordered]@{
            DisplayName     = $Name
            MailNickname    = ($Name -replace '[^A-Za-z0-9]', '').ToLowerInvariant() + 'nick'
            SecurityEnabled = $true
            MailEnabled     = $false
            Description     = $Description
            Ensure          = 'Present'
        }
        foreach ($extraName in $Extra.get_Keys())
        {
            $props[$extraName] = $Extra[$extraName]
        }
        [pscustomobject]@{
            ResourceType = 'AADGroup'
            Key          = $Name
            Workload     = 'Entra ID'
            Properties   = $props
        }
    }

    function New-TestState
    {
        param
        (
            [object[]]$Records = @(),
            [object[]]$NotChecked = @(),
            [string]$Source = 'full check',
            [hashtable]$Meta = @{ TenantId = 'dev.onmicrosoft.com'; ExportedAt = '2026-10-21T10:00:00Z' }
        )

        $m = @{}
        foreach ($k in $Meta.Keys)
        {
            $m[$k] = $Meta[$k]
        }
        if ($Source)
        {
            $m['Source'] = $Source
        }
        & (Get-Module PolicyEngine) {
            param ($r, $n, $mm)
            New-PEState -Records $r -NotChecked $n -Meta $mm
        } $Records $NotChecked $m
    }

    function New-TestRemoveDecision
    {
        param
        (
            [string]$Key,
            [string]$Type = 'AADGroup'
        )

        [pscustomobject]@{ Kind = 'Remove'; ResourceType = $Type; Key = $Key; Property = $null; Value = $null; Reason = 'test'; At = '2026-10-21T00:00:00.000Z' }
    }

    function New-TestFinding
    {
        # A hand-built finding for kinds Compare-PEState produces only in special situations.
        param
        (
            [string]$Kind,
            [string]$Key = 'X',
            [string]$Type = 'AADGroup',
            $BlueprintRecord = $null,
            $TargetRecord = $null,
            [string]$Hint = $null,
            [string]$State = 'Open'
        )

        [pscustomobject]@{
            Kind = $Kind; ResourceType = $Type; Key = $Key; Workload = 'Entra ID'; Differences = @(); Hint = $Hint; State = $State
            BlueprintRecord = $BlueprintRecord; TargetRecord = $TargetRecord; BlueprintCount = $null; TargetCount = $null
        }
    }

    function New-TestItem
    {
        # A plan item registered as if New-PERectifyPlan had produced it (for rendering tests with unusual records).
        param
        (
            [string]$Action = 'Create',
            $Record,
            [string]$Key = $Record.Key
        )

        $item = [pscustomobject]@{
            Action = $Action; ResourceType = $Record.ResourceType; Key = $Key; Workload = 'Entra ID'; Record = $Record
            Finding = $null; ConfirmNotRenamed = $false; SourceIdentity = $null
        }
        InModuleScope PolicyEngine -Parameters @{ Item = $item } { param ($Item) Register-PEPlanItem -Item $Item }
        $item
    }

    function Get-TestStrict
    {
        param ($Value)

        InModuleScope PolicyEngine -Parameters @{ V = $Value } { param ($V) ConvertTo-PEStrictText $V }
    }

    function Resolve-TestDscValue
    {
        # DSCParser returns a concatenation expression ('a' + [char]0x00D1 + $OrganizationName) as its text; evaluate it
        # the way configuration compilation does, with the placeholder standing for itself. Test-only.
        param ([string]$Text)

        if ($Text -notlike '(*)')
        {
            return $Text
        }
        $OrganizationName = '$OrganizationName'
        return [string](Invoke-Expression $Text)
    }

    function Get-ParseErrorCount
    {
        param ([string]$Text)

        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
        return @($errors).Count
    }

    # Blueprint (current, version 3): Sales, Finance, HR. Target: Sales (changed description), Finance (same), DevOnly.
    $script:Blueprint = New-TestState -Source $null -Meta @{ Version = 3; ExportedAt = '2026-10-20T08:00:00Z'; TenantId = 'prod.onmicrosoft.com' } -Records @(
        (New-TestGroup -Name 'Sales' -Description 'Sales team'),
        (New-TestGroup -Name 'Finance' -Description 'Finance team'),
        (New-TestGroup -Name 'HR' -Description 'People team')
    )
    $script:Target = New-TestState -Records @(
        (New-TestGroup -Name 'Sales' -Description 'Sales team (edited)'),
        (New-TestGroup -Name 'Finance' -Description 'Finance team'),
        (New-TestGroup -Name 'DevOnly' -Description 'Built in Dev')
    )
    $script:Findings = @(Compare-PEState -Blueprint $script:Blueprint -Target $script:Target)
    $script:Missing = $script:Findings | Where-Object Kind -eq 'Missing'
    $script:Changed = $script:Findings | Where-Object Kind -eq 'Changed'
    $script:TargetOnly = $script:Findings | Where-Object Kind -eq 'TargetOnly'
    $script:PlanArgs = @{ Source = $script:Target; Blueprint = $script:Blueprint }
}

Describe 'New-PERectifyPlan' {
    It 'the fixture yields one Missing, one Changed and one TargetOnly finding' {
        @($script:Missing).Count | Should -Be 1
        @($script:Changed).Count | Should -Be 1
        @($script:TargetOnly).Count | Should -Be 1
    }

    It 'Create is refused for a Changed finding' {
        { New-PERectifyPlan -Findings $script:Changed -Action Create @PlanArgs } | Should -Throw '*Create*Changed*'
    }

    It 'Remove is refused without a Remove decision' {
        { New-PERectifyPlan -Findings $script:TargetOnly -Action Remove @PlanArgs } | Should -Throw '*Remove decision*'
        { New-PERectifyPlan -Findings $script:TargetOnly -Action Remove @PlanArgs -Decisions @(New-TestRemoveDecision -Key 'Other') } | Should -Throw '*Remove decision*'
    }

    It 'Remove for an Ambiguous finding throws' {
        $t = New-TestState -Records @((New-TestGroup -Name 'Dup'), (New-TestGroup -Name 'dup'))
        $f = @(Compare-PEState -Blueprint (New-TestState) -Target $t)
        $f[0].Kind | Should -Be 'Ambiguous'
        { New-PERectifyPlan -Findings $f -Action Remove -Source $t -Blueprint (New-TestState) -Decisions @(New-TestRemoveDecision -Key 'Dup') } | Should -Throw '*Ambiguous*'
    }

    It '<Action> is refused for a <Kind> finding' -TestCases @(
        foreach ($action in 'Create', 'Update', 'Remove', 'Promote')
        {
            foreach ($kind in 'Ambiguous', 'NotChecked', 'NotAvailable', 'Excluded', 'Unkeyed', 'Unreadable')
            {
                @{ Action = $action; Kind = $kind }
            }
        }
    ) {
        param ($Action, $Kind)
        $record = New-TestGroup -Name 'X'
        $finding = New-TestFinding -Kind $Kind -BlueprintRecord $record -TargetRecord $record
        { New-PERectifyPlan -Findings @($finding) -Action $Action -Source (New-TestState -Records @($record)) -Blueprint (New-TestState -Records @($record)) -Decisions @(New-TestRemoveDecision -Key 'X') -ConfirmNotRenamed } |
            Should -Throw "*$Kind*"
    }

    It 'an unknown finding Kind is refused' {
        $finding = New-TestFinding -Kind 'Weird' -TargetRecord (New-TestGroup -Name 'X')
        { New-PERectifyPlan -Findings @($finding) -Action Promote @PlanArgs } | Should -Throw '*Weird*'
    }

    It 'Create plans a Missing finding with the blueprint record' {
        $plan = @(New-PERectifyPlan -Findings $script:Missing -Action Create @PlanArgs)
        $plan.Count | Should -Be 1
        $plan[0].Action | Should -Be 'Create'
        $plan[0].ResourceType | Should -Be 'AADGroup'
        $plan[0].Key | Should -Be 'HR'
        $plan[0].Workload | Should -Be 'Entra ID'
        Get-TestStrict $plan[0].Record.Properties | Should -BeExactly (Get-TestStrict $script:Missing.BlueprintRecord.Properties)
        $plan[0].Record | Should -Not -Be $script:Missing.BlueprintRecord
        $plan[0].Finding | Should -Be $script:Missing
        $plan[0].ConfirmNotRenamed | Should -BeFalse
    }

    It 'Update plans a Changed finding with the blueprint record as desired state' {
        $plan = @(New-PERectifyPlan -Findings $script:Changed -Action Update @PlanArgs)
        $plan[0].Action | Should -Be 'Update'
        $plan[0].Record.Properties['Description'] | Should -Be 'Sales team'
    }

    It 'Remove plans a TargetOnly finding with a Remove decision (case-insensitive) and the target record' {
        $plan = @(New-PERectifyPlan -Findings $script:TargetOnly -Action Remove @PlanArgs -Decisions @(New-TestRemoveDecision -Key 'devonly' -Type 'aadgroup'))
        $plan[0].Action | Should -Be 'Remove'
        Get-TestStrict $plan[0].Record.Properties | Should -BeExactly (Get-TestStrict $script:TargetOnly.TargetRecord.Properties)
    }

    It 'Promote plans a TargetOnly finding with the target record and needs no decision' {
        $plan = @(New-PERectifyPlan -Findings $script:TargetOnly -Action Promote @PlanArgs)
        $plan[0].Action | Should -Be 'Promote'
        $plan[0].Record.Properties['Description'] | Should -Be 'Built in Dev'
    }

    It '<Action> is refused for a <Kind> finding (wrong kind for the action)' -TestCases @(
        @{ Action = 'Update'; Kind = 'Missing' }
        @{ Action = 'Remove'; Kind = 'Missing' }
        @{ Action = 'Promote'; Kind = 'Missing' }
        @{ Action = 'Create'; Kind = 'TargetOnly' }
        @{ Action = 'Update'; Kind = 'TargetOnly' }
        @{ Action = 'Remove'; Kind = 'Changed' }
        @{ Action = 'Promote'; Kind = 'Changed' }
    ) {
        param ($Action, $Kind)
        $finding = $script:Findings | Where-Object Kind -eq $Kind
        { New-PERectifyPlan -Findings @($finding) -Action $Action @PlanArgs -Decisions @(New-TestRemoveDecision -Key 'DevOnly'), (New-TestRemoveDecision -Key 'HR'), (New-TestRemoveDecision -Key 'Sales') } |
            Should -Throw "*$Action*$Kind*"
    }

    It 'one bad finding refuses the whole plan' {
        { New-PERectifyPlan -Findings @($script:Missing, $script:Changed) -Action Create @PlanArgs } | Should -Throw
    }

    It 'Remove is refused for an Unmanaged finding even with a Remove decision' {
        $f = @(Compare-PEState -Blueprint $script:Blueprint -Target $script:Target -Decisions @([pscustomobject]@{ Kind = 'Unmanaged'; ResourceType = 'AADGroup'; Key = 'DevOnly' }))
        $devOnly = $f | Where-Object Key -eq 'DevOnly'
        $devOnly.State | Should -Be 'Unmanaged'
        { New-PERectifyPlan -Findings @($devOnly) -Action Remove @PlanArgs -Decisions @(New-TestRemoveDecision -Key 'DevOnly') } | Should -Throw '*Unmanaged*'
    }

    It '<Action> is refused for an Unmanaged-state finding' -TestCases @(@{ Action = 'Create' }, @{ Action = 'Update' }) {
        param ($Action)
        $kind = if ($Action -eq 'Create') { 'Missing' } else { 'Changed' }
        $finding = ($script:Findings | Where-Object Kind -eq $kind) | Select-Object *
        $finding.State = 'Unmanaged'
        { New-PERectifyPlan -Findings @($finding) -Action $Action @PlanArgs } | Should -Throw '*Unmanaged*'
    }

    It 'Promote is allowed for an Unmanaged TargetOnly finding' {
        $f = @(Compare-PEState -Blueprint $script:Blueprint -Target $script:Target -Decisions @([pscustomobject]@{ Kind = 'Unmanaged'; ResourceType = 'AADGroup'; Key = 'DevOnly' }))
        $plan = @(New-PERectifyPlan -Findings @($f | Where-Object Key -eq 'DevOnly') -Action Promote @PlanArgs)
        $plan[0].Action | Should -Be 'Promote'
    }

    It 'Remove is refused for a finding with a hint (rename check skipped) even with a decision' {
        $finding = $script:TargetOnly | Select-Object *
        $finding.Hint = 'Rename check skipped: too many candidates'
        { New-PERectifyPlan -Findings @($finding) -Action Remove @PlanArgs -Decisions @(New-TestRemoveDecision -Key 'DevOnly') -ConfirmNotRenamed } | Should -Throw '*hint*'
    }

    Context 'PossibleRename' {
        BeforeAll {
            $props = [ordered]@{ Visibility = 'Private'; GroupTypes = @('Unified'); MembershipRule = 'r'; MembershipRuleProcessingState = 'On' }
            $script:RenameBlueprint = New-TestState -Records @(New-TestGroup -Name 'Old' -Description 'same' -Extra $props)
            $old = New-TestGroup -Name 'New' -Description 'same' -Extra $props
            $old.Properties['MailNickname'] = 'oldnick'
            $script:RenameTarget = New-TestState -Records @($old)
            $bp = $script:RenameBlueprint.Records[0]
            $bp.Properties['MailNickname'] = 'oldnick'
            $script:RenameFindings = @(Compare-PEState -Blueprint $script:RenameBlueprint -Target $script:RenameTarget)
            $script:RenameMissingSide = $script:RenameFindings | Where-Object Key -eq 'Old'
            $script:RenameTargetSide = $script:RenameFindings | Where-Object Key -eq 'New'
            $script:RenamePlan = @{ Source = $script:RenameTarget; Blueprint = $script:RenameBlueprint }
        }

        It 'the fixture yields two PossibleRename findings' {
            $script:RenameMissingSide.Kind | Should -Be 'PossibleRename'
            $script:RenameTargetSide.Kind | Should -Be 'PossibleRename'
        }

        It '<Action> is refused for a PossibleRename without -ConfirmNotRenamed' -TestCases @(
            @{ Action = 'Create' }, @{ Action = 'Update' }, @{ Action = 'Remove' }, @{ Action = 'Promote' }
        ) {
            param ($Action)
            foreach ($finding in $script:RenameFindings)
            {
                { New-PERectifyPlan -Findings @($finding) -Action $Action @RenamePlan -Decisions @(New-TestRemoveDecision -Key 'New') } | Should -Throw '*rename*'
            }
        }

        It 'Create is allowed for the blueprint side with -ConfirmNotRenamed and records the flag' {
            $plan = @(New-PERectifyPlan -Findings @($script:RenameMissingSide) -Action Create @RenamePlan -ConfirmNotRenamed)
            $plan[0].Action | Should -Be 'Create'
            $plan[0].ConfirmNotRenamed | Should -BeTrue
            $plan[0].Finding.Kind | Should -Be 'PossibleRename'
            Get-TestStrict $plan[0].Record.Properties | Should -BeExactly (Get-TestStrict $script:RenameMissingSide.BlueprintRecord.Properties)
        }

        It 'Remove is allowed for the target side with -ConfirmNotRenamed and a Remove decision' {
            $plan = @(New-PERectifyPlan -Findings @($script:RenameTargetSide) -Action Remove @RenamePlan -Decisions @(New-TestRemoveDecision -Key 'New') -ConfirmNotRenamed)
            $plan[0].Action | Should -Be 'Remove'
            $plan[0].ConfirmNotRenamed | Should -BeTrue
        }

        It 'Remove of the target side still needs a Remove decision with -ConfirmNotRenamed' {
            { New-PERectifyPlan -Findings @($script:RenameTargetSide) -Action Remove @RenamePlan -ConfirmNotRenamed } | Should -Throw '*Remove decision*'
        }

        It 'the sides cannot be swapped with -ConfirmNotRenamed' {
            { New-PERectifyPlan -Findings @($script:RenameTargetSide) -Action Create @RenamePlan -ConfirmNotRenamed } | Should -Throw
            { New-PERectifyPlan -Findings @($script:RenameMissingSide) -Action Remove @RenamePlan -Decisions @(New-TestRemoveDecision -Key 'Old') -ConfirmNotRenamed } | Should -Throw
        }

        It '<Action> stays refused for a PossibleRename with -ConfirmNotRenamed' -TestCases @(@{ Action = 'Update' }, @{ Action = 'Promote' }) {
            param ($Action)
            foreach ($finding in $script:RenameFindings)
            {
                { New-PERectifyPlan -Findings @($finding) -Action $Action @RenamePlan -ConfirmNotRenamed } | Should -Throw
            }
        }
    }

    Context 'validation against the source state' {
        It 'a stale TargetOnly finding (object no longer in the source) is refused' {
            $source = New-TestState -Records @((New-TestGroup -Name 'Sales'), (New-TestGroup -Name 'Finance'))
            { New-PERectifyPlan -Findings $script:TargetOnly -Action Promote -Source $source -Blueprint $script:Blueprint } | Should -Throw '*stale*'
            { New-PERectifyPlan -Findings $script:TargetOnly -Action Remove -Source $source -Blueprint $script:Blueprint -Decisions @(New-TestRemoveDecision -Key 'DevOnly') } | Should -Throw '*stale*'
        }

        It 'a stale Missing finding (object now in the source) is refused' {
            $source = New-TestState -Records @($script:Target.Records + @(New-TestGroup -Name 'hr'))
            { New-PERectifyPlan -Findings $script:Missing -Action Create -Source $source -Blueprint $script:Blueprint } | Should -Throw '*stale*'
        }

        It 'a TargetOnly or Changed finding whose target record differs from the source is refused' {
            $source = New-TestState -Records @(
                (New-TestGroup -Name 'Sales' -Description 'edited again'),
                (New-TestGroup -Name 'DevOnly' -Description 'edited in Dev')
            )
            { New-PERectifyPlan -Findings $script:TargetOnly -Action Promote -Source $source -Blueprint $script:Blueprint } | Should -Throw '*stale*'
            { New-PERectifyPlan -Findings $script:Changed -Action Update -Source $source -Blueprint $script:Blueprint } | Should -Throw '*stale*'
        }

        It 'a finding whose type is not checked in the source is refused' {
            $source = New-TestState -Records $script:Target.Records -NotChecked @([pscustomobject]@{ ResourceType = 'AADGroup'; Reason = 'export failed' })
            { New-PERectifyPlan -Findings $script:Missing -Action Create -Source $source -Blueprint $script:Blueprint } | Should -Throw '*not checked*'
        }

        It 'a quick-scan source (key-only records) is refused' {
            $source = New-TestState -Records $script:Target.Records -Source 'quick scan'
            { New-PERectifyPlan -Findings $script:Missing -Action Create -Source $source -Blueprint $script:Blueprint } | Should -Throw '*Full check*'
        }

        It 'a record with no properties is refused' {
            $record = [pscustomobject]@{ ResourceType = 'AADGroup'; Key = 'Bare'; Workload = 'Entra ID'; Properties = [ordered]@{} }
            $finding = New-TestFinding -Kind 'TargetOnly' -Key 'Bare' -TargetRecord $record
            { New-PERectifyPlan -Findings @($finding) -Action Promote -Source (New-TestState -Records @($record)) -Blueprint (New-TestState) } | Should -Throw '*no properties*'
        }

        It 'a finding whose record names another key is refused' {
            $finding = $script:TargetOnly | Select-Object *
            $finding.Key = 'Finance'
            { New-PERectifyPlan -Findings @($finding) -Action Promote @PlanArgs } | Should -Throw
        }

        It 'works on findings and states read back from JSON' {
            $json = ConvertTo-Json -InputObject @{ Findings = $script:Findings; State = $script:Target; Blueprint = $script:Blueprint } -Depth 20
            $back = $json | ConvertFrom-Json -Depth 20 -DateKind String
            $missing = $back.Findings | Where-Object Kind -eq 'Missing'
            $changed = $back.Findings | Where-Object Kind -eq 'Changed'
            @(New-PERectifyPlan -Findings @($missing) -Action Create -Source $back.State -Blueprint $back.Blueprint).Count | Should -Be 1
            @(New-PERectifyPlan -Findings @($changed) -Action Update -Source $back.State -Blueprint $script:Blueprint).Count | Should -Be 1
        }
    }

    Context 'validation against the current blueprint' {
        It 'Remove planned against an older blueprint is refused once the current blueprint has the key' {
            $current = New-TestState -Source $null -Records @($script:Blueprint.Records + @(New-TestGroup -Name 'DevOnly' -Description 'Built in Dev'))
            { New-PERectifyPlan -Findings $script:TargetOnly -Action Remove -Source $script:Target -Blueprint $current -Decisions @(New-TestRemoveDecision -Key 'DevOnly') } | Should -Throw '*blueprint changed since the check; re-run the check*'
        }

        It 'Promote planned against an older blueprint is refused once the current blueprint has the key' {
            $current = New-TestState -Source $null -Records @($script:Blueprint.Records + @(New-TestGroup -Name 'devonly'))
            { New-PERectifyPlan -Findings $script:TargetOnly -Action Promote -Source $script:Target -Blueprint $current } | Should -Throw '*blueprint changed*'
        }

        It 'Create with an outdated blueprint record is refused' {
            $current = New-TestState -Source $null -Records @(
                (New-TestGroup -Name 'Sales' -Description 'Sales team'),
                (New-TestGroup -Name 'HR' -Description 'People team, revised')
            )
            { New-PERectifyPlan -Findings $script:Missing -Action Create -Source $script:Target -Blueprint $current } | Should -Throw '*blueprint changed*'
        }

        It 'Create is refused once the key has left the current blueprint' {
            $current = New-TestState -Source $null -Records @(New-TestGroup -Name 'Sales' -Description 'Sales team')
            { New-PERectifyPlan -Findings $script:Missing -Action Create -Source $script:Target -Blueprint $current } | Should -Throw '*blueprint changed*'
        }

        It 'Update with an outdated blueprint record is refused' {
            $current = New-TestState -Source $null -Records @(New-TestGroup -Name 'Sales' -Description 'Sales team v4')
            { New-PERectifyPlan -Findings $script:Changed -Action Update -Source $script:Target -Blueprint $current } | Should -Throw '*blueprint changed*'
        }

        It 'a type not checked in the current blueprint is refused' {
            $current = New-TestState -Source $null -Records $script:Blueprint.Records -NotChecked @([pscustomobject]@{ ResourceType = 'AADGroup'; Reason = 'export failed' })
            { New-PERectifyPlan -Findings $script:TargetOnly -Action Promote -Source $script:Target -Blueprint $current } | Should -Throw '*not checked in the current blueprint*'
        }
    }

    Context 'source identity' {
        It 'each item records the source state and blueprint identity' {
            $item = @(New-PERectifyPlan -Findings $script:Missing -Action Create @PlanArgs)[0]
            $item.SourceIdentity.ExportedAt | Should -Be '2026-10-21T10:00:00Z'
            $item.SourceIdentity.TenantId | Should -Be 'dev.onmicrosoft.com'
            $item.SourceIdentity.Source | Should -Be 'full check'
            $item.SourceIdentity.BlueprintVersion | Should -Be 3
            $item.SourceIdentity.BlueprintExportedAt | Should -Be '2026-10-20T08:00:00Z'
        }

        It 'a source state without ExportedAt is refused' {
            $source = New-TestState -Records $script:Target.Records -Meta @{ TenantId = 'dev.onmicrosoft.com' }
            { New-PERectifyPlan -Findings $script:Missing -Action Create -Source $source -Blueprint $script:Blueprint } | Should -Throw '*ExportedAt*'
        }

        It '-ExpectedTenantId must match the source tenant' {
            { New-PERectifyPlan -Findings $script:Missing -Action Create @PlanArgs -ExpectedTenantId 'prod.onmicrosoft.com' } | Should -Throw '*expected tenant*'
            @(New-PERectifyPlan -Findings $script:Missing -Action Create @PlanArgs -ExpectedTenantId 'DEV.onmicrosoft.com').Count | Should -Be 1
            { New-PERectifyPlan -Findings $script:Missing -Action Create @PlanArgs -ExpectedTenantId '' } | Should -Throw
        }
    }

    It 'duplicate findings collapse to one plan item' {
        $plan = @(New-PERectifyPlan -Findings @($script:Missing, $script:Missing, ($script:Missing | Select-Object *)) -Action Create @PlanArgs)
        $plan.Count | Should -Be 1
    }

    It 'an empty finding list throws' {
        { New-PERectifyPlan -Findings @() -Action Create @PlanArgs } | Should -Throw '*No findings*'
        { New-PERectifyPlan -Findings @($null) -Action Create @PlanArgs } | Should -Throw '*No findings*'
    }
}

Describe 'ConvertTo-PEDscConfig' {
    BeforeAll {
        $script:CreatePlan = @(New-PERectifyPlan -Findings $script:Missing -Action Create @PlanArgs)
        $script:UpdatePlan = @(New-PERectifyPlan -Findings $script:Changed -Action Update @PlanArgs)
        $script:RemovePlan = @(New-PERectifyPlan -Findings $script:TargetOnly -Action Remove @PlanArgs -Decisions @(New-TestRemoveDecision -Key 'DevOnly'))
        $script:PromotePlan = @(New-PERectifyPlan -Findings $script:TargetOnly -Action Promote @PlanArgs)
    }

    Context 'a plan of 1 Create, 1 Remove and 1 Update' -Tag 'Slow' {
        BeforeAll {
            $script:MixedConfig = ConvertTo-PEDscConfig -Plan @($script:CreatePlan + $script:RemovePlan + $script:UpdatePlan) -ConfigurationName 'Rectify' -Target Replica
            $script:MixedObjects = @(ConvertTo-DSCObject -Content $script:MixedConfig -WarningAction SilentlyContinue)
        }

        It 'the config contains only the planned instances' {
            $script:MixedConfig | Should -Match "DisplayName\s*=\s*'HR'"
            $script:MixedConfig | Should -Match "DisplayName\s*=\s*'DevOnly'"
            $script:MixedConfig | Should -Match "DisplayName\s*=\s*'Sales'"
            $script:MixedConfig | Should -Not -Match 'Finance'
            @($script:MixedObjects.DisplayName | Sort-Object) | Should -Be @('DevOnly', 'HR', 'Sales')
        }

        It 'Remove items get Ensure Absent' {
            ($script:MixedObjects | Where-Object DisplayName -eq 'DevOnly').Ensure | Should -Be 'Absent'
            ($script:MixedObjects | Where-Object DisplayName -eq 'HR').Ensure | Should -Be 'Present'
            ($script:MixedObjects | Where-Object DisplayName -eq 'Sales').Ensure | Should -Be 'Present'
        }

        It 'Update uses the blueprint values' {
            ($script:MixedObjects | Where-Object DisplayName -eq 'Sales').Description | Should -Be 'Sales team'
        }

        It 'the output parses without errors' {
            Get-ParseErrorCount $script:MixedConfig | Should -Be 0
        }

        It 'round-trips through ConvertTo-DSCObject with the planned instances, types, keys and values' {
            $script:MixedObjects.Count | Should -Be 3
            @($script:MixedObjects.ResourceName | Select-Object -Unique) | Should -Be @('AADGroup')
            $hr = $script:MixedObjects | Where-Object DisplayName -eq 'HR'
            $hr.SecurityEnabled | Should -BeTrue
            $hr.MailEnabled | Should -BeFalse
            $hr.MailNickname | Should -Be 'hrnick'
        }

        It 'includes the pinned Import-DscResource line and a Node localhost wrapper' {
            $script:MixedConfig | Should -Match "Import-DscResource -ModuleName 'Microsoft365DSC' -ModuleVersion '2.26.1021.1'"
            $script:MixedConfig | Should -Match '(?m)^\s*Node localhost\s*$'
            $script:MixedConfig | Should -Match '(?m)^Configuration Rectify\s*$'
        }

        It 'takes credentials from the configuration data and embeds no credential values' {
            foreach ($name in 'ApplicationId', 'TenantId', 'CertificateThumbprint')
            {
                ([regex]::Matches($script:MixedConfig, "(?m)^\s*$name\s*=\s*\`$ConfigurationData\.NonNodeData\.$name;?\s*$")).Count | Should -Be 3
                ([regex]::Matches($script:MixedConfig, "(?m)^\s*$name\s*=")).Count | Should -Be 3
            }
            foreach ($object in $script:MixedObjects)
            {
                $object.ApplicationId | Should -Be '$ConfigurationData.NonNodeData.ApplicationId'
                $object.TenantId | Should -Be '$ConfigurationData.NonNodeData.TenantId'
                $object.CertificateThumbprint | Should -Be '$ConfigurationData.NonNodeData.CertificateThumbprint'
            }
        }
    }

    Context 'rendering of unusual records (one configuration)' -Tag 'Slow' {
        BeforeAll {
            $script:HostileName = "O'Brien ``$x ‘q’ `"dq`" `$(Get-Date) @{a=1}"
            $script:HostileDescription = "line1`nline2 ``n `$env:USERNAME ''"
            $noEnsure = New-TestGroup -Name 'NoEnsure'
            $noEnsure.Properties.Remove('Ensure')
            $script:AppProps = [ordered]@{
                DisplayName            = 'App One'
                Ensure                 = 'Present'
                Api                    = @{
                    CIMInstance               = 'MSFT_MicrosoftGraphapiApplication'
                    Oauth2PermissionScopes    = @(
                        @{ CIMInstance = 'MSFT_MicrosoftGraphAPIOauth2PermissionScopes'; Value = 'user_impersonation'; IsEnabled = $true; Type = 'User' }
                    )
                    PreAuthorizedApplications = @()
                }
                IdentifierUris         = @('api://one', "api://o'ne")
                IsFallbackPublicClient = $false
                Description            = $null
            }
            $appJson = '{"ResourceType":"AADApplication","Key":"App Two","Workload":"Entra ID","Properties":{"DisplayName":"App Two","Api":{"CIMInstance":"MSFT_MicrosoftGraphapiApplication","PreAuthorizedApplications":[],"Oauth2PermissionScopes":[]},"IsFallbackPublicClient":false,"Ensure":"Present"}}'
            # The reviewer's cp1252 break-out value, and one with several non-ASCII characters and an emoji.
            $script:EquipoName = 'Equipo ' + [char]0x00D1 + ' + (Write-Output INJECTED) + [string]0 #'
            $script:UnicodeName = 'Caf' + [char]0x00E9 + ' ' + [char]0x00D1 + ' it' + [char]0x2019 + 's ' + [char]::ConvertFromUtf32(0x1F600)
            $records = @(
                (New-TestGroup -Name $script:HostileName -Description $script:HostileDescription),
                (New-TestGroup -Name $script:EquipoName -Description $script:UnicodeName),
                (New-TestGroup -Name $script:UnicodeName),
                (New-TestGroup -Name 'Org' -Description 'admin@$OrganizationName and $OrganizationNameX ''q'' `x'),
                $noEnsure,
                (New-TestGroup -Name 'a b'),
                (New-TestGroup -Name 'a/b'),
                (New-TestGroup -Name 'A?B'),
                (New-TestGroup -Name "x'`$y"),
                [pscustomobject]@{ ResourceType = 'AADApplication'; Key = 'App One'; Workload = 'Entra ID'; Properties = $script:AppProps },
                ($appJson | ConvertFrom-Json -DateKind String)
            )
            $items = @($records | ForEach-Object { New-TestItem -Record $_ })
            $singleton = [pscustomobject]@{ ResourceType = 'AADAccessReviewPolicy'; Key = '(singleton)'; Workload = 'Entra ID'; Properties = [ordered]@{ IsSingleInstance = 'Yes'; IsGroupOwnerManagementEnabled = $false } }
            $items += New-TestItem -Action Update -Record $singleton
            $script:RenderConfig = ConvertTo-PEDscConfig -Plan $items -ConfigurationName 'Render' -Target Replica
            $script:RenderObjects = @(ConvertTo-DSCObject -Content $script:RenderConfig -WarningAction SilentlyContinue)
            $script:RenderErrors = $null
            $script:RenderAst = [System.Management.Automation.Language.Parser]::ParseInput($script:RenderConfig, [ref]$null, [ref]$script:RenderErrors)
            $script:Rendered = @{}
            foreach ($o in $script:RenderObjects)
            {
                $script:Rendered[[string]$(if ($o.DisplayName) { Resolve-TestDscValue $o.DisplayName } else { $o.ResourceName })] = $o
            }
        }

        It 'parses and round-trips every instance' {
            @($script:RenderErrors).Count | Should -Be 0
            $script:RenderObjects.Count | Should -Be 12
        }

        It 'escapes quotes, backticks and dollars in keys and values' {
            $o = $script:Rendered[$script:HostileName]
            $o | Should -Not -BeNullOrEmpty
            Resolve-TestDscValue $o.DisplayName | Should -BeExactly $script:HostileName
            Resolve-TestDscValue $o.Description | Should -BeExactly $script:HostileDescription
        }

        It 'writes pure ASCII and non-ASCII values as [char] codes' {
            $script:RenderConfig | Should -Not -Match '[^\x09\x0A\x0D\x20-\x7E]'
            $script:RenderConfig | Should -Match ([regex]::Escape("(-join @('Equipo ', [char]0x00D1, ' + (Write-Output INJECTED) + [string]0 #'))"))
            Resolve-TestDscValue $script:Rendered[$script:EquipoName].Description | Should -BeExactly $script:UnicodeName
            Resolve-TestDscValue $script:Rendered[$script:UnicodeName].DisplayName | Should -BeExactly $script:UnicodeName
        }

        It 'is command-free under both UTF-8 and Windows-1252 decoding of its bytes' {
            # The text is pure ASCII, so both decodings give back exactly the generated text; it parses once, cleanly.
            $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($script:RenderConfig)
            [System.Text.UTF8Encoding]::new($false).GetString($bytes) | Should -BeExactly $script:RenderConfig
            [System.Text.Encoding]::GetEncoding(1252).GetString($bytes) | Should -BeExactly $script:RenderConfig
            @($script:RenderErrors).Count | Should -Be 0
            @($script:RenderAst.FindAll({
                        param ($n)
                        $n -is [System.Management.Automation.Language.CommandAst] -or
                        $n -is [System.Management.Automation.Language.SubExpressionAst] -or
                        $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]
                    }, $true)).Count | Should -Be 0
        }

        It 'the safety check rejects text that breaks out under Windows-1252' {
            # What the reviewer showed for a single-quoted UTF-8 literal read as cp1252: U+00D1 -> C3 91 -> U+00C3 U+2018.
            $value = "'Equipo " + [char]0x00D1 + " + (Write-Output INJECTED) + [string]0 #'"
            $text = [regex]::Replace($script:RenderConfig, "(?m)^(\s*DisplayName\s*=\s*)'NoEnsure';", { param ($m) $m.Groups[1].Value + $value + ';' })
            $text | Should -Not -BeExactly $script:RenderConfig
            { InModuleScope PolicyEngine -Parameters @{ T = $text } { param ($T) Test-PEDscConfigSafe -Text $T -ResourceTypes @('AADGroup', 'AADApplication', 'AADAccessReviewPolicy') -ExpectedBlocks 12 -ConfigurationName 'Render' } } | Should -Throw '*Windows-1252*'
        }

        It 'the safety check accepts the generated configuration' {
            { InModuleScope PolicyEngine -Parameters @{ T = $script:RenderConfig } { param ($T) Test-PEDscConfigSafe -Text $T -ResourceTypes @('AADGroup', 'AADApplication', 'AADAccessReviewPolicy') -ExpectedBlocks 12 -ConfigurationName 'Render' } } | Should -Not -Throw
        }

        It 'the safety check rejects a <Kind> added to a resource block of a valid configuration' -TestCases @(
            @{ Kind = 'static member'; Expr = '[Math]::PI' }
            @{ Kind = 'convert to [int]'; Expr = "[int]'5'" }
            @{ Kind = 'sub-expression'; Expr = '$(Get-Date)' }
        ) {
            param ($Kind, $Expr)
            $text = [regex]::Replace($script:RenderConfig, "(?m)^(\s*)DisplayName(\s*=\s*)'NoEnsure';", { param ($m) $m.Value + "`n" + $m.Groups[1].Value + 'Visibility = ' + $Expr + ';' })
            $text | Should -Not -BeExactly $script:RenderConfig
            { InModuleScope PolicyEngine -Parameters @{ T = $text } { param ($T) Test-PEDscConfigSafe -Text $T -ResourceTypes @('AADGroup', 'AADApplication', 'AADAccessReviewPolicy') -ExpectedBlocks 12 -ConfigurationName 'Render' } } | Should -Throw
        }

        It 'keeps the $OrganizationName placeholder of the export as a variable' {
            $script:RenderConfig | Should -Match '\$OrganizationName = \$ConfigurationData\.NonNodeData\.OrganizationName'
            Resolve-TestDscValue $script:Rendered['Org'].Description | Should -BeExactly 'admin@$OrganizationName and $OrganizationNameX ''q'' `x'
            # The placeholder is a separate operand, so no following character (ASCII or not) can extend the name.
            $script:RenderConfig | Should -Match ([regex]::Escape("(-join @('admin@', `$OrganizationName, ' and ', `$OrganizationName, 'X ''q'' ``x'))"))
            $ast = $script:RenderAst
            @($ast.FindAll({ param ($n) $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)).Count | Should -Be 0
            $names = @($ast.FindAll({ param ($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.VariablePath.UserPath } | Sort-Object -Unique)
            $names | Should -Be @('ConfigurationData', 'false', 'OrganizationName', 'TenantGuid', 'true')
        }

        It 'Create gets Ensure Present when the record lacks Ensure and the resource has it' {
            $script:Rendered['NoEnsure'].Ensure | Should -Be 'Present'
        }

        It 'a resource without Ensure gets no Ensure' {
            $script:Rendered['AADAccessReviewPolicy'].Keys | Should -Not -Contain 'Ensure'
        }

        It 'gives unique, valid instance names' {
            $names = @($script:RenderObjects.ResourceInstanceName)
            @($names | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique).Count | Should -Be $names.Count
            foreach ($n in $names)
            {
                $n | Should -Match '^(AADGroup|AADApplication|AADAccessReviewPolicy)-[A-Za-z0-9_.-]+$'
            }
            @($names | Where-Object { $_ -like 'AADGroup-a-b*' }).Count | Should -Be 3
        }

        It 'renders nested CIM instances, arrays, numbers and booleans, and omits nulls' {
            $o = $script:Rendered['App One']
            $o.Api.CIMInstance | Should -Be 'MSFT_MicrosoftGraphapiApplication'
            $o.Api.Oauth2PermissionScopes[0].Value | Should -Be 'user_impersonation'
            $o.Api.Oauth2PermissionScopes[0].IsEnabled | Should -BeTrue
            @($o.IdentifierUris) | Should -Be @('api://one', "api://o'ne")
            $o.IsFallbackPublicClient | Should -BeFalse
            $o.Keys | Should -Not -Contain 'Description'
            $equal = InModuleScope PolicyEngine -Parameters @{ A = $script:AppProps.Api; B = $o.Api } { param ($A, $B) Test-PEValueEqual -A $A -B $B }
            $equal | Should -BeTrue
        }

        It 'renders CIM instances read back from JSON (PSCustomObject)' {
            $script:Rendered['App Two'].Api.CIMInstance | Should -Be 'MSFT_MicrosoftGraphapiApplication'
        }
    }

    Context 'a role assignment with a future start (conditional ignore path)' -Tag 'Slow' {
        It 'keeps the future ScheduleInfo.startDateTime through normalisation and renders it' {
            $raw = [pscustomobject]@{
                ResourceType = 'AADRoleAssignmentScheduleRequest'; Key = $null; Workload = 'Entra ID'; TenantId = $null
                Properties   = [ordered]@{
                    Principal = 'ann@contoso.com'; PrincipalType = 'User'; RoleDefinition = 'Global Reader'; DirectoryScopeId = '/'
                    Ensure = 'Present'; Id = 'x'
                    ScheduleInfo = @{
                        CIMInstance = 'MSFT_AADRoleAssignmentScheduleRequestSchedule'; startDateTime = '2026-12-01T00:00:00Z'
                        expiration = @{ CIMInstance = 'MSFT_AADRoleAssignmentScheduleRequestScheduleExpiration'; type = 'noExpiration' }
                    }
                }
            }
            $record = InModuleScope PolicyEngine -Parameters @{ R = $raw } { param ($R) ConvertTo-PENormalizedRecord -Record $R -ExportedAt '2026-10-22T08:51:16Z' }
            $record.Properties.ScheduleInfo.startDateTime | Should -Be '2026-12-01T00:00:00Z'
            $config = ConvertTo-PEDscConfig -Plan @(New-TestItem -Record $record) -ConfigurationName 'Future' -Target Replica
            $config | Should -Match 'startDateTime\s*=\s*''2026-12-01T00:00:00Z'''
        }
    }

    Context 'refusals' {
        It 'refuses a record carrying an ignored property <Name>' -TestCases @(
            @{ Name = 'TenantId' }, @{ Name = 'ApplicationId' }, @{ Name = 'CertificateThumbprint' }, @{ Name = 'Id' },
            @{ Name = 'Credential' }, @{ Name = 'ApplicationSecret' }, @{ Name = 'Members' }, @{ Name = 'Owners' }
        ) {
            param ($Name)
            $record = New-TestGroup -Name 'Leaky' -Extra @{ $Name = 'secret-value' }
            { ConvertTo-PEDscConfig -Plan @(New-TestItem -Record $record) -ConfigurationName 'C' -Target Replica } | Should -Throw "*$Name*"
        }

        It 'refuses a nested dictionary without a CIM class name' {
            $record = [pscustomobject]@{ ResourceType = 'AADApplication'; Key = 'App'; Workload = 'Entra ID'; Properties = [ordered]@{ DisplayName = 'App'; Api = @{ X = 1 } } }
            { ConvertTo-PEDscConfig -Plan @(New-TestItem -Record $record) -ConfigurationName 'C' -Target Replica } | Should -Throw '*CIM*'
        }

        It 'refuses a nested CIM member that is not a property of its class' {
            $record = [pscustomobject]@{ ResourceType = 'AADApplication'; Key = 'App'; Workload = 'Entra ID'; Properties = [ordered]@{ DisplayName = 'App'; Api = @{ CIMInstance = 'MSFT_MicrosoftGraphapiApplication'; Bogus = 1 } } }
            { ConvertTo-PEDscConfig -Plan @(New-TestItem -Record $record) -ConfigurationName 'C' -Target Replica } | Should -Throw '*Bogus*MSFT_MicrosoftGraphapiApplication*'
        }

        It 'refuses values that are not plain data' {
            $record = New-TestGroup -Name 'Cred' -Extra @{ Description = [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force)) }
            { ConvertTo-PEDscConfig -Plan @(New-TestItem -Record $record) -ConfigurationName 'C' -Target Replica } | Should -Throw
        }

        It 'refuses property and class names that are not identifiers, including a trailing newline' {
            $record = New-TestGroup -Name 'Bad' -Extra @{ 'Description; Remove-Item' = 'x' }
            { ConvertTo-PEDscConfig -Plan @(New-TestItem -Record $record) -ConfigurationName 'C' -Target Replica } | Should -Throw '*identifier*'
            $record = New-TestGroup -Name 'Bad2' -Extra @{ "Visibility`n" = 'x' }
            { ConvertTo-PEDscConfig -Plan @(New-TestItem -Record $record) -ConfigurationName 'C' -Target Replica } | Should -Throw '*identifier*'
            $record = [pscustomobject]@{ ResourceType = 'AADApplication'; Key = 'App'; Workload = 'Entra ID'; Properties = [ordered]@{ DisplayName = 'App'; Api = @{ CIMInstance = 'MSFT_X{}; evil'; A = 1 } } }
            { ConvertTo-PEDscConfig -Plan @(New-TestItem -Record $record) -ConfigurationName 'C' -Target Replica } | Should -Throw
            $record = [pscustomobject]@{ ResourceType = "AADGroup`n"; Key = 'G'; Workload = 'Entra ID'; Properties = (New-TestGroup -Name 'G').Properties }
            { ConvertTo-PEDscConfig -Plan @(New-TestItem -Record $record) -ConfigurationName 'C' -Target Replica } | Should -Throw '*resource type*'
        }

        It 'refuses an unknown resource type, an unknown property and a missing key property' {
            $record = [pscustomobject]@{ ResourceType = 'NotAResource'; Key = 'k'; Workload = 'Other'; Properties = [ordered]@{ DisplayName = 'k' } }
            { ConvertTo-PEDscConfig -Plan @(New-TestItem -Record $record) -ConfigurationName 'C' -Target Replica } | Should -Throw '*NotAResource*'
            $record = New-TestGroup -Name 'Extra' -Extra @{ NoSuchProperty = 'x' }
            { ConvertTo-PEDscConfig -Plan @(New-TestItem -Record $record) -ConfigurationName 'C' -Target Replica } | Should -Throw '*NoSuchProperty*'
            $record = New-TestGroup -Name 'NoNick'
            $record.Properties.Remove('MailNickname')
            { ConvertTo-PEDscConfig -Plan @(New-TestItem -Record $record) -ConfigurationName 'C' -Target Replica } | Should -Throw '*MailNickname*'
        }

        It 'refuses Remove for a resource type without Ensure' {
            $record = [pscustomobject]@{ ResourceType = 'AADAccessReviewPolicy'; Key = '(singleton)'; Workload = 'Entra ID'; Properties = [ordered]@{ IsSingleInstance = 'Yes'; IsGroupOwnerManagementEnabled = $false } }
            { ConvertTo-PEDscConfig -Plan @(New-TestItem -Action Remove -Record $record) -ConfigurationName 'C' -Target Replica } | Should -Throw '*Ensure*'
        }

        It 'a Master config takes Create, Update, Remove and Promote items (restoring the master to its blueprint)' -Tag 'Slow' {
            $config = ConvertTo-PEDscConfig -Plan $script:PromotePlan -ConfigurationName 'Promote' -Target Master
            $config | Should -Match "DisplayName\s*=\s*'DevOnly'"
            $config | Should -Match "Ensure\s*=\s*'Present'"
            ConvertTo-PEDscConfig -Plan $script:CreatePlan -ConfigurationName 'C' -Target Master | Should -Match "Ensure\s*=\s*'Present'"
            ConvertTo-PEDscConfig -Plan $script:RemovePlan -ConfigurationName 'C' -Target Master | Should -Match "Ensure\s*=\s*'Absent'"
        }

        It 'a Replica config never takes Promote' {
            { ConvertTo-PEDscConfig -Plan $script:PromotePlan -ConfigurationName 'C' -Target Replica } | Should -Throw '*Promote*'
        }

        It 'refuses two items for the same resource instance' {
            $record = New-TestGroup -Name 'Twice'
            { ConvertTo-PEDscConfig -Plan @((New-TestItem -Record $record), (New-TestItem -Action Update -Record $record)) -ConfigurationName 'C' -Target Replica } | Should -Throw '*more than once*'
        }

        It 'refuses an item whose record does not match its type and key' {
            $item = New-TestItem -Record (New-TestGroup -Name 'Real') -Key 'Someone else'
            { ConvertTo-PEDscConfig -Plan @($item) -ConfigurationName 'C' -Target Replica } | Should -Throw '*own record*'
        }

        It 'refuses an empty plan and an invalid configuration name' {
            { ConvertTo-PEDscConfig -Plan @() -ConfigurationName 'C' -Target Replica } | Should -Throw '*empty*'
            { ConvertTo-PEDscConfig -Plan $script:CreatePlan -ConfigurationName 'bad name; x' -Target Replica } | Should -Throw
            { ConvertTo-PEDscConfig -Plan $script:CreatePlan -ConfigurationName "Good`n" -Target Replica } | Should -Throw
        }
    }

    Context 'only plan items from New-PERectifyPlan' {
        It 'a hand-built Remove item is refused' {
            $item = [pscustomobject]@{
                Action = 'Remove'; ResourceType = 'AADGroup'; Key = 'Finance'; Workload = 'Entra ID'; Record = (New-TestGroup -Name 'Finance')
                Finding = $null; ConfirmNotRenamed = $false; SourceIdentity = $null
            }
            { ConvertTo-PEDscConfig -Plan @($item) -ConfigurationName 'C' -Target Replica } | Should -Throw '*not produced by New-PERectifyPlan*'
        }

        It 'a JSON round-tripped item is refused' {
            $back = ConvertTo-Json -InputObject $script:RemovePlan[0] -Depth 20 | ConvertFrom-Json -Depth 20
            { ConvertTo-PEDscConfig -Plan @($back) -ConfigurationName 'C' -Target Replica } | Should -Throw '*not produced by New-PERectifyPlan*'
        }

        It 'a copy of a real item is refused' {
            $copy = $script:CreatePlan[0] | Select-Object *
            { ConvertTo-PEDscConfig -Plan @($copy) -ConfigurationName 'C' -Target Replica } | Should -Throw '*not produced by New-PERectifyPlan*'
        }

        It 'an item changed after planning is refused' {
            $item = @(New-PERectifyPlan -Findings $script:TargetOnly -Action Promote @PlanArgs)[0]
            $item.Action = 'Remove'
            { ConvertTo-PEDscConfig -Plan @($item) -ConfigurationName 'C' -Target Replica } | Should -Throw '*changed after New-PERectifyPlan*'
            $item = @(New-PERectifyPlan -Findings $script:Missing -Action Create @PlanArgs)[0]
            $saved = $item.Record.Properties['Description']
            try
            {
                $item.Record.Properties['Description'] = 'tampered'
                { ConvertTo-PEDscConfig -Plan @($item) -ConfigurationName 'C' -Target Replica } | Should -Throw '*changed after New-PERectifyPlan*'
            }
            finally
            {
                $item.Record.Properties['Description'] = $saved
            }
        }

        It 'adding an empty <Name> property after planning invalidates the item' -TestCases @(
            @{ Name = 'AssignedLicenses'; Value = @() }, @{ Name = 'GroupTypes'; Value = '' }
        ) {
            param ($Name, $Value)
            $item = @(New-PERectifyPlan -Findings $script:Missing -Action Create @PlanArgs)[0]
            $item.Record.Properties[$Name] = $Value
            { ConvertTo-PEDscConfig -Plan @($item) -ConfigurationName 'C' -Target Replica } | Should -Throw '*changed after New-PERectifyPlan*'
        }

        It 'reordering an array after planning invalidates the item' {
            $target = New-TestState -Records @(New-TestGroup -Name 'Arr' -Extra @{ GroupTypes = @('Unified', 'DynamicMembership') })
            $finding = @(Compare-PEState -Blueprint (New-TestState) -Target $target)
            $item = @(New-PERectifyPlan -Findings $finding -Action Promote -Source $target -Blueprint (New-TestState))[0]
            $item.Record.Properties['GroupTypes'] = @('DynamicMembership', 'Unified')
            { ConvertTo-PEDscConfig -Plan @($item) -ConfigurationName 'C' -Target Master } | Should -Throw '*changed after New-PERectifyPlan*'
        }

        It 'editing <Field> after planning invalidates the item' -TestCases @(
            @{ Field = 'Workload' }, @{ Field = 'SourceIdentity' }, @{ Field = 'Finding Kind' }, @{ Field = 'Finding Hint' }
        ) {
            param ($Field)
            $findings = @(Compare-PEState -Blueprint $script:Blueprint -Target $script:Target)
            $item = @(New-PERectifyPlan -Findings @($findings | Where-Object Kind -eq 'TargetOnly') -Action Promote @PlanArgs)[0]
            switch ($Field)
            {
                'Workload' { $item.Workload = 'Intune' }
                'SourceIdentity' { $item.SourceIdentity.TenantId = 'other.onmicrosoft.com' }
                'Finding Kind' { $item.Finding.Kind = 'Missing' }
                'Finding Hint' { $item.Finding.Hint = 'x' }
            }
            { ConvertTo-PEDscConfig -Plan @($item) -ConfigurationName 'C' -Target Master } | Should -Throw '*changed after New-PERectifyPlan*'
        }

        It 'the item renders the record as planned, whatever the caller does to its own objects later' -Tag 'Slow' {
            $global:PETestDescription = 'first'
            try
            {
                $props = [pscustomobject]@{ DisplayName = 'Getter'; MailNickname = 'getter'; SecurityEnabled = $true; MailEnabled = $false; Ensure = 'Present' }
                $props | Add-Member -MemberType ScriptProperty -Name Description -Value { $global:PETestDescription }
                $record = [pscustomobject]@{ ResourceType = 'AADGroup'; Key = 'Getter'; Workload = 'Entra ID'; Properties = $props }
                $target = New-TestState -Records @($record)
                $finding = @(Compare-PEState -Blueprint (New-TestState) -Target $target)
                $item = @(New-PERectifyPlan -Findings $finding -Action Promote -Source $target -Blueprint (New-TestState))[0]
                $global:PETestDescription = 'second'
                $props.MailNickname = 'changed'
                $config = ConvertTo-PEDscConfig -Plan @($item) -ConfigurationName 'C' -Target Master
                $config | Should -Match "Description\s*=\s*'first'"
                $config | Should -Match "MailNickname\s*=\s*'getter'"
            }
            finally
            {
                Remove-Variable -Name PETestDescription -Scope Global -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'Save-PEAudit' -Tag 'Slow' {
    BeforeAll {
        $script:AuditPlan = @(
            @(New-PERectifyPlan -Findings $script:Changed -Action Update @PlanArgs) +
            @(New-PERectifyPlan -Findings $script:TargetOnly -Action Remove @PlanArgs -Decisions @(New-TestRemoveDecision -Key 'DevOnly'))
        )
        $script:Config = ConvertTo-PEDscConfig -Plan $script:AuditPlan -ConfigurationName 'Rectify' -Target Replica
    }

    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-audit-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Temp | Out-Null
    }

    AfterEach {
        Remove-Item $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Save-PEAudit writes config, plan and user' {
        $folder = Save-PEAudit -Plan $script:AuditPlan -Config $script:Config -User 'andrew' -DataRoot $script:Temp
        Split-Path -Parent $folder | Should -Be (Join-Path $script:Temp 'audit')
        Split-Path -Leaf $folder | Should -Match '^\d{8}-\d{9}$'
        Get-Content (Join-Path $folder 'config.ps1') -Raw | Should -Be $script:Config
        $who = Get-Content (Join-Path $folder 'who.txt') -Raw
        $who | Should -Match 'User: andrew'
        $who | Should -Match 'UTC: \d{4}-\d{2}-\d{2}T'
        $plan = Get-Content (Join-Path $folder 'plan.json') -Raw | ConvertFrom-Json
        $plan.User | Should -Be 'andrew'
        $plan.Items.Count | Should -Be 2
        $update = $plan.Items | Where-Object Action -eq 'Update'
        $update.ResourceType | Should -Be 'AADGroup'
        $update.Key | Should -Be 'Sales'
        $update.Workload | Should -Be 'Entra ID'
        $update.Kind | Should -Be 'Changed'
        $update.ConfirmNotRenamed | Should -BeFalse
        @($update.ChangedProperties) | Should -Be @('Description')
        ($plan.Items | Where-Object Action -eq 'Remove').Kind | Should -Be 'TargetOnly'
    }

    It 'plan.json records the source state and blueprint identity of each item' {
        $folder = Save-PEAudit -Plan $script:AuditPlan -Config $script:Config -User 'andrew' -DataRoot $script:Temp
        $plan = Get-Content (Join-Path $folder 'plan.json') -Raw | ConvertFrom-Json -DateKind String
        foreach ($entry in $plan.Items)
        {
            $entry.Source.ExportedAt | Should -Be '2026-10-21T10:00:00Z'
            $entry.Source.TenantId | Should -Be 'dev.onmicrosoft.com'
            $entry.Source.Source | Should -Be 'full check'
            $entry.Source.BlueprintVersion | Should -Be 3
            $entry.Source.BlueprintExportedAt | Should -Be '2026-10-20T08:00:00Z'
        }
    }

    It 'config.ps1 starts with the UTF-8 BOM and ConfigSha256 is the hash of the file bytes' {
        $folder = Save-PEAudit -Plan $script:AuditPlan -Config $script:Config -User 'andrew' -DataRoot $script:Temp
        $plan = Get-Content (Join-Path $folder 'plan.json') -Raw | ConvertFrom-Json
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $folder 'config.ps1'))
        @($bytes[0..2]) | Should -Be @(0xEF, 0xBB, 0xBF)
        $plan.ConfigSha256 | Should -Match '^[0-9A-F]{64}$'
        [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)) | Should -Be $plan.ConfigSha256
        (Get-FileHash -LiteralPath (Join-Path $folder 'config.ps1') -Algorithm SHA256).Hash | Should -Be $plan.ConfigSha256
        $plan.Target | Should -Be 'Replica'
        $plan.Configuration | Should -Be 'Rectify'
    }

    It 'refuses a config that was not generated from this plan' {
        { Save-PEAudit -Plan $script:AuditPlan -Config "# other`n$($script:Config)" -User 'u' -DataRoot $script:Temp } | Should -Throw '*config was not generated from this plan*'
        $oneChar = $script:Config.Replace("'Sales team'", "'Sales teaM'")
        $oneChar | Should -Not -BeExactly $script:Config
        { Save-PEAudit -Plan $script:AuditPlan -Config $oneChar -User 'u' -DataRoot $script:Temp } | Should -Throw '*config was not generated from this plan*'
        # A config generated from plan A is refused with plan B, and accepted with plan A.
        $planB = @(New-PERectifyPlan -Findings $script:Missing -Action Create @PlanArgs)
        { Save-PEAudit -Plan $planB -Config $script:Config -User 'u' -DataRoot $script:Temp } | Should -Throw '*config was not generated from this plan*'
        { Save-PEAudit -Plan @($script:AuditPlan[0]) -Config $script:Config -User 'u' -DataRoot $script:Temp } | Should -Throw '*config was not generated from this plan*'
        Test-Path (Join-Path $script:Temp 'audit\*') | Should -BeFalse
        Save-PEAudit -Plan $script:AuditPlan -Config $script:Config -User 'u' -DataRoot $script:Temp | Should -Exist
    }

    It 'plan.json carries no record, finding or difference values' {
        $folder = Save-PEAudit -Plan $script:AuditPlan -Config $script:Config -User 'andrew' -DataRoot $script:Temp
        $text = Get-Content (Join-Path $folder 'plan.json') -Raw
        $text | Should -Not -Match 'Sales team'
        $text | Should -Not -Match 'Built in Dev'
        $text | Should -Not -Match '"(Finding|Record|Properties|Differences|BlueprintRecord|TargetRecord)"'
    }

    It 'a colliding timestamp gets a suffix and nothing is overwritten' {
        Mock -ModuleName PolicyEngine Get-PEUtcNow { [datetime]::new(2026, 10, 21, 12, 0, 0, 123, [System.DateTimeKind]::Utc) }
        $first = Save-PEAudit -Plan $script:AuditPlan -Config $script:Config -User 'one' -DataRoot $script:Temp
        $second = Save-PEAudit -Plan $script:AuditPlan -Config $script:Config -User 'two' -DataRoot $script:Temp
        Split-Path -Leaf $first | Should -Be '20261021-120000123'
        Split-Path -Leaf $second | Should -Be '20261021-120000123-2'
        Get-Content (Join-Path $first 'who.txt') -Raw | Should -Match 'User: one'
        Get-Content (Join-Path $second 'who.txt') -Raw | Should -Match 'User: two'
    }

    It 'a failed write removes the folder it created and rethrows' {
        Mock -ModuleName PolicyEngine Write-PETextNew { throw 'disk full' }
        { Save-PEAudit -Plan $script:AuditPlan -Config $script:Config -User 'andrew' -DataRoot $script:Temp } | Should -Throw '*disk full*'
        @(Get-ChildItem (Join-Path $script:Temp 'audit') -Force).Count | Should -Be 0
    }

    It 'refuses an empty plan, an empty config, an empty user and hand-built items' {
        { Save-PEAudit -Plan @() -Config $script:Config -User 'u' -DataRoot $script:Temp } | Should -Throw '*empty*'
        { Save-PEAudit -Plan $script:AuditPlan -Config ' ' -User 'u' -DataRoot $script:Temp } | Should -Throw '*empty*'
        { Save-PEAudit -Plan $script:AuditPlan -Config $script:Config -User '' -DataRoot $script:Temp } | Should -Throw
        { Save-PEAudit -Plan @($script:AuditPlan[0] | Select-Object *) -Config $script:Config -User 'u' -DataRoot $script:Temp } | Should -Throw '*not produced by New-PERectifyPlan*'
        Test-Path (Join-Path $script:Temp 'audit\*') | Should -BeFalse
    }

    It 'flattens control characters in the user name' {
        $folder = Save-PEAudit -Plan $script:AuditPlan -Config $script:Config -User "eve`nUTC: forged" -DataRoot $script:Temp
        @(Get-Content (Join-Path $folder 'who.txt') | Where-Object { $_ -like 'UTC:*' }).Count | Should -Be 1
    }
}

Describe 'Rendering limits and the value allowlist' {
    BeforeAll {
        function Test-Fragment
        {
            # Runs the allowlist on @{ X = <expression> } (a plain hashtable parses without loading DSC keywords).
            param ([string]$Expression)

            $ast = [System.Management.Automation.Language.Parser]::ParseInput("@{ X = $Expression }", [ref]$null, [ref]$null)
            $hashtable = $ast.Find({ param ($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
            InModuleScope PolicyEngine -Parameters @{ H = $hashtable } { param ($H) Assert-PEDscHashtableAst -Node $H -Path 'T' }
        }

        function ConvertFrom-TestValueAst
        {
            # Constant-folds a generated value (a single-quoted literal or (-join @(...))) from its AST, without evaluating.
            param ($Pipeline)

            $expression = $Pipeline.PipelineElements[0].Expression
            if ($expression -is [System.Management.Automation.Language.StringConstantExpressionAst])
            {
                return $expression.Value
            }
            $array = $expression.Pipeline.PipelineElements[0].Expression.Child.SubExpression.Statements[0].PipelineElements[0].Expression
            $elements = if ($array -is [System.Management.Automation.Language.ArrayLiteralAst]) { $array.Elements } else { @($array) }
            $builder = [System.Text.StringBuilder]::new()
            foreach ($element in $elements)
            {
                if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst]) { [void]$builder.Append($element.Value) }
                elseif ($element -is [System.Management.Automation.Language.ConvertExpressionAst]) { [void]$builder.Append([char][int]$element.Child.Value) }
                elseif ($element -is [System.Management.Automation.Language.VariableExpressionAst]) { [void]$builder.Append('$OrganizationName') }
                else { throw "unexpected element $($element.GetType().Name)" }
            }
            return $builder.ToString()
        }
    }

    It 'allows the generated value form <Expression>' -TestCases @(
        @{ Expression = "'a'" }, @{ Expression = '5' }, @{ Expression = '-5' }, @{ Expression = '1.5' }, @{ Expression = '$true' },
        @{ Expression = '$ConfigurationData.NonNodeData.TenantId' }, @{ Expression = "(-join @('a', [char]0x00D1, `$OrganizationName))" },
        @{ Expression = '(-join @([char]0x00D1))' }, @{ Expression = '@()' }, @{ Expression = "@(`n'a'`n'b'`n)" }
    ) {
        param ($Expression)
        { Test-Fragment $Expression } | Should -Not -Throw
    }

    It 'refuses <Kind>' -TestCases @(
        @{ Kind = 'a sub-expression'; Expression = '$(Get-Date)' }
        @{ Kind = 'a command'; Expression = 'Get-Date' }
        @{ Kind = 'a command in parentheses'; Expression = '(Get-Date)' }
        @{ Kind = 'a script block'; Expression = '{ 1 }' }
        @{ Kind = 'a static member'; Expression = '[Math]::PI' }
        @{ Kind = 'a member invocation'; Expression = "'a'.ToUpper()" }
        @{ Kind = 'a convert to [int]'; Expression = "[int]'5'" }
        @{ Kind = 'a [char] convert of a string'; Expression = "[char]'x'" }
        @{ Kind = 'another variable'; Expression = '$env:USERNAME' }
        @{ Kind = 'another configuration data member'; Expression = '$ConfigurationData.NonNodeData.Secret' }
        @{ Kind = 'an expandable string'; Expression = '"x$y"' }
        @{ Kind = 'a double-quoted string'; Expression = '"x"' }
        @{ Kind = 'a hashtable literal'; Expression = '@{ a = 1 }' }
        @{ Kind = 'string concatenation'; Expression = "('a' + 'b')" }
        @{ Kind = 'another variable in a join'; Expression = "(-join @('a', `$x))" }
        @{ Kind = 'a command in a join'; Expression = "(-join @('a', (Get-Date)))" }
        @{ Kind = 'a join with a separator'; Expression = "('a', 'b' -join ',')" }
    ) {
        param ($Kind, $Expression)
        { Test-Fragment $Expression } | Should -Throw '*Disallowed*'
    }

    It 'renders a 30,000-character non-ASCII value flat, parses it and constant-folds it to the exact input' -Tag 'Slow' {
        $value = 'x' + [string]::new([char]0x00E9, 29980) + '$OrganizationName' + [char]0x2019
        $record = New-TestGroup -Name 'Long' -Description $value
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $config = ConvertTo-PEDscConfig -Plan @(New-TestItem -Record $record) -ConfigurationName 'C' -Target Replica
        $watch.Stop()
        Write-Host "    30,000-character value: generated and checked in $([math]::Round($watch.Elapsed.TotalSeconds, 1))s"
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 20
        $config | Should -Not -Match '[^\x09\x0A\x0D\x20-\x7E]'
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($config)
        [System.Text.Encoding]::GetEncoding(1252).GetString($bytes) | Should -BeExactly $config
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($config, [ref]$null, [ref]$errors)
        @($errors).Count | Should -Be 0
        $pair = $ast.Find({ param ($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true).KeyValuePairs |
            Where-Object { $_.Item1.Value -eq 'Description' }
        ConvertFrom-TestValueAst $pair.Item2 | Should -BeExactly $value
    }

    It 'refuses a string value above the length limit before generating any text' {
        $record = New-TestGroup -Name 'TooLong' -Description ([string]::new([char]0x00E9, 131073))
        { ConvertTo-PEDscConfig -Plan @(New-TestItem -Record $record) -ConfigurationName 'C' -Target Replica } | Should -Throw '*AADGroup`[TooLong`].Description*131073*limit*'
    }

    It 'refuses an array above the element limit' {
        $record = New-TestGroup -Name 'TooMany' -Extra @{ GroupTypes = @(1..2001 | ForEach-Object { "t$_" }) }
        { ConvertTo-PEDscConfig -Plan @(New-TestItem -Record $record) -ConfigurationName 'C' -Target Replica } | Should -Throw '*AADGroup`[TooMany`].GroupTypes*2000*'
    }
}

Describe 'Rendering and audit use only the frozen snapshot' -Tag 'Slow' {
    AfterEach {
        Remove-Variable -Name PESwapReads, PESwapOriginal, PESwapTampered -Scope Global -ErrorAction SilentlyContinue
    }

    It 'a ScriptProperty swapped in for Record.Properties after validation has no effect on the config' {
        $item = @(New-PERectifyPlan -Findings $script:Missing -Action Create @PlanArgs)[0]
        $global:PESwapReads = 0
        $global:PESwapOriginal = $item.Record.Properties
        $tampered = [ordered]@{}
        foreach ($k in $item.Record.Properties.Keys) { $tampered[$k] = $item.Record.Properties[$k] }
        $tampered['Description'] = 'TAMPERED'
        $global:PESwapTampered = $tampered
        [void]$item.Record.PSObject.Properties.Remove('Properties')
        # The first read (validation) sees the original; any later read would see the tampered value.
        $item.Record | Add-Member -MemberType ScriptProperty -Name Properties -Value {
            $global:PESwapReads++
            if ($global:PESwapReads -le 1) { $global:PESwapOriginal } else { $global:PESwapTampered }
        }
        $config = ConvertTo-PEDscConfig -Plan @($item) -ConfigurationName 'C' -Target Replica
        $global:PESwapReads | Should -Be 1
        $config | Should -Match "Description\s*=\s*'People team'"
        $config | Should -Not -Match 'TAMPERED'
    }

    It 'a ScriptProperty swapped in for Finding after validation has no effect on plan.json' {
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-audit-' + [guid]::NewGuid())
        try
        {
            $findings = @(Compare-PEState -Blueprint $script:Blueprint -Target $script:Target)
            $item = @(New-PERectifyPlan -Findings @($findings | Where-Object Kind -eq 'Changed') -Action Update @PlanArgs)[0]
            $config = ConvertTo-PEDscConfig -Plan @($item) -ConfigurationName 'C' -Target Replica
            $global:PESwapReads = 0
            $global:PESwapOriginal = $item.Finding
            $global:PESwapTampered = [pscustomobject]@{ Kind = 'TAMPERED'; State = 'TAMPERED'; Hint = 'TAMPERED'; Differences = @([pscustomobject]@{ Property = 'TAMPERED' }) }
            [void]$item.PSObject.Properties.Remove('Finding')
            $item | Add-Member -MemberType ScriptProperty -Name Finding -Value {
                $global:PESwapReads++
                if ($global:PESwapReads -le 1) { $global:PESwapOriginal } else { $global:PESwapTampered }
            }
            $folder = Save-PEAudit -Plan @($item) -Config $config -User 'u' -DataRoot $temp
            $global:PESwapReads | Should -Be 1
            $text = Get-Content (Join-Path $folder 'plan.json') -Raw
            $text | Should -Not -Match 'TAMPERED'
            ($text | ConvertFrom-Json).Items[0].Kind | Should -Be 'Changed'
        }
        finally
        {
            Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Configuration registry' {
    It 'keeps every plan that produced the same text' -Tag 'Slow' {
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-audit-' + [guid]::NewGuid())
        try
        {
            # Same records, different check states: the plans differ (SourceIdentity), the configuration text does not.
            $otherTarget = New-TestState -Records $script:Target.Records -Meta @{ TenantId = 'dev.onmicrosoft.com'; ExportedAt = '2026-10-21T11:00:00Z' }
            $planA = @(New-PERectifyPlan -Findings $script:Missing -Action Create @PlanArgs)
            $planB = @(New-PERectifyPlan -Findings $script:Missing -Action Create -Source $otherTarget -Blueprint $script:Blueprint)
            $configA = ConvertTo-PEDscConfig -Plan $planA -ConfigurationName 'Same' -Target Replica
            $configB = ConvertTo-PEDscConfig -Plan $planB -ConfigurationName 'Same' -Target Replica
            $configB | Should -BeExactly $configA
            Save-PEAudit -Plan $planA -Config $configA -User 'a' -DataRoot $temp | Should -Exist
            Save-PEAudit -Plan $planB -Config $configB -User 'b' -DataRoot $temp | Should -Exist
        }
        finally
        {
            Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps only the most recent 100 registrations' {
        $result = InModuleScope PolicyEngine {
            for ($i = 1; $i -le 101; $i++)
            {
                Register-PEDscConfig -Text "text $i" -PlanFingerprint "plan $i" -ConfigurationName 'C' -Target 'Replica'
            }
            [pscustomobject]@{
                Limit  = $script:PEConfigRegistryLimit
                First  = Get-PEDscConfigRegistration -Text 'text 1' -PlanFingerprint 'plan 1'
                Second = Get-PEDscConfigRegistration -Text 'text 2' -PlanFingerprint 'plan 2'
                Last   = Get-PEDscConfigRegistration -Text 'text 101' -PlanFingerprint 'plan 101'
                Count  = $script:PEConfigRegistryOrder.Count
            }
        }
        $result.Limit | Should -Be 100
        $result.First | Should -BeNullOrEmpty
        $result.Second | Should -Not -BeNullOrEmpty
        $result.Last | Should -Not -BeNullOrEmpty
        $result.Count | Should -Be 100
    }
}

Describe 'Total configuration size' {
    It 'a plan of many capped values throws before any parsing' {
        $items = foreach ($i in 1..20)
        {
            New-TestItem -Record (New-TestGroup -Name "Big$i" -Description ([string]::new([char]0x00E9, 32768)))
        }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        { ConvertTo-PEDscConfig -Plan @($items) -ConfigurationName 'C' -Target Replica } | Should -Throw '*exceed 8388608 characters at Create AADGroup ''Big*Split the plan into smaller batches*'
        $watch.Stop()
        Write-Host "    8 MB cap reached and refused in $([math]::Round($watch.Elapsed.TotalSeconds, 1))s"
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 30
    }

    It 'a plan exactly at a (lowered) cap passes and one character over throws' -Tag 'Slow' {
        $plan = @(New-PERectifyPlan -Findings $script:Missing -Action Create @PlanArgs)
        $config = ConvertTo-PEDscConfig -Plan $plan -ConfigurationName 'Cap' -Target Replica
        try
        {
            InModuleScope PolicyEngine -Parameters @{ L = $config.Length } { param ($L) $script:PEMaxConfigLength = $L }
            ConvertTo-PEDscConfig -Plan $plan -ConfigurationName 'Cap' -Target Replica | Should -BeExactly $config
            InModuleScope PolicyEngine -Parameters @{ L = $config.Length - 1 } { param ($L) $script:PEMaxConfigLength = $L }
            { ConvertTo-PEDscConfig -Plan $plan -ConfigurationName 'Cap' -Target Replica } | Should -Throw "*exceed $($config.Length - 1) characters at Create AADGroup 'HR' (plan item 1 of 1)*"
        }
        finally
        {
            InModuleScope PolicyEngine { $script:PEMaxConfigLength = 8MB }
        }
    }
}

Describe 'Safety check outside resource blocks' -Tag 'Slow' {
    BeforeAll {
        $plan = @(New-PERectifyPlan -Findings $script:Missing -Action Create @PlanArgs)
        $script:Base = ConvertTo-PEDscConfig -Plan $plan -ConfigurationName 'Base' -Target Replica

        function Test-Variant
        {
            param ([string]$Text, [string]$Name = 'Base')

            InModuleScope PolicyEngine -Parameters @{ T = $Text; N = $Name } { param ($T, $N) Test-PEDscConfigSafe -Text $T -ResourceTypes @('AADGroup') -ExpectedBlocks 1 -ConfigurationName $N }
        }

        function Add-BlockLine
        {
            # Inserts a property line after the DisplayName line of the resource block.
            param ([string]$Line)

            [regex]::Replace($script:Base, "(?m)^(\s*)DisplayName(\s*=\s*)'HR';", { param ($m) $m.Value + "`n" + $m.Groups[1].Value + $Line })
        }
    }

    It 'accepts the generated configuration' {
        { Test-Variant $script:Base } | Should -Not -Throw
    }

    It 'refuses <Kind>' -TestCases @(
        @{ Kind = 'a root-level trap'; Variant = 'RootTrap' }
        @{ Kind = 'a trap in the configuration body'; Variant = 'BodyTrap' }
        @{ Kind = 'a configuration named by an expression'; Variant = 'ExpressionName' }
        @{ Kind = 'a configuration named by a variable'; Variant = 'VariableName' }
        @{ Kind = 'a configuration name other than the expected one'; Variant = 'OtherName' }
        @{ Kind = 'a #requires statement'; Variant = 'Requires' }
        @{ Kind = 'a using statement'; Variant = 'Using' }
        @{ Kind = 'DependsOn in a resource block'; Variant = 'DependsOn' }
        @{ Kind = 'PsDscRunAsCredential in a resource block'; Variant = 'RunAs' }
        @{ Kind = 'a secret property in a resource block'; Variant = 'Credential' }
        @{ Kind = 'a membership property in a resource block'; Variant = 'Members' }
    ) {
        param ($Kind, $Variant)
        $name = 'Base'
        $text = switch ($Variant)
        {
            'RootTrap' { "trap { continue }`n" + $script:Base }
            'BodyTrap' { $script:Base.Replace("    param ()`n", "    param ()`n    trap { continue }`n") }
            'ExpressionName' { $script:Base.Replace('Configuration Base', "Configuration ([System.IO.StreamWriter]'C:\x')") }
            'VariableName' { $script:Base.Replace('Configuration Base', 'Configuration $x') }
            'OtherName' { $name = 'Expected'; $script:Base }
            'Requires' { "#requires -Version 5.1`n" + $script:Base }
            'Using' { "using namespace System.IO`n" + $script:Base }
            'DependsOn' { Add-BlockLine "DependsOn = '[AADGroup]Other';" }
            'RunAs' { Add-BlockLine "PsDscRunAsCredential = 'x';" }
            'Credential' { Add-BlockLine "Credential = 'x';" }
            'Members' { Add-BlockLine "Members = @('a');" }
        }
        if ($Variant -ne 'OtherName')
        {
            $text | Should -Not -BeExactly $script:Base
        }
        { Test-Variant -Text $text -Name $name } | Should -Throw
    }
}

Describe 'Evicted configuration registrations' -Tag 'Slow' {
    It 'Save-PEAudit says the registration may have been evicted, and a regenerated config is accepted' {
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-audit-' + [guid]::NewGuid())
        try
        {
            $plan = @(New-PERectifyPlan -Findings $script:Missing -Action Create @PlanArgs)
            $config = ConvertTo-PEDscConfig -Plan $plan -ConfigurationName 'Evict' -Target Replica
            InModuleScope PolicyEngine {
                for ($i = 1; $i -le $script:PEConfigRegistryLimit; $i++)
                {
                    Register-PEDscConfig -Text "filler $i" -PlanFingerprint "plan $i" -ConfigurationName 'C' -Target 'Replica'
                }
            }
            { Save-PEAudit -Plan $plan -Config $config -User 'u' -DataRoot $temp } | Should -Throw '*evicted after 100 newer configs*regenerate*'
            $again = ConvertTo-PEDscConfig -Plan $plan -ConfigurationName 'Evict' -Target Replica
            $again | Should -BeExactly $config
            Save-PEAudit -Plan $plan -Config $again -User 'u' -DataRoot $temp | Should -Exist
        }
        finally
        {
            Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Exact UTF-16 rendering' {
    BeforeAll {
        function ConvertTo-TestLiteral
        {
            # Renders strings with the module's renderer and checks each against the allowlist as a property value.
            param ([string[]]$Values)

            InModuleScope PolicyEngine -Parameters @{ Values = $Values } {
                param ($Values)
                foreach ($value in $Values)
                {
                    $literal = ConvertTo-PEDscStringLiteral -Value $value
                    $errors = $null
                    $ast = [System.Management.Automation.Language.Parser]::ParseInput("@{ X = $literal }", [ref]$null, [ref]$errors)
                    if (@($errors).Count -gt 0)
                    {
                        throw "parse errors for $literal"
                    }
                    $hashtable = $ast.Find({ param ($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
                    Assert-PEDscHashtableAst -Node $hashtable -Path 'T'
                    [pscustomobject]@{ Literal = $literal; Value = $hashtable.KeyValuePairs[0].Item2 }
                }
            }
        }

        function ConvertFrom-TestFold
        {
            # Constant-folds a rendered value from its AST (parse only, never executed) to the exact UTF-16 code units.
            param ($Pipeline)

            $expression = $Pipeline.PipelineElements[0].Expression
            if ($expression -is [System.Management.Automation.Language.StringConstantExpressionAst])
            {
                return $expression.Value
            }
            $array = $expression.Pipeline.PipelineElements[0].Expression.Child.SubExpression.Statements[0].PipelineElements[0].Expression
            $elements = if ($array -is [System.Management.Automation.Language.ArrayLiteralAst]) { $array.Elements } else { @($array) }
            $builder = [System.Text.StringBuilder]::new()
            foreach ($element in $elements)
            {
                if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst]) { [void]$builder.Append($element.Value) }
                elseif ($element -is [System.Management.Automation.Language.ConvertExpressionAst]) { [void]$builder.Append([char][int]$element.Child.Value) }
                elseif ($element -is [System.Management.Automation.Language.VariableExpressionAst]) { [void]$builder.Append('$OrganizationName') }
                else { throw "unexpected element $($element.GetType().Name)" }
            }
            return $builder.ToString()
        }

        function Get-TestCodeUnits
        {
            param ([string]$Text)

            ($Text.ToCharArray() | ForEach-Object { '{0:X4}' -f [int]$_ }) -join ' '
        }
    }

    It 'renders <Name> as its exact code units' -TestCases @(
        @{ Name = 'a lone high surrogate'; Value = [string][char]0xD800 }
        @{ Name = 'a lone low surrogate'; Value = [string][char]0xDC00 }
        @{ Name = 'a string ending in a high surrogate'; Value = 'abc' + [char]0xDBFF }
        @{ Name = 'a valid pair'; Value = [char]::ConvertFromUtf32(0x1F600) }
        @{ Name = 'a pair split by ASCII'; Value = [string][char]0xD83D + 'x' + [char]0xDE00 }
        @{ Name = 'a + D800 + b'; Value = 'a' + [char]0xD800 + 'b' }
    ) {
        param ($Name, $Value)
        $result = @(ConvertTo-TestLiteral -Values @($Value))[0]
        $result.Literal | Should -Not -Match '[^\x20-\x7E]'
        $result.Literal | Should -Not -Match 'FFFD'
        Get-TestCodeUnits (ConvertFrom-TestFold $result.Value) | Should -BeExactly (Get-TestCodeUnits $Value)
    }

    It 'regression: a lone surrogate is not replaced by U+FFFD' {
        $result = @(ConvertTo-TestLiteral -Values @('a' + [char]0xD800 + 'b'))[0]
        $result.Literal | Should -BeExactly "(-join @('a', [char]0xD800, 'b'))"
    }

    It 'fuzz: random strings render to pure ASCII, pass the allowlist and fold to the exact input' {
        $random = [System.Random]::new(20261022)
        $pieces = @('a', 'Z', ' ', "'", '$', '`', '"', '$OrganizationName', '$Organization', [string][char]0x00E9, [string][char]0x2019,
            [string][char]0x00D1, "`n", "`t", [string][char]0)
        $values = foreach ($i in 1..3000)
        {
            $builder = [System.Text.StringBuilder]::new()
            $count = $random.Next(0, 12)
            for ($j = 0; $j -lt $count; $j++)
            {
                switch ($random.Next(0, 4))
                {
                    0 { [void]$builder.Append([char]$random.Next(0xD800, 0xE000)) }
                    1 { [void]$builder.Append([char]::ConvertFromUtf32($random.Next(0x10000, 0x110000))) }
                    2 { [void]$builder.Append([char]$random.Next(0x20, 0x7F)) }
                    default { [void]$builder.Append($pieces[$random.Next(0, $pieces.Count)]) }
                }
            }
            $builder.ToString()
        }
        $results = @(ConvertTo-TestLiteral -Values $values)
        $results.Count | Should -Be 3000
        for ($i = 0; $i -lt $values.Count; $i++)
        {
            if ($results[$i].Literal -match '[^\x20-\x7E]')
            {
                throw "non-ASCII output for value $i"
            }
            $folded = ConvertFrom-TestFold $results[$i].Value
            if (-not [string]::Equals($folded, $values[$i], [System.StringComparison]::Ordinal))
            {
                throw "value $i folds to $(Get-TestCodeUnits $folded), expected $(Get-TestCodeUnits $values[$i])"
            }
        }
    }

    It 'two records that differ only in a lone surrogate have different fingerprints' {
        $prints = InModuleScope PolicyEngine {
            foreach ($c in [char]0xD800, [char]0xDFFF)
            {
                Get-PEPlanSnapshotFingerprint -Snapshot ([ordered]@{ Value = 'a' + $c })
            }
        }
        $prints[0] | Should -Not -Be $prints[1]
    }
}

Describe 'Rendering budget' {
    It 'an item with 2,000 maximum-length strings is refused in under 5 seconds' {
        $long = [string]::new([char]0x00E9, 32768)
        $record = New-TestGroup -Name 'Wide' -Extra @{ GroupTypes = @(for ($i = 0; $i -lt 2000; $i++) { $long }) }
        $item = New-TestItem -Record $record
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        { ConvertTo-PEDscConfig -Plan @($item) -ConfigurationName 'C' -Target Replica } | Should -Throw "*exceed 8388608 characters at Create AADGroup 'Wide' property GroupTypes (plan item 1 of 1)*Split the plan*"
        $watch.Stop()
        Write-Host "    2,000 x 32,768 characters refused in $([math]::Round($watch.Elapsed.TotalSeconds, 1))s"
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 5
    }

    It 'the budget stops rendering after a few elements' {
        $rendered = InModuleScope PolicyEngine {
            $long = [string]::new([char]0x00E9, 32768)
            $budget = [pscustomobject]@{ Remaining = 1000000; Exceeded = $false }
            $script:PETestRendered = 0
            Mock ConvertTo-PEDscStringLiteral { $script:PETestRendered++; 'x' * 459000 }
            try
            {
                Format-PEDscValue -Value @(for ($i = 0; $i -lt 2000; $i++) { $long }) -Path 'T' -Budget $budget
            }
            catch
            {
            }
            [pscustomobject]@{ Count = $script:PETestRendered; Exceeded = $budget.Exceeded }
        }
        $rendered.Exceeded | Should -BeTrue
        $rendered.Count | Should -Be 3
    }
}

Describe 'Allowlist names, fragment level' {
    It 'refuses a resource property that is not in the schema' {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput("@{ DisplayName = 'x'; NoSuchProperty = 'y' }", [ref]$null, [ref]$null)
        $hashtable = $ast.Find({ param ($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
        { InModuleScope PolicyEngine -Parameters @{ H = $hashtable } { param ($H) Assert-PEDscHashtableAst -Node $H -Path 'AADGroup[x]' -Parameters (Get-PEDscResourceSchema -ResourceType 'AADGroup') } } |
            Should -Throw '*NoSuchProperty is not a parameter in the schema*'
    }

    It 'refuses a nested CIM member that is not in its class schema' {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput("@{ Oauth2PermissionScopes = @(); Bogus = 'y' }", [ref]$null, [ref]$null)
        $hashtable = $ast.Find({ param ($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
        { InModuleScope PolicyEngine -Parameters @{ H = $hashtable } { param ($H) Assert-PEDscHashtableAst -Node $H -Path 'Api' -Parameters (Get-PEDscSchema)['MSFT_MicrosoftGraphapiApplication'] } } |
            Should -Throw '*Bogus is not a parameter in the schema*'
    }

    It 'refuses a never-generated name even when the schema has it' {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput("@{ Credential = 'x' }", [ref]$null, [ref]$null)
        $hashtable = $ast.Find({ param ($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
        { InModuleScope PolicyEngine -Parameters @{ H = $hashtable } {
                param ($H)
                $refused = [System.Collections.Generic.HashSet[string]]::new([string[]]@('Credential'), [System.StringComparer]::OrdinalIgnoreCase)
                Assert-PEDscHashtableAst -Node $H -Path 'AADGroup[x]' -Parameters (Get-PEDscResourceSchema -ResourceType 'AADGroup') -Refused $refused
            } } | Should -Throw '*Credential is never generated*'
    }
}

Describe 'New-PERectifyPlan and properties excluded for the tenant' {
    BeforeEach {
        # Sales differs in Description only; the owner excluded Description for this tenant, and Ensure-less AADGroup also differs in nothing else,
        # so a second real difference (MailEnabled) is added to the finding to make it a mixed one.
        $targetDescription = $script:Changed.TargetRecord.Properties['Description']
        $script:Mixed = $script:Changed | Select-Object *
        $script:Mixed.Differences = @([pscustomobject]@{ Property = 'MailEnabled'; Blueprint = $false; Target = $true })
        $script:Mixed.ExcludedDifferences = @([pscustomobject]@{ Property = 'description'; Blueprint = 'Sales team'; Target = $targetDescription })
    }

    It 'Update writes the tenant value of an excluded property and the blueprint value of the rest' {
        $plan = @(New-PERectifyPlan -Findings @($script:Mixed) -Action Update @PlanArgs)
        $plan[0].Record.Properties['Description'] | Should -Be 'Sales team (edited)'
        $plan[0].Record.Properties['MailEnabled'] | Should -BeFalse
        $plan[0].Record.Properties['DisplayName'] | Should -Be 'Sales'
        # the finding's own blueprint record is not modified
        $script:Mixed.BlueprintRecord.Properties['Description'] | Should -Be 'Sales team'
    }

    It 'a tenant with no value for the excluded property gets it left out of the record' {
        $noValue = [pscustomobject]@{ ResourceType = 'AADGroup'; Key = 'Sales'; Workload = 'Entra ID'; Properties = [ordered]@{ DisplayName = 'Sales' } }
        $mixed = $script:Mixed | Select-Object *
        $mixed.TargetRecord = $noValue
        $plan = @(New-PERectifyPlan -Findings @($mixed) -Action Update -Source (New-TestState -Records @($noValue)) -Blueprint $script:Blueprint)
        $plan[0].Record.Properties.Contains('Description') | Should -BeFalse
    }

    It 'a stored finding older than the exclusion is still protected by the decisions passed in' {
        $rule = { param ($key, $tenant) [pscustomobject]@{ Kind = 'PropertyExcluded'; ResourceType = 'AADGroup'; Key = $key; Property = 'description'; Value = $null; Tenant = $tenant } }
        # $script:Changed has Description as an enforced difference and no ExcludedDifferences (it was made before the exclusion).
        $type = @(New-PERectifyPlan -Findings $script:Changed -Action Update @PlanArgs -Decisions @(& $rule $null 'dev'))
        $type[0].Record.Properties['Description'] | Should -Be 'Sales team (edited)'
        $item = @(New-PERectifyPlan -Findings $script:Changed -Action Update @PlanArgs -Decisions @(& $rule 'sales' 'dev'))
        $item[0].Record.Properties['Description'] | Should -Be 'Sales team (edited)'
    }

    It 'a decision for another item, with no tenant, or for another property does not protect anything' {
        $make = { param ($key, $tenant, $property) [pscustomobject]@{ Kind = 'PropertyExcluded'; ResourceType = 'AADGroup'; Key = $key; Property = $property; Value = $null; Tenant = $tenant } }
        foreach ($decision in @((& $make 'Finance' 'dev' 'Description'), (& $make $null $null 'Description'), (& $make $null 'dev' 'MailEnabled')))
        {
            $plan = @(New-PERectifyPlan -Findings $script:Changed -Action Update @PlanArgs -Decisions @($decision))
            $plan[0].Record.Properties['Description'] | Should -Be 'Sales team'
        }
    }

    It 'a finding without excluded differences plans as before' {
        $plan = @(New-PERectifyPlan -Findings $script:Changed -Action Update @PlanArgs)
        $plan[0].Record.Properties['Description'] | Should -Be 'Sales team'
    }

    It 'the audit snapshot lists the excluded properties' {
        $plan = @(New-PERectifyPlan -Findings @($script:Mixed) -Action Update @PlanArgs)
        $snapshot = InModuleScope PolicyEngine -Parameters @{ Item = $plan[0] } { param ($Item) Get-PEPlanItemSnapshot -Item $Item }
        @($snapshot.Finding.ExcludedProperties) | Should -Be @('description')
    }

    It 'a finding whose only differences are excluded (Unmanaged) is still refused for Update' {
        $only = $script:Mixed | Select-Object *
        $only.Differences = @()
        $only.State = 'Unmanaged'
        { New-PERectifyPlan -Findings @($only) -Action Update @PlanArgs } | Should -Throw '*Unmanaged*'
    }
}
