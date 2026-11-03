BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..\pipelines\scripts\Invoke-PipelineApprovedApply.ps1'
    $script:Pwsh = (Get-Command pwsh).Source
    $script:Thumb = '0123456789ABCDEF0123456789ABCDEF01234567'

    # A throwaway world: fake build / LCM / connect / disconnect scripts, a Dev config, an approvals folder and a prepared build output.
    function New-World
    {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-aa-' + [guid]::NewGuid().ToString('N'))
        foreach ($d in 'fakes', 'cfg', 'approvals', 'scenario', 'out') { New-Item -ItemType Directory -Path (Join-Path $root $d) -Force | Out-Null }
        $fakes = Join-Path $root 'fakes'
        Set-Content (Join-Path $fakes 'Build.ps1') -Value @'
param ($ListPath, $SourceExportPath, $TargetExportPath, $TargetTenantDomain, $OutputPath, $MaxAgeDays, $ApplicationId, $CertificateThumbprint, $OrganizationName)
Add-Content $env:PE_FAKE_LOG "build thumb=$CertificateThumbprint app=$ApplicationId"
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
Copy-Item -Path (Join-Path $env:PE_FAKE_BUILD_DIR '*') -Destination $OutputPath -Recurse -Force
'@
        Set-Content (Join-Path $fakes 'Lcm.ps1') -Value @'
param ($MofPath, $Mode)
$dir = Split-Path $MofPath
Add-Content $env:PE_FAKE_LOG ("lcm $Mode " + (Split-Path $dir -Leaf))
Get-Content (Join-Path $dir "lcm-$Mode.json") -Raw
'@
        Set-Content (Join-Path $fakes 'Connect.ps1') -Value @'
param ($Environment, $Role, $ExpectedThumbprint, [switch]$ThumbprintOnly, $ConfigPath)
if ($ThumbprintOnly) { '0123456789ABCDEF0123456789ABCDEF01234567'; return }
Add-Content $env:PE_FAKE_LOG "connect expected=$ExpectedThumbprint"
'@
        Set-Content (Join-Path $fakes 'Disconnect.ps1') -Value @'
param ($Slug, $Role)
Add-Content $env:PE_FAKE_LOG "disconnect $Slug $Role"
'@
        Set-Content (Join-Path $root 'cfg\Dev.psd1') -Value "@{ TenantDomain = 'contoso-dev.onmicrosoft.com'; OrganizationName = 'contoso-dev.onmicrosoft.com'; WriterAppId = '$([guid]::NewGuid())' }"
        Set-Content (Join-Path $root 'approvals\a.json') -Value '{}'
        $env:PE_FAKE_LOG = Join-Path $root 'log.txt'
        $env:PE_FAKE_BUILD_DIR = Join-Path $root 'scenario'
        $env:BUILD_SOURCEBRANCH = 'refs/heads/main'
        [pscustomobject]@{ Root = $root; Out = (Join-Path $root 'out\apply'); Log = $env:PE_FAKE_LOG }
    }

    # outcomes.json, summary.json and one MOF folder per configuration, each with the LCM answers the fake LCM will give.
    function Set-Scenario
    {
        param ($World, [object[]]$Outcomes, [hashtable]$Lcm)
        $s = Join-Path $World.Root 'scenario'
        ConvertTo-Json -InputObject @($Outcomes) -Depth 4 | Set-Content (Join-Path $s 'outcomes.json')
        # Like the real build: only configurations that hold at least one item exist.
        $used = @($Outcomes | ForEach-Object { $_.ConfigurationName })
        $configs = @(
            @{ Name = '01-AADGroup-Changes'; ConfigurationName = 'PE_AADGroup_Changes'; ItemCount = 1 }
            @{ Name = '02-AADGroup-Removals'; ConfigurationName = 'PE_AADGroup_Removals'; ItemCount = 1 }) | Where-Object { $used -contains $_.ConfigurationName }
        [ordered]@{ Totals = @{ Items = @($Outcomes).Count }; Lines = @('Create 1 AADGroup', 'Remove 1 AADGroup'); Configs = $configs } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $s 'summary.json')
        foreach ($c in $configs)
        {
            $dir = Join-Path $s "MOF\$($c.Name)"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content (Join-Path $dir 'localhost.mof') -Value '// fake'
            foreach ($mode in 'Test', 'Apply')
            {
                $answer = $Lcm["$($c.Name)|$mode"]
                if (-not $answer) { $answer = @{ InDesiredState = @(); NotInDesiredState = @() } }
                $answer | ConvertTo-Json -Depth 4 -Compress | Set-Content (Join-Path $dir "lcm-$mode.json")
            }
        }
    }
    function Row { param ($Action, $Key, $Cfg) [ordered]@{ Action = $Action; ResourceType = 'AADGroup'; Key = $Key; Outcome = 'ToApply'; Reason = ''; ResourceId = "[AADGroup]AADGroup-$Key"; ConfigurationName = $Cfg } }

    function Invoke-ApprovedApply
    {
        param ($World, [string]$Mode = 'Test', [string]$IncludeRemovals = 'False', [string]$List)
        if (-not $List) { $List = Join-Path $World.Root 'approvals\a.json' }
        $fakes = Join-Path $World.Root 'fakes'
        $messages = & $script:Script -ListPath $List -PreProdExportPath 'x' -DevExportPath 'y' -OutputPath $World.Out -Mode $Mode -IncludeRemovals $IncludeRemovals `
            -ApprovalsRoot (Join-Path $World.Root 'approvals') -ConfigPath (Join-Path $World.Root 'cfg') `
            -BuildScript (Join-Path $fakes 'Build.ps1') -LcmScript (Join-Path $fakes 'Lcm.ps1') -LcmHost $script:Pwsh `
            -ConnectScript (Join-Path $fakes 'Connect.ps1') -DisconnectScript (Join-Path $fakes 'Disconnect.ps1') 6>&1 3>$null
        @($messages | ForEach-Object { "$_" })
    }
    function Get-Log { param ($World) if (Test-Path $World.Log) { @(Get-Content $World.Log) } else { @() } }
}

Describe 'pipelines\scripts\Invoke-PipelineApprovedApply.ps1 guards' {
    It 'stops before any tenant access when the run is not on the default branch (G9)' {
        $w = New-World
        Set-Scenario $w @((Row Create 'Finance' 'PE_AADGroup_Changes')) @{}
        $env:BUILD_SOURCEBRANCH = 'refs/heads/feature/x'
        { Invoke-ApprovedApply $w } | Should -Throw '*default branch*'
        @(Get-Log $w).Count | Should -Be 0
    }

    It 'stops when the list is outside the approvals folder (G9)' {
        $w = New-World
        Set-Scenario $w @((Row Create 'Finance' 'PE_AADGroup_Changes')) @{}
        $elsewhere = Join-Path $w.Root 'cfg\Dev.psd1'
        { Invoke-ApprovedApply $w -List $elsewhere } | Should -Throw '*approvals*'
        @(Get-Log $w).Count | Should -Be 0
    }

    It 'refuses an unknown mode' {
        $w = New-World
        { Invoke-ApprovedApply $w -Mode 'Destroy' } | Should -Throw
    }

    It 'compiles with Dev''s Writer app and the thumbprint taken from the certificate, and always disconnects' {
        $w = New-World
        Set-Scenario $w @((Row Create 'Finance' 'PE_AADGroup_Changes')) @{}
        Invoke-ApprovedApply $w | Out-Null
        $log = Get-Log $w
        ($log | Where-Object { $_ -like 'build thumb=0123456789ABCDEF0123456789ABCDEF01234567 app=*' }).Count | Should -Be 1
        $log[-1] | Should -Be 'disconnect dev Writer'
    }

    It 'disconnects even when the LCM fails, and reports the item as Failed' {
        $w = New-World
        Set-Scenario $w @((Row Create 'Finance' 'PE_AADGroup_Changes')) @{ '01-AADGroup-Changes|Apply' = @{ Error = 'LCM exploded'; InDesiredState = @(); NotInDesiredState = @() } }
        Invoke-ApprovedApply $w -Mode Apply | Out-Null
        (Get-Log $w)[-1] | Should -Be 'disconnect dev Writer'
        $result = Get-Content (Join-Path $w.Out 'result.json') -Raw | ConvertFrom-Json
        $result.Items[0].Outcome | Should -Be 'Failed'
        $result.Items[0].Reason | Should -BeLike '*LCM exploded*'
    }
}

Describe 'pipelines\scripts\Invoke-PipelineApprovedApply.ps1 test and apply' {
    It 'in Test mode runs only the LCM test of the Changes (removals not asked for), never an apply, and does not fail the step' {
        $w = New-World
        Set-Scenario $w @((Row Create 'Finance' 'PE_AADGroup_Changes'), (Row Remove 'Marketing' 'PE_AADGroup_Removals')) @{}
        $messages = Invoke-ApprovedApply $w
        $log = Get-Log $w
        $log | Should -Contain 'lcm Test 01-AADGroup-Changes'
        $log | Should -Not -Contain 'lcm Test 02-AADGroup-Removals'
        ($log | Where-Object { $_ -like 'lcm Apply*' }).Count | Should -Be 0
        ($messages -join "`n") | Should -Not -Match 'task.complete'
        ($messages -join "`n") | Should -Match 'Create 1 AADGroup'
        $result = Get-Content (Join-Path $w.Out 'result.json') -Raw | ConvertFrom-Json
        $result.Mode | Should -Be 'Test'
        ($result.Items | Where-Object Key -eq 'Finance').Outcome | Should -Be 'ToApply'
    }

    It 'runs every LCM test before the first apply' {
        $w = New-World
        Set-Scenario $w @((Row Create 'Finance' 'PE_AADGroup_Changes'), (Row Remove 'Marketing' 'PE_AADGroup_Removals')) @{
            '01-AADGroup-Changes|Apply' = @{ InDesiredState = @('[AADGroup]AADGroup-Finance'); NotInDesiredState = @() }
            '02-AADGroup-Removals|Apply' = @{ InDesiredState = @('[AADGroup]AADGroup-Marketing'); NotInDesiredState = @() } }
        Invoke-ApprovedApply $w -Mode Apply -IncludeRemovals 'True' | Out-Null
        $log = @(Get-Log $w | Where-Object { $_ -like 'lcm *' })
        $log | Should -Be @('lcm Test 01-AADGroup-Changes', 'lcm Test 02-AADGroup-Removals', 'lcm Apply 01-AADGroup-Changes', 'lcm Apply 02-AADGroup-Removals')
    }

    It 'ends green when every item is Applied' {
        $w = New-World
        Set-Scenario $w @((Row Create 'Finance' 'PE_AADGroup_Changes')) @{ '01-AADGroup-Changes|Apply' = @{ InDesiredState = @('[AADGroup]AADGroup-Finance'); NotInDesiredState = @() } }
        $messages = Invoke-ApprovedApply $w -Mode Apply
        ($messages -join "`n") | Should -Not -Match 'SucceededWithIssues'
        (Get-Content (Join-Path $w.Out 'result.json') -Raw | ConvertFrom-Json).Complete | Should -BeTrue
    }

    It 'finishes with issues, lists what is left and carries on after a failed resource' {
        $w = New-World
        Set-Scenario $w @((Row Create 'Finance' 'PE_AADGroup_Changes'), (Row Remove 'Marketing' 'PE_AADGroup_Removals')) @{
            '01-AADGroup-Changes|Apply' = @{ InDesiredState = @(); NotInDesiredState = @(@{ ResourceId = '[AADGroup]AADGroup-Finance'; Error = 'Insufficient privileges' }) }
            '02-AADGroup-Removals|Apply' = @{ InDesiredState = @('[AADGroup]AADGroup-Marketing'); NotInDesiredState = @() } }
        $messages = Invoke-ApprovedApply $w -Mode Apply -IncludeRemovals 'True'
        ($messages -join "`n") | Should -Match 'task\.complete result=SucceededWithIssues'
        ($messages -join "`n") | Should -Match 'Insufficient privileges'
        (Get-Log $w) | Should -Contain 'lcm Apply 02-AADGroup-Removals'
        $result = Get-Content (Join-Path $w.Out 'result.json') -Raw | ConvertFrom-Json
        ($result.Items | Where-Object Key -eq 'Finance').Outcome | Should -Be 'Failed'
        ($result.Items | Where-Object Key -eq 'Marketing').Outcome | Should -Be 'Applied'
        $total = $result.Totals.Applied + $result.Totals.NoActionRequired + $result.Totals.NotGenerated + $result.Totals.Failed + $result.Totals.Skipped
        $total | Should -Be $result.Totals.Items
    }

    It 'leaves an approved Remove Skipped, and ends with issues, when removals were not included' {
        $w = New-World
        Set-Scenario $w @((Row Remove 'Marketing' 'PE_AADGroup_Removals')) @{}
        $messages = Invoke-ApprovedApply $w -Mode Apply
        ($messages -join "`n") | Should -Match 'SucceededWithIssues'
        (Get-Log $w | Where-Object { $_ -like 'lcm Apply*' }).Count | Should -Be 0
        (Get-Content (Join-Path $w.Out 'result.json') -Raw | ConvertFrom-Json).Items[0].Outcome | Should -Be 'Skipped'
    }
}
