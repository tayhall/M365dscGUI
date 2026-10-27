function Invoke-PEGuiRequestAction
{
    # One request -> one outcome @{ Status; Result; Config; Refresh } (GenerateConfig adds Files, the item count of each file). Throws on anything invalid.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        $Request,

        [Parameter(Mandatory)]
        $Job,

        [Parameter(Mandatory)]
        [string]$BlueprintName,

        [Parameter(Mandatory)]
        [string]$DataRoot,

        # The GUI data folder (default <DataRoot>\gui): GenerateConfig writes the job's files to configs\<jobId> in it, where the server serves them.
        [string]$GuiRoot,

        [string]$Role,

        [scriptblock]$ApplyScript,

        [scriptblock]$RecheckScript,

        [scriptblock]$ExportScript,

        # Test seam for the standards requests that talk to git: called with [string[]]$Arguments, returns ExitCode and Output.
        [scriptblock]$GitScript,

        # Called with a text while a long job runs (the device-code prompt of Connect tenant); the worker writes it into the job.
        [scriptblock]$Progress
    )

    $action =[string]$Request.action
    $reason = [string]$Request.reason
    $items = @($Request.items | Where-Object { $null -ne $_ })
    # The tenant the request is about (the GUI's tenant id is the tenant's slug); a replica is brought into line with the blueprint.
    $tenant = $(if ([string]$Request.tenantId) { [string]$Request.tenantId } else { 'master' })
    # The blueprint the tenant is checked against, promoted into and reverted to: its own (the last layer), or the master blueprint.
    $ownBlueprint = { @(Get-PETenantBlueprint -Tenant $tenant -MasterBlueprint $BlueprintName -DataRoot $DataRoot)[-1] }
    $done = { param($text) @{ Status = 'Succeeded'; Result = $text; Config = $null; Refresh = $true } }
    # After a property exclusion changes: compares the Changed findings of the type (or one item) of the tenant's latest snapshot with its blueprint again,
    # from the records the snapshot holds (no tenant read). $false when there is nothing to compare or the snapshot is of another blueprint.
    $recompareProperty = {
        param ($type, $key)
        try
        {
            $check = Get-PECheck -Latest -Kind Full -Tenant $tenant -DataRoot $DataRoot
            $affected = @(@($check.Findings) | Where-Object { $_.Kind -eq 'Changed' -and [string]$_.ResourceType -ieq $type -and ([string]::IsNullOrEmpty($key) -or [string]$_.Key -ieq $key) } |
                    ForEach-Object { [pscustomobject]@{ ResourceType = $_.ResourceType; Key = $_.Key } })
            if ($affected.Count -eq 0) { return $false }
            return [bool](Update-PECheckForItems -Tenant $tenant -BlueprintName (& $ownBlueprint) -Item $affected -DataRoot $DataRoot)
        }
        catch
        {
            Write-Warning "The items were not compared again: $($_.Exception.Message)"
            return $false
        }
    }

    switch ($action)
    {
        'ConnectTenant'
        {
            if (-not $Request.PSObject.Properties['connect'] -or $null -eq $Request.connect) { throw 'The request has no tenant details.' }
            $c = $Request.connect
            if ($c.PSObject.Properties['mode'] -and [string]$c.mode -eq 'create')
            {
                # The administrator signs in with a device code; tools\New-PETenantApps.ps1 creates the apps, consent and roles.
                $createArguments = @{ Slug = [string]$c.slug; TenantDomain = [string]$c.tenantDomain; DisplayName = [string]$c.displayName }
                if (-not [bool]$c.createWriter) { $createArguments.NoWriter = $true }
                elseif ([bool]$c.writerRoles) { $createArguments.WriterRoles = @('Exchange Administrator', 'Teams Administrator') }
                if ($Progress) { $createArguments.Progress = $Progress }
                $run = Invoke-PETenantAppsProcess @createArguments
                if ($run.ExitCode -ne 0 -or $null -eq $run.Result)
                {
                    $tail = (@($run.Output | Where-Object { $_ }) | Select-Object -Last 4) -join ' | '
                    throw "The apps could not be created (exit code $($run.ExitCode)). $tail"
                }
                $skipped = @($run.Result.Unresolved).Count
                $readerWrite = @($run.Result.ReaderReadWrite).Count
                return (& $done "Tenant '$($c.slug)' connected: Reader app$(if ($run.Result.Writer) { ' and Writer app' }) created from DSC's permission lists, consent given and the tenant registered as a replica$(if ($skipped) { "; $skipped permission(s) are not available in that tenant and were skipped" })$(if ($readerWrite) { ". Note: DSC's read list gives the Reader app $readerWrite ReadWrite permission(s), so it can change those areas" }). Run a check for it from the Overview.")
            }
            $arguments = @{
                Slug                = [string]$c.slug
                TenantId            = [string]$c.tenantDomain
                DisplayName         = [string]$c.displayName
                ReaderApplicationId = [string]$c.readerApplicationId
                ReaderThumbprint    = [string]$c.readerThumbprint
                DataRoot            = $DataRoot
            }
            if ([string]$c.writerApplicationId) { $arguments.WriterApplicationId = [string]$c.writerApplicationId; $arguments.WriterThumbprint = [string]$c.writerThumbprint }
            Connect-PETenant @arguments | Out-Null
            return (& $done "Tenant '$($c.slug)' registered as a replica: the Reader app signed in$(if ($arguments.ContainsKey('WriterApplicationId')) { ', Writer app recorded' } else { '; no Writer app, so it can be checked but not brought into line' }). Run a check for it from the Overview.")
        }
        'ReviewModule'
        {
            # The drift the upgrade brought was reviewed: records the installed Microsoft365DSC version for every blueprint built with another one
            # (Set-PEBlueprintModule), which allows Reverts again. Nothing is written to a tenant.
            $pin = Get-PEPinnedVersion -Name Microsoft365DSC
            if (-not $reason.Trim()) { $reason = "Drift reviewed in the GUI after the upgrade to Microsoft365DSC $pin" }
            $names = @(Get-PETenant -DataRoot $DataRoot | ForEach-Object { Get-PETenantBlueprint -Tenant $_.Slug -MasterBlueprint $BlueprintName -DataRoot $DataRoot } | Select-Object -Unique)
            $stamped = @($names | Where-Object { (Get-PEModuleState -BlueprintName $_ -DataRoot $DataRoot).Match -eq $false })
            if ($stamped.Count -eq 0) { throw "No blueprint was built with another Microsoft365DSC version than $pin." }
            foreach ($name in $stamped) { Set-PEBlueprintModule -Name $name -Reason $reason -DataRoot $DataRoot | Out-Null }
            return (& $done "Microsoft365DSC $pin recorded for blueprint $($stamped -join ', '). Reverts are allowed again. No tenant was changed.")
        }
        'RenameTenant'
        {
            # Only the friendly name changes (tenants.json); the slug, tenant id and blueprints stay. No tenant is written to.
            $null = Get-PETenant -Slug $tenant -DataRoot $DataRoot
            $name = ([string]$Request.displayName).Trim()
            if (-not $name -or $name.Length -gt 80) { throw 'The name must be 1 to 80 characters.' }
            Set-PETenant -Slug $tenant -DisplayName $name -DataRoot $DataRoot | Out-Null
            return (& $done "Tenant '$tenant' is now called '$name'.")
        }
        'Recheck'
        {
            # Reads the tenant again (Reader app) and compares it with the latest blueprint. Scope: the types the
            # blueprint holds records for (an export of every workload takes about half an hour).
            if ((Get-PETenant -Slug $tenant -DataRoot $DataRoot).Offline) { throw "Tenant '$tenant' is offline: upload a newer export instead." }
            $own = & $ownBlueprint
            if ($Request.PSObject.Properties['scope'] -and $Request.scope)
            {
                # One scope: only its types are read, and the result is folded into the latest Full check.
                $scoped = Invoke-PEScopeCheck -Scope ([string]$Request.scope) -BlueprintName $own -Tenant $tenant -DataRoot $DataRoot -ExportScript $ExportScript -AcceptModuleChange -WarningAction SilentlyContinue
                return (& $done "Scope '$($scoped.Scope)' refreshed (snapshot $($scoped.CheckId)): $($scoped.Items) item(s), $(if ($scoped.Drifted) { "$($scoped.Drifted) drifted" } else { 'no drift' })$(if ($scoped.NotChecked) { ", $($scoped.NotChecked) type(s) not checked" }).")
            }
            $blueprint = Get-PEBlueprint -Name $own -DataRoot $DataRoot
            $types = @(@($blueprint.Records) | ForEach-Object { [string]$_.ResourceType } | Sort-Object -Unique)
            if ($types.Count -eq 0) { throw "Blueprint '$own' has no records to check." }
            $arguments = @{ BlueprintName = $own; Workloads = $types; Tenant = $tenant; DataRoot = $DataRoot; AcceptModuleChange = $true }
            if ($ExportScript) { $arguments.ExportScript = $ExportScript }
            $asBaseline = $Request.PSObject.Properties['baseline'] -and [bool]$Request.baseline
            # A snapshot that becomes the blueprint reads everything DSC exports for the default workloads, not only the types the blueprint
            # holds: types and items that a newer Microsoft365DSC can see must reach the baseline too.
            if ($asBaseline) { $arguments.Remove('Workloads') }
            Invoke-PEFullCheck @arguments -WarningAction SilentlyContinue | Out-Null
            $check = Get-PECheck -Latest -Kind Full -Tenant $tenant -DataRoot $DataRoot
            # "Use this snapshot as the blueprint": the tenant's own blueprint becomes what this snapshot read (New-PETenantBaseline), and the
            # snapshot's findings are compared with it again, so the tenant starts from no drift. The snapshot is kept either way.
            $baselineText = ''
            if ($asBaseline)
            {
                if ($tenant -eq 'master') { throw 'The master tenant has no blueprint of its own: the master blueprint changes through Promote.' }
                $baseline = New-PETenantBaseline -Slug $tenant -MasterBlueprint $BlueprintName -DataRoot $DataRoot
                if ($null -eq $baseline)
                {
                    $baselineText = " The blueprint '$own' already matched this snapshot, so no new version was recorded."
                }
                else
                {
                    $null = Update-PECheckForItems -Tenant $tenant -BlueprintName $baseline.Name -Item @($baseline.Items) -DataRoot $DataRoot
                    $check = Get-PECheck -Latest -Kind Full -Tenant $tenant -DataRoot $DataRoot
                    $left = @(if ($baseline.Excluded) { "$($baseline.Excluded) excluded" }; if ($baseline.NeedDecision) { "$($baseline.NeedDecision) that need a decision (renames, duplicate keys)" })
                    $baselineText = " Blueprint '$($baseline.Name)' v$($baseline.Version) recorded from this snapshot: $($baseline.Added) added, $($baseline.Changed) changed, $($baseline.Removed) removed.$(if ($left) { ' Left out: ' + ($left -join ', ') + '.' }) The master blueprint is unchanged."
                }
            }
            $drift = @(@($check.Findings) | Where-Object { $_.State -eq 'Open' -and $_.Kind -in 'Missing', 'Changed', 'TargetOnly', 'PossibleRename', 'Ambiguous' }).Count
            return (& $done "Snapshot taken of $($types.Count) resource type(s) (snapshot $($check.CheckId)): $(if ($drift) { "$drift drifted item(s)" } else { 'no drift' }).$baselineText")
        }
        'UploadSnapshot'
        {
            # The files are DSC exports of an offline tenant (New-PEUploadCheck turns them into a Full check). A new tenant is
            # registered first, because the check needs the tenant, and taken out again when the upload fails before a check exists.
            $files = @(@($Request.files) | Where-Object { $null -ne $_ } | ForEach-Object { [pscustomobject]@{ Name = [string]$_.name; Text = [string]$_.text } })
            if ($files.Count -eq 0) { throw 'The request has no files.' }
            $saveAsBlueprint = [bool]$Request.saveAsBlueprint
            $registered = $false
            $new = $(if ($Request.PSObject.Properties['newTenant']) { $Request.newTenant } else { $null })
            if ($new)
            {
                if ([string]$new.slug -cne $tenant) { throw "The new tenant's short name must be the tenant id of the request." }
                if (@(Get-PETenant -DataRoot $DataRoot | Where-Object { $_.Slug -ceq $tenant }).Count) { throw "Tenant '$tenant' is already registered." }
            }
            if ($saveAsBlueprint -and $tenant -ieq $BlueprintName) { throw "The tenant's own blueprint would be named '$tenant', the same as the master blueprint. Use another short name." }
            if ($new)
            {
                Set-PETenant -Slug $tenant -DisplayName ([string]$new.displayName) -Offline -Blueprints @($BlueprintName) -DataRoot $DataRoot | Out-Null
                $registered = $true
            }
            $uploadArguments = @{ Tenant = $tenant; File = $files; DataRoot = $DataRoot }
            # A tenant with no blueprint of its own follows the master blueprint, so its check is compared with that, unless this upload
            # becomes its blueprint (then the first check has nothing to compare with and a second one follows).
            $ownLayers = @((Get-PETenant -Slug $tenant -DataRoot $DataRoot).Blueprints)
            $hasOwn = ($ownLayers.Count -gt 0 -and $ownLayers[-1] -ceq $tenant)
            if (-not $hasOwn -and -not $saveAsBlueprint) { $uploadArguments.BlueprintName = $BlueprintName }
            if ([string]$Request.tenantDomain) { $uploadArguments.TenantDomain = [string]$Request.tenantDomain }
            $complete = @(@($Request.completeWorkloads) | Where-Object { $_ } | ForEach-Object { [string]$_ })
            if ($complete.Count) { $uploadArguments.CompleteWorkload = $complete }
            try
            {
                $upload = New-PEUploadCheck @uploadArguments
            }
            catch
            {
                if ($registered) { Remove-PETenant -Slug $tenant -DataRoot $DataRoot }
                throw
            }
            $note = ''
            if ($saveAsBlueprint -and -not $hasOwn)
            {
                # The first upload becomes the tenant's own blueprint. A check is never rewritten, so the compare runs again from
                # the same files and the stored check then holds the findings against that blueprint.
                $firstCheck = $upload.CheckId
                try
                {
                    Initialize-PETenantBlueprint -Slug $tenant -MasterBlueprint $BlueprintName -FromCheck -DataRoot $DataRoot | Out-Null
                    $upload = New-PEUploadCheck @uploadArguments
                }
                catch
                {
                    throw "The tenant '$tenant' was registered and its check $firstCheck stored, but the blueprint could not be seeded: $($_.Exception.Message)"
                }
            }
            elseif ($saveAsBlueprint) { $note = " The tenant already has its own blueprint '$tenant', which was not replaced." }
            $check = Get-PECheck -CheckId $upload.CheckId -DataRoot $DataRoot
            $drift = @(@($check.Findings) | Where-Object { $_.State -eq 'Open' -and $_.Kind -in 'Missing', 'Changed', 'TargetOnly', 'PossibleRename', 'Ambiguous' }).Count
            $notChecked = @(@($check.State.NotChecked) | Where-Object { $null -ne $_ }).Count
            $warnings = @($upload.Warnings | Where-Object { $_ })
            return (& $done "Snapshot uploaded (check $($upload.CheckId)): $drift drifted item(s), $notChecked type(s) not checked.$note$(if ($warnings) { ' ' + ($warnings -join ' ') })")
        }
        'GenerateConfig'
        {
            # The configuration the tenant's owner runs to bring it in line with its own blueprint (New-PEOfflineConfig), generated in
            # this process. The text goes only into configs\<jobId>: Changes.ps1, Removals.ps1 (when there is something to remove) and
            # Manual.json (always), each written once. The job result carries the counts. Nothing is written to a tenant, a blueprint,
            # a check or the decisions.
            if ([string]$Job.jobId -cnotmatch '\AJ-[0-9]+\z') { throw 'The job has no valid job id.' }
            $generated = New-PEOfflineConfig -Tenant $tenant -DataRoot $DataRoot
            $count = { param ($text) if ($text) { @((Split-PEDscConfigText -Text $text).Blocks).Count } else { 0 } }
            $files = [ordered]@{ changes = (& $count $generated.Changes); removals = (& $count $generated.Removals); manual = @($generated.Manual).Count }
            $folder = Join-Path $(if ($GuiRoot) { $GuiRoot } else { Join-Path $DataRoot 'gui' }) "configs\$($Job.jobId)"
            if (Test-Path -LiteralPath $folder) { throw "The files of job $($Job.jobId) already exist; they are never overwritten." }
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            try
            {
                if ($generated.Changes) { Write-PETextNew -Path (Join-Path $folder 'Changes.ps1') -Text $generated.Changes -Bom }
                if ($generated.Removals) { Write-PETextNew -Path (Join-Path $folder 'Removals.ps1') -Text $generated.Removals -Bom }
                Write-PEJsonNew -Path (Join-Path $folder 'Manual.json') -InputObject @($generated.Manual)
            }
            catch
            {
                # This call created the folder, so no half set of files is left behind.
                Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
                throw
            }
            $text = "Configuration generated from check $($generated.CheckId) against blueprint '$($generated.BlueprintName)': " +
                "$(if ($files.changes) { "$($files.changes) item(s) in Changes.ps1" } else { 'nothing to change' }), " +
                "$(if ($files.removals) { "$($files.removals) in Removals.ps1 (run it after the changes)" } else { 'nothing to remove' }), " +
                "$($files.manual) item(s) need manual action." +
                $(if ($generated.PSObject.Properties['NoBlueprintTypeCount'] -and $generated.NoBlueprintTypeCount) { " $($generated.NoBlueprintTypeCount) of them exist only in the tenant, of a type with no records in the blueprint, so they are not removed." }) +
                ' Nothing was written to a tenant.'
            if ($generated.PSObject.Properties['CheckBlueprintVersion'] -and $null -ne $generated.CheckBlueprintVersion -and $generated.BlueprintVersion -ne $generated.CheckBlueprintVersion)
            {
                $text += " Compared with blueprint '$($generated.BlueprintName)' v$($generated.BlueprintVersion); the check was made against v$($generated.CheckBlueprintVersion)."
            }
            return @{ Status = 'Succeeded'; Result = $text; Config = $null; Refresh = $false; Files = $files }
        }
        'Exclude'
        {
            if ($items.Count -eq 0) { throw 'No items in the request.' }
            # On the master only items that exist in the tenant and not in the blueprint can be excluded: a Missing or Changed item there is
            # real drift and an exclusion must not hide it. In a replica, a Missing or Changed item may simply be specific to that tenant.
            $notTargetOnly = @($items | Where-Object { $_.findingKind -ne 'TargetOnly' })
            if ($notTargetOnly.Count -gt 0 -and $Role -ne 'Replica')
            {
                throw "Only target-only items can be excluded on the master; not: $(($notTargetOnly | ForEach-Object { "$($_.resourceType) '$($_.key)' ($($_.findingKind))" }) -join '; '). Missing and changed items can be excluded in a replica."
            }
            $notExcludable = @($items | Where-Object { $_.findingKind -notin 'TargetOnly', 'Missing', 'Changed' })
            if ($notExcludable.Count -gt 0)
            {
                throw "These cannot be excluded: $(($notExcludable | ForEach-Object { "$($_.resourceType) '$($_.key)' ($($_.findingKind))" }) -join '; ')."
            }            foreach ($item in $items)
            {
                Set-PEDecision -Kind Unmanaged -ResourceType ([string]$item.resourceType) -Key ([string]$item.key) -Reason $reason -Tenant $tenant -DataRoot $DataRoot | Out-Null
            }
            return (& $done "Excluded $($items.Count) item(s) from management.")
        }
        'ExcludeProperty'
        {
            if ($items.Count -ne 1) { throw 'A noise rule applies to exactly one property of one item.' }
            $item = $items[0]
            $arguments = @{ Kind = 'Noise'; ResourceType = [string]$item.resourceType; Property = [string]$item.property; Value = $item.value; Reason = $reason; DataRoot = $DataRoot }
            if ($item.scope -eq 'item') { $arguments.Key = [string]$item.key }
            Set-PEDecision @arguments | Out-Null
            return (& $done "Noise rule recorded for $($item.resourceType).$($item.property).")
        }
        'ExcludePropertyForTenant'
        {
            if ($items.Count -ne 1) { throw 'A property exclusion applies to exactly one property of one item.' }
            $item = $items[0]
            $arguments = @{ Kind = 'PropertyExcluded'; ResourceType = [string]$item.resourceType; Property = [string]$item.property; Tenant = $tenant; Reason = $reason; DataRoot = $DataRoot }
            if ($item.scope -eq 'item') { $arguments.Key = [string]$item.key }
            Set-PEDecision @arguments | Out-Null
            $recompared = & $recompareProperty ([string]$item.resourceType) $(if ($item.scope -eq 'item') { [string]$item.key } else { $null })
            return (& $done "$($item.resourceType).$($item.property) is no longer enforced in '$tenant'$(if ($item.scope -eq 'item') { " for '$($item.key)'" } else { ' for any item of the type' }). It stays visible in the item and a revert leaves it as it is.$(if (-not $recompared) { ' The drift list updates at the next snapshot.' })")
        }
        'IncludePropertyForTenant'
        {
            if ($items.Count -eq 0) { throw 'No items in the request.' }
            foreach ($item in $items)
            {
                $arguments = @{ Kind = 'PropertyExcluded'; ResourceType = [string]$item.resourceType; Property = [string]$item.property; Tenant = $tenant; DataRoot = $DataRoot }
                if ($item.key) { $arguments.Key = [string]$item.key }
                Remove-PEDecision @arguments
                $null = & $recompareProperty ([string]$item.resourceType) $(if ($item.key) { [string]$item.key } else { $null })
            }
            return (& $done "$($items.Count) property exclusion(s) removed in '$tenant'. The setting is enforced again.")
        }
        'Unexclude'
        {
            if ($items.Count -eq 0) { throw 'No items in the request.' }
            foreach ($item in $items)
            {
                if ($item.property)
                {
                    $arguments = @{ Kind = 'Noise'; ResourceType = [string]$item.resourceType; Property = [string]$item.property; DataRoot = $DataRoot }
                    if ($item.key) { $arguments.Key = [string]$item.key }
                    Remove-PEDecision @arguments
                }
                else
                {
                    Remove-PEDecision -Kind Unmanaged -ResourceType ([string]$item.resourceType) -Key ([string]$item.key) -Tenant $tenant -DataRoot $DataRoot
                }
            }
            return (& $done 'Back under management.')
        }
        'Promote'
        {
            if ($items.Count -eq 0) { throw 'No items in the request.' }
            # Only the tenant's own blueprint changes: the tenant's side becomes the blueprint. No tenant is written to.
            $own = & $ownBlueprint
            if ($tenant -ne 'master' -and $own -ieq $BlueprintName)
            {
                throw "Replica '$tenant' has no blueprint of its own, so Promote would change the master blueprint. Give it one first (Initialize-PETenantBlueprint)."
            }
            $check = Get-PECheck -Latest -Kind Full -Tenant $tenant -DataRoot $DataRoot
            $changes = @(Get-PEBlueprintChange -Name $own -MasterState $check.State -DataRoot $DataRoot)
            $accept = foreach ($item in $items)
            {
                $match = @($changes | Where-Object { $_.ResourceType -ieq [string]$item.resourceType -and $_.Key -ieq [string]$item.key })
                if ($match.Count -ne 1)
                {
                    throw "$($item.resourceType) '$($item.key)' is not a change against blueprint '$own' in the latest snapshot ($($check.CheckId)); take a new snapshot."
                }
                $match[0]
            }
            $version = Approve-PEBlueprintChange -Name $own -MasterState $check.State -Accept @($accept) -Reason $reason -DataRoot $DataRoot
            # The blueprint is recorded; re-comparing just these items with it (no tenant read) must not fail the job.
            $recompared = $false
            try { $recompared = [bool](Update-PECheckForItems -Tenant $tenant -BlueprintName $own -Item @($accept) -DataRoot $DataRoot) } catch { Write-Warning "The promoted items were not re-compared: $($_.Exception.Message)" }
            return (& $done "Blueprint v$version recorded in '$own' from check $($check.CheckId). No tenant was changed.$(if ($recompared) { ' The promoted items were compared with it again, so they leave the drift list now.' } else { ' They leave the drift list at the next check.' })")
        }
        'Accept'
        {
            # Restores the tenant to the approved blueprint: Create (Missing), Update (Changed), Remove (TargetOnly).
            # Plans and applies in this one process (Invoke-PERectify's session constraint), with the Writer app.
            # Reverting the master changes the tenant the blueprint was taken from, so it needs the explicit confirmation; a replica
            # is what the blueprint is for. Nothing can write to an offline tenant: refused before any decision is recorded.
            if ((Get-PETenant -Slug $tenant -DataRoot $DataRoot).Offline) { throw "Tenant '$tenant' is offline: nothing can be written to it from here. Use Generate configuration and let its owner run the files instead." }
            $isReplica = ($Role -eq 'Replica')
            if (-not $isReplica -and -not [bool]$Request.confirmedMasterWrite)
            {
                throw 'Accept writes to the master tenant and needs the master-write confirmation.'
            }
            if ($items.Count -eq 0) { throw 'No items in the request.' }
            $own = & $ownBlueprint
            $check = Get-PECheck -Latest -Kind Full -Tenant $tenant -DataRoot $DataRoot
            $blueprint = Get-PEBlueprint -Name $own -DataRoot $DataRoot
            $actionFor = @{ Missing = 'Create'; Changed = 'Update'; TargetOnly = 'Remove' }
            $chosen = foreach ($item in $items)
            {
                $finding = @($check.Findings | Where-Object { $_.ResourceType -ieq [string]$item.resourceType -and $_.Key -ieq [string]$item.key }) | Select-Object -First 1
                if ($null -eq $finding) { throw "No finding for $($item.resourceType) '$($item.key)' in snapshot $($check.CheckId); take a new snapshot." }
                if ([string]$finding.Kind -eq 'PossibleRename')
                {
                    throw "'$($item.key)' looks like it was renamed to '$($finding.Hint -replace '^Possible rename of ', '')'. Reverting a rename would delete the renamed group and create a new one from the blueprint (members and the object id are not restored), so it is not done automatically. Rename it back in the tenant, then Re-check."
                }
                if (-not $actionFor.ContainsKey([string]$finding.Kind)) { throw "$($finding.Kind) $($item.resourceType) '$($item.key)' cannot be accepted automatically; look at it first." }
                [pscustomobject]@{ Finding = $finding; Action = $actionFor[[string]$finding.Kind] }
            }
            # A TargetOnly item is removed only on this explicit request: the confirmed Accept is the Remove decision.
            foreach ($entry in $chosen | Where-Object Action -EQ 'Remove')
            {
                Set-PEDecision -Kind Remove -ResourceType ([string]$entry.Finding.ResourceType) -Key ([string]$entry.Finding.Key) -Reason 'Accept from the web GUI (confirmed write)' -Tenant $tenant -DataRoot $DataRoot | Out-Null
            }
            $decisions = @(Get-PEDecision -Tenant $tenant -DataRoot $DataRoot)
            $plan = foreach ($group in (Sort-PERevertEntry -Entry @($chosen)) | Group-Object Action)
            {
                New-PERectifyPlan -Findings @($group.Group | ForEach-Object { $_.Finding }) -Action $group.Name -Source $check.State -Blueprint $blueprint -Decisions $decisions
            }
            $plan = @($plan)
            $arguments = @{ Plan = $plan; Target = $(if ($isReplica) { 'Replica' } else { 'Master' }); Tenant = $tenant; BlueprintName = $own; ConfigurationName = "PE_$($Job.jobId -replace '-', '')"; DataRoot = $DataRoot; Confirm = $false }
            if (-not $isReplica) { $arguments.ConfirmMasterWrite = $true }
            if ($ApplyScript) { $arguments.ApplyScript = $ApplyScript }
            if ($RecheckScript) { $arguments.RecheckScript = $RecheckScript }
            $applied = Invoke-PERectify @arguments -WarningAction SilentlyContinue
            $config = $null
            $configFile = Join-Path ([string]$applied.AuditPath) 'config.ps1'
            if (Test-Path -LiteralPath $configFile) { $config = Get-Content -LiteralPath $configFile -Raw }
            $labels = ($plan | ForEach-Object { "$($_.Action) $($_.ResourceType) '$($_.Key)'" }) -join '; '
            if (-not $applied.Applied)
            {
                return @{ Status = 'Failed'; Result = "Not applied ($labels). $(@($applied.Warnings) -join ' ') $(Format-PEApplyOutcome -Applied $applied)Audit: $($applied.AuditPath)"; Config = $config; Refresh = $false }
            }
            if ($null -eq $applied.RecheckFindings -or @($applied.RecheckFindings).Count -gt 0)
            {
                return @{ Status = 'Failed'; Result = "Applied ($labels) but the re-read did not confirm it. $(@($applied.Warnings) -join ' ') $(Format-PEApplyOutcome -Applied $applied)Audit: $($applied.AuditPath)"; Config = $config; Refresh = $false }
            }
            $patched = New-PEPatchedCheck -Check $check -Plan $plan -DataRoot $DataRoot
            return @{ Status = 'Succeeded'; Result = "Applied and confirmed by a re-read: $labels. Tenant matches blueprint '$own' for these items (snapshot $patched; take a new snapshot to refresh the rest). Audit: $($applied.AuditPath)"; Config = $config; Refresh = $true }
        }
        { $_ -in 'PromoteUp', 'PullDown' }
        {
            # Blueprint to blueprint: a new version of the target only, never a tenant. Promote up takes the tenant blueprint's
            # differences into the master blueprint, update tenant blueprint takes the master blueprint's into the tenant's own.
            if ($items.Count -eq 0) { throw 'No items in the request.' }
            $layers = @(Get-PETenantBlueprint -Tenant $tenant -MasterBlueprint $BlueprintName -DataRoot $DataRoot)
            if ($layers.Count -lt 2) { throw "Tenant '$tenant' follows one blueprint layer, so there is nothing to move between layers." }
            $from, $to = $(if ($action -eq 'PromoteUp') { $layers[-1], $layers[0] } else { $layers[0], $layers[-1] })
            $expectedSource = $(if ($Request.PSObject.Properties['expectedSourceVersion']) { [int]$Request.expectedSourceVersion } else { throw 'The request does not say which version of the source blueprint was reviewed.' })
            $expected = $(if ($Request.PSObject.Properties['expectedVersion']) { [int]$Request.expectedVersion } else { throw 'The request does not say which version of the target blueprint was reviewed.' })
            $version = Move-PEBlueprintItem -From $from -To $to -Item @($items | ForEach-Object { [pscustomobject]@{ ResourceType = [string]$_.resourceType; Key = [string]$_.key } }) -Reason $reason -ExpectedVersion $expected -ExpectedSourceVersion $expectedSource -DataRoot $DataRoot
            return (& $done "Blueprint v$version recorded in '$to' from '$from' ($($items.Count) item(s)). No tenant was changed.")
        }
        'RevertBlueprint'
        {
            # Restores the master blueprint: a new version that is a copy of an earlier one, or of one item of it. History is kept; no tenant is written to.
            $target = [int]$Request.targetVersion
            $arguments = @{ Name = $BlueprintName; Version = $target; Reason = $reason; DataRoot = $DataRoot }
            # The items of the request are everything the restore changes; restoreItem says the user asked for one of them only.
            $oneItem = $Request.PSObject.Properties['restoreItem'] -and [bool]$Request.restoreItem -and $items.Count -eq 1
            if ($oneItem) { $arguments.Item = @([pscustomobject]@{ ResourceType = [string]$items[0].resourceType; Key = [string]$items[0].key }) }
            $restored = Restore-PEBlueprintVersion @arguments
            # The blueprint is recorded; comparing what changed with the master tenant's latest snapshot again (no tenant read) must not fail the job.
            $recompared = $false
            $masterTenant = @(Get-PETenant -DataRoot $DataRoot | Where-Object { $_.Slug -eq 'master' })
            if ($masterTenant.Count -gt 0)
            {
                try { $recompared = [bool](Update-PECheckForItems -Tenant 'master' -BlueprintName $BlueprintName -Item @($restored.Items) -DataRoot $DataRoot) } catch { Write-Warning "The restored items were not re-compared: $($_.Exception.Message)" }
            }
            $what = if ($oneItem) { "item '$($items[0].key)' of v$target" } else { "v$target" }
            return (& $done "Blueprint '$BlueprintName' v$($restored.Version) recorded as a copy of $what. The versions in between are kept. No tenant was changed.$(if ($recompared) { ' The changed items were compared with the latest master snapshot again.' } else { ' The drift list updates at the next snapshot.' })")
        }
        'StandardCheck'
        {
            # Compares the tenant's own blueprint with the standard. Nothing is read from the tenant, so it also works for an offline tenant.
            $standard = [string]$Request.standard
            $result = Invoke-PEStandardCheck -StandardName $standard -BlueprintName $BlueprintName -Tenant $tenant -DataRoot $DataRoot
            $c = $result.Coverage
            $notCovered = (@($c.NotCovered.Values) | Measure-Object -Sum).Sum
            return (& $done "Compared $($c.Checked) of $($c.Total) settings of '$standard' with blueprint '$($result.BlueprintName)' v$($result.BlueprintVersion) (check $($result.CheckId)): $($c.NotReadable) not in the blueprint's data, $([int]$notCovered) not covered. Nothing was read from the tenant.")
        }
        'Adopt'
        {
            # Copies the standard's settings into the tenant's own blueprint (a new version, provenance kept). No tenant is written to.
            if ($items.Count -eq 0) { throw 'No items in the request.' }
            $standard = [string]$Request.standard
            $own = & $ownBlueprint
            $writesMaster = $own -ieq $BlueprintName
            if ($writesMaster -and $tenant -ne 'master')
            {
                throw "Replica '$tenant' has no blueprint of its own, so Adopt would change the master blueprint. Give it one first (Initialize-PETenantBlueprint)."
            }
            if ($writesMaster -and -not [bool]$Request.confirmedMasterWrite)
            {
                throw 'Adopt writes to the master blueprint and needs the master-write confirmation.'
            }
            # What is reviewed is the standard's value, which Adopt overwrites with its own; the blueprint's latest version is read now and
            # Copy-PEStandardItem still refuses if the blueprint moves while it writes.
            $latest = @(Get-PEBlueprintVersionNumber -Directory (Get-PEBlueprintDirectory -Name $own -DataRoot $DataRoot))[-1]
            $picked = @($items | ForEach-Object { [pscustomobject]@{ ResourceType = [string]$_.resourceType; Key = [string]$_.key } })
            $version = Copy-PEStandardItem -Standard $standard -To $own -Item $picked -Reason $reason -ExpectedVersion $latest -DataRoot $DataRoot
            $refreshed = $false
            try { $null = Invoke-PEStandardCheck -StandardName $standard -BlueprintName $BlueprintName -Tenant $tenant -DataRoot $DataRoot; $refreshed = $true } catch { Write-Warning "The comparison with the standard was not refreshed: $($_.Exception.Message)" }
            # Like Promote: the adopted items are compared with the new blueprint version again, from the records of the tenant's latest check (no
            # tenant read), so that they show in the tenant's own Drift review now and can be reverted from there.
            $recompared = $false
            try { $recompared = [bool](Update-PECheckForItems -Tenant $tenant -BlueprintName $own -Item $picked -DataRoot $DataRoot) } catch { Write-Warning "The adopted items were not compared with the tenant's check: $($_.Exception.Message)" }
            return (& $done "Blueprint v$version recorded in '$own' from '$standard'. No tenant was changed.$(if ($recompared) { ' The adopted items were compared with the tenant''s latest check again, so any that differ show in Drift review now: revert the tenant to its blueprint there to push the change.' } else { ' They show in Drift review after the next check; then revert the tenant to its blueprint to push the change.' })$(if ($refreshed) { ' The blueprint now matches the standard for them.' })")
        }
        'AcceptRisk'
        {
            # A note, per item, of who accepted leaving the tenant different from the standard and why (for the whole item, or per property).
            if ($items.Count -eq 0) { throw 'No items in the request.' }
            $standard = [string]$Request.standard
            $check = Get-PECheck -Latest -Kind Standard -Standard $standard -Tenant $tenant -DataRoot $DataRoot
            $count = 0
            foreach ($item in $items)
            {
                $finding = @($check.Findings | Where-Object { [string]$_.ResourceType -ieq [string]$item.resourceType -and [string]$_.Key -ieq [string]$item.key -and [string]$_.Kind -in 'Missing', 'Changed' }) | Select-Object -First 1
                if ($null -eq $finding) { throw "No difference for $($item.resourceType) '$($item.key)' in check $($check.CheckId); check again." }
                $by = ([string]$item.approvedBy).Trim()
                $why = ([string]$item.why).Trim()
                if (-not $by) { throw "Accept risk needs 'approved by' for '$($item.key)'." }
                if (-not $why) { throw "Accept risk needs 'why' for '$($item.key)'." }
                $properties = @(@($item.properties) | Where-Object { $_ } | ForEach-Object { [string]$_ })
                $differing = @(@($finding.Differences) + @($finding.AcceptedDifferences) | Where-Object { $_ } | ForEach-Object { [string]$_.Property })
                foreach ($property in $properties)
                {
                    if ($differing -inotcontains $property) { throw "'$property' does not differ on '$($item.key)'." }
                }
                $arguments = @{ Standard = $standard; Tenant = $tenant; ResourceType = [string]$item.resourceType; Key = [string]$item.key; ApprovedBy = $by; Reason = $why; DataRoot = $DataRoot }
                if ($properties.Count -eq 0) { Set-PERiskAcceptance @arguments | Out-Null; $count++ }
                else { foreach ($property in $properties) { Set-PERiskAcceptance @arguments -Property $property | Out-Null; $count++ } }
            }
            $refreshed = $false
            try { $null = Invoke-PEStandardCheck -StandardName $standard -BlueprintName $BlueprintName -Tenant $tenant -DataRoot $DataRoot; $refreshed = $true } catch { Write-Warning "The comparison with the standard was not refreshed: $($_.Exception.Message)" }
            return (& $done "Accepted risk recorded ($count note$(if ($count -ne 1) { 's' })). No tenant or blueprint was changed.$(if ($refreshed) { ' The check shows it.' })")
        }
        'RemoveRisk'
        {
            if ($items.Count -eq 0) { throw 'No items in the request.' }
            $standard = [string]$Request.standard
            $removed = 0
            foreach ($item in $items)
            {
                $found = @(Get-PEDecision -Kind RiskAccepted -Tenant $tenant -DataRoot $DataRoot | Where-Object {
                        [string]$_.Tenant -ceq $tenant -and [string]$_.Standard -ceq $standard -and [string]$_.ResourceType -ieq [string]$item.resourceType -and [string]$_.Key -ieq [string]$item.key })
                if ($found.Count -eq 0) { throw "No accepted risk for $($item.resourceType) '$($item.key)' in tenant '$tenant' against '$standard'." }
                foreach ($decision in $found)
                {
                    Remove-PEDecision -Kind RiskAccepted -ResourceType ([string]$decision.ResourceType) -Key ([string]$decision.Key) -Property ([string]$decision.Property) -Tenant $tenant -DataRoot $DataRoot
                    $removed++
                }
            }
            $refreshed = $false
            try { $null = Invoke-PEStandardCheck -StandardName $standard -BlueprintName $BlueprintName -Tenant $tenant -DataRoot $DataRoot; $refreshed = $true } catch { Write-Warning "The comparison with the standard was not refreshed: $($_.Exception.Message)" }
            return (& $done "Accepted risk removed ($removed note$(if ($removed -ne 1) { 's' })). The differences count again.$(if ($refreshed) { ' The check shows them.' })")
        }
        'ImportStandard'
        {
            # Fetches a release (the latest when no tag is given) and imports it as a new version of the standard. No tenant is involved.
            $arguments = @{ Standard = [string]$Request.standard; DataRoot = $DataRoot }
            if ($Request.PSObject.Properties['tag'] -and $Request.tag) { $arguments.Tag = [string]$Request.tag }
            if ($GitScript) { $arguments.Git = $GitScript }
            $summary = Import-PEStandardRelease @arguments -WarningAction SilentlyContinue 6>$null
            $changes = if ($summary.Version -gt 1) { " Since the previous version: $($summary.Added) added, $($summary.Changed) changed, $($summary.Removed) removed." } else { '' }
            return (& $done "Imported '$($summary.Name)' version $($summary.Version) from $($summary.SourceVersion): $($summary.Covered) of $($summary.Total) settings stored, $($summary.NotCovered) not covered.$changes")
        }
        'CheckStandardRelease'
        {
            # Asks the repository for its newest release tag (git ls-remote only, nothing is downloaded) and notes it for the page.
            $standard = [string]$Request.standard
            $arguments = @{ Standard = $standard }
            if ($GitScript) { $arguments.Git = $GitScript }
            $tag = Get-PEStandardLatestTag @arguments
            Write-PEJson -Path (Join-Path (Get-PEDataRoot -Override $DataRoot) "sources\$standard-latest.json") -InputObject ([ordered]@{ tag = $tag; checkedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') })
            return (& $done "The latest release of '$standard' is $tag.")
        }
        default
        {
            throw "Unknown action '$action'."
        }
    }
}

function Format-PEApplyOutcome
{
    # What happened to each item of an apply, from the apply tool's per-resource rows ("Applied: ...; Failed: ... (reason); Not run: ...").
    # Empty when there are no rows. The tool stops at the first failure, so items after it are Not run and nothing depends on them.
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        $Applied
    )

    $rows = @($Applied.ApplyResult.Resources | Where-Object { $null -ne $_ })
    if ($rows.Count -eq 0)
    {
        return ''
    }
    $parts = foreach ($status in 'Applied', 'InDesiredState', 'Failed', 'NotRun')
    {
        $group = @($rows | Where-Object { $_.Status -eq $status })
        if ($group.Count -eq 0) { continue }
        $names = ($group | ForEach-Object {
                $text = [string]$_.ResourceId
                if ($status -eq 'Failed' -and $_.Error) { $text += " ($((([string]$_.Error) -split "`r?`n")[0]))" }
                $text
            }) -join ', '
        "$($status -replace 'NotRun', 'Not run' -replace 'InDesiredState', 'Already correct'): $names"
    }
    return (($parts -join '; ') + '. ')
}
