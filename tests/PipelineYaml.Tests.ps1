BeforeAll {
    $script:Generator = Join-Path $PSScriptRoot '..\pipelines\scripts\New-PipelineYaml.ps1'

    function New-Settings
    {
        param ([hashtable]$Extra = @{}, [string[]]$Without = @())
        $s = [ordered]@{ Pool = 'Agents'; DevServiceConnection = 'sc-dev'; PreProdServiceConnection = 'sc-preprod' }
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

    It 'finds the two export pipelines by name at run time, and puts the default branch and the Dev service connection into the approved apply' {
        $text = Get-Content (Join-Path (New-Yaml (New-Settings)) 'Apply-Approved-Dev.yaml') -Raw
        $text | Should -Match "(?s)Resolve-ExportPipelineIds\.ps1.*?-PreProdName 'M365DSC - Export PreProd tenant' -DevName 'M365DSC - Export Dev tenant'"
        $text | Should -Match "definition: '\$\(EXPORT_PREPROD_ID\)'"
        $text | Should -Match "definition: '\$\(EXPORT_DEV_ID\)'"
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

    It 'needs no pipeline ids, and ignores them (with a warning) when an old settings file still has them' {
        $out = New-Yaml (New-Settings)
        (Test-Path (Join-Path $out 'Apply-Approved-Dev.yaml')) | Should -BeTrue
        $out2 = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-yaml-out-' + [guid]::NewGuid().ToString('N'))
        $warnings = & $script:Generator -SettingsPath (New-Settings -Extra @{ ExportDevPipelineId = '22'; ExportPreProdPipelineId = '21' }) -OutputPath $out2 6>&1 3>&1 | ForEach-Object { "$_" }
        ($warnings -join "`n") | Should -Match 'ExportDevPipelineId'
        (Get-Content (Join-Path $out2 'Apply-Approved-Dev.yaml') -Raw) | Should -Not -Match "definition: '2[12]'"
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
    It 'is generated with every token filled and builds the tenant map from the export pipeline ids found at run time' {
        $text = Get-Content (Join-Path (New-Yaml (New-Settings)) 'Tenant-Changes.yaml') -Raw
        $text | Should -Not -Match '__[A-Z][A-Z_]*__'
        $text | Should -Match "Resolve-ExportPipelineIds\.ps1"
        $text | Should -Match 'PE_TENANT_MAP: ''\$\(EXPORT_TENANT_MAP\)'''
        $text | Should -Match '(?s)Resolve-ExportPipelineIds\.ps1.*?-Require \$env:PE_REQUIRE'
        $text | Should -Match '(?m)^\s+PE_REQUIRE: \$\{\{ parameters\.tenant \}\}'
    }

    It 'is queued by hand, with the tenant and the two optional versions as parameters' {
        $text = Get-Content (Join-Path (New-Yaml (New-Settings)) 'Tenant-Changes.yaml') -Raw
        $text | Should -Match '(?m)^trigger: none'
        $text | Should -Match '(?m)^pr: none'
        $text | Should -Match "(?s)- name: tenant\s+displayName: [^\r\n]+\s+type: string\s+default: Dev\s+values:\s+- Dev\s+- PreProd"
        $text | Should -Match "(?s)- name: exportVersion\s+displayName: [^\r\n]+\s+type: string\s+default: ''"
        $text | Should -Match "(?s)- name: previousVersion\s+displayName: [^\r\n]+\s+type: string\s+default: ''"
    }

    It 'has a workload picker, Full by default, passed to the resolver and the compare as an environment variable' {
        $text = Get-Content (Join-Path (New-Yaml (New-Settings)) 'Tenant-Changes.yaml') -Raw
        $text | Should -Match "(?s)- name: workload\s+displayName: [^\r\n]+\s+type: string\s+default: Full\s+values:\s+- Full\s+- AAD"
        ([regex]::Matches($text, '(?m)^          PE_WORKLOAD: \$\{\{ parameters\.workload \}\}')).Count | Should -Be 2
        $text | Should -Match '-Workload \$env:PE_WORKLOAD'
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

    It 'names the export runs <Tenant>-<Workload>-v<counter>, so each workload has its own series and counter' {
        $out = New-Yaml (New-Settings)
        (Get-Content (Join-Path $out 'Export-Dev.yaml') -Raw) | Should -Match "(?m)^name: 'Dev-\`$\{\{ parameters\.workload \}\}-v\`$\(Rev:r\)'"
        (Get-Content (Join-Path $out 'Export-PreProd.yaml') -Raw) | Should -Match "(?m)^name: 'PreProd-\`$\{\{ parameters\.workload \}\}-v\`$\(Rev:r\)'"
    }
}

Describe 'the workload picker of the export, Tenant-changes and Compare pipelines' {
    BeforeAll {
        $script:Workloads = (Import-PowerShellDataFile (Join-Path $PSScriptRoot '..\src\PolicyEngine\Data\Workloads.psd1')).Workloads
        function Get-Gen { param ([string]$Dir, [string]$Name) Get-Content (Join-Path $Dir $Name) -Raw }
    }

    It 'the export pipelines have one workload picker: Full first and the default, then every workload of Workloads.psd1' {
        $out = New-Yaml (New-Settings)
        foreach ($file in 'Export-Dev.yaml', 'Export-PreProd.yaml')
        {
            $text = Get-Gen $out $file
            $text | Should -Match "(?s)- name: workload\s+displayName: [^\r\n]+\s+type: string\s+default: Full\s+values:\s+- Full"
            $values = [regex]::Match($text, '(?s)- name: workload.*?values:\r?\n((?:\s+- \w+\r?\n)+)').Groups[1].Value
            @([regex]::Matches($values, '- (\w+)') | ForEach-Object { $_.Groups[1].Value }) | Should -Be (@('Full') + @($script:Workloads | ForEach-Object { $_['Prefix'] }))
            ([regex]::Matches($text, 'type: boolean')).Count | Should -Be 0
        }
    }

    It 'the export pipelines and the compare pipeline pass the picker to the script as PE_WORKLOAD, and the compare pipeline has no boxes' {
        $out = New-Yaml (New-Settings)
        foreach ($file in 'Export-Dev.yaml', 'Export-PreProd.yaml')
        {
            (Get-Gen $out $file) | Should -Match '(?m)^          PE_WORKLOAD: \$\{\{ parameters\.workload \}\}\r?$'
        }
        $text = Get-Gen $out 'Compare-PreProd-to-Dev.yaml'
        $text | Should -Match '(?m)^          PE_WORKLOAD: \$\{\{ parameters\.workload \}\}\r?$'
        $text | Should -Not -Match 'PE_WL_|type: boolean'
    }

    It 'the export pipelines have no workloads text parameter and the compare pipeline no completeWorkloads' {
        $out = New-Yaml (New-Settings)
        foreach ($file in 'Export-Dev.yaml', 'Export-PreProd.yaml')
        {
            (Get-Gen $out $file) | Should -Not -Match 'PE_WORKLOADS|name: workloads|-Workloads|PE_WL_'
        }
        $c = Get-Gen $out 'Compare-PreProd-to-Dev.yaml'
        $c | Should -Not -Match 'completeWorkloads|PE_COMPLETE_WORKLOADS|-CompleteWorkloads'
        $c | Should -Match '(?m)^  - name: mofLayout'
        $c | Should -Match 'PE_FROM_RUN'
    }

    It 'the compare pipeline has the same picker values as the export pipelines and no checkboxes' {
        $c = Get-Gen (New-Yaml (New-Settings)) 'Compare-PreProd-to-Dev.yaml'
        $values = [regex]::Match($c, '(?s)- name: workload.*?values:\r?\n((?:\s+- \w+\r?\n)+)').Groups[1].Value
        @([regex]::Matches($values, '- (\w+)') | ForEach-Object { $_.Groups[1].Value }) | Should -Be (@('Full') + @($script:Workloads | ForEach-Object { $_['Prefix'] }))
        $c | Should -Not -Match 'Complete in the Dev export|type: boolean|PE_WL_'
    }

    It 'a workload added to a temp Workloads.psd1 is a picker value of the export, Tenant-changes and Compare pipelines (and no box appears)' {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-wl-' + [guid]::NewGuid().ToString('N') + '.psd1')
        Set-Content $path -Value @('@{ Workloads = @(', "  @{ Prefix = 'AAD'; Name = 'Entra ID'; Default = `$true }", "  @{ Prefix = 'Zed9'; Name = `"Zed's thing`"; Default = `$false }", ') }')
        $out = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-yaml-out-' + [guid]::NewGuid().ToString('N'))
        & $script:Generator -SettingsPath (New-Settings) -OutputPath $out -WorkloadsPath $path 6>&1 3>$null | Out-Null
        foreach ($file in 'Export-Dev.yaml', 'Export-PreProd.yaml', 'Tenant-Changes.yaml', 'Compare-PreProd-to-Dev.yaml')
        {
            $text = Get-Gen $out $file
            $text | Should -Match '(?m)^      - Zed9\r?$'
            $text | Should -Not -Match 'Intune'
            $text | Should -Not -Match '__[A-Z][A-Z_]*__'
        }
        (Get-Gen $out 'Compare-PreProd-to-Dev.yaml') | Should -Not -Match 'PE_WL_|type: boolean'
    }

    It 'refuses a workload prefix that is not letters and digits' {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-wl-' + [guid]::NewGuid().ToString('N') + '.psd1')
        Set-Content $path -Value @('@{ Workloads = @(', "  @{ Prefix = 'A B'; Name = 'Bad'; Default = `$true }", ') }')
        $out = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-yaml-out-' + [guid]::NewGuid().ToString('N'))
        { & $script:Generator -SettingsPath (New-Settings) -OutputPath $out -WorkloadsPath $path 6>&1 3>$null | Out-Null } | Should -Throw '*Prefix*'
    }

    It 'no parameter value is spliced into the script text: the picker is only in the run name, its own definition and the env block' {
        $out = New-Yaml (New-Settings)
        foreach ($file in 'Export-Dev.yaml', 'Export-PreProd.yaml', 'Tenant-Changes.yaml')
        {
            $uses = @((Get-Gen $out $file) -split '\r?\n' | Where-Object { $_ -match 'parameters\.workload\b' })
            $uses | ForEach-Object { $_ | Should -Match "^(name: |\s+PE_WORKLOAD: )" }
        }
        $uses = @((Get-Gen $out 'Compare-PreProd-to-Dev.yaml') -split '\r?\n' | Where-Object { $_ -match 'parameters\.workload\b' })
        $uses | ForEach-Object { $_ | Should -Match "^(name: |\s+PE_WORKLOAD: )" }
    }
}

Describe 'AzurePowerShellVersion' {
    It 'uses the newest Az on the agent by default, and pins the version when the setting is given' {
        (Get-Content (Join-Path (New-Yaml (New-Settings)) 'Export-Dev.yaml') -Raw) | Should -Match 'azurePowerShellVersion: LatestVersion'
        $text = Get-Content (Join-Path (New-Yaml (New-Settings -Extra @{ AzurePowerShellVersion = '15.2.0' })) 'Export-Dev.yaml') -Raw
        $text | Should -Match "(?s)azurePowerShellVersion: OtherVersion\s+preferredAzurePowerShellVersion: '15\.2\.0'"
        $text | Should -Not -Match 'LatestVersion'
    }
    It 'refuses a value that is not an Az version' {
        { New-Yaml (New-Settings -Extra @{ AzurePowerShellVersion = '5.3.2; x' }) } | Should -Throw '*AzurePowerShellVersion*'
    }
}

Describe 'Prod as a tenant' {
    It 'generates Export-Prod.yaml and offers Prod only when ProdServiceConnection is set' {
        $with = New-Yaml (New-Settings -Extra @{ ProdServiceConnection = 'sc-prod' })
        (Test-Path (Join-Path $with 'Export-Prod.yaml')) | Should -BeTrue
        $tc = Get-Content (Join-Path $with 'Tenant-Changes.yaml') -Raw
        $tc | Should -Match '- Prod'
        $tc | Should -Match "-ProdName 'M365DSC - Export Prod tenant'"
        $without = New-Yaml (New-Settings)
        (Test-Path (Join-Path $without 'Export-Prod.yaml')) | Should -BeFalse
        (Get-Content (Join-Path $without 'Tenant-Changes.yaml') -Raw) | Should -Not -Match '(?<!Pre)Prod'
    }

    It 'Export-Prod publishes the ProdExport artifact using the Prod service connection' {
        $text = Get-Content (Join-Path (New-Yaml (New-Settings -Extra @{ ProdServiceConnection = 'sc-prod' })) 'Export-Prod.yaml') -Raw
        $text | Should -Match "azureSubscription: 'sc-prod'"
        $text | Should -Match 'artifact: ProdExport'
        $text | Should -Match "Prod-\$\{\{ parameters.workload \}\}-v"
        $text | Should -Not -Match '__[A-Z][A-Z_]*__'
    }
}

Describe 'the Compare pipeline with a From and a To picker' {
    BeforeAll {
        $script:C = Get-Content (Join-Path (New-Yaml (New-Settings)) 'Compare-PreProd-to-Dev.yaml') -Raw
        $script:CProd = Get-Content (Join-Path (New-Yaml (New-Settings -Extra @{ ProdServiceConnection = 'sc-prod' })) 'Compare-PreProd-to-Dev.yaml') -Raw
    }

    It 'has from and to pickers: Dev and PreProd, and Prod only when Prod is set up' {
        foreach ($name in 'from', 'to') { $script:C | Should -Match "(?s)  - name: $name\b.*?values:\s+- Dev\s+- PreProd\s+  - name:" }
        foreach ($name in 'from', 'to') { $script:CProd | Should -Match "(?s)  - name: $name\b.*?values:\s+- Dev\s+- PreProd\s+- Prod\s+  - name:" }
        $script:C | Should -Not -Match '(?<!Pre)Prod\b'
    }

    It 'has one workload picker like the export pipelines, and uses it for both exports and the compare' {
        $script:C | Should -Match '(?s)  - name: workload\b.*?default: Full\s+values:\s+- Full\s+- AAD'
        ([regex]::Matches($script:C, '-Workload \$env:PE_WORKLOAD').Count) | Should -Be 3
        $uses = @($script:C -split '\r?\n' | Where-Object { $_ -match 'parameters\.workload\b' })
        $uses | ForEach-Object { $_ | Should -Match '^(name: |\s+PE_WORKLOAD: )' }
        $uses.Count | Should -BeGreaterThan 2
    }

    It 'has the optional versions of both sides, blank for the latest export' {
        foreach ($name in 'fromVersion', 'toVersion') { $script:C | Should -Match "(?s)  - name: $name\b.*?default: ''" }
    }

    It 'requires only the two chosen tenants to have an export pipeline' {
        $script:C | Should -Match '(?s)Resolve-ExportPipelineIds\.ps1.*?-Require \$env:PE_REQUIRE'
        $script:C | Should -Match '(?m)^\s+PE_REQUIRE: \$\{\{ parameters\.from \}\},\$\{\{ parameters\.to \}\}'
        $script:C | Should -Match "PE_TENANT_MAP: '\$\(EXPORT_TENANT_MAP\)'"
        $script:C | Should -Not -Match 'EXPORT_PREPROD_ID|EXPORT_DEV_ID'
    }

    It 'has no pipeline resources and downloads both exports by the ids found at run time' {
        $script:C | Should -Not -Match '(?m)^resources:'
        $script:C | Should -Match "(?s)Resolve-ExportPipelineIds\.ps1.*?-PreProdName 'M365DSC - Export PreProd tenant' -DevName 'M365DSC - Export Dev tenant'"
        $script:C | Should -Match "-NoPrevious -VariablePrefix 'FROM_'"
        $script:C | Should -Match "-NoPrevious -VariablePrefix 'TO_'"
        $script:C | Should -Match "definition: '\$\(FROM_DEFINITION_ID\)'"
        $script:C | Should -Match "pipelineId: '\$\(TO_RUN\)'"
        $script:C | Should -Match "artifactName: '\$\(TO_ARTIFACT_NAME\)'"
    }

    It 'stops before any lookup when both sides are the same tenant' {
        $script:C | Should -Match "(?s)eq\(parameters\.from, parameters\.to\).*?Tenant changes.*?Resolve-ExportPipelineIds"
    }

    It 'chooses the service connection by the target tenant, Prod only when set up' {
        $script:C | Should -Match "(?s)eq\(parameters\.to, 'Dev'\) \}\}:\s+azureSubscription: 'sc-dev'\s+\`$\{\{ else \}\}:\s+azureSubscription: 'sc-preprod'"
        $script:CProd | Should -Match "(?s)eq\(parameters\.to, 'Dev'\) \}\}:\s+azureSubscription: 'sc-dev'\s+\`$\{\{ elseif eq\(parameters\.to, 'Prod'\) \}\}:\s+azureSubscription: 'sc-prod'\s+\`$\{\{ else \}\}:"
    }

    It 'passes the tenants and the run ids through the environment, not into the script text' {
        $script:C | Should -Match '(?m)^\s+PE_FROM: \$\{\{ parameters\.from \}\}'
        $script:C | Should -Match '(?m)^\s+PE_TO: \$\{\{ parameters\.to \}\}'
        $script:C | Should -Match '(?m)^\s+PE_FROM_RUN: \$\(FROM_RUN\)'
        $script:C | Should -Match '-SourceTenant \$env:PE_FROM -TargetTenant \$env:PE_TO'
    }

    It 'still publishes the DriftReport artifact that Apply-Dev reads, and is named for the pair' {
        $script:C | Should -Match 'artifact: DriftReport'
        $script:C | Should -Match "(?m)^name: 'Compare \$\{\{ parameters\.from \}\} to \$\{\{ parameters\.to \}\}"
    }
}
