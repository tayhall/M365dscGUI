BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..\pipelines\scripts\Get-ApplyResult.ps1'

    function Row
    {
        param ($Action, $Key, $Outcome = 'ToApply', $ConfigurationName = $null, $ResourceId = $null, $Reason = '')
        [pscustomobject]@{ Action = $Action; ResourceType = 'AADGroup'; Key = $Key; Outcome = $Outcome; Reason = $Reason
            ResourceId = $(if ($ResourceId) { $ResourceId } elseif ($Outcome -eq 'ToApply') { "[AADGroup]AADGroup-$Key" } else { $null })
            ConfigurationName = $(if ($ConfigurationName) { $ConfigurationName } elseif ($Outcome -eq 'ToApply') { if ($Action -eq 'Remove') { 'PE_AADGroup_Removals' } else { 'PE_AADGroup_Changes' } } else { $null }) }
    }
    function Cfg
    {
        param ($Name, [string[]]$In = @(), [object[]]$NotIn = @(), $Error = $null, [bool]$Ran = $true)
        [pscustomobject]@{ ConfigurationName = $Name; Ran = $Ran; Error = $Error; InDesiredState = $In; NotInDesiredState = $NotIn }
    }
    function Get-Result { param ($Items, $Cfgs, $Mode = 'Apply', [switch]$IncludeRemovals) & $script:Script -Item $Items -ConfigResult $Cfgs -Mode $Mode -IncludeRemovals:$IncludeRemovals }
}

Describe 'pipelines\scripts\Get-ApplyResult.ps1' {
    It 'marks every item Applied when its configuration is in the desired state' {
        $r = Get-Result @((Row Create 'Finance'), (Row Update 'Sales')) @(Cfg 'PE_AADGroup_Changes' -In @('[AADGroup]AADGroup-Finance', '[AADGroup]AADGroup-Sales'))
        @($r.Items.Outcome | Select-Object -Unique) | Should -Be @('Applied')
        $r.Complete | Should -BeTrue
        $r.Totals.Applied | Should -Be 2
    }

    It 'carries on after a failed resource: the failed one is Failed with the DSC error, the rest Applied' {
        $cfg = Cfg 'PE_AADGroup_Changes' -In @('[AADGroup]AADGroup-Finance') -NotIn @([pscustomobject]@{ ResourceId = '[AADGroup]AADGroup-Sales'; Error = 'Insufficient privileges' })
        $r = Get-Result @((Row Create 'Finance'), (Row Update 'Sales')) @($cfg)
        ($r.Items | Where-Object Key -eq 'Finance').Outcome | Should -Be 'Applied'
        $sales = $r.Items | Where-Object Key -eq 'Sales'
        $sales.Outcome | Should -Be 'Failed'
        $sales.Reason | Should -Be 'Insufficient privileges'
        $r.Complete | Should -BeFalse
        @($r.Left.Key) | Should -Be @('Sales')
    }

    It 'fails every item of a configuration that did not run or returned an error' {
        $r = Get-Result @((Row Create 'Finance')) @(Cfg 'PE_AADGroup_Changes' -Ran $false -Error 'LCM error: boom')
        $r.Items[0].Outcome | Should -Be 'Failed'
        $r.Items[0].Reason | Should -BeLike '*boom*'
        $r2 = Get-Result @((Row Create 'Finance')) @()
        $r2.Items[0].Outcome | Should -Be 'Failed'
    }

    It 'keeps NoActionRequired, Skipped and NotGenerated as they are and counts all five outcomes' {
        $items = @((Row Create 'A' -Outcome NoActionRequired), (Row Create 'B' -Outcome Skipped -Reason 'differs'), (Row Create 'C' -Outcome NotGenerated -Reason 'refused'),
            (Row Create 'Finance'), (Row Update 'Sales'))
        $cfg = Cfg 'PE_AADGroup_Changes' -In @('[AADGroup]AADGroup-Finance') -NotIn @([pscustomobject]@{ ResourceId = '[AADGroup]AADGroup-Sales'; Error = 'x' })
        $r = Get-Result $items @($cfg)
        $r.Totals.NoActionRequired | Should -Be 1
        $r.Totals.Skipped | Should -Be 1
        $r.Totals.NotGenerated | Should -Be 1
        $r.Totals.Applied | Should -Be 1
        $r.Totals.Failed | Should -Be 1
        ($r.Totals.NoActionRequired + $r.Totals.Skipped + $r.Totals.NotGenerated + $r.Totals.Applied + $r.Totals.Failed) | Should -Be $r.Totals.Items
        $r.Complete | Should -BeFalse
        @($r.Left.Key | Sort-Object) | Should -Be @('B', 'C', 'Sales')
    }

    It 'is complete when every item is Applied or NoActionRequired' {
        $r = Get-Result @((Row Create 'A' -Outcome NoActionRequired), (Row Create 'Finance')) @(Cfg 'PE_AADGroup_Changes' -In @('[AADGroup]AADGroup-Finance'))
        $r.Complete | Should -BeTrue
        @($r.Left).Count | Should -Be 0
    }

    It 'skips an approved Remove unless removals were included, and applies it when they were' {
        $items = @((Row Remove 'Marketing'))
        $cfg = Cfg 'PE_AADGroup_Removals' -In @('[AADGroup]AADGroup-Marketing')
        $off = Get-Result $items @($cfg)
        $off.Items[0].Outcome | Should -Be 'Skipped'
        $off.Items[0].Reason | Should -BeLike '*includeRemovals*'
        $on = Get-Result $items @($cfg) -IncludeRemovals
        $on.Items[0].Outcome | Should -Be 'Applied'
    }

    It 'in Test mode leaves the items to apply as ToApply and never says Applied' {
        $r = Get-Result @((Row Create 'Finance'), (Row Create 'A' -Outcome NoActionRequired)) @(Cfg 'PE_AADGroup_Changes' -In @('[AADGroup]AADGroup-Finance')) -Mode Test
        ($r.Items | Where-Object Key -eq 'Finance').Outcome | Should -Be 'ToApply'
        $r.Totals.ToApply | Should -Be 1
        $r.Totals.Applied | Should -Be 0
    }

    It 'treats an item with no resource id as Applied only when its whole configuration is in the desired state' {
        $noId = Row Create 'Finance'
        $noId.ResourceId = $null
        (Get-Result @($noId) @(Cfg 'PE_AADGroup_Changes')).Items[0].Outcome | Should -Be 'Applied'
        $bad = Cfg 'PE_AADGroup_Changes' -NotIn @([pscustomobject]@{ ResourceId = '[AADGroup]AADGroup-Other'; Error = 'e' })
        (Get-Result @($noId) @($bad)).Items[0].Outcome | Should -Be 'Failed'
    }

    It 'fails an item the LCM did not report when the configuration still has resources not in the desired state' {
        $cfg = Cfg 'PE_AADGroup_Changes' -In @('[AADGroup]AADGroup-Other') -NotIn @([pscustomobject]@{ ResourceId = '[AADGroup]AADGroup-Else'; Error = 'e' })
        $r = Get-Result @((Row Create 'Finance')) @($cfg)
        $r.Items[0].Outcome | Should -Be 'Failed'
        $r.Items[0].Reason | Should -BeLike '*did not report*'
    }
}
