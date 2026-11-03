BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures\upload'
    $script:FpA = ('a' * 64)
    $script:FpB = ('b' * 64)

    function New-ExportCopy
    {
        param ([string]$Fixture)
        $folder = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-rd-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Fixtures $Fixture) -Destination (Join-Path $folder 'export.ps1')
        Set-Content -LiteralPath (Join-Path $folder 'export.log') -Value '' -Encoding utf8
        $folder
    }
    function Get-Comparison
    {
        param ([string]$Target = 'entra-drift.ps1')
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-rd-root-' + [guid]::NewGuid().ToString('N'))
        Invoke-PEExportComparison -SourceExportPath (New-ExportCopy 'entra.ps1') -TargetExportPath (New-ExportCopy $Target) `
            -TargetTenantDomain 'contoso-dev.onmicrosoft.com' -DataRoot $root -CompleteWorkload 'AAD' -WarningAction SilentlyContinue
    }
    function Get-Data
    {
        param ([object]$Comparison, [string]$FpSource = $script:FpA, [string]$FpTarget = $script:FpB, [hashtable]$Extra = @{})
        Get-PEDriftReportData -Comparison $Comparison -Tenant 'dev' @Extra `
            -Source @{ Run = '101'; ExportedAt = '2026-11-03T10:00:00Z'; Fingerprint = $FpSource } `
            -Target @{ Run = '102'; ExportedAt = '2026-11-03T10:05:00Z'; Fingerprint = $FpTarget }
    }
    $script:Cmp = Get-Comparison
}

Describe 'Get-PEDriftReportData' {
    It 'lists Create Finance, Update Sales and Remove Marketing' {
        $d = Get-Data $script:Cmp
        @($d.Items.Id) | Should -Be @('Create|AADGroup|Finance', 'Remove|AADGroup|Marketing', 'Update|AADGroup|Sales')
        ($d.Items | Where-Object Approvable -eq $false).Count | Should -Be 0
    }

    It 'shows the differing property with both values' {
        $d = Get-Data $script:Cmp
        $sales = $d.Items | Where-Object Key -eq 'Sales'
        @($sales.Differences).Count | Should -Be 1
        $sales.Differences[0].Property | Should -Be 'MailNickname'
        $sales.Differences[0].PreProd | Should -BeOfType [string]
        $sales.Differences[0].Dev | Should -BeOfType [string]
        $sales.Differences[0].Dev | Should -Not -Be $sales.Differences[0].PreProd
    }

    It 'counts approvable items per action and keeps Matching honest' {
        $d = Get-Data $script:Cmp
        $d.Totals.Create | Should -Be 1
        $d.Totals.Update | Should -Be 1
        $d.Totals.Remove | Should -Be 1
        $d.Totals.CannotApprove | Should -Be 0
        $sourceRecords = @($script:Cmp.SourceState.Records).Count
        $d.Totals.Matching | Should -Be ($sourceRecords - 2)
    }

    It 'has every record matching when nothing differs' {
        $same = Get-Comparison -Target 'entra.ps1'
        $d = Get-Data $same
        @($d.Items).Count | Should -Be 0
        $d.Totals.Matching | Should -Be @($same.SourceState.Records).Count
        $d.Totals.Total | Should -Be @($same.SourceState.Records).Count
    }

    It 'marks an item the engine refuses as not approvable with its reason' {
        Mock -ModuleName PolicyEngine New-PERectifyPlan { throw "refused for test`nsecond line" } -ParameterFilter { @($Findings)[0].Key -eq 'Sales' }
        Mock -ModuleName PolicyEngine New-PERectifyPlan { @($Findings | ForEach-Object { [pscustomobject]@{ ResourceType = $_.ResourceType; Key = $_.Key } }) } -ParameterFilter { @($Findings)[0].Key -ne 'Sales' }
        $d = Get-Data $script:Cmp
        $sales = $d.Items | Where-Object Key -eq 'Sales'
        $sales.Approvable | Should -BeFalse
        $sales.Reason | Should -Be 'refused for test'
        ($d.Items | Where-Object Key -eq 'Finance').Approvable | Should -BeTrue
        $d.Totals.CannotApprove | Should -Be 1
        $d.Totals.Update | Should -Be 0
    }

    It 'gives a non-actionable kind no action' {
        $cmp = Get-Comparison
        $ambiguous = [pscustomobject]@{ Kind = 'Ambiguous'; ResourceType = 'AADGroup'; Key = 'Dup'; Workload = 'Entra ID'; State = 'Open'
            Hint = 'Key matches 2 blueprint and 2 target records'; Differences = @(); BlueprintCount = 2; TargetCount = 2 }
        $cmp = [pscustomobject]@{ Findings = @($cmp.Findings + $ambiguous); Check = $cmp.Check; Blueprint = $cmp.Blueprint; DataRoot = $cmp.DataRoot; SourceState = $cmp.SourceState }
        $d = Get-Data $cmp
        $dup = $d.Items | Where-Object Key -eq 'Dup'
        $dup.Action | Should -BeNullOrEmpty
        $dup.Approvable | Should -BeFalse
        $dup.Reason | Should -BeLike 'Key matches*'
        $dup.Id | Should -Be 'Ambiguous|AADGroup|Dup'
        $d.Totals.CannotApprove | Should -Be 1
    }

    It 'cuts a long value' {
        $cmp = Get-Comparison
        $long = 'x' * 10000
        $cmp.Findings | Where-Object { $_.Kind -eq 'Changed' } | ForEach-Object { $_.Differences[0].Target = $long }
        $d = Get-Data $cmp -Extra @{ MaxValueLength = 50 }
        $dev = ($d.Items | Where-Object Key -eq 'Sales').Differences[0].Dev
        $dev.Length | Should -BeLessOrEqual 51
        $dev | Should -BeLike '*…'
    }

    It 'does not embed matching resources' {
        @((Get-Data $script:Cmp).Items).Count | Should -Be 3
    }

    It 'ReportId is stable for the same fingerprints and changes with either one' {
        $a = (Get-Data $script:Cmp).Meta.ReportId
        $a | Should -Match '\A[0-9a-f]{64}\z'
        (Get-Data $script:Cmp).Meta.ReportId | Should -Be $a
        (Get-Data $script:Cmp -FpSource ('c' * 64)).Meta.ReportId | Should -Not -Be $a
        (Get-Data $script:Cmp -FpTarget ('c' * 64)).Meta.ReportId | Should -Not -Be $a
    }

    It 'carries the meta an approved list needs' {
        $m = (Get-Data $script:Cmp).Meta
        $m.Tenant | Should -Be 'dev'
        $m.Source.Run | Should -Be '101'
        $m.Target.Fingerprint | Should -Be $script:FpB
        $m.ModuleVersion | Should -Match '\A\d+(\.\d+){1,3}\z'
    }

    Context 'eligibility rules that mirror New-PEOfflineConfig' {
        BeforeAll {
            function Get-WithExtra
            {
                param ([hashtable]$Finding)
                $cmp = Get-Comparison
                $extra = [pscustomobject]$Finding
                [pscustomobject]@{ Findings = @($cmp.Findings + $extra); Check = $cmp.Check; Blueprint = $cmp.Blueprint; DataRoot = $cmp.DataRoot; SourceState = $cmp.SourceState }
            }
        }

        It 'does not offer to remove an object of a type PreProd has no records of' {
            $cmp = Get-WithExtra @{ Kind = 'TargetOnly'; ResourceType = 'EXOAcceptedDomain'; Key = 'contoso.com'; Workload = 'Exchange'; State = 'Open'; Hint = ''; Differences = @() }
            $item = (Get-Data $cmp).Items | Where-Object Key -eq 'contoso.com'
            $item.Action | Should -Be 'Remove'
            $item.Approvable | Should -BeFalse
            $item.Reason | Should -BeLike "*no records in PreProd*"
        }

        It 'does not offer an item that carries a hint, and shows the hint' {
            $cmp = Get-WithExtra @{ Kind = 'Missing'; ResourceType = 'AADGroup'; Key = 'Hinted'; Workload = 'Entra ID'; State = 'Open'; Hint = 'checked by hand'; Differences = @() }
            $item = (Get-Data $cmp).Items | Where-Object Key -eq 'Hinted'
            $item.Approvable | Should -BeFalse
            $item.Reason | Should -Be 'checked by hand'
        }

        It 'does not offer an actionable finding that has no key' {
            $cmp = Get-WithExtra @{ Kind = 'Missing'; ResourceType = 'AADGroup'; Key = ''; Workload = 'Entra ID'; State = 'Open'; Hint = ''; Differences = @() }
            $item = (Get-Data $cmp).Items | Where-Object { $_.Kind -eq 'Missing' -and $_.Key -eq '' }
            $item.Approvable | Should -BeFalse
            $item.Reason | Should -BeLike '*without a key'
        }

        It 'leaves out findings that are not open' {
            $cmp = Get-WithExtra @{ Kind = 'Missing'; ResourceType = 'AADGroup'; Key = 'Closed'; Workload = 'Entra ID'; State = 'Accepted'; Hint = ''; Differences = @() }
            @((Get-Data $cmp).Items | Where-Object Key -eq 'Closed').Count | Should -Be 0
        }
    }

    Context 'cost at scale' {
        BeforeAll {
            function Get-WithMany
            {
                param ([string[]]$Keys)
                $cmp = Get-Comparison
                $extra = foreach ($k in $Keys) { [pscustomobject]@{ Kind = 'Missing'; ResourceType = 'AADGroup'; Key = $k; Workload = 'Entra ID'; State = 'Open'; Hint = ''; Differences = @() } }
                [pscustomobject]@{ Findings = @($cmp.Findings + $extra); Check = $cmp.Check; Blueprint = $cmp.Blueprint; DataRoot = $cmp.DataRoot; SourceState = $cmp.SourceState }
            }
        }

        It 'asks the engine once per action when nothing is refused (each call indexes every record)' {
            Mock -ModuleName PolicyEngine New-PERectifyPlan { @($Findings | ForEach-Object { [pscustomobject]@{ ResourceType = $_.ResourceType; Key = $_.Key } }) }
            $cmp = Get-WithMany (1..8 | ForEach-Object { "many$_" })
            $d = Get-Data $cmp
            @($d.Items | Where-Object { $_.Action -eq 'Create' -and -not $_.Approvable }).Count | Should -Be 0
            Should -Invoke -ModuleName PolicyEngine New-PERectifyPlan -Times 1 -Exactly -ParameterFilter { $Action -eq 'Create' }
        }

        It 'still finds the one refused item among many and gives it the engine message, in far fewer calls than items' {
            $global:PEPlanCalls = 0
            Mock -ModuleName PolicyEngine New-PERectifyPlan { $global:PEPlanCalls++; if (@($Findings).Key -contains 'many5') { throw 'many5 is refused' }; @($Findings | ForEach-Object { [pscustomobject]@{ ResourceType = $_.ResourceType; Key = $_.Key } }) }
            $cmp = Get-WithMany (1..40 | ForEach-Object { "many$_" })
            $d = Get-Data $cmp
            $refused = @($d.Items | Where-Object { $_.Action -eq 'Create' -and -not $_.Approvable })
            @($refused.Key) | Should -Be @('many5')
            $refused[0].Reason | Should -Be 'many5 is refused'
            @($d.Items | Where-Object { $_.Key -like 'many*' -and $_.Approvable }).Count | Should -Be 39
            $global:PEPlanCalls | Should -BeLessThan 25 -Because '41 Create items asked one by one would be 41 calls'
            Remove-Variable -Name PEPlanCalls -Scope Global
        }
    }

    Context 'not compared is separate from drift' {
        BeforeAll {
            function Get-WithKinds
            {
                param ([string[]]$Kinds)
                $cmp = Get-Comparison
                $extra = foreach ($k in $Kinds) { [pscustomobject]@{ Kind = $k; ResourceType = "Type$k"; Key = $null; Workload = 'W'; State = 'Open'; Hint = "reason for $k"; Differences = @() } }
                [pscustomobject]@{ Findings = @($cmp.Findings + $extra); Check = $cmp.Check; Blueprint = $cmp.Blueprint; DataRoot = $cmp.DataRoot; SourceState = $cmp.SourceState }
            }
        }

        It 'marks Excluded, NotChecked and NotAvailable as not compared and counts them apart from Cannot be approved' {
            $d = Get-Data (Get-WithKinds 'Excluded', 'NotChecked', 'NotAvailable')
            $nc = @($d.Items | Where-Object NotCompared)
            @($nc.Kind | Sort-Object) | Should -Be @('Excluded', 'NotAvailable', 'NotChecked')
            ($nc | ForEach-Object Approvable) | Should -Not -Contain $true
            ($nc | Where-Object Kind -eq 'Excluded').Reason | Should -Be 'reason for Excluded'
            $d.Totals.NotCompared | Should -Be 3
            $d.Totals.CannotApprove | Should -Be 0
        }

        It 'keeps Ambiguous and PossibleRename as drift that cannot be approved' {
            $d = Get-Data (Get-WithKinds 'Ambiguous', 'PossibleRename')
            @($d.Items | Where-Object NotCompared).Count | Should -Be 0
            $d.Totals.CannotApprove | Should -Be 2
            $d.Totals.NotCompared | Should -Be 0
        }

        It 'does not mark real drift as not compared' {
            $d = Get-Data $script:Cmp
            @($d.Items | Where-Object NotCompared).Count | Should -Be 0
            $d.Totals.NotCompared | Should -Be 0
        }
    }

    Context 'labels' {
        It 'defaults to PreProd and Dev' {
            $m = (Get-Data $script:Cmp).Meta
            $m.SourceLabel | Should -Be 'PreProd'
            $m.TargetLabel | Should -Be 'Dev'
        }

        It 'carries the labels it is given' {
            $m = (Get-Data $script:Cmp -Extra @{ SourceLabel = 'master'; TargetLabel = 'contoso' }).Meta
            $m.SourceLabel | Should -Be 'master'
            $m.TargetLabel | Should -Be 'contoso'
        }

        It 'refuses a label that is not plain text' {
            { Get-Data $script:Cmp -Extra @{ SourceLabel = '<b>x</b>' } } | Should -Throw
        }
    }

    Context 'every property of both sides, per resource' {
        It 'gives a changed item every property of both sides, with a state per property' {
            $sales = (Get-Data $script:Cmp).Items | Where-Object Key -eq 'Sales'
            $byName = @{}
            foreach ($p in $sales.Props) { $byName[$p.Property] = $p }
            $byName['MailNickname'].State | Should -Be 'different'
            $byName['MailNickname'].Source | Should -Be 'sales'
            $byName['MailNickname'].Target | Should -Not -Be 'sales'
            $byName['DisplayName'].State | Should -Be 'same'
            $byName['DisplayName'].Source | Should -Be $byName['DisplayName'].Target
            @($sales.Props).Count | Should -BeGreaterThan 3
        }

        It 'shows a create with only the source side and a remove with only the target side' {
            $d = Get-Data $script:Cmp
            $finance = $d.Items | Where-Object Key -eq 'Finance'
            @($finance.Props).Count | Should -BeGreaterThan 0
            ($finance.Props | ForEach-Object State | Sort-Object -Unique) | Should -Be @('only-source')
            ($finance.Props | ForEach-Object Target | Where-Object { $null -ne $_ }).Count | Should -Be 0
            $marketing = $d.Items | Where-Object Key -eq 'Marketing'
            ($marketing.Props | ForEach-Object State | Sort-Object -Unique) | Should -Be @('only-target')
            ($marketing.Props | ForEach-Object Source | Where-Object { $null -ne $_ }).Count | Should -Be 0
        }

        It 'marks a property that differs in the records but not in the findings as ignored' {
            $cmp = Get-Comparison
            $sales = $cmp.Findings | Where-Object { $_.Kind -eq 'Changed' -and $_.Key -eq 'Sales' }
            # a property the engine did not report (for example a tenant-bound id) but whose values differ on the page
            $sales.TargetRecord.Properties | Add-Member -NotePropertyName Description -NotePropertyValue 'only in the replica' -Force
            $sales.BlueprintRecord.Properties | Add-Member -NotePropertyName Description -NotePropertyValue 'only in the master' -Force
            $row = ((Get-Data $cmp).Items | Where-Object Key -eq 'Sales').Props | Where-Object Property -eq 'Description'
            $row.State | Should -Be 'ignored'
        }

        It 'gives an item without records no property rows' {
            $cmp = Get-Comparison
            $extra = [pscustomobject]@{ Kind = 'NotChecked'; ResourceType = 'EXOAcceptedDomain'; Key = $null; Workload = 'Exchange Online'; State = 'Open'; Hint = 'x'; Differences = @() }
            $cmp = [pscustomobject]@{ Findings = @($cmp.Findings + $extra); Check = $cmp.Check; Blueprint = $cmp.Blueprint; DataRoot = $cmp.DataRoot; SourceState = $cmp.SourceState }
            $item = (Get-Data $cmp).Items | Where-Object { $_.Kind -eq 'NotChecked' }
            @($item.Props).Count | Should -Be 0
        }

        It 'cuts a long property value' {
            $cmp = Get-Comparison
            ($cmp.Findings | Where-Object { $_.Kind -eq 'Changed' }).BlueprintRecord.Properties | Add-Member -NotePropertyName Description -NotePropertyValue ('x' * 10000) -Force
            $row = ((Get-Data $cmp -Extra @{ MaxValueLength = 50 }).Items | Where-Object Key -eq 'Sales').Props | Where-Object Property -eq 'Description'
            $row.Source.Length | Should -BeLessOrEqual 51
        }
    }

    Context 'totals per type and workload order' {
        It 'counts the records of each type on both sides' {
            $d = Get-Data $script:Cmp
            $group = @($d.Types | Where-Object ResourceType -eq 'AADGroup')
            $group.Count | Should -Be 1
            $group[0].Workload | Should -Be 'Entra ID'
            $group[0].Source | Should -Be @($script:Cmp.SourceState.Records | Where-Object ResourceType -eq 'AADGroup').Count
            $group[0].Target | Should -Be @($script:Cmp.Check.State.Records | Where-Object ResourceType -eq 'AADGroup').Count
        }

        It 'lists a type that only has drift items even when neither side has records of it' {
            $cmp = Get-Comparison
            $extra = [pscustomobject]@{ Kind = 'NotChecked'; ResourceType = 'EXOAcceptedDomain'; Key = $null; Workload = 'Exchange Online'; State = 'Open'; Hint = 'x'; Differences = @() }
            $cmp = [pscustomobject]@{ Findings = @($cmp.Findings + $extra); Check = $cmp.Check; Blueprint = $cmp.Blueprint; DataRoot = $cmp.DataRoot; SourceState = $cmp.SourceState }
            $t = @((Get-Data $cmp).Types | Where-Object ResourceType -eq 'EXOAcceptedDomain')
            $t.Count | Should -Be 1
            $t[0].Source | Should -Be 0
            $t[0].Workload | Should -Be 'Exchange Online'
        }

        It 'gives the workload order of the engine, ending with Other' {
            $order = @((Get-Data $script:Cmp).Meta.WorkloadOrder)
            $order[0] | Should -Be 'Entra ID'
            $order | Should -Contain 'Exchange Online'
            $order[-1] | Should -Be 'Other'
        }
    }
}

