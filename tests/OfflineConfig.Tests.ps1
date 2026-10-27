BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    Import-Module DSCParser -RequiredVersion 3.1.0.7 -ErrorAction Stop

    function New-TestGroup
    {
        param ([string]$Name, [string]$Description = "About $Name", [System.Collections.IDictionary]$Extra = @{})
        $props = [ordered]@{
            DisplayName     = $Name
            MailNickname    = ($Name -replace '[^A-Za-z0-9]', '').ToLowerInvariant() + 'nick'
            SecurityEnabled = $true
            MailEnabled     = $false
            Description     = $Description
            Ensure          = 'Present'
        }
        foreach ($k in $Extra.get_Keys()) { $props[$k] = $Extra[$k] }
        [pscustomobject]@{ ResourceType = 'AADGroup'; Key = $Name; Workload = 'Entra ID'; Properties = $props }
    }

    function New-TestState
    {
        param ([object[]]$Records = @(), [object[]]$NotChecked = @(), [hashtable]$ExtraMeta = @{})
        $meta = @{ TenantId = 'acme.example'; ExportedAt = '2026-10-25T10:00:00Z'; Source = 'Uploaded' }
        foreach ($k in $ExtraMeta.Keys) { $meta[$k] = $ExtraMeta[$k] }
        & (Get-Module PolicyEngine) {
            param ($r, $n, $m)
            New-PEState -Records $r -NotChecked $n -Meta $m
        } $Records $NotChecked $meta
    }

    function Add-TestTenant
    {
        # A tenant with its own blueprint (named after it) and a stored Full check of $Target.
        # -CheckedAgainst: the blueprint records the stored findings were computed with, when the blueprint changed after the check.
        # -CheckBlueprintVersion: the blueprint version the stored check says it was made against (default 1, the one created here).
        param ([string]$Root, [string]$Slug, [switch]$Offline, [object[]]$Own, $Target, [object[]]$CheckedAgainst, [int]$CheckBlueprintVersion = 1)
        $arguments = @{ Slug = $Slug; TenantId = 'acme.example'; DataRoot = $Root }
        if ($Offline) { $arguments.Offline = $true }
        Set-PETenant @arguments | Out-Null
        Initialize-PEBlueprint -Name $Slug -State (New-TestState -Records $Own) -DataRoot $Root | Out-Null
        Set-PETenant -Slug $Slug -Blueprints @('main', $Slug) -DataRoot $Root | Out-Null
        $checkedBlueprint = if ($CheckedAgainst) { New-TestState -Records $CheckedAgainst } else { Get-PEBlueprint -Name $Slug -DataRoot $Root }
        $findings = @(Compare-PEState -Blueprint $checkedBlueprint -Target $Target)
        $directory = Join-Path $Root 'checks\20261025-100000'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        [ordered]@{ CheckId = '20261025-100000'; Kind = 'Full'; TenantSlug = $Slug; BlueprintName = $Slug; BlueprintVersion = $CheckBlueprintVersion; Findings = $findings; State = $Target } |
            ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $directory 'result.json') -Encoding utf8
    }

    function Get-Block
    {
        # The resource block of one key in a generated configuration, or $null.
        param ([string]$Text, [string]$Key)
        if (-not $Text) { return $null }
        $parts = & (Get-Module PolicyEngine) { param ($t) Split-PEDscConfigText -Text $t } $Text
        @($parts.Blocks | Where-Object { $_ -match "(?m)^\s+DisplayName\s+= '$([regex]::Escape($Key))';" }) | Select-Object -First 1
    }
}

Describe 'New-PEOfflineConfig' -Tag 'Slow' {
    BeforeAll {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-offcfg-' + [guid]::NewGuid())
        # The own blueprint: Sales (changed in the tenant), Gone (missing), Hidden (missing, and its record still carries Members, a
        # property on the ignored list of AADGroup: a blueprint stored before the entry was added), Team Alpha (renamed in the
        # tenant to Team Alpha 2) and an EXOMailTips record of a type the upload did not check.
        $own = @(
            (New-TestGroup 'Sales' -Description 'one'),
            (New-TestGroup 'Gone'),
            (New-TestGroup 'Hidden' -Extra ([ordered]@{ Members = @('someone@acme.example') })),
            (New-TestGroup 'Team Alpha' -Description 'Same'),
            [pscustomobject]@{ ResourceType = 'EXOMailTips'; Key = 'default'; Workload = 'Exchange Online'; Properties = [ordered]@{ Organization = 'default'; MailTipsAllTipsEnabled = $true; Ensure = 'Present' } }
        )
        $renamed = New-TestGroup 'Team Alpha 2' -Description 'Same'
        $renamed.Properties.MailNickname = 'teamalphanick'
        $target = New-TestState -Records @(
            (New-TestGroup 'Sales' -Description 'two'),
            (New-TestGroup 'Extra'),
            (New-TestGroup 'Kept'),
            $renamed,
            [pscustomobject]@{ ResourceType = 'EXOMailTips'; Key = 'other'; Workload = 'Exchange Online'; Properties = [ordered]@{ Organization = 'other'; MailTipsAllTipsEnabled = $false; Ensure = 'Present' } }
        ) -NotChecked @([pscustomobject]@{ ResourceType = 'EXOMailTips'; Reason = 'no records in the upload and no export log' })
        Add-TestTenant -Root $script:Temp -Slug 'acme' -Offline -Own $own -Target $target
        # Kept is left in the tenant on purpose: an Unmanaged decision for this tenant, made after the check.
        Set-PEDecision -Kind Unmanaged -ResourceType 'AADGroup' -Key 'Kept' -Reason 'tenant-specific' -Tenant 'acme' -DataRoot $script:Temp | Out-Null
        $script:Result = New-PEOfflineConfig -Tenant 'acme' -DataRoot $script:Temp
    }

    AfterAll {
        Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'names the check and the tenant''s own blueprint it was generated from' {
        $script:Result.CheckId | Should -Be '20261025-100000'
        $script:Result.BlueprintName | Should -Be 'acme'
    }

    It 'puts the Create and the Update in Changes, which parses without errors' {
        $script:Result.Changes | Should -Not -BeNullOrEmpty
        $script:Result.Changes | Should -Match '(?m)^Configuration PE_Changes\s*$'
        $gone = Get-Block $script:Result.Changes 'Gone'
        $gone | Should -Not -BeNullOrEmpty
        $gone | Should -Match "Ensure\s+= 'Present';"
        $sales = Get-Block $script:Result.Changes 'Sales'
        $sales | Should -Match "Description\s+= 'one';"
        $sales | Should -Match "Ensure\s+= 'Present';"
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($script:Result.Changes, [ref]$null, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
        $script:Result.Changes | Should -Match 'Resource instances: 2\.'
    }

    It 'puts only the open target-only item in Removals, with Ensure Absent' {
        $script:Result.Removals | Should -Match '(?m)^Configuration PE_Removals\s*$'
        $script:Result.Removals | Should -Match 'Resource instances: 1\.'
        $extra = Get-Block $script:Result.Removals 'Extra'
        $extra | Should -Match "Ensure\s+= 'Absent';"
        $script:Result.Changes | Should -Not -Match "'Extra'"
    }

    It 'never removes an item the user decided to keep (Unmanaged), nor writes it anywhere' {
        Get-Block $script:Result.Removals 'Kept' | Should -BeNullOrEmpty
        $script:Result.Removals | Should -Not -Match 'Kept'
        $script:Result.Changes | Should -Not -Match 'Kept'
        @($script:Result.Manual | Where-Object Key -EQ 'Kept').Count | Should -Be 0
    }

    It 'never removes or creates either side of a possible rename; both go to Manual with the hint' {
        $script:Result.Removals | Should -Not -Match 'Team Alpha'
        $script:Result.Changes | Should -Not -Match 'Team Alpha'
        $sides = @($script:Result.Manual | Where-Object { $_.Key -like 'Team Alpha*' })
        $sides.Count | Should -Be 2
        @($sides | Where-Object Key -EQ 'Team Alpha').Action | Should -Be 'Create'
        @($sides | Where-Object Key -EQ 'Team Alpha 2').Action | Should -Be 'Remove'
        $sides | ForEach-Object { $_.Reason | Should -BeLike '*Possible rename*' }
    }

    It 'writes nothing of a type the check did not read, on either side' {
        $script:Result.Changes | Should -Not -Match 'EXOMailTips'
        $script:Result.Removals | Should -Not -Match 'EXOMailTips'
        @($script:Result.Manual | Where-Object ResourceType -EQ 'EXOMailTips').Count | Should -Be 0
    }

    It 'lists the item that needs an ignored property in Manual with the reason, and still generates the rest' {
        $hidden = @($script:Result.Manual | Where-Object Key -EQ 'Hidden')
        $hidden.Count | Should -Be 1
        $hidden[0].ResourceType | Should -Be 'AADGroup'
        $hidden[0].Action | Should -Be 'Create'
        $hidden[0].Reason | Should -BeLike '*Members*ignored/secret*'
        $script:Result.Changes | Should -Not -Match 'Hidden'
        $script:Result.Changes | Should -Not -Match 'someone@acme\.example'
    }

    It 'stamps both files with the pinned module version and writes credentials only as configuration data references' {
        $pinned = & (Get-Module PolicyEngine) { Get-PEPinnedVersion -Name Microsoft365DSC }
        $pinned | Should -Be '2.26.1021.1'
        foreach ($text in $script:Result.Changes, $script:Result.Removals)
        {
            $text | Should -Match "Import-DscResource -ModuleName 'Microsoft365DSC' -ModuleVersion '2.26.1021.1'"
            foreach ($name in 'ApplicationId', 'TenantId', 'CertificateThumbprint')
            {
                $assignments = @([regex]::Matches($text, "(?m)^\s+$name\s+= (.+);\s*$") | ForEach-Object { $_.Groups[1].Value })
                $assignments.Count | Should -BeGreaterThan 0
                $assignments | ForEach-Object { $_ | Should -BeExactly ('$ConfigurationData.NonNodeData.' + $name) }
            }
            $text | Should -Not -Match 'acme\.example'
        }
    }

    It 'starts both files with how to run them: dot-source, call with the configuration data, Changes before Removals' {
        foreach ($pair in @(@('PE_Changes', $script:Result.Changes), @('PE_Removals', $script:Result.Removals)))
        {
            $name, $text = $pair
            $head = ($text -split "`n" | Select-Object -First 12) -join "`n"
            $head | Should -Match "(?m)^# $name brings tenant 'acme' in line with its blueprint 'acme' v1 \(check 20261025-100000\)\."
            $head | Should -Match '(?m)^# Needs Microsoft365DSC 2.26.1021.1'
            $head | Should -Match '(?m)^#\s+\. \.\\<this file>\.ps1$'
            $head | Should -Match "(?m)^#\s+$name -ConfigurationData \.\\ConfigurationData\.psd1 -OutputPath \.\\$name$"
            $head | Should -Match "(?m)^#\s+Start-DscConfiguration -Path \.\\$name -Wait -Verbose"
            $head | Should -Match 'NonNodeData holds ApplicationId, TenantId, CertificateThumbprint and OrganizationName'
            $head | Should -Match '(?m)^# Apply PE_Changes before PE_Removals, and review every block of PE_Removals first: it deletes objects\.$'
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors) | Out-Null
            @($errors).Count | Should -Be 0
        }
        $script:Result.BlueprintVersion | Should -Be 1
        $script:Result.CheckBlueprintVersion | Should -Be 1
    }

    It 'stores nothing: no decision, check or blueprint version is added' {
        @(Get-PEDecision -Kind Remove -DataRoot $script:Temp).Count | Should -Be 0
        @(Get-ChildItem (Join-Path $script:Temp 'checks') -Directory).Count | Should -Be 1
        Test-Path (Join-Path $script:Temp 'audit') | Should -BeFalse
    }
}

Describe 'New-PEOfflineConfig without drift or without a blueprint of its own' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-offcfg-' + [guid]::NewGuid())
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'gives no files when the tenant matches its blueprint, for a live tenant as for an offline one' {
        Add-TestTenant -Root $script:Temp -Slug 'live' -Own @((New-TestGroup 'Sales')) -Target (New-TestState -Records @((New-TestGroup 'Sales')))
        (Get-PETenant -Slug 'live' -DataRoot $script:Temp).Offline | Should -BeFalse
        $result = New-PEOfflineConfig -Tenant 'live' -DataRoot $script:Temp
        $result.Changes | Should -BeNullOrEmpty
        $result.Removals | Should -BeNullOrEmpty
        @($result.Manual).Count | Should -Be 0
        $result.BlueprintName | Should -Be 'live'
    }

    It 'gives no Removals when there is nothing to remove, and no Changes when there is nothing to change' {
        Add-TestTenant -Root $script:Temp -Slug 'live' -Own @((New-TestGroup 'Sales')) -Target (New-TestState -Records @((New-TestGroup 'Sales'), (New-TestGroup 'Unmanaged one')))
        Set-PEDecision -Kind Unmanaged -ResourceType 'AADGroup' -Key 'Unmanaged one' -Reason 'kept' -Tenant 'live' -DataRoot $script:Temp | Out-Null
        $result = New-PEOfflineConfig -Tenant 'live' -DataRoot $script:Temp
        $result.Changes | Should -BeNullOrEmpty
        $result.Removals | Should -BeNullOrEmpty
    }

    It 'removes nothing that was moved into the blueprint after the check, although the stored check still lists it as target-only' {
        Add-TestTenant -Root $script:Temp -Slug 'live' -Own @((New-TestGroup 'Sales'), (New-TestGroup 'Extra')) -CheckedAgainst @((New-TestGroup 'Sales')) -Target (New-TestState -Records @((New-TestGroup 'Sales'), (New-TestGroup 'Extra')))
        @((Get-PECheck -Latest -Kind Full -Tenant 'live' -DataRoot $script:Temp).Findings | Where-Object { $_.Kind -eq 'TargetOnly' -and $_.Key -eq 'Extra' }).Count | Should -Be 1
        $result = New-PEOfflineConfig -Tenant 'live' -DataRoot $script:Temp
        $result.Removals | Should -BeNullOrEmpty
        @($result.Manual).Count | Should -Be 0
    }

    It 'refuses a check of another tenant than the one registered' {
        Add-TestTenant -Root $script:Temp -Slug 'live' -Own @((New-TestGroup 'Sales')) -Target (New-TestState -Records @((New-TestGroup 'Sales'), (New-TestGroup 'Extra')))
        Set-PETenant -Slug 'live' -TenantId 'other.example' -DataRoot $script:Temp | Out-Null
        { New-PEOfflineConfig -Tenant 'live' -DataRoot $script:Temp } | Should -Throw "*acme.example*other.example*"
    }

    It 'refuses a check a scope check patched, because which types it read cannot be told from its blueprint version' {
        $target = New-TestState -Records @((New-TestGroup 'Sales')) -ExtraMeta @{ PatchedFrom = '20261024-100000'; ScopeChecks = @{ groups = '2026-10-25T10:00:00Z' } }
        Add-TestTenant -Root $script:Temp -Slug 'live' -Own @((New-TestGroup 'Sales'), (New-TestGroup 'Gone')) -Target $target
        { New-PEOfflineConfig -Tenant 'live' -DataRoot $script:Temp } | Should -Throw '*20261025-100000*patched by a scope check*cannot be told*full check*'
    }

    It 'refuses when the blueprint version the check was made against cannot be read, naming the check and the version' {
        Add-TestTenant -Root $script:Temp -Slug 'live' -Own @((New-TestGroup 'Sales'), (New-TestGroup 'Gone')) -Target (New-TestState -Records @((New-TestGroup 'Sales'))) -CheckBlueprintVersion 9
        { New-PEOfflineConfig -Tenant 'live' -DataRoot $script:Temp } | Should -Throw "*20261025-100000*'live' v9*"
    }

    It 'refuses a tenant that follows only the master blueprint, saying how to give it one' {
        Set-PETenant -Slug 'plain' -Offline -TenantId 'plain.example' -Blueprints @('main') -DataRoot $script:Temp | Out-Null
        { New-PEOfflineConfig -Tenant 'plain' -DataRoot $script:Temp } | Should -Throw '*no blueprint of its own*first upload*blueprint*'
    }
}

Describe 'New-PEOfflineConfig when the blueprint gained types after the check' -Tag 'Slow' {
    It 'plans nothing of a type the check never read, and still creates a missing item of a type it did read' {
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-offcfg-' + [guid]::NewGuid())
        try
        {
            # v1 holds Entra only and the check (made against v1) read Entra only; v2 gains an Exchange accepted domain and one more group.
            Add-TestTenant -Root $temp -Slug 'acme' -Offline -Own @((New-TestGroup 'Sales')) -Target (New-TestState -Records @((New-TestGroup 'Sales')))
            $domain = [pscustomobject]@{ ResourceType = 'EXOAcceptedDomain'; Key = 'contoso.example'; Workload = 'Exchange Online'; Properties = [ordered]@{ Identity = 'contoso.example'; DomainType = 'Authoritative'; MatchSubDomains = $false; OutboundOnly = $false; Ensure = 'Present' } }
            $wanted = New-TestState -Records @((New-TestGroup 'Sales'), (New-TestGroup 'Later'), $domain)
            $changes = @(Get-PEBlueprintChange -Name 'acme' -MasterState $wanted -DataRoot $temp)
            Approve-PEBlueprintChange -Name 'acme' -MasterState $wanted -Accept $changes -Reason 'moved in' -DataRoot $temp | Should -Be 2

            $result = New-PEOfflineConfig -Tenant 'acme' -DataRoot $temp
            $result.Changes | Should -Not -Match 'EXOAcceptedDomain'
            $result.Changes | Should -Not -Match 'contoso\.example'
            @($result.Manual | Where-Object ResourceType -EQ 'EXOAcceptedDomain').Count | Should -Be 0
            Get-Block $result.Changes 'Later' | Should -Match "Ensure\s+= 'Present';"
            $result.Changes | Should -Match 'Resource instances: 1\.'
            $result.BlueprintVersion | Should -Be 2
            $result.CheckBlueprintVersion | Should -Be 1
        }
        finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'New-PEOfflineConfig after an upload folded into an earlier one' -Tag 'Slow' {
    It 'generates from the folded check as usual' {
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-offcfg-' + [guid]::NewGuid())
        try
        {
            $dir = Join-Path $PSScriptRoot 'fixtures\upload'
            $file = { param ($n) [pscustomobject]@{ Name = $n; Text = Get-Content -LiteralPath (Join-Path $dir $n) -Raw } }
            Set-PETenant -Slug 'acme' -Offline -Blueprints @('main') -DataRoot $temp | Out-Null
            # The first upload (Entra and Exchange) becomes the own blueprint and the check; the second (Entra only, drifted) is folded into it.
            New-PEUploadCheck -Tenant 'acme' -File @((& $file 'entra.ps1'), (& $file 'exchange.ps1')) -TenantDomain 'acme.example' -DataRoot $temp | Out-Null
            Initialize-PETenantBlueprint -Slug 'acme' -MasterBlueprint 'main' -FromCheck -DataRoot $temp | Out-Null
            Start-Sleep -Seconds 1
            New-PEUploadCheck -Tenant 'acme' -File @((& $file 'entra.ps1'), (& $file 'exchange.ps1')) -DataRoot $temp | Out-Null
            Start-Sleep -Seconds 1
            $folded = New-PEUploadCheck -Tenant 'acme' -File @((& $file 'entra-drift.ps1')) -DataRoot $temp
            $check = Get-PECheck -CheckId $folded.CheckId -DataRoot $temp
            $check.State.Meta.PatchedFrom | Should -Not -BeNullOrEmpty
            $check.State.Meta.PSObject.Properties['ScopeChecks'] | Should -BeNullOrEmpty

            $result = New-PEOfflineConfig -Tenant 'acme' -DataRoot $temp
            $result.CheckId | Should -Be $folded.CheckId
            Get-Block $result.Changes 'Finance' | Should -Match "Ensure\s+= 'Present';"
            Get-Block $result.Changes 'Sales' | Should -Match "MailNickname\s+= 'sales';"
            Get-Block $result.Removals 'Marketing' | Should -Match "Ensure\s+= 'Absent';"
            $result.Changes | Should -Not -Match 'EXOAcceptedDomain'
            @($result.Manual).Count | Should -Be 0
        }
        finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'New-PEOfflineConfig after uploads of only some workloads' -Tag 'Slow' {
    BeforeAll {
        $script:Dir = Join-Path $PSScriptRoot 'fixtures\upload'
        $script:File = { param ($n) [pscustomobject]@{ Name = $n; Text = Get-Content -LiteralPath (Join-Path $script:Dir $n) -Raw } }
        function New-MainBlueprint
        {
            # The master blueprint 'main': the fixtures' records plus -Extra records, taken from tenant m.example.
            param ([string]$Root, [object[]]$Extra = @())
            $records = @(& (Get-Module PolicyEngine) {
                    param ($d)
                    foreach ($n in 'entra.ps1', 'exchange.ps1') { Read-PEExport -Path (Join-Path $d $n) -TenantId 'm.example' | ForEach-Object { ConvertTo-PENormalizedRecord -Record $_ } }
                } $script:Dir) + $Extra
            Initialize-PEBlueprint -Name 'main' -State (New-TestState -Records $records) -DataRoot $Root | Out-Null
        }
    }

    It 'creates nothing of a type moved into the own blueprint that the kept workload''s check never read' {
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-offcfg-' + [guid]::NewGuid())
        try
        {
            # Entra and Exchange are uploaded and become the own blueprint; an Exchange sharing policy no upload holds is then moved
            # from main into it (v2); then Entra alone is uploaded. Exchange is kept from a check that never read sharing policies.
            New-MainBlueprint -Root $temp -Extra @([pscustomobject]@{ ResourceType = 'EXOSharingPolicy'; Key = 'Default Sharing Policy'; Workload = 'Exchange Online'; Properties = [ordered]@{ Name = 'Default Sharing Policy'; Enabled = $true; Ensure = 'Present' } })
            Set-PETenant -Slug 'acme' -Offline -Blueprints @('main') -DataRoot $temp | Out-Null
            New-PEUploadCheck -Tenant 'acme' -File @((& $script:File 'entra.ps1'), (& $script:File 'exchange.ps1')) -TenantDomain 'acme.example' -DataRoot $temp | Out-Null
            Initialize-PETenantBlueprint -Slug 'acme' -MasterBlueprint 'main' -FromCheck -DataRoot $temp | Out-Null
            Start-Sleep -Seconds 1
            New-PEUploadCheck -Tenant 'acme' -File @((& $script:File 'entra.ps1'), (& $script:File 'exchange.ps1')) -DataRoot $temp | Out-Null
            Move-PEBlueprintItem -From 'main' -To 'acme' -Item @([pscustomobject]@{ ResourceType = 'EXOSharingPolicy'; Key = 'Default Sharing Policy' }) -Reason 'wanted' -ExpectedVersion 1 -DataRoot $temp | Out-Null
            Start-Sleep -Seconds 1
            New-PEUploadCheck -Tenant 'acme' -File @((& $script:File 'entra.ps1')) -DataRoot $temp | Out-Null

            $result = New-PEOfflineConfig -Tenant 'acme' -DataRoot $temp
            $result.Changes | Should -Not -Match 'EXOSharingPolicy'
            $result.Changes | Should -Not -Match 'Default Sharing Policy'
            @($result.Manual | Where-Object ResourceType -EQ 'EXOSharingPolicy').Count | Should -Be 0
        }
        finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'removes nothing of a type the own blueprint has no records of, and lists those items in Manual' {
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-offcfg-' + [guid]::NewGuid())
        try
        {
            # The own blueprint is seeded from an Entra-only upload; the next upload holds Entra and Exchange, so every Exchange
            # object is target-only of a type the own blueprint never managed.
            New-MainBlueprint -Root $temp
            Set-PETenant -Slug 'acme' -Offline -Blueprints @('main') -DataRoot $temp | Out-Null
            New-PEUploadCheck -Tenant 'acme' -File @((& $script:File 'entra.ps1')) -TenantDomain 'acme.example' -DataRoot $temp | Out-Null
            Initialize-PETenantBlueprint -Slug 'acme' -MasterBlueprint 'main' -FromCheck -DataRoot $temp | Out-Null
            Start-Sleep -Seconds 1
            New-PEUploadCheck -Tenant 'acme' -File @((& $script:File 'entra-drift.ps1'), (& $script:File 'exchange.ps1')) -DataRoot $temp | Out-Null

            $result = New-PEOfflineConfig -Tenant 'acme' -DataRoot $temp
            $result.Removals | Should -Not -Match 'EXOAcceptedDomain'
            $manual = @($result.Manual | Where-Object ResourceType -EQ 'EXOAcceptedDomain')
            $manual.Count | Should -Be 1
            $manual[0].Action | Should -Be 'Remove'
            $manual[0].Reason | Should -BeLike "type 'EXOAcceptedDomain' has no records in the blueprint, so nothing says the tenant should not have these*remove by hand*"
            $result.NoBlueprintTypeCount | Should -Be 1
            # A target-only item of a type the blueprint does manage is still removed (Marketing is in entra-drift.ps1 only).
            Get-Block $result.Removals 'Marketing' | Should -Match "Ensure\s+= 'Absent';"
        }
        finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'New-PEOfflineConfig for a live tenant' -Tag 'Slow' {
    It 'generates a removal for a connected tenant just the same' {
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-offcfg-' + [guid]::NewGuid())
        try
        {
            Add-TestTenant -Root $temp -Slug 'live' -Own @((New-TestGroup 'Sales')) -Target (New-TestState -Records @((New-TestGroup 'Sales'), (New-TestGroup 'Extra')))
            $result = New-PEOfflineConfig -Tenant 'live' -DataRoot $temp
            $result.Changes | Should -BeNullOrEmpty
            Get-Block $result.Removals 'Extra' | Should -Match "Ensure\s+= 'Absent';"
        }
        finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
