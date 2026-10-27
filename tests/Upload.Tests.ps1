BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Dir = Join-Path $PSScriptRoot 'fixtures\upload'

    function Get-UploadFile
    {
        param ([string[]]$Name)
        foreach ($n in $Name) { [pscustomobject]@{ Name = $n; Text = Get-Content -LiteralPath (Join-Path $script:Dir $n) -Raw } }
    }
}

Describe 'Get-PEExportFileVersion' {
    It 'reads the version from the generated header' {
        $text = (Get-UploadFile 'entra.ps1').Text
        & (Get-Module PolicyEngine) { Get-PEExportFileVersion -Text $args[0] } $text | Should -Be '2.26.1021.1'
    }

    It 'throws when the generated line is missing' {
        $text = (Get-UploadFile 'entra.ps1').Text -replace '(?m)^# Generated with.*\r?\n', ''
        { & (Get-Module PolicyEngine) { Get-PEExportFileVersion -Text $args[0] } $text } | Should -Throw '*Generated with Microsoft365DSC*'
    }

    It 'throws when the header and the Import-DscResource version disagree' {
        $text = (Get-UploadFile 'entra.ps1').Text -replace "-ModuleVersion '2.26.1021.1'", "-ModuleVersion '2.26.1.1'"
        { & (Get-Module PolicyEngine) { Get-PEExportFileVersion -Text $args[0] } $text } | Should -Throw '*2.26.1.1*'
    }
}

Describe 'Get-PEExportFileVersion (first line, BOM)' {
    It 'accepts a leading byte order mark with CRLF text' {
        $text = [string][char]0xFEFF + ((Get-UploadFile 'entra.ps1').Text -replace "`r?`n", "`r`n")
        & (Get-Module PolicyEngine) { Get-PEExportFileVersion -Text $args[0] } $text | Should -Be '2.26.1021.1'
    }

    It 'refuses a header that is not on the first line' {
        $text = "# some note`n" + (Get-UploadFile 'entra.ps1').Text
        { & (Get-Module PolicyEngine) { Get-PEExportFileVersion -Text $args[0] } $text } | Should -Throw '*first line*'
    }
}

Describe 'Assert-PEUploadVersion' {
    It 'names every offending file, also one without a header' {
        $good = Get-UploadFile 'entra.ps1'
        $other = Get-UploadFile 'other-version.ps1'
        $bad = [pscustomobject]@{ Name = 'noheader.ps1'; Text = ($good.Text -replace '(?m)^# Generated with.*\r?\n', '') }
        $message = $null
        try { & (Get-Module PolicyEngine) { Assert-PEUploadVersion -File $args[0] } @($bad, $other, $good) } catch { $message = $_.Exception.Message }
        $message | Should -BeLike '*noheader.ps1: *'
        $message | Should -BeLike '*other-version.ps1 was exported with Microsoft365DSC 1.26.422.1*'
        $message | Should -Not -BeLike '*entra.ps1*'
    }

    It 'accepts files exported with the pinned version' {
        $files = @(Get-UploadFile 'entra.ps1', 'exchange.ps1')
        { & (Get-Module PolicyEngine) { Assert-PEUploadVersion -File $args[0] } $files } | Should -Not -Throw
    }

    It 'names the file and both versions for another version' {
        $files = @(Get-UploadFile 'entra.ps1', 'other-version.ps1')
        $message = $null
        try { & (Get-Module PolicyEngine) { Assert-PEUploadVersion -File $args[0] } $files } catch { $message = $_.Exception.Message }
        $message | Should -Be 'other-version.ps1 was exported with Microsoft365DSC 1.26.422.1, but this installation is pinned to 2.26.1021.1. Export again with 2.26.1021.1.'
    }
}

Describe 'Write-PEUploadStage' {
    BeforeEach { $script:Stage = Join-Path $TestDrive ('stage-' + [guid]::NewGuid().ToString('N')) }

    It 'writes the files as one export that holds the resources of both, without an export.log' {
        $files = @(Get-UploadFile 'entra.ps1', 'exchange.ps1')
        $warnings = @(& (Get-Module PolicyEngine) { Write-PEUploadStage -File $args[0] -Path $args[1] } $files $script:Stage)
        $warnings.Count | Should -Be 0
        Test-Path (Join-Path $script:Stage 'export.log') | Should -BeFalse
        $records = @(& (Get-Module PolicyEngine) { Read-PEExport -Path (Join-Path $args[0] 'export.ps1') } $script:Stage)
        $records.Count | Should -Be 3
        ($records.ResourceType | Sort-Object -Unique) | Should -Be @('AADGroup', 'EXOAcceptedDomain')
        $workloads = @($records | ForEach-Object { & (Get-Module PolicyEngine) { Get-PEWorkload -ResourceType $args[0] } $_.ResourceType } | Sort-Object -Unique)
        $workloads.Count | Should -Be 2
        @(Get-ChildItem (Split-Path -Parent $script:Stage) -Directory -Filter 'upload-part-*').Count | Should -Be 0
    }

    It 'warns once for an instance that is in more than one file and keeps both blocks out of silent loss' {
        $files = @(Get-UploadFile 'entra.ps1', 'other-version.ps1')
        $warnings = @(& (Get-Module PolicyEngine) { Write-PEUploadStage -File $args[0] -Path $args[1] } $files $script:Stage)
        $warnings.Count | Should -Be 2
        $warnings[0] | Should -BeLike '*AADGroup*AADGroup-Sales*'
    }
}

Describe 'Write-PEUploadStage (checks)' {
    BeforeEach { $script:Stage = Join-Path $TestDrive ('stage-' + [guid]::NewGuid().ToString('N')) }

    It 'warns for the same instance in two files with the same name, saying the later file''s record is kept' {
        $one = Get-UploadFile 'exchange.ps1'
        $files = @($one, [pscustomobject]@{ Name = $one.Name; Text = $one.Text })
        $warnings = @(& (Get-Module PolicyEngine) { Write-PEUploadStage -File $args[0] -Path $args[1] } $files $script:Stage)
        $warnings.Count | Should -Be 1
        $warnings[0] | Should -BeLike "*file 1*file 2*same type and key count once*later file's one is kept*"
    }

    It 'stages a file that starts with a byte order mark and CRLF' {
        $good = Get-UploadFile 'entra.ps1'
        $files = @([pscustomobject]@{ Name = 'bom.ps1'; Text = [string][char]0xFEFF + ($good.Text -replace "`r?`n", "`r`n") }, (Get-UploadFile 'exchange.ps1'))
        & (Get-Module PolicyEngine) { Write-PEUploadStage -File $args[0] -Path $args[1] } $files $script:Stage | Out-Null
        (Get-Content -LiteralPath (Join-Path $script:Stage 'export.ps1') -Raw).Contains([string][char]0xFEFF) | Should -BeFalse
        @(& (Get-Module PolicyEngine) { Read-PEExport -Path (Join-Path $args[0] 'export.ps1') } $script:Stage).Count | Should -Be 3
    }

    It 'refuses a single file without a Node block, naming the file' {
        $files = @([pscustomobject]@{ Name = 'junk.ps1'; Text = 'not an export' })
        { & (Get-Module PolicyEngine) { Write-PEUploadStage -File $args[0] -Path $args[1] } $files $script:Stage } | Should -Throw '*junk.ps1*'
    }

    It 'refuses a file with an empty Node block, naming the file' {
        $empty = [pscustomobject]@{ Name = 'empty.ps1'; Text = ((Get-UploadFile 'entra.ps1').Text -replace '(?s)(Node localhost\r?\n    \{\r?\n).*?(\r?\n    \}\r?\n\})', '$1$2') }
        $files = @((Get-UploadFile 'exchange.ps1'), $empty)
        { & (Get-Module PolicyEngine) { Write-PEUploadStage -File $args[0] -Path $args[1] } $files $script:Stage } | Should -Throw '*empty.ps1*'
    }
}
