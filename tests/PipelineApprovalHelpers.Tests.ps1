BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Dir = Join-Path $PSScriptRoot '..\pipelines\scripts'

    function New-Approvals
    {
        $env:PE_TEST_HOOKS = '1'
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-ah-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'approvals') -Force | Out-Null
        $side = { param ($run) @{ Run = $run; ExportedAt = '2026-11-03T10:00:00Z'; Fingerprint = ('a' * 64) } }
        $list = New-PEApprovedList -Tenant 'dev' -ApprovedBy 'andrew' -Source (& $side '4711') -Target (& $side '4712') -ModuleVersion '2.26.1104.1' `
            -Item @(@{ Action = 'Create'; ResourceType = 'AADGroup'; Key = 'Finance'; ExcludedProperties = @() })
        $path = Join-Path $root 'approvals\a.json'
        Save-PEApprovedList -List $list -Path $path
        [pscustomobject]@{ Root = $root; Approvals = (Join-Path $root 'approvals'); List = $path }
    }
}

Describe 'pipelines\scripts\Test-ApprovalLocation.ps1' {
    It 'returns the full path of a list inside the approvals folder on the default branch' {
        $a = New-Approvals
        $env:BUILD_SOURCEBRANCH = 'refs/heads/main'
        (& (Join-Path $script:Dir 'Test-ApprovalLocation.ps1') -ListPath $a.List -ApprovalsRoot $a.Approvals) | Should -Be ([System.IO.Path]::GetFullPath($a.List))
    }

    It 'refuses another branch, naming the branch' {
        $a = New-Approvals
        $env:BUILD_SOURCEBRANCH = 'refs/heads/feature/x'
        { & (Join-Path $script:Dir 'Test-ApprovalLocation.ps1') -ListPath $a.List -ApprovalsRoot $a.Approvals } | Should -Throw '*default branch*feature/x*'
    }

    It 'refuses a list outside the approvals folder, including one that only starts with the same name' {
        $a = New-Approvals
        $env:BUILD_SOURCEBRANCH = 'refs/heads/main'
        $sibling = Join-Path $a.Root 'approvals-evil'
        New-Item -ItemType Directory -Path $sibling | Out-Null
        Copy-Item $a.List (Join-Path $sibling 'a.json')
        { & (Join-Path $script:Dir 'Test-ApprovalLocation.ps1') -ListPath (Join-Path $sibling 'a.json') -ApprovalsRoot $a.Approvals } | Should -Throw '*approvals folder*'
        { & (Join-Path $script:Dir 'Test-ApprovalLocation.ps1') -ListPath (Join-Path $a.Approvals '..\x.json') -ApprovalsRoot $a.Approvals } | Should -Throw '*approvals folder*'
    }

    It 'refuses a list that does not exist' {
        $a = New-Approvals
        $env:BUILD_SOURCEBRANCH = 'refs/heads/main'
        { & (Join-Path $script:Dir 'Test-ApprovalLocation.ps1') -ListPath (Join-Path $a.Approvals 'nope.json') -ApprovalsRoot $a.Approvals } | Should -Throw '*No approved list*'
    }
}

Describe 'pipelines\scripts\Read-ApprovedList.ps1' {
    It 'prints the two export run ids as pipeline variables and a one-line summary' {
        $a = New-Approvals
        $env:BUILD_SOURCEBRANCH = 'refs/heads/main'
        $out = @(& (Join-Path $script:Dir 'Read-ApprovedList.ps1') -ListPath $a.List -ApprovalsRoot $a.Approvals 6>&1 | ForEach-Object { "$_" })
        $out | Should -Contain '##vso[task.setvariable variable=PREPROD_RUN]4711'
        $out | Should -Contain '##vso[task.setvariable variable=DEV_RUN]4712'
        ($out -join "`n") | Should -Match 'Create 1 AADGroup'
    }

    It 'refuses a list that does not pass the format rules' {
        $a = New-Approvals
        $env:BUILD_SOURCEBRANCH = 'refs/heads/main'
        $json = (Get-Content $a.List -Raw | ConvertFrom-Json -DateKind String)
        $json.Items[0] | Add-Member -NotePropertyName Value -NotePropertyValue 'x'
        $bad = Join-Path $a.Approvals 'bad.json'
        [System.IO.File]::WriteAllText($bad, ($json | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
        { & (Join-Path $script:Dir 'Read-ApprovedList.ps1') -ListPath $bad -ApprovalsRoot $a.Approvals } | Should -Throw 'Approved list*'
    }

    It 'refuses another branch before reading the list' {
        $a = New-Approvals
        $env:BUILD_SOURCEBRANCH = 'refs/heads/other'
        { & (Join-Path $script:Dir 'Read-ApprovedList.ps1') -ListPath $a.List -ApprovalsRoot $a.Approvals } | Should -Throw '*default branch*'
    }
}

Describe 'pipelines\scripts\New-ExportRetentionLease.ps1' {
    It 'asks Azure DevOps to keep both export runs, with the pipeline definition of each' {
        $env:SYSTEM_COLLECTIONURI = 'https://dev.azure.com/contoso/'
        $env:SYSTEM_TEAMPROJECT = 'Platform'
        $env:SYSTEM_ACCESSTOKEN = 'token-not-logged'
        $global:PERetentionCalls = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-RestMethod { $global:PERetentionCalls.Add(@{ Uri = $Uri; Body = $Body; Headers = $Headers }) }
        & (Join-Path $script:Dir 'New-ExportRetentionLease.ps1') -PreProdRun 4711 -DevRun 4712 -PreProdDefinitionId 21 -DevDefinitionId 22 -DaysValid 60 6>&1 | Out-Null
        $global:PERetentionCalls.Count | Should -Be 1
        $global:PERetentionCalls[0].Uri | Should -BeLike 'https://dev.azure.com/contoso/Platform/_apis/build/retention/leases?api-version=7.1'
        $body = $global:PERetentionCalls[0].Body | ConvertFrom-Json
        @($body).Count | Should -Be 2
        @($body.runId | Sort-Object) | Should -Be @(4711, 4712)
        @($body | Where-Object runId -EQ 4711).definitionId | Should -Be 21
        @($body | Where-Object runId -EQ 4712).definitionId | Should -Be 22
        $body[0].daysValid | Should -Be 60
        $body[0].protectPipeline | Should -BeFalse
        Remove-Variable -Name PERetentionCalls -Scope Global
    }

    It 'warns and carries on when Azure DevOps refuses (the build identity may lack the permission)' {
        $env:SYSTEM_COLLECTIONURI = 'https://dev.azure.com/contoso/'
        $env:SYSTEM_TEAMPROJECT = 'Platform'
        $env:SYSTEM_ACCESSTOKEN = 'token-not-logged'
        Mock Invoke-RestMethod { throw 'TF400813: not authorized' }
        $out = @(& (Join-Path $script:Dir 'New-ExportRetentionLease.ps1') -PreProdRun 1 -DevRun 2 -PreProdDefinitionId 21 -DevDefinitionId 22 6>&1 | ForEach-Object { "$_" })
        ($out -join "`n") | Should -Match 'task\.logissue type=warning'
        ($out -join "`n") | Should -Not -Match 'token-not-logged'
    }

    It 'refuses a run id or a definition id that is not digits' {
        { & (Join-Path $script:Dir 'New-ExportRetentionLease.ps1') -PreProdRun '12a' -DevRun 2 -PreProdDefinitionId 21 -DevDefinitionId 22 } | Should -Throw
        { & (Join-Path $script:Dir 'New-ExportRetentionLease.ps1') -PreProdRun 1 -DevRun 2 -PreProdDefinitionId 'x' -DevDefinitionId 22 } | Should -Throw
    }
}

Describe 'pipelines\scripts\Test-ApprovalLocation.ps1 test hook' {
    It 'refuses another approvals folder unless test hooks are switched on' {
        $a = New-Approvals
        $env:BUILD_SOURCEBRANCH = 'refs/heads/main'
        $env:PE_TEST_HOOKS = $null
        { & (Join-Path $script:Dir 'Test-ApprovalLocation.ps1') -ListPath $a.List -ApprovalsRoot $a.Approvals } | Should -Throw '*test hook*'
        $env:PE_TEST_HOOKS = '1'
    }
}
