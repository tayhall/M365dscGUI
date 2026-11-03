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

Describe 'the retention step of the approved apply' {
    It 'only runs when applying, so repeated Test runs do not pile up leases' {
        $text = Get-Content (Join-Path (New-Yaml (New-Settings)) 'Apply-Approved-Dev.yaml') -Raw
        $text | Should -Match "(?s)displayName: Keep the two export runs.*?condition: eq\('\$\{\{ parameters.mode \}\}', 'Apply'\)"
    }
}
