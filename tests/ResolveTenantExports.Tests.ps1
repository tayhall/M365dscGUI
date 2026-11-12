BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..\pipelines\scripts\Resolve-TenantExports.ps1'
    $script:Map = 'Dev=22;PreProd=21'

    # Fake Azure DevOps. $global:PEFake.Builds are the completed builds of definition 22 (newest has the highest id); builds listed in
    # $global:PEFake.NoArtifact have lost their artifact to retention; $global:PEFake.Other are builds of another definition.
    function Set-FakeAdo
    {
        param ([object[]]$Builds, [int[]]$NoArtifact = @(), [object[]]$Other = @(), [string]$FailWith = '', [int]$PageSize = 100)
        $global:PEFake = @{ Builds = $Builds; NoArtifact = $NoArtifact; Other = $Other; FailWith = $FailWith; PageSize = $PageSize }
    }
    function New-Build { param ([int]$Id, [string]$Number, [string]$Result = 'succeeded', [int]$Definition = 22) [pscustomobject]@{ id = $Id; buildNumber = $Number; result = $Result; status = 'completed'; definition = [pscustomobject]@{ id = $Definition } } }
    function Resolve-Exports { param ([hashtable]$Arguments = @{}) & $script:Script -Tenant Dev -TenantMap $script:Map @Arguments }
}

Describe 'pipelines\scripts\Resolve-TenantExports.ps1' {
    BeforeEach {
        $env:SYSTEM_COLLECTIONURI = 'https://dev.azure.com/contoso/'
        $env:SYSTEM_TEAMPROJECT = 'M365'
        $env:SYSTEM_ACCESSTOKEN = 'token-not-printed'
        Set-FakeAdo -Builds @(
            (New-Build 130 'Dev-Full-v9'), (New-Build 125 'Dev-Full-v8' 'failed'), (New-Build 120 'Dev-Full-v7'),
            (New-Build 110 'Dev-Full-v6'), (New-Build 90 'M365DSC - Export Dev tenant'))

        Mock Invoke-RestMethod {
            if ($global:PEFake.FailWith) { throw [System.Net.Http.HttpRequestException]::new($global:PEFake.FailWith) }
            if ($Uri -match '/artifacts\?') {
                $id = [int]([regex]::Match($Uri, '/builds/(\d+)/artifacts').Groups[1].Value)
                if ($global:PEFake.NoArtifact -contains $id) { throw [System.Net.Http.HttpRequestException]::new('Response status code does not indicate success: 404 (Not Found).') }
                return [pscustomobject]@{ name = 'DevExport' }
            }
            if ($Uri -match '/builds/(\d+)\?') {
                $id = [int]$Matches[1]
                $found = @($global:PEFake.Builds + $global:PEFake.Other) | Where-Object { $_.id -eq $id }
                if (-not $found) { throw [System.Net.Http.HttpRequestException]::new('Response status code does not indicate success: 404 (Not Found).') }
                return $found
            }
            if ($Uri -match '/builds\?') {
                $skip = 0
                if ($Uri -match 'continuationToken=(\d+)') { $skip = [int]$Matches[1] }
                $all = @($global:PEFake.Builds | Sort-Object { -$_.id })
                $page = @($all | Select-Object -Skip $skip -First $global:PEFake.PageSize)
                if ($ResponseHeadersVariable) {
                    $headers = @{}
                    if ($skip + $page.Count -lt $all.Count) { $headers['x-ms-continuationtoken'] = @([string]($skip + $page.Count)) }
                    Set-Variable -Name $ResponseHeadersVariable -Value $headers -Scope 1
                }
                return [pscustomobject]@{ value = $page; count = $page.Count }
            }
            throw "unexpected uri $Uri"
        }
    }
    AfterAll { Remove-Variable PEFake -Scope Global -ErrorAction SilentlyContinue; Remove-Item Env:SYSTEM_ACCESSTOKEN, Env:SYSTEM_COLLECTIONURI, Env:SYSTEM_TEAMPROJECT -ErrorAction SilentlyContinue }

    It 'blank and blank give the newest successful export and the successful one before it, skipping the failed run' {
        $r = Resolve-Exports
        $r.Latest.RunId | Should -Be '130'
        $r.Latest.Name | Should -Be 'v9'
        $r.Previous.RunId | Should -Be '120'
        $r.Previous.Name | Should -Be 'v7'
        $r.DefinitionId | Should -Be '22'
        $r.ArtifactName | Should -Be 'DevExport'
    }

    It 'skips an export whose artifact retention deleted, for the defaults' {
        Set-FakeAdo -Builds $global:PEFake.Builds -NoArtifact @(130)
        $r = Resolve-Exports
        $r.Latest.RunId | Should -Be '120'
        $r.Previous.RunId | Should -Be '110'
    }

    It 'resolves v-names, and a bare number as a run id, including an old run with no vN in its name' {
        $r = Resolve-Exports @{ ExportVersion = 'v7'; PreviousVersion = '90' }
        $r.Latest.RunId | Should -Be '120'
        $r.Previous.RunId | Should -Be '90'
        $r.Previous.Name | Should -Be 'run 90'
        (Resolve-Exports @{ ExportVersion = '110'; PreviousVersion = '90' }).Latest.Name | Should -Be 'v6'
    }

    It 'does not take v1 for v19 or the other way round' {
        Set-FakeAdo -Builds @((New-Build 200 'Dev-Full-v19'), (New-Build 150 'Dev-Full-v1'), (New-Build 100 'M365DSC - Export Dev tenant'))
        (Resolve-Exports @{ ExportVersion = 'v1'; PreviousVersion = '100' }).Latest.RunId | Should -Be '150'
    }

    It 'uses the successful run just before a named export as the default previous' {
        $r = Resolve-Exports @{ ExportVersion = 'v7' }
        $r.Latest.RunId | Should -Be '120'
        $r.Previous.RunId | Should -Be '110'
    }

    It 'refuses a name that does not exist, naming it' {
        { Resolve-Exports @{ ExportVersion = 'v42' } } | Should -Throw '*v42*'
    }

    It 'refuses an unsuccessful run' {
        { Resolve-Exports @{ ExportVersion = 'v8' } } | Should -Throw '*did not succeed*'
    }

    It 'refuses a run of another pipeline' {
        Set-FakeAdo -Builds $global:PEFake.Builds -Other @(New-Build 777 'PreProd-export-v3' 'succeeded' 21)
        { Resolve-Exports @{ ExportVersion = '777' } } | Should -Throw '*another pipeline*'
    }

    It 'refuses a named run whose artifact is gone' {
        Set-FakeAdo -Builds $global:PEFake.Builds -NoArtifact @(120)
        { Resolve-Exports @{ ExportVersion = 'v7' } } | Should -Throw '*no longer has its artifact*'
    }

    It 'refuses an after that is not newer than the before, and the same run twice' {
        { Resolve-Exports @{ ExportVersion = 'v6'; PreviousVersion = 'v7' } } | Should -Throw '*newer*'
        { Resolve-Exports @{ ExportVersion = 'v7'; PreviousVersion = 'v7' } } | Should -Throw '*same*'
    }

    It 'says to take a fresh export when there is no earlier successful export' {
        Set-FakeAdo -Builds @(New-Build 130 'Dev-Full-v1')
        { Resolve-Exports } | Should -Throw '*no earlier successful export of Dev Full; take a fresh export first*'
    }

    It 'names the View builds permission when Azure DevOps refuses the token' {
        Set-FakeAdo -Builds $global:PEFake.Builds -FailWith 'Response status code does not indicate success: 403 (Forbidden).'
        { Resolve-Exports } | Should -Throw '*View builds*'
    }

    It 'reads past the first page of builds' {
        Set-FakeAdo -Builds $global:PEFake.Builds -PageSize 2
        $r = Resolve-Exports @{ PreviousVersion = '90' }
        $r.Latest.RunId | Should -Be '130'
        $r.Previous.RunId | Should -Be '90'
    }

    It 'writes the six pipeline variables with -SetVariables, and never prints the token' {
        $out = (& $script:Script -Tenant Dev -TenantMap $script:Map -SetVariables 6>&1 | ForEach-Object { "$_" }) -join "`n"
        foreach ($name in 'DEFINITION_ID', 'ARTIFACT_NAME', 'LATEST_RUN', 'PREVIOUS_RUN', 'LATEST_NAME', 'PREVIOUS_NAME')
        {
            $out | Should -Match "##vso\[task\.setvariable variable=$name\]"
        }
        $out | Should -Match '##vso\[task\.setvariable variable=LATEST_RUN\]130'
        $out | Should -Not -Match 'token-not-printed'
    }

    It 'refuses a selected run whose name could inject a logging command, and prints nothing of it' {
        Set-FakeAdo -Builds @((New-Build 140 'Dev-Full-v10]%0D##vso[task.setvariable variable=LATEST_RUN]1'), (New-Build 120 'Dev-Full-v7'))
        # A name outside the plain characters is part of no series, so a default pick never meets it; chosen by its run id it is refused.
        $thrown = $null
        $out = ''
        try { $out = (& $script:Script -Tenant Dev -TenantMap $script:Map -ExportVersion 140 -PreviousVersion 120 -SetVariables 6>&1 | ForEach-Object { "$_" }) -join "`n" } catch { $thrown = $_.Exception.Message }
        $thrown | Should -Match 'run name'
        $out | Should -Not -Match '##vso'
        $thrown | Should -Not -Match '##vso'
    }

    It 'labels runs as vN, or as run <id> for an old run, in the result and in the pipeline variables' {
        $out = (& $script:Script -Tenant Dev -TenantMap $script:Map -ExportVersion 'v7' -PreviousVersion '90' -SetVariables 6>&1 | ForEach-Object { "$_" }) -join "`n"
        $out | Should -Match '##vso\[task\.setvariable variable=LATEST_NAME\]v7'
        $out | Should -Match '##vso\[task\.setvariable variable=PREVIOUS_NAME\]run 90'
        $out | Should -Match 'previous run 90 \(run 90\) -> latest v7 \(run 120\)'
    }

    It 'never puts a run name in a message before it was checked: a failed run, a missing artifact, a bad pair, a default pick' {
        $bad = 'Dev ##vso[task.logissue type=error]-v10'
        $cases = @(
            @{ Builds = @((New-Build 140 $bad 'failed'), (New-Build 120 'Dev-Full-v7')); Arguments = @{ ExportVersion = 'v10' }; NoArtifact = @() },
            @{ Builds = @((New-Build 140 $bad), (New-Build 120 'Dev-Full-v7')); Arguments = @{ ExportVersion = 'v10' }; NoArtifact = @(140) },
            @{ Builds = @((New-Build 140 $bad), (New-Build 120 'Dev-Full-v7')); Arguments = @{ ExportVersion = 'v7'; PreviousVersion = 'v10' }; NoArtifact = @() },
            @{ Builds = @((New-Build 140 $bad)); Arguments = @{}; NoArtifact = @() }
        )
        foreach ($case in $cases)
        {
            Set-FakeAdo -Builds $case.Builds -NoArtifact $case.NoArtifact
            $thrown = $null
            try { Resolve-Exports $case.Arguments | Out-Null } catch { $thrown = $_.Exception.Message }
            $thrown | Should -Not -BeNullOrEmpty
            $thrown | Should -Not -Match '##vso'
        }
    }

    It 'refuses a tenant with no entry in the map, and a bad version' {
        { & $script:Script -Tenant PreProd -TenantMap 'Dev=22' } | Should -Throw '*PreProd*'
        { Resolve-Exports @{ ExportVersion = 'latest;rm' } } | Should -Throw
    }
}

Describe 'pipelines\scripts\Resolve-TenantExports.ps1 per-workload series' {
    BeforeEach {
        $env:SYSTEM_COLLECTIONURI = 'https://dev.azure.com/contoso/'
        $env:SYSTEM_TEAMPROJECT = 'M365'
        $env:SYSTEM_ACCESSTOKEN = 'token-not-printed'
        # Full and AAD runs are interleaved: each series has its own counter and its own newest/previous.
        Set-FakeAdo -Builds @(
            (New-Build 150 'Dev-AAD-v3'), (New-Build 140 'Dev-Full-v9'), (New-Build 135 'Dev-AAD-v2'), (New-Build 130 'Dev-Intune-v1'),
            (New-Build 120 'Dev-Full-v8'), (New-Build 110 'Dev-AAD-v1'), (New-Build 100 'Dev-export-v7'), (New-Build 90 'M365DSC - Export Dev tenant'))
        Mock Invoke-RestMethod {
            if ($Uri -match '/artifacts\?') { return [pscustomobject]@{ name = 'DevExport' } }
            if ($Uri -match '/builds/(\d+)\?') { $id = [int]$Matches[1]; return @($global:PEFake.Builds) | Where-Object { $_.id -eq $id } }
            if ($Uri -match '/builds\?')
            {
                if ($ResponseHeadersVariable) { Set-Variable -Name $ResponseHeadersVariable -Value @{} -Scope 1 }
                return [pscustomobject]@{ value = @($global:PEFake.Builds | Sort-Object { -$_.id }); count = $global:PEFake.Builds.Count }
            }
            throw "unexpected uri $Uri"
        }
    }

    It 'takes the newest and the previous run of the chosen workload only' {
        $aad = Resolve-Exports @{ Workload = 'AAD' }
        $aad.Latest.RunId | Should -Be '150'
        $aad.Latest.Name | Should -Be 'v3'
        $aad.Previous.RunId | Should -Be '135'
        $full = Resolve-Exports @{ Workload = 'Full' }
        $full.Latest.RunId | Should -Be '140'
        $full.Previous.RunId | Should -Be '120'
    }

    It 'defaults to the Full series' {
        (Resolve-Exports).Latest.RunId | Should -Be '140'
    }

    It 'resolves a v-name inside the chosen workload, not across workloads' {
        (Resolve-Exports @{ Workload = 'AAD'; ExportVersion = 'v2' }).Latest.RunId | Should -Be '135'
        (Resolve-Exports @{ Workload = 'Full'; ExportVersion = 'v8'; PreviousVersion = '100' }).Latest.RunId | Should -Be '120'
        { Resolve-Exports @{ Workload = 'Intune'; ExportVersion = 'v2' } } | Should -Throw '*v2*Intune*'
    }

    It 'says which workload has no earlier export' {
        { Resolve-Exports @{ Workload = 'Intune' } } | Should -Throw '*no earlier successful export of Dev Intune*'
    }

    It 'says which workload has no export at all' {
        { Resolve-Exports @{ Workload = 'Teams' } } | Should -Throw '*no successful export of Dev Teams*'
    }

    It 'refuses a numeric run id that belongs to another workload series, and takes an old run with no series name' {
        { Resolve-Exports @{ Workload = 'AAD'; ExportVersion = '140' } } | Should -Throw '*Full*not*AAD*'
        $r = Resolve-Exports @{ Workload = 'Full'; ExportVersion = '140'; PreviousVersion = '90' }
        $r.Previous.RunId | Should -Be '90'
    }

    It 'refuses a workload name that is not a plain word' {
        { Resolve-Exports @{ Workload = 'AAD;rm' } } | Should -Throw
    }

    It 'sets a WORKLOAD pipeline variable with -SetVariables' {
        $out = (& $script:Script -Tenant Dev -TenantMap $script:Map -Workload AAD -SetVariables 6>&1 | ForEach-Object { "$_" }) -join "`n"
        $out | Should -Match '##vso\[task\.setvariable variable=LATEST_RUN\]150'
    }
}
