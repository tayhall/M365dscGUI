BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures'

    function New-ExportFolder
    {
        param ([string]$Content, [string]$Log, [switch]$Bom, [switch]$Crlf)
        $folder = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-int-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        $text = if ($Crlf) { $Content -replace "`r?`n", "`r`n" } else { $Content -replace "`r`n", "`n" }
        $bytes = [System.Text.UTF8Encoding]::new($Bom.IsPresent).GetPreamble() + [System.Text.UTF8Encoding]::new($false).GetBytes($text)
        [System.IO.File]::WriteAllBytes((Join-Path $folder 'export.ps1'), $bytes)
        if ($PSBoundParameters.ContainsKey('Log')) { Set-Content -LiteralPath (Join-Path $folder 'export.log') -Value $Log -Encoding utf8 }
        $folder
    }
    $script:Entra = Get-Content (Join-Path $script:Fixtures 'upload\entra.ps1') -Raw
    $script:GoodLog = Get-Content (Join-Path $script:Fixtures 'export-log-filtered-single.txt') -Raw
}

Describe 'Get-PEExportFingerprint' {
    It 'gives the same fingerprint for CRLF, LF and BOM copies of one export' {
        $lf = New-ExportFolder -Content $script:Entra
        $crlf = New-ExportFolder -Content $script:Entra -Crlf
        $bom = New-ExportFolder -Content $script:Entra -Bom
        $a = Get-PEExportFingerprint -Path $lf
        $a | Should -Match '\A[0-9a-f]{64}\z'
        Get-PEExportFingerprint -Path $crlf | Should -Be $a
        Get-PEExportFingerprint -Path $bom | Should -Be $a
    }

    It 'gives a different fingerprint when one character changes' {
        $one = New-ExportFolder -Content $script:Entra
        $two = New-ExportFolder -Content ($script:Entra + ' ')
        Get-PEExportFingerprint -Path $one | Should -Not -Be (Get-PEExportFingerprint -Path $two)
    }

    It 'is the same for an upload staged by New-PEUploadCheck as for the original folder' {
        $folder = New-ExportFolder -Content $script:Entra -Log $script:GoodLog
        $before = Get-PEExportFingerprint -Path $folder
        $state = New-PEStateFromExport -Path $folder -TenantId 't'
        $state.Meta.ExportFingerprint | Should -Be $before
    }
}

Describe 'Test-PEExportComplete' {
    It 'is complete for a log with no failures' {
        $folder = New-ExportFolder -Content $script:Entra -Log $script:GoodLog
        $r = Test-PEExportComplete -Path $folder
        $r.LogPresent | Should -BeTrue
        $r.Complete | Should -BeTrue
        $r.FailedComponents.Count | Should -Be 0
    }

    It 'is not complete without export.log' {
        $folder = New-ExportFolder -Content $script:Entra
        $r = Test-PEExportComplete -Path $folder
        $r.LogPresent | Should -BeFalse
        $r.Complete | Should -BeFalse
    }

    It 'reports a failed component by name' {
        $log = Get-Content (Join-Path $script:Fixtures 'export-log.txt') -Raw
        $folder = New-ExportFolder -Content $script:Entra -Log $log
        $r = Test-PEExportComplete -Path $folder
        $r.Complete | Should -BeFalse
        $r.FailedComponents | Should -Contain 'EXOFocusedInbox'
    }

    It 'reports a shortfall line' {
        $log = $script:GoodLog + "`nWARNING: [/deviceManagement/x] Graph reported 100 items but only 0 were returned (100% shortfall).`n"
        $folder = New-ExportFolder -Content $script:Entra -Log $log
        $r = Test-PEExportComplete -Path $folder
        $r.Shortfalls.Count | Should -Be 1
        $r.Complete | Should -BeFalse
    }

    It 'ignores a line where all items were returned' {
        $log = $script:GoodLog + "`nWARNING: [/x] Graph reported 5 items but only 5 were returned.`n"
        $folder = New-ExportFolder -Content $script:Entra -Log $log
        (Test-PEExportComplete -Path $folder).Shortfalls.Count | Should -Be 0
    }
}
