BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
}

Describe 'Get-PEResourceKey' {
    It 'Key is the first of DisplayName, Name, Identity that is non-empty' {
        InModuleScope PolicyEngine {
            Get-PEResourceKey -ResourceType 'AADGroup' -Properties @{ Identity = 'i'; Name = 'n'; DisplayName = 'd' } | Should -Be 'd'
            Get-PEResourceKey -ResourceType 'AADGroup' -Properties @{ Identity = 'i'; Name = 'n' } | Should -Be 'n'
            Get-PEResourceKey -ResourceType 'AADGroup' -Properties @{ Identity = 'i' } | Should -Be 'i'
        }
    }

    It 'Key is null when no key property exists' {
        InModuleScope PolicyEngine {
            Get-PEResourceKey -ResourceType 'AADGroup' -Properties @{ Description = 'x' } | Should -BeNullOrEmpty
        }
    }

    It 'Overrides win over the default order' {
        InModuleScope PolicyEngine {
            Get-PEResourceKey -ResourceType 'AADUser' -Properties @{ DisplayName = 'Ann'; UserPrincipalName = 'ann@contoso.com' } | Should -Be 'ann@contoso.com'
        }
    }

    It 'empty or whitespace key values fall through to the next candidate' {
        InModuleScope PolicyEngine {
            Get-PEResourceKey -ResourceType 'AADGroup' -Properties @{ DisplayName = ''; Name = '   '; Identity = 'i' } | Should -Be 'i'
            Get-PEResourceKey -ResourceType 'AADGroup' -Properties @{ DisplayName = $null; Name = 'n' } | Should -Be 'n'
            Get-PEResourceKey -ResourceType 'AADGroup' -Properties @{ DisplayName = ' '; Name = '' } | Should -BeNullOrEmpty
        }
    }

    It 'stores the key as exported, without trimming or case change' {
        InModuleScope PolicyEngine {
            Get-PEResourceKey -ResourceType 'AADGroup' -Properties @{ DisplayName = '  SALES team ' } | Should -Be '  SALES team '
        }
    }

    It 'matches property names and resource types case-insensitively' {
        InModuleScope PolicyEngine {
            Get-PEResourceKey -ResourceType 'AADGroup' -Properties ([ordered]@{ displayname = 'd' }) | Should -Be 'd'
            Get-PEResourceKey -ResourceType 'aaduser' -Properties @{ userprincipalname = 'u@c.com' } | Should -Be 'u@c.com'
        }
    }

    It 'every override entry is a non-empty list of property names' {
        InModuleScope PolicyEngine {
            $map = Get-PEKeyMap
            $map.Default.Count | Should -BeGreaterThan 0
            foreach ($type in $map.Overrides.Keys)
            {
                @($map.Overrides[$type]).Count | Should -BeGreaterThan 0 -Because $type
            }
        }
    }
}

Describe 'ConvertTo-PENormalizedRecord' {
    It 'sets Key and keeps the record shape' {
        InModuleScope PolicyEngine {
            $r = [pscustomobject]@{ ResourceType = 'AADGroup'; Key = $null; Workload = 'Entra ID'; TenantId = 't1'; Properties = [ordered]@{ DisplayName = 'Sales'; Description = 'd' } }
            $n = ConvertTo-PENormalizedRecord -Record $r
            $n.Key | Should -Be 'Sales'
            $n.ResourceType | Should -Be 'AADGroup'
            $n.Workload | Should -Be 'Entra ID'
            $n.TenantId | Should -Be 't1'
            $n.Properties.Description | Should -Be 'd'
        }
    }

    It 'Global ignored properties are removed' {
        InModuleScope PolicyEngine {
            $r = [pscustomobject]@{ ResourceType = 'AADGroup'; Key = $null; Workload = 'Entra ID'; TenantId = $null; Properties = [ordered]@{ Id = '1'; TenantId = 't'; DisplayName = 'Sales' } }
            $n = ConvertTo-PENormalizedRecord -Record $r
            $n.Properties.Keys | Should -Not -Contain 'Id'
            $n.Properties.Keys | Should -Not -Contain 'TenantId'
            $n.Properties.Keys | Should -Contain 'DisplayName'
        }
    }

    It 'Password is removed from every record' {
        InModuleScope PolicyEngine {
            $r = [pscustomobject]@{ ResourceType = 'EXOMailContact'; Key = $null; Workload = 'Exchange Online'; TenantId = $null; Properties = [ordered]@{ Name = 'c'; Password = 'secret'; password2 = 'kept' } }
            $n = ConvertTo-PENormalizedRecord -Record $r
            $n.Properties.Keys | Should -Not -Contain 'Password'
            $n.Properties.Keys | Should -Contain 'password2'
        }
    }

    It 'AADGroup Members and Owners are removed' {
        InModuleScope PolicyEngine {
            $r = [pscustomobject]@{ ResourceType = 'AADGroup'; Key = $null; Workload = 'Entra ID'; TenantId = $null; Properties = [ordered]@{ DisplayName = 'Sales'; Members = @('a'); Owners = @('b'); MemberOf = @('c'); Description = 'd' } }
            $n = ConvertTo-PENormalizedRecord -Record $r
            $n.Properties.Keys | Should -Not -Contain 'Members'
            $n.Properties.Keys | Should -Not -Contain 'Owners'
            $n.Properties.Keys | Should -Not -Contain 'MemberOf'
            $n.Properties.Keys | Should -Contain 'Description'
        }
    }

    It 'Other types keep a property named Members' {
        InModuleScope PolicyEngine {
            $r = [pscustomobject]@{ ResourceType = 'TeamsTeam'; Key = $null; Workload = 'Teams'; TenantId = $null; Properties = [ordered]@{ DisplayName = 'T'; Members = @('a') } }
            $n = ConvertTo-PENormalizedRecord -Record $r
            $n.Properties.Keys | Should -Contain 'Members'
        }
    }

    It 'Secret-like values are not kept' {
        InModuleScope PolicyEngine {
            $r = [pscustomobject]@{ ResourceType = 'AADGroup'; Key = $null; Workload = 'Entra ID'; TenantId = $null; Properties = [ordered]@{ DisplayName = 'S'; Credential = 'x'; ApplicationSecret = 's'; CertificatePassword = 'p'; AccessTokens = @('t'); CertificateThumbprint = 'th' } }
            $n = ConvertTo-PENormalizedRecord -Record $r
            @($n.Properties.Keys) | Should -Be @('DisplayName')
        }
    }

    It 'ignored-property matching is case-insensitive' {
        InModuleScope PolicyEngine {
            $r = [pscustomobject]@{ ResourceType = 'aadgroup'; Key = $null; Workload = 'Entra ID'; TenantId = $null; Properties = [ordered]@{ DisplayName = 'S'; credential = 'x'; MEMBERS = @('a'); owners = @('b') } }
            $n = ConvertTo-PENormalizedRecord -Record $r
            @($n.Properties.Keys) | Should -Be @('DisplayName')
        }
    }

    It 'does not mutate the input record' {
        InModuleScope PolicyEngine {
            $props = [ordered]@{ Id = '1'; DisplayName = 'S'; Members = @('a') }
            $r = [pscustomobject]@{ ResourceType = 'AADGroup'; Key = $null; Workload = 'Entra ID'; TenantId = $null; Properties = $props }
            $null = ConvertTo-PENormalizedRecord -Record $r
            $r.Key | Should -BeNullOrEmpty
            $r.Properties.Keys | Should -Contain 'Id'
            $r.Properties.Keys | Should -Contain 'Members'
        }
    }

    It 'passes nested values and arrays through unchanged' {
        InModuleScope PolicyEngine {
            $cim = [ordered]@{ Name = 'inner'; Values = @(1, 2) }
            $arr = @('x', 'y')
            $r = [pscustomobject]@{ ResourceType = 'TeamsTeam'; Key = $null; Workload = 'Teams'; TenantId = $null; Properties = [ordered]@{ DisplayName = 'T'; Nested = $cim; List = $arr } }
            $n = ConvertTo-PENormalizedRecord -Record $r
            [object]::ReferenceEquals($n.Properties.Nested, $cim) | Should -BeTrue
            $n.Properties.List | Should -Be @('x', 'y')
        }
    }

    It 'gives a singleton resource the key (singleton)' {
        InModuleScope PolicyEngine {
            $r = [pscustomobject]@{ ResourceType = 'AADAuthorizationPolicy'; Key = $null; Workload = 'Entra ID'; TenantId = $null; Properties = [ordered]@{ IsSingleInstance = 'Yes'; AllowInvitesFrom = 'everyone' } }
            (ConvertTo-PENormalizedRecord -Record $r).Key | Should -Be '(singleton)'
        }
    }

    It 'leaves Key null when the record has neither a key nor IsSingleInstance' {
        InModuleScope PolicyEngine {
            $r = [pscustomobject]@{ ResourceType = 'AADGroup'; Key = $null; Workload = 'Entra ID'; TenantId = $null; Properties = [ordered]@{ Description = 'x' } }
            (ConvertTo-PENormalizedRecord -Record $r).Key | Should -BeNullOrEmpty
        }
    }

    It 'skips array-valued key candidates instead of joining them' {
        InModuleScope PolicyEngine {
            Get-PEResourceKey -ResourceType 'AADGroup' -Properties @{ DisplayName = @('a', 'b'); Name = 'n' } | Should -Be 'n'
            Get-PEResourceKey -ResourceType 'AADGroup' -Properties @{ DisplayName = @('a', 'b') } | Should -BeNullOrEmpty
        }
    }

    It 'does not use AppId for AADServicePrincipal' {
        InModuleScope PolicyEngine {
            Get-PEResourceKey -ResourceType 'AADServicePrincipal' -Properties @{ AppId = '00000000-0000-0000-0000-000000000001'; DisplayName = 'My App' } | Should -Be 'My App'
        }
    }

    It 'tolerates a record without a TenantId field under strict mode' {
        InModuleScope PolicyEngine {
            Set-StrictMode -Version Latest
            $r = [pscustomobject]@{ ResourceType = 'AADGroup'; Key = $null; Workload = 'Entra ID'; Properties = [ordered]@{ DisplayName = 'S' } }
            (ConvertTo-PENormalizedRecord -Record $r).TenantId | Should -BeNullOrEmpty
        }
    }
}

Describe 'New-PEState' {
    It 'builds a state from records, not-checked entries and meta' {
        InModuleScope PolicyEngine {
            $rec = [pscustomobject]@{ ResourceType = 'AADGroup'; Key = 'S'; Workload = 'Entra ID'; TenantId = $null; Properties = [ordered]@{} }
            $nc = @(@{ ResourceType = 'EXOFoo'; Reason = 'not exported' })
            $meta = @{ TenantId = 't'; ExportedAt = '2026-10-21'; Source = 'x.ps1' }
            $s = New-PEState -Records @($rec) -NotChecked $nc -Meta $meta
            @($s.Records).Count | Should -Be 1
            $s.Records[0].Key | Should -Be 'S'
            $s.NotChecked[0].Reason | Should -Be 'not exported'
            $s.Meta.TenantId | Should -Be 't'
        }
    }

    It 'accepts empty inputs' {
        InModuleScope PolicyEngine {
            $s = New-PEState -Records @() -NotChecked @() -Meta @{}
            @($s.Records).Count | Should -Be 0
            @($s.NotChecked).Count | Should -Be 0
        }
    }
}

Describe 'Nested ignore paths' {
    BeforeAll {
        # Replaces the ignore data for one test (restored from the data file after each test).
        function Set-TestIgnoreData
        {
            param ([hashtable]$ByType = @{}, [string[]]$Global = @())

            InModuleScope PolicyEngine -Parameters @{ B = $ByType; G = $Global } {
                param ($B, $G)
                $script:PEIgnoredProperties = @{ Global = @($G); ByType = $B }
                $script:PEIgnoredPaths = $null
            }
        }

        function New-TestRaw
        {
            param ([string]$Type, [System.Collections.IDictionary]$Properties)
            [pscustomobject]@{ ResourceType = $Type; Key = $null; Workload = 'Entra ID'; TenantId = $null; Properties = $Properties }
        }

        function Invoke-TestNormalize
        {
            param ($Raw, $ExportedAt)
            InModuleScope PolicyEngine -Parameters @{ R = $Raw; E = $ExportedAt } { param ($R, $E) ConvertTo-PENormalizedRecord -Record $R -ExportedAt $E }
        }

        function New-TestAssignmentRaw
        {
            param ($Start)
            $schedule = @{ CIMInstance = 'MSFT_AADRoleAssignmentScheduleRequestSchedule'; startDateTime = $Start; expiration = @{ CIMInstance = 'MSFT_AADRoleAssignmentScheduleRequestScheduleExpiration'; type = 'noExpiration' } }
            New-TestRaw -Type 'AADRoleAssignmentScheduleRequest' -Properties ([ordered]@{ Principal = 'p'; RoleDefinition = 'r'; DirectoryScopeId = '/'; ScheduleInfo = $schedule })
        }
    }

    AfterEach {
        InModuleScope PolicyEngine {
            $script:PEIgnoredProperties = $null
            $script:PEIgnoredPaths = $null
        }
    }

    It 'removes a ScheduleInfo.startDateTime before the export time and keeps the rest of ScheduleInfo' {
        $n = Invoke-TestNormalize (New-TestAssignmentRaw -Start '2026-10-20T11:27:15Z') -ExportedAt '2026-10-22T08:51:16Z'
        @($n.Properties.ScheduleInfo.Keys) | Should -Not -Contain 'startDateTime'
        $n.Properties.ScheduleInfo.CIMInstance | Should -Be 'MSFT_AADRoleAssignmentScheduleRequestSchedule'
        $n.Properties.ScheduleInfo.expiration.type | Should -Be 'noExpiration'
        $n.Key | Should -Be 'p | r | /'
    }

    It 'removes a start equal to the export time, and an empty start' {
        (Invoke-TestNormalize (New-TestAssignmentRaw -Start '2026-10-22T08:51:16Z') -ExportedAt '2026-10-22T08:51:16Z').Properties.ScheduleInfo.Keys | Should -Not -Contain 'startDateTime'
        (Invoke-TestNormalize (New-TestAssignmentRaw -Start '') -ExportedAt '2026-10-22T08:51:16Z').Properties.ScheduleInfo.Keys | Should -Not -Contain 'startDateTime'
        # The same instant written with an offset.
        (Invoke-TestNormalize (New-TestAssignmentRaw -Start '2026-10-22T10:51:16+02:00') -ExportedAt '2026-10-22T08:51:16Z').Properties.ScheduleInfo.Keys | Should -Not -Contain 'startDateTime'
    }

    It 'keeps a future start, an unparseable start, and any start when the export time is unknown' {
        (Invoke-TestNormalize (New-TestAssignmentRaw -Start '2026-12-01T00:00:00Z') -ExportedAt '2026-10-22T08:51:16Z').Properties.ScheduleInfo.startDateTime | Should -Be '2026-12-01T00:00:00Z'
        (Invoke-TestNormalize (New-TestAssignmentRaw -Start 'soon') -ExportedAt '2026-10-22T08:51:16Z').Properties.ScheduleInfo.startDateTime | Should -Be 'soon'
        (Invoke-TestNormalize (New-TestAssignmentRaw -Start '2026-10-20T11:27:15Z')).Properties.ScheduleInfo.startDateTime | Should -Be '2026-10-20T11:27:15Z'
        (Invoke-TestNormalize (New-TestAssignmentRaw -Start '2026-10-20T11:27:15Z') -ExportedAt 'not a date').Properties.ScheduleInfo.startDateTime | Should -Be '2026-10-20T11:27:15Z'
    }

    It 'does not mutate the input record (nested containers are copied along the path)' {
        Set-TestIgnoreData -ByType @{ TestType = @('ScheduleInfo.startDateTime') }
        $expiration = @{ type = 'noExpiration' }
        $schedule = @{ startDateTime = 's'; expiration = $expiration }
        $raw = New-TestRaw -Type 'TestType' -Properties ([ordered]@{ DisplayName = 'p'; ScheduleInfo = $schedule })
        $n = Invoke-TestNormalize $raw
        $schedule.Keys | Should -Contain 'startDateTime'
        [object]::ReferenceEquals($raw.Properties.ScheduleInfo, $schedule) | Should -BeTrue
        [object]::ReferenceEquals($n.Properties.ScheduleInfo, $schedule) | Should -BeFalse
        @($n.Properties.ScheduleInfo.Keys) | Should -Not -Contain 'startDateTime'
        # Members off the path are shared, not copied.
        [object]::ReferenceEquals($n.Properties.ScheduleInfo.expiration, $expiration) | Should -BeTrue
    }

    It 'matches property names and path segments case-insensitively' {
        Set-TestIgnoreData -ByType @{ TestType = @('scheduleinfo.STARTDATETIME') }
        $raw = New-TestRaw -Type 'testtype' -Properties ([ordered]@{ DisplayName = 'x'; ScheduleInfo = [ordered]@{ StartDateTime = 's'; Other = 'o' } })
        $n = Invoke-TestNormalize $raw
        @($n.Properties.ScheduleInfo.Keys) | Should -Be @('Other')
    }

    It 'walks PSCustomObjects (a state read back from JSON) and returns PSCustomObjects' {
        Set-TestIgnoreData -ByType @{ TestType = @('Outer.Inner.drop') }
        $outer = '{"Inner":{"drop":1,"keep":2},"Name":"n"}' | ConvertFrom-Json
        $raw = New-TestRaw -Type 'TestType' -Properties ([ordered]@{ DisplayName = 'x'; Outer = $outer })
        $n = Invoke-TestNormalize $raw
        $n.Properties.Outer | Should -BeOfType [System.Management.Automation.PSCustomObject]
        @($n.Properties.Outer.Inner.PSObject.Properties.Name) | Should -Be @('keep')
        $n.Properties.Outer.Name | Should -Be 'n'
        @($outer.Inner.PSObject.Properties.Name) | Should -Be @('drop', 'keep')
    }

    It 'walks a CimInstance' {
        Set-TestIgnoreData -ByType @{ TestType = @('Settings.drop') }
        $cim = New-CimInstance -ClassName 'MSFT_TestSetting' -Namespace 'root/test' -ClientOnly -Property @{ drop = 'd'; keep = 'k' }
        $raw = New-TestRaw -Type 'TestType' -Properties ([ordered]@{ DisplayName = 'x'; Settings = $cim })
        $n = Invoke-TestNormalize $raw
        $n.Properties.Settings.keep | Should -Be 'k'
        $n.Properties.Settings.CIMInstance | Should -Be 'MSFT_TestSetting'
        @($n.Properties.Settings.Keys) | Should -Not -Contain 'drop'
    }

    It 'applies the path to every element of an array (Intune-style assignments)' {
        Set-TestIgnoreData -ByType @{ TestType = @('Assignments.groupId') }
        $a1 = @{ CIMInstance = 'MSFT_Assignment'; groupId = 'g1'; groupDisplayName = 'One' }
        $a2 = @{ CIMInstance = 'MSFT_Assignment'; groupId = 'g2'; groupDisplayName = 'Two' }
        $raw = New-TestRaw -Type 'TestType' -Properties ([ordered]@{ DisplayName = 'x'; Assignments = @($a1, 'scalar', $a2) })
        $n = Invoke-TestNormalize $raw
        $list = @($n.Properties.Assignments)
        $list.Count | Should -Be 3
        $list[0].Keys | Should -Not -Contain 'groupId'
        $list[0].groupDisplayName | Should -Be 'One'
        $list[1] | Should -Be 'scalar'
        $list[2].Keys | Should -Not -Contain 'groupId'
        $list[2].groupDisplayName | Should -Be 'Two'
        $a1.Keys | Should -Contain 'groupId'
    }

    It 'drops a parent object the removal leaves empty, keeps one with other members, and never drops array elements' {
        Set-TestIgnoreData -ByType @{ TestType = @('Only.drop', 'Two.drop', 'List.drop') }
        $props = [ordered]@{
            DisplayName = 'x'
            Only        = @{ CIMInstance = 'MSFT_Only'; drop = 1 }
            Two         = @{ drop = 1; keep = 2 }
            List        = @(@{ CIMInstance = 'MSFT_Item'; drop = 1 }, @{ drop = 2; keep = 3 })
        }
        $n = Invoke-TestNormalize (New-TestRaw -Type 'TestType' -Properties $props)
        @($n.Properties.Keys) | Should -Be @('DisplayName', 'Two', 'List')
        @($n.Properties.Two.Keys) | Should -Be @('keep')
        $list = @($n.Properties.List)
        $list.Count | Should -Be 2
        @($list[0].Keys) | Should -Be @('CIMInstance')
        $list[1].keep | Should -Be 3
    }

    It 'keeps an array whose elements all become empty, with every element' {
        Set-TestIgnoreData -ByType @{ TestType = @('List.drop') }
        $n = Invoke-TestNormalize (New-TestRaw -Type 'TestType' -Properties ([ordered]@{ DisplayName = 'x'; List = @(@{ drop = 1 }, @{ drop = 2 }) }))
        @($n.Properties.Keys) | Should -Be @('DisplayName', 'List')
        @($n.Properties.List).Count | Should -Be 2
    }

    It 'a nested array ignore still shows a change in the number of elements' {
        Set-TestIgnoreData -ByType @{ TestType = @('Assignments.groupId') }
        $mk = { param ($id, $name) @{ CIMInstance = 'MSFT_Assignment'; dataType = '#microsoft.graph.groupAssignmentTarget'; groupId = $id; groupDisplayName = $name } }
        $two = Invoke-TestNormalize (New-TestRaw -Type 'TestType' -Properties ([ordered]@{ DisplayName = 'x'; Assignments = @((& $mk 'g1' 'One'), (& $mk 'g2' 'Two')) }))
        $one = Invoke-TestNormalize (New-TestRaw -Type 'TestType' -Properties ([ordered]@{ DisplayName = 'x'; Assignments = @((& $mk 'other-tenant-guid' 'One')) }))
        $none = Invoke-TestNormalize (New-TestRaw -Type 'TestType' -Properties ([ordered]@{ DisplayName = 'x' }))
        $same = Invoke-TestNormalize (New-TestRaw -Type 'TestType' -Properties ([ordered]@{ DisplayName = 'x'; Assignments = @((& $mk 'g1' 'One')) }))
        InModuleScope PolicyEngine -Parameters @{ Two = $two; One = $one; None = $none; Same = $same } {
            param ($Two, $One, $None, $Same)
            @(Get-PEPropertyDifference $Two.Properties $One.Properties).Property | Should -Be @('Assignments')
            @(Get-PEPropertyDifference $Two.Properties $None.Properties).Property | Should -Be @('Assignments')
            # Only the ignored groupId differs.
            (Get-PEPropertyDifference $One.Properties $Same.Properties).Count | Should -Be 0
        }
    }

    It 'a path that does not exist changes nothing' {
        Set-TestIgnoreData -ByType @{ TestType = @('Nested.missing', 'Absent.x') }
        $nested = @{ a = 1 }
        $n = Invoke-TestNormalize (New-TestRaw -Type 'TestType' -Properties ([ordered]@{ DisplayName = 'x'; Nested = $nested }))
        [object]::ReferenceEquals($n.Properties.Nested, $nested) | Should -BeTrue
        @($n.Properties.Keys) | Should -Be @('DisplayName', 'Nested')
    }

    It 'a path through a non-object value changes nothing' {
        Set-TestIgnoreData -ByType @{ TestType = @('Description.Length', 'Count.x', 'Tags.Length', 'Empty.x') }
        $tags = @('a', 'bb')
        $n = Invoke-TestNormalize (New-TestRaw -Type 'TestType' -Properties ([ordered]@{ DisplayName = 'x'; Description = 'text'; Count = 3; Tags = $tags; Empty = $null }))
        $n.Properties.Description | Should -Be 'text'
        $n.Properties['Count'] | Should -Be 3
        [object]::ReferenceEquals($n.Properties.Tags, $tags) | Should -BeTrue
        @($n.Properties.get_Keys()) | Should -Be @('DisplayName', 'Description', 'Count', 'Tags', 'Empty')
    }

    It 'applies a Global dotted path to every type, and a ByType path only to its type' {
        Set-TestIgnoreData -Global @('Meta.stamp') -ByType @{ TypeA = @('Settings.drop') }
        $na = Invoke-TestNormalize (New-TestRaw -Type 'TypeA' -Properties ([ordered]@{ DisplayName = 'a'; Meta = @{ stamp = 1; keep = 1 }; Settings = @{ drop = 1; keep = 1 } }))
        $nb = Invoke-TestNormalize (New-TestRaw -Type 'TypeB' -Properties ([ordered]@{ DisplayName = 'b'; Meta = @{ stamp = 1; keep = 1 }; Settings = @{ drop = 1; keep = 1 } }))
        @($na.Properties.Meta.Keys) | Should -Be @('keep')
        @($na.Properties.Settings.Keys) | Should -Be @('keep')
        @($nb.Properties.Meta.Keys) | Should -Be @('keep')
        @($nb.Properties.Settings.Keys | Sort-Object) | Should -Be @('drop', 'keep')
    }

    It 'throws on a path with an empty segment' {
        Set-TestIgnoreData -ByType @{ TestType = @('A..b') }
        { Invoke-TestNormalize (New-TestRaw -Type 'TestType' -Properties ([ordered]@{ DisplayName = 'x' })) } | Should -Throw '*empty segment*'
    }

    It 'every entry of the ignore data file is a name or a well-formed dotted path' {
        InModuleScope PolicyEngine {
            $data = Get-PEIgnoredProperties
            foreach ($type in @($data.ByType.Keys) + @('AnyOtherType'))
            {
                { Get-PEIgnoredPath -ResourceType $type } | Should -Not -Throw -Because $type
            }
            $paths = Get-PEIgnoredPath -ResourceType 'AADRoleAssignmentScheduleRequest'
            $schedule = @($paths | Where-Object { ($_.Segments -join '.') -eq 'ScheduleInfo.startDateTime' })
            $schedule.Count | Should -Be 1
            $schedule[0].When | Should -Be 'PastExport'
        }
    }
}

Describe 'ExcludedTypes data file' {
    It 'gives every excluded type a reason' {
        InModuleScope PolicyEngine {
            $map = Get-PEExcludedTypeMap
            $map.Count | Should -BeGreaterThan 0
            foreach ($type in $map.Keys)
            {
                $type | Should -Match '^[A-Za-z0-9]+$'
                $map[$type].Reason | Should -Not -BeNullOrEmpty -Because $type
            }
        }
    }

    It 'excludes EXOManagementRoleEntry and the per-mailbox types, and no tenant-wide policy type' {
        InModuleScope PolicyEngine {
            $map = Get-PEExcludedTypeMap
            foreach ($type in 'EXOManagementRoleEntry', 'EXOMailboxSettings', 'EXOCASMailboxSettings', 'EXOMailboxPermission', 'EXORecipientPermission')
            {
                $map.ContainsKey($type) | Should -BeTrue -Because $type
            }
            foreach ($type in 'EXOOrganizationConfig', 'EXOMailboxPlan', 'EXOCASMailboxPlan', 'EXOOwaMailboxPolicy', 'EXORoleGroup', 'EXOManagementRoleAssignment', 'EXODistributionGroup', 'EXOTransportRule', 'EXOAuthenticationPolicy', 'AADGroup')
            {
                $map.ContainsKey($type) | Should -BeFalse -Because $type
            }
            $map['EXOMailboxSettings'].Reason | Should -Match 'GUID'
            $map['EXOMailboxSettings'].RecordRule | Should -BeNullOrEmpty
            $map['EXOManagementRoleEntry'].RecordRule | Should -Be 'KeepCustomRoleEntries'
            $map['EXOManagementRoleEntry'].Reason | Should -Match 'custom roles'
        }
    }

    It 'excludes the user-bound types and keeps every type that grants admin roles' {
        InModuleScope PolicyEngine {
            $map = Get-PEExcludedTypeMap
            foreach ($type in 'AADUser', 'AADAuthenticationRequirement', 'TeamsUser', 'TeamsUserCallingSettings', 'TeamsOnlineVoicemailUserSettings', 'TeamsOnlineVoiceUser', 'TeamsUserPolicyAssignment')
            {
                $map.ContainsKey($type) | Should -BeTrue -Because $type
            }
            foreach ($type in 'AADRoleAssignmentScheduleRequest', 'AADRoleEligibilityScheduleRequest', 'EXOManagementRoleAssignment', 'IntuneRoleAssignment', 'EXORoleGroup', 'TeamsGroupPolicyAssignment')
            {
                $map.ContainsKey($type) | Should -BeFalse -Because $type
            }
        }
    }

    It 'adds the user-list property ignores' {
        InModuleScope PolicyEngine {
            $byType = (Get-PEIgnoredProperties).ByType
            $byType['AADAdministrativeUnit'] | Should -Contain 'Members'
            $byType['AADServicePrincipal'] | Should -Contain 'AppRoleAssignedTo'
            $byType['AADServicePrincipal'] | Should -Contain 'Owners'
            $byType['AADApplication'] | Should -Contain 'Owners'
            $byType['EXODistributionGroup'] | Should -Contain 'Members'
            $byType['TeamsTeam'] | Should -Contain 'Owner'
        }
    }

    It 'returns a new map on every call (callers may remove types)' {
        InModuleScope PolicyEngine {
            $first = Get-PEExcludedTypeMap
            [void]$first.Remove('EXOManagementRoleEntry')
            (Get-PEExcludedTypeMap).ContainsKey('exomanagementroleentry') | Should -BeTrue
        }
    }
}
