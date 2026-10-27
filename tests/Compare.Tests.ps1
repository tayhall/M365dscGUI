BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force

    function New-TestRecord
    {
        param
        (
            [string]$Type = 'AADGroup',
            [AllowNull()]
            [string]$Key,
            [System.Collections.IDictionary]$Properties = @{}
        )

        $props = [ordered]@{}
        if ($Key)
        {
            $props['DisplayName'] = $Key
        }
        # get_Keys(): a property named Keys would shadow .Keys on a dictionary.
        foreach ($name in $Properties.get_Keys())
        {
            $props[$name] = $Properties[$name]
        }
        [pscustomobject]@{
            ResourceType = $Type
            Key          = $(if ($Key) { $Key } else { $null })
            Workload     = 'Entra ID'
            Properties   = $props
        }
    }

    function New-TestState
    {
        param
        (
            [object[]]$Records = @(),
            [object[]]$NotChecked = @()
        )

        # New-PEState is private to the module.
        & (Get-Module PolicyEngine) {
            param ($r, $n)
            New-PEState -Records $r -NotChecked $n -Meta @{ TenantId = 't'; ExportedAt = '2026-10-21'; Source = 'test' }
        } $Records $NotChecked
    }

    function New-TestDecision
    {
        param
        (
            [string]$Kind,
            [string]$Type = 'AADGroup',
            [string]$Key,
            [string]$Property,
            $Value
        )

        [pscustomobject]@{
            Kind         = $Kind
            ResourceType = $Type
            Key          = $(if ($Key) { $Key } else { $null })
            Property     = $(if ($Property) { $Property } else { $null })
            Value        = $Value
            Reason       = 'test'
            At           = '2026-10-21T00:00:00.000Z'
        }
    }
}

Describe 'Compare-PEState' {
    It 'is exported' {
        (Get-Command -Module PolicyEngine).Name | Should -Contain 'Compare-PEState'
    }

    It 'identical states produce no findings' {
        $b = New-TestState -Records @(
            (New-TestRecord -Key 'Sales' -Properties ([ordered]@{ MailEnabled = $false; Roles = @('a', 'b') })),
            (New-TestRecord -Type 'AADConditionalAccessPolicy' -Key 'Require MFA' -Properties ([ordered]@{ State = 'enabled' }))
        )
        $t = New-TestState -Records @(
            (New-TestRecord -Key 'Sales' -Properties ([ordered]@{ MailEnabled = $false; Roles = @('a', 'b') })),
            (New-TestRecord -Type 'AADConditionalAccessPolicy' -Key 'Require MFA' -Properties ([ordered]@{ State = 'enabled' }))
        )
        @(Compare-PEState -Blueprint $b -Target $t).Count | Should -Be 0
    }

    It 'empty states and no decisions produce no findings' {
        @(Compare-PEState -Blueprint (New-TestState) -Target (New-TestState) -Decisions @()).Count | Should -Be 0
        @(Compare-PEState -Blueprint (New-TestState) -Target (New-TestState) -Decisions $null).Count | Should -Be 0
    }

    It 'blueprint-only record is Missing' {
        $rec = New-TestRecord -Key 'Sales' -Properties @{ MailEnabled = $false }
        $f = @(Compare-PEState -Blueprint (New-TestState -Records @($rec)) -Target (New-TestState))
        $f.Count | Should -Be 1
        $f[0].Kind | Should -Be 'Missing'
        $f[0].ResourceType | Should -Be 'AADGroup'
        $f[0].Key | Should -Be 'Sales'
        $f[0].Workload | Should -Be 'Entra ID'
        $f[0].State | Should -Be 'Open'
        @($f[0].Differences).Count | Should -Be 0
        $f[0].BlueprintRecord | Should -Be $rec
        $f[0].TargetRecord | Should -BeNullOrEmpty
    }

    It 'target-only record is TargetOnly' {
        $rec = New-TestRecord -Key 'Dev Group' -Properties @{ MailEnabled = $true }
        $f = @(Compare-PEState -Blueprint (New-TestState) -Target (New-TestState -Records @($rec)))
        $f.Count | Should -Be 1
        $f[0].Kind | Should -Be 'TargetOnly'
        $f[0].Key | Should -Be 'Dev Group'
        $f[0].State | Should -Be 'Open'
        $f[0].TargetRecord | Should -Be $rec
        $f[0].BlueprintRecord | Should -BeNullOrEmpty
    }

    It 'different property is Changed and names the property with both values' {
        $b = New-TestState -Records @(New-TestRecord -Key 'Sales' -Properties ([ordered]@{ MailEnabled = $false; Description = 'same' }))
        $t = New-TestState -Records @(New-TestRecord -Key 'Sales' -Properties ([ordered]@{ MailEnabled = $true; Description = 'same' }))
        $f = @(Compare-PEState -Blueprint $b -Target $t)
        $f.Count | Should -Be 1
        $f[0].Kind | Should -Be 'Changed'
        $f[0].Key | Should -Be 'Sales'
        $d = @($f[0].Differences)
        $d.Count | Should -Be 1
        $d[0].Property | Should -Be 'MailEnabled'
        $d[0].Blueprint | Should -Be $false
        $d[0].Target | Should -Be $true
        $f[0].BlueprintRecord.Properties.MailEnabled | Should -Be $false
        $f[0].TargetRecord.Properties.MailEnabled | Should -Be $true
    }

    It 'key match ignores case' {
        $b = New-TestState -Records @(New-TestRecord -Key 'Sales' -Properties @{ X = 1 })
        $t = New-TestState -Records @(New-TestRecord -Key 'SALES' -Properties @{ X = 1 })
        $t.Records[0].Properties.DisplayName = 'Sales'
        @(Compare-PEState -Blueprint $b -Target $t).Count | Should -Be 0
    }

    It 'resource type match ignores case' {
        $b = New-TestState -Records @(New-TestRecord -Type 'AADGroup' -Key 'Sales')
        $t = New-TestState -Records @(New-TestRecord -Type 'aadgroup' -Key 'Sales')
        @(Compare-PEState -Blueprint $b -Target $t).Count | Should -Be 0
    }

    It 'duplicate key in the target is Ambiguous and produces no Missing or TargetOnly' {
        $b = New-TestState -Records @(New-TestRecord -Key 'Finance' -Properties @{ X = 1 })
        $t = New-TestState -Records @(
            (New-TestRecord -Key 'Finance' -Properties @{ X = 1 }),
            (New-TestRecord -Key 'Finance' -Properties @{ X = 2 })
        )
        $f = @(Compare-PEState -Blueprint $b -Target $t)
        $f.Count | Should -Be 1
        $f[0].Kind | Should -Be 'Ambiguous'
        $f[0].Key | Should -Be 'Finance'
        @($f | Where-Object Kind -in 'Missing', 'TargetOnly', 'Changed', 'PossibleRename').Count | Should -Be 0
        $f[0].BlueprintCount | Should -Be 1
        $f[0].TargetCount | Should -Be 2
    }

    It 'target-only duplicate key is Ambiguous with BlueprintCount 0' {
        $t = New-TestState -Records @(
            (New-TestRecord -Key 'Finance' -Properties @{ X = 1 }),
            (New-TestRecord -Key 'Finance' -Properties @{ X = 2 })
        )
        $f = @(Compare-PEState -Blueprint (New-TestState) -Target $t)
        $f[0].Kind | Should -Be 'Ambiguous'
        $f[0].BlueprintCount | Should -Be 0
        $f[0].TargetCount | Should -Be 2
    }

    It 'non-Ambiguous findings have null counts' {
        $b = New-TestState -Records @(New-TestRecord -Key 'A' -Properties @{ X = 1 })
        $f = @(Compare-PEState -Blueprint $b -Target (New-TestState))
        $f[0].Kind | Should -Be 'Missing'
        $f[0].BlueprintCount | Should -BeNullOrEmpty
    }

    It 'duplicate key in the blueprint is Ambiguous' {
        $b = New-TestState -Records @(
            (New-TestRecord -Key 'Finance' -Properties @{ X = 1 }),
            (New-TestRecord -Key 'Finance' -Properties @{ X = 2 })
        )
        $f = @(Compare-PEState -Blueprint $b -Target (New-TestState))
        $f.Count | Should -Be 1
        $f[0].Kind | Should -Be 'Ambiguous'
        $f[0].BlueprintCount | Should -Be 2
        $f[0].TargetCount | Should -Be 0
    }

    It 'keys that differ only by case within one state are Ambiguous' {
        $t = New-TestState -Records @(
            (New-TestRecord -Key 'Finance'),
            (New-TestRecord -Key 'FINANCE')
        )
        $f = @(Compare-PEState -Blueprint (New-TestState) -Target $t)
        $f.Count | Should -Be 1
        $f[0].Kind | Should -Be 'Ambiguous'
    }

    It 'Ambiguous records never take part in rename matching' {
        $b = New-TestState -Records @(New-TestRecord -Key 'Old' -Properties ([ordered]@{ A = 1; B = 2; C = 3; D = 4; E = 5; F = 6; G = 7; H = 8; I = 9 }))
        $t = New-TestState -Records @(
            (New-TestRecord -Key 'New' -Properties ([ordered]@{ A = 1; B = 2; C = 3; D = 4; E = 5; F = 6; G = 7; H = 8; I = 9 })),
            (New-TestRecord -Key 'New' -Properties ([ordered]@{ A = 1; B = 2; C = 3; D = 4; E = 5; F = 6; G = 7; H = 8; I = 9 }))
        )
        $f = @(Compare-PEState -Blueprint $b -Target $t)
        $f.Count | Should -Be 2
        ($f | Where-Object Key -eq 'Old').Kind | Should -Be 'Missing'
        ($f | Where-Object Key -eq 'New').Kind | Should -Be 'Ambiguous'
    }

    It 'type in Target.NotChecked yields NotChecked and never Missing' {
        $b = New-TestState -Records @(
            (New-TestRecord -Type 'EXOAvailabilityConfig' -Key 'a'),
            (New-TestRecord -Type 'EXOAvailabilityConfig' -Key 'b'),
            (New-TestRecord -Key 'Sales')
        )
        $t = New-TestState -Records @(New-TestRecord -Key 'Sales') -NotChecked @(@{ ResourceType = 'EXOAvailabilityConfig'; Reason = 'export failed: 403' })
        $f = @(Compare-PEState -Blueprint $b -Target $t)
        $f.Count | Should -Be 1
        $f[0].Kind | Should -Be 'NotChecked'
        $f[0].ResourceType | Should -Be 'EXOAvailabilityConfig'
        $f[0].Workload | Should -Be 'Exchange Online'
        $f[0].Hint | Should -BeLike '*403*'
        $f[0].State | Should -Be 'Open'
    }

    It 'type in Target.NotChecked yields no TargetOnly, Changed or Unkeyed for partial target records of that type' {
        $b = New-TestState -Records @(New-TestRecord -Type 'EXOAvailabilityConfig' -Key 'a' -Properties @{ X = 1 })
        $t = New-TestState -Records @(
            (New-TestRecord -Type 'EXOAvailabilityConfig' -Key 'a' -Properties @{ X = 2 }),
            (New-TestRecord -Type 'EXOAvailabilityConfig' -Key 'z'),
            (New-TestRecord -Type 'EXOAvailabilityConfig' -Key $null)
        ) -NotChecked @(@{ ResourceType = 'EXOAvailabilityConfig'; Reason = 'r' })
        $f = @(Compare-PEState -Blueprint $b -Target $t)
        $f.Count | Should -Be 1
        $f[0].Kind | Should -Be 'NotChecked'
    }

    It 'type only in Blueprint.NotChecked yields NotChecked and never TargetOnly' {
        $b = New-TestState -NotChecked @([pscustomobject]@{ ResourceType = 'TeamsMeetingPolicy'; Reason = 'blueprint export failed' })
        $t = New-TestState -Records @(New-TestRecord -Type 'TeamsMeetingPolicy' -Key 'Global')
        $f = @(Compare-PEState -Blueprint $b -Target $t)
        $f.Count | Should -Be 1
        $f[0].Kind | Should -Be 'NotChecked'
        $f[0].ResourceType | Should -Be 'TeamsMeetingPolicy'
        $f[0].Hint | Should -BeLike '*blueprint*'
    }

    It 'type in both NotChecked lists is NotAvailable' {
        $b = New-TestState -NotChecked @(@{ ResourceType = 'EXOAvailabilityConfig'; Reason = 'not licensed' })
        $t = New-TestState -NotChecked @(@{ ResourceType = 'exoavailabilityconfig'; Reason = 'not licensed' }, @{ ResourceType = 'EXOAvailabilityConfig'; Reason = 'dup' })
        $f = @(Compare-PEState -Blueprint $b -Target $t)
        $f.Count | Should -Be 1
        $f[0].Kind | Should -Be 'NotAvailable'
        $f[0].ResourceType | Should -Be 'EXOAvailabilityConfig'
    }

    It 'Missing plus similar TargetOnly of same type become PossibleRename' {
        $props = [ordered]@{ A = 1; B = 2; C = 3; D = 4; E = 5; F = 6; G = 7; H = 8; I = 9 }
        $b = New-TestState -Records @(New-TestRecord -Key 'Old Name' -Properties $props)
        $t = New-TestState -Records @(New-TestRecord -Key 'New Name' -Properties $props)
        $f = @(Compare-PEState -Blueprint $b -Target $t)
        $f.Count | Should -Be 2
        $old = $f | Where-Object Key -eq 'Old Name'
        $new = $f | Where-Object Key -eq 'New Name'
        $old.Kind | Should -Be 'PossibleRename'
        $new.Kind | Should -Be 'PossibleRename'
        $old.Hint | Should -Be 'Possible rename of New Name'
        $new.Hint | Should -Be 'Possible rename of Old Name'
        $old.BlueprintRecord | Should -Not -BeNullOrEmpty
        $old.TargetRecord | Should -BeNullOrEmpty
        $new.TargetRecord | Should -Not -BeNullOrEmpty
        $new.BlueprintRecord | Should -BeNullOrEmpty
    }

    It 'dissimilar Missing and TargetOnly stay separate' {
        $b = New-TestState -Records @(New-TestRecord -Key 'Old' -Properties ([ordered]@{ A = 1; B = 2; C = 3 }))
        $t = New-TestState -Records @(New-TestRecord -Key 'New' -Properties ([ordered]@{ A = 9; B = 8; C = 3 }))
        $f = @(Compare-PEState -Blueprint $b -Target $t)
        $f.Count | Should -Be 2
        ($f | Where-Object Key -eq 'Old').Kind | Should -Be 'Missing'
        ($f | Where-Object Key -eq 'New').Kind | Should -Be 'TargetOnly'
        @($f | Where-Object Hint).Count | Should -Be 0
    }

    It 'similar Missing and TargetOnly of different types stay separate' {
        $props = [ordered]@{ A = 1; B = 2; C = 3; D = 4; E = 5; F = 6; G = 7; H = 8; I = 9 }
        $b = New-TestState -Records @(New-TestRecord -Type 'AADGroup' -Key 'Old' -Properties $props)
        $t = New-TestState -Records @(New-TestRecord -Type 'AADApplication' -Key 'New' -Properties $props)
        $f = @(Compare-PEState -Blueprint $b -Target $t)
        @($f | Where-Object Kind -eq 'PossibleRename').Count | Should -Be 0
    }

    It 'similarity at exactly the threshold is a rename and just below is not' {
        # 5 properties in the union (DisplayName + A..D); 4 equal = 0.8.
        $b = New-TestState -Records @(New-TestRecord -Key 'Old' -Properties ([ordered]@{ A = 1; B = 2; C = 3; D = 4 }))
        $t = New-TestState -Records @(New-TestRecord -Key 'New' -Properties ([ordered]@{ A = 1; B = 2; C = 3; D = 4 }))
        @(Compare-PEState -Blueprint $b -Target $t | Where-Object Kind -eq 'PossibleRename').Count | Should -Be 2
        @(Compare-PEState -Blueprint $b -Target $t -RenameThreshold 0.81 | Where-Object Kind -eq 'PossibleRename').Count | Should -Be 0
    }

    It 'Missing A similar to both T1 and T2 makes all three PossibleRename, each naming its counterparts' {
        $props = [ordered]@{ A = 1; B = 2; C = 3; D = 4; E = 5; F = 6; G = 7; H = 8; I = 9; J = 10; K = 11; L = 12; M = 13; N = 14; O = 15; P = 16; Q = 17; R = 18; S = 19 }
        # Union is DisplayName + A..S (20); 19 equal = 0.95 against both targets.
        $b = New-TestState -Records @(New-TestRecord -Key 'A' -Properties $props)
        $t = New-TestState -Records @(
            (New-TestRecord -Key 'T1' -Properties $props),
            (New-TestRecord -Key 'T2' -Properties $props)
        )
        $f = @(Compare-PEState -Blueprint $b -Target $t)
        $f.Count | Should -Be 3
        @($f | Where-Object Kind -eq 'PossibleRename').Count | Should -Be 3
        @($f | Where-Object Kind -eq 'TargetOnly').Count | Should -Be 0
        ($f | Where-Object Key -eq 'A').Hint | Should -Be 'Possible rename of T1, T2'
        ($f | Where-Object Key -eq 'T1').Hint | Should -Be 'Possible rename of A'
        ($f | Where-Object Key -eq 'T2').Hint | Should -Be 'Possible rename of A'
    }

    It 'a 2x2 tie makes all four PossibleRename, each hint naming both counterparts' {
        $props = [ordered]@{ A = 1; B = 2; C = 3; D = 4; E = 5; F = 6; G = 7; H = 8; I = 9 }
        $b = New-TestState -Records @((New-TestRecord -Key 'Old1' -Properties $props), (New-TestRecord -Key 'Old2' -Properties $props))
        $t = New-TestState -Records @((New-TestRecord -Key 'New1' -Properties $props), (New-TestRecord -Key 'New2' -Properties $props))
        $f = @(Compare-PEState -Blueprint $b -Target $t)
        $f.Count | Should -Be 4
        @($f | Where-Object Kind -eq 'PossibleRename').Count | Should -Be 4
        ($f | Where-Object Key -eq 'Old1').Hint | Should -Be 'Possible rename of New1, New2'
        ($f | Where-Object Key -eq 'Old2').Hint | Should -Be 'Possible rename of New1, New2'
        ($f | Where-Object Key -eq 'New1').Hint | Should -Be 'Possible rename of Old1, Old2'
        ($f | Where-Object Key -eq 'New2').Hint | Should -Be 'Possible rename of Old1, Old2'
    }

    It 'rename hint lists candidates in descending similarity' {
        # Old~NewB 0.9, Old~NewA 0.8 (union DisplayName + A..I).
        $b = New-TestState -Records @(New-TestRecord -Key 'Old' -Properties ([ordered]@{ A = 1; B = 2; C = 3; D = 4; E = 5; F = 6; G = 7; H = 8; I = 9 }))
        $t = New-TestState -Records @(
            (New-TestRecord -Key 'NewA' -Properties ([ordered]@{ A = 1; B = 2; C = 3; D = 4; E = 5; F = 6; G = 7; H = 8; I = 0 })),
            (New-TestRecord -Key 'NewB' -Properties ([ordered]@{ A = 1; B = 2; C = 3; D = 4; E = 5; F = 6; G = 7; H = 8; I = 9 }))
        )
        $f = @(Compare-PEState -Blueprint $b -Target $t)
        ($f | Where-Object Key -eq 'Old').Hint | Should -Be 'Possible rename of NewB, NewA'
    }

    It 'rename hint names at most five candidates and counts the rest' {
        $props = [ordered]@{ A = 1; B = 2; C = 3; D = 4; E = 5; F = 6; G = 7; H = 8; I = 9 }
        $b = New-TestState -Records @(New-TestRecord -Key 'Old' -Properties $props)
        $t = New-TestState -Records @(1..7 | ForEach-Object { New-TestRecord -Key "New$_" -Properties $props })
        $f = @(Compare-PEState -Blueprint $b -Target $t)
        ($f | Where-Object Key -eq 'Old').Hint | Should -Be 'Possible rename of New1, New2, New3, New4, New5 and 2 more'
    }

    It 'two distinct default-heavy records do not match once both-empty and Ensure properties are ignored' {
        $mk = {
            param ($key, $description)
            $p = [ordered]@{ Ensure = 'Present'; Description = $description }
            foreach ($n in 1..10)
            {
                $p["Empty$n"] = @($null, '', @())[$n % 3]
            }
            New-TestRecord -Key $key -Properties $p
        }
        $b = New-TestState -Records @(& $mk 'Finance' 'money')
        $t = New-TestState -Records @(& $mk 'Marketing' 'brand')
        $f = @(Compare-PEState -Blueprint $b -Target $t)
        ($f | Where-Object Key -eq 'Finance').Kind | Should -Be 'Missing'
        ($f | Where-Object Key -eq 'Marketing').Kind | Should -Be 'TargetOnly'
    }

    It 'rename similarity ignores both-empty properties and Ensure' {
        InModuleScope PolicyEngine {
            $a = Get-PESimilarityMap -Record ([pscustomobject]@{ Properties = [ordered]@{ Ensure = 'Present'; X = 'a'; Y = 'b'; E1 = $null; E2 = ''; E3 = @() } })
            $b = Get-PESimilarityMap -Record ([pscustomobject]@{ Properties = [ordered]@{ Ensure = 'Absent'; X = 'a'; Y = 'c'; E1 = @(); E2 = $null } })
            Get-PESimilarity -A $a -B $b | Should -Be 0.5
            # Empty on one side only stays in the union as unequal.
            $c = Get-PESimilarityMap -Record ([pscustomobject]@{ Properties = [ordered]@{ X = 'a'; Y = 'b'; Z = 'z' } })
            Get-PESimilarity -A $a -B $c | Should -Be (2 / 3)
        }
    }

    It 'rename check is skipped with a hint when a type has more pairs than the bound' {
        InModuleScope PolicyEngine {
            $saved = $script:PERenameMaxPairs
            try
            {
                $script:PERenameMaxPairs = 3
                $mk = { param ($k) [pscustomobject]@{ ResourceType = 'AADGroup'; Key = $k; Workload = 'Entra ID'; Properties = [ordered]@{ DisplayName = $k; A = 1; B = 2; C = 3; D = 4; E = 5; F = 6; G = 7; H = 8; I = 9 } } }
                $b = New-PEState -Records @((& $mk 'O1'), (& $mk 'O2')) -NotChecked @() -Meta @{}
                $t = New-PEState -Records @((& $mk 'N1'), (& $mk 'N2')) -NotChecked @() -Meta @{}
                $f = @(Compare-PEState -Blueprint $b -Target $t)
                @($f | Where-Object Kind -eq 'PossibleRename').Count | Should -Be 0
                @($f | Where-Object Kind -eq 'Missing').Count | Should -Be 2
                @($f | Where-Object Kind -eq 'TargetOnly').Count | Should -Be 2
                $f | ForEach-Object { $_.Hint | Should -Be 'Rename check skipped: too many candidates' }

                $script:PERenameMaxPairs = 4
                $f = @(Compare-PEState -Blueprint $b -Target $t)
                @($f | Where-Object Kind -eq 'PossibleRename').Count | Should -Be 4
            }
            finally
            {
                $script:PERenameMaxPairs = $saved
            }
        }
    }

    It 'rename check at the bound (141 x 141 = 19,881 similar pairs) finishes in under 60 seconds' {
        InModuleScope PolicyEngine {
            $script:PERenameMaxPairs | Should -Be 20000
        }
        $mk = {
            param ($prefix)
            for ($i = 0; $i -lt 141; $i++)
            {
                $p = [ordered]@{ Ensure = 'Present'; Enabled = $true; Roles = @('r1', 'r2'); Nested = @{ CIMInstance = 'MSFT_N'; V = 'v' } }
                foreach ($n in 1..12)
                {
                    $p["P$n"] = "same$n"
                }
                New-TestRecord -Key "$prefix$i" -Properties $p
            }
        }
        $b = New-TestState -Records @(& $mk 'old')
        $t = New-TestState -Records @(& $mk 'new')
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $f = @(Compare-PEState -Blueprint $b -Target $t)
        $sw.Stop()
        Write-Host "    rename check at the bound took $([math]::Round($sw.Elapsed.TotalSeconds, 2))s"
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 60
        @($f | Where-Object Kind -eq 'PossibleRename').Count | Should -Be 282
        ($f | Where-Object Key -eq 'old0').Hint | Should -Be 'Possible rename of new0, new1, new10, new100, new101 and 136 more'
    }

    It 'Unmanaged decision marks a TargetOnly finding Unmanaged' {
        $t = New-TestState -Records @(
            (New-TestRecord -Key 'Dev Group'),
            (New-TestRecord -Key 'Other')
        )
        $d = @(New-TestDecision -Kind 'Unmanaged' -Key 'dev group')
        $f = @(Compare-PEState -Blueprint (New-TestState) -Target $t -Decisions $d)
        $f.Count | Should -Be 2
        ($f | Where-Object Key -eq 'Dev Group').State | Should -Be 'Unmanaged'
        ($f | Where-Object Key -eq 'Dev Group').Kind | Should -Be 'TargetOnly'
        ($f | Where-Object Key -eq 'Other').State | Should -Be 'Open'
    }

    It 'Unmanaged decision for another type does not apply' {
        $t = New-TestState -Records @(New-TestRecord -Key 'Dev Group')
        $d = @(New-TestDecision -Kind 'Unmanaged' -Type 'AADApplication' -Key 'Dev Group')
        $f = @(Compare-PEState -Blueprint (New-TestState) -Target $t -Decisions $d)
        $f[0].State | Should -Be 'Open'
    }

    It 'a stale Unmanaged decision never hides a Missing or Changed finding' {
        $d = @(New-TestDecision -Kind 'Unmanaged' -Key 'Sales')
        $b = New-TestState -Records @(New-TestRecord -Key 'Sales' -Properties @{ X = 1 })
        $missing = @(Compare-PEState -Blueprint $b -Target (New-TestState) -Decisions $d)
        $missing[0].Kind | Should -Be 'Missing'
        $missing[0].State | Should -Be 'Open'
        $t = New-TestState -Records @(New-TestRecord -Key 'Sales' -Properties @{ X = 2 })
        $changed = @(Compare-PEState -Blueprint $b -Target $t -Decisions $d)
        $changed[0].Kind | Should -Be 'Changed'
        $changed[0].State | Should -Be 'Open'
    }

    It 'Unmanaged applies to a PossibleRename built from the target side only' {
        $props = [ordered]@{ A = 1; B = 2; C = 3; D = 4; E = 5; F = 6; G = 7; H = 8; I = 9 }
        $b = New-TestState -Records @(New-TestRecord -Key 'Old' -Properties $props)
        $t = New-TestState -Records @(New-TestRecord -Key 'New' -Properties $props)
        $d = @((New-TestDecision -Kind 'Unmanaged' -Key 'New'), (New-TestDecision -Kind 'Unmanaged' -Key 'Old'))
        $f = @(Compare-PEState -Blueprint $b -Target $t -Decisions $d)
        ($f | Where-Object Key -eq 'New').State | Should -Be 'Unmanaged'
        ($f | Where-Object Key -eq 'Old').State | Should -Be 'Open'
    }

    It 'an Unmanaged TargetOnly record is never a rename candidate, so the similar Missing record stays Missing' {
        $props = [ordered]@{ A = 1; B = 2; C = 3; D = 4; E = 5; F = 6; G = 7; H = 8; I = 9 }
        $b = New-TestState -Records @(New-TestRecord -Key 'Old' -Properties $props)
        $t = New-TestState -Records @(New-TestRecord -Key 'Legacy' -Properties $props)
        $d = @(New-TestDecision -Kind 'Unmanaged' -Key 'Legacy')
        $f = @(Compare-PEState -Blueprint $b -Target $t -Decisions $d)
        $old = $f | Where-Object Key -eq 'Old'
        $legacy = $f | Where-Object Key -eq 'Legacy'
        $old.Kind | Should -Be 'Missing'
        $old.Hint | Should -BeNullOrEmpty
        $legacy.Kind | Should -Be 'TargetOnly'
        $legacy.State | Should -Be 'Unmanaged'
        $legacy.Hint | Should -BeNullOrEmpty
    }

    It 'an Unmanaged TargetOnly record does not count towards the rename pair bound' {
        InModuleScope PolicyEngine { $script:PERenameMaxPairs = 1 }
        try
        {
            $props = [ordered]@{ A = 1; B = 2; C = 3; D = 4; E = 5; F = 6; G = 7; H = 8; I = 9 }
            $b = New-TestState -Records @(New-TestRecord -Key 'Old' -Properties $props)
            $t = New-TestState -Records @((New-TestRecord -Key 'New' -Properties $props), (New-TestRecord -Key 'Legacy' -Properties $props))
            $d = @(New-TestDecision -Kind 'Unmanaged' -Key 'Legacy')
            $f = @(Compare-PEState -Blueprint $b -Target $t -Decisions $d)
            ($f | Where-Object Key -eq 'Old').Hint | Should -Be 'Possible rename of New'
            ($f | Where-Object Key -eq 'New').Kind | Should -Be 'PossibleRename'
            ($f | Where-Object Key -eq 'Legacy').Kind | Should -Be 'TargetOnly'
        }
        finally
        {
            InModuleScope PolicyEngine { $script:PERenameMaxPairs = 20000 }
        }
    }

    It 'Remove decision does not change the finding' {
        $t = New-TestState -Records @(New-TestRecord -Key 'Dev Group')
        $f = @(Compare-PEState -Blueprint (New-TestState) -Target $t -Decisions @(New-TestDecision -Kind 'Remove' -Key 'Dev Group'))
        $f.Count | Should -Be 1
        $f[0].Kind | Should -Be 'TargetOnly'
        $f[0].State | Should -Be 'Open'
    }

    It 'Noise decision hides the matching value but not a different value' {
        $b = New-TestState -Records @(
            (New-TestRecord -Key 'G1' -Properties ([ordered]@{ Visibility = 'Private'; Other = 'x' })),
            (New-TestRecord -Key 'G2' -Properties ([ordered]@{ Visibility = 'Private' }))
        )
        $t = New-TestState -Records @(
            (New-TestRecord -Key 'G1' -Properties ([ordered]@{ Visibility = 'Public'; Other = 'y' })),
            (New-TestRecord -Key 'G2' -Properties ([ordered]@{ Visibility = 'HiddenMembership' }))
        )
        $d = @(New-TestDecision -Kind 'Noise' -Property 'visibility' -Value 'Public')
        $f = @(Compare-PEState -Blueprint $b -Target $t -Decisions $d)
        $f.Count | Should -Be 2
        $g1 = $f | Where-Object Key -eq 'G1'
        @($g1.Differences).Count | Should -Be 1
        $g1.Differences[0].Property | Should -Be 'Other'
        $g2 = $f | Where-Object Key -eq 'G2'
        $g2.Kind | Should -Be 'Changed'
        $g2.Differences[0].Target | Should -Be 'HiddenMembership'
    }

    It 'a Changed finding whose only differences are Noise is dropped' {
        $b = New-TestState -Records @(New-TestRecord -Key 'G1' -Properties @{ Visibility = 'Private' })
        $t = New-TestState -Records @(New-TestRecord -Key 'G1' -Properties @{ Visibility = 'Public' })
        $d = @(New-TestDecision -Kind 'Noise' -Property 'Visibility' -Value 'Public')
        @(Compare-PEState -Blueprint $b -Target $t -Decisions $d).Count | Should -Be 0
    }

    It 'Noise decision scoped to a key only hides that instance' {
        $b = New-TestState -Records @(
            (New-TestRecord -Key 'G1' -Properties @{ V = 'a' }),
            (New-TestRecord -Key 'G2' -Properties @{ V = 'a' })
        )
        $t = New-TestState -Records @(
            (New-TestRecord -Key 'G1' -Properties @{ V = 'b' }),
            (New-TestRecord -Key 'G2' -Properties @{ V = 'b' })
        )
        $d = @(New-TestDecision -Kind 'Noise' -Key 'g1' -Property 'V' -Value 'b')
        $f = @(Compare-PEState -Blueprint $b -Target $t -Decisions $d)
        $f.Count | Should -Be 1
        $f[0].Key | Should -Be 'G2'
    }

    It 'Noise decision matches a value read back from JSON (Int64, arrays, nested objects)' {
        $b = New-TestState -Records @(New-TestRecord -Key 'P' -Properties ([ordered]@{ N = [int]1; L = @('x', 'y'); C = @{ CIMInstance = 'MSFT_X'; On = $true } }))
        $t = New-TestState -Records @(New-TestRecord -Key 'P' -Properties ([ordered]@{ N = [int]2; L = @('z', 'y'); C = @{ CIMInstance = 'MSFT_X'; On = $false } }))
        $json = ConvertTo-Json -Depth 10 -InputObject @(
            (New-TestDecision -Kind 'Noise' -Property 'N' -Value 2),
            (New-TestDecision -Kind 'Noise' -Property 'L' -Value @('y', 'z')),
            (New-TestDecision -Kind 'Noise' -Property 'C' -Value @{ On = $false; CIMInstance = 'MSFT_X' })
        )
        $d = @($json | ConvertFrom-Json)
        $d[0].Value | Should -BeOfType [long]
        @(Compare-PEState -Blueprint $b -Target $t -Decisions $d).Count | Should -Be 0
    }

    It 'Unkeyed record yields Unkeyed' {
        $b = New-TestState -Records @(New-TestRecord -Type 'AADThing' -Key $null -Properties @{ X = 1 })
        $t = New-TestState -Records @(New-TestRecord -Type 'AADThing' -Key $null -Properties @{ X = 1 })
        $f = @(Compare-PEState -Blueprint $b -Target $t)
        $f.Count | Should -Be 2
        @($f | Where-Object Kind -eq 'Unkeyed').Count | Should -Be 2
        @($f | Where-Object { $_.BlueprintRecord }).Count | Should -Be 1
        @($f | Where-Object { $_.TargetRecord }).Count | Should -Be 1
        $f | ForEach-Object { $_.Key | Should -BeNullOrEmpty }
    }

    It 'Unkeyed records never become Missing, TargetOnly or renames' {
        $props = [ordered]@{ A = 1; B = 2; C = 3; D = 4; E = 5; F = 6; G = 7; H = 8; I = 9 }
        $b = New-TestState -Records @(New-TestRecord -Key 'Old' -Properties $props)
        $t = New-TestState -Records @(New-TestRecord -Key $null -Properties $props)
        $f = @(Compare-PEState -Blueprint $b -Target $t)
        ($f | Where-Object Kind -eq 'Unkeyed').Count | Should -Be 1
        ($f | Where-Object Key -eq 'Old').Kind | Should -Be 'Missing'
    }

    It 'PossibleRename findings carry no Differences and keep their own record' {
        $props = [ordered]@{ A = 1; B = 2; C = 3; D = 4; E = 5; F = 6; G = 7; H = 8; I = 9 }
        $b = New-TestState -Records @(New-TestRecord -Key 'Old Name' -Properties $props)
        $t = New-TestState -Records @(New-TestRecord -Key 'New Name' -Properties $props)
        $f = @(Compare-PEState -Blueprint $b -Target $t)
        foreach ($finding in $f)
        {
            @($finding.Differences).Count | Should -Be 0
        }
        ($f | Where-Object Key -eq 'Old Name').BlueprintRecord.Key | Should -Be 'Old Name'
        ($f | Where-Object Key -eq 'New Name').TargetRecord.Key | Should -Be 'New Name'
    }

    It 'Ambiguous findings carry no records, so they cannot be rectified' {
        $t = New-TestState -Records @((New-TestRecord -Key 'Finance'), (New-TestRecord -Key 'Finance'))
        $f = @(Compare-PEState -Blueprint (New-TestState -Records @(New-TestRecord -Key 'Finance')) -Target $t)
        $f[0].Kind | Should -Be 'Ambiguous'
        $f[0].BlueprintRecord | Should -BeNullOrEmpty
        $f[0].TargetRecord | Should -BeNullOrEmpty
        $f[0].Hint | Should -Be 'Key matches 1 blueprint and 2 target records'
    }

    It 'decisions given as hashtables work' {
        $t = New-TestState -Records @(New-TestRecord -Key 'Dev Group')
        $d = @(@{ Kind = 'Unmanaged'; ResourceType = 'AADGroup'; Key = 'Dev Group'; Property = $null; Value = $null; Reason = 'r'; At = 'x' })
        $f = @(Compare-PEState -Blueprint (New-TestState) -Target $t -Decisions $d)
        $f[0].State | Should -Be 'Unmanaged'
    }

    It 'a state read back from JSON compares equal to the original' {
        $records = @(
            (New-TestRecord -Type 'AADConditionalAccessPolicy' -Key 'CA' -Properties ([ordered]@{
                        State           = 'enabled'
                        Count           = 3
                        Enabled         = $true
                        BuiltInControls = @('mfa')
                        IncludeRoles    = @('Global Administrator', 'Security Administrator')
                        SessionControls = @{ CIMInstance = 'MSFT_Session'; IsEnabled = $true; Hours = 4; Apps = @('x', 'y') }
                        Rules           = @(@{ CIMInstance = 'MSFT_Rule'; Id = 'r1' }, @{ CIMInstance = 'MSFT_Rule'; Id = 'r2' })
                        Empty           = $null
                    }))
        )
        $b = New-TestState -Records $records
        $roundTrip = ConvertTo-Json -InputObject $b -Depth 20 | ConvertFrom-Json -Depth 20
        $roundTrip.Records[0].Properties | Should -BeOfType [pscustomobject]
        @(Compare-PEState -Blueprint $roundTrip -Target $b).Count | Should -Be 0
        @(Compare-PEState -Blueprint $b -Target $roundTrip).Count | Should -Be 0
    }

    It 'every finding carries the documented properties' {
        $b = New-TestState -Records @(New-TestRecord -Key 'Sales' -Properties @{ X = 1 })
        $f = @(Compare-PEState -Blueprint $b -Target (New-TestState))
        $names = $f[0].PSObject.Properties.Name
        foreach ($n in 'Kind', 'ResourceType', 'Key', 'Workload', 'Differences', 'Hint', 'State', 'BlueprintRecord', 'TargetRecord')
        {
            $names | Should -Contain $n
        }
    }

    It 'handles 5,000 records per side in under 60 seconds' {
        $make = {
            param ($prefix, $variant)
            for ($i = 0; $i -lt 5000; $i++)
            {
                $type = 'AADType' + ($i % 25)
                $key = "$prefix$i"
                [pscustomobject]@{
                    ResourceType = $type
                    Key          = $key
                    Workload     = 'Entra ID'
                    Properties   = [ordered]@{
                        DisplayName = $key
                        Ensure      = 'Present'
                        Enabled     = $true
                        Count       = $i
                        Roles       = @('r1', 'r2', "r$($i % 7)")
                        Nested      = @{ CIMInstance = 'MSFT_N'; Value = "v$variant$($i % 3)"; List = @('a', 'b') }
                        Description = "desc $i"
                    }
                }
            }
        }
        # 4,600 shared keys (some Changed), 400 Missing and 400 TargetOnly spread over 25 types.
        $bRecords = @(& $make 'k' 0 | Select-Object -First 4600) + @(& $make 'gone' 0 | Select-Object -First 400)
        $tRecords = @(& $make 'k' 0 | Select-Object -First 4600) + @(& $make 'new' 1 | Select-Object -First 400)
        for ($i = 0; $i -lt 4600; $i += 50)
        {
            $tRecords[$i].Properties.Description = 'changed'
        }
        $b = New-TestState -Records $bRecords
        $t = New-TestState -Records $tRecords
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $f = @(Compare-PEState -Blueprint $b -Target $t)
        $sw.Stop()
        Write-Host "    5,000 x 5,000 compare took $([math]::Round($sw.Elapsed.TotalSeconds, 2))s, $($f.Count) findings"
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 60
        @($f | Where-Object Kind -eq 'Changed').Count | Should -Be 92
        (@($f | Where-Object Kind -in 'Missing', 'TargetOnly', 'PossibleRename')).Count | Should -Be 800
    }
}

Describe 'Value comparison' {
    It 'arrays of scalars compare as sets, ignoring order' {
        InModuleScope PolicyEngine {
            Test-PEValueEqual -A @('Global Admin', 'Reader') -B @('Reader', 'Global Admin') | Should -BeTrue
            Test-PEValueEqual -A @('a', 'b') -B @('a', 'c') | Should -BeFalse
            Test-PEValueEqual -A @('a', 'b') -B @('a') | Should -BeFalse
        }
    }

    It 'duplicates inside an array are ignored (set semantics)' {
        InModuleScope PolicyEngine {
            Test-PEValueEqual -A @('a', 'a', 'b') -B @('b', 'a') | Should -BeTrue
        }
    }

    It 'a scalar equals a one-element array of the same value' {
        InModuleScope PolicyEngine {
            Test-PEValueEqual -A 'mfa' -B @('mfa') | Should -BeTrue
        }
    }

    It 'nested hashtables compare recursively regardless of key order and key case' {
        InModuleScope PolicyEngine {
            $a = [ordered]@{ CIMInstance = 'MSFT_A'; Name = 'n'; Inner = @{ CIMInstance = 'MSFT_B'; List = @(1, 2) } }
            $b = [ordered]@{ inner = @{ list = @(2, 1); CIMInstance = 'MSFT_B' }; name = 'n'; CIMInstance = 'MSFT_A' }
            Test-PEValueEqual -A $a -B $b | Should -BeTrue
            $c = [ordered]@{ CIMInstance = 'MSFT_A'; Name = 'n'; Inner = @{ CIMInstance = 'MSFT_B'; List = @(1, 3) } }
            Test-PEValueEqual -A $a -B $c | Should -BeFalse
        }
    }

    It 'arrays of CIM instances compare as sets' {
        InModuleScope PolicyEngine {
            $a = @(@{ CIMInstance = 'MSFT_R'; Id = 'x'; On = $true }, @{ CIMInstance = 'MSFT_R'; Id = 'y'; On = $false })
            $b = @(@{ CIMInstance = 'MSFT_R'; Id = 'y'; On = $false }, @{ CIMInstance = 'MSFT_R'; Id = 'x'; On = $true })
            Test-PEValueEqual -A $a -B $b | Should -BeTrue
            $c = @(@{ CIMInstance = 'MSFT_R'; Id = 'y'; On = $true }, @{ CIMInstance = 'MSFT_R'; Id = 'x'; On = $true })
            Test-PEValueEqual -A $a -B $c | Should -BeFalse
        }
    }

    It 'a hashtable equals a pscustomobject with the same members' {
        InModuleScope PolicyEngine {
            Test-PEValueEqual -A @{ A = 1; B = 'x' } -B ([pscustomobject]@{ B = 'x'; A = 1 }) | Should -BeTrue
        }
    }

    It 'a CimInstance equals the hashtable form the DSC parser produces' {
        InModuleScope PolicyEngine {
            $cim = New-CimInstance -ClassName MSFT_Test -Namespace root/pe -ClientOnly -Property @{ Name = 'n'; On = $true }
            Test-PEValueEqual -A $cim -B @{ CIMInstance = 'MSFT_Test'; Name = 'n'; On = $true } | Should -BeTrue
            Test-PEValueEqual -A $cim -B @{ CIMInstance = 'MSFT_Test'; Name = 'n'; On = $false } | Should -BeFalse
            Test-PEValueEqual -A $cim -B @{ CIMInstance = 'MSFT_Other'; Name = 'n'; On = $true } | Should -BeFalse
        }
    }

    It 'null, empty string and empty array are equal' {
        InModuleScope PolicyEngine {
            Test-PEValueEqual -A $null -B '' | Should -BeTrue
            Test-PEValueEqual -A $null -B @() | Should -BeTrue
            Test-PEValueEqual -A '' -B @() | Should -BeTrue
            Test-PEValueEqual -A $null -B ' ' | Should -BeFalse
            Test-PEValueEqual -A $null -B $false | Should -BeFalse
            Test-PEValueEqual -A $null -B 0 | Should -BeFalse
        }
    }

    It 'empty hashtables, empty objects and all-empty collections equal $null' {
        InModuleScope PolicyEngine {
            Test-PEValueEqual -A @{} -B $null | Should -BeTrue
            Test-PEValueEqual -A ([pscustomobject]@{}) -B $null | Should -BeTrue
            Test-PEValueEqual -A @{ A = $null; B = '' } -B $null | Should -BeTrue
            Test-PEValueEqual -A @($null, '') -B $null | Should -BeTrue
            Test-PEValueEqual -A @(@(), @{}) -B '' | Should -BeTrue
        }
    }

    It 'an empty element next to a real one is kept: @(x, $null) does not equal x' {
        InModuleScope PolicyEngine {
            Test-PEValueEqual -A @('x', $null) -B 'x' | Should -BeFalse
            Test-PEValueEqual -A @('x', $null) -B @('x', '') | Should -BeTrue
        }
    }

    It 'a nested member that is null equals an absent member' {
        InModuleScope PolicyEngine {
            Test-PEValueEqual -A @{ A = 1; B = $null } -B @{ A = 1 } | Should -BeTrue
            Test-PEValueEqual -A @{ A = 1; B = @() } -B @{ A = 1; B = '' } | Should -BeTrue
        }
    }

    It 'strings compare exactly: case and whitespace matter' {
        InModuleScope PolicyEngine {
            Test-PEValueEqual -A 'Enabled' -B 'enabled' | Should -BeFalse
            Test-PEValueEqual -A 'a' -B 'a ' | Should -BeFalse
            Test-PEValueEqual -A 'a' -B 'a' | Should -BeTrue
        }
    }

    It 'numbers compare by value across numeric types but never equal a numeric string' {
        InModuleScope PolicyEngine {
            Test-PEValueEqual -A ([int]1) -B ([long]1) | Should -BeTrue
            Test-PEValueEqual -A ([int]1) -B ([double]1.0) | Should -BeTrue
            Test-PEValueEqual -A 1 -B '1' | Should -BeFalse
            Test-PEValueEqual -A 1 -B 2 | Should -BeFalse
            Test-PEValueEqual -A $true -B 'True' | Should -BeFalse
            Test-PEValueEqual -A $true -B 1 | Should -BeFalse
        }
    }

    It 'a DateTime never equals a date string (stores must keep dates as strings)' {
        InModuleScope PolicyEngine {
            Test-PEValueEqual -A ([datetime]'2027-01-21T19:30:26Z') -B '2027-01-21T19:30:26+00:00' | Should -BeFalse
        }
    }

    It 'strings containing separators do not collide' {
        InModuleScope PolicyEngine {
            Test-PEValueEqual -A @('a,b') -B @('a', 'b') | Should -BeFalse
            Test-PEValueEqual -A @{ A = 'x;B=y' } -B @{ A = 'x'; B = 'y' } | Should -BeFalse
        }
    }
}

Describe 'Record property differences' {
    It 'a property present on one side only is a Difference with $null on the missing side' {
        $b = New-TestState -Records @(New-TestRecord -Key 'S' -Properties ([ordered]@{ A = 1 }))
        $t = New-TestState -Records @(New-TestRecord -Key 'S' -Properties ([ordered]@{ A = 1; Extra = 'v' }))
        $f = @(Compare-PEState -Blueprint $b -Target $t)
        $f.Count | Should -Be 1
        $f[0].Differences[0].Property | Should -Be 'Extra'
        $f[0].Differences[0].Blueprint | Should -BeNullOrEmpty
        $f[0].Differences[0].Target | Should -Be 'v'
    }

    It 'a property present on one side only with a null or empty value is not a Difference' {
        $b = New-TestState -Records @(New-TestRecord -Key 'S' -Properties ([ordered]@{ A = 1; E = '' }))
        $t = New-TestState -Records @(New-TestRecord -Key 'S' -Properties ([ordered]@{ A = 1; F = @(); G = $null }))
        @(Compare-PEState -Blueprint $b -Target $t).Count | Should -Be 0
    }

    It 'property names match case-insensitively' {
        $b = New-TestState -Records @(New-TestRecord -Key 'S' -Properties ([ordered]@{ MailEnabled = $true }))
        $t = New-TestState -Records @(New-TestRecord -Key 'S' -Properties ([ordered]@{ mailenabled = $true }))
        @(Compare-PEState -Blueprint $b -Target $t).Count | Should -Be 0
    }

    It 'properties named Count, Keys or Values do not shadow dictionary members' {
        $props = [ordered]@{ Count = 0; Keys = 'k'; Values = @('v'); A = 1; B = 2; C = 3; D = 4; E = 5; F = 6; G = 7 }
        $b = New-TestState -Records @((New-TestRecord -Key 'Same' -Properties $props), (New-TestRecord -Key 'Old' -Properties $props))
        $changedProps = [ordered]@{ Count = 1; Keys = 'k'; Values = @('v'); A = 1; B = 2; C = 3; D = 4; E = 5; F = 6; G = 7 }
        $t = New-TestState -Records @((New-TestRecord -Key 'Same' -Properties $changedProps), (New-TestRecord -Key 'New' -Properties $props))
        $f = @(Compare-PEState -Blueprint $b -Target $t)
        $same = $f | Where-Object Key -eq 'Same'
        $same.Kind | Should -Be 'Changed'
        @($same.Differences).Property | Should -Be @('Count')
        ($f | Where-Object Key -eq 'Old').Kind | Should -Be 'PossibleRename'
        InModuleScope PolicyEngine {
            Test-PEValueEqual -A @{ Count = 1; Keys = 'x' } -B @{ Keys = 'x'; Count = 1 } | Should -BeTrue
            Test-PEValueEqual -A @{ Count = 1; Keys = 'x' } -B @{ Keys = 'y'; Count = 1 } | Should -BeFalse
        }
    }

    It 'role list in a different order is not a change' {
        $b = New-TestState -Records @(New-TestRecord -Type 'AADConditionalAccessPolicy' -Key 'CA' -Properties @{ IncludeRoles = @('Global Administrator', 'Security Administrator') })
        $t = New-TestState -Records @(New-TestRecord -Type 'AADConditionalAccessPolicy' -Key 'CA' -Properties @{ IncludeRoles = @('Security Administrator', 'Global Administrator') })
        @(Compare-PEState -Blueprint $b -Target $t).Count | Should -Be 0
    }
}

Describe 'Names that collide with dictionary members' {
    It 'handles record keys and resource types literally named Keys or Count' {
        $b = New-TestState -Records @(
            (New-TestRecord -Type 'Keys' -Key 'Count'),
            (New-TestRecord -Type 'Count' -Key 'Keys' -Properties ([ordered]@{ State = 'on' })),
            (New-TestRecord -Key 'Keys')
        ) -NotChecked @(@{ ResourceType = 'Keys'; Reason = 'r' })
        $t = New-TestState -Records @(
            (New-TestRecord -Type 'Count' -Key 'Keys' -Properties ([ordered]@{ State = 'off' })),
            (New-TestRecord -Type 'Keys' -Key 'Other'),
            (New-TestRecord -Type 'Count' -Key 'Count')
        )
        $findings = @(Compare-PEState -Blueprint $b -Target $t)
        ($findings | Where-Object { $_.ResourceType -eq 'Keys' }).Kind | Should -Be 'NotChecked'
        ($findings | Where-Object { $_.ResourceType -eq 'Count' -and $_.Key -eq 'Keys' }).Kind | Should -Be 'Changed'
        ($findings | Where-Object { $_.ResourceType -eq 'Count' -and $_.Key -eq 'Count' }).Kind | Should -Be 'TargetOnly'
        ($findings | Where-Object { $_.ResourceType -eq 'AADGroup' -and $_.Key -eq 'Keys' }).Kind | Should -Be 'Missing'
    }
}

Describe 'Compare-PEState excluded types' {
    BeforeAll {
        $script:RoleEntryReason = InModuleScope PolicyEngine { (Get-PEExcludedTypeMap)['EXOManagementRoleEntry'].Reason }

        function New-TestRole
        {
            param ([string]$Name, [string]$Parent)
            [pscustomobject]@{ ResourceType = 'EXOManagementRole'; Key = $Name; Workload = 'Exchange Online'; Properties = [ordered]@{ Name = $Name; Parent = $Parent; Description = '' } }
        }

        function New-TestRoleEntry
        {
            param ([string]$Identity, [string[]]$Parameters = @())
            [pscustomobject]@{ ResourceType = 'EXOManagementRoleEntry'; Key = $Identity; Workload = 'Exchange Online'; Properties = [ordered]@{ Identity = $Identity; Parameters = $Parameters } }
        }
    }

    It 'records of an excluded type on both sides produce only one Excluded finding' {
        $b = New-TestState -Records @(
            (New-TestRecord -Type 'EXOMailboxSettings' -Key 'ann' -Properties ([ordered]@{ TimeZone = 'x' })),
            (New-TestRecord -Type 'EXOMailboxSettings' -Key 'ann'),
            (New-TestRecord -Type 'EXOMailboxSettings' -Key 'bob'),
            (New-TestRecord -Type 'EXOMailboxSettings' -Key $null),
            (New-TestRecord -Key 'Sales')
        )
        $t = New-TestState -Records @(
            (New-TestRecord -Type 'EXOMailboxSettings' -Key 'ann' -Properties ([ordered]@{ TimeZone = 'y' })),
            (New-TestRecord -Type 'exomailboxsettings' -Key 'carl'),
            (New-TestRecord -Key 'Sales')
        )
        $findings = @(Compare-PEState -Blueprint $b -Target $t)
        $findings.Count | Should -Be 1
        $f = $findings[0]
        $f.Kind | Should -Be 'Excluded'
        $f.ResourceType | Should -Be 'EXOMailboxSettings'
        $f.Key | Should -BeNullOrEmpty
        $f.Workload | Should -Be 'Exchange Online'
        $f.Hint | Should -Match 'GUID'
        $f.BlueprintCount | Should -Be 4
        $f.TargetCount | Should -Be 2
        $f.BlueprintRecord | Should -BeNullOrEmpty
        $f.TargetRecord | Should -BeNullOrEmpty
        @($f.Differences).Count | Should -Be 0
    }

    It 'an excluded type with records on one side only is reported once, with no Missing or TargetOnly' {
        $b = New-TestState -Records @((New-TestRecord -Type 'EXOMailboxSettings' -Key 'ann@contoso.com'))
        $t = New-TestState -Records @((New-TestRecord -Type 'EXOMailboxPermission' -Key 'x'))
        $findings = @(Compare-PEState -Blueprint $b -Target $t | Sort-Object ResourceType)
        @($findings.Kind) | Should -Be @('Excluded', 'Excluded')
        @($findings.ResourceType) | Should -Be @('EXOMailboxPermission', 'EXOMailboxSettings')
        $findings[1].BlueprintCount | Should -Be 1
        $findings[1].TargetCount | Should -Be 0
    }

    It 'user-bound types are excluded' {
        $b = New-TestState -Records @((New-TestRecord -Type 'AADUser' -Key 'ann@contoso.com'), (New-TestRecord -Type 'TeamsUser' -Key 'T | ann'))
        $findings = @(Compare-PEState -Blueprint $b -Target (New-TestState) | Sort-Object ResourceType)
        @($findings.Kind) | Should -Be @('Excluded', 'Excluded')
        @($findings.ResourceType) | Should -Be @('AADUser', 'TeamsUser')
    }

    It 'an excluded type with no records and not in a NotChecked list produces no finding' {
        $s = New-TestState -Records @((New-TestRecord -Key 'Sales'))
        @(Compare-PEState -Blueprint $s -Target $s).Count | Should -Be 0
    }

    It 'Excluded wins over NotChecked and NotAvailable' {
        $b = New-TestState -Records @((New-TestRecord -Type 'EXOMailboxSettings' -Key 'm')) -NotChecked @(@{ ResourceType = 'EXOMailboxPermission'; Reason = 'Forbidden' })
        $t = New-TestState -NotChecked @(@{ ResourceType = 'EXOMailboxSettings'; Reason = 'timeout' }, @{ ResourceType = 'EXOMailboxPermission'; Reason = 'Forbidden' }, @{ ResourceType = 'EXOMailboxIRMAccess'; Reason = 'error' })
        $findings = @(Compare-PEState -Blueprint $b -Target $t | Sort-Object ResourceType)
        @($findings.Kind) | Should -Be @('Excluded', 'Excluded', 'Excluded')
        @($findings.ResourceType) | Should -Be @('EXOMailboxIRMAccess', 'EXOMailboxPermission', 'EXOMailboxSettings')
    }

    It '-IncludeTypes compares a type that is excluded by default (case-insensitive) and warns about a type that is not excluded' {
        $b = New-TestState -Records @(
            (New-TestRecord -Type 'EXOMailboxSettings' -Key 'm' -Properties ([ordered]@{ TimeZone = 'A' })),
            (New-TestRecord -Type 'EXOMailboxPermission' -Key 'p')
        )
        $t = New-TestState -Records @((New-TestRecord -Type 'EXOMailboxSettings' -Key 'm' -Properties ([ordered]@{ TimeZone = 'B' })))
        $findings = @(Compare-PEState -Blueprint $b -Target $t -IncludeTypes 'exomailboxsettings', 'NotAType', 'AADGroup' -WarningVariable warnings -WarningAction SilentlyContinue | Sort-Object ResourceType)
        $findings.Count | Should -Be 2
        $findings[0].Kind | Should -Be 'Excluded'
        $findings[0].ResourceType | Should -Be 'EXOMailboxPermission'
        $findings[1].Kind | Should -Be 'Changed'
        $findings[1].Key | Should -Be 'm'
        @($findings[1].Differences.Property) | Should -Be @('TimeZone')
        @($warnings).Count | Should -Be 1
        [string]$warnings[0] | Should -Match 'NotAType, AADGroup'
    }

    It 'no warning when every -IncludeTypes name is excluded' {
        $null = Compare-PEState -Blueprint (New-TestState) -Target (New-TestState) -IncludeTypes 'EXOMailboxSettings' -WarningVariable warnings
        @($warnings).Count | Should -Be 0
    }

    It 'without -IncludeTypes the next call excludes the type again' {
        $b = New-TestState -Records @((New-TestRecord -Type 'EXOMailboxSettings' -Key 'm'))
        $null = Compare-PEState -Blueprint $b -Target (New-TestState) -IncludeTypes 'EXOMailboxSettings'
        @(Compare-PEState -Blueprint $b -Target (New-TestState)).Kind | Should -Be @('Excluded')
    }

    Context 'EXOManagementRoleEntry (record rule KeepCustomRoleEntries)' {
        It 'compares entries of custom roles and excludes entries of built-in roles' {
            $b = New-TestState -Records @(
                (New-TestRole -Name 'Custom Reader' -Parent 'contoso\View-Only Recipients'),
                (New-TestRole -Name 'Mail Recipients' -Parent ''),
                (New-TestRoleEntry -Identity 'Custom Reader\Get-Mailbox' -Parameters @('Identity')),
                (New-TestRoleEntry -Identity 'Custom Reader\Get-User'),
                (New-TestRoleEntry -Identity 'Mail Recipients\Set-Mailbox'),
                (New-TestRoleEntry -Identity 'Mail Recipients\Set-Mailbox'),
                (New-TestRoleEntry -Identity 'Built-in Only\Get-Thing')
            )
            $t = New-TestState -Records @(
                (New-TestRole -Name 'Custom Reader' -Parent 'contoso\View-Only Recipients'),
                (New-TestRole -Name 'Mail Recipients' -Parent ''),
                (New-TestRoleEntry -Identity 'custom reader\Get-Mailbox' -Parameters @('Identity', 'Filter')),
                (New-TestRoleEntry -Identity 'Custom Reader\Set-User'),
                (New-TestRoleEntry -Identity 'Mail Recipients\Set-Mailbox')
            )
            $findings = @(Compare-PEState -Blueprint $b -Target $t)
            $excluded = @($findings | Where-Object Kind -eq 'Excluded')
            $excluded.Count | Should -Be 1
            $excluded[0].ResourceType | Should -Be 'EXOManagementRoleEntry'
            $excluded[0].Hint | Should -Be $script:RoleEntryReason
            $excluded[0].BlueprintCount | Should -Be 3
            $excluded[0].TargetCount | Should -Be 1
            $rest = @($findings | Where-Object Kind -ne 'Excluded' | Sort-Object Key)
            @($rest | ForEach-Object { "$($_.Kind) $($_.Key)" }) | Should -Be @('Changed Custom Reader\Get-Mailbox', 'Missing Custom Reader\Get-User', 'TargetOnly Custom Reader\Set-User')
        }

        It 'judges each side by its own custom roles: a custom role removed in the target shows its entries Missing' {
            $role = New-TestRole -Name 'Custom Reader' -Parent 'contoso\View-Only Recipients'
            $entry = New-TestRoleEntry -Identity 'Custom Reader\Get-Mailbox'
            $b = New-TestState -Records @($role, $entry)
            $t = New-TestState -Records @($entry)
            $findings = @(Compare-PEState -Blueprint $b -Target $t | Sort-Object ResourceType, Kind)
            @($findings | ForEach-Object { "$($_.Kind) $($_.ResourceType)" }) | Should -Be @('Missing EXOManagementRole', 'Excluded EXOManagementRoleEntry', 'Missing EXOManagementRoleEntry')
            ($findings | Where-Object Kind -eq 'Excluded').TargetCount | Should -Be 1
        }

        It 'no Excluded finding when every entry belongs to a custom role' {
            $s = New-TestState -Records @((New-TestRole -Name 'R' -Parent 'p\Q'), (New-TestRoleEntry -Identity 'R\Get-X'))
            @(Compare-PEState -Blueprint $s -Target $s).Count | Should -Be 0
        }

        It 'a NotChecked role-entry type is NotChecked for its custom-role entries, and Excluded for the rest' {
            $b = New-TestState -Records @((New-TestRole -Name 'R' -Parent 'p\Q'), (New-TestRoleEntry -Identity 'R\Get-X'), (New-TestRoleEntry -Identity 'Builtin\Get-Y'))
            $t = New-TestState -Records @((New-TestRole -Name 'R' -Parent 'p\Q')) -NotChecked @(@{ ResourceType = 'EXOManagementRoleEntry'; Reason = 'timeout' })
            $findings = @(Compare-PEState -Blueprint $b -Target $t | Sort-Object Kind)
            @($findings.Kind) | Should -Be @('Excluded', 'NotChecked')
        }

        It 'is lifted by -IncludeTypes (every entry compared)' {
            $b = New-TestState -Records @((New-TestRoleEntry -Identity 'Builtin\Get-Y'))
            @(Compare-PEState -Blueprint $b -Target (New-TestState) -IncludeTypes 'EXOManagementRoleEntry').Kind | Should -Be @('Missing')
        }
    }
}

Describe 'Compare-PEState nested ignore paths' {
    BeforeAll {
        function New-TestAssignment
        {
            param ([string]$Start, [string]$Expiration = 'noExpiration', [switch]$Json)

            $schedule = [ordered]@{ CIMInstance = 'MSFT_AADRoleAssignmentScheduleRequestSchedule'; startDateTime = $Start; expiration = [ordered]@{ CIMInstance = 'MSFT_AADRoleAssignmentScheduleRequestScheduleExpiration'; type = $Expiration } }
            if ($Json)
            {
                $schedule = $schedule | ConvertTo-Json -Depth 5 | ConvertFrom-Json
            }
            [pscustomobject]@{
                ResourceType = 'AADRoleAssignmentScheduleRequest'
                Key          = 'admin | Reader | /'
                Workload     = 'Entra ID'
                Properties   = [ordered]@{ Principal = 'admin'; RoleDefinition = 'Reader'; DirectoryScopeId = '/'; ScheduleInfo = $schedule }
            }
        }

        function New-TestStateAt
        {
            param ([object[]]$Records = @(), $ExportedAt)

            $meta = @{ TenantId = 't'; Source = 'test' }
            if ($ExportedAt)
            {
                $meta['ExportedAt'] = $ExportedAt
            }
            & (Get-Module PolicyEngine) {
                param ($r, $m)
                New-PEState -Records $r -NotChecked @() -Meta $m
            } $Records $meta
        }
    }

    It 'a stored blueprint that still has a past ScheduleInfo.startDateTime compares clean against a new export time' {
        $b = New-TestStateAt -Records @((New-TestAssignment -Start '2026-10-20T11:27:15Z' -Json)) -ExportedAt '2026-10-22T04:52:56Z'
        $t = New-TestStateAt -Records @((New-TestAssignment -Start '2026-10-22T08:50:00Z')) -ExportedAt '2026-10-22T08:51:16Z'
        @(Compare-PEState -Blueprint $b -Target $t).Count | Should -Be 0
    }

    It 'uses each state''s own export time (a start after the blueprint export but before the target export)' {
        # Past for the target, future for the blueprint: the blueprint keeps it, the target drops it -> Changed.
        $b = New-TestStateAt -Records @((New-TestAssignment -Start '2026-10-22T06:00:00Z')) -ExportedAt '2026-10-22T04:52:56Z'
        $t = New-TestStateAt -Records @((New-TestAssignment -Start '2026-10-22T06:00:00Z')) -ExportedAt '2026-10-22T08:51:16Z'
        @(Compare-PEState -Blueprint $b -Target $t).Kind | Should -Be @('Changed')
    }

    It 'a future start is compared: a change of a future start is a Changed finding' {
        $b = New-TestStateAt -Records @((New-TestAssignment -Start '2026-12-01T00:00:00Z')) -ExportedAt '2026-10-22T04:52:56Z'
        $same = New-TestStateAt -Records @((New-TestAssignment -Start '2026-12-01T00:00:00Z')) -ExportedAt '2026-10-22T08:51:16Z'
        $moved = New-TestStateAt -Records @((New-TestAssignment -Start '2026-12-15T00:00:00Z')) -ExportedAt '2026-10-22T08:51:16Z'
        @(Compare-PEState -Blueprint $b -Target $same).Count | Should -Be 0
        $findings = @(Compare-PEState -Blueprint $b -Target $moved)
        $findings.Kind | Should -Be @('Changed')
        $findings[0].Differences[0].Property | Should -Be 'ScheduleInfo'
        $findings[0].Differences[0].Target.startDateTime | Should -Be '2026-12-15T00:00:00Z'
    }

    It 'a state without ExportedAt keeps the start (conditional paths are not applied to it)' {
        $b = New-TestStateAt -Records @((New-TestAssignment -Start '2026-10-20T11:27:15Z'))
        $t = New-TestStateAt -Records @((New-TestAssignment -Start '2026-10-22T08:50:00Z')) -ExportedAt '2026-10-22T08:51:16Z'
        @(Compare-PEState -Blueprint $b -Target $t).Kind | Should -Be @('Changed')
    }

    It 'other members of ScheduleInfo are still compared' {
        $b = New-TestStateAt -Records @((New-TestAssignment -Start '2026-10-20T11:27:15Z')) -ExportedAt '2026-10-22T04:52:56Z'
        $t = New-TestStateAt -Records @((New-TestAssignment -Start '2026-10-22T08:00:00Z' -Expiration 'afterDateTime')) -ExportedAt '2026-10-22T08:51:16Z'
        $findings = @(Compare-PEState -Blueprint $b -Target $t)
        $findings.Count | Should -Be 1
        $findings[0].Kind | Should -Be 'Changed'
        @($findings[0].Differences.Property) | Should -Be @('ScheduleInfo')
        $findings[0].Differences[0].Target.Keys | Should -Not -Contain 'startDateTime'
        # The attached records are the compared records, unchanged.
        $findings[0].TargetRecord.Properties.ScheduleInfo.startDateTime | Should -Be '2026-10-22T08:00:00Z'
    }

    It 'does not modify the records it compares' {
        $blueprintRecord = New-TestAssignment -Start '2026-10-01T00:00:00Z'
        $targetRecord = New-TestAssignment -Start '2026-10-02T00:00:00Z'
        $null = Compare-PEState -Blueprint (New-TestStateAt -Records @($blueprintRecord) -ExportedAt '2026-10-22T00:00:00Z') -Target (New-TestStateAt -Records @($targetRecord) -ExportedAt '2026-10-22T00:00:00Z')
        $blueprintRecord.Properties.ScheduleInfo.startDateTime | Should -Be '2026-10-01T00:00:00Z'
        $targetRecord.Properties.ScheduleInfo.startDateTime | Should -Be '2026-10-02T00:00:00Z'
    }
}
