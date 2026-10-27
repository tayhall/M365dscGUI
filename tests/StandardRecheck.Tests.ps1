BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures\asd-mini'
    . "$PSScriptRoot\StandardTestHelper.ps1"

    function Import-TestStandard
    {
        param ([string]$Path, [string]$SourceVersion, [string]$Root)
        Import-PEStandard -Name 'asd' -Path $Path -SourceName 'ASD' -SourceUrl 'https://example.test' -SourceVersion $SourceVersion -DataRoot $Root -WarningAction SilentlyContinue 6>$null
    }
}

Describe 'Checking a tenant against a newer version of a standard' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-recheck-' + [guid]::NewGuid())
    }

    AfterEach {
        if (Test-Path $script:Temp) { Remove-Item $script:Temp -Recurse -Force }
    }

    It 'keeps an accepted risk until the standard changes the item, then asks for another look, and adopts what is promoted' {
        Import-TestStandard -Path $script:Fixture -SourceVersion 'v1.4.0' -Root $script:Temp | Out-Null
        $folder = New-TenantExport -Root $script:Temp -Countries '@("AU","NZ")'
        $export = { $folder }.GetNewClosure()
        $check = { Invoke-PEStandardCheck -StandardName 'asd' -ExportScript $export -TargetTenantId 'tenant-1' -DataRoot $script:Temp }

        # v1: the named location differs (Changed) and the Teams policy is missing.
        $first = & $check
        @($first.Findings | Where-Object { $_.State -eq 'Open' -and $_.Kind -in 'Changed', 'Missing' }).Count | Should -Be 2

        # The location is accepted with who and why; the next check shows it as Accepted.
        Set-PERiskAcceptance -Standard 'asd' -Tenant master -ResourceType AADNamedLocationPolicy -Key 'Allowed Countries' -ApprovedBy 'cio' -Reason 'NZ staff' -DataRoot $script:Temp | Out-Null
        $second = & $check
        (@($second.Findings | Where-Object ResourceType -EQ 'AADNamedLocationPolicy')[0]).State | Should -Be 'Accepted'

        # v2 of the standard changes the value it states for that location.
        $copy = Join-Path $script:Temp 'v2files'
        Copy-Item -LiteralPath $script:Fixture -Destination $copy -Recurse
        $entra = Join-Path $copy 'Entra.txt'
        (Get-Content -LiteralPath $entra -Raw).Replace('CountriesAndRegions               = @("AU");', 'CountriesAndRegions               = @("AU","FJ");') | Set-Content -LiteralPath $entra -NoNewline
        $imported = Import-TestStandard -Path $copy -SourceVersion 'v1.5.0' -Root $script:Temp
        $imported.Version | Should -Be 2
        $change = @(Get-PEStandardChange -Name 'asd' -FromVersion 1 -ToVersion 2 -DataRoot $script:Temp)
        $change.Count | Should -Be 1
        $change[0].Op | Should -Be 'Changed'

        $third = & $check
        $third.Coverage.Checked | Should -Be 2
        $location = @($third.Findings | Where-Object ResourceType -EQ 'AADNamedLocationPolicy')[0]
        $location.State | Should -Be 'Open'
        $location.Hint | Should -Be 'Accepted risk needs another look: the standard has changed.'

        # The Teams policy is promoted into the user's blueprint and shows as adopted.
        Initialize-PEBlueprint -Name 'prod' -State (& (Get-Module PolicyEngine) { New-PEState -Records @() -NotChecked @() -Meta @{ TenantId = 't' } }) -DataRoot $script:Temp | Out-Null
        $teams = @((Get-PEBlueprint -Name 'asd' -DataRoot $script:Temp).Records | Where-Object ResourceType -EQ 'TeamsMessagingPolicy')[0]
        Copy-PEStandardItem -Standard 'asd' -To 'prod' -Item ([pscustomobject]@{ ResourceType = $teams.ResourceType; Key = $teams.Key }) -Reason 'adopt' -ExpectedVersion 1 -DataRoot $script:Temp | Should -Be 2
        $adoption = @(Get-PEStandardAdoption -Standard 'asd' -Blueprint 'prod' -DataRoot $script:Temp)
        ($adoption | Where-Object ResourceType -EQ 'TeamsMessagingPolicy').Adopted | Should -BeTrue
        ($adoption | Where-Object ResourceType -EQ 'AADNamedLocationPolicy').Adopted | Should -BeFalse
    }
}
