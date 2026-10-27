function Invoke-PEGuiRequest
{
    <#
    .SYNOPSIS
    Processes the action requests the web GUI queued (activity\J-*.json with status Queued, written next to
    requests\<id>.json) and writes each job's outcome back, then refreshes the view models.

    .DESCRIPTION
    Runs only what is safe without touching a tenant:
    - Exclude (TargetOnly items) -> Set-PEDecision Unmanaged; ExcludeProperty -> Noise; Unexclude -> Remove-PEDecision.
    - Promote -> Approve-PEBlueprintChange: a blueprint-only change from the latest Full check (it writes a local
      blueprint version, never a tenant). Promote from a replica would write to the master and is refused, as is
      Promote of a Possible rename (Approve-PEBlueprintChange refuses it).
    - Accept restores the tenant to the blueprint (Create for Missing, Update for Changed, Remove for TargetOnly) with
      Invoke-PERectify in this process: Writer app, re-check with the Reader app. It needs confirmedMasterWrite in the
      request. After a clean re-check a patched copy of the check is saved (New-PEPatchedCheck) so the GUI shows the
      items aligned; a real full check replaces it. Possible renames are refused.
    - RevertBlueprint: the engine has no revert command yet; the job fails with that message.
    - GenerateConfig -> New-PEOfflineConfig: the configuration that brings the tenant in line with its own blueprint, written to
      <GuiRoot>\configs\<jobId> (Changes.ps1, Removals.ps1, Manual.json) for the tenant's owner to download and run. No tenant is
      written to.
    Each job is marked Running, then Succeeded or Failed with a result text. Jobs the mock timer owns (mock = true)
    are left alone. Files are replaced atomically, under the same named mutex the GUI uses for the folder.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$BlueprintName,

        [string]$DataRoot,

        [string]$GuiRoot,

        [ValidatePattern('^J-\d+$')]
        [string]$JobId,

        # Seams for tests: passed to Invoke-PERectify for Accept. The defaults apply with the Writer app and re-check with the Reader app.
        [scriptblock]$ApplyScript,

        [scriptblock]$RecheckScript,

        # Test seam for Recheck: replaces the Reader-app export of Invoke-PEFullCheck.
        [scriptblock]$ExportScript
    )

    $root = Get-PEDataRoot -Override $DataRoot
    if (-not $GuiRoot)
    {
        $GuiRoot = Join-Path $root 'gui'
    }
    $GuiRoot = [System.IO.Path]::GetFullPath($GuiRoot)
    $guiPrefix = $GuiRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar

    $readJson = {
        param($relative)
        $path = Join-Path $GuiRoot $relative
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -NoEnumerate -DateKind String
    }
    $locked = {
        param($block)
        $hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($guiPrefix)))
        $mutex = [System.Threading.Mutex]::new($false, "PEGui-$($hash.Substring(0, 32))")
        $held = $false
        try
        {
            try { $held = $mutex.WaitOne([TimeSpan]::FromSeconds(10)) } catch [System.Threading.AbandonedMutexException] { $held = $true }
            if (-not $held) { throw 'The GUI data folder is busy; try again.' }
            & $block
        }
        finally
        {
            if ($held) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    }
    $writeJob = {
        param($job)
        $path = Join-Path $GuiRoot "activity\$($job.jobId).json"
        $temp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
        [System.IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $job -Depth 20), [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($temp, $path, $true)
    }
    # The worker shows that it is alive: its process id, the time and the job it is running, in activity\worker.json, on every pass
    # and while an export runs. The GUI uses it to tell a job nobody is running (its worker is gone or was restarted; only the
    # server can mark it Cancelled) from one a live worker can be asked to stop.
    $running = @{ JobId = $null }
    $beat = {
        $folder = Join-Path $GuiRoot 'activity'
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        $path = Join-Path $folder 'worker.json'
        $temp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
        [System.IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject ([ordered]@{ pid = $PID; at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); jobId = $running.JobId }) -Depth 3), [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($temp, $path, $true)
    }
    & $beat
    $setActive = {
        param($finishedId)
        & $locked {
            $ids = @(& $readJson 'activity\active.json' | Where-Object { $_ -cmatch '^J-\d+$' -and $_ -ne $finishedId })
            $path = Join-Path $GuiRoot 'activity\active.json'
            $temp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
            [System.IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject @($ids) -Depth 5), [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::Move($temp, $path, $true)
        }
    }

    $activity = Join-Path $GuiRoot 'activity'
    $queued = @()
    if (Test-Path -LiteralPath $activity)
    {
        $queued = @(Get-ChildItem -LiteralPath $activity -Filter 'J-*.json' | Sort-Object { [int]($_.BaseName -replace '\D', '') } | ForEach-Object {
                $job = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -DateKind String
                if ($job.status -eq 'Queued' -and $job.mock -ne $true -and (-not $JobId -or $job.jobId -eq $JobId)) { $job }
            })
    }

    $refresh = $false
    foreach ($job in $queued)
    {
        # Queued to Running under the lock the server holds to cancel, so the two cannot interleave: a cancel lands before this (the
        # job is skipped) or after it (the job is Running and the rules for cancelling a running job apply). A cancel is never
        # overwritten by this write.
        $claimed = & $locked {
            $latest = & $readJson "activity\$($job.jobId).json"
            if ($null -eq $latest -or $latest.status -ne 'Queued') { return $false }
            $job.status = 'Running'
            $job.updatedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
            & $writeJob $job
            $true
        }
        if (-not $claimed) { continue }
        $running.JobId = $job.jobId
        & $beat
        Write-Host ('{0:HH:mm:ss} {1} {2}: running' -f (Get-Date), $job.jobId, $job.action)

        # A long job (Connect tenant waits for a sign-in) can show its progress in the job while it runs.
        $progress = { param ($text) $job.result = $text; $job.updatedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); & $writeJob $job }
        # While a long export runs, Invoke-PEExportToolProcess asks this whether the user pressed Cancel (and so keeps the heartbeat).
        # Only a Recheck can be stopped: it reads a tenant and writes nothing to it. Anything that changes a tenant or a blueprint
        # is never killed partway, whatever the job file says.
        if ($job.action -eq 'Recheck')
        {
            $script:PEJobCancelCheck = {
                & $beat
                $now = & $readJson "activity\$($job.jobId).json"
                $null -ne $now -and ($now.status -eq 'Cancelled' -or $now.cancelRequested -eq $true)
            }.GetNewClosure()
        }
        try
        {
            if ($job.requestId -notmatch '^[0-9T-]+-[0-9a-f]{4}$') { throw "Job $($job.jobId) has no valid request id." }
            $request = & $readJson "requests\$($job.requestId).json"
            if ($null -eq $request) { throw "Request $($job.requestId) not found." }
            $role = [string](@((& $readJson 'index.json').tenants | Where-Object { $_.tenantId -ceq [string]$request.tenantId }) | Select-Object -First 1).role
            $outcome = Invoke-PEGuiRequestAction -Request $request -Job $job -BlueprintName $BlueprintName -DataRoot $root -GuiRoot $GuiRoot -Role $role -ApplyScript $ApplyScript -RecheckScript $RecheckScript -ExportScript $ExportScript -Progress $progress
            $job.status = $outcome.Status
            $job.result = $outcome.Result
            if ($outcome.Config) { $job.config = $outcome.Config }
            # GenerateConfig: how many items each of the job's files holds (the files are served from configs\<jobId>).
            if ($outcome.ContainsKey('Files') -and $outcome.Files) { $job | Add-Member -NotePropertyName files -NotePropertyValue $outcome.Files -Force }
            if ($outcome.Refresh)
            {
                # Refresh the view models BEFORE the job reads Succeeded: the page reloads its data when a job finishes.
                $refresh = $true
                Export-PEGuiData -BlueprintName $BlueprintName -DataRoot $root -GuiRoot $GuiRoot | Out-Null
            }
        }
        catch
        {
            $now = & $readJson "activity\$($job.jobId).json"
            if ($job.action -eq 'Recheck' -and ($_.Exception -is [System.OperationCanceledException] -or ($null -ne $now -and $now.cancelRequested -eq $true)))
            {
                $job.status = 'Cancelled'
                $job.result = 'Cancelled by request: the export was stopped and nothing was saved.'
            }
            else
            {
                $job.status = 'Failed'
                $job.result = "Failed: $($_.Exception.Message)"
            }
        }
        finally
        {
            $script:PEJobCancelCheck = $null
            $running.JobId = $null
        }
        $job.updatedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        # A job the server already marked Cancelled (it found no live worker) stays Cancelled, whatever this late run ended with.
        # Read and write under the lock, so a cancel cannot land between them.
        & $locked {
            $now = & $readJson "activity\$($job.jobId).json"
            if ($null -ne $now -and $now.status -eq 'Cancelled') { $job.status = 'Cancelled'; $job.result = $now.result; $job.updatedAt = $now.updatedAt }
            else { & $writeJob $job }
        }
        & $setActive $job.jobId
        Write-Host ('{0:HH:mm:ss} {1} {2}: {3}. {4}' -f (Get-Date), $job.jobId, $job.action, $job.status, $job.result)
    }

    [pscustomobject]@{ Processed = $queued.Count; Refreshed = $refresh }
}
