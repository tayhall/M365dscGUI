BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force

    function New-Group
    {
        param ([string]$Key)
        [pscustomobject]@{
            ResourceType = 'AADGroup'; Key = $Key; Workload = 'Entra ID'; TenantId = 't'
            Properties   = [ordered]@{ DisplayName = $Key; MailNickname = ($Key -replace '[^A-Za-z0-9]', '').ToLowerInvariant(); SecurityEnabled = $true; MailEnabled = $false; Description = "About $Key"; Ensure = 'Present' }
        }
    }

    function New-Blueprint
    {
        param ([string]$Root, [object[]]$Records)
        $state = & (Get-Module PolicyEngine) { param ($r) New-PEState -Records $r -NotChecked @() -Meta @{ TenantId = 'contoso.onmicrosoft.com'; ExportedAt = '2026-10-23T00:00:00Z' } } $Records
        Initialize-PEBlueprint -Name 'main' -State $state -DataRoot $Root | Out-Null
    }
}

Describe 'Invoke-PERoundTrip' {
    BeforeEach {
        $script:Temp = Join-Path ([IO.Path]::GetTempPath()) ('pe-rt-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Temp | Out-Null
    }
    AfterEach { Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'with -RenderOnly builds the configurations, tests nothing and does not write latest.json' {
        New-Blueprint -Root $script:Temp -Records @((New-Group 'Sales'), (New-Group 'Finance'))
        $list = @(Invoke-PERoundTrip -BlueprintName main -RenderOnly -DataRoot $script:Temp)
        $list.Count | Should -Be 1
        $list[0].ResourceType | Should -Be 'AADGroup'
        $list[0].Class | Should -Be 'Rendered'
        Test-Path (Join-Path $script:Temp 'roundtrip\latest.json') | Should -BeFalse
        @(Get-ChildItem (Join-Path $script:Temp 'roundtrip') -Filter '*.json').Count | Should -Be 1
    }

    It 'classifies a type Reliable when the LCM reports every tested instance in its desired state, and records the run' {
        New-Blueprint -Root $script:Temp -Records @((New-Group 'Sales'))
        $test = { param ($a) [pscustomobject]@{ Success = $true; Resources = @([pscustomobject]@{ ResourceId = '[AADGroup]x'; ResourceType = 'AADGroup'; Status = 'InDesiredState' }) } }
        $list = @(Invoke-PERoundTrip -BlueprintName main -TestScript $test -DataRoot $script:Temp)
        $list[0].Class | Should -Be 'Reliable'
        $list[0].Tested | Should -Be 1
        $saved = Get-Content (Join-Path $script:Temp 'roundtrip\latest.json') -Raw | ConvertFrom-Json
        $saved.BlueprintName | Should -Be 'main'
        $saved.Types[0].ResourceType | Should -Be 'AADGroup'
    }

    It 'classifies NeverMatches, Mixed and TestError' {
        New-Blueprint -Root $script:Temp -Records @((New-Group 'Sales'), (New-Group 'Finance'))
        $never = { param ($a) [pscustomobject]@{ Success = $true; Resources = @(1, 2 | ForEach-Object { [pscustomobject]@{ ResourceType = 'AADGroup'; Status = 'WouldChange' } }) } }
        (Invoke-PERoundTrip -BlueprintName main -PerType 2 -TestScript $never -DataRoot $script:Temp)[0].Class | Should -Be 'NeverMatches'
        $mixed = { param ($a) [pscustomobject]@{ Success = $true; Resources = @([pscustomobject]@{ ResourceType = 'AADGroup'; Status = 'InDesiredState' }, [pscustomobject]@{ ResourceType = 'AADGroup'; Status = 'WouldChange' }) } }
        (Invoke-PERoundTrip -BlueprintName main -PerType 2 -TestScript $mixed -DataRoot $script:Temp)[0].Class | Should -Be 'Mixed'
        $failed = { param ($a) [pscustomobject]@{ Success = $false; Error = 'LCM: boom'; Resources = @() } }
        $result = (Invoke-PERoundTrip -BlueprintName main -TestScript $failed -DataRoot $script:Temp)[0]
        $result.Class | Should -Be 'TestError'
        $result.Detail | Should -Be 'LCM: boom'
    }

    It 'tests each workload in a run of its own' {
        $teams = [pscustomobject]@{ ResourceType = 'TeamsMeetingPolicy'; Key = 'Global'; Workload = 'Teams'; TenantId = 't'; Properties = [ordered]@{ Identity = 'Global'; Ensure = 'Present' } }
        New-Blueprint -Root $script:Temp -Records @((New-Group 'Sales'), $teams)
        $script:Runs = [System.Collections.Generic.List[string]]::new()
        $test = { param ($a) $script:Runs.Add((Get-Content -LiteralPath $a.ConfigPath -Raw)); [pscustomobject]@{ Success = $true; Resources = @() } }
        Invoke-PERoundTrip -BlueprintName main -TestScript $test -DataRoot $script:Temp | Out-Null
        $script:Runs.Count | Should -Be 2
        @($script:Runs | Where-Object { $_ -match 'AADGroup' -and $_ -match 'TeamsMeetingPolicy' }).Count | Should -Be 0
    }
    Context 'one bad resource in a run' {
        BeforeEach {
            $records = foreach ($type in 'TeamsMeetingPolicy', 'TeamsMessagingPolicy', 'TeamsCallingPolicy', 'TeamsAppSetupPolicy', 'TeamsEmergencyCallingPolicy') {
                [pscustomobject]@{ ResourceType = $type; Key = 'Global'; Workload = 'Teams'; TenantId = 't'; Properties = [ordered]@{ Identity = 'Global'; Ensure = 'Present' } }
            }
            New-Blueprint -Root $script:Temp -Records @($records)
            $script:Runs = 0
        }

        It 'pins the failure on the one type that causes it and tests the rest' {
            $test = {
                param ($a)
                $script:Runs++
                $text = Get-Content -LiteralPath $a.ConfigPath -Raw
                if ($text -match 'TeamsMessagingPolicy') { return [pscustomobject]@{ Success = $false; Error = 'LCM: boom'; Resources = @() } }
                $types = [regex]::Matches($text, "(?m)^\s+(Teams\w+) '") | ForEach-Object { $_.Groups[1].Value }
                [pscustomobject]@{ Success = $true; Resources = @($types | ForEach-Object { [pscustomobject]@{ ResourceType = $_; Status = 'InDesiredState' } }) }
            }
            $list = @(Invoke-PERoundTrip -BlueprintName main -TestScript $test -DataRoot $script:Temp)
            ($list | Where-Object ResourceType -EQ 'TeamsMessagingPolicy').Class | Should -Be 'TestError'
            ($list | Where-Object ResourceType -EQ 'TeamsMessagingPolicy').Detail | Should -Be 'LCM: boom'
            @($list | Where-Object Class -EQ 'Reliable').Count | Should -Be 4
        }

        It 'does not split further when every half fails with the same error as the whole' {
            $test = { param ($a) $script:Runs++; [pscustomobject]@{ Success = $false; Error = 'LCM: module cannot load'; Resources = @() } }
            $list = @(Invoke-PERoundTrip -BlueprintName main -TestScript $test -DataRoot $script:Temp)
            @($list | Where-Object Class -EQ 'TestError').Count | Should -Be 5
            @($list.Detail | Select-Object -Unique) | Should -Be @('LCM: module cannot load')
            $script:Runs | Should -Be 3
        }
    }
    It 'asks for an elevated session before testing and says so' {
        New-Blueprint -Root $script:Temp -Records @((New-Group 'Sales'))
        Mock -ModuleName PolicyEngine Test-PEElevated { $false }
        { Invoke-PERoundTrip -BlueprintName main -DataRoot $script:Temp } | Should -Throw '*elevated*'
    }

    It 'honours -Type and skips types the engine excludes' {
        New-Blueprint -Root $script:Temp -Records @((New-Group 'Sales'), [pscustomobject]@{ ResourceType = 'EXOMailboxSettings'; Key = 'someone'; Workload = 'Exchange'; TenantId = 't'; Properties = [ordered]@{ Identity = 'someone' } })
        $list = @(Invoke-PERoundTrip -BlueprintName main -RenderOnly -DataRoot $script:Temp)
        $list.ResourceType | Should -Be @('AADGroup')
        @(Invoke-PERoundTrip -BlueprintName main -RenderOnly -Type 'NoSuchType' -DataRoot $script:Temp).Count | Should -Be 0
    }
}
