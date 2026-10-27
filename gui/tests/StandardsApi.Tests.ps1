BeforeAll {
    Import-Module "$PSScriptRoot/../PEGui.psm1" -Force
    $script:MockData = Resolve-Path "$PSScriptRoot/../mock-data"

    function New-TestDataRoot {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Item -Path $script:MockData -Destination $root -Recurse
        $root
    }
    function Get-RowId($Root, $Type, $Key, $Tenant = 'master') {
        $view = Get-Content -LiteralPath (Join-Path $Root "tenants/$Tenant/standards/asd.json") -Raw | ConvertFrom-Json
        ($view.rows | Where-Object { $_.resourceType -eq $Type -and $_.key -eq $Key } | Select-Object -First 1).itemId
    }
    function Get-Preview($Root, $Body) { Get-PEGuiRequestPreview -DataRoot $Root -Request $Body }
    function Set-IndexTenant($Root, [scriptblock]$Change) {
        $path = Join-Path $Root 'index.json'
        $index = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        & $Change $index
        $index | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8
    }
}

Describe 'Standards routes' {
    BeforeAll { $root = New-TestDataRoot }

    It 'serves the standards index, a standard''s coverage and a tenant''s view' {
        $index = (Invoke-PEGuiApi -DataRoot $root -Method GET -Path '/api/standards').Json | ConvertFrom-Json -NoEnumerate
        @($index)[0].name | Should -Be 'asd'
        $coverage = (Invoke-PEGuiApi -DataRoot $root -Method GET -Path '/api/standards/asd/coverage').Json | ConvertFrom-Json
        @($coverage.rows).Count | Should -Be 42
        $view = (Invoke-PEGuiApi -DataRoot $root -Method GET -Path '/api/tenants/master/standards/asd').Json | ConvertFrom-Json
        $view.headline.checked | Should -Be 87
        @($view.rows).Count | Should -Be 19
        ((Invoke-PEGuiApi -DataRoot $root -Method GET -Path '/api/tenants/replica/standards/asd').Json | ConvertFrom-Json).checked | Should -BeFalse
    }

    It 'refuses a standard name that is not a plain name' {
        foreach ($name in '..\x', '.hidden', 'a b', 'x:y', '..')
        {
            $reply = Invoke-PEGuiApi -DataRoot $root -Method GET -Path "/api/standards/$name/coverage"
            $reply.StatusCode | Should -Be 400 -Because $name
        }
        (Invoke-PEGuiApi -DataRoot $root -Method GET -Path '/api/tenants/master/standards/..%5Cx').StatusCode | Should -Be 400
    }

    It 'refuses an unknown standard and an unknown tenant' {
        (Invoke-PEGuiApi -DataRoot $root -Method GET -Path '/api/standards/nist/coverage').StatusCode | Should -Be 400
        (Invoke-PEGuiApi -DataRoot $root -Method GET -Path '/api/tenants/nobody/standards/asd').StatusCode | Should -Be 400
    }
}

Describe 'Standards request previews' {
    BeforeEach {
        $root = New-TestDataRoot
        $countries = Get-RowId $root 'AADNamedLocationPolicy' 'Allowed Countries'
        $trusted = Get-RowId $root 'AADNamedLocationPolicy' 'Trusted IPs'
        $giphy = Get-RowId $root 'TeamsMessagingPolicy' 'Global'
        $edge = Get-RowId $root 'IntuneSettingCatalogCustomPolicyWindows10' 'Edge hardening'
    }

    It 'previews Adopt into the master blueprint as a master write with the next version' {
        $p = Get-Preview $root @{ action = 'Adopt'; tenantId = 'master'; standard = 'asd'; reason = 'adopt'; confirmedMasterWrite = $true; items = @(@{ itemId = $countries }, @{ itemId = $edge }) }
        $p.valid | Should -BeTrue -Because ($p.errors -join '; ')
        $p.writesMaster | Should -BeTrue
        $p.reasonRequired | Should -BeTrue
        $p.blueprintName | Should -Be 'prod'
        $p.blueprintVersionAfter | Should -Be 8
        @($p.items).Count | Should -Be 2
        $p.items[0].effect | Should -BeLike "*blueprint prod*tenant is not changed*"
    }

    It 'refuses Adopt into the master blueprint without the master-write confirmation' {
        $p = Get-Preview $root @{ action = 'Adopt'; tenantId = 'master'; standard = 'asd'; reason = 'adopt'; items = @(@{ itemId = $countries }) }
        $p.valid | Should -BeFalse
        ($p.errors -join ' ') | Should -BeLike '*needs confirmedMasterWrite*'
    }

    It 'previews Adopt for a replica as a write to its own blueprint only' {
        Copy-Item (Join-Path $root 'tenants/master/standards/asd.json') (Join-Path $root 'tenants/replica/standards/asd.json') -Force
        $id = Get-RowId $root 'AADNamedLocationPolicy' 'Allowed Countries' 'replica'
        $p = Get-Preview $root @{ action = 'Adopt'; tenantId = 'replica'; standard = 'asd'; reason = 'adopt'; items = @(@{ itemId = $id }) }
        $p.valid | Should -BeTrue -Because ($p.errors -join '; ')
        $p.writesMaster | Should -BeFalse
        $p.blueprintName | Should -Be 'replica'
    }

    It 'refuses Adopt for a replica that has no blueprint of its own' {
        Copy-Item (Join-Path $root 'tenants/master/standards/asd.json') (Join-Path $root 'tenants/replica/standards/asd.json') -Force
        Set-IndexTenant $root { param ($i) ($i.tenants | Where-Object tenantId -EQ 'replica').layers = @(($i.tenants | Where-Object tenantId -EQ 'replica').layers | Select-Object -First 1) }
        $id = Get-RowId $root 'AADNamedLocationPolicy' 'Allowed Countries' 'replica'
        $p = Get-Preview $root @{ action = 'Adopt'; tenantId = 'replica'; standard = 'asd'; reason = 'adopt'; items = @(@{ itemId = $id }) }
        $p.valid | Should -BeFalse
        ($p.errors -join ' ') | Should -BeLike '*no blueprint of its own*'
    }

    It 'refuses Adopt without a reason, on an accepted row, on an adopted row and for an item that is not a row' {
        (Get-Preview $root @{ action = 'Adopt'; tenantId = 'master'; standard = 'asd'; items = @(@{ itemId = $countries }) }).errors -join ' ' | Should -BeLike '*reason is required*'
        (Get-Preview $root @{ action = 'Adopt'; tenantId = 'master'; standard = 'asd'; reason = 'x'; items = @(@{ itemId = $trusted }) }).errors -join ' ' | Should -BeLike "*not allowed*"
        (Get-Preview $root @{ action = 'Adopt'; tenantId = 'master'; standard = 'asd'; reason = 'x'; items = @(@{ itemId = $giphy }) }).errors -join ' ' | Should -BeLike "*not allowed*"
        (Get-Preview $root @{ action = 'Adopt'; tenantId = 'master'; standard = 'asd'; reason = 'x'; items = @(@{ itemId = 'Nope~x' }) }).errors -join ' ' | Should -BeLike "*No row*"
        (Get-Preview $root @{ action = 'Adopt'; tenantId = 'master'; standard = 'asd'; reason = 'x'; items = @() }).errors -join ' ' | Should -BeLike '*at least one item*'
    }

    It 'previews Accept risk with who and why, and with one property' {
        $p = Get-Preview $root @{ action = 'AcceptRisk'; tenantId = 'master'; standard = 'asd'; items = @(@{ itemId = $countries; approvedBy = 'J. Citizen'; why = 'NZ staff' }) }
        $p.valid | Should -BeTrue -Because ($p.errors -join '; ')
        $p.writesMaster | Should -BeFalse
        $p.reasonRequired | Should -BeFalse
        $p.items[0].effect | Should -BeLike '*J. Citizen*NZ staff*'
        $q = Get-Preview $root @{ action = 'AcceptRisk'; tenantId = 'master'; standard = 'asd'; items = @(@{ itemId = $countries; approvedBy = 'a'; why = 'b'; properties = @('CountriesAndRegions') }) }
        $q.valid | Should -BeTrue -Because ($q.errors -join '; ')
    }

    It 'does not double the full stop when the reason already ends with one' {
        $p = Get-Preview $root @{ action = 'AcceptRisk'; tenantId = 'master'; standard = 'asd'; items = @(@{ itemId = $countries; approvedBy = 'J. Citizen'; why = 'Managed by the device team.' }) }
        $p.items[0].effect | Should -Be 'Records that J. Citizen accepted this difference: Managed by the device team.'
        $q = Get-Preview $root @{ action = 'AcceptRisk'; tenantId = 'master'; standard = 'asd'; items = @(@{ itemId = $countries; approvedBy = 'J. Citizen'; why = 'NZ staff' }) }
        $q.items[0].effect | Should -Be 'Records that J. Citizen accepted this difference: NZ staff.'
    }
    It 'refuses Accept risk without approver or why, or for a property that does not differ' {
        (Get-Preview $root @{ action = 'AcceptRisk'; tenantId = 'master'; standard = 'asd'; items = @(@{ itemId = $countries; why = 'b' }) }).errors -join ' ' | Should -BeLike '*approved by*'
        (Get-Preview $root @{ action = 'AcceptRisk'; tenantId = 'master'; standard = 'asd'; items = @(@{ itemId = $countries; approvedBy = 'a'; why = '   ' }) }).errors -join ' ' | Should -BeLike '*why*'
        (Get-Preview $root @{ action = 'AcceptRisk'; tenantId = 'master'; standard = 'asd'; items = @(@{ itemId = $countries; approvedBy = 'a'; why = 'b'; properties = @('IsTrusted') }) }).errors -join ' ' | Should -BeLike "*does not differ*"
    }

    It 'previews Remove only for accepted or look-again rows' {
        (Get-Preview $root @{ action = 'RemoveRisk'; tenantId = 'master'; standard = 'asd'; items = @(@{ itemId = $trusted }) }).valid | Should -BeTrue
        (Get-Preview $root @{ action = 'RemoveRisk'; tenantId = 'master'; standard = 'asd'; items = @(@{ itemId = $countries }) }).errors -join ' ' | Should -BeLike '*not allowed*'
    }

    It 'previews the tenant-level requests and refuses bad ones' {
        (Get-Preview $root @{ action = 'StandardCheck'; tenantId = 'master'; standard = 'asd' }).valid | Should -BeTrue
        (Get-Preview $root @{ action = 'StandardCheck'; tenantId = 'master'; standard = 'nist' }).errors -join ' ' | Should -BeLike '*Unknown standard*'
        (Get-Preview $root @{ action = 'ImportStandard'; standard = 'asd' }).valid | Should -BeTrue
        (Get-Preview $root @{ action = 'ImportStandard'; standard = 'asd'; tag = 'v1.5.0' }).valid | Should -BeTrue
        (Get-Preview $root @{ action = 'CheckStandardRelease'; standard = 'asd' }).valid | Should -BeTrue
        foreach ($tag in 'main', 'v1.4.0; calc', 'v1.4', '--upload-pack=x')
        {
            (Get-Preview $root @{ action = 'ImportStandard'; standard = 'asd'; tag = $tag }).errors -join ' ' | Should -BeLike '*vX.Y.Z*' -Because $tag
        }
        (Get-Preview $root @{ action = 'ImportStandard'; standard = '..\x' }).valid | Should -BeFalse
    }

    It 'refuses a standard check for an offline tenant or while a check is running' {
        Set-IndexTenant $root { param ($i) ($i.tenants | Where-Object tenantId -EQ 'replica') | Add-Member -NotePropertyName offline -NotePropertyValue $true -Force }
        (Get-Preview $root @{ action = 'StandardCheck'; tenantId = 'replica'; standard = 'asd' }).errors -join ' ' | Should -BeLike '*offline*'
        $first = New-PEGuiRequest -DataRoot $root -Request @{ action = 'StandardCheck'; tenantId = 'master'; standard = 'asd' }
        $first.created | Should -BeTrue
        (Get-Preview $root @{ action = 'StandardCheck'; tenantId = 'master'; standard = 'asd' }).errors -join ' ' | Should -BeLike '*already running*'
    }
}

Describe 'Standards requests are queued' {
    It 'saves what the worker needs: the standard, the items and who approved' {
        $root = New-TestDataRoot
        $id = Get-RowId $root 'AADNamedLocationPolicy' 'Allowed Countries'
        $r = New-PEGuiRequest -DataRoot $root -Request @{ action = 'AcceptRisk'; tenantId = 'master'; standard = 'asd'; items = @(@{ itemId = $id; approvedBy = 'J. Citizen'; why = 'NZ staff'; properties = @('CountriesAndRegions') }) }
        $r.created | Should -BeTrue
        $saved = Get-Content -LiteralPath (Join-Path $root "requests/$($r.requestId).json") -Raw | ConvertFrom-Json
        $saved.action | Should -Be 'AcceptRisk'
        $saved.standard | Should -Be 'asd'
        $saved.items[0].approvedBy | Should -Be 'J. Citizen'
        $saved.items[0].why | Should -Be 'NZ staff'
        @($saved.items[0].properties) | Should -Be @('CountriesAndRegions')
        (Get-Content -LiteralPath (Join-Path $root "activity/$($r.jobId).json") -Raw | ConvertFrom-Json).status | Should -Be 'Queued'
    }

    It 'claims the next blueprint version for Adopt, as Promote does' {
        $root = New-TestDataRoot
        $id = Get-RowId $root 'AADNamedLocationPolicy' 'Allowed Countries'
        $r = New-PEGuiRequest -DataRoot $root -Request @{ action = 'Adopt'; tenantId = 'master'; standard = 'asd'; reason = 'adopt'; confirmedMasterWrite = $true; items = @(@{ itemId = $id }) }
        $r.created | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $root "activity/$($r.jobId).json") -Raw | ConvertFrom-Json).blueprintVersionAfter | Should -Be 8
        (Get-PEGuiRequestPreview -DataRoot $root -Request @{ action = 'Adopt'; tenantId = 'master'; standard = 'asd'; reason = 'adopt'; confirmedMasterWrite = $true; items = @(@{ itemId = (Get-RowId $root 'IntuneSettingCatalogCustomPolicyWindows10' 'Edge hardening') }) }).blueprintVersionAfter | Should -Be 9
    }

    It 'returns errors and writes nothing for an invalid request' {
        $root = New-TestDataRoot
        $r = New-PEGuiRequest -DataRoot $root -Request @{ action = 'AcceptRisk'; tenantId = 'master'; standard = 'asd'; items = @(@{ itemId = 'Nope~x'; approvedBy = 'a'; why = 'b' }) }
        $r.created | Should -BeFalse
        @($r.errors).Count | Should -BeGreaterThan 0
    }

    It 'gives the mock job timer a result text for each standards action' {
        $root = New-TestDataRoot
        $r = New-PEGuiRequest -DataRoot $root -Request @{ action = 'CheckStandardRelease'; standard = 'asd' }
        $r.created | Should -BeTrue
        Update-PEGuiMockJob -DataRoot $root -Now ([datetime]::UtcNow.AddSeconds(10))
        (Get-Content -LiteralPath (Join-Path $root "activity/$($r.jobId).json") -Raw | ConvertFrom-Json).result | Should -BeLike '*(mock)*'
    }
}

Describe 'Mock standards data' {
    BeforeAll {
        $script:Views = @(Get-ChildItem -Path (Join-Path $script:MockData 'tenants') -Recurse -Filter '*.json' | Where-Object { $_.DirectoryName -like '*standards' } |
                ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.checked })
        $script:Coverage = Get-Content -LiteralPath (Join-Path $script:MockData 'standards/asd/coverage.json') -Raw | ConvertFrom-Json
    }

    It 'has at least one checked tenant to show' {
        @($script:Views).Count | Should -BeGreaterThan 0
    }

    It 'adds up: every setting is in exactly one of match, differ, accepted, not readable and not covered' {
        foreach ($view in $script:Views)
        {
            $h = $view.headline
            ($h.match + $h.differ + $h.accepted + $h.notReadable + $h.notCovered) | Should -Be $h.total
            ($h.match + $h.differ + $h.accepted) | Should -Be $h.checked
            foreach ($w in @($view.byWorkload))
            {
                ($w.match + $w.differ + $w.accepted + $w.notReadable + $w.notCovered) | Should -Be $w.total -Because $w.workload
            }
            (@($view.byWorkload | Measure-Object -Property total -Sum).Sum) | Should -Be $h.total
        }
    }

    It 'agrees with its own rows and with the coverage list' {
        foreach ($view in $script:Views)
        {
            @($view.rows | Where-Object status -NE 'accepted').Count | Should -Be $view.headline.differ
            @($view.rows | Where-Object status -EQ 'accepted').Count | Should -Be $view.headline.accepted
            @($view.rows | Where-Object status -EQ 'lookAgain').Count | Should -Be $view.headline.lookAgain
            $view.headline.notCovered | Should -Be ($script:Coverage.total - $script:Coverage.covered)
            $view.headline.covered | Should -Be $script:Coverage.covered
        }
        @($script:Coverage.rows).Count | Should -Be ($script:Coverage.total - $script:Coverage.covered)
        (($script:Coverage.byReason.PSObject.Properties | Measure-Object -Property Value -Sum).Sum) | Should -Be @($script:Coverage.rows).Count
    }

    It 'gives every row the item id the page and the server derive' {
        foreach ($view in $script:Views)
        {
            foreach ($row in @($view.rows))
            {
                $row.itemId | Should -Be (ConvertTo-PEGuiItemId -ResourceType $row.resourceType -Key $row.key)
            }
        }
    }
}
