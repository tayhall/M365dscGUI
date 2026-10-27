function Invoke-PERoundTrip
{
    <#
    .SYNOPSIS
    Classifies every resource type of a blueprint by whether DSC's own Test accepts the configuration a Revert would send, against the tenant the
    blueprint came from.

    .DESCRIPTION
    The blueprint was taken from the master, so the configuration a Revert builds from a blueprint record must test as already in its desired
    state in the master. For each resource type this takes up to -PerType records, builds that configuration the way a Revert does (New-PERectifyPlan,
    ConvertTo-PEDscConfig), and asks the Local Configuration Manager to Test it (tools\Invoke-PEApply.ps1 -TestOnly with the Reader app: nothing is
    changed). A type is
      Reliable       every tested instance is in the desired state,
      NeverMatches   no tested instance is: DSC's own Test cannot confirm this type after a Set (the access package is one), so only the drift re-check can,
      Mixed          some are and some are not (volatile or tenant-specific values),
      RenderFailed   the engine could not build the configuration for it (the message says why),
      TestError      the LCM could not test it (chunk failed, timed out, or the resource was not reported).
    -RenderOnly stops after building the configurations (no LCM, no elevation needed): it finds the RenderFailed types quickly.
    The Test needs an elevated session (the LCM). Results are written to <data root>\roundtrip\<time>.json and latest.json and returned.

    .PARAMETER PerType
    Records tested per type (the first by key). Each tested instance costs about 10 to 20 seconds in the LCM.

    .PARAMETER ChunkSize
    Instances per LCM run; a failed or timed-out chunk marks only its own types TestError.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$BlueprintName,

        [ValidatePattern('(?-i)\A[a-z0-9][a-z0-9-]{0,39}\z')]
        [string]$Tenant = 'master',

        [string[]]$Type,

        [ValidateRange(1, 20)]
        [int]$PerType = 1,

        [ValidateRange(1, 200)]
        [int]$ChunkSize = 25,

        [ValidateRange(1, 720)]
        [int]$ChunkTimeoutMinutes = 90,

        [switch]$RenderOnly,

        # Test seam: & $TestScript @{ ConfigPath; ConfigurationName } returns the apply tool's result object.
        [scriptblock]$TestScript,

        [string]$DataRoot
    )

    $root = Get-PEDataRoot -Override $DataRoot
    $blueprint = Get-PEBlueprint -Name $BlueprintName -DataRoot $root
    $version = @(Get-PEBlueprintVersionNumber -Directory (Get-PEBlueprintDirectory -Name $BlueprintName -DataRoot $root))[-1]
    if (-not $RenderOnly -and -not $TestScript -and -not (Test-PEElevated))
    {
        throw 'The Local Configuration Manager needs an elevated session: run this from an elevated PowerShell 7 console (or use -RenderOnly to only build the configurations).'
    }
    $started = [datetime]::UtcNow

    # 1. The records to test: up to -PerType keyed records of each type that is compared (excluded types are not).
    $excluded = Get-PEExcludedTypeMap
    $wanted = if ($Type) { [System.Collections.Generic.HashSet[string]]::new([string[]]$Type, [System.StringComparer]::OrdinalIgnoreCase) } else { $null }
    $results = [ordered]@{}
    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($group in @($blueprint.Records) | Group-Object { [string]$_.ResourceType } | Sort-Object Name)
    {
        if ($wanted -and -not $wanted.Contains($group.Name)) { continue }
        if ($excluded.ContainsKey($group.Name)) { continue }
        $keyed = @($group.Group | Where-Object { -not [string]::IsNullOrEmpty([string]$_.Key) } | Sort-Object { [string]$_.Key } | Select-Object -First $PerType)
        if ($keyed.Count -eq 0)
        {
            $results[$group.Name] = [pscustomobject]@{ ResourceType = $group.Name; Class = 'RenderFailed'; Tested = 0; InDesiredState = 0; WouldChange = 0; Detail = 'No record has a key.' }
            continue
        }
        foreach ($record in $keyed) { $selected.Add($record) }
    }

    # 2. A plan item per record, built as a Revert builds it (every record is a Missing finding against an empty tenant).
    $tenantId = [string](Get-PEMetaValue -Meta $blueprint.Meta -Name 'TenantId')
    $empty = New-PEState -Records @() -NotChecked @() -Meta @{ TenantId = $tenantId; ExportedAt = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); Source = 'round trip' }
    $findings = @(Compare-PEState -Blueprint (New-PEState -Records @($selected) -NotChecked @() -Meta @{ TenantId = $tenantId }) -Target $empty -CrossTenant No -WarningAction SilentlyContinue |
            Where-Object { $_.Kind -eq 'Missing' })
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($finding in $findings)
    {
        try
        {
            foreach ($item in @(New-PERectifyPlan -Findings @($finding) -Action Create -Source $empty -Blueprint $blueprint))
            {
                $items.Add($item)
            }
        }
        catch
        {
            $results[[string]$finding.ResourceType] = [pscustomobject]@{ ResourceType = [string]$finding.ResourceType; Class = 'RenderFailed'; Tested = 0; InDesiredState = 0; WouldChange = 0; Detail = $_.Exception.Message }
        }
    }
    # A type with some records rendered and some not is judged on the ones that rendered.
    foreach ($key in @($results.get_Keys())) { if ($results[$key].Class -eq 'RenderFailed' -and @($items | Where-Object { $_.ResourceType -ieq $key }).Count -gt 0) { $results.Remove($key) } }

    # 3. Build and test the configurations, one chunk at a time.
    $tested = @{}
    $add = { param ($typeName, $status) if (-not $tested.ContainsKey($typeName)) { $tested[$typeName] = [System.Collections.Generic.List[string]]::new() }; $tested[$typeName].Add($status) }
    $chunks = [System.Collections.Generic.List[object]]::new()
    # One workload per LCM run: the module sets of different workloads (Graph, Exchange, Teams, PnP) conflict when they are loaded into one session,
    # which is why the exporter also runs them in separate processes.
    foreach ($workload in @($items | Group-Object { [string]$_.Workload } | Sort-Object Name))
    {
        $group = @($workload.Group)
        for ($i = 0; $i -lt $group.Count; $i += $ChunkSize)
        {
            $chunks.Add(@($group[$i..([Math]::Min($i + $ChunkSize, $group.Count) - 1)]))
        }
    }
    # The LCM stops a Test at its first failing resource and reports one error for the whole run, so a single bad resource would mark every type of
    # its chunk TestError. A failed run is therefore narrowed down: the instances of the failing types are split in halves and each half is tested
    # again, recursively, until the failure is pinned to single instances. When both halves fail with the same error as the whole, it is one cause
    # (for example a module that cannot load) and is recorded for all of them without splitting further.
    $state = @{ Runs = 0 }
    $execute = {
        param ($subset)
        $subsetItems = @($subset)
        $state.Runs++
        $name = "PE_RT_$($state.Runs)"
        $text = ConvertTo-PEDscConfig -Plan $subsetItems -ConfigurationName $name -Target Master
        $configPath = Join-Path ([System.IO.Path]::GetTempPath()) ("pe-roundtrip-{0}-{1}.ps1" -f [guid]::NewGuid().ToString('N'), $state.Runs)
        [System.IO.File]::WriteAllText($configPath, $text, [System.Text.UTF8Encoding]::new($false))
        try
        {
            Write-Progress -Activity 'Round trip' -Status "LCM run $($state.Runs): $($subsetItems.Count) instance(s) of $(@($subsetItems | ForEach-Object { [string]$_.ResourceType } | Sort-Object -Unique).Count) type(s)"
            $run = if ($TestScript) { & $TestScript @{ ConfigPath = $configPath; ConfigurationName = $name } } else { Invoke-PERoundTripTool -ConfigPath $configPath -ConfigurationName $name -Tenant $Tenant -TimeoutMinutes $ChunkTimeoutMinutes }
        }
        finally
        {
            Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
        }
        $rows = @($run.Resources | Where-Object { $null -ne $_ })
        $statuses = @{}
        $failedTypes = [System.Collections.Generic.List[string]]::new()
        foreach ($typeName in @($subsetItems | ForEach-Object { [string]$_.ResourceType } | Sort-Object -Unique))
        {
            $typeRows = @($rows | Where-Object { [string]$_.ResourceType -ieq $typeName -and [string]$_.Status -in 'InDesiredState', 'WouldChange' })
            if ($typeRows.Count -eq 0) { $failedTypes.Add($typeName) } else { $statuses[$typeName] = @($typeRows | ForEach-Object { [string]$_.Status }) }
        }
        return @{
            Items       = $subsetItems
            Error       = $(if ($run.Error) { [string]$run.Error } else { 'not reported by the LCM' })
            Statuses    = $statuses
            FailedTypes = @($failedTypes)
            Failed      = ($failedTypes.Count -gt 0)
            AllFailed   = ($statuses.Count -eq 0)
        }
    }
    $resolve = {
        param ($result)
        foreach ($typeName in @($result.Statuses.get_Keys())) { foreach ($status in $result.Statuses[$typeName]) { & $add $typeName $status } }
        if (-not $result.Failed) { return }
        $failedItems = @($result.Items | Where-Object { $result.FailedTypes -contains [string]$_.ResourceType })
        if ($failedItems.Count -le 1)
        {
            foreach ($item in $failedItems) { & $add ([string]$item.ResourceType) "Error:$($result.Error)" }
            return
        }
        $half = [int][Math]::Ceiling($failedItems.Count / 2)
        $left = & $execute @($failedItems[0..($half - 1)])
        $right = & $execute @($failedItems[$half..($failedItems.Count - 1)])
        if ($left.AllFailed -and $right.AllFailed -and $left.Error -ceq $result.Error -and $right.Error -ceq $result.Error)
        {
            foreach ($item in $failedItems) { & $add ([string]$item.ResourceType) "Error:$($result.Error)" }
            return
        }
        & $resolve $left
        & $resolve $right
    }
    foreach ($chunk in $chunks)
    {
        $chunkItems = @($chunk)
        try
        {
            $null = ConvertTo-PEDscConfig -Plan $chunkItems -ConfigurationName 'PE_RT_CHECK' -Target Master
        }
        catch
        {
            # One bad item must not hide the rest: build them one at a time to find it.
            $good = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $chunkItems)
            {
                try { $null = ConvertTo-PEDscConfig -Plan @($item) -ConfigurationName 'PE_RT_CHECK' -Target Master; $good.Add($item) }
                catch { $results[[string]$item.ResourceType] = [pscustomobject]@{ ResourceType = [string]$item.ResourceType; Class = 'RenderFailed'; Tested = 0; InDesiredState = 0; WouldChange = 0; Detail = $_.Exception.Message } }
            }
            $chunkItems = @($good)
        }
        if ($chunkItems.Count -eq 0) { continue }
        if ($RenderOnly)
        {
            foreach ($item in $chunkItems) { if (-not $results.Contains([string]$item.ResourceType)) { & $add ([string]$item.ResourceType) 'Rendered' } }
            continue
        }
        & $resolve (& $execute $chunkItems)
    }
    Write-Progress -Activity 'Round trip' -Completed

    # 4. Classify.
    foreach ($typeName in @($tested.get_Keys() | Sort-Object))
    {
        if ($results.Contains($typeName)) { continue }
        $statuses = @($tested[$typeName])
        $ok = @($statuses | Where-Object { $_ -eq 'InDesiredState' }).Count
        $changed = @($statuses | Where-Object { $_ -eq 'WouldChange' }).Count
        $errors = @($statuses | Where-Object { $_ -like 'Error:*' })
        $class = if ($RenderOnly) { 'Rendered' } elseif ($errors.Count -gt 0 -and $ok + $changed -eq 0) { 'TestError' } elseif ($changed -eq 0 -and $ok -gt 0) { 'Reliable' } elseif ($ok -eq 0 -and $changed -gt 0) { 'NeverMatches' } else { 'Mixed' }
        $results[$typeName] = [pscustomobject]@{ ResourceType = $typeName; Class = $class; Tested = $ok + $changed; InDesiredState = $ok; WouldChange = $changed; Detail = $(if ($errors.Count -gt 0) { ($errors | Select-Object -First 1) -replace '^Error:', '' } else { $null }) }
    }
    $list = @($results.get_Values() | Sort-Object ResourceType)

    $document = [ordered]@{
        Tenant           = $Tenant
        BlueprintName    = $BlueprintName
        BlueprintVersion = $version
        ModuleVersion    = (Get-PEPinnedVersion -Name Microsoft365DSC)
        PerType          = $PerType
        RenderOnly       = [bool]$RenderOnly
        StartedAt        = $started.ToString('yyyy-MM-ddTHH:mm:ssZ')
        FinishedAt       = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        Summary          = @($list | Group-Object Class | Sort-Object Name | ForEach-Object { [ordered]@{ Class = $_.Name; Types = $_.Count } })
        Types            = $list
    }
    $stamp = $started.ToString('yyyyMMdd-HHmmss')
    Write-PEJson -Path (Join-Path $root "roundtrip\$stamp.json") -InputObject $document
    if (-not $RenderOnly)
    {
        Write-PEJson -Path (Join-Path $root 'roundtrip\latest.json') -InputObject $document
    }
    return $list
}
