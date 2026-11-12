BeforeAll {
    $script:Generator = Join-Path $PSScriptRoot '..\pipelines\scripts\New-PipelineYaml.ps1'

    function New-Settings
    {
        param ([hashtable]$Extra = @{}, [string[]]$Without = @())
        $s = [ordered]@{ Pool = 'Agents'; DevServiceConnection = 'sc-dev'; PreProdServiceConnection = 'sc-preprod'
            ExportPreProdPipelineId = '21'; ExportDevPipelineId = '22' }
        foreach ($k in $Extra.Keys) { $s[$k] = $Extra[$k] }
        foreach ($k in $Without) { $s.Remove($k) }
        $lines = $s.GetEnumerator() | ForEach-Object { "    $($_.Key) = '$($_.Value)'" }
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-yaml-' + [guid]::NewGuid().ToString('N') + '.psd1')
        Set-Content $path -Value (@('@{') + $lines + @('}'))
        $path
    }
    function New-Yaml
    {
        param ([string]$Settings)
        $out = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-yaml-out-' + [guid]::NewGuid().ToString('N'))
        & $script:Generator -SettingsPath $Settings -OutputPath $out 6>&1 3>$null | Out-Null
        $out
    }
}

Describe 'pipelines\scripts\New-PipelineYaml.ps1 and the approved-apply pipeline' {
    It 'fills every token of every template, including the approved apply, and leaves none' {
        $out = New-Yaml (New-Settings)
        $names = @(Get-ChildItem $out -Filter *.yaml | ForEach-Object Name)
        $names | Should -Contain 'Apply-Approved-Dev.yaml'
        foreach ($name in $names) { (Get-Content (Join-Path $out $name) -Raw) | Should -Not -Match '__[A-Z][A-Z_]*__' }
    }

    It 'puts the two export pipeline ids, the default branch and the Dev service connection into the approved apply' {
        $text = Get-Content (Join-Path (New-Yaml (New-Settings)) 'Apply-Approved-Dev.yaml') -Raw
        $text | Should -Match "definition: '21'"
        $text | Should -Match "definition: '22'"
        $text | Should -Match "-DefaultBranch 'main'"
        $text | Should -Match "azureSubscription: 'sc-dev'"
        (New-Yaml (New-Settings -Extra @{ DefaultBranch = 'release' }) | ForEach-Object { Get-Content (Join-Path $_ 'Apply-Approved-Dev.yaml') -Raw }) | Should -Match "-DefaultBranch 'release'"
    }

    It 'prefills approvalFile with approvals/approved.json, editable, as a path that starts at the approvals folder' {
        $text = Get-Content (Join-Path (New-Yaml (New-Settings)) 'Apply-Approved-Dev.yaml') -Raw
        $text | Should -Match "(?s)- name: approvalFile\s+displayName: [^\r\n]+\s+type: string\s+default: 'approvals/approved\.json'"
        # the path is joined to the project folder by the script, so the default must not repeat the project folder name
        $text | Should -Not -Match "default: '[^']*M365dscGUI/approvals"
    }

    It 'downloads the two export runs the list names, by run id' {
        $text = Get-Content (Join-Path (New-Yaml (New-Settings)) 'Apply-Approved-Dev.yaml') -Raw
        ([regex]::Matches($text, 'task: DownloadPipelineArtifact@2')).Count | Should -Be 2
        $text | Should -Match "pipelineId: '\`$\(PREPROD_RUN\)'"
        $text | Should -Match "pipelineId: '\`$\(DEV_RUN\)'"
        $text | Should -Match "buildVersionToDownload: 'specific'"
        $text | Should -Match "artifactName: 'PreProdExport'"
        $text | Should -Match "artifactName: 'DevExport'"
    }

    It 'checks the list before anything is downloaded and keeps the free-form path out of the script text' {
        $text = Get-Content (Join-Path (New-Yaml (New-Settings)) 'Apply-Approved-Dev.yaml') -Raw
        $text.IndexOf('Read-ApprovedList.ps1') | Should -BeLessThan $text.IndexOf('DownloadPipelineArtifact@2')
        $text | Should -Match 'PE_APPROVAL_FILE: \$\{\{ parameters.approvalFile \}\}'
        $text | Should -Not -Match "-ListPath '\$\{\{ parameters.approvalFile \}\}'"
    }

    It 'is gated by the environment approval, tests by default, and always removes the certificate' {
        $text = Get-Content (Join-Path (New-Yaml (New-Settings)) 'Apply-Approved-Dev.yaml') -Raw
        $text | Should -Match "environment: 'm365-dev'"
        $text | Should -Match '(?s)name: mode.*?default: Test'
        $text | Should -Match '(?s)Disconnect-PipelineTenant\.ps1.*?condition: always\(\)'
        $text | Should -Match 'ApprovedApplyReport'
    }

    It 'refuses a pipeline id that is not digits' {
        { New-Yaml (New-Settings -Extra @{ ExportDevPipelineId = '22; rm -rf' }) } | Should -Throw '*ExportDevPipelineId*'
    }

    It 'still generates the other pipelines when the new settings are not set, and says what the approved apply needs' {
        $settings = New-Settings -Without 'ExportPreProdPipelineId', 'ExportDevPipelineId'
        $out = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-yaml-out-' + [guid]::NewGuid().ToString('N'))
        { & $script:Generator -SettingsPath $settings -OutputPath $out 6>&1 3>$null | Out-Null } | Should -Throw '*ExportPreProdPipelineId*'
        (Test-Path (Join-Path $out 'Export-Dev.yaml')) | Should -BeTrue
    }

    It 'parses as YAML with the cleanup step last, when a YAML module is available' -Skip:(-not (Get-Module -ListAvailable powershell-yaml)) {
        Import-Module powershell-yaml
        $doc = ConvertFrom-Yaml (Get-Content (Join-Path (New-Yaml (New-Settings)) 'Apply-Approved-Dev.yaml') -Raw)
        $steps = @($doc.jobs[0].strategy.runOnce.deploy.steps)
        $steps[-1].condition | Should -Not -BeNullOrEmpty
    }
}

Describe 'the bump-pins pipeline' {
    It 'fills with no token left and passes its two parameters as environment variables, not in the script text' {
        $text = Get-Content (Join-Path (New-Yaml (New-Settings)) 'Bump-Dsc-Pin.yaml') -Raw
        $text | Should -Not -Match '__[A-Z][A-Z_]*__'
        $text | Should -Match "name: 'M365DSC - Bump DSC pins'"
        $text | Should -Match 'PE_PIN_VERSION: \$\{\{ parameters.version \}\}'
        $text | Should -Match 'PE_PIN_GRAPH_VERSION: \$\{\{ parameters.graphAuthenticationVersion \}\}'
        # The only place the parameters appear is the env block.
        ([regex]::Matches($text, '\$\{\{ parameters\.')).Count | Should -Be 2
        $text | Should -Match 'persistCredentials: true'
        $text | Should -Match 'fetchDepth: 0'
        $text | Should -Match 'Update-DscPin\.ps1.*-CreatePullRequest'
        $text | Should -Match '(?m)^trigger: none'
        $text | Should -Match '(?m)^pr: none'
    }
}

Describe 'the retention step of the approved apply' {
    It 'only runs when applying, so repeated Test runs do not pile up leases' {
        $text = Get-Content (Join-Path (New-Yaml (New-Settings)) 'Apply-Approved-Dev.yaml') -Raw
        $text | Should -Match "(?s)displayName: Keep the two export runs.*?condition: eq\('\$\{\{ parameters.mode \}\}', 'Apply'\)"
    }
}

Describe 'the Tenant-Changes pipeline and the readable export run names' {
    It 'is generated with every token filled and carries the tenant map of the two export pipeline ids' {
        $text = Get-Content (Join-Path (New-Yaml (New-Settings)) 'Tenant-Changes.yaml') -Raw
        $text | Should -Not -Match '__[A-Z][A-Z_]*__'
        $text | Should -Match "PE_TENANT_MAP: 'Dev=22;PreProd=21'"
    }

    It 'is queued by hand, with the tenant and the two optional versions as parameters' {
        $text = Get-Content (Join-Path (New-Yaml (New-Settings)) 'Tenant-Changes.yaml') -Raw
        $text | Should -Match '(?m)^trigger: none'
        $text | Should -Match '(?m)^pr: none'
        $text | Should -Match "(?s)- name: tenant\s+displayName: [^\r\n]+\s+type: string\s+default: Dev\s+values:\s+- Dev\s+- PreProd"
        $text | Should -Match "(?s)- name: exportVersion\s+displayName: [^\r\n]+\s+type: string\s+default: ''"
        $text | Should -Match "(?s)- name: previousVersion\s+displayName: [^\r\n]+\s+type: string\s+default: ''"
    }

    It 'resolves the runs, downloads both by run id from the resolved pipeline, and publishes TenantChanges' {
        $text = Get-Content (Join-Path (New-Yaml (New-Settings)) 'Tenant-Changes.yaml') -Raw
        $text | Should -Match '(?s)Resolve-TenantExports\.ps1.*?-SetVariables'
        $text | Should -Match "definition: '\`$\(DEFINITION_ID\)'"
        $text | Should -Match "pipelineId: '\`$\(LATEST_RUN\)'"
        $text | Should -Match "pipelineId: '\`$\(PREVIOUS_RUN\)'"
        $text | Should -Match "artifactName: '\`$\(ARTIFACT_NAME\)'"
        $text | Should -Match 'Invoke-PipelineTenantChanges\.ps1'
        $text | Should -Match '(?m)^\s+artifact: TenantChanges'
    }

    It 'never puts a resolved value or a parameter inside a command line: they travel as environment variables' {
        $text = Get-Content (Join-Path (New-Yaml (New-Settings)) 'Tenant-Changes.yaml') -Raw
        $commandLines = @($text -split "`n" | Where-Object { $_ -match '\.ps1' })
        $commandLines | Where-Object { $_ -match '\$\((LATEST|PREVIOUS)_(RUN|NAME)\)|parameters\.' } | Should -BeNullOrEmpty
        $text | Should -Match 'PE_LATEST_RUN: \$\(LATEST_RUN\)'
        $text | Should -Match 'SYSTEM_ACCESSTOKEN: \$\(System\.AccessToken\)'
    }

    It 'uses the tenant''s own service connection, chosen when the YAML is compiled' {
        $text = Get-Content (Join-Path (New-Yaml (New-Settings)) 'Tenant-Changes.yaml') -Raw
        $text | Should -Match "(?s)\`$\{\{ if eq\(parameters\.tenant, 'Dev'\) \}\}:\s+azureSubscription: 'sc-dev'\s+\`$\{\{ else \}\}:\s+azureSubscription: 'sc-preprod'"
    }

    It 'needs both export pipeline ids and says so' {
        $settings = New-Settings -Without 'ExportDevPipelineId'
        $out = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-yaml-out-' + [guid]::NewGuid().ToString('N'))
        { & $script:Generator -SettingsPath $settings -OutputPath $out 6>&1 3>$null | Out-Null } | Should -Throw '*Tenant-Changes.yaml*ExportDevPipelineId*'
    }

    It 'names the export runs with a counter, per tenant, so the run list tells them apart' {
        $out = New-Yaml (New-Settings)
        (Get-Content (Join-Path $out 'Export-Dev.yaml') -Raw) | Should -Match "(?m)^name: 'Dev-export-v\`$\(Rev:r\)'"
        (Get-Content (Join-Path $out 'Export-PreProd.yaml') -Raw) | Should -Match "(?m)^name: 'PreProd-export-v\`$\(Rev:r\)'"
    }
}
