BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    Import-Module "$PSScriptRoot\..\gui\PEGui.psm1" -Force

    function New-TestRecord
    {
        param ([string]$Type = 'AADGroup', [string]$Key, [hashtable]$Props = @{}, [string]$Workload = 'Entra ID')
        $p = [ordered]@{ DisplayName = $Key }
        foreach ($k in $Props.Keys) { $p[$k] = $Props[$k] }
        [pscustomobject]@{ ResourceType = $Type; Key = $Key; Workload = $Workload; Properties = $p }
    }

    function New-TestState
    {
        param ([object[]]$Records = @(), [object[]]$NotChecked = @())
        & (Get-Module PolicyEngine) {
            param ($r, $n)
            New-PEState -Records $r -NotChecked $n -Meta @{ TenantId = 't'; ExportedAt = '2026-10-21T01:02:03Z'; Source = 'test' }
        } $Records $NotChecked
    }

    function Add-DevCheck
    {
        param ([string]$Blueprint)
        $state = New-TestState -Records @($script:LayerRecords + (New-TestRecord -Key 'DevExtra'))
        $findings = @(Compare-PEState -Blueprint (Get-PEBlueprint -Name $Blueprint -DataRoot $script:Temp) -Target $state)
        $directory = Join-Path $script:Temp 'checks\20261021-030000'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        [ordered]@{ CheckId = '20261021-030000'; Kind = 'Full'; TenantSlug = 'dev'; BlueprintName = $Blueprint; BlueprintVersion = 1; Findings = $findings; State = $state } |
            ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $directory 'result.json') -Encoding utf8
    }

    function Read-Json
    {
        param ($Root, $Relative)
        Get-Content -LiteralPath (Join-Path $Root $Relative) -Raw | ConvertFrom-Json -NoEnumerate -DateKind String
    }
}

Describe 'Export-PEGuiData' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-gui-' + [guid]::NewGuid())
        $script:Gui = Join-Path $script:Temp 'gui'
        $base = New-TestState -Records @(
            (New-TestRecord -Key 'Sales' -Props @{ Description = 'one' }),
            (New-TestRecord -Key 'Finance Team / EU'),
            (New-TestRecord -Type 'TeamsMeetingPolicy' -Key 'Global' -Workload 'Teams'),
            (New-TestRecord -Type 'EXOTransportRule' -Key 'Disclaimer' -Workload 'Exchange Online'))
        Initialize-PEBlueprint -Name 'main' -State $base -DataRoot $script:Temp | Out-Null

        $target = New-TestState -Records @(
            (New-TestRecord -Key 'Sales' -Props @{ Description = 'two' }),
            (New-TestRecord -Key 'Finance Team / EU'),
            (New-TestRecord -Key 'Extra'),
            (New-TestRecord -Type 'TeamsMeetingPolicy' -Key 'Global' -Workload 'Teams')) -NotChecked @([pscustomobject]@{ ResourceType = 'EXOTransportRule'; Reason = 'export failed: 404' })
        $findings = @(Compare-PEState -Blueprint (Get-PEBlueprint -Name 'main' -DataRoot $script:Temp) -Target $target)
        $directory = Join-Path $script:Temp 'checks\20261021-020000'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        [ordered]@{ CheckId = '20261021-020000'; Kind = 'Full'; BlueprintName = 'main'; BlueprintVersion = 1; Findings = $findings; State = $target } |
            ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $directory 'result.json') -Encoding utf8
        Set-PEDecision -Kind Unmanaged -ResourceType 'AADGroup' -Key 'Old Group' -Reason 'retired' -DataRoot $script:Temp | Out-Null
        Set-PEDecision -Kind Noise -ResourceType 'AADGroup' -Property 'Description' -Value 'x' -Reason 'noisy' -DataRoot $script:Temp | Out-Null

        $script:Result = Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui -TenantDisplayName 'contoso.example'
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'shows the stored name of the master even when a display name is passed' {
        Set-PETenant -Slug 'master' -DisplayName 'Production' -TenantId 'contoso.example' -DataRoot $script:Temp | Out-Null
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui -TenantDisplayName 'contoso.example' | Out-Null
        (Read-Json $script:Gui 'index.json').tenants[0].displayName | Should -Be 'Production'
    }

    Context 'Blueprint layers' {
        BeforeEach {
            $script:LayerRecords = @(
                (New-TestRecord -Key 'Sales' -Props @{ Description = 'one' }),
                (New-TestRecord -Key 'Finance Team / EU'),
                (New-TestRecord -Type 'TeamsMeetingPolicy' -Key 'Global' -Workload 'Teams'),
                (New-TestRecord -Type 'EXOTransportRule' -Key 'Disclaimer' -Workload 'Exchange Online'))
            Set-PETenant -Slug 'dev' -DisplayName 'Dev tenant' -DataRoot $script:Temp | Out-Null
        }

        It 'writes the version history of a tenant blueprint next to the master one, only for the blueprints a tenant follows' {
            Initialize-PEBlueprint -Name 'dev' -State (New-TestState -Records @($script:LayerRecords + (New-TestRecord -Key 'DevExtra'))) -DataRoot $script:Temp | Out-Null
            Set-PETenant -Slug 'dev' -Blueprints @('main', 'dev') -DataRoot $script:Temp | Out-Null
            Add-DevCheck -Blueprint 'dev'
            Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null

            $own = @(Read-Json $script:Gui 'blueprint\dev\versions.json')
            $own.version | Should -Be @(1)
            $own[0].source | Should -Be 'Initial'
            @(Read-Json $script:Gui 'blueprint\versions.json').Count | Should -BeGreaterThan 0
            Test-Path (Join-Path $script:Gui 'blueprint\main\versions.json') | Should -BeFalse -Because 'the master blueprint keeps blueprint\versions.json'
        }

        It 'reports drift against the master blueprint and against the tenant blueprint' {
            Initialize-PEBlueprint -Name 'dev' -State (New-TestState -Records @($script:LayerRecords + (New-TestRecord -Key 'DevExtra'))) -DataRoot $script:Temp | Out-Null
            Set-PETenant -Slug 'dev' -Blueprints @('main', 'dev') -DataRoot $script:Temp | Out-Null
            Add-DevCheck -Blueprint 'dev'
            Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null

            $layers = @(((Read-Json $script:Gui 'index.json').tenants | Where-Object tenantId -EQ 'dev').layers)
            $layers.name | Should -Be @('main', 'dev')
            $layers.role | Should -Be @('master', 'tenant')
            $layers.sameAsOwn | Should -Be @($false, $true)
            $layers.checked | Should -Be @($true, $true) -Because ($layers | ConvertTo-Json -Depth 3)
            $layers.version | Should -Be @(1, 1)
            $layers[0].drifted | Should -Be 1
            $layers[0].targetOnly | Should -Be 1
            $layers[1].drifted | Should -Be 0
            $layers[1].aligned | Should -Be ($layers[0].aligned + 1)

            $masterRows = @(Read-Json $script:Gui 'tenants\dev\layers\main\findings.json')
            @($masterRows | Where-Object { $_.kind -eq 'TargetOnly' -and $_.key -eq 'DevExtra' }).Count | Should -Be 1
            $masterRows[0].layer | Should -Be 'main'
            @(Read-Json $script:Gui 'tenants\dev\findings.json' | Where-Object { $_.state -eq 'Open' -and $_.kind -eq 'TargetOnly' }).Count | Should -Be 0
        }

        It 'writes the master layer''s side of an item only where it differs from the tenant blueprint, and a file for an item only the master blueprint has' {
            $ownRecords = @((New-TestRecord -Key 'Sales' -Props @{ Description = 'devver' }), (New-TestRecord -Type 'TeamsMeetingPolicy' -Key 'Global' -Workload 'Teams'), (New-TestRecord -Type 'EXOTransportRule' -Key 'Disclaimer' -Workload 'Exchange Online'))
            Initialize-PEBlueprint -Name 'dev' -State (New-TestState -Records $ownRecords) -DataRoot $script:Temp | Out-Null
            Set-PETenant -Slug 'dev' -Blueprints @('main', 'dev') -DataRoot $script:Temp | Out-Null
            $state = New-TestState -Records @((New-TestRecord -Key 'Sales' -Props @{ Description = 'one' }), (New-TestRecord -Type 'TeamsMeetingPolicy' -Key 'Global' -Workload 'Teams'), (New-TestRecord -Type 'EXOTransportRule' -Key 'Disclaimer' -Workload 'Exchange Online'))
            $directory = Join-Path $script:Temp 'checks\20261021-030000'
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            [ordered]@{ CheckId = '20261021-030000'; Kind = 'Full'; TenantSlug = 'dev'; BlueprintName = 'dev'; BlueprintVersion = 1; Findings = @(Compare-PEState -Blueprint (Get-PEBlueprint -Name 'dev' -DataRoot $script:Temp) -Target $state); State = $state } |
                ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $directory 'result.json') -Encoding utf8
            Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null

            $sales = Read-Json $script:Gui 'tenants\dev\items\AADGroup~Sales.json'
            $sales.blueprint.Description | Should -Be 'devver'
            $sales.layerBlueprints.main.Description | Should -Be 'one'

            $same = Read-Json $script:Gui 'tenants\dev\items\TeamsMeetingPolicy~Global.json'
            $same.layerBlueprints.PSObject.Properties.Name | Should -Not -Contain 'main'

            $id = & (Get-Module PolicyEngine) { ConvertTo-PEGuiItemId -ResourceType 'AADGroup' -Key 'Finance Team / EU' }
            $only = Read-Json $script:Gui "tenants\dev\items\$id.json"
            $only.blueprint | Should -BeNullOrEmpty
            $only.target | Should -BeNullOrEmpty
            $only.layerBlueprints.main.DisplayName | Should -Be 'Finance Team / EU'
            @(Read-Json $script:Gui 'tenants\dev\items.json' | Where-Object { $_.itemId -eq $id }).Count | Should -Be 0
        }

        It 'lists what could move between the master blueprint and the tenant blueprint, for a tenant with two layers only' {
            Initialize-PEBlueprint -Name 'dev' -State (New-TestState -Records @($script:LayerRecords + (New-TestRecord -Key 'DevExtra'))) -DataRoot $script:Temp | Out-Null
            Set-PETenant -Slug 'dev' -Blueprints @('main', 'dev') -DataRoot $script:Temp | Out-Null
            Add-DevCheck -Blueprint 'dev'
            Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null

            $moves = Read-Json $script:Gui (Join-Path (Join-Path 'tenants' 'dev') 'moves.json')
            $moves.master.name | Should -Be 'main'
            $moves.own.name | Should -Be 'dev'
            $moves.master.version | Should -Be 1
            $moves.own.version | Should -Be 1
            @($moves.up).Count | Should -Be 1
            $moves.up[0].key | Should -Be 'DevExtra'
            $moves.up[0].op | Should -Be 'Added'
            $moves.up[0].itemId | Should -Be 'AADGroup~DevExtra'
            @($moves.down).Count | Should -Be 1
            $moves.down[0].op | Should -Be 'Removed'
            Test-Path (Join-Path (Join-Path (Join-Path $script:Gui 'tenants') 'master') 'moves.json') | Should -BeFalse
        }

        It 'lists every layer of a tenant that was never checked as not checked' {
            Initialize-PEBlueprint -Name 'dev' -State (New-TestState -Records $script:LayerRecords) -DataRoot $script:Temp | Out-Null
            Set-PETenant -Slug 'dev' -Blueprints @('main', 'dev') -DataRoot $script:Temp | Out-Null
            Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
            $layers = @(((Read-Json $script:Gui 'index.json').tenants | Where-Object tenantId -EQ 'dev').layers)
            $layers.name | Should -Be @('main', 'dev')
            $layers.checked | Should -Be @($false, $false)
            $layers.drifted | Should -Be @(0, 0)
        }

        It 'gives a tenant with no stored list the master blueprint as its only layer' {
            Add-DevCheck -Blueprint 'main'
            Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
            $layers = @(((Read-Json $script:Gui 'index.json').tenants | Where-Object tenantId -EQ 'dev').layers)
            $layers.Count | Should -Be 1
            $layers[0].name | Should -Be 'main'
            $layers[0].sameAsOwn | Should -BeTrue
            $layers[0].checked | Should -BeTrue
            $layers[0].drifted | Should -Be 1
        }

        It 'exports a first upload whose check has no blueprint and still shows the master layer drift' {
            $state = New-TestState -Records @($script:LayerRecords + (New-TestRecord -Key 'DevExtra'))
            $directory = Join-Path $script:Temp 'checks\20261021-030000'
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            [ordered]@{ CheckId = '20261021-030000'; Kind = 'Full'; TenantSlug = 'dev'; BlueprintName = $null; BlueprintTenantId = ''; CrossTenant = $false; BlueprintVersion = $null; Findings = @(); State = $state } |
                ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $directory 'result.json') -Encoding utf8
            Set-PETenant -Slug 'dev' -Blueprints @('main') -DataRoot $script:Temp | Out-Null
            { Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null } | Should -Not -Throw
            $entry = (Read-Json $script:Gui 'index.json').tenants | Where-Object tenantId -EQ 'dev'
            $entry.lastFullCheck | Should -Not -BeNullOrEmpty
            $entry.layers[0].checked | Should -BeTrue -Because ($entry.layers | ConvertTo-Json -Depth 3)
            $entry.layers[0].targetOnly | Should -Be 1
            (Read-Json $script:Gui 'tenants\dev\findings.json').Count | Should -Be 0
        }

        It 'exports the same check after it seeded the tenant blueprint, with the master layer drift and no drift against the own layer' {
            $state = New-TestState -Records @($script:LayerRecords + (New-TestRecord -Key 'DevExtra'))
            $directory = Join-Path $script:Temp 'checks\20261021-030000'
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            [ordered]@{ CheckId = '20261021-030000'; Kind = 'Full'; TenantSlug = 'dev'; BlueprintName = $null; BlueprintTenantId = ''; CrossTenant = $false; BlueprintVersion = $null; Findings = @(); State = $state } |
                ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $directory 'result.json') -Encoding utf8
            Initialize-PETenantBlueprint -Slug 'dev' -MasterBlueprint 'main' -FromCheck -DataRoot $script:Temp | Out-Null
            { Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null } | Should -Not -Throw
            $layers = @(((Read-Json $script:Gui 'index.json').tenants | Where-Object tenantId -EQ 'dev').layers)
            $layers.name | Should -Be @('main', 'dev')
            $layers.checked | Should -Be @($true, $true) -Because ($layers | ConvertTo-Json -Depth 3)
            $layers[0].targetOnly | Should -Be 1
            $layers[1].drifted | Should -Be 0
            $layers[1].targetOnly | Should -Be 0
        }

        It 'shows a workload that was not uploaded as not checked in the master layer, never as missing' {
            # dev is offline; its first upload (Entra only) seeds its own blueprint, so that blueprint has no Teams or Exchange type.
            # The next upload is again Entra only: the master layer must not read the master's Teams and Exchange records as Missing.
            $upload = { [pscustomobject]@{ Name = 'entra.ps1'; Text = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\upload\entra.ps1') -Raw } }
            Set-PETenant -Slug 'dev' -Offline -Blueprints @('main') -DataRoot $script:Temp | Out-Null
            New-PEUploadCheck -Tenant 'dev' -File @(& $upload) -TenantDomain 'dev.example' -DataRoot $script:Temp | Out-Null
            Initialize-PETenantBlueprint -Slug 'dev' -MasterBlueprint 'main' -FromCheck -DataRoot $script:Temp | Out-Null
            Start-Sleep -Seconds 1
            New-PEUploadCheck -Tenant 'dev' -File @(& $upload) -DataRoot $script:Temp | Out-Null
            Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null

            # Read-Json keeps the array as one object: unwrap it so each row is filtered on its own.
            $masterRows = @(Read-Json $script:Gui 'tenants\dev\layers\main\findings.json' | ForEach-Object { $_ })
            @($masterRows | Where-Object { $_.kind -eq 'Missing' -and $_.resourceType -in 'TeamsMeetingPolicy', 'EXOTransportRule' }).Count | Should -Be 0
            @($masterRows | Where-Object { $_.kind -eq 'NotChecked' } | ForEach-Object { $_.resourceType } | Sort-Object) | Should -Be @('EXOTransportRule', 'TeamsMeetingPolicy')
            $layers = @(((Read-Json $script:Gui 'index.json').tenants | Where-Object tenantId -EQ 'dev').layers)
            # The master's Finance Team / EU group is a real Missing: Entra was uploaded.
            $layers[0].missing | Should -Be 1
        }

        It 'still exports when a layer blueprint is missing on disk and says so' {
            Set-PETenant -Slug 'dev' -Blueprints @('main', 'gone') -DataRoot $script:Temp | Out-Null
            Add-DevCheck -Blueprint 'main'
            { Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null } | Should -Not -Throw
            $layers = @(((Read-Json $script:Gui 'index.json').tenants | Where-Object tenantId -EQ 'dev').layers)
            $layers.name | Should -Be @('main', 'gone')
            $layers[1].checked | Should -BeFalse
            $layers[1].problem | Should -Not -BeNullOrEmpty
            $layers[0].checked | Should -BeTrue
        }
    }

    It 'derives the same item id as the GUI' {
        foreach ($key in 'Sales', 'Finance Team / EU', 'Ünï "q" 100%')
        {
            (& (Get-Module PolicyEngine) { param ($k) ConvertTo-PEGuiItemId -ResourceType "AADGroup" -Key $k } $key) | Should -BeExactly (& (Get-Module PEGui) { param ($k) ConvertTo-PEGuiItemId -ResourceType 'AADGroup' -Key $k } $key)
        }
    }

    It 'writes index, status, findings, items, versions and exclusions' {
        foreach ($file in 'index.json', 'tenants\master\status.json', 'tenants\master\findings.json', 'tenants\master\items.json', 'blueprint\versions.json', 'exclusions.json')
        {
            Test-Path (Join-Path $script:Gui $file) | Should -BeTrue -Because $file
        }
        $index = Read-Json $script:Gui 'index.json'
        $index.blueprint.name | Should -Be 'main'
        $index.blueprint.version | Should -Be 1
        $index.tenants[0].tenantId | Should -Be 'master'
        $index.tenants[0].displayName | Should -Be 'contoso.example'
        $index.tenants[0].lastFullCheck | Should -Be '2026-10-21T01:02:03Z'
    }

    It 'gives the page the engine''s workload prefixes, so it can tell the workload of any resource type' {
        $prefixes = @((Read-Json $script:Gui 'index.json').workloadPrefixes)
        $expected = @(& (Get-Module PolicyEngine) { Get-PEWorkloadDefinition })
        $prefixes.Count | Should -Be $expected.Count
        ($prefixes | Where-Object prefix -EQ 'SC').name | Should -Be 'Security and Compliance'
        ($prefixes | Where-Object prefix -EQ 'EXO').name | Should -Be 'Exchange Online'
    }

    It 'maps findings with item ids, differences and the not-checked reason' {
        $findings = Read-Json $script:Gui 'tenants\master\findings.json'
        $changed = $findings | Where-Object { $_.kind -eq 'Changed' -and $_.key -eq 'Sales' }
        $changed.itemId | Should -Be 'AADGroup~Sales'
        $changed.differences[0].property | Should -Be 'Description'
        $changed.differences[0].blueprint | Should -Be 'one'
        $changed.differences[0].target | Should -Be 'two'
        ($findings | Where-Object { $_.kind -eq 'TargetOnly' }).key | Should -Be 'Extra'
        $notChecked = $findings | Where-Object { $_.kind -eq 'NotChecked' }
        $notChecked.resourceType | Should -Be 'EXOTransportRule'
        $notChecked.itemId | Should -BeNullOrEmpty
        $notChecked.id | Should -Be 'EXOTransportRule~'
        $notChecked.error | Should -Be 'export failed: 404'
    }

    It 'counts a not-checked type as not checked and never as aligned' {
        $status = Read-Json $script:Gui 'tenants\master\status.json'
        $exo = $status.workloads | Where-Object workload -EQ 'Exchange Online'
        $exo.notChecked | Should -Be 1
        $exo.aligned | Should -Be 0
        $exo.types[0].status | Should -Be 'NotChecked'
        $entra = $status.workloads | Where-Object workload -EQ 'Entra ID'
        $entra.managed | Should -Be 2
        $entra.drifted | Should -Be 1
        $entra.aligned | Should -Be 1
    }

    It 'lists blueprint and target-only items with their property bags' {
        $items = Read-Json $script:Gui 'tenants\master\items.json'
        ($items | Where-Object itemId -EQ 'AADGroup~Extra').inBlueprint | Should -BeFalse
        ($items | Where-Object itemId -EQ 'AADGroup~Sales').inBlueprint | Should -BeTrue
        $detail = Read-Json $script:Gui 'tenants\master\items\AADGroup~Finance%20Team%20%2F%20EU.json'
        $detail.key | Should -Be 'Finance Team / EU'
        $detail.blueprint.DisplayName | Should -Be 'Finance Team / EU'
        (Read-Json $script:Gui 'tenants\master\items\AADGroup~Extra.json').blueprint | Should -BeNullOrEmpty
    }

    It 'writes exclusions from decisions' {
        $exclusions = Read-Json $script:Gui 'exclusions.json'
        $exclusions.unmanaged[0].itemId | Should -Be 'AADGroup~Old%20Group'
        $exclusions.unmanaged[0].reason | Should -Be 'retired'
        $exclusions.noise[0].property | Should -Be 'Description'
    }

    It 'lists blueprint versions, with the change record of an accepted change' {
        $master = New-TestState -Records @((New-TestRecord -Key 'Sales' -Props @{ Description = 'one' }), (New-TestRecord -Key 'Finance Team / EU'), (New-TestRecord -Type 'TeamsMeetingPolicy' -Key 'Global' -Workload 'Teams'), (New-TestRecord -Type 'EXOTransportRule' -Key 'Disclaimer' -Workload 'Exchange Online'), (New-TestRecord -Key 'New one'))
        $change = @(Get-PEBlueprintChange -Name 'main' -MasterState $master -DataRoot $script:Temp)
        Approve-PEBlueprintChange -Name 'main' -MasterState $master -Accept $change -Reason 'add new one' -DataRoot $script:Temp | Out-Null
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $versions = Read-Json $script:Gui 'blueprint\versions.json'
        $versions.Count | Should -Be 2
        $versions[0].source | Should -Be 'Initial'
        $versions[1].changes[0].op | Should -Be 'Added'
        $versions[1].changes[0].itemId | Should -Be 'AADGroup~New%20one'
        $versions[1].reason | Should -Be 'add new one'
        (Read-Json $script:Gui 'index.json').blueprint.version | Should -Be 2
    }

    It 'is readable through the GUI API, with allowed actions' {
        $findings = @((Invoke-PEGuiApi -DataRoot $script:Gui -Method GET -Path '/api/tenants/master/findings').Json | ConvertFrom-Json)
        $findings.Count | Should -BeGreaterThan 0
        $changed = $findings | Where-Object { $_.kind -eq 'Changed' }
        @($changed.allowedActions) | Should -Contain 'Promote'
        ((Invoke-PEGuiApi -DataRoot $script:Gui -Method GET -Path '/api/index').Json | ConvertFrom-Json).tenants[0].tenantId | Should -Be 'master'
    }

    It 'gives every blueprint version a date, version 1 included' {
        $versions = Read-Json $script:Gui 'blueprint\versions.json'
        $versions[0].at | Should -Be '2026-10-21T01:02:03Z'
    }

    It 'shows a rename as one row with the settings that differ' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-gui-rename-' + [guid]::NewGuid())
        try
        {
            $props = { param ($n) @{ Description = 'same long description for matching'; Visibility = 'Private'; Classification = 'x'; Theme = 'y' } }
            $old = New-TestRecord -Key 'Executive' -Props (& $props 'Executive')
            $new = New-TestRecord -Key 'Executive Team' -Props (& $props 'Executive Team')
            Initialize-PEBlueprint -Name 'r' -State (New-TestState -Records @($old)) -DataRoot $root | Out-Null
            $target = New-TestState -Records @($new)
            $findings = @(Compare-PEState -Blueprint (Get-PEBlueprint -Name 'r' -DataRoot $root) -Target $target)
            @($findings | Where-Object Kind -EQ 'PossibleRename').Count | Should -Be 2
            $directory = Join-Path $root 'checks\20261021-020000'
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            [ordered]@{ CheckId = '20261021-020000'; Kind = 'Full'; Findings = $findings; State = $target } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $directory 'result.json') -Encoding utf8
            Export-PEGuiData -BlueprintName 'r' -DataRoot $root -GuiRoot (Join-Path $root 'gui') | Out-Null
            $rows = @(Read-Json (Join-Path $root 'gui') 'tenants\master\findings.json')
            $rows.Count | Should -Be 1
            $rows[0].kind | Should -Be 'PossibleRename'
            $rows[0].key | Should -Be 'Executive'
            $rows[0].other | Should -Be 'Executive Team'
            ($rows[0].differences | ForEach-Object property) | Should -Contain 'DisplayName'
            $detail = Read-Json (Join-Path $root 'gui') 'tenants\master\items\AADGroup~Executive.json'
            $detail.targetKey | Should -Be 'Executive Team'
            $detail.target.DisplayName | Should -Be 'Executive Team'
        }
        finally
        {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'lists the scopes with item and drift counts on the tenant entry' {
        Set-PEScope -Name 'groups' -Types 'AADGroup' -Keys 'Sales', 'Extra' -Description 'two groups' -DataRoot $script:Temp | Out-Null
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $scope = (Read-Json $script:Gui 'index.json').tenants[0].scopes[0]
        $scope.name | Should -Be 'groups'
        $scope.items | Should -Be 1
        $scope.drifted | Should -Be 2
        # the items the page reverts or promotes as a whole: the open Missing, Changed and TargetOnly ones of the scope
        @($scope.driftItems).Count | Should -Be 2
        @($scope.driftItems) | ForEach-Object { $_ | Should -Match '^AADGroup~' }
        $scope.lastChecked | Should -BeNullOrEmpty
    }
    It 'lists every resource type of the blueprint as a scope with its counts' {
        $types = @((Read-Json $script:Gui 'index.json').tenants[0].typeScopes)
        $types.type | Should -Be @('AADGroup', 'EXOTransportRule', 'TeamsMeetingPolicy')
        $group = $types | Where-Object type -EQ 'AADGroup'
        $group.items | Should -Be 2
        $group.drifted | Should -Be 2
        @($group.driftItems).Count | Should -Be 2
        @(($types | Where-Object type -EQ 'TeamsMeetingPolicy').driftItems).Count | Should -Be 0
        $group.workload | Should -Be 'Entra ID'
        ($types | Where-Object type -EQ 'TeamsMeetingPolicy').drifted | Should -Be 0
    }

    It 'tells the page whether the blueprint and the pinned DSC version match' {
        $dsc = (Read-Json $script:Gui 'index.json').dsc
        $dsc.match | Should -BeTrue
        $dsc.pin | Should -Be $dsc.blueprint
        $file = Join-Path $script:Temp 'blueprints\main\module.json'
        $record = Get-Content $file -Raw | ConvertFrom-Json
        $record.ModuleVersion = '2.25.0.1'
        $record | ConvertTo-Json | Set-Content $file
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $dsc = (Read-Json $script:Gui 'index.json').dsc
        $dsc.match | Should -BeFalse
        $dsc.blueprint | Should -Be '2.25.0.1'
    }
    It 'exports every registered tenant from its own check, and lists one with no check yet empty' {
        Set-PETenant -Slug 'dev' -DisplayName 'Dev tenant' -DataRoot $script:Temp | Out-Null
        Set-PETenant -Slug 'newtenant' -DisplayName 'Not checked yet' -Offline -DataRoot $script:Temp | Out-Null
        $blueprint = Get-PEBlueprint -Name 'main' -DataRoot $script:Temp
        $devState = New-TestState -Records @((New-TestRecord -Key 'Sales' -Props @{ Description = 'one' }), (New-TestRecord -Key 'Finance Team / EU'), (New-TestRecord -Type 'TeamsMeetingPolicy' -Key 'Global' -Workload 'Teams'), (New-TestRecord -Type 'EXOTransportRule' -Key 'Disclaimer' -Workload 'Exchange Online'), (New-TestRecord -Key 'DevExtra'))
        $devFindings = @(Compare-PEState -Blueprint $blueprint -Target $devState)
        $directory = Join-Path $script:Temp 'checks\20261021-030000'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        [ordered]@{ CheckId = '20261021-030000'; Kind = 'Full'; TenantSlug = 'dev'; BlueprintName = 'main'; BlueprintVersion = 1; Findings = $devFindings; State = $devState } |
            ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $directory 'result.json') -Encoding utf8
        Set-PEDecision -Kind Unmanaged -ResourceType AADGroup -Key 'DevExtra' -Reason 'dev only' -Tenant 'dev' -DataRoot $script:Temp | Out-Null
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null

        $tenants = @((Read-Json $script:Gui 'index.json').tenants)
        $tenants.tenantId | Should -Be @('master', 'dev', 'newtenant')
        ($tenants | Where-Object tenantId -EQ 'dev').role | Should -Be 'Replica'
        ($tenants | Where-Object tenantId -EQ 'dev').displayName | Should -Be 'Dev tenant'
        ($tenants | Where-Object tenantId -EQ 'newtenant').lastFullCheck | Should -BeNullOrEmpty
        ($tenants | Where-Object tenantId -EQ 'newtenant').offline | Should -BeTrue
        ($tenants | Where-Object tenantId -EQ 'dev').offline | Should -BeFalse
        ($tenants | Where-Object tenantId -EQ 'master').offline | Should -BeFalse
        $devRows = @(Get-Content (Join-Path $script:Gui 'tenants\dev\findings.json') -Raw | ConvertFrom-Json)
        ($devRows | Where-Object key -EQ 'DevExtra').kind | Should -Be 'TargetOnly'
        @(Get-Content (Join-Path $script:Gui 'tenants\master\findings.json') -Raw | ConvertFrom-Json | Where-Object key -EQ 'DevExtra').Count | Should -Be 0
        @(Get-Content (Join-Path $script:Gui 'tenants\newtenant\findings.json') -Raw | ConvertFrom-Json).Count | Should -Be 0
        @((Read-Json $script:Gui 'tenants\newtenant\status.json').workloads).Count | Should -Be 0
        $unmanaged = @((Read-Json $script:Gui 'exclusions.json').unmanaged | Where-Object key -EQ 'DevExtra')
        $unmanaged.tenantId | Should -Be @('dev')
    }
    It 'labels the snapshot of a tenant: Live for a check read from the tenant, Uploaded with its workloads for an upload' {
        Set-PETenant -Slug 'acme' -DisplayName 'Acme' -Offline -TenantId 'acme.example' -DataRoot $script:Temp | Out-Null
        $state = & (Get-Module PolicyEngine) {
            param ($r)
            New-PEState -Records $r -NotChecked @() -Meta @{ TenantId = 'acme.example'; ExportedAt = '2026-10-25T08:00:00Z'; Source = 'Uploaded'; Workloads = [ordered]@{ 'Entra ID' = [ordered]@{ Source = 'Uploaded'; At = '2026-10-25T08:00:00Z' }; 'Teams' = [ordered]@{ Source = 'Live'; At = '2026-10-20T01:00:00Z' } } }
        } @((New-TestRecord -Key 'Sales'), (New-TestRecord -Type 'TeamsMeetingPolicy' -Key 'Global' -Workload 'Teams'))
        $directory = Join-Path $script:Temp 'checks\20261025-080000'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        [ordered]@{ CheckId = '20261025-080000'; Kind = 'Full'; TenantSlug = 'acme'; BlueprintName = 'main'; BlueprintVersion = 1; Findings = @(Compare-PEState -Blueprint (Get-PEBlueprint -Name 'main' -DataRoot $script:Temp) -Target $state); State = $state } |
            ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $directory 'result.json') -Encoding utf8
        Set-PETenant -Slug 'empty' -DisplayName 'Empty' -Offline -DataRoot $script:Temp | Out-Null
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null

        $tenants = @((Read-Json $script:Gui 'index.json').tenants)
        $acme = ($tenants | Where-Object tenantId -EQ 'acme').snapshot
        ($tenants | Where-Object tenantId -EQ 'acme').offline | Should -BeTrue
        $acme.source | Should -Be 'Uploaded'
        $acme.at | Should -Be '2026-10-25T08:00:00Z'
        @($acme.workloads).Count | Should -Be 2
        $entra = $acme.workloads | Where-Object workload -EQ 'Entra ID'
        $entra.source | Should -Be 'Uploaded'
        $entra.at | Should -Be '2026-10-25T08:00:00Z'
        ($acme.workloads | Where-Object workload -EQ 'Teams').source | Should -Be 'Live'
        ($acme.workloads | Where-Object workload -EQ 'Teams').at | Should -Be '2026-10-20T01:00:00Z'
        # a check of Invoke-PEFullCheck has no Meta.Workloads: Live at the export time, one entry per workload of its records
        $master = ($tenants | Where-Object tenantId -EQ 'master').snapshot
        $master.source | Should -Be 'Live'
        $master.at | Should -Be '2026-10-21T01:02:03Z'
        @($master.workloads | ForEach-Object { $_.workload } | Sort-Object) | Should -Be @('Entra ID', 'Teams')
        @($master.workloads | ForEach-Object { $_.source } | Sort-Object -Unique) | Should -Be @('Live')
        # no check yet: no label
        ($tenants | Where-Object tenantId -EQ 'empty').snapshot | Should -BeNullOrEmpty
    }
    It 'leaves activity and requests alone and replaces files without leftovers' {
        New-Item -ItemType Directory -Path (Join-Path $script:Gui 'requests') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Gui 'requests\r1.json') -Value '{}'
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        Test-Path (Join-Path $script:Gui 'requests\r1.json') | Should -BeTrue
        @(Get-ChildItem -LiteralPath $script:Gui -Recurse -Filter '*.tmp').Count | Should -Be 0
    }
}
