# Helpers for Public\Invoke-PERectify.ps1: the default apply (tools\Invoke-PEApply.ps1 in a child pwsh), the checks of
# an apply result against the plan, the default recheck (Export-PEDelta with the Reader app), the Promote blueprint
# update, and redaction of the app identifiers from everything returned.

function Get-PERectifyRedaction
{
    # Values that must never appear in anything Invoke-PERectify returns, warns or writes: the certificate thumbprints
    # and application ids of the Reader and Writer apps (from ~\.m365dsc-policy\M365DSC-Policy-<Role>.json). A
    # function so tests can inject recognisable values.
    [CmdletBinding()]
    [OutputType([string[]])]
    param ()

    $values = [System.Collections.Generic.List[string]]::new()
    # The app files of every tenant: ~\.m365dsc-policy\M365DSC-Policy-<Role>.json and ~\.m365dsc-policy\<slug>\...
    $files = @(Get-ChildItem -LiteralPath (Join-Path $HOME '.m365dsc-policy') -Recurse -Filter 'M365DSC-Policy-*.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^M365DSC-Policy-(Reader|Writer)\.json$' })
    foreach ($file in $files)
    {
        $path = $file.FullName
        try
        {
            $info = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        }
        catch
        {
            continue
        }
        foreach ($name in 'Thumbprint', 'ApplicationId')
        {
            $value = [string]$info.$name
            if ($value.Length -ge 8)
            {
                $values.Add($value)
            }
        }
    }
    return , $values.ToArray()
}

function Protect-PERectifyText
{
    # Replaces every redaction value (case-insensitive) with '<redacted>'.
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Values
    )

    if ([string]::IsNullOrEmpty($Text))
    {
        return $Text
    }
    foreach ($value in @($Values))
    {
        if (-not [string]::IsNullOrEmpty($value))
        {
            $Text = [regex]::Replace($Text, [regex]::Escape($value), '<redacted>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
    }
    return $Text
}

function Protect-PERectifyObject
{
    # A redacted copy of a plain-data object (an apply result): serialised, redacted, read back.
    [CmdletBinding()]
    param
    (
        [AllowNull()]
        $InputObject,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Values
    )

    if ($null -eq $InputObject)
    {
        return $null
    }
    $json = ConvertTo-Json -InputObject $InputObject -Depth 10 -Compress -WarningAction SilentlyContinue
    return (Protect-PERectifyText -Text $json -Values $Values) | ConvertFrom-Json -Depth 10 -DateKind String
}

function ConvertFrom-PEApplyToolOutput
{
    <#
    .SYNOPSIS
    The result object of a tools\Invoke-PEApply.ps1 -Json run, from its STDOUT lines, its exit code and (for
    diagnostics only) its stderr lines.

    .DESCRIPTION
    The result is the LAST stdout line that parses as a JSON object with the tool's fields (Success and Resources);
    the tool prints warnings before it. Stderr is never parsed for the result (a Graph error body or any other JSON
    there must not replace the tool's own result); its text, capped, goes into StdErr when the exit code is not 0 or
    no result was found. Exit code 0 = Success, 2 = the compile or a resource failed (the JSON says which), 1 = a
    guard or start-up failure before anything ran (no JSON). Without a result: exit code 1 gives PartiallyApplied
    $false (nothing ran); any other exit code gives PartiallyApplied $null (unknown: something may have been
    applied). A result that disagrees with the exit code is marked failed.
    #>
    [CmdletBinding()]
    param
    (
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Lines,

        [Parameter(Mandatory)]
        [int]$ExitCode,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$ErrorLines
    )

    $text = @($Lines | Where-Object { $null -ne $_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $result = $null
    for ($n = $text.Count - 1; $n -ge 0 -and $null -eq $result; $n--)
    {
        if (-not $text[$n].StartsWith('{'))
        {
            continue
        }
        try
        {
            $candidate = $text[$n] | ConvertFrom-Json -Depth 10 -DateKind String
        }
        catch
        {
            continue
        }
        if ($candidate -is [System.Management.Automation.PSCustomObject] -and
            $candidate.PSObject.Properties['Success'] -and $candidate.PSObject.Properties['Resources'])
        {
            $result = $candidate
        }
    }
    $errorText = (@($ErrorLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }) -join ' | ')
    if ($errorText.Length -gt 2000)
    {
        $errorText = $errorText.Substring(0, 2000) + ' ...'
    }
    if ($null -eq $result)
    {
        $tail = (@($text | Select-Object -Last 5) -join ' | ')
        $what = if ($ExitCode -eq 1) { 'refused before applying anything (guard or start-up failure)' } else { 'ended without a result; what was applied is UNKNOWN' }
        return [pscustomobject]@{
            Success          = $false
            TestOnly         = $false
            PartiallyApplied = $(if ($ExitCode -eq 1) { $false } else { $null })
            ResourceCount    = 0
            Error            = "The apply tool $what (exit code $ExitCode): $tail"
            StdErr           = $(if ($errorText) { $errorText } else { $null })
            Resources        = @()
        }
    }
    if ($ExitCode -ne 0 -and $errorText)
    {
        $result | Add-Member -NotePropertyName StdErr -NotePropertyValue $errorText -Force
    }
    $expectedExit = if ($result.Success -eq $true) { 0 } else { 2 }
    if ($ExitCode -ne $expectedExit)
    {
        $message = "The apply tool exited with code $ExitCode but its result says Success = $($result.Success)."
        $result.Success = $false
        if ($result.PSObject.Properties['Error'])
        {
            $result.Error = (@($result.Error, $message) | Where-Object { $_ }) -join ' '
        }
        else
        {
            $result | Add-Member -NotePropertyName Error -NotePropertyValue $message
        }
    }
    return $result
}
function Get-PERectifyPwshPath
{
    # The pwsh of THIS installation (not whatever 'pwsh' is first on PATH).
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    $name = if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') { 'pwsh.exe' } else { 'pwsh' }
    $path = Join-Path $PSHOME $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf))
    {
        throw "PowerShell 7 executable not found at $path."
    }
    return $path
}

function Invoke-PEChildProcess
{
    <#
    .SYNOPSIS
    Runs a process with stdout and stderr redirected (read asynchronously, so a full pipe cannot deadlock it) and a
    timeout; on timeout the whole process tree is killed. Returns ProcessId, ExitCode ($null on timeout), StdOut
    and StdErr (non-empty lines of each, kept apart) and TimedOut.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ArgumentList,

        [Parameter(Mandatory)]
        [ValidateRange(0.1, 86400)]
        [double]$TimeoutSeconds
    )

    $info = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($argument in $ArgumentList)
    {
        $info.ArgumentList.Add($argument)
    }
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    $info.CreateNoWindow = $true
    $info.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    try
    {
        [void]$process.Start()
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit([int][math]::Min([int]::MaxValue, $TimeoutSeconds * 1000))
        if ($timedOut)
        {
            try
            {
                $process.Kill($true)
            }
            catch
            {
                # Reported by the caller as an unknown apply state; a warning here could throw under -WarningAction Stop.
                $null = $_
            }
            [void]$process.WaitForExit(30000)
        }
        else
        {
            # Also waits for the redirected streams to reach end of file.
            $process.WaitForExit()
        }
        $streams = foreach ($task in $stdout, $stderr)
        {
            $lines = if ($task.Wait(30000)) { @($task.Result -split '\r?\n' | Where-Object { $_ -ne '' }) } else { @() }
            , [string[]]$lines
        }
        [pscustomobject]@{
            ProcessId = $process.Id
            ExitCode  = $(if ($timedOut) { $null } else { $process.ExitCode })
            StdOut    = $streams[0]
            StdErr    = $streams[1]
            TimedOut  = $timedOut
        }
    }
    finally
    {
        $process.Dispose()
    }
}

function Invoke-PERectifyApplyTool
{
    # The default apply: tools\Invoke-PEApply.ps1 in a child pwsh (this installation's) with the Writer app (for every
    # target), -Json, with a timeout after which the child's process tree is killed. The tool writes and deletes its
    # own thumbprint-bearing configuration data and MOF. Exit code 1 without JSON = nothing ran (a guard) or the child
    # failed to start.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [int]$ExpectedResourceCount,

        [Parameter(Mandatory)]
        [string]$ConfigurationName,

        [ValidateRange(1, 720)]
        [int]$TimeoutMinutes = 10,

        [string]$Tenant = 'master'
    )

    $tool = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'tools\Invoke-PEApply.ps1'
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-File', $tool, '-ConfigPath', $ConfigPath, '-ConfigurationName', $ConfigurationName,
        '-ExpectedResourceCount', [string]$ExpectedResourceCount, '-Role', 'Writer', '-Json'
    )
    if ($Tenant -ne 'master') { $arguments += @('-AppInfoPath', (Get-PEAppInfoPath -Role Writer -Tenant $Tenant)) }
    $run = Invoke-PEChildProcess -FilePath (Get-PERectifyPwshPath) -ArgumentList $arguments -TimeoutSeconds ($TimeoutMinutes * 60)
    if ($run.TimedOut)
    {
        return [pscustomobject]@{
            Success          = $false
            TestOnly         = $false
            TimedOut         = $true
            PartiallyApplied = $null
            ResourceCount    = 0
            Error            = "The apply did not finish within $TimeoutMinutes minutes; its process tree was killed. What was applied is unknown."
            Resources        = @()
        }
    }
    return (ConvertFrom-PEApplyToolOutput -Lines $run.StdOut -ErrorLines $run.StdErr -ExitCode $run.ExitCode)
}

function Get-PERectifyWriterApp
{
    # The Writer app details, read and validated by the same helper the apply tool uses (Get-PEApplyApp in
    # tools\PEApply.Common.ps1), so the tenant checked here is the tenant the apply will use.
    [CmdletBinding()]
    param
    (
        [string]$Tenant = 'master'
    )

    . (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'tools\PEApply.Common.ps1')
    return (Get-PEApplyApp -Role Writer -Path (Get-PEAppInfoPath -Role Writer -Tenant $Tenant))
}

function Assert-PERectifyTenant
{
    # Every item's check state must come from the Writer app's tenant (case-insensitive); an unknown tenant is refused.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [object[]]$Items,

        [Parameter(Mandatory)]
        [string]$TenantId
    )

    foreach ($item in $Items)
    {
        $tenant = if ($null -ne $item.SourceIdentity) { [string]$item.SourceIdentity.TenantId } else { '' }
        $label = "$($item.Action) $($item.ResourceType) '$($item.Key)'"
        if ([string]::IsNullOrWhiteSpace($tenant) -or $tenant -ieq 'unknown')
        {
            throw "Refusing $label`: its check state has no known tenant, so it cannot be bound to the Writer app's tenant ($TenantId)."
        }
        if ($tenant -ine $TenantId)
        {
            throw "Refusing $label`: it was planned from tenant '$tenant', but the Writer app applies to '$TenantId'."
        }
    }
}

# Plan items whose real apply has started in this process (by reference). They are also removed from the plan registry,
# so ConvertTo-PEDscConfig and Save-PEAudit refuse them; this table only gives the clearer message.
$script:PEAppliedPlanItems = [System.Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()

function Assert-PERectifyPlanUnused
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [object[]]$Items
    )

    foreach ($item in $Items)
    {
        $entry = $null
        if ($item -is [System.Management.Automation.PSObject] -and $script:PEAppliedPlanItems.TryGetValue($item, [ref]$entry))
        {
            throw "plan already applied; make a new plan ($($item.Action) $($item.ResourceType) '$($item.Key)' was applied at $entry)."
        }
    }
}

function Complete-PERectifyPlanUse
{
    # Consumes plan items once a real apply is launched: never usable again in this session.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [object[]]$Items
    )

    $at = (Get-PEUtcNow).ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [cultureinfo]::InvariantCulture)
    foreach ($item in $Items)
    {
        $script:PEAppliedPlanItems.AddOrUpdate($item, $at)
        [void]$script:PEPlanRegistry.Remove($item)
    }
}

function Assert-PERectifyAuditIntact
{
    # Before launching: the saved config.ps1 must be byte for byte what plan.json's ConfigSha256 records, its text
    # exactly the generated configuration, and that text still registered for this plan. Throws otherwise.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$AuditPath,

        [Parameter(Mandatory)]
        [string]$Config,

        [Parameter(Mandatory)]
        [string]$PlanFingerprint
    )

    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $AuditPath 'config.ps1'))
    $recorded = [string](Read-PEJson -Path (Join-Path $AuditPath 'plan.json')).ConfigSha256
    if ((Get-PETextSha256 -Bytes $bytes) -cne $recorded)
    {
        throw "The saved config.ps1 in $AuditPath does not match plan.json's ConfigSha256; refusing to apply (nothing was applied)."
    }
    $encoding = [System.Text.UTF8Encoding]::new($true, $true)
    $preamble = $encoding.GetPreamble()
    $offset = if ($bytes.Length -ge 3 -and $bytes[0] -eq $preamble[0] -and $bytes[1] -eq $preamble[1] -and $bytes[2] -eq $preamble[2]) { 3 } else { 0 }
    $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
    if ($text -cne $Config -or $null -eq (Get-PEDscConfigRegistration -Text $text -PlanFingerprint $PlanFingerprint))
    {
        throw "The saved config.ps1 in $AuditPath is not the configuration generated for this plan; refusing to apply (nothing was applied)."
    }
}
function Test-PERectifyApplyResult
{
    <#
    .SYNOPSIS
    The problems that make an apply result unacceptable for this plan (empty when it is acceptable).

    .DESCRIPTION
    Required: Success true, not test-only, exactly one resource row per plan item, the multiset of ResourceTypes equal
    to the plan's (the apply tool only bounds the count), and every row Applied or InDesiredState.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param
    (
        [AllowNull()]
        $Result,

        [Parameter(Mandatory)]
        [object[]]$Items
    )

    $problems = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Result)
    {
        $problems.Add('The apply returned no result.')
        return , $problems.ToArray()
    }
    if ($Result.Success -ne $true)
    {
        $problems.Add("The apply reported failure: $($Result.Error)")
    }
    if ($Result.PSObject.Properties['TestOnly'] -and $Result.TestOnly -eq $true)
    {
        $problems.Add('The apply ran in test-only mode; nothing was set.')
    }
    $resources = @($Result.Resources | Where-Object { $null -ne $_ })
    if ($resources.Count -ne $Items.Count)
    {
        $problems.Add("The apply reported $($resources.Count) resources for $($Items.Count) plan items.")
    }
    $planned = [System.Collections.Generic.List[string]]::new([string[]]@($Items | ForEach-Object { ([string]$_.ResourceType).ToLowerInvariant() }))
    $applied = [System.Collections.Generic.List[string]]::new([string[]]@($resources | ForEach-Object { ([string]$_.ResourceType).ToLowerInvariant() }))
    $planned.Sort([System.StringComparer]::Ordinal)
    $applied.Sort([System.StringComparer]::Ordinal)
    if (($planned -join ',') -cne ($applied -join ','))
    {
        $problems.Add("The apply reported resource types [$($applied -join ', ')] for planned types [$($planned -join ', ')].")
    }
    foreach ($resource in $resources)
    {
        if ([string]$resource.Status -notin 'Applied', 'InDesiredState')
        {
            $problems.Add("$($resource.ResourceId): $($resource.Status)$(if ($resource.Error) { " ($($resource.Error))" })")
        }
    }
    return , $problems.ToArray()
}

function Invoke-PERectifyRecheck
{
    <#
    .SYNOPSIS
    The default recheck after an apply: re-exports the planned objects (Reader app, Export-PEDelta) and returns the
    differences from the plan as findings; empty when the tenant now matches the plan.

    .DESCRIPTION
    Create, Update and Promote items: a (filtered) delta export of those keys, compared with Compare-PEState against a
    synthetic desired state made of exactly the planned records, so a difference is a Changed finding and an object
    that is not there a Missing finding. Remove items: the WHOLE type is exported (a filtered export of an object that
    no longer exists logs no completion mark and throws Incomplete by design), and a key still present is a TargetOnly
    finding. The decisions in -DataRoot (Get-PEDecision) are applied as in a check, so Noise rules hide what they cover.
    -ExportScript is passed to Export-PEDelta (tests).
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [object[]]$Items,

        [scriptblock]$ExportScript,

        [string]$Tenant = 'master',

        [string]$DataRoot,

        # Passed to Compare-PEState: Yes when the tenant is not the one the blueprint came from.
        [ValidateSet('Auto', 'Yes', 'No')]
        [string]$CrossTenant = 'Auto'
    )

    $common = @{}
    if ($ExportScript)
    {
        $common['ExportScript'] = $ExportScript
    }
    $common['Tenant'] = $Tenant
    if ($DataRoot)
    {
        $common['DataRoot'] = $DataRoot
    }
    $present = @($Items | Where-Object { $_.Action -in 'Create', 'Update', 'Promote' })
    $removed = @($Items | Where-Object { $_.Action -eq 'Remove' })
    $records = [System.Collections.Generic.List[object]]::new()
    if ($present.Count -gt 0)
    {
        $requests = foreach ($item in $present)
        {
            [pscustomobject]@{ Kind = 'TargetOnly'; ResourceType = [string]$item.ResourceType; Key = [string]$item.Key }
        }
        $state = Export-PEDelta -Findings @($requests) @common -WarningAction SilentlyContinue
        foreach ($record in @($state.Records))
        {
            $records.Add($record)
        }
    }
    if ($removed.Count -gt 0)
    {
        $requests = foreach ($item in $removed)
        {
            [pscustomobject]@{ Kind = 'TargetOnly'; ResourceType = [string]$item.ResourceType; Key = [string]$item.Key }
        }
        # Absent keys are the expected outcome here, so Export-PEDelta's not-found warnings are suppressed.
        $state = Export-PEDelta -Findings @($requests) -WholeType @common -WarningAction SilentlyContinue
        foreach ($record in @($state.Records))
        {
            $records.Add($record)
        }
    }
    # ExportedAt = now: a conditional ignore path (When = PastExport) then ignores in the planned records exactly what
    # is in the past at recheck time, as it does in the fresh export.
    $desired = New-PEState -Records @($present | ForEach-Object { $_.Record }) -NotChecked @() -Meta @{ Source = 'rectify plan'; ExportedAt = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $actual = New-PEState -Records $records.ToArray() -NotChecked @() -Meta @{ Source = 'rectify recheck' }
    # The same decisions as a check: accepted-noise rules hide the differences they cover.
    $decisions = @(Get-PEDecision -DataRoot $DataRoot -Tenant $Tenant)
    # The planned types are compared even if Data\ExcludedTypes.psd1 lists them: the plan names exactly these objects.
    $plannedTypes = @($Items | ForEach-Object { [string]$_.ResourceType } | Sort-Object -Unique)
    return , @(Compare-PEState -Blueprint $desired -Target $actual -Decisions $decisions -IncludeTypes $plannedTypes -CrossTenant $CrossTenant)
}

function Assert-PERectifyBlueprintVersion
{
    # Throws unless every item was planned against the latest version of the blueprint. A version document without
    # Meta.Version is version 1 (Initialize-PEBlueprint writes none; Approve-PEBlueprintChange writes it from v2 on).
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [object[]]$Items,

        [Parameter(Mandatory)]
        [string]$Name,

        [string]$DataRoot
    )

    $directory = Get-PEBlueprintDirectory -Name $Name -DataRoot $DataRoot
    $numbers = @(Get-PEBlueprintVersionNumber -Directory $directory)
    if ($numbers.Count -eq 0)
    {
        throw "Blueprint '$Name' not found under $directory."
    }
    $latest = [int]$numbers[-1]
    $latestState = Get-PEBlueprint -Name $Name -Version ([string]$latest) -DataRoot $DataRoot
    $latestExportedAt = [string](Get-PEMetaValue -Meta $latestState.Meta -Name 'ExportedAt')
    foreach ($item in $Items)
    {
        $identity = $item.SourceIdentity
        $label = "$($item.Action) $($item.ResourceType) '$($item.Key)'"
        if ($null -eq $identity)
        {
            throw "blueprint changed since the plan was made; re-run the check ($label records no blueprint version)."
        }
        $planned = if ($null -ne $identity.BlueprintVersion) { [int]$identity.BlueprintVersion } else { 1 }
        if ($planned -ne $latest)
        {
            throw "blueprint changed since the plan was made; re-run the check ($label was planned against version $planned of '$Name'; the latest is $latest)."
        }
        $plannedExportedAt = [string]$identity.BlueprintExportedAt
        if ($plannedExportedAt -and $latestExportedAt -and $plannedExportedAt -cne $latestExportedAt)
        {
            throw "blueprint changed since the plan was made; re-run the check ($label was planned against a blueprint exported at $plannedExportedAt; version $latest of '$Name' was exported at $latestExportedAt)."
        }
    }
}

function Update-PERectifyBlueprint
{
    <#
    .SYNOPSIS
    After a Promote: writes the next blueprint version with exactly the promoted records added. Returns the version.

    .DESCRIPTION
    The master state is the latest blueprint plus the promoted records, so the inverted comparison
    (Get-PEBlueprintChange) yields a Missing finding for each promoted key and nothing else for them; exactly those
    findings are accepted with Approve-PEBlueprintChange, citing Reason. Throws if any promoted key does not come out
    as exactly one Missing finding.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [object[]]$Items,

        [Parameter(Mandatory)]
        [string]$Reason,

        [string]$DataRoot
    )

    $promoted = @($Items | Where-Object { $_.Action -eq 'Promote' })
    $current = Get-PEBlueprint -Name $Name -DataRoot $DataRoot
    $wanted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($item in $promoted)
    {
        [void]$wanted.Add((Get-PEMatchKey -ResourceType ([string]$item.ResourceType) -Key ([string]$item.Key)))
    }
    # The master state's export time (recorded by Approve-PEBlueprintChange as MasterExportedAt) is the latest
    # export time of the plan sources of the promoted items: that is the state the promoted records were read from.
    $exportedAt = @($promoted | ForEach-Object { [string]$_.SourceIdentity.ExportedAt } | Where-Object { $_ } | Sort-Object)[-1]
    $masterMeta = @{}
    if ($exportedAt)
    {
        $masterMeta['ExportedAt'] = $exportedAt
    }
    $master = New-PEState -Records @(@($current.Records) + @($promoted | ForEach-Object { $_.Record })) -NotChecked @($current.NotChecked) -Meta $masterMeta
    $changes = @(Get-PEBlueprintChange -Name $Name -MasterState $master -DataRoot $DataRoot)
    $accept = @($changes | Where-Object {
            $_.Kind -eq 'Missing' -and -not [string]::IsNullOrEmpty([string]$_.Key) -and
            $wanted.Contains((Get-PEMatchKey -ResourceType ([string]$_.ResourceType) -Key ([string]$_.Key)))
        })
    if ($accept.Count -ne $wanted.Count)
    {
        $kinds = (@($changes | Where-Object { -not [string]::IsNullOrEmpty([string]$_.Key) -and $wanted.Contains((Get-PEMatchKey -ResourceType ([string]$_.ResourceType) -Key ([string]$_.Key))) } |
                    ForEach-Object { "$($_.Kind) $($_.ResourceType) '$($_.Key)'" }) -join ', ')
        throw "The promoted items do not come out as new blueprint records (found: $(if ($kinds) { $kinds } else { 'nothing' }))."
    }
    return (Approve-PEBlueprintChange -Name $Name -MasterState $master -Accept $accept -Reason $Reason -DataRoot $DataRoot)
}
