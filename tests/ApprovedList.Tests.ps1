BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Fp = ('a' * 64)
    function New-Side
    {
        param ([string]$Run = '101')
        @{ Run = $Run; ExportedAt = '2026-11-03T10:00:00Z'; Fingerprint = $script:Fp }
    }
    function New-TestList
    {
        param ([object[]]$Item)
        if (-not $Item)
        {
            $Item = @(
                @{ Action = 'Create'; ResourceType = 'AADGroup'; Key = 'Finance'; ExcludedProperties = @() }
                @{ Action = 'Create'; ResourceType = 'AADGroup'; Key = 'HR'; ExcludedProperties = @() }
                @{ Action = 'Create'; ResourceType = 'AADGroup'; Key = 'Ops'; ExcludedProperties = @() }
                @{ Action = 'Update'; ResourceType = 'AADGroup'; Key = 'Sales'; ExcludedProperties = @('MailNickname') }
            )
        }
        New-PEApprovedList -Tenant 'dev' -ApprovedBy 'andrew' -Source (New-Side '101') -Target (New-Side '102') -Item $Item -ModuleVersion '2.26.1104.1' -CreatedUtc ([datetime]'2026-11-03T11:00:00Z')
    }
    function Save-Json
    {
        param ([string]$Json)
        $p = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-al-' + [guid]::NewGuid().ToString('N') + '.json')
        [System.IO.File]::WriteAllText($p, $Json, [System.Text.UTF8Encoding]::new($false))
        $p
    }
}

Describe 'New-PEApprovedList / Save / Read' {
    It 'round-trips a list through Save and Read' {
        $list = New-TestList
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-al-' + [guid]::NewGuid().ToString('N') + '\approvals\a.json')
        Save-PEApprovedList -List $list -Path $path
        $back = Read-PEApprovedList -Path $path
        $back.Format | Should -Be 1
        $back.Tenant | Should -Be 'dev'
        $back.Items.Count | Should -Be 4
        $back.Items[3].ExcludedProperties | Should -Be @('MailNickname')
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes[0] | Should -Not -Be 0xEF
        [System.Text.Encoding]::UTF8.GetString($bytes) | Should -Not -Match "`r"
    }

    It 'counts items per type and action' {
        $c = (New-TestList).Counts
        $c.Count | Should -Be 2
        ($c | Where-Object Action -eq 'Create').Count | Should -Be 3
        ($c | Where-Object Action -eq 'Update').Count | Should -Be 1
    }

    It 'refuses to overwrite a saved list' {
        $list = New-TestList
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-al-' + [guid]::NewGuid().ToString('N') + '.json')
        Save-PEApprovedList -List $list -Path $path
        { Save-PEApprovedList -List $list -Path $path } | Should -Throw '*already exists*'
    }

    It 'Read refuses <Name>' -ForEach @(
        @{ Name = 'an unknown action'; Mutate = { param ($j) $j.Items[0].Action = 'Delete' } }
        @{ Name = 'an item with an extra Value property'; Mutate = { param ($j) $j.Items[0] | Add-Member Value 'x' } }
        @{ Name = 'an extra top-level property'; Mutate = { param ($j) $j | Add-Member Extra 1 } }
        @{ Name = 'a duplicate item differing only in key case'; Mutate = { param ($j) $j.Items[1].Key = 'FINANCE' } }
        @{ Name = 'a key with a newline'; Mutate = { param ($j) $j.Items[0].Key = "a`nb" } }
        @{ Name = 'a bad fingerprint'; Mutate = { param ($j) $j.Source.Fingerprint = 'xyz' } }
        @{ Name = 'a bad run id'; Mutate = { param ($j) $j.Target.Run = '12a' } }
        @{ Name = 'a hand-edited Counts'; Mutate = { param ($j) $j.Counts[0].Count = 99 } }
        @{ Name = 'Format 2'; Mutate = { param ($j) $j.Format = 2 } }
        @{ Name = 'a Tenant of Dev Tenant'; Mutate = { param ($j) $j.Tenant = 'Dev Tenant' } }
        @{ Name = 'an ExcludedProperties entry with a space'; Mutate = { param ($j) $j.Items[3].ExcludedProperties = @('a b') } }
    ) {
        $j = (New-TestList | ConvertTo-Json -Depth 8) | ConvertFrom-Json -DateKind String
        & $Mutate $j
        $path = Save-Json ($j | ConvertTo-Json -Depth 8)
        { Read-PEApprovedList -Path $path } | Should -Throw 'Approved list*'
    }
}

Describe 'Read-PEApprovedList Counts order' {
    It 'accepts Counts rows in any order (the order is not part of the format)' {
        $items = @(
            @{ Action = 'Update'; ResourceType = 'AADGroup'; Key = 'Sales'; ExcludedProperties = @() }
            @{ Action = 'Create'; ResourceType = 'AADGroup'; Key = 'Finance'; ExcludedProperties = @() }
            @{ Action = 'Create'; ResourceType = 'EXOAcceptedDomain'; Key = 'contoso.com'; ExcludedProperties = @() }
        )
        $j = (New-PEApprovedList -Tenant 'dev' -ApprovedBy 'a' -Source (New-Side '1') -Target (New-Side '2') -Item $items -ModuleVersion '2.26.1104.1' | ConvertTo-Json -Depth 8) | ConvertFrom-Json -DateKind String
        $j.Counts = @($j.Counts[2], $j.Counts[0], $j.Counts[1])
        $path = Save-Json ($j | ConvertTo-Json -Depth 8)
        { Read-PEApprovedList -Path $path } | Should -Not -Throw
    }
}
