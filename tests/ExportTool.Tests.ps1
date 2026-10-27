BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Tool = (Resolve-Path "$PSScriptRoot\..\tools\Export-M365DscTenant.ps1").Path
    $script:Pwsh = (Get-Process -Id $PID).Path

    function Invoke-ToolBindingProbe
    {
        # Runs ONLY the real tool's param block and its first statement (the Workloads normalisation) in a child
        # `pwsh -File`, exactly as Invoke-PEFullCheck starts the tool, and returns what was bound. No tenant call.
        param ([string[]]$ArgumentList)

        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Tool, [ref]$null, [ref]$null)
        $paramText = $ast.ParamBlock.Extent.Text
        $first = $ast.EndBlock.Statements[0].Extent.Text
        $probe = Join-Path $TestDrive ('probe-' + [guid]::NewGuid().ToString('N') + '.ps1')
        $body = "$paramText`n$first`n[pscustomobject]@{ Role = `$Role; Workloads = @(`$Workloads); OutputPath = `$OutputPath; Components = @(`$Components) } | ConvertTo-Json -Compress`n"
        Set-Content -LiteralPath $probe -Value $body
        $output = & $script:Pwsh -NoProfile -File $probe @ArgumentList 2>&1
        if ($LASTEXITCODE -ne 0)
        {
            throw "probe failed: $($output -join ' ')"
        }
        return ($output | Select-Object -Last 1 | ConvertFrom-Json)
    }
}

Describe 'Get-PEExportToolArgument' {
    It 'passes the workloads as ONE comma-joined string' {
        $a = @(& (Get-Module PolicyEngine) { Get-PEExportToolArgument -Workloads 'AAD', 'Intune', 'EXO' -OutputPath 'C:\x y\out' })
        $i = [array]::IndexOf($a, '-Workloads')
        $i | Should -BeGreaterThan -1
        $a[$i + 1] | Should -Be 'AAD,Intune,EXO'
        $a[[array]::IndexOf($a, '-OutputPath') + 1] | Should -Be 'C:\x y\out'
        $a | Should -Contain '-File'
    }
}

Describe 'tools\Export-M365DscTenant.ps1 parameter binding (offline)' {
    It 'binds the default child arguments: Workloads split, Role stays default, nothing positional' {
        $arguments = @(& (Get-Module PolicyEngine) { Get-PEExportToolArgument -Workloads 'AAD', 'Intune', 'EXO', 'Teams' -OutputPath 'C:\out' })
        # Drop '-NoProfile -File <tool>' (the probe is run with -File itself).
        $rest = $arguments[3..($arguments.Count - 1)]
        $bound = Invoke-ToolBindingProbe -ArgumentList $rest
        $bound.Role | Should -Be 'Reader'
        @($bound.Workloads) | Should -Be @('AAD', 'Intune', 'EXO', 'Teams')
        $bound.OutputPath | Should -Be 'C:\out'
    }

    It 'splits a comma-joined value and trims blanks' {
        $bound = Invoke-ToolBindingProbe -ArgumentList @('-Workloads', 'AAD, Intune,,EXO')
        @($bound.Workloads) | Should -Be @('AAD', 'Intune', 'EXO')
    }

    It 'still accepts an array in-process' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Tool, [ref]$null, [ref]$null)
        $probe = [scriptblock]::Create($ast.ParamBlock.Extent.Text + "`n" + $ast.EndBlock.Statements[0].Extent.Text + "`n@(`$Workloads)")
        @(& $probe -Workloads 'AAD', 'EXO') | Should -Be @('AAD', 'EXO')
    }

    It 'documents the failure the old call had: an array through -File lands in -Role' {
        { Invoke-ToolBindingProbe -ArgumentList @('-Workloads', 'AAD', 'Intune') } | Should -Throw '*Role*'
    }
}

Describe 'Invoke-PEFullCheck default export path' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-exporttool-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Temp | Out-Null
        $state = & (Get-Module PolicyEngine) {
            New-PEState -Records @([pscustomobject]@{ ResourceType = 'AADGroup'; Key = 'G'; Workload = 'Entra ID'; Properties = [ordered]@{ DisplayName = 'G' } }) -NotChecked @() -Meta @{ TenantId = 't' }
        }
        Initialize-PEBlueprint -Name 'main' -State $state -DataRoot $script:Temp | Out-Null
        $script:Captured = $null
        $script:MiniFixture = Join-Path $PSScriptRoot 'fixtures\mini-export.ps1'
        Mock -ModuleName PolicyEngine Get-PEReaderTenantId { 'reader-tenant' }
        Mock -ModuleName PolicyEngine Invoke-PEExportToolProcess {
            param ($ArgumentList)
            $script:Captured = @($ArgumentList)
            $out = $ArgumentList[[array]::IndexOf($ArgumentList, '-OutputPath') + 1]
            New-Item -ItemType Directory -Path $out -Force | Out-Null
            Copy-Item $script:MiniFixture (Join-Path $out 'export.ps1')
        }
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'starts the tool with arguments that bind Workloads correctly and leave Role at Reader' {
        Invoke-PEFullCheck -BlueprintName 'main' -DataRoot $script:Temp -WarningAction SilentlyContinue | Out-Null
        $script:Captured | Should -Not -BeNullOrEmpty
        $rest = $script:Captured[3..($script:Captured.Count - 1)]
        $bound = Invoke-ToolBindingProbe -ArgumentList $rest
        $bound.Role | Should -Be 'Reader'
        @($bound.Workloads) | Should -Be @('AAD', 'Intune', 'EXO', 'Teams')
    }

    It 'honours a custom -Workloads list' {
        Invoke-PEFullCheck -BlueprintName 'main' -Workloads 'AAD', 'Teams' -DataRoot $script:Temp -WarningAction SilentlyContinue | Out-Null
        $bound = Invoke-ToolBindingProbe -ArgumentList ($script:Captured[3..($script:Captured.Count - 1)])
        @($bound.Workloads) | Should -Be @('AAD', 'Teams')
    }
}

Describe 'the scheduled full-check path' {
    It 'tools\Invoke-PEFullCheck.ps1 forwards its workloads to Invoke-PEFullCheck as a string array parameter (in-process)' {
        $tool = Resolve-Path "$PSScriptRoot\..\tools\Invoke-PEFullCheck.ps1"
        $text = Get-Content $tool -Raw
        $text | Should -Match 'Invoke-PEFullCheck @arguments'
        $text | Should -Match 'Workloads = \$Workloads'
    }

    It 'the scheduled task starts the tool with only -BlueprintName, so the default workloads apply' {
        . "$PSScriptRoot\..\tools\PESchedule.Common.ps1"
        $def = Get-PEScheduleDefinition -BlueprintName 'test' -PwshPath 'pwsh' -ToolsPath 'D:\r\tools'
        $def.FullCheck.Argument | Should -Be '-NoProfile -File D:\r\tools\Invoke-PEFullCheck.ps1 -BlueprintName test'
        $def.FullCheck.Argument | Should -Not -Match 'Workloads'
    }
}

Describe 'Split-PEExportComponent' {
    It 'puts the components of a workload that needs its own process apart, keeping the order of the rest' {
        $split = & (Get-Module PolicyEngine) { Split-PEExportComponent -Component 'TeamsMeetingPolicy', 'AADGroup', 'SCRoleGroup', 'EXOAcceptedDomain', 'SCComplianceTag' }
        @($split.Main) | Should -Be @('TeamsMeetingPolicy', 'AADGroup', 'EXOAcceptedDomain')
        @($split.Isolated) | Should -Be @('SCRoleGroup', 'SCComplianceTag')
    }

    It 'has nothing apart when no component needs its own process, and nothing in Main when all do' {
        $none = & (Get-Module PolicyEngine) { Split-PEExportComponent -Component 'AADGroup', 'EXOAcceptedDomain' }
        @($none.Isolated).Count | Should -Be 0
        @($none.Main).Count | Should -Be 2
        $all = & (Get-Module PolicyEngine) { Split-PEExportComponent -Component 'SCRoleGroup' }
        @($all.Main).Count | Should -Be 0
        @($all.Isolated) | Should -Be @('SCRoleGroup')
    }

    It 'takes the workloads from Data\Workloads.psd1 (only Security and Compliance today)' {
        $prefixes = @(& (Get-Module PolicyEngine) { Get-PEOwnProcessPrefix })
        $prefixes | Should -Be @('SC')
    }
}

Describe 'Merge-PEExportPart' {
    BeforeEach {
        $script:Main = Join-Path $TestDrive ('main-' + [guid]::NewGuid().ToString('N'))
        $script:Part = Join-Path $TestDrive ('part-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Main, $script:Part | Out-Null
        Copy-Item (Join-Path $PSScriptRoot 'fixtures\mini-export.ps1') (Join-Path $script:Main 'export.ps1')
        Set-Content -LiteralPath (Join-Path $script:Main 'export.log') -Value @('Exporting Microsoft 365 configuration for Components: AADGroup', '[1/1] Extracting [AADGroup] using {CertificateThumbprint}...✅')
        @'
# Generated with Microsoft365DSC version 2.26.1021.1
param (
)

Configuration export
{
    param (
    )

    $OrganizationName = $ConfigurationData.NonNodeData.OrganizationName

    Import-DscResource -ModuleName 'Microsoft365DSC' -ModuleVersion '2.26.1021.1'

    Node localhost
    {
        SCRoleGroup "SCRoleGroup-Help"
        {
            ApplicationId         = $ConfigurationData.NonNodeData.ApplicationId;
            CertificateThumbprint = $ConfigurationData.NonNodeData.CertificateThumbprint;
            Description           = "";
            DisplayName           = "Help";
            Ensure                = "Present";
            Name                  = "Help";
            Roles                 = @("MyBaseOptions");
            TenantId              = $ConfigurationData.NonNodeData.TenantId;
        }
    }
}

export -ConfigurationData .\ConfigurationData.psd1
'@ | Set-Content -LiteralPath (Join-Path $script:Part 'export.ps1')
        Set-Content -LiteralPath (Join-Path $script:Part 'export.log') -Value @('Exporting Microsoft 365 configuration for Components: SCRoleGroup', '[1/1] Extracting [SCRoleGroup] using {CertificateThumbprint}...✅')
    }

    It 'puts the resources of the part into the main export and appends its log' {
        & (Get-Module PolicyEngine) { Merge-PEExportPart -Path $args[0] -PartPath $args[1] } $script:Main $script:Part
        $records = @(& (Get-Module PolicyEngine) { Read-PEExport -Path (Join-Path $args[0] 'export.ps1') } $script:Main)
        ($records.ResourceType | Sort-Object -Unique) | Should -Contain 'SCRoleGroup'
        ($records.ResourceType | Sort-Object -Unique) | Should -Contain 'AADGroup'
        @($records | Where-Object ResourceType -EQ 'SCRoleGroup').Count | Should -Be 1
        @($records | Where-Object ResourceType -EQ 'AADGroup').Count | Should -BeGreaterThan 1
        $log = Get-Content -LiteralPath (Join-Path $script:Main 'export.log')
        $log -join "`n" | Should -Match 'Extracting \[AADGroup\]'
        $log -join "`n" | Should -Match 'Extracting \[SCRoleGroup\]'
        @(& (Get-Module PolicyEngine) { Read-PEExportLog -Path (Join-Path $args[0] 'export.log') -Warnings ([System.Collections.Generic.List[string]]::new()) } $script:Main | Where-Object Status -NE 'Ok').Count | Should -Be 0
    }

    It 'keeps every resource: the merged file holds as many resource blocks as the two files together' {
        $count = { param ($p) @([regex]::Matches((Get-Content -LiteralPath $p -Raw), '(?m)^        [A-Za-z0-9]+ "[^"]*"\s*$')).Count }
        $before = (& $count (Join-Path $script:Main 'export.ps1')) + (& $count (Join-Path $script:Part 'export.ps1'))
        & (Get-Module PolicyEngine) { Merge-PEExportPart -Path $args[0] -PartPath $args[1] } $script:Main $script:Part
        (& $count (Join-Path $script:Main 'export.ps1')) | Should -Be $before
    }

    It 'refuses a part that is not in the generated layout and leaves the main export untouched' {
        Set-Content -LiteralPath (Join-Path $script:Part 'export.ps1') -Value 'not an export'
        $before = Get-Content -LiteralPath (Join-Path $script:Main 'export.ps1') -Raw
        { & (Get-Module PolicyEngine) { Merge-PEExportPart -Path $args[0] -PartPath $args[1] } $script:Main $script:Part } | Should -Throw '*layout*'
        Get-Content -LiteralPath (Join-Path $script:Main 'export.ps1') -Raw | Should -Be $before
        (Get-Content -LiteralPath (Join-Path $script:Main 'export.log') -Raw) | Should -Not -Match 'SCRoleGroup'
    }
}

Describe 'Invoke-PEExportToolProcess' {
    It 'returns when the process ends with exit code 0 and throws on any other exit code' {
        { & (Get-Module PolicyEngine) { Invoke-PEExportToolProcess -ArgumentList '-NoProfile', '-Command', 'exit 0' } } | Should -Not -Throw
        { & (Get-Module PolicyEngine) { Invoke-PEExportToolProcess -ArgumentList '-NoProfile', '-Command', 'exit 3' } } | Should -Throw '*exit code 3*'
    }

    It 'stops the process and throws OperationCanceledException when the job cancel check says so' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $caught = $null
        try { & (Get-Module PolicyEngine) { $script:PEJobCancelCheck = { $true }; try { Invoke-PEExportToolProcess -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 120' } finally { $script:PEJobCancelCheck = $null } } }
        catch { $caught = $_.Exception }
        $caught | Should -BeOfType ([System.OperationCanceledException])
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 30
    }

    It 'does not stop a process whose job is not cancelled' {
        { & (Get-Module PolicyEngine) { $script:PEJobCancelCheck = { $false }; try { Invoke-PEExportToolProcess -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 1' } finally { $script:PEJobCancelCheck = $null } } } | Should -Not -Throw
    }
}
Describe 'Remove-PEExportPart' {
    BeforeEach {
        $script:PartDir = Join-Path $TestDrive ('part-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:PartDir | Out-Null
        Set-Content -LiteralPath (Join-Path $script:PartDir 'export.ps1') -Value 'x'
    }

    It 'removes the folder of a merged part' {
        (& (Get-Module PolicyEngine) { Remove-PEExportPart -PartPath $args[0] } $script:PartDir) | Should -BeTrue
        Test-Path -LiteralPath $script:PartDir | Should -BeFalse
    }

    It 'never throws when a file in it is held by another process (antivirus, indexer): it warns and leaves the folder' {
        $held = [System.IO.File]::Open((Join-Path $script:PartDir 'export.ps1'), 'Open', 'ReadWrite', 'None')
        try
        {
            $result = & (Get-Module PolicyEngine) { Remove-PEExportPart -PartPath $args[0] -Attempts 2 -DelayMilliseconds 10 -WarningVariable w -WarningAction SilentlyContinue; $w } $script:PartDir
            @($result) -join ' ' | Should -BeLike '*not removed*'
        }
        finally { $held.Dispose() }
        Test-Path -LiteralPath $script:PartDir | Should -BeTrue
    }

    It 'tries again, so a file that is released a moment later does not matter' {
        $path = Join-Path $script:PartDir 'export.ps1'
        $held = [System.IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
        $release = Start-ThreadJob -ScriptBlock { Start-Sleep -Milliseconds 600; ($using:held).Dispose() }
        (& (Get-Module PolicyEngine) { Remove-PEExportPart -PartPath $args[0] -Attempts 20 -DelayMilliseconds 200 } $script:PartDir) | Should -BeTrue
        $release | Wait-Job | Remove-Job
        Test-Path -LiteralPath $script:PartDir | Should -BeFalse
    }
}
Describe 'Test-PEExportPartFailed' {
    BeforeEach {
        $script:PartDir = Join-Path $TestDrive ('part-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:PartDir | Out-Null
    }

    It 'is false when the log reports no failed exports' {
        Set-Content -LiteralPath (Join-Path $script:PartDir 'export.log') -Value @('Successful exports: {7}', 'Failed exports: {0}')
        & (Get-Module PolicyEngine) { Test-PEExportPartFailed -PartPath $args[0] } $script:PartDir | Should -BeFalse
    }

    It 'is true when the log reports failed exports' {
        Set-Content -LiteralPath (Join-Path $script:PartDir 'export.log') -Value @('Successful exports: {7}', 'Failed exports: {11}')
        & (Get-Module PolicyEngine) { Test-PEExportPartFailed -PartPath $args[0] } $script:PartDir | Should -BeTrue
    }

    It 'is true when there is no log or no summary line (the export did not finish)' {
        & (Get-Module PolicyEngine) { Test-PEExportPartFailed -PartPath $args[0] } $script:PartDir | Should -BeTrue
        Set-Content -LiteralPath (Join-Path $script:PartDir 'export.log') -Value 'Starting export'
        & (Get-Module PolicyEngine) { Test-PEExportPartFailed -PartPath $args[0] } $script:PartDir | Should -BeTrue
    }
}
