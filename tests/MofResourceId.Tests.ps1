BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    function New-Mof
    {
        param ([string[]]$Id)
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-mof-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $lines = [System.Collections.Generic.List[string]]::new()
        $n = 0
        foreach ($one in $Id)
        {
            $n++
            $lines.Add('instance of AADGroup as $AADGroup' + $n + 'ref')
            $lines.Add('{')
            $lines.Add(' ResourceID = "' + $one + '";')
            $lines.Add(' DisplayName = "x";')
            $lines.Add('};')
            $lines.Add('')
        }
        $lines.Add('instance of OMI_ConfigurationDocument')
        $lines.Add('{')
        $lines.Add(' Version = "2.0.0";')
        $lines.Add('};')
        Set-Content (Join-Path $dir 'localhost.mof') -Value $lines
        $dir
    }
}

Describe 'Get-PEMofResourceId' {
    It 'lists the ResourceID of every instance in a compiled MOF, not the configuration document' {
        $dir = New-Mof @('[AADGroup]AADGroup-Finance', '[AADGroup]AADGroup-Sales')
        @(Get-PEMofResourceId -Path $dir) | Should -Be @('[AADGroup]AADGroup-Finance', '[AADGroup]AADGroup-Sales')
    }

    It 'accepts the MOF file itself' {
        $dir = New-Mof @('[AADGroup]AADGroup-Finance')
        @(Get-PEMofResourceId -Path (Join-Path $dir 'localhost.mof')) | Should -Be @('[AADGroup]AADGroup-Finance')
    }

    It 'throws when there is no MOF' {
        $empty = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-mof-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $empty | Out-Null
        { Get-PEMofResourceId -Path $empty } | Should -Throw '*No MOF*'
    }
}

Describe 'Test-PEResourceIdInMof' {
    It 'returns nothing when every expected id is in the MOF (case does not matter)' {
        $dir = New-Mof @('[AADGroup]AADGroup-Finance')
        @(Test-PEResourceIdInMof -ExpectedId @('[aadgroup]aadgroup-finance') -Path $dir).Count | Should -Be 0
    }

    It 'returns the ids the MOF does not have' {
        $dir = New-Mof @('[AADGroup]AADGroup-Finance')
        @(Test-PEResourceIdInMof -ExpectedId @('[AADGroup]AADGroup-Finance', '[AADGroup]AADGroup-Other') -Path $dir) | Should -Be @('[AADGroup]AADGroup-Other')
    }
}
