BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force

    function New-TestRecord
    {
        param ([string]$Type = 'AADGroup', [string]$Key, [hashtable]$Props = @{})
        $p = [ordered]@{ DisplayName = $Key }
        foreach ($k in $Props.Keys) { $p[$k] = $Props[$k] }
        [pscustomobject]@{ ResourceType = $Type; Key = $Key; Workload = 'Entra ID'; TenantId = 't'; Properties = $p }
    }

    function New-TestState
    {
        param ([object[]]$Records = @(), [object[]]$NotChecked = @())
        & (Get-Module PolicyEngine) {
            param ($r, $n)
            New-PEState -Records $r -NotChecked $n -Meta @{ TenantId = 't'; ExportedAt = '2026-10-21T01:02:03Z'; Source = 'test' }
        } $Records $NotChecked
    }
}

Describe 'Blueprints' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-' + [guid]::NewGuid())
        $script:Base = New-TestState -Records @((New-TestRecord -Key 'g1' -Props @{ Description = 'one'; Created = '2026-01-02T03:04:05Z' }), (New-TestRecord -Key 'g2'))
    }

    AfterEach {
        if (Test-Path $script:Temp)
        {
            Remove-Item $script:Temp -Recurse -Force
        }
    }

    Context 'Initialize and Get' {
        It 'Initialize creates v1 and refuses to overwrite' {
            Initialize-PEBlueprint -Name 'main' -State $script:Base -DataRoot $script:Temp | Should -Be 1
            Test-Path (Join-Path $script:Temp 'blueprints\main\v0001.json') | Should -BeTrue
            { Initialize-PEBlueprint -Name 'main' -State $script:Base -DataRoot $script:Temp } | Should -Throw '*already exists*'
        }

        It 'Initialize writes Meta.Version 1 into v0001, keeping the other Meta values, and leaves the input state untouched' {
            Initialize-PEBlueprint -Name 'main' -State $script:Base -DataRoot $script:Temp | Out-Null
            $v1 = Get-PEBlueprint -Name 'main' -Version 1 -DataRoot $script:Temp
            $v1.Meta.Version | Should -Be 1
            $v1.Meta.TenantId | Should -Be $script:Base.Meta.TenantId
            $script:Base.Meta.Keys | Should -Not -Contain 'Version'
            $raw = Get-Content (Join-Path $script:Temp 'blueprints\main\v0001.json') -Raw | ConvertFrom-Json
            $raw.Meta.Version | Should -Be 1
        }

        It 'Get-PEBlueprint latest returns the highest version' {
            Initialize-PEBlueprint -Name 'main' -State $script:Base -DataRoot $script:Temp | Out-Null
            $master = New-TestState -Records @($script:Base.Records + (New-TestRecord -Key 'g3'))
            $f = @(Get-PEBlueprintChange -Name 'main' -MasterState $master -DataRoot $script:Temp)
            Approve-PEBlueprintChange -Name 'main' -MasterState $master -Accept $f -Reason 'add g3' -DataRoot $script:Temp | Should -Be 2
            @((Get-PEBlueprint -Name 'main' -Version 'latest' -DataRoot $script:Temp).Records).Count | Should -Be 3
            @((Get-PEBlueprint -Name 'main' -Version 1 -DataRoot $script:Temp).Records).Count | Should -Be 2
            @((Get-PEBlueprint -Name 'main' -DataRoot $script:Temp).Records).Count | Should -Be 3
        }

        It 'throws clear errors for a missing blueprint or version' {
            { Get-PEBlueprint -Name 'nope' -DataRoot $script:Temp } | Should -Throw '*not found*'
            Initialize-PEBlueprint -Name 'main' -State $script:Base -DataRoot $script:Temp | Out-Null
            { Get-PEBlueprint -Name 'main' -Version 7 -DataRoot $script:Temp } | Should -Throw '*version 7*'
        }

        It 'rejects names that could escape the blueprint folder' {
            { Initialize-PEBlueprint -Name '..\x' -State $script:Base -DataRoot $script:Temp } | Should -Throw
        }

        It 'rejects invalid or reserved name <Name>' -ForEach @(
            @{ Name = 'bad.' }, @{ Name = 'bad ' }, @{ Name = "ok`n" }, @{ Name = 'CON' }, @{ Name = 'nul' }, @{ Name = 'Com1' }, @{ Name = 'LPT9' }, @{ Name = 'aux.txt' }
        ) {
            { Initialize-PEBlueprint -Name $Name -State $script:Base -DataRoot $script:Temp } | Should -Throw
        }

        It 'a saved blueprint compares clean against an equal state (dates stay strings)' {
            Initialize-PEBlueprint -Name 'main' -State $script:Base -DataRoot $script:Temp | Out-Null
            @(Get-PEBlueprintChange -Name 'main' -MasterState $script:Base -DataRoot $script:Temp).Count | Should -Be 0
        }
    }

    Context 'Get-PEBlueprintChange' {
        BeforeEach {
            Initialize-PEBlueprint -Name 'main' -State $script:Base -DataRoot $script:Temp | Out-Null
        }

        It 'reports a new master record as Missing relative to the blueprint' {
            $master = New-TestState -Records @($script:Base.Records + (New-TestRecord -Key 'g3'))
            $f = @(Get-PEBlueprintChange -Name 'main' -MasterState $master -DataRoot $script:Temp)
            $f.Count | Should -Be 1
            $f[0].Kind | Should -Be 'Missing'
            $f[0].Key | Should -Be 'g3'
        }

        It 'reports a record gone from the master as TargetOnly and a modified one as Changed' {
            $master = New-TestState -Records @((New-TestRecord -Key 'g1' -Props @{ Description = 'two'; Created = '2026-01-02T03:04:05Z' }))
            $f = @(Get-PEBlueprintChange -Name 'main' -MasterState $master -DataRoot $script:Temp)
            ($f | Where-Object Key -eq 'g2').Kind | Should -Be 'TargetOnly'
            ($f | Where-Object Key -eq 'g1').Kind | Should -Be 'Changed'
        }
    }

    Context 'Approve-PEBlueprintChange' {
        BeforeEach {
            Initialize-PEBlueprint -Name 'main' -State $script:Base -DataRoot $script:Temp | Out-Null
            $script:Master = New-TestState -Records @(
                (New-TestRecord -Key 'g1' -Props @{ Description = 'two'; Created = '2026-01-02T03:04:05Z' }),
                (New-TestRecord -Key 'g3'))
            $script:Findings = @(Get-PEBlueprintChange -Name 'main' -MasterState $script:Master -DataRoot $script:Temp)
        }

        It 'applies Missing, TargetOnly and Changed' {
            Approve-PEBlueprintChange -Name 'main' -MasterState $script:Master -Accept $script:Findings -Reason 'sync' -DataRoot $script:Temp | Should -Be 2
            $v2 = Get-PEBlueprint -Name 'main' -Version 2 -DataRoot $script:Temp
            $keys = @($v2.Records | ForEach-Object Key | Sort-Object)
            $keys | Should -Be @('g1', 'g3')
            ($v2.Records | Where-Object Key -eq 'g1').Properties.Description | Should -Be 'two'
            @(Get-PEBlueprintChange -Name 'main' -MasterState $script:Master -DataRoot $script:Temp).Count | Should -Be 0
        }

        It 'Approve with a subset of changes leaves the others out of the new version' {
            $only = @($script:Findings | Where-Object Kind -eq 'Missing')
            Approve-PEBlueprintChange -Name 'main' -MasterState $script:Master -Accept $only -Reason 'only add' -DataRoot $script:Temp | Out-Null
            $v2 = Get-PEBlueprint -Name 'main' -Version 2 -DataRoot $script:Temp
            @($v2.Records | ForEach-Object Key | Sort-Object) | Should -Be @('g1', 'g2', 'g3')
            ($v2.Records | Where-Object Key -eq 'g1').Properties.Description | Should -Be 'one'
            $left = @(Get-PEBlueprintChange -Name 'main' -MasterState $script:Master -DataRoot $script:Temp)
            $left.Count | Should -Be 2
        }

        It 'older versions are never modified' {
            $path = Join-Path $script:Temp 'blueprints\main\v0001.json'
            $before = (Get-FileHash $path).Hash
            Approve-PEBlueprintChange -Name 'main' -MasterState $script:Master -Accept $script:Findings -Reason 'sync' -DataRoot $script:Temp | Out-Null
            (Get-FileHash $path).Hash | Should -Be $before
        }

        It 'replaces an orphaned change record from a failed attempt and succeeds on retry' {
            $dir = Join-Path $script:Temp 'blueprints\main'
            New-Item -ItemType Directory -Path (Join-Path $dir 'changes') -Force | Out-Null
            Set-Content (Join-Path $dir 'changes\v0002.json') 'x'
            Approve-PEBlueprintChange -Name 'main' -MasterState $script:Master -Accept $script:Findings -Reason 'retry' -WarningAction SilentlyContinue -DataRoot $script:Temp | Should -Be 2
            (Get-Content (Join-Path $dir 'changes\v0002.json') -Raw | ConvertFrom-Json).Reason | Should -Be 'retry'
            Test-Path (Join-Path $dir 'v0002.json') | Should -BeTrue
        }

        It 'ignores leftover tmp files and leaves no new tmp file after writing' {
            $dir = Join-Path $script:Temp 'blueprints\main'
            Set-Content (Join-Path $dir 'v0009.json.abc.tmp') 'garbage'
            @((Get-PEBlueprint -Name 'main' -DataRoot $script:Temp).Records).Count | Should -Be 2
            Approve-PEBlueprintChange -Name 'main' -MasterState $script:Master -Accept $script:Findings -Reason 'x' -DataRoot $script:Temp | Should -Be 2
            @(Get-ChildItem $dir -Recurse -Filter '*.tmp' | Where-Object Name -ne 'v0009.json.abc.tmp').Count | Should -Be 0
        }

        It 'a pre-existing lock makes Approve throw and leaves the blueprint untouched' {
            $dir = Join-Path $script:Temp 'blueprints\main'
            Set-Content (Join-Path $dir '.lock') 'someone'
            { Approve-PEBlueprintChange -Name 'main' -MasterState $script:Master -Accept $script:Findings -Reason 'x' -DataRoot $script:Temp } | Should -Throw '*Another approval is in progress*delete the lock file*'
            Test-Path (Join-Path $dir '.lock') | Should -BeTrue
            Test-Path (Join-Path $dir 'v0002.json') | Should -BeFalse
            Test-Path (Join-Path $dir 'changes') | Should -BeFalse
            @((Get-PEBlueprint -Name 'main' -DataRoot $script:Temp).Records).Count | Should -Be 2
        }

        It 'releases the lock after success and after a validation error' {
            $dir = Join-Path $script:Temp 'blueprints\main'
            Approve-PEBlueprintChange -Name 'main' -MasterState $script:Master -Accept $script:Findings -Reason 'x' -DataRoot $script:Temp | Out-Null
            Test-Path (Join-Path $dir '.lock') | Should -BeFalse
            $forged = [pscustomobject]@{ Kind = 'Missing'; ResourceType = 'AADGroup'; Key = 'ghost' }
            { Approve-PEBlueprintChange -Name 'main' -MasterState $script:Master -Accept @($forged) -Reason 'x' -DataRoot $script:Temp } | Should -Throw '*not part of the current*'
            Test-Path (Join-Path $dir '.lock') | Should -BeFalse
            @((Get-PEBlueprint -Name 'main' -DataRoot $script:Temp -Version latest).Records).Count | Should -Be 2
        }

        It 'reads ExportedAt and Source from a master whose Meta is a PSCustomObject' {
            $master = [pscustomobject]@{
                Records    = @($script:Base.Records + (New-TestRecord -Key 'g3'))
                NotChecked = @()
                Meta       = [pscustomobject]@{ TenantId = 't'; ExportedAt = '2028-01-02T03:04:05Z'; Source = 'json' }
            }
            $f = @(Get-PEBlueprintChange -Name 'main' -MasterState $master -DataRoot $script:Temp)
            Approve-PEBlueprintChange -Name 'main' -MasterState $master -Accept $f -Reason 'x' -DataRoot $script:Temp | Out-Null
            $v2 = Get-PEBlueprint -Name 'main' -Version 2 -DataRoot $script:Temp
            $v2.Meta.ExportedAt | Should -Be '2028-01-02T03:04:05Z'
            $v2.Meta.Source | Should -Be 'json'
            (Get-Content (Join-Path $script:Temp 'blueprints\main\changes\v0002.json') -Raw | ConvertFrom-Json -DateKind String).MasterExportedAt | Should -Be '2028-01-02T03:04:05Z'
        }

        It 'a truncated committed version file still throws loudly' {
            $dir = Join-Path $script:Temp 'blueprints\main'
            Set-Content (Join-Path $dir 'v0002.json') '{ "Records": [ '
            { Get-PEBlueprint -Name 'main' -DataRoot $script:Temp } | Should -Throw
        }

        It 'clears NotChecked types that the master now exports, and their records become findings' {
            $nc = @([pscustomobject]@{ ResourceType = 'EXOMailbox'; Reason = 'no access' })
            Initialize-PEBlueprint -Name 'nc' -State (New-TestState -Records @($script:Base.Records) -NotChecked $nc) -DataRoot $script:Temp | Out-Null
            $mailbox = New-TestRecord -Type 'EXOMailbox' -Key 'm1'
            $master = New-TestState -Records @($script:Base.Records + (New-TestRecord -Key 'g3') + $mailbox)
            $f = @(Get-PEBlueprintChange -Name 'nc' -MasterState $master -DataRoot $script:Temp)
            $g3 = @($f | Where-Object Key -eq 'g3')
            Approve-PEBlueprintChange -Name 'nc' -MasterState $master -Accept $g3 -Reason 'x' -DataRoot $script:Temp | Out-Null
            @((Get-PEBlueprint -Name 'nc' -DataRoot $script:Temp).NotChecked).Count | Should -Be 0
            $after = @(Get-PEBlueprintChange -Name 'nc' -MasterState $master -DataRoot $script:Temp)
            $after.Count | Should -Be 1
            $after[0].Kind | Should -Be 'Missing'
            $after[0].Key | Should -Be 'm1'
        }

        It 'keeps NotChecked types that are still not checked in the master' {
            $nc = @([pscustomobject]@{ ResourceType = 'EXOMailbox'; Reason = 'no access' })
            Initialize-PEBlueprint -Name 'nc' -State (New-TestState -Records @($script:Base.Records) -NotChecked $nc) -DataRoot $script:Temp | Out-Null
            $master = New-TestState -Records @($script:Base.Records + (New-TestRecord -Key 'g3')) -NotChecked $nc
            $f = @(Get-PEBlueprintChange -Name 'nc' -MasterState $master -DataRoot $script:Temp | Where-Object Key -eq 'g3')
            Approve-PEBlueprintChange -Name 'nc' -MasterState $master -Accept $f -Reason 'x' -DataRoot $script:Temp | Out-Null
            @((Get-PEBlueprint -Name 'nc' -DataRoot $script:Temp).NotChecked).Count | Should -Be 1
        }

        It 'takes ExportedAt and Source from the master and records them in the change record' {
            $master = & (Get-Module PolicyEngine) {
                param ($r)
                New-PEState -Records $r -NotChecked @() -Meta @{ TenantId = 't'; ExportedAt = '2027-05-06T07:08:09Z'; Source = 'newsrc' }
            } @($script:Base.Records + (New-TestRecord -Key 'g3'))
            $f = @(Get-PEBlueprintChange -Name 'main' -MasterState $master -DataRoot $script:Temp)
            Approve-PEBlueprintChange -Name 'main' -MasterState $master -Accept $f -Reason 'x' -DataRoot $script:Temp | Out-Null
            $v2 = Get-PEBlueprint -Name 'main' -Version 2 -DataRoot $script:Temp
            $v2.Meta.ExportedAt | Should -Be '2027-05-06T07:08:09Z'
            $v2.Meta.Source | Should -Be 'newsrc'
            $v2.Meta.Version | Should -Be 2
            (Get-Content (Join-Path $script:Temp 'blueprints\main\changes\v0002.json') -Raw | ConvertFrom-Json -DateKind String).MasterExportedAt | Should -Be '2027-05-06T07:08:09Z'
        }

        It 'each approval writes a change record with reason, timestamp and user' {
            $env:USERNAME = 'tester'
            Approve-PEBlueprintChange -Name 'main' -MasterState $script:Master -Accept $script:Findings -Reason 'because' -DataRoot $script:Temp | Out-Null
            $rec = Get-Content (Join-Path $script:Temp 'blueprints\main\changes\v0002.json') -Raw | ConvertFrom-Json -DateKind String
            $rec.Version | Should -Be 2
            $rec.Reason | Should -Be 'because'
            $rec.User | Should -Be 'tester'
            $rec.At | Should -Match '^\d{4}-\d\d-\d\dT.*Z$'
            @($rec.Changes).Count | Should -Be 3
            $c = $rec.Changes | Where-Object Key -eq 'g1'
            $c.Kind | Should -Be 'Changed'
            $c.ResourceType | Should -Be 'AADGroup'
            $c.Workload | Should -Be 'Entra ID'
            @($c.Differences | ForEach-Object Property) | Should -Contain 'Description'
        }

        It 'Approve with no findings throws' {
            { Approve-PEBlueprintChange -Name 'main' -MasterState $script:Master -Accept @() -Reason 'x' -DataRoot $script:Temp } | Should -Throw
            Test-Path (Join-Path $script:Temp 'blueprints\main\v0002.json') | Should -BeFalse
        }

        It 'rejects a finding that is not part of the current comparison' {
            $forged = [pscustomobject]@{ Kind = 'Missing'; ResourceType = 'AADGroup'; Key = 'ghost'; Workload = 'Entra ID'; Differences = @(); BlueprintRecord = (New-TestRecord -Key 'ghost') }
            { Approve-PEBlueprintChange -Name 'main' -MasterState $script:Master -Accept @($forged) -Reason 'x' -DataRoot $script:Temp } | Should -Throw '*not part of the current*'
            Test-Path (Join-Path $script:Temp 'blueprints\main\v0002.json') | Should -BeFalse
        }

        It 'rejects a stale finding after the master moved on' {
            $newMaster = New-TestState -Records @($script:Base.Records)
            { Approve-PEBlueprintChange -Name 'main' -MasterState $newMaster -Accept $script:Findings -Reason 'x' -DataRoot $script:Temp } | Should -Throw '*not part of the current*'
        }

        It 'uses the master record, not a record carried by the supplied finding' {
            $f = $script:Findings | Where-Object Kind -eq 'Missing'
            $f.BlueprintRecord = New-TestRecord -Key 'g3' -Props @{ DisplayName = 'tampered' }
            Approve-PEBlueprintChange -Name 'main' -MasterState $script:Master -Accept @($f) -Reason 'x' -DataRoot $script:Temp | Out-Null
            $v2 = Get-PEBlueprint -Name 'main' -Version 2 -DataRoot $script:Temp
            ($v2.Records | Where-Object Key -eq 'g3').Properties.DisplayName | Should -Be 'g3'
        }
    }

    Context 'Findings that cannot be accepted' {
        It 'rejects <Kind> findings with a resolve-first error' -ForEach @(
            @{ Kind = 'PossibleRename' }, @{ Kind = 'Ambiguous' }, @{ Kind = 'NotChecked' }, @{ Kind = 'NotAvailable' }, @{ Kind = 'Excluded' }, @{ Kind = 'Unkeyed' }
        ) {
            Initialize-PEBlueprint -Name 'main' -State $script:Base -DataRoot $script:Temp | Out-Null
            $f = [pscustomobject]@{ Kind = $Kind; ResourceType = 'AADGroup'; Key = 'g1'; Workload = 'Entra ID'; Differences = @() }
            { Approve-PEBlueprintChange -Name 'main' -MasterState $script:Base -Accept @($f) -Reason 'x' -DataRoot $script:Temp } | Should -Throw '*resolve*first*'
            Test-Path (Join-Path $script:Temp 'blueprints\main\v0002.json') | Should -BeFalse
        }

        It 'rejects a real PossibleRename produced by the comparison' {
            $mk = { param ($k) New-TestRecord -Key $k -Props @{ A = 1; B = 2; C = 3; D = 4; E = 5; F = 6; G = 7; H = 8; I = 9 } }
            Initialize-PEBlueprint -Name 'main' -State (New-TestState -Records @((& $mk 'old'))) -DataRoot $script:Temp | Out-Null
            $master = New-TestState -Records @((& $mk 'new'))
            $f = @(Get-PEBlueprintChange -Name 'main' -MasterState $master -DataRoot $script:Temp)
            @($f | Where-Object Kind -eq 'PossibleRename').Count | Should -Be 2
            { Approve-PEBlueprintChange -Name 'main' -MasterState $master -Accept $f -Reason 'x' -DataRoot $script:Temp } | Should -Throw '*resolve*first*'
        }
    }
}
