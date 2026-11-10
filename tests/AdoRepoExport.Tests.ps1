BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    $script:tool = Join-Path $root 'tools\Export-PEAdoRepo.ps1'
    $script:manifest = Import-PowerShellDataFile (Join-Path $root 'pipelines\ado-manifest.psd1')
}

Describe 'ADO manifest' {
    It 'lists only paths that exist' {
        $bad = @(@($manifest.Include) + @($manifest.ModuleFiles) + @($manifest.Tests) | Where-Object { -not (Test-Path (Join-Path $root $_)) })
        $bad | Should -BeNullOrEmpty
    }
    It 'lists no module file twice' {
        $dupes = @($manifest.ModuleFiles | Group-Object | Where-Object Count -gt 1)
        $dupes | Should -BeNullOrEmpty
    }
}

Describe 'Export-PEAdoRepo' {
    BeforeEach { $script:dest = Join-Path ([IO.Path]::GetTempPath()) ("ado-" + [guid]::NewGuid().ToString('N')) }
    AfterEach { Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue }

    It 'copies the manifest and leaves out the GUI and standards data' {
        & $tool -Destination $dest 6>$null
        Test-Path (Join-Path $dest 'pipelines\scripts\Invoke-PipelineExport.ps1') | Should -BeTrue
        Test-Path (Join-Path $dest 'src\PolicyEngine\PolicyEngine.psd1') | Should -BeTrue
        Test-Path (Join-Path $dest 'gui') | Should -BeFalse
        Test-Path (Join-Path $dest 'src\PolicyEngine\Data\StandardSources.psd1') | Should -BeFalse
    }
    It 'never overwrites the destination repo own config, settings or generated YAML' {
        New-Item -ItemType Directory -Force (Join-Path $dest 'pipelines\config') | Out-Null
        Set-Content (Join-Path $dest 'pipelines\config\Dev.psd1') 'mine'
        Set-Content (Join-Path $dest 'pipelines\Export-Dev.yaml') 'mine'
        & $tool -Destination $dest 6>$null
        Get-Content (Join-Path $dest 'pipelines\config\Dev.psd1') | Should -Be 'mine'
        Get-Content (Join-Path $dest 'pipelines\Export-Dev.yaml') | Should -Be 'mine'
    }
    It 'reports stale files and deletes them only with -RemoveStale, never .git' {
        & $tool -Destination $dest 6>$null
        New-Item -ItemType Directory -Force (Join-Path $dest 'tools'), (Join-Path $dest '.git') | Out-Null
        Set-Content (Join-Path $dest 'tools\Old.ps1') 'x'
        Set-Content (Join-Path $dest '.git\HEAD') 'x'
        & $tool -Destination $dest -WarningAction SilentlyContinue 6>$null
        Test-Path (Join-Path $dest 'tools\Old.ps1') | Should -BeTrue
        & $tool -Destination $dest -RemoveStale 6>$null
        Test-Path (Join-Path $dest 'tools\Old.ps1') | Should -BeFalse
        Test-Path (Join-Path $dest '.git\HEAD') | Should -BeTrue
    }
    It 'refuses a destination inside this repo' {
        { & $tool -Destination (Join-Path $root 'data\ado') } | Should -Throw '*inside this repo*'
    }
}
