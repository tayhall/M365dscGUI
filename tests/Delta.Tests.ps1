BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force

    function New-TestRecord
    {
        param ([string]$Type, [string]$Key, [hashtable]$Props = @{})
        $p = [ordered]@{ DisplayName = $Key }
        foreach ($k in $Props.Keys) { $p[$k] = $Props[$k] }
        [pscustomobject]@{ ResourceType = $Type; Key = $Key; Workload = 'Entra ID'; TenantId = 'tenant-1'; Properties = $p }
    }

    function New-Finding
    {
        param ([string]$Kind = 'TargetOnly', [string]$Type = 'AADGroup', [string]$Key)
        [pscustomobject]@{ Kind = $Kind; ResourceType = $Type; Key = $Key; Workload = 'Entra ID'; Hint = $null; State = 'Open' }
    }

    function New-FakeProvider
    {
        # A provider whose inventory is the given keys.
        param ([string]$Type = 'AADGroup', [string[]]$Keys)
        $items = @(foreach ($k in $Keys) { @{ Key = $k; Id = [guid]::NewGuid().ToString(); Modified = $null } })
        @{ ResourceType = $Type; GetInventory = { param($App) $items }.GetNewClosure() }
    }

    function New-ExportText
    {
        # A Microsoft365DSC-shaped export holding one AADGroup per display name.
        param ([string[]]$Names, [string]$Type = 'AADGroup')
        $blocks = foreach ($name in $Names)
        {
            $escaped = $name.Replace('`', '``').Replace('"', '`"').Replace('$', '`$')
            @"
        $Type "$Type-$([guid]::NewGuid().ToString('N'))"
        {
            ApplicationId         = `$ConfigurationData.NonNodeData.ApplicationId;
            CertificateThumbprint = `$ConfigurationData.NonNodeData.CertificateThumbprint;
            DisplayName           = "$escaped";
            Ensure                = "Present";
            Id                    = "$([guid]::NewGuid())";
            MailNickname          = "nick";
            SecurityEnabled       = `$True;
            TenantId              = `$ConfigurationData.NonNodeData.TenantId;
        }
"@
        }
        @"
Configuration delta-export
{
    Import-DscResource -ModuleName 'Microsoft365DSC' -ModuleVersion '2.26.1021.1'
    Node localhost
    {
$($blocks -join "`n")
    }
}
"@
    }

    function New-ExportLogText
    {
        # export.log for one component that exported the given number of instances.
        param ([string]$Type, [string[]]$Names, [switch]$Failed)
        $check = [string][char]0x2705
        $redX = [string][char]0x274C
        if ($Failed)
        {
            return "[1/1] Extracting [$Type] using {CertificateThumbprint}...$redX`r`n    An error occurred while exporting resource {$Type}: throttled`r`n"
        }
        if ($Names.Count -eq 0)
        {
            return "[1/1] Extracting [$Type] using {CertificateThumbprint}...$check`r`n"
        }
        $lines = @("[1/1] Extracting [$Type] using {CertificateThumbprint}...")
        for ($i = 1; $i -le $Names.Count; $i++)
        {
            $line = "    |---[$i/$($Names.Count)] $($Names[$i - 1])"
            if ($i -eq $Names.Count) { $line += $check }
            $lines += $line
        }
        return ($lines -join "`r`n") + "`r`n"
    }
}

Describe 'Pinned versions' {
    It 'Data\Versions.psd1 is the single source for the Microsoft365DSC and Graph pins' {
        $pins = Import-PowerShellDataFile "$PSScriptRoot\..\src\PolicyEngine\Data\Versions.psd1"
        $pins.Microsoft365DSC | Should -Match '^\d+\.\d+\.\d+\.\d+$'
        $pins.MicrosoftGraphAuthentication | Should -Match '^\d+\.\d+\.\d+$'
        InModuleScope PolicyEngine -Parameters @{ P = $pins } {
            Get-PEPinnedVersion -Name Microsoft365DSC | Should -Be $P.Microsoft365DSC
            Get-PEPinnedVersion -Name MicrosoftGraphAuthentication | Should -Be $P.MicrosoftGraphAuthentication
        }
        foreach ($file in "$PSScriptRoot\..\src\PolicyEngine\Private\Delta.ps1", "$PSScriptRoot\..\src\PolicyEngine\Private\Graph.ps1", "$PSScriptRoot\..\tools\Export-M365DscTenant.ps1")
        {
            (Get-Content $file -Raw) | Should -Not -Match ([regex]::Escape($pins.Microsoft365DSC))
            (Get-Content $file -Raw) | Should -Not -Match ("'" + [regex]::Escape($pins.MicrosoftGraphAuthentication) + "'")
        }
    }

    It 'the export tool defaults its module version to the shared pin' {
        $tool = "$PSScriptRoot\..\tools\Export-M365DscTenant.ps1"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $tool), [ref]$null, [ref]$null)
        $param = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ModuleVersion' }
        # No parameter default (so the param block can be bound offline); the body reads the pin when unbound.
        $param.DefaultValue | Should -BeNullOrEmpty
        $body = $ast.EndBlock.Extent.Text
        $body | Should -Match 'if \(-not \$ModuleVersion\)'
        $body | Should -Match ([regex]::Escape('Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot ''..\src\PolicyEngine\Data\Versions.psd1'')).Microsoft365DSC'))
    }
}

Describe 'Export-PEDelta' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Temp | Out-Null
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        # The fake export: the given groups in export.ps1 and an Ok export.log.
        $script:ExportNames = @('Sales', 'Finance', "O'Brien Team")
        $script:LogOverride = $null
        $script:Fake = {
            param ([string[]]$Components, [hashtable]$Filters, [string]$OutputPath)
            $script:Calls.Add([pscustomobject]@{ Components = $Components; Filters = $Filters; OutputPath = $OutputPath })
            New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $OutputPath 'export.ps1'), (New-ExportText -Names $script:ExportNames -Type $Components[0]))
            $log = if ($null -ne $script:LogOverride) { $script:LogOverride } else { New-ExportLogText -Type $Components[0] -Names $script:ExportNames }
            if ($log -ne 'none')
            {
                [System.IO.File]::WriteAllText((Join-Path $OutputPath 'export.log'), $log)
            }
            $OutputPath
        }
        Mock -ModuleName PolicyEngine Test-PEResourceFilterSupport {
            $map = [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($t in $ResourceType) { $map[$t] = $true }
            return , $map
        }
    }

    AfterEach {
        if (Test-Path $script:Temp)
        {
            Remove-Item $script:Temp -Recurse -Force
        }
    }

    It 'Export-PEDelta asks for only the requested key' {
        $state = Export-PEDelta -Findings (New-Finding -Key "O'Brien Team") -ExportScript $script:Fake -DataRoot $script:Temp
        $script:Calls.Count | Should -Be 1
        @($script:Calls[0].Components) | Should -Be @('AADGroup')
        $script:Calls[0].Filters.Count | Should -Be 1
        $script:Calls[0].Filters['AADGroup'] | Should -BeExactly "DisplayName eq 'O''Brien Team'"
        @($state.Records).Count | Should -Be 1
        $state.Records[0].Key | Should -BeExactly "O'Brien Team"
        $state.Records[0].Properties.Contains('Id') | Should -BeFalse

        # An injection attempt stays one string literal: every quote is doubled.
        $script:Calls.Clear()
        $script:ExportNames = @("x' or displayName ne '")
        $state = Export-PEDelta -Findings (New-Finding -Key "x' or displayName ne '") -ExportScript $script:Fake -DataRoot $script:Temp
        $script:Calls[0].Filters['AADGroup'] | Should -BeExactly "DisplayName eq 'x'' or displayName ne '''"
        @($state.Records.Key) | Should -Be @("x' or displayName ne '")
    }

    It 'makes one filtered export per requested key' {
        $state = Export-PEDelta -Findings @((New-Finding -Key 'Sales'), (New-Finding -Kind 'Missing' -Key 'Finance')) -ExportScript $script:Fake -DataRoot $script:Temp
        $script:Calls.Count | Should -Be 2
        @($script:Calls.Filters | ForEach-Object { $_['AADGroup'] } | Sort-Object) | Should -Be @("DisplayName eq 'Finance'", "DisplayName eq 'Sales'")
        @($state.Records.Key | Sort-Object) | Should -Be @('Finance', 'Sales')
    }

    It 'Export-PEDelta falls back to the whole type and filters records when the resource has no Filter support' {
        Mock -ModuleName PolicyEngine Test-PEResourceFilterSupport {
            $map = [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($t in $ResourceType) { $map[$t] = $false }
            return , $map
        }
        $state = Export-PEDelta -Findings @((New-Finding -Key 'sales'), (New-Finding -Key 'Finance')) -ExportScript $script:Fake -DataRoot $script:Temp
        $script:Calls.Count | Should -Be 1
        @($script:Calls[0].Components) | Should -Be @('AADGroup')
        $script:Calls[0].Filters.Count | Should -Be 0
        @($state.Records.Key | Sort-Object) | Should -Be @('Finance', 'Sales')
    }

    It 'exports the whole type for a type with no safe filter even if DSC supports Filter' {
        $state = Export-PEDelta -Findings (New-Finding -Type 'AADConditionalAccessPolicy' -Key 'Sales') -ExportScript $script:Fake -DataRoot $script:Temp
        $script:Calls.Count | Should -Be 1
        $script:Calls[0].Filters.Count | Should -Be 0
        @($state.Records).Count | Should -Be 1
        $state.Records[0].ResourceType | Should -Be 'AADConditionalAccessPolicy'
    }

    It 'reports a requested key that is absent from the export' {
        $state = Export-PEDelta -Findings @((New-Finding -Key 'Sales'), (New-Finding -Kind 'Missing' -Key 'Gone')) -ExportScript $script:Fake -DataRoot $script:Temp -WarningVariable warnings -WarningAction SilentlyContinue
        @($state.Records.Key) | Should -Be @('Sales')
        @($state.Meta.NotFound).Count | Should -Be 1
        $state.Meta.NotFound[0].ResourceType | Should -Be 'AADGroup'
        $state.Meta.NotFound[0].Key | Should -Be 'Gone'
        ($warnings -join ' ') | Should -BeLike '*Gone*'
    }

    It 'rejects findings that are not Missing or TargetOnly' -TestCases @(
        @{ Kind = 'Changed' }
        @{ Kind = 'NotChecked' }
        @{ Kind = 'Ambiguous' }
    ) {
        { Export-PEDelta -Findings (New-Finding -Kind $Kind -Key 'Sales') -ExportScript $script:Fake -DataRoot $script:Temp } | Should -Throw "*$Kind*"
        $script:Calls.Count | Should -Be 0
    }

    It 'accepts a target-side PossibleRename (it carries TargetRecord: the object exists in the tenant)' {
        $finding = New-Finding -Kind 'PossibleRename' -Key 'Sales'
        $finding | Add-Member -NotePropertyName TargetRecord -NotePropertyValue ([pscustomobject]@{ Key = 'Sales' })
        $state = Export-PEDelta -Findings $finding -ExportScript $script:Fake -DataRoot $script:Temp
        @($state.Records.Key) | Should -Be @('Sales')
    }

    It 'rejects a blueprint-side PossibleRename (no TargetRecord: the object does not exist in the tenant)' {
        $finding = New-Finding -Kind 'PossibleRename' -Key 'Sales'
        $finding | Add-Member -NotePropertyName BlueprintRecord -NotePropertyValue ([pscustomobject]@{ Key = 'Sales' })
        { Export-PEDelta -Findings $finding -ExportScript $script:Fake -DataRoot $script:Temp } | Should -Throw '*PossibleRename*'
        $script:Calls.Count | Should -Be 0
    }

    It 'throws when the export log marks the type Failed, never returning an empty delta' {
        $script:LogOverride = New-ExportLogText -Type 'AADGroup' -Failed
        { Export-PEDelta -Findings (New-Finding -Key 'Sales') -ExportScript $script:Fake -DataRoot $script:Temp } | Should -Throw '*throttled*'
    }

    It 'throws when the export log is incomplete' {
        $script:LogOverride = "[1/1] Extracting [AADGroup] using {CertificateThumbprint}...`r`n    |---[1/3] Sales`r`n"
        { Export-PEDelta -Findings (New-Finding -Key 'Sales') -ExportScript $script:Fake -DataRoot $script:Temp } | Should -Throw '*incomplete*'
    }

    It 'throws, naming the filter, when a filtered export of an absent object logs no completion mark (seen live)' {
        $script:ExportNames = @()
        $script:LogOverride = "[1/1] Extracting [AADGroup] using {CertificateThumbprint}...\r\n" + [char]0x231B + " Export took {4 seconds} for {0 instances}`r`nSuccessful exports: {1}`r`nFailed exports: {0}`r`n"
        { Export-PEDelta -Findings (New-Finding -Kind 'Missing' -Key 'Gone') -ExportScript $script:Fake -DataRoot $script:Temp } | Should -Throw "*DisplayName eq 'Gone'*may not exist*"
    }

    It 'throws when there is no export log' {
        $script:LogOverride = 'none'
        { Export-PEDelta -Findings (New-Finding -Key 'Sales') -ExportScript $script:Fake -DataRoot $script:Temp } | Should -Throw '*export log*'
    }

    It 'throws when the export log does not mention the type' {
        $script:LogOverride = New-ExportLogText -Type 'AADUser' -Names @('x')
        { Export-PEDelta -Findings (New-Finding -Key 'Sales') -ExportScript $script:Fake -DataRoot $script:Temp } | Should -Throw '*not in export log*'
    }

    It 'has no Role parameter (deltas are exported with the Reader app)' {
        (Get-Command Export-PEDelta).Parameters.Keys | Should -Not -Contain 'Role'
    }
}
