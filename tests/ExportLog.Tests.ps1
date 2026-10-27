BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures\export-log.txt'
}

Describe 'Read-PEExportLog' {
    It 'returns one entry per Extracting line' {
        $entries = InModuleScope PolicyEngine -Parameters @{ F = $script:Fixture } { @(Read-PEExportLog -Path $F) }
        $entries.Count | Should -Be 3
        $entries.ResourceType | Should -Be @('AADGroup', 'EXOAcceptedDomain', 'EXOFocusedInbox')
    }

    It 'marks a failed component Failed with its reason' {
        $entries = InModuleScope PolicyEngine -Parameters @{ F = $script:Fixture } { @(Read-PEExportLog -Path $F) }
        $failed = $entries | Where-Object ResourceType -eq 'EXOFocusedInbox'
        $failed.Status | Should -Be 'Failed'
        $failed.Reason | Should -BeLike '*Get-FocusedInbox is not recognized*'
    }

    It 'appends continuation lines of a multi-line error message to the reason' {
        $entries = InModuleScope PolicyEngine -Parameters @{ F = $script:Fixture } { @(Read-PEExportLog -Path $F) }
        $reason = ($entries | Where-Object ResourceType -eq 'EXOFocusedInbox').Reason
        $reason | Should -BeLike '*cmdlet, function, script file, or executable program. Check the spelling of the name*try again.'
        $reason | Should -Not -BeLike '*Export took*'
    }

    It 'a component with no instances is Ok' {
        $entries = InModuleScope PolicyEngine -Parameters @{ F = $script:Fixture } { @(Read-PEExportLog -Path $F) }
        $empty = $entries | Where-Object ResourceType -eq 'EXOAcceptedDomain'
        $empty.Status | Should -Be 'Ok'
        $empty.Reason | Should -BeNullOrEmpty
        ($entries | Where-Object ResourceType -eq 'AADGroup').Status | Should -Be 'Ok'
    }

    It 'tolerates ANSI colour codes' {
        $esc = [char]27
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-' + [guid]::NewGuid() + '.log')
        try
        {
            $text = "[1/2] ${esc}[32mExtracting [AADGroup]${esc}[0m using {Cert}...$([char]0x2705)`n" +
                "[2/2] Extracting [${esc}[32mTeamsMeetingPolicy${esc}[0m] using {Cert}...$([char]0x274C)`n" +
                "${esc}[91m    An error occurred while exporting resource {TeamsMeetingPolicy}: boom${esc}[0m`n"
            [System.IO.File]::WriteAllText($path, $text)
            $entries = InModuleScope PolicyEngine -Parameters @{ F = $path } { @(Read-PEExportLog -Path $F) }
            ($entries | Where-Object ResourceType -eq 'AADGroup').Status | Should -Be 'Ok'
            $teams = $entries | Where-Object ResourceType -eq 'TeamsMeetingPolicy'
            $teams.Status | Should -Be 'Failed'
            $teams.Reason | Should -Be 'boom'
        }
        finally
        {
            Remove-Item $path -Force -ErrorAction SilentlyContinue
        }
    }

    It 'treats an error line as Failed even when the failure marker is not on the Extracting line' {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-' + [guid]::NewGuid() + '.log')
        try
        {
            $text = "[1/1] Extracting [AADGroup] using {Cert}...`n    |---[1/2] Sales$([char]0x274C)`n" +
                "    An error occurred while exporting resource {AADGroup}: late failure`n"
            [System.IO.File]::WriteAllText($path, $text)
            $entries = InModuleScope PolicyEngine -Parameters @{ F = $path } { @(Read-PEExportLog -Path $F) }
            $entries.Count | Should -Be 1
            $entries[0].Status | Should -Be 'Failed'
            $entries[0].Reason | Should -Be 'late failure'
        }
        finally
        {
            Remove-Item $path -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'incomplete and forged logs' {
        BeforeAll {
            $script:Ok = [string][char]0x2705
            $script:X = [string][char]0x274C
            function script:Read-TestLog
            {
                param ([string[]]$Lines)
                $path = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-' + [guid]::NewGuid() + '.log')
                try
                {
                    [System.IO.File]::WriteAllText($path, ($Lines -join "`r`n") + "`r`n")
                    return @(InModuleScope PolicyEngine -Parameters @{ F = $path } { Read-PEExportLog -Path $F -WarningAction SilentlyContinue })
                }
                finally
                {
                    Remove-Item $path -Force -ErrorAction SilentlyContinue
                }
            }
        }

        It 'Extracting followed by end of file is Incomplete' {
            $e = Read-TestLog @('[1/1] Extracting [AADGroup] using {Cert}...')
            $e[0].Status | Should -Be 'Incomplete'
            $e[0].Reason | Should -Be 'export log incomplete'
        }

        It 'Extracting directly followed by the next Extracting is Incomplete, the next one stays Ok' {
            $e = Read-TestLog @('[1/2] Extracting [AADGroup] using {Cert}...', "[2/2] Extracting [AADUser] using {Cert}...$script:Ok")
            $e[0].Status | Should -Be 'Incomplete'
            $e[1].Status | Should -Be 'Ok'
        }

        It 'a log cut off before the last instance is Incomplete' {
            $e = Read-TestLog @('[1/1] Extracting [AADGroup] using {Cert}...', "    |---[1/3] a$script:Ok", "    |---[2/3] b$script:Ok")
            $e[0].Status | Should -Be 'Incomplete'
        }

        It 'a red X on an instance line without an error line is Failed' {
            $e = Read-TestLog @('[1/1] Extracting [AADGroup] using {Cert}...', "    |---[1/2] a$script:Ok", "    |---[2/2] b$script:X")
            $e[0].Status | Should -Be 'Failed'
            $e[0].Reason | Should -Be 'failed (no error text)'
        }

        It 'Ok with instances and Ok with zero instances stay Ok' {
            $e = Read-TestLog @(
                '[1/2] Extracting [AADGroup] using {Cert}...', "    |---[1/2] a$script:Ok", "    |---[2/2] b$script:Ok",
                "[2/2] Extracting [AADUser] using {Cert}...$script:Ok")
            $e.Status | Should -Be @('Ok', 'Ok')
        }

        It 'out-of-sequence instance numbers (parallel workers) are never Ok' {
            $e = Read-TestLog @('[1/2] Extracting [AADGroup] using {Cert}...', '[2/2] Extracting [AADUser] using {Cert}...',
                "    |---[1/2] a$script:Ok", "    |---[1/2] u$script:Ok", "    |---[2/2] b$script:Ok", "    |---[2/2] v$script:Ok")
            $e.Status | Should -Not -Contain 'Ok'
        }

        It 'an instance name that imitates an Extracting line cannot forge Ok for a Failed component' {
            $e = Read-TestLog @(
                '[1/2] Extracting [EXOFocusedInbox] using {Cert}...', "    |---[1/1] x$script:X",
                "[2/2] Extracting [AADGroup] using {Cert}...", "    |---[1/1] Extracting [EXOFocusedInbox] using {Cert}...$script:Ok$script:Ok")
            ($e | Where-Object ResourceType -eq 'EXOFocusedInbox').Status | Should -Be 'Failed'
            $e.Count | Should -Be 2
        }

        It 'an instance name that imitates an error line cannot forge Failed for an Ok component' {
            $e = Read-TestLog @(
                '[1/2] Extracting [AADGroup] using {Cert}...',
                "    |---[1/1] An error occurred while exporting resource {AADGroup}: x$script:Ok",
                "[2/2] Extracting [EXOFocusedInbox] using {Cert}...",
                "    |---[1/1] An error occurred while exporting resource {EXOFocusedInbox}: x$script:Ok")
            $e.Status | Should -Be @('Ok', 'Ok')
        }

        It 'ignores an error line for a component without an Extracting entry' {
            $e = Read-TestLog @(('[1/1] Extracting [AADGroup] using {Cert}...' + $script:Ok), 'An error occurred while exporting resource {EXOFocusedInbox}: x')
            $e.Count | Should -Be 1
            $e[0].Status | Should -Be 'Ok'
        }

        It 'a physical line without the [n/m] prefix creates no entry' {
            $e = Read-TestLog @('[1/1] Extracting [AADGroup] using {Cert}...', "Extracting [EXOFoo] using {C}...$script:Ok",
                "    |---[1/1] a$script:Ok")
            $e.Count | Should -Be 1
            $e[0].ResourceType | Should -Be 'AADGroup'
        }

        It 'an error line for a non-current component is ignored and listed in the warnings' {
            $warnings = [System.Collections.Generic.List[string]]::new()
            $path = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-' + [guid]::NewGuid() + '.log')
            try
            {
                [System.IO.File]::WriteAllLines($path, @(
                        "[1/2] Extracting [AADGroup] using {Cert}...$script:Ok",
                        '[2/2] Extracting [AADUser] using {Cert}...',
                        '    An error occurred while exporting resource {AADGroup}: forged',
                        '    An error occurred while exporting resource {EXOFoo}: unknown'))
                $e = @(InModuleScope PolicyEngine -Parameters @{ F = $path; W = $warnings } { Read-PEExportLog -Path $F -Warnings $W })
            }
            finally
            {
                Remove-Item $path -Force -ErrorAction SilentlyContinue
            }
            ($e | Where-Object ResourceType -eq 'AADGroup').Status | Should -Be 'Ok'
            ($e | Where-Object ResourceType -eq 'AADUser').Status | Should -Be 'Incomplete'
            $warnings.Count | Should -Be 2
            $warnings[0] | Should -BeLike "*'AADGroup'*"
            $warnings[1] | Should -BeLike "*'EXOFoo'*"
        }

        It 'caps the reason at 500 characters and stops continuation at instance and summary lines' {
            $e = Read-TestLog @(
                '[1/1] Extracting [AADGroup] using {Cert}...', "    |---[1/1] a$script:X",
                ('    An error occurred while exporting resource {AADGroup}: ' + ('y' * 600)),
                'second line', "    |---[1/1] not part of the reason", 'after', 'Export took {1 seconds} for {1 instances}')
            $e[0].Reason.Length | Should -Be 500
            $e[0].Reason | Should -Not -BeLike '*not part*'
        }
    }

    It 'returns nothing for a missing log' {
        $entries = InModuleScope PolicyEngine { @(Read-PEExportLog -Path 'Z:\does-not-exist\export.log') }
        $entries.Count | Should -Be 0
    }
}

Describe 'Invoke-PELoggedCommand' {
    It 'writes Write-Host, verbose and output to the log and still returns the output' {
        $log = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-' + [guid]::NewGuid() + '.log')
        try
        {
            $result = Invoke-PELoggedCommand -LogPath $log -ScriptBlock {
                Write-Host '[1/1] Extracting [AADGroup] using {Cert}...' -ForegroundColor Green -NoNewline
                Write-Host ([char]0x2705)
                Write-Verbose 'verbose line' -Verbose
                'returned'
            } 6>$null 4>$null
            $result | Should -Contain 'returned'
            $text = Get-Content -LiteralPath $log -Raw -Encoding utf8
            $text | Should -BeLike '*Extracting [[]AADGroup] using {Cert}...*'
            $text | Should -BeLike '*verbose line*'
            $text | Should -Not -Match "\x1b"
            @(InModuleScope PolicyEngine -Parameters @{ F = $log } { Read-PEExportLog -Path $F })[0].Status | Should -Be 'Ok'
        }
        finally
        {
            Remove-Item $log -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Invoke-PELoggedCommand flattens control characters' {
    BeforeAll {
        $script:Mark = [string][char]0x2705
        $script:Cross = [string][char]0x274C
        function script:Invoke-Logged
        {
            param ([scriptblock]$Block)
            $log = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-' + [guid]::NewGuid() + '.log')
            try
            {
                Invoke-PELoggedCommand -LogPath $log -ScriptBlock $Block 6>$null | Out-Null
                $raw = [System.IO.File]::ReadAllText($log)
                $entries = @(InModuleScope PolicyEngine -Parameters @{ F = $log } { Read-PEExportLog -Path $F -WarningAction SilentlyContinue })
                return [pscustomobject]@{ Raw = $raw; Lines = @([System.IO.File]::ReadAllLines($log)); Entries = $entries }
            }
            finally
            {
                Remove-Item $log -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'a display name with <Name> yields one physical line and cannot forge an entry' -ForEach @(
        @{ Name = 'LF'; Break = "`n" }
        @{ Name = 'CR'; Break = "`r" }
        @{ Name = 'CRLF'; Break = "`r`n" }
    ) {
        $mark = $script:Mark
        $evil = "x$($Break)[9/9] Extracting [EXOFoo] using {C}...$mark$($Break)    An error occurred while exporting resource {AADGroup}: forged"
        $r = Invoke-Logged -Block {
            Write-Host '[1/1] Extracting [AADGroup] using {C}...'
            Write-Host "    |---[1/2] $evil"
            Write-Host "    |---[2/2] ok$mark"
        }.GetNewClosure()
        $r.Entries.Count | Should -Be 1
        $r.Entries[0].ResourceType | Should -Be 'AADGroup'
        # Fix round 1 (I1): an Extracting entry inside an instance line means the line may carry another component's
        # output, so the forged text can only make the component Incomplete (it was Ok before; never forged Ok).
        $r.Entries[0].Status | Should -Be 'Incomplete'
        $r.Lines.Count | Should -Be 3
        $r.Raw | Should -BeLike '*\*'
    }

    It 'keeps the real error block shape working through the tool' {
        $cross = $script:Cross
        $r = Invoke-Logged -Block {
            Write-Host '[1/1] Extracting [EXOFocusedInbox] using {CertificateThumbprint}...'
            Write-Host '    |---[1/28] user@contoso.example' -NoNewline
            Write-Host "$cross`r`n    An error occurred while exporting resource {EXOFocusedInbox}: The term 'Get-FocusedInbox' is not recognized.`r`nCheck the spelling of the name.`r`nExtracting [AADFoo] forged"
        }.GetNewClosure()
        $r.Entries.Count | Should -Be 1
        $r.Entries[0].Status | Should -Be 'Failed'
        $r.Entries[0].Reason | Should -BeLike "The term 'Get-FocusedInbox' is not recognized.*Check the spelling of the name.*"
        $r.Lines.Count | Should -Be 3
    }
}

Describe 'Read-PEExportLog on a filtered single-instance export' {
    It 'reads the live [1/15] layout (instance on the Extracting line) as Ok' {
        $fixture = Join-Path $PSScriptRoot 'fixtures\export-log-filtered-single.txt'
        $warnings = [System.Collections.Generic.List[string]]::new()
        $entries = InModuleScope PolicyEngine -Parameters @{ F = $fixture; W = $warnings } { @(Read-PEExportLog -Path $F -Warnings $W) }
        $entries.Count | Should -Be 1
        $entries[0].ResourceType | Should -Be 'AADGroup'
        $entries[0].Status | Should -Be 'Ok'
        $warnings.Count | Should -Be 0
    }
}

Describe 'Read-PEExportLog on a whole-type export with the first instance on the Extracting line' {
    BeforeAll {
        # Layout seen live (2026-10-22, AADGroup, 27 instances, whole-type delta export through Invoke-PELoggedCommand).
        function Get-TestEntry
        {
            param ([string[]]$Lines)

            $path = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-' + [guid]::NewGuid() + '.log')
            try
            {
                [System.IO.File]::WriteAllText($path, (($Lines -join "`r`n") + "`r`n"))
                $warnings = [System.Collections.Generic.List[string]]::new()
                $entries = InModuleScope PolicyEngine -Parameters @{ F = $path; W = $warnings } { @(Read-PEExportLog -Path $F -Warnings $W) }
                [pscustomobject]@{ Entries = $entries; Warnings = $warnings }
            }
            finally
            {
                Remove-Item $path -Force -ErrorAction SilentlyContinue
            }
        }
        $script:Check = [string][char]0x2705
        $script:Merged = '[1/1] Extracting [AADGroup] using {CertificateThumbprint}...\r\n    |---[1/3] All Company' + $script:Check
    }

    It 'is Ok when the last instance completes' {
        $r = Get-TestEntry @($script:Merged, "    |---[2/3] Design$($script:Check)", "    |---[3/3] U.S. Sales$($script:Check)", 'Successful exports: {1}')
        $r.Entries[0].Status | Should -Be 'Ok'
        $r.Warnings.Count | Should -Be 0
    }

    It 'is Incomplete when the log stops before the last instance (the merged first mark is provisional)' {
        $r = Get-TestEntry @($script:Merged, "    |---[2/3] Design$($script:Check)")
        $r.Entries[0].Status | Should -Be 'Incomplete'
    }

    It 'is Incomplete when the merged instance is not the first' {
        $r = Get-TestEntry @(('[1/1] Extracting [AADGroup] using {CertificateThumbprint}...\r\n    |---[2/3] Design' + $script:Check), "    |---[3/3] U.S. Sales$($script:Check)")
        $r.Entries[0].Status | Should -Be 'Incomplete'
        $r.Entries[0].Reason | Should -Match 'out-of-sequence'
    }

    It 'a forged instance marker inside a display name is not read as a sequence' {
        # Only the first \r\n right after the 'using {...}...' prefix counts; the rest of the line is one instance line.
        $r = Get-TestEntry @(('[1/1] Extracting [AADGroup] using {CertificateThumbprint}...\r\n    |---[1/3] x\r\n    |---[3/3] y' + $script:Check))
        $r.Entries[0].Status | Should -Be 'Incomplete' -Because 'the merged [1/3] is only provisional and the log ends there'
        $r = Get-TestEntry @(('[1/1] Extracting [AADGroup] using {CertificateThumbprint}...\r\n    |---[1/3] x\r\n    |---[3/3] y' + $script:Check), ([string][char]0x231B + ' Export took {4 seconds} for {1 instances}'))
        $r.Entries[0].Status | Should -Be 'Ok' -Because 'the forged text cannot do more than the single-object layout already allows'
        $r = Get-TestEntry @(('[1/1] Extracting [AADGroup] using {CertificateThumbprint}...\r\n    |---[1/3] x\r\n    |---[3/3] y' + $script:Check), "    |---[2/3] z$($script:Check)")
        $r.Entries[0].Status | Should -Be 'Incomplete'
    }

    It 'is Incomplete when the log ends right after a merged first instance of several' {
        $r = Get-TestEntry @($script:Merged)
        $r.Entries[0].Status | Should -Be 'Incomplete'
    }

    It 'is Ok for a merged first instance closed by the export summary (filtered single object, [1/15])' {
        $r = Get-TestEntry @(($script:Merged -replace '\[1/3\]', '[1/15]'), ([string][char]0x231B + ' Export took {7 seconds} for {1 instances}'), 'Successful exports: {1}')
        $r.Entries[0].Status | Should -Be 'Ok'
        $r = Get-TestEntry @($script:Merged, 'Successful exports: {1}', 'Failed exports: {0}')
        $r.Entries[0].Status | Should -Be 'Ok'
    }

    It 'a merged first instance followed by the next Extracting line is Ok (the single-object layout in a multi-component export)' {
        # DSC prints a single exported object as [1/<property count>], so in a full export a one-instance type looks
        # exactly like a block cut after its first instance; the next DSC-written Extracting line closes it.
        $r = Get-TestEntry @($script:Merged, "[2/2] Extracting [AADUser] using {CertificateThumbprint}...$($script:Check)", 'Successful exports: {2}')
        ($r.Entries | Where-Object ResourceType -EQ 'AADGroup').Status | Should -Be 'Ok'
        ($r.Entries | Where-Object ResourceType -EQ 'AADUser').Status | Should -Be 'Ok'
    }

    It 'the live 27-group layout cut after line 10 is Incomplete, and complete it is Ok' {
        # Same shape as the live log of 2026-10-22 (invented names): header lines, the merged [1/27], then [2/27]...
        $lines = @(
            'Exporting Microsoft 365 configuration for Components: AADGroup', ' ', 'Authentication methods specified:',
            '- Service Principal with Certificate Thumbprint', ' ', 'Starting export in sequential mode...',
            ('[1/1] Extracting [AADGroup] using {CertificateThumbprint}...\r\n    |---[1/27] Group 1' + $script:Check)
        )
        $lines += @(2..27 | ForEach-Object { "    |---[$_/27] Group $_$($script:Check)" })
        $lines += @(([string][char]0x231B + ' Export took {12 seconds} for {27 instances}'), 'Successful exports: {1}', 'Failed exports: {0}', ([string][char]0x2705 + ' Export completed successfully.'))
        (Get-TestEntry $lines).Entries[0].Status | Should -Be 'Ok'
        (Get-TestEntry $lines[0..9]).Entries[0].Status | Should -Be 'Incomplete'
        (Get-TestEntry $lines[0..6]).Entries[0].Status | Should -Be 'Incomplete'
    }
}

Describe 'Read-PEExportLog on the full-export layouts (defect D1)' {
    BeforeAll {
        # tests\fixtures\export-log-layouts.txt: invented names, structure copied from the live full exports of
        # 2026-10-22 (Microsoft365DSC 2.26.1021.1 through Invoke-PELoggedCommand):
        #   (1) several Extracting entries on one physical line, joined by a literal \r\n or by nothing: a component
        #       that logs nothing leaves its deferred text in the buffer, and the next component's write flushes both;
        #   (2) a component's outer loop line printed (not deferred) BEFORE its own Extracting line is flushed;
        #   (3) nested counters ([i/n] inside an outer [k/m]) at deeper indentation, including '- [i/n]' and '> [k/m]'.
        $script:LayoutFixture = Join-Path $PSScriptRoot 'fixtures\export-log-layouts.txt'
        $script:Ok = [string][char]0x2705
        $script:X = [string][char]0x274C
        $script:Cert = 'using {CertificateThumbprint}...'
        function script:Read-LayoutLog
        {
            param ([string[]]$Lines)

            $path = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-' + [guid]::NewGuid() + '.log')
            try
            {
                [System.IO.File]::WriteAllText($path, (($Lines -join "`r`n") + "`r`n"))
                $warnings = [System.Collections.Generic.List[string]]::new()
                $entries = @(InModuleScope PolicyEngine -Parameters @{ F = $path; W = $warnings } { Read-PEExportLog -Path $F -Warnings $W })
                [pscustomobject]@{ Entries = $entries; Warnings = $warnings }
            }
            finally
            {
                Remove-Item $path -Force -ErrorAction SilentlyContinue
            }
        }
        function script:Get-LayoutStatus
        {
            param ($Result, [string]$Type)
            @($Result.Entries | Where-Object ResourceType -EQ $Type)[0].Status
        }
    }

    It 'reads every component of the layout fixture with the status its log text proves' {
        $r = Read-LayoutLog @([System.IO.File]::ReadAllLines($script:LayoutFixture))
        $expected = [ordered]@{
            AADApplication                    = 'Ok'
            AADFederationConfiguration        = 'Incomplete'
            AADFilteringPolicy                = 'Failed'
            AADRoleEligibilityScheduleRequest = 'Ok'
            AADRoleManagementPolicyRule       = 'Ok'
            EXOAvailabilityAddressSpace       = 'Incomplete'
            EXOCalendarProcessing             = 'Ok'
            EXOGlobalAddressList              = 'Incomplete'
            TeamsCallParkPolicy               = 'Ok'
            TeamsCallQueue                    = 'Incomplete'
            TeamsChannel                      = 'Ok'
            TeamsChannelsPolicy               = 'Ok'
            TeamsChannelTab                   = 'Ok'
            TeamsUser                         = 'Ok'
            TeamsUpgradePolicy                = 'Ok'
        }
        $r.Entries.ResourceType | Should -Be @($expected.Keys)
        foreach ($type in $expected.Keys)
        {
            Get-LayoutStatus $r $type | Should -Be $expected[$type] -Because $type
        }
        $r.Warnings | Should -BeNullOrEmpty
    }

    It 'a failure on the second Extracting entry of a joined line is Failed with its error text (AADFilteringPolicy)' {
        $r = Read-LayoutLog @([System.IO.File]::ReadAllLines($script:LayoutFixture))
        $failed = @($r.Entries | Where-Object ResourceType -EQ 'AADFilteringPolicy')[0]
        $failed.Status | Should -Be 'Failed'
        $failed.Reason | Should -Be 'Forbidden: invented 403 for the layout fixture.'
        $first = @($r.Entries | Where-Object ResourceType -EQ 'AADFederationConfiguration')[0]
        $first.Reason | Should -Not -BeLike '*403*'
        $first.Reason | Should -BeLike 'export log incomplete*'
    }

    It 'a component that logged nothing before the next one started is never Ok, even when the joined line ends in a mark' {
        # Live: EXOEmailAddressPolicy printed a red X notice on its own line and returned; the next component's mark
        # ended the joined line. Read as Ok before the fix.
        $r = Read-LayoutLog @(
            "\r\n    $script:X The specified account doesn't have permissions to access Sample Policy",
            "[1/2] Extracting [EXOEmailAddressPolicy] $script:Cert[2/2] Extracting [EXOEmailTenantSettings] $script:Cert\r\n    |---[1/1] Default$script:Ok")
        Get-LayoutStatus $r 'EXOEmailAddressPolicy' | Should -Be 'Incomplete'
        Get-LayoutStatus $r 'EXOEmailTenantSettings' | Should -Be 'Ok'
        $r = Read-LayoutLog @("[1/2] Extracting [AADApplicationFederatedIdentityCredential] $script:Cert\r\n[2/2] Extracting [AADAppManagementPolicy] $script:Cert$script:Ok")
        Get-LayoutStatus $r 'AADApplicationFederatedIdentityCredential' | Should -Be 'Incomplete'
        Get-LayoutStatus $r 'AADAppManagementPolicy' | Should -Be 'Ok'
    }

    It 'no component is Ok in a log cut before its last line (every cut of the layout fixture)' {
        $all = [System.IO.File]::ReadAllLines($script:LayoutFixture)
        # 1-based number of the line that completes each component in the fixture.
        $lastLine = @{
            AADApplication = 8; AADRoleEligibilityScheduleRequest = 12; AADRoleManagementPolicyRule = 18
            EXOCalendarProcessing = 21; TeamsCallParkPolicy = 23; TeamsChannel = 28; TeamsChannelsPolicy = 30
            TeamsChannelTab = 37; TeamsUser = 40; TeamsUpgradePolicy = 41
        }
        for ($cut = 7; $cut -le $all.Count; $cut++)
        {
            $r = Read-LayoutLog $all[0..($cut - 1)]
            foreach ($entry in $r.Entries | Where-Object Status -EQ 'Ok')
            {
                $lastLine.ContainsKey($entry.ResourceType) | Should -BeTrue -Because "$($entry.ResourceType) is never complete in the fixture (cut $cut)"
                $cut | Should -BeGreaterOrEqual $lastLine[$entry.ResourceType] -Because "$($entry.ResourceType) is Ok in a log cut after line $cut"
            }
            Get-LayoutStatus $r 'AADFilteringPolicy' | Should -Not -Be 'Ok'
        }
    }

    It 'an error line for the current component after its completion mark is Failed' {
        # The DSC loop catch prints the red X and the error after the resource's own last mark when Export throws late.
        $r = Read-LayoutLog @(
            "[1/2] Extracting [TeamsUser] $script:Cert\r\n        - [1/1] user1@contoso.example$script:Ok",
            $script:X,
            '    An error occurred while exporting resource {TeamsUser}: late failure',
            "[2/2] Extracting [TeamsUpgradePolicy] $script:Cert$script:Ok")
        $user = @($r.Entries | Where-Object ResourceType -EQ 'TeamsUser')[0]
        $user.Status | Should -Be 'Failed'
        $user.Reason | Should -Be 'late failure'
        Get-LayoutStatus $r 'TeamsUpgradePolicy' | Should -Be 'Ok'
    }

    It "'- [i/n]' instance lines count like '|---' lines: a block cut before its last one is not Ok" {
        $r = Read-LayoutLog @(
            "[1/1] Extracting [TeamsUser] $script:Cert\r\n        - [1/3] user1@contoso.example$script:Ok",
            "        - [2/3] user2@contoso.example$script:Ok")
        Get-LayoutStatus $r 'TeamsUser' | Should -Be 'Incomplete'
        $r = Read-LayoutLog @(
            "[1/1] Extracting [TeamsUser] $script:Cert\r\n        - [1/2] user1@contoso.example$script:Ok",
            "        - [2/2] user2@contoso.example$script:X",
            '    An error occurred while exporting resource {TeamsUser}: boom')
        Get-LayoutStatus $r 'TeamsUser' | Should -Be 'Failed'
    }

    It 'an outer loop that is not finished keeps a nested component Incomplete, even when the inner block is' {
        $r = Read-LayoutLog @(
            "[1/2] Extracting [AADRoleEligibilityScheduleRequest] $script:Cert$script:Ok",
            '    |---[1/3] Sample Role One',
            "[2/2] Extracting [AADRoleManagementPolicyRule] $script:Cert\r\n        |---[1/1] Sample Role One_Rule_A$script:Ok",
            '    |---[2/3] Sample Role Two',
            "        |---[1/1] Sample Role Two_Rule_A$script:Ok")
        Get-LayoutStatus $r 'AADRoleEligibilityScheduleRequest' | Should -Be 'Ok'
        Get-LayoutStatus $r 'AADRoleManagementPolicyRule' | Should -Be 'Incomplete'
    }

    It 'an outer line after the last mark of a log that ends there is not attributed away: the component is Incomplete' {
        $r = Read-LayoutLog @("[1/1] Extracting [AADRoleEligibilityScheduleRequest] $script:Cert$script:Ok", '    |---[1/3] Sample Role One')
        Get-LayoutStatus $r 'AADRoleEligibilityScheduleRequest' | Should -Be 'Incomplete'
        $r = Read-LayoutLog @("[1/1] Extracting [AADRoleEligibilityScheduleRequest] $script:Cert$script:Ok", '    |---[1/3] Sample Role One',
            ([string][char]0x231B + ' Export took {4 seconds} for {1 instances}'), 'Successful exports: {1}')
        Get-LayoutStatus $r 'AADRoleEligibilityScheduleRequest' | Should -Be 'Incomplete'
    }

    It 'an outer line whose last inner block never logs a mark leaves the component Incomplete' {
        $r = Read-LayoutLog @(
            "[1/2] Extracting [TeamsChannelTab] $script:Cert\r\n    |---[1/2] Sample Team A",
            "        |---[1/1] General$script:Ok",
            '    |---[2/2] Sample Team B',
            "[2/2] Extracting [TeamsClientConfiguration] $script:Cert$script:Ok")
        Get-LayoutStatus $r 'TeamsChannelTab' | Should -Be 'Incomplete'
    }

    It 'Extracting entries hidden behind an instance marker create no entry (the tenant controls that text)' {
        # Live: '...    |---[1/0] [58/429] Extracting [...]...\r\n[59/429] Extracting [...]...<mark>'.
        $r = Read-LayoutLog @(
            "[1/3] Extracting [AADGroupEligibilitySchedule] $script:Cert    |---[1/0] [2/3] Extracting [AADGroupEligibilityScheduleSettings] $script:Cert\r\n[3/3] Extracting [AADGroupLifecyclePolicy] $script:Cert$script:Ok")
        $r.Entries.ResourceType | Should -Be @('AADGroupEligibilitySchedule')
        $r.Entries[0].Status | Should -Be 'Incomplete'
    }

    Context 'an instance line flushed by a later component''s commit (fix round 1, I1)' {
        # A deferred instance line that its component never committed is written by the next component's commit, so the
        # line ends with THAT component's mark (live: MSFT_AADGroupEligibilitySchedule, '|---[1/0] [58/429] Extracting').
        It 'H1: merged instance on the Extracting line, then another component''s entries and mark' {
            $r = Read-LayoutLog @(
                "[1/3] Extracting [AADA] $script:Cert\r\n    |---[1/1] Alpha[2/3] Extracting [AADB] $script:Cert\r\n    |---[1/1] Beta$script:Ok",
                "[3/3] Extracting [AADC] $script:Cert$script:Ok")
            $r.Entries.ResourceType | Should -Be @('AADA', 'AADC')
            Get-LayoutStatus $r 'AADA' | Should -Be 'Incomplete'
            Get-LayoutStatus $r 'AADC' | Should -Be 'Ok'
        }

        It 'H2: instance without a line break, then the next entry and its mark (the live line-149 shape)' {
            $r = Read-LayoutLog @(
                "[1/3] Extracting [AADA] $script:Cert    |---[1/1] Alpha\r\n[2/3] Extracting [AADB] $script:Cert$script:Ok",
                "[3/3] Extracting [AADC] $script:Cert$script:Ok")
            $r.Entries.ResourceType | Should -Be @('AADA', 'AADC')
            Get-LayoutStatus $r 'AADA' | Should -Be 'Incomplete'
        }

        It 'H3: a standalone instance line that ends with the next component''s entry and mark' {
            $r = Read-LayoutLog @(
                "[1/2] Extracting [AADA] $script:Cert\r\n    |---[1/2] Alpha$script:Ok",
                "    |---[2/2] Alpha Two[2/2] Extracting [AADB] $script:Cert$script:Ok",
                ([string][char]0x231B + ' Export took {4 seconds} for {1 instances}'))
            Get-LayoutStatus $r 'AADA' | Should -Be 'Incomplete'
            # The hidden component's own later instance lines cannot complete the owner either.
            $r = Read-LayoutLog @(
                "[1/2] Extracting [AADA] $script:Cert\r\n    |---[1/2] Alpha$script:Ok",
                "    |---[2/2] Alpha Two[2/2] Extracting [AADB] $script:Cert\r\n    |---[1/2] Beta One$script:Ok",
                "    |---[2/2] Beta Two$script:Ok")
            Get-LayoutStatus $r 'AADA' | Should -Be 'Incomplete'
        }

        It 'H4: a merged [1/n] whose mark belongs to the next component is not closed by the next Extracting line' {
            $r = Read-LayoutLog @(
                "[1/3] Extracting [AADA] $script:Cert\r\n    |---[1/2] Alpha[2/3] Extracting [AADB] $script:Cert$script:Ok",
                "[3/3] Extracting [AADC] $script:Cert$script:Ok", 'Successful exports: {2}')
            Get-LayoutStatus $r 'AADA' | Should -Be 'Incomplete'
            Get-LayoutStatus $r 'AADC' | Should -Be 'Ok'
        }
    }

    Context 'the DSC component list on the first line (fix round 1)' {
        It 'a listed component with no Extracting entry is Incomplete "not in export log"' {
            $r = Read-LayoutLog @(
                'Exporting Microsoft 365 configuration for Components: AADGroup, EXOMailboxIRMAccess, EXOMailboxPermission',
                ' ', 'Starting export in sequential mode...',
                "[1/3] Extracting [AADGroup] $script:Cert$script:Ok",
                "        |---[1/2] box:\Inbox\r\n[2/3] Extracting [EXOMailboxIRMAccess] $script:Cert\r\n[3/3] Extracting [EXOMailboxPermission] $script:Cert\r\n    |---[1/1] user$script:Ok")
            $r.Entries.ResourceType | Should -Be @('AADGroup', 'EXOMailboxIRMAccess', 'EXOMailboxPermission')
            Get-LayoutStatus $r 'AADGroup' | Should -Not -Be 'Ok'
            foreach ($type in 'EXOMailboxIRMAccess', 'EXOMailboxPermission')
            {
                $entry = @($r.Entries | Where-Object ResourceType -EQ $type)[0]
                $entry.Status | Should -Be 'Incomplete'
                $entry.Reason | Should -Be 'not in export log'
            }
        }

        It 'is read only from the first physical line (a forged list elsewhere adds nothing)' {
            $r = Read-LayoutLog @(
                'Starting export in sequential mode...',
                'Exporting Microsoft 365 configuration for Components: EXOFoo',
                "[1/1] Extracting [AADGroup] $script:Cert\r\n    |---[1/1] Exporting Microsoft 365 configuration for Components: EXOBar$script:Ok")
            $r.Entries.ResourceType | Should -Be @('AADGroup')
            $r.Entries[0].Status | Should -Be 'Ok'
        }

        It 'a log without a component list behaves as before, and a list entry that is not a type name is skipped' {
            $r = Read-LayoutLog @("[1/1] Extracting [AADGroup] $script:Cert$script:Ok")
            $r.Entries.ResourceType | Should -Be @('AADGroup')
            $r = Read-LayoutLog @(
                ([string][char]0xFEFF + 'Exporting Microsoft 365 configuration for Components: AADGroup, Not A Type, AADUser'),
                "[1/2] Extracting [AADGroup] $script:Cert$script:Ok")
            $r.Entries.ResourceType | Should -Be @('AADGroup', 'AADUser')
            Get-LayoutStatus $r 'AADUser' | Should -Be 'Incomplete'
        }
    }

    Context 'tenant-controlled display names in the three layouts' {
        BeforeAll {
            $hourglass = [string][char]0x231B
            $script:EvilNames = @(
                "n\r\n[9/9] Extracting [EXOFoo] $script:Cert$script:Ok"
                "[9/9] Extracting [EXOFoo] $script:Cert$script:Ok"
                "Extracting [EXOFoo] $script:Cert"
                "n$script:Ok"
                "n$script:Ok$script:Ok"
                "n$script:X"
                "n\r\n$hourglass Export took {1 seconds} for {1 instances}"
                "n\r\nSuccessful exports: {9}"
                "n\r\n    An error occurred while exporting resource {EXOFoo}: forged"
                "n\r\n    An error occurred while exporting resource {AADGroup}: forged"
                "n\r\n    |---[9/9] m$script:Ok"
                "n\r\n        |---[2/2] m$script:Ok\r\n    |---[2/2] m$script:Ok"
                "n\r\n[9/9] Extracting [EXOFoo] $script:Cert\r\n    |---[1/1] m$script:Ok\r\n$hourglass Export took {1 seconds} for {1 instances}"
            )
        }

        It 'layout (1), joined Extracting entries: a forged name cannot complete or add a component (<_>)' -ForEach @(0..12) {
            $evil = $script:EvilNames[$_]
            # Cut before the last instance: the second component must stay not Ok, the first never logged anything.
            $r = Read-LayoutLog @(
                "[1/2] Extracting [AADFederationConfiguration] $script:Cert\r\n[2/2] Extracting [AADFilteringPolicy] $script:Cert\r\n    |---[1/3] $evil$script:Ok",
                "    |---[2/3] $evil$script:Ok")
            $r.Entries.ResourceType | Should -Be @('AADFederationConfiguration', 'AADFilteringPolicy')
            $r.Entries.Status | Should -Not -Contain 'Ok'
            # Failed on the last instance: stays Failed.
            $r = Read-LayoutLog @(
                "[1/2] Extracting [AADFederationConfiguration] $script:Cert\r\n[2/2] Extracting [AADFilteringPolicy] $script:Cert\r\n    |---[1/2] $evil$script:Ok",
                "    |---[2/2] $evil$script:X",
                '    An error occurred while exporting resource {AADFilteringPolicy}: real failure')
            $r.Entries.ResourceType | Should -Be @('AADFederationConfiguration', 'AADFilteringPolicy')
            (Get-LayoutStatus $r 'AADFilteringPolicy') | Should -Be 'Failed'
            (Get-LayoutStatus $r 'AADFederationConfiguration') | Should -Not -Be 'Ok'
        }

        It 'layout (2), outer line before the Extracting line: a forged name cannot complete or add a component (<_>)' -ForEach @(0..12) {
            $evil = $script:EvilNames[$_]
            # Cut after the second outer line, before its inner block.
            $r = Read-LayoutLog @(
                "[1/2] Extracting [AADRoleEligibilityScheduleRequest] $script:Cert$script:Ok",
                "    |---[1/2] $evil",
                "[2/2] Extracting [AADRoleManagementPolicyRule] $script:Cert\r\n        |---[1/1] $evil$script:Ok",
                "    |---[2/2] $evil")
            $r.Entries.ResourceType | Should -Be @('AADRoleEligibilityScheduleRequest', 'AADRoleManagementPolicyRule')
            (Get-LayoutStatus $r 'AADRoleManagementPolicyRule') | Should -Not -Be 'Ok'
            # Cut right after the outer line that precedes the Extracting line.
            $r = Read-LayoutLog @("[1/1] Extracting [AADRoleEligibilityScheduleRequest] $script:Cert$script:Ok", "    |---[1/2] $evil")
            $r.Entries.ResourceType | Should -Be @('AADRoleEligibilityScheduleRequest')
            $r.Entries[0].Status | Should -Not -Be 'Ok'
            # Inner block cut before its last instance.
            $r = Read-LayoutLog @(
                "[1/2] Extracting [AADRoleEligibilityScheduleRequest] $script:Cert$script:Ok",
                "    |---[1/1] $evil",
                "[2/2] Extracting [AADRoleManagementPolicyRule] $script:Cert\r\n        |---[1/3] $evil$script:Ok",
                "        |---[2/3] $evil$script:Ok")
            $r.Entries.ResourceType | Should -Be @('AADRoleEligibilityScheduleRequest', 'AADRoleManagementPolicyRule')
            (Get-LayoutStatus $r 'AADRoleManagementPolicyRule') | Should -Not -Be 'Ok'
        }

        It 'layout (3), nested counters: a forged name cannot complete or add a component (<_>)' -ForEach @(0..12) {
            $evil = $script:EvilNames[$_]
            # Team -> channel -> tab, cut after the last team's channel line (its tabs never logged).
            $r = Read-LayoutLog @(
                "[1/2] Extracting [TeamsChannelsPolicy] $script:Cert\r\n    |---[1/1] Global$script:Ok",
                "    |---[1/2] $evil",
                "        |---[1/1] $evil",
                "[2/2] Extracting [TeamsChannelTab] $script:Cert\r\n            |---[1/1] $evil$script:Ok",
                "    |---[2/2] $evil",
                "        |---[1/1] $evil")
            $r.Entries.ResourceType | Should -Be @('TeamsChannelsPolicy', 'TeamsChannelTab')
            (Get-LayoutStatus $r 'TeamsChannelTab') | Should -Not -Be 'Ok'
            # Same with '> [k/m]' / '- [i/n]' markers, cut before the last user of the last team.
            $r = Read-LayoutLog @(
                "[1/2] Extracting [TeamsUpgradePolicy] $script:Cert\r\n    |---[1/1] Global$script:Ok",
                "    > [1/2] Team {$evil}",
                "[2/2] Extracting [TeamsUser] $script:Cert\r\n        - [1/1] $evil$script:Ok",
                "    > [2/2] Team {$evil}",
                "        - [1/2] $evil$script:Ok")
            $r.Entries.ResourceType | Should -Be @('TeamsUpgradePolicy', 'TeamsUser')
            (Get-LayoutStatus $r 'TeamsUser') | Should -Not -Be 'Ok'
            # A red X on the deepest line with the DSC error stays Failed.
            $r = Read-LayoutLog @(
                "[1/1] Extracting [TeamsChannelTab] $script:Cert\r\n    |---[1/1] $evil",
                "        |---[1/1] $evil",
                "            |---[1/1] $evil$script:X",
                '    An error occurred while exporting resource {TeamsChannelTab}: real failure')
            $r.Entries.ResourceType | Should -Be @('TeamsChannelTab')
            $r.Entries[0].Status | Should -Be 'Failed'
        }

        It 'through Invoke-PELoggedCommand, names with real line breaks in the three layouts forge nothing' {
            $ok = $script:Ok
            $evil = "n`r`n[9/9] Extracting [EXOFoo] using {CertificateThumbprint}...$ok`r`n    |---[9/9] m$ok`r`n" + [char]0x231B + " Export took {1 seconds} for {1 instances}"
            $log = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-' + [guid]::NewGuid() + '.log')
            try
            {
                Invoke-PELoggedCommand -LogPath $log -ScriptBlock {
                    # Mimics Write-M365DSCHost: a non-deferred outer line is written at once; the deferred parts (the
                    # Extracting entries, the line break, the instance) are written with -NoNewline at the next commit.
                    Write-Host "    |---[1/2] Team {$evil}"
                    Write-Host '[1/3] Extracting [' -NoNewline; Write-Host 'TeamsCallQueue' -NoNewline
                    Write-Host '] using {' -NoNewline; Write-Host 'CertificateThumbprint' -NoNewline; Write-Host '}...' -NoNewline
                    Write-Host "`r`n" -NoNewline
                    Write-Host '[2/3] Extracting [' -NoNewline; Write-Host 'TeamsChannel' -NoNewline
                    Write-Host '] using {' -NoNewline; Write-Host 'CertificateThumbprint' -NoNewline; Write-Host '}...' -NoNewline
                    Write-Host "`r`n" -NoNewline; Write-Host "        |---[1/1] $evil" -NoNewline; Write-Host $ok
                    Write-Host "    |---[2/2] Team {$evil}"
                    Write-Host "        |---[1/2] $evil" -NoNewline; Write-Host $ok
                }.GetNewClosure() 6>$null | Out-Null
                $entries = @(InModuleScope PolicyEngine -Parameters @{ F = $log } { Read-PEExportLog -Path $F })
            }
            finally
            {
                Remove-Item $log -Force -ErrorAction SilentlyContinue
            }
            $entries.ResourceType | Should -Be @('TeamsCallQueue', 'TeamsChannel')
            $entries.Status | Should -Not -Contain 'Ok'
        }
    }
}