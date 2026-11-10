BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Records = InModuleScope PolicyEngine -Parameters @{ F = (Join-Path $PSScriptRoot 'fixtures\mini-export.ps1') } { @(Read-PEExport -Path $F) }
    $script:Empty = Join-Path $PSScriptRoot 'fixtures\empty-export.ps1'
}

Describe 'Read-PEExport' {
    It 'returns one record per instance' {
        $script:Records.Count | Should -Be 4
    }

    It 'ResourceType comes from the DSC resource name' {
        @($script:Records | Where-Object ResourceType -eq 'AADGroup').Count | Should -Be 3
    }

    It 'Properties keep the exported values' {
        $sales = $script:Records | Where-Object { $_.Properties.DisplayName -eq 'Sales' }
        $sales.Properties.DisplayName | Should -Be 'Sales'
        $sales.Key | Should -BeNullOrEmpty
        $sales.Properties.Keys | Should -Not -Contain 'ResourceName'
        $sales.Properties.Keys | Should -Not -Contain 'ResourceInstanceName'
    }

    It 'sets Workload on every record' {
        @($script:Records | Where-Object Workload -eq 'Entra ID').Count | Should -Be 4
    }

    It 'keeps Members as an array' {
        $sales = $script:Records | Where-Object { $_.Properties.DisplayName -eq 'Sales' }
        , $sales.Properties.Members | Should -BeOfType [object[]]
        @($sales.Properties.Members) | Should -Be @('a@x.com')
    }

    It 'keeps booleans as booleans' {
        $sales = $script:Records | Where-Object { $_.Properties.DisplayName -eq 'Sales' }
        $sales.Properties.MailEnabled | Should -BeOfType [bool]
        $sales.Properties.MailEnabled | Should -Be $false
        $sales.Properties.SecurityEnabled | Should -Be $true
    }

    It 'keeps duplicate DisplayNames as separate records with their own Ids' {
        $fin = @($script:Records | Where-Object { $_.Properties.DisplayName -eq 'Finance' })
        $fin.Count | Should -Be 2
        @($fin.Properties.Id | Sort-Object) | Should -Be @('22222222-2222-2222-2222-222222222222', '33333333-3333-3333-3333-333333333333')
    }

    It 'keeps nested CIM instances as nested values' {
        $ca = $script:Records | Where-Object ResourceType -eq 'AADConditionalAccessPolicy'
        $ca.Properties.SessionControls.IsEnabled | Should -Be $true
        $ca.Properties.SessionControls.Name | Should -Be 'inner'
    }

    It 'yields zero records for a configuration with no instances' {
        $n = InModuleScope PolicyEngine -Parameters @{ F = $script:Empty } { @(Read-PEExport -Path $F).Count }
        $n | Should -Be 0
    }

    It 'throws for a missing path' {
        { InModuleScope PolicyEngine { Read-PEExport -Path 'Z:\no\such\export.ps1' } } | Should -Throw '*not found*'
    }
}

Describe 'Get-PEWorkload' {
    It 'maps prefixes' {
        InModuleScope PolicyEngine {
            Get-PEWorkload -ResourceType 'AADGroup' | Should -Be 'Entra ID'
            Get-PEWorkload -ResourceType 'EXOAcceptedDomain' | Should -Be 'Exchange Online'
            Get-PEWorkload -ResourceType 'TeamsMeetingPolicy' | Should -Be 'Teams'
            Get-PEWorkload -ResourceType 'IntuneX' | Should -Be 'Intune'
            Get-PEWorkload -ResourceType 'SPOSite' | Should -Be 'Other'
        }
    }
}

Describe 'Workloads (Data\Workloads.psd1)' {
    It 'labels Security and Compliance and leaves it out of the default export' {
        InModuleScope PolicyEngine {
            Get-PEWorkload -ResourceType 'SCLabelPolicy' | Should -Be 'Security and Compliance'
            Get-PEDefaultWorkload | Should -Be @('AAD', 'Intune', 'EXO', 'Teams')
        }
    }

    It 'one pattern selects every supported workload, for the apps and the permission script' {
        InModuleScope PolicyEngine {
            $pattern = Get-PEWorkloadPattern
            'SCLabelPolicy' | Should -Match $pattern
            'AADGroup' | Should -Match $pattern
            'SPOSite' | Should -Not -Match $pattern
        }
    }
}

Describe 'Read-PEExport with a UTF-8 byte order mark' {
    # Microsoft365DSC 2.26.1028.1 and later write export.ps1 as UTF-8 with a BOM.
    It 'reads the same records from a BOM copy as from a BOM-less copy' {
        $source = Join-Path $PSScriptRoot 'fixtures\mini-export.ps1'
        $text = [System.IO.File]::ReadAllText($source, [System.Text.UTF8Encoding]::new($false)).TrimStart([char]0xFEFF)
        $folder = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-bom-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        try
        {
            $plain = Join-Path $folder 'plain.ps1'
            $bom = Join-Path $folder 'bom.ps1'
            [System.IO.File]::WriteAllText($plain, $text, [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText($bom, $text, [System.Text.UTF8Encoding]::new($true))
            ([System.IO.File]::ReadAllBytes($bom))[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)

            $a = InModuleScope PolicyEngine -Parameters @{ F = $plain } { @(Read-PEExport -Path $F 3>$null) }
            $b = InModuleScope PolicyEngine -Parameters @{ F = $bom } { @(Read-PEExport -Path $F 3>$null) }
            $b.Count | Should -Be $a.Count
            $a.Count | Should -BeGreaterThan 0
            ($b | ForEach-Object { '{0}|{1}' -f $_.ResourceType, $_.Key }) | Should -Be ($a | ForEach-Object { '{0}|{1}' -f $_.ResourceType, $_.Key })
            ($b | ForEach-Object { ($_.Properties.Keys | Sort-Object) -join ',' }) | Should -Be ($a | ForEach-Object { ($_.Properties.Keys | Sort-Object) -join ',' })
        }
        finally
        {
            Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
