BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    Import-Module "$PSScriptRoot\..\gui\PEGui.psm1" -Force
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures\asd-mini'
    . "$PSScriptRoot\StandardTestHelper.ps1"

    function Send-Request
    {
        param ([hashtable]$Body)
        $reply = Invoke-PEGuiApi -DataRoot $script:Gui -Method POST -Path '/api/requests' -Body ([pscustomobject]$Body)
        $reply.StatusCode | Should -Be 201 -Because $reply.Json
        ($reply.Json | ConvertFrom-Json).jobId
    }

    function Read-Json
    {
        param ($Relative)
        Get-Content -LiteralPath (Join-Path $script:Gui $Relative) -Raw | ConvertFrom-Json -NoEnumerate -DateKind String
    }

    function Get-Row
    {
        param ([string]$Type, [string]$Key = '', [string]$Tenant = 'master')
        @((Read-Json "tenants/$Tenant/standards/asd.json").rows | Where-Object { $_.resourceType -eq $Type -and ($Key -eq '' -or $_.key -eq $Key) })[0]
    }

    function Export-TestGui
    {
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui -WarningAction SilentlyContinue | Out-Null
    }

    function Invoke-Worker
    {
        param ([string]$JobId, [scriptblock]$ExportScript, [scriptblock]$GitScript)
        $arguments = @{ BlueprintName = 'main'; DataRoot = $script:Temp; GuiRoot = $script:Gui; JobId = $JobId }
        if ($ExportScript) { $arguments.ExportScript = $ExportScript }
        if ($GitScript) { $arguments.GitScript = $GitScript }
        Invoke-PEGuiRequest @arguments -WarningAction SilentlyContinue 6>$null | Out-Null
        Read-Json "activity/$JobId.json"
    }

    function Invoke-Check
    {
        # The master blueprint compared with the standard; -SecondDifference first remakes it so a second property differs.
        param ([string]$Tenant = 'master', [switch]$SecondDifference)
        if ($SecondDifference)
        {
            Remove-Item -LiteralPath (Join-Path $script:Temp 'blueprints\main') -Recurse -Force
            New-TestTenantBlueprint -Root $script:Temp -Name 'main' -SecondDifference
        }
        Invoke-PEStandardCheck -StandardName 'asd' -BlueprintName 'main' -Tenant $Tenant -DataRoot $script:Temp
    }

    function Invoke-Action
    {
        # The worker's action function, called directly with a request that the API would have refused.
        param ($Request, [scriptblock]$GitScript)
        & (Get-Module PolicyEngine) {
            param ($r, $root, $git)
            Invoke-PEGuiRequestAction -Request $r -Job ([pscustomobject]@{ jobId = 'J-1' }) -BlueprintName 'main' -DataRoot $root -GuiRoot (Join-Path $root 'gui') -GitScript $git
        } ([pscustomobject]$Request) $script:Temp $GitScript
    }
}

Describe 'Standards requests in the worker' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-guistdreq-' + [guid]::NewGuid())
        $script:Gui = Join-Path $script:Temp 'gui'
        $state = & (Get-Module PolicyEngine) { New-PEState -Records @() -NotChecked @() -Meta @{ TenantId = 't'; ExportedAt = '2026-10-21T01:02:03Z' } }
        New-TestTenantBlueprint -Root $script:Temp -Name 'main'
        $directory = Join-Path $script:Temp 'checks\20261021-020000'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        [ordered]@{ CheckId = '20261021-020000'; Kind = 'Full'; BlueprintName = 'main'; BlueprintVersion = 1; Findings = @(); State = $state } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $directory 'result.json') -Encoding utf8
        Import-PEStandard -Name 'asd' -Path $script:Fixture -SourceName 'ASD' -SourceUrl 'https://example.test' -SourceVersion 'v1.4.0' -DataRoot $script:Temp -WarningAction SilentlyContinue 6>$null | Out-Null
        $script:First = Invoke-Check
        Export-TestGui
    }

    AfterEach {
        if (Test-Path $script:Temp) { Remove-Item $script:Temp -Recurse -Force }
    }

    Context 'Adopt' {
        It 'records the next version of the tenant''s own blueprint with provenance, and the setting then matches' {
            $row = Get-Row 'TeamsMessagingPolicy'
            $job = Invoke-Worker (Send-Request @{ action = 'Adopt'; tenantId = 'master'; standard = 'asd'; reason = 'adopt messaging'; confirmedMasterWrite = $true; items = @(@{ itemId = $row.itemId }) })
            $job.status | Should -Be 'Succeeded' -Because $job.result
            $job.result | Should -BeLike "*Blueprint v2 recorded in 'main'*No tenant was changed*"
            $record = @((Get-PEBlueprint -Name 'main' -DataRoot $script:Temp).Records | Where-Object ResourceType -EQ 'TeamsMessagingPolicy')[0]
            $record.Provenance.Standard | Should -Be 'asd'
            (Get-PECheck -Latest -Kind Standard -Standard asd -DataRoot $script:Temp).CheckId | Should -Not -Be $script:First.CheckId
            @((Read-Json 'tenants/master/standards/asd.json').rows | Where-Object resourceType -EQ 'TeamsMessagingPolicy').Count | Should -Be 0
            (Read-Json 'tenants/master/standards/asd.json').blueprint.version | Should -Be 2
        }

        It 'refuses the master blueprint without the master-write confirmation, and a replica with no blueprint of its own' {
            $row = Get-Row 'TeamsMessagingPolicy'
            { Invoke-Action @{ action = 'Adopt'; tenantId = 'master'; standard = 'asd'; reason = 'x'; confirmedMasterWrite = $false; items = @(@{ resourceType = $row.resourceType; key = $row.key }) } } | Should -Throw '*master-write confirmation*'
            Set-PETenant -Slug 'dev' -DisplayName 'Dev' -TenantId 'dev.onmicrosoft.com' -DataRoot $script:Temp | Out-Null
            { Invoke-Action @{ action = 'Adopt'; tenantId = 'dev'; standard = 'asd'; reason = 'x'; items = @(@{ resourceType = $row.resourceType; key = $row.key }) } } | Should -Throw '*no blueprint of its own*'
            (Get-PEBlueprint -Name 'main' -DataRoot $script:Temp).Meta.Version | Should -Be 1
        }
    }

    Context 'Accept risk and Remove' {
        It 'records one decision for the whole item, and the check shows it as accepted' {
            $row = Get-Row 'AADNamedLocationPolicy'
            $job = Invoke-Worker (Send-Request @{ action = 'AcceptRisk'; tenantId = 'master'; standard = 'asd'; items = @(@{ itemId = $row.itemId; approvedBy = 'J. Citizen'; why = 'NZ staff' }) })
            $job.status | Should -Be 'Succeeded' -Because $job.result
            $decisions = @(Get-PEDecision -Kind RiskAccepted -DataRoot $script:Temp)
            $decisions.Count | Should -Be 1
            $decisions[0].ApprovedBy | Should -Be 'J. Citizen'
            $decisions[0].Reason | Should -Be 'NZ staff'
            $decisions[0].Standard | Should -Be 'asd'
            $decisions[0].Tenant | Should -Be 'master'
            $decisions[0].Property | Should -BeNullOrEmpty
            $accepted = Get-Row 'AADNamedLocationPolicy'
            $accepted.status | Should -Be 'accepted'
            $accepted.approvedBy | Should -Be 'J. Citizen'
        }

        It 'records one decision per ticked property' {
            $script:First = Invoke-Check -SecondDifference
            Export-TestGui
            $row = Get-Row 'AADNamedLocationPolicy'
            @($row.differences | ForEach-Object property | Sort-Object) | Should -Be @('CountriesAndRegions', 'CountryLookupMethod')
            $job = Invoke-Worker (Send-Request @{ action = 'AcceptRisk'; tenantId = 'master'; standard = 'asd'; items = @(@{ itemId = $row.itemId; approvedBy = 'cio'; why = 'both'; properties = @('CountriesAndRegions', 'CountryLookupMethod') }) })
            $job.status | Should -Be 'Succeeded' -Because $job.result
            @(Get-PEDecision -Kind RiskAccepted -DataRoot $script:Temp | ForEach-Object Property | Sort-Object) | Should -Be @('CountriesAndRegions', 'CountryLookupMethod')
            (Get-Row 'AADNamedLocationPolicy').status | Should -Be 'accepted'
        }

        It 'refuses a request without who and why, and a property that does not differ' {
            $row = Get-Row 'AADNamedLocationPolicy'
            { Invoke-Action @{ action = 'AcceptRisk'; tenantId = 'master'; standard = 'asd'; items = @(@{ resourceType = $row.resourceType; key = $row.key; approvedBy = ''; why = 'x' }) } } | Should -Throw '*approved by*'
            { Invoke-Action @{ action = 'AcceptRisk'; tenantId = 'master'; standard = 'asd'; items = @(@{ resourceType = $row.resourceType; key = $row.key; approvedBy = 'a'; why = '' }) } } | Should -Throw '*why*'
            { Invoke-Action @{ action = 'AcceptRisk'; tenantId = 'master'; standard = 'asd'; items = @(@{ resourceType = $row.resourceType; key = $row.key; approvedBy = 'a'; why = 'b'; properties = @('IsTrusted') }) } } | Should -Throw '*does not differ*'
            @(Get-PEDecision -Kind RiskAccepted -DataRoot $script:Temp).Count | Should -Be 0
        }

        It 'removes the acceptance and the row is open again' {
            $row = Get-Row 'AADNamedLocationPolicy'
            Invoke-Worker (Send-Request @{ action = 'AcceptRisk'; tenantId = 'master'; standard = 'asd'; items = @(@{ itemId = $row.itemId; approvedBy = 'cio'; why = 'x' }) }) | Out-Null
            $job = Invoke-Worker (Send-Request @{ action = 'RemoveRisk'; tenantId = 'master'; standard = 'asd'; items = @(@{ itemId = $row.itemId }) })
            $job.status | Should -Be 'Succeeded' -Because $job.result
            @(Get-PEDecision -Kind RiskAccepted -DataRoot $script:Temp).Count | Should -Be 0
            (Get-Row 'AADNamedLocationPolicy').status | Should -Be 'differs'
        }
    }

    Context 'Standard check' {
        It 'compares the blueprint again and saves a new Standard check, without reading the tenant' {
            $job = Invoke-Worker (Send-Request @{ action = 'StandardCheck'; tenantId = 'master'; standard = 'asd' })
            $job.status | Should -Be 'Succeeded' -Because $job.result
            $job.result | Should -BeLike "*Compared 2 of 5 settings*blueprint 'main' v1*Nothing was read from the tenant*"
            (Get-PECheck -Latest -Kind Standard -Standard asd -DataRoot $script:Temp).CheckId | Should -Not -Be $script:First.CheckId
            Test-Path (Join-Path $script:Temp 'exports') | Should -BeFalse
        }

        It 'works for an offline tenant' {
            Set-PETenant -Slug 'off' -DisplayName 'Offline' -TenantId 'off.onmicrosoft.com' -Offline -DataRoot $script:Temp | Out-Null
            Export-TestGui
            $job = Invoke-Worker (Send-Request @{ action = 'StandardCheck'; tenantId = 'off'; standard = 'asd' })
            $job.status | Should -Be 'Succeeded' -Because $job.result
            (Read-Json 'tenants/off/standards/asd.json').checked | Should -BeTrue
        }
    }

    Context 'Import and release' {
        It 'imports a named release through the shared import' {
            $fake = New-FakeGit
            $job = Invoke-Worker (Send-Request @{ action = 'ImportStandard'; standard = 'asd'; tag = 'v1.5.0' }) -GitScript $fake.Git
            $job.status | Should -Be 'Succeeded' -Because $job.result
            $job.result | Should -BeLike '*version 2 from v1.5.0*'
            @((Get-PEStandard -Name asd -DataRoot $script:Temp).Versions).Count | Should -Be 2
        }

        It 'fails clearly when the latest release is already imported' {
            $fake = New-FakeGit
            $job = Invoke-Worker (Send-Request @{ action = 'ImportStandard'; standard = 'asd' }) -GitScript $fake.Git
            $job.status | Should -Be 'Failed'
            $job.result | Should -BeLike '*already imported*'
        }

        It 'refuses a tag that is not vX.Y.Z' {
            { Invoke-Action @{ action = 'ImportStandard'; standard = 'asd'; tag = 'v1.4.0; calc' } -GitScript (New-FakeGit).Git } | Should -Throw '*vX.Y.Z*'
        }

        It 'writes the latest release tag for the page to read' {
            $fake = New-FakeGit -Tags @('v1.4.0', 'v1.6.0')
            $job = Invoke-Worker (Send-Request @{ action = 'CheckStandardRelease'; standard = 'asd' }) -GitScript $fake.Git
            $job.status | Should -Be 'Succeeded' -Because $job.result
            $found = Get-Content -LiteralPath (Join-Path $script:Temp 'sources\asd-latest.json') -Raw | ConvertFrom-Json
            $found.tag | Should -Be 'v1.6.0'
            (@(Read-Json 'standards/index.json')[0]).latestRelease.tag | Should -Be 'v1.6.0'
        }
    }
}
