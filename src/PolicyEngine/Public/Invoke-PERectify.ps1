function Invoke-PERectify
{
    <#
    .SYNOPSIS
    Applies a rectify plan to a tenant: generates the configuration, saves the audit folder, applies it with the Writer
    app, re-checks the same objects and, for Promote, updates the blueprint for those items only.

    .DESCRIPTION
    Order of operations (nothing is applied unless every step before the apply succeeds):
    1. Preconditions: a non-empty plan of items issued by New-PERectifyPlan in THIS session, unchanged since and not
       applied before (the registry is per process, so a plan read back from disk or made in another session is
       refused; a plan whose real apply started is consumed: 'plan already applied; make a new plan');
       -ConfirmMasterWrite for Target Master or any Promote item; a non-empty -Reason for Promote;
       every item planned from the Writer app's tenant (its check state's TenantId, case-insensitive; unknown is
       refused) and against the LATEST version of -BlueprintName (otherwise 'blueprint changed since the plan was
       made; re-run the check').
    2. ConvertTo-PEDscConfig (-ConfigurationName, default PERectify) and Save-PEAudit (-User, default $env:USERNAME).
       The audit folder is never removed afterwards. With -WhatIf (or a declined -Confirm) it stops here: the preview
       is written to the host, result.json is written with Preview = $true, and AuditPath is returned with Applied
       $false; neither apply nor recheck runs and the plan stays usable.
    3. Apply: the saved config.ps1 is re-hashed against plan.json and the registered configuration (a mismatch throws,
       nothing applied); an 'apply-started.txt' marker is written and the plan items are consumed; then -ApplyScript is
       called with -ConfigPath <audit>\config.ps1, -ExpectedResourceCount <plan items> and -ConfigurationName, and
       returns the result object of tools\Invoke-PEApply.ps1 -Json. The default runs that tool in a child pwsh (this
       installation's) with the Writer app (for both targets), killed with its process tree after -ApplyTimeoutMinutes
       (default 10 + 3 per item). Applied is $true only when Success is true, there is one resource row per plan item,
       the ResourceTypes are the plan's (as a multiset) and every row is Applied or InDesiredState. Otherwise Applied
       is $false and PartiallyApplied comes from the tool (also $true when any row was Applied; $null when unknown:
       timeout, crash, no result); the recheck is skipped (RecheckFindings $null).
    4. Recheck: -RecheckScript is called with -Items <the plan items' frozen snapshots: Action, ResourceType, Key,
       Record, ...> and returns findings. The default re-exports Create/Update/Promote objects with the Reader app and
       compares them with the planned records (Compare-PEState, with the decisions of -DataRoot), and exports Remove
       types whole to confirm the keys are gone (see Invoke-PERectifyRecheck). RecheckFindings is @() when clean. A
       recheck that throws does not undo a successful apply: Applied stays $true, RecheckFindings is $null and the
       error is a warning.
    5. Promote: after a successful apply and a clean recheck, the blueprint gets one new version with exactly the
       promoted records (Approve-PEBlueprintChange, Reason = -Reason); BlueprintVersionCreated is that version. If that
       fails, Applied stays $true and a warning says the master and the blueprint are out of step.
    Every warning is also written with Write-Warning. The app thumbprints and application ids are replaced by
    '<redacted>' in ApplyResult, the warnings and the audit's result.json. RecheckFindings are tenant data and returned
    as they are. In v1 both targets are the Writer app's tenant; -Target only decides which actions the configuration
    may contain.

    Returns [pscustomobject]@{ AuditPath; Applied; PartiallyApplied; ApplyResult; RecheckFindings; Warnings;
    BlueprintVersionCreated }. Throws only before the apply starts (failed preconditions, generation, audit write or
    audit integrity check); once it has started, every failure becomes a warning and result.json is written.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param
    (
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Plan,

        [Parameter(Mandatory)]
        [ValidateSet('Replica', 'Master')]
        [string]$Target,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$BlueprintName,

        [string]$ConfigurationName = 'PERectify',

        [string]$Reason,

        # Required for Target Master and for any Promote item: they write to the master tenant.
        [switch]$ConfirmMasterWrite,

        [scriptblock]$ApplyScript,

        [scriptblock]$RecheckScript,

        # Timeout of the default apply child; default 10 minutes + 3 per plan item.
        [ValidateRange(1, 720)]
        [int]$ApplyTimeoutMinutes,

        [ValidatePattern('(?-i)\A[a-z0-9][a-z0-9-]{0,39}\z')]
        [string]$Tenant = 'master',

        [string]$DataRoot,

        [string]$User
    )

    Assert-PEBlueprintNotStandard -Name $BlueprintName -Action 'apply it to a tenant' -DataRoot $DataRoot

    # 1. Preconditions, before anything is generated, saved or applied.
    $items = @($Plan | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0)
    {
        throw 'The plan is empty: nothing to rectify.'
    }
    Assert-PERectifyPlanUnused -Items $items
    # Validates every item (issued by New-PERectifyPlan in this session, unchanged); from here on only the frozen
    # snapshots are read.
    $snapshotSet = Get-PEPlanSnapshotSet -Items $items
    $snapshots = @($snapshotSet.Snapshots)
    $labels = @($snapshots | ForEach-Object { "$($_.Action) $($_.ResourceType) '$($_.Key)'" })
    $promotes = @($snapshots | Where-Object Action -EQ 'Promote')
    if (-not $ConfirmMasterWrite)
    {
        if ($Target -eq 'Master')
        {
            throw "Target Master writes to the master tenant; pass -ConfirmMasterWrite to apply: $($labels -join ', ')."
        }
        if ($promotes.Count -gt 0)
        {
            throw "Promote writes to the master tenant; pass -ConfirmMasterWrite to apply: $(($promotes | ForEach-Object { "Promote $($_.ResourceType) '$($_.Key)'" }) -join ', ')."
        }
    }
    if ($promotes.Count -gt 0 -and [string]::IsNullOrWhiteSpace($Reason))
    {
        throw 'Promote changes the blueprint; pass -Reason (recorded in the blueprint change record).'
    }
    Assert-PEModuleVersion -BlueprintName $BlueprintName -DataRoot $DataRoot
    $writer = Get-PERectifyWriterApp -Tenant $Tenant
    Assert-PERectifyTenant -Items $snapshots -TenantId ([string]$writer.TenantId)
    Assert-PERectifyBlueprintVersion -Items $snapshots -Name $BlueprintName -DataRoot $DataRoot
    if ([string]::IsNullOrWhiteSpace($User))
    {
        $User = if ($env:USERNAME) { $env:USERNAME } else { [System.Environment]::UserName }
    }
    if (-not $PSBoundParameters.ContainsKey('ApplyTimeoutMinutes'))
    {
        $ApplyTimeoutMinutes = [math]::Min(720, 10 + 3 * $items.Count)
    }

    $proceed = $PSCmdlet.ShouldProcess(
        "$Target tenant (Writer app): $($items.Count) resource instance(s): $($labels -join ', ')",
        'Apply rectify configuration')
    # From here the function's own file operations must run whatever -WhatIf / -Confirm said.
    $WhatIfPreference = $false
    $ConfirmPreference = 'None'

    # 2. Generate and save the audit before anything is applied.
    # Users named in a policy are looked up in the target tenant and rendered as object ids (Data\IdentityReferences.psd1).
    $userIds = $null
    if (@($items | Where-Object { @(Get-PEUserSetPath -ResourceType ([string]$_.ResourceType)).Count -gt 0 }).Count -gt 0)
    {
        $userIds = New-PEUserIdResolver -Tenant $Tenant
    }
    # The Id of an object whose own Id is its DSC key (Data\IdentityReferences.psd1, OwnIds) is looked up in a target other than the blueprint's tenant.
    $ownIds = $null
    if (@($items | Where-Object { Test-PEOwnIdType -ResourceType ([string]$_.ResourceType) }).Count -gt 0)
    {
        $blueprintTenant = Get-PEMetaValue -Meta (Get-PEBlueprint -Name $BlueprintName -DataRoot $DataRoot).Meta -Name 'TenantId'
        if (Test-PECrossTenant -BlueprintTenantId $blueprintTenant -TargetTenantId (Get-PEReaderTenantId -Tenant $Tenant))
        {
            $ownIds = New-PEOwnIdResolver -Tenant $Tenant
        }
    }
    try
    {
        $ownIdBlock = $null
        if ($ownIds) { $ownIdBlock = { param ($type, $key) $ownIds.Resolve($type, $key) }.GetNewClosure() }
        $resolverBlock = $null
        if ($userIds) { $resolverBlock = { param ($upn) $userIds.Resolve($upn) }.GetNewClosure() }
        $config = ConvertTo-PEDscConfig -Plan $items -ConfigurationName $ConfigurationName -Target $Target -UserIdResolver $resolverBlock -OwnIdResolver $ownIdBlock
    }
    finally
    {
        if ($userIds) { $userIds.Close() }
    }
    $auditPath = Save-PEAudit -Plan $items -Config $config -User $User -DataRoot $DataRoot
    $configPath = Join-Path $auditPath 'config.ps1'

    $redaction = [string[]]@(Get-PERectifyRedaction | ForEach-Object { $_ })
    $warnings = [System.Collections.Generic.List[string]]::new()
    $warn = {
        param ([string]$Text)
        $safe = Protect-PERectifyText -Text $Text -Values $redaction
        $warnings.Add($safe)
        # Never throws (a caller's -WarningAction Stop must not stop the run after the apply started); the warning is
        # in the result and in result.json either way.
        try
        {
            Write-Warning $safe
        }
        catch
        {
            $null = $_
        }
    }
    $output = [ordered]@{
        AuditPath               = $auditPath
        Applied                 = $false
        PartiallyApplied        = $false
        ApplyResult             = $null
        RecheckFindings         = $null
        Warnings                = @()
        BlueprintVersionCreated = $null
    }
    $writeSummary = {
        param ([bool]$Preview)
        $output.Warnings = $warnings.ToArray()
        $summary = [ordered]@{
            CompletedAt             = (Get-PEUtcNow).ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [cultureinfo]::InvariantCulture)
            Preview                 = $Preview
            Applied                 = $output.Applied
            PartiallyApplied        = $output.PartiallyApplied
            ApplyResult             = $output.ApplyResult
            RecheckFindings         = $(if ($null -eq $output.RecheckFindings) { $null } else {
                    @(@($output.RecheckFindings) | ForEach-Object {
                            [ordered]@{
                                Kind              = [string]$_.Kind
                                ResourceType      = [string]$_.ResourceType
                                Key               = [string]$_.Key
                                ChangedProperties = [string[]]@(@($_.Differences) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.Property })
                            }
                        })
                })
            Warnings                = $output.Warnings
            BlueprintVersionCreated = $output.BlueprintVersionCreated
        }
        try
        {
            Write-PEJsonNew -Path (Join-Path $auditPath 'result.json') -InputObject $summary
        }
        catch
        {
            & $warn "Could not write result.json to the audit folder: $($_.Exception.Message)"
            $output.Warnings = $warnings.ToArray()
        }
    }

    if (-not $proceed)
    {
        $preview = @("Preview (nothing applied): $($items.Count) resource instance(s) to the $Target with the Writer app; configuration saved at $configPath") +
        @($labels | ForEach-Object { "  $_" })
        Write-Host ($preview -join "`n")
        & $writeSummary $true
        return [pscustomobject]$output
    }

    # 3. Apply. The saved file must still be exactly the generated, registered configuration.
    Assert-PERectifyAuditIntact -AuditPath $auditPath -Config $config -PlanFingerprint $snapshotSet.Plan
    # The marker is the last step before the launch: if consuming the plan fails, it is removed again (nothing ran).
    $startedAt = (Get-PEUtcNow).ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [cultureinfo]::InvariantCulture)
    $marker = Join-Path $auditPath 'apply-started.txt'
    Write-PETextNew -Path $marker -Text "Apply started (UTC): $startedAt`nUser: $(ConvertTo-PEAuditText -Text $User)`n"
    try
    {
        Complete-PERectifyPlanUse -Items $items
    }
    catch
    {
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        throw "Could not mark the plan as used, so nothing was applied: $($_.Exception.Message)"
    }
    # From here nothing throws: every failure becomes a warning and result.json is written.

    $result = $null
    $applyError = $null
    try
    {
        $applyArguments = @{ ConfigPath = $configPath; ExpectedResourceCount = $items.Count; ConfigurationName = $ConfigurationName }
        $result = if ($ApplyScript)
        {
            @(& $ApplyScript @applyArguments | Where-Object { $null -ne $_ }) | Select-Object -Last 1
        }
        else
        {
            Invoke-PERectifyApplyTool @applyArguments -TimeoutMinutes $ApplyTimeoutMinutes -Tenant $Tenant
        }
    }
    catch
    {
        $applyError = $_.Exception.Message
    }
    try
    {
        if ($null -eq $result)
        {
            # Unknown: the apply may have changed some objects before it failed.
            $output.PartiallyApplied = $null
            $why = if ($applyError) { "The apply failed: $applyError." } else { 'The apply returned no result.' }
            & $warn "$why What was applied is unknown; re-run the check before trying again. Audit folder: $auditPath."
        }
        else
        {
            $output.ApplyResult = Protect-PERectifyObject -InputObject $result -Values $redaction
            if ($result.PSObject.Properties['StdErr'] -and $result.StdErr)
            {
                & $warn "The apply tool wrote to stderr: $($result.StdErr)"
            }
            $problems = [string[]]@(Test-PERectifyApplyResult -Result $result -Items $snapshots | ForEach-Object { $_ })
            if ($problems.Count -eq 0)
            {
                $output.Applied = $true
            }
            elseif ($result.PSObject.Properties['TimedOut'] -and $result.TimedOut -eq $true)
            {
                $output.PartiallyApplied = $null
                & $warn "APPLY STATE UNKNOWN: $($result.Error) Do not re-apply blindly: re-run the check first. The configuration that was being applied is in $auditPath."
            }
            else
            {
                # PartiallyApplied from the tool; also $true when any row was Applied (something changed in the tenant).
                $anyApplied = @(@($result.Resources) | Where-Object { $null -ne $_ -and $_.Status -eq 'Applied' }).Count -gt 0
                $toolValue = if ($result.PSObject.Properties['PartiallyApplied']) { $result.PartiallyApplied } else { $false }
                $output.PartiallyApplied = if ($anyApplied -or $toolValue -eq $true) { $true } elseif ($null -eq $toolValue) { $null } else { $false }
                if ($null -eq $output.PartiallyApplied)
                {
                    & $warn "APPLY STATE UNKNOWN: $($problems -join ' ') Something may have been applied: re-run the check before trying again. Audit folder: $auditPath."
                }
                else
                {
                    & $warn "The apply did not succeed: $($problems -join ' ') Audit folder: $auditPath."
                }
            }
        }
    }
    catch
    {
        $output.Applied = $false
        $output.PartiallyApplied = $null
        & $warn "The apply result could not be processed: $($_.Exception.Message). What was applied is unknown; re-run the check. Audit folder: $auditPath."
    }

    # 4. Recheck, only after a verified apply.
    if ($output.Applied)
    {
        try
        {
            $raw = if ($RecheckScript)
            {
                & $RecheckScript -Items $snapshots
            }
            else
            {
                $sourceTenantId = Get-PEMetaValue -Meta (Get-PEBlueprint -Name $BlueprintName -DataRoot $DataRoot).Meta -Name 'TenantId'
                $cross = if (Test-PECrossTenant -BlueprintTenantId $sourceTenantId -TargetTenantId (Get-PEReaderTenantId -Tenant $Tenant)) { 'Yes' } else { 'No' }
                Invoke-PERectifyRecheck -Items $snapshots -DataRoot $DataRoot -Tenant $Tenant -CrossTenant $cross
            }
            # @() when clean (never $null: $null means the recheck did not run).
            $findings = @($raw | Where-Object { $null -ne $_ })
            $output.RecheckFindings = $findings
            if ($findings.Count -gt 0)
            {
                & $warn "The recheck found $($findings.Count) difference(s) between the tenant and the plan: $((@($findings) | ForEach-Object { "$($_.Kind) $($_.ResourceType) '$($_.Key)'" }) -join ', ')."
            }
        }
        catch
        {
            $output.RecheckFindings = $null
            & $warn "The apply succeeded but the recheck failed: $($_.Exception.Message). Re-run the check to confirm the result."
        }
    }
    else
    {
        & $warn 'The recheck was skipped because the apply did not succeed; RecheckFindings is null. Re-run the check to see the current state.'
    }

    # 5. Promote: the blueprint follows the master for exactly the promoted items.
    if ($promotes.Count -gt 0 -and $output.Applied)
    {
        $outOfStep = "The master was changed but blueprint '$BlueprintName' was NOT updated, so the master and the blueprint are now out of step for: $(($promotes | ForEach-Object { "$($_.ResourceType) '$($_.Key)'" }) -join ', ')."
        if ($null -eq $output.RecheckFindings -or @($output.RecheckFindings).Count -gt 0)
        {
            & $warn "$outOfStep The recheck was not clean. Re-run the check; then update the blueprint with Get-PEBlueprintChange / Approve-PEBlueprintChange for these items, or Promote them again."
        }
        else
        {
            try
            {
                $output.BlueprintVersionCreated = Update-PERectifyBlueprint -Name $BlueprintName -Items $snapshots -Reason $Reason -DataRoot $DataRoot
            }
            catch
            {
                & $warn "$outOfStep The blueprint update failed: $($_.Exception.Message). Fix the cause, then update the blueprint with Get-PEBlueprintChange / Approve-PEBlueprintChange accepting only these items (Kind Missing). Audit folder: $auditPath."
            }
        }
    }

    & $writeSummary $false
    return [pscustomobject]$output
}
