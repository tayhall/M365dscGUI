# Applying a generated configuration

How a configuration produced by `ConvertTo-PEDscConfig` (and saved by `Save-PEAudit` as `config.ps1`) is compiled and
applied to a tenant with the Writer app registration. Everything here was run against the test tenant
`<test-tenant>.onmicrosoft.com` on 2026-10-21 (Task 11 step 1). `tools\Invoke-PEApply.ps1` is the proven sequence as
a script; `Invoke-PERectify` wraps or replaces it.

## Summary

- **Microsoft365DSC's own route (since 2026-10-23).** Compile with `Invoke-M365DSCConfigurationBuild -Engine Standard` from PowerShell 7,
  read the instances back from the MOF to check them, then apply with `Start-DscConfiguration -Wait -Force` (or test with
  `Test-DscConfiguration -ReferenceConfiguration`) through the Local Configuration Manager, run from Windows PowerShell 5.1
  (`tools\Invoke-PELcm.ps1`). The LCM relays each resource call into a PowerShell 7 session. This is what the module documents
  (`deploying-configurations.md`, `powershell7-support.md`) and what an Azure DevOps pipeline would run.
- **Prerequisites (one time per machine).** An elevated session (and an elevated GUI worker); the `PowerShell.7` WinRM endpoint
  (`Enable-PSRemoting -Force -SkipNetworkProfileCheck` from an elevated PowerShell 7); the pinned Microsoft365DSC (and its
  dependencies) also under `C:\Program Files\WindowsPowerShell\Modules`; the app certificate in `Cert:\LocalMachine\My`
  (the LCM runs as SYSTEM). `New-PETenantApps.ps1` copies the Writer certificate there when it is run elevated.
- **Behaviour.** Resources are applied in MOF order and the LCM carries on after a failed one (nothing is transactional). There is
  no Test after a Set. Success per resource is "in the desired state according to `Get-DscConfigurationStatus`", the engine's drift
  re-check confirms the tenant. The LCM keeps one configuration, so applies are serialised with a machine-wide mutex, and the
  configuration is removed from the LCM afterwards (otherwise it would keep re-testing the tenant). The guards that read the MOF
  (no credentials, no `DependsOn`, resource count, tenant and app match) run before the LCM sees it.
- **Replaced.** The earlier in-process route (`Invoke-DscResource` Test, Set per instance, no LCM, no elevation) is gone; the section
  "The LCM route" below was written when that was the only route that worked on the machine.- Timing: about 6 s module import, 11 s compile (Standard; 1.2 s FastHost), then 40 to 55 s per resource that changes
  (Test + Set + Test) and 10 to 20 s per resource that is already in the desired state.

## Prerequisites

| What | Value |
| --- | --- |
| Shell | `pwsh` 7.6 or later (tested 7.6.7), not elevated |
| Modules (CurrentUser, PowerShell 7 path) | `Microsoft365DSC` 2.26.1015.1 (pin: `src\PolicyEngine\Data\Versions.psd1`), `M365DSC.PSDesiredStateConfiguration` 3.1.10 (the fast-host DSC engine Microsoft365DSC uses to compile) |
| App | Writer app registration, details in `~\.m365dsc-policy\M365DSC-Policy-Writer.json` (`ApplicationId`, `TenantId`, `Thumbprint`) |
| Certificate | Writer certificate with private key in `Cert:\CurrentUser\My` of the user running the apply |
| Working directory | Any. All paths are passed explicitly; the compile pushes into the config's folder itself |

Always `Import-Module Microsoft365DSC -RequiredVersion <pin>`: Microsoft365DSC 1.26.701.1 is installed system-wide for
Windows PowerShell and must never be picked up.

## Configuration data

The generated configuration refers to `$ConfigurationData.NonNodeData.ApplicationId`, `TenantId`,
`CertificateThumbprint` and `OrganizationName`. The `.psd1` passed as `-ConfigurationDataPath`:

```powershell
@{
    AllNodes    = @(@{ NodeName = 'localhost' })
    NonNodeData = @{
        OrganizationName      = '<tenant>.onmicrosoft.com'   # the TenantId value from the app JSON
        TenantId              = '<tenant>.onmicrosoft.com'   # app JSON: TenantId
        ApplicationId         = '<guid>'                     # app JSON: ApplicationId
        CertificateThumbprint = '<thumbprint>'               # app JSON: Thumbprint
    }
}
```

`tools\Invoke-PEApply.ps1` writes exactly this file into its per-run work folder, from the app JSON for `-Role`, when no
`-ConfigurationDataPath` is given, and deletes it afterwards. The thumbprint is not a secret (the private key stays in the certificate store), but
it ends up in the `.psd1` and in the compiled MOF (`CertificateThumbprint = "..."`), so both belong in a temp folder,
never in the repo or the audit folder. The audit `config.ps1` holds only the `$ConfigurationData...` references.

No `PSDscAllowPlainTextPassword` is needed: certificate authentication puts no credential in the MOF.

## The command sequence

```powershell
# pwsh 7.6, not elevated. $ConfigPath = audit folder\config.ps1, $DataPath = ConfigurationData.psd1 (temp),
# $Name = the configuration name given to ConvertTo-PEDscConfig, $Out = a new temp folder.
$ErrorActionPreference = 'Stop'
$pin = (Import-PowerShellDataFile src\PolicyEngine\Data\Versions.psd1).Microsoft365DSC
Import-Module Microsoft365DSC -RequiredVersion $pin -WarningAction SilentlyContinue
Import-Module M365DSC.PSDesiredStateConfiguration -RequiredVersion 3.1.10

# 1. Compile. Throws on a schema error (unknown property, bad type). Output: <Out>\mof\localhost.mof (UTF-16 LE).
$mof = Invoke-M365DSCConfigurationBuild -Path $ConfigPath -ConfigurationDataPath $DataPath `
    -ConfigurationName $Name -OutputPath (Join-Path $Out 'mof') -Engine Standard

# 2. Read the instances back. 4 = MofDeserializerSchemaValidationOption.Ignore. The last instance is the
#    OMI_ConfigurationDocument; skip it.
$instances = [Microsoft.PowerShell.DesiredStateConfiguration.Internal.DscClassCache]::ImportInstances($mof.FullName, 4)

# 3. Test / Set / Test each resource instance, in MOF order (= configuration order).
$meta = 'ModuleName', 'ModuleVersion', 'ResourceID', 'SourceInfo', 'ConfigurationName', 'DependsOn'
foreach ($i in $instances | Where-Object { $_.CimClass.CimClassName -ne 'OMI_ConfigurationDocument' })
{
    $p = @{}
    foreach ($cp in $i.CimInstanceProperties)
    {
        if ($cp.Name -notin $meta -and $null -ne $cp.Value) { $p[$cp.Name] = $cp.Value }   # embedded CIM instances: convert to hashtables (see the tool)
    }
    $invoke = @{
        Name       = $i.CimClass.CimClassName
        ModuleName = @{ ModuleName = $i.CimInstanceProperties['ModuleName'].Value; ModuleVersion = $i.CimInstanceProperties['ModuleVersion'].Value }
        Property   = $p
    }
    if (-not (M365DSC.PSDesiredStateConfiguration\Invoke-DscResource @invoke -Method Test).InDesiredState)
    {
        $null = M365DSC.PSDesiredStateConfiguration\Invoke-DscResource @invoke -Method Set     # throws on a Graph error
        $ok = (M365DSC.PSDesiredStateConfiguration\Invoke-DscResource @invoke -Method Test).InDesiredState   # retry: eventual consistency
    }
}
```

`tools\Invoke-PEApply.ps1` is this sequence with guards, cleanup and a structured result. Its logic lives in
`tools\PEApply.Common.ps1` (`Invoke-PEApply`). `tests\Apply.Tests.ps1` covers it with the module, compile, MOF and
`Invoke-DscResource` calls mocked; a default mock that throws catches any test that would otherwise reach them. Tests
that parse a configuration, and so load the resource schemas, are tagged `Slow`.

```powershell
pwsh -NoProfile -File tools\Invoke-PEApply.ps1 -ConfigPath <audit>\config.ps1 -ConfigurationName PERectify `
    -ExpectedResourceCount <plan items> [-Json] [-Role Writer|Reader] [-ConfigurationDataPath <psd1>] `
    [-OutputPath <parent dir outside the repo>] [-TestOnly | -Preview | -WhatIf] [-KeepOutput] `
    [-Engine Standard|FastHost]
```

**`-ConfigPath` is executed by the compile** (a configuration script is PowerShell code). Pass only trusted,
generated configurations (an audit folder's `config.ps1` written by `Save-PEAudit`).

**`-ExpectedResourceCount` is mandatory for a real apply.** Invoke-PERectify passes the number of plan items.
Test-only runs may omit it.

Guards. They throw, so the script exits 1, before any Test or Set:

- The app JSON for `-Role` (default Writer) is always read. A `-ConfigurationDataPath` must have NonNodeData
  `TenantId` (case-insensitive), `ApplicationId` and `CertificateThumbprint` equal to it, and an `OrganizationName`.
  Without one, the tool writes the configuration data from the app JSON into its work folder.
- `-Role Reader` is allowed only with `-TestOnly` or `-WhatIf`. A Reader run never calls Set.
- `-OutputPath` must not be inside the repository. Checks:
  - UNC (`\\server\...`) and `\\?\` paths are refused.
  - The path is normalised with `GetFullPath`.
  - Every existing junction or symbolic link along it, and along the repo root, is resolved to its target.
  - Both the literal and the resolved path are compared with the repo root.
- After the compile the MOF must pass these checks. They fail closed, so every instance must pass all of them:
  - Module `Microsoft365DSC`, at exactly the pinned version.
  - A resource class that this version exports (`DscResourcesToExport`).
  - `TenantId`, `ApplicationId` and `CertificateThumbprint` all present and equal to the app JSON (tenant
    case-insensitive).
  - None of `Credential`, `ApplicationSecret`, `CertificatePath`, `CertificatePassword`, `ManagedIdentity`,
    `AccessTokens` or `PsDscRunAsCredential`.
  - No `DependsOn`: it is not honoured, because instances run in MOF order.
- The number of MOF instances must equal the number of resource blocks inside `Node` in the configuration script
  (counted from the AST), and `-ExpectedResourceCount`.

Test-only mode: `-TestOnly` (alias `-Preview`) and `-WhatIf` both compile, read the MOF and run Test only. Each resource
reports `InDesiredState` or `WouldChange`, and Set is never called. Declining a `-Confirm` prompt also gives a test-only
run. Only the script maps `-WhatIf`: **in-process callers of the `Invoke-PEApply` function must pass `-TestOnly`
explicitly**, because the function has no `-WhatIf`. The tool's own folder operations ignore the caller's
`-Confirm`/`-WhatIf` preferences: they never prompt and are never skipped.

Work folder: each run uses `<-OutputPath or the OS temp folder>\PEApply-<guid>`. On Windows its ACL is replaced by
full control for the current user only, with no inherited access. It holds the generated `ConfigurationData.psd1` and
`mof\localhost.mof`, both of which carry the certificate thumbprint. A `finally` block deletes it after success, after
failure and after a guard throws. A caller-supplied `-ConfigurationDataPath` is never deleted.

`-KeepOutput` keeps the work folder, and the caller must then delete those thumbprint-bearing files. The kept path is
always reported:

- in `OutputFolder`, which is set as soon as the folder exists, so also after a compile failure
- in a warning
- in the message of any exception thrown: `... (work folder kept: <path>)`

Every error text has the app's certificate thumbprint replaced by `<thumbprint>` (case-insensitive). That covers
`Resources[].Error`, the compile error, exception messages and the `-Json` output.

Output: the result object, or with `-Json` the same object as one line of compact JSON. Exit code: **0** when
`Success`, **2** when the compile or a resource failed (or a Test failed in test-only mode), **1** when a guard threw.

```text
Success               : compile succeeded and no resource Failed (with -TestOnly: every Test ran)
TestOnly              : True for -TestOnly / -Preview / -WhatIf
PartiallyApplied      : True when at least one resource is Applied and at least one is Failed or NotRun
ResourceCount         : instances found in the MOF
ExpectedResourceCount : the -ExpectedResourceCount given, or null (test-only)
OutputFolder, MofPath : only with -KeepOutput (otherwise null; the files are already deleted)
CompileSeconds        : 11.5
ApplySeconds          : 51.8
Error                 : null | 'Compile failed: ...' | 'One or more resources failed: [AADGroup]B'
Resources             : one per instance, in MOF order:
                        ResourceId ('[AADGroup]AADGroup-PE-TEST-Gen-1'), ResourceType,
                        Status (InDesiredState | WouldChange | Applied | Failed | NotRun), InDesiredStateBefore,
                        SetInvoked, RebootRequired (from Set), InDesiredStateAfter, Seconds,
                        Error (the exception message, e.g. Request_BadRequest: ...)
```

The LCM applies the resources in MOF order and carries on after a failed one; the result lists each resource as Applied, Failed (with the LCM's error) or NotRun. There is no Test after a Set. -Engine FastHost prints a warning, because it silently drops unknown properties.

## Detecting success and failure

| Situation | How it shows |
| --- | --- |
| Compile error (unknown property, wrong type, missing Key) with `-Engine Standard` | `Invoke-M365DSCConfigurationBuild` throws, e.g. `The member 'NoSuchProperty' is not valid. Valid members are ...`. No MOF, nothing applied |
| Graph rejects the change | The LCM reports the resource as not in the desired state, with the Graph message in its error, e.g. `Request_BadRequest: Invalid value specified for property 'mailNickname' of resource 'Group'.` Nothing is created for that resource |
| Set returns but the object is not right | Not detected by the apply; the engine's drift re-check of the tenant shows it |
| Success | `Get-DscConfigurationStatus` lists the resource under ResourcesInDesiredState |

`Invoke-DscResource -Method Set` returns an object with `RebootRequired` only; it does not say whether anything
changed, and it never sets an exit code. `tools\Invoke-PEApply.ps1` adds the exit code (0, 1 or 2, as above) from the
result.

## What was run (2026-10-21, test tenant)

All in `pwsh` 7.6.7, not elevated, from scratch folders in the OS temp folder. Read-back with the Reader app
(Graph `GET /v1.0/groups?$filter=startswith(displayName,'PE-TEST-')`, certificate auth).

| Step | Config | Result | Time |
| --- | --- | --- | --- |
| Create | hand-written, one `AADGroup` `PE-TEST-Apply-1` (security, MailNickname, no members) | Test False, Set, Test True; group read back | compile 1.8 s (FastHost); Test 20.6 s, Set 18.6 s, Test 12.7 s |
| Update | same, Description changed | same group id, new description read back | Test 21 s, Set 16 s, Test 14 s |
| Remove | same, `Ensure = 'Absent'` | group gone | Test 20 s, Set 14 s, Test 11 s |
| Generated Create | `ConvertTo-PEDscConfig` (plan: Missing -> Create, Target Replica), saved by `Save-PEAudit` (UTF-8 BOM, pure ASCII, `-join @('PE generated: ', [char]0x00C9, 'quipe ', [char]0x00D1)`) | MOF holds `Description = "PE generated: Équipe Ñ"`; Graph returns `PE generated: Équipe Ñ` | 47 to 70 s end to end |
| Generated Remove | `ConvertTo-PEDscConfig` (plan: TargetOnly + Remove decision passed with `-Decisions`, no data folder written) | group gone | 56 s end to end |
| Failure | three groups A (valid), B (`MailNickname = 'bad nick (x)@'`), C (valid) | A Applied, B Failed (`Request_BadRequest ... mailNickname`), C NotRun; B not created; A stayed (removed in cleanup) | 81 s |
| Unknown property | `NoSuchProperty = 'y'` added | FastHost compiled it **silently without the property** and applied the rest; Standard threw | |
| Idempotent re-run | cleanup config, everything already absent | all `InDesiredState`, no Set | 56 s for 3 resources |

The generated `config.ps1` (UTF-8 with BOM, pure ASCII) also compiles in Windows PowerShell 5.1 with
`Invoke-M365DSCConfigurationBuild` (after putting the PowerShell 7 module folder on `PSModulePath`); its MOF is identical
to the PowerShell 7 one apart from the generation header. The BOM is harmless in both shells; since the text is pure
ASCII, it does not change the decoding either.

## Gotchas

1. **FastHost drops unknown properties silently.** `-Engine FastHost` (and `Auto`, which picks it) compiled a config
   with a misspelt property, left the property out of the MOF and gave no error. Use `-Engine Standard` (about 10 s
   slower), which validates property names. `ConvertTo-PEDscConfig` already rejects unknown properties, so this is
   defence in depth.
2. **AADGroup Create restores from the recycle bin.** If a deleted group with the same DisplayName is in
   `directory/deletedItems`, Set restores it (same object id, old settings) and then updates it; if more than one deleted
   group has that name, Set throws. A Remove (`Ensure = 'Absent'`) is a soft delete: the group stays in the recycle bin
   for 30 days. Tests that create and remove the same name repeatedly must purge it
   (`DELETE /v1.0/directory/deletedItems/{id}` with the Writer app).
3. **Eventual consistency.** Right after a restore, the Test after Set returned `False` once; the same Test a minute
   later returned `True`. The tool retries the Test after Set (3 times, 15 s apart) before calling it a failure.
4. **Not transactional.** Resources run one after another; a failure leaves the earlier ones applied. The generated
   config lists one resource per plan item, so per-item results map straight back to the plan. Invoke-PERectify should
   report per item and rely on the delta re-check rather than assume all-or-nothing.
5. **Slow per call.** Each `Invoke-DscResource` call takes 10 to 20 s (it loads the resource module in a fresh runspace
   and connects to Graph). Large plans take minutes. The order is the configuration order.
6. **Not honoured or not tested.** `DependsOn` is not evaluated, so the tool refuses a MOF that has it; the generator
   never emits it. `RebootRequired` is only reported. `PsDscRunAsCredential` and `Credential` were neither used nor
   tested: authentication is the certificate in the configuration data, as the current user.
7. **Only AADGroup was tested live**, and only with simple properties. Embedded CIM instances (complex properties such
   as `AssignedLicenses`) come out of the MOF as `CimInstance` values; the tool converts them to hashtables before
   `Invoke-DscResource`, but that path has not been run against a tenant. Treat the first apply of every other
   resource type as a test.
8. **DSC itself sets no exit code.** In the raw runs above every process exited 0, failures included. The tool derives
   its exit code from the result (0, 1 or 2); in-process callers read `Success` from the result object.
9. **The MOF and the configuration data contain the thumbprint.** The tool keeps them in its per-user work folder and
   deletes them itself (see the work folder above). Only `-KeepOutput` leaves them behind.
10. **The configuration script is code.** Compiling runs it, so only trusted, generated files may be passed.

## The LCM route (not used)

Microsoft365DSC 2.x documents `Start-DscConfiguration -Path <mof folder> -Wait -Verbose -Force` from Windows
PowerShell 5.1, with the LCM relaying each resource call into PowerShell 7 over WinRM. Tried non-elevated:

```text
PS 5.1> Start-DscConfiguration -Path <scratch>\mof -Wait -Verbose -Force
VERBOSE: Perform operation 'Invoke CimMethod' ... 'methodName' = SendConfigurationApply, 'className' = MSFT_DSCLocalConfigurationManager ...
The WS-Management service cannot process the request. The WMI service returned an 'access denied' error.  (17 s)
PS 5.1> Get-DscLocalConfigurationManager
Access denied
```

It would need all of: an elevated Windows PowerShell 5.1; Microsoft365DSC 2.26.1015.1 installed under
`C:\Program Files\WindowsPowerShell\Modules` (only 1.26.701.1 is there now); `Enable-PSRemoting -Force
-SkipNetworkProfileCheck` from an elevated PowerShell 7 to register the `PowerShell.7` endpoint; the Writer certificate
in `Cert:\LocalMachine\My` (the LCM runs as SYSTEM and cannot see the user's store). It also leaves the configuration
in the LCM, which then re-checks the tenant every 15 minutes unless it is removed. None of that is needed for the
`Invoke-DscResource` route, so the policy engine does not use the LCM.

If the LCM is ever used, reset it afterwards from an elevated Windows PowerShell 5.1:

```powershell
Stop-DscConfiguration -Force
foreach ($stage in 'Pending', 'Current', 'Previous')
{
    Remove-DscConfigurationDocument -Stage $stage -Force
}
```

The failed attempt above was rejected before any MOF was sent, so no LCM state was created. The `Invoke-DscResource`
route never touches the LCM.

## Cleanup after an apply

- Nothing to do locally: the tool deletes its work folder (MOF and generated `ConfigurationData.psd1`) in a `finally`
  block. Only after a `-KeepOutput` run does the caller delete `OutputFolder`. A caller's own
  `-ConfigurationDataPath` file is the caller's to delete.
- For tests: remove the test objects with `Ensure = 'Absent'` and purge them from `directory/deletedItems` (gotcha 2),
  then verify with a Reader read. All `PE-TEST-*` groups created on 2026-10-21 were removed and purged, and a Reader
  read of `groups` and `directory/deletedItems` for `PE-TEST-` returned 0 objects.

## Invoke-PERectify

`Invoke-PERectify` (src\PolicyEngine\Public\Invoke-PERectify.ps1) runs a rectify plan end to end: generate, audit,
apply, recheck and, for Promote, update the blueprint.

```powershell
$plan = New-PERectifyPlan -Findings $selected -Action Create -Source $checkState -Blueprint (Get-PEBlueprint -Name main)
Invoke-PERectify -Plan $plan -Target Replica -BlueprintName main -WhatIf      # generate + audit + preview only
Invoke-PERectify -Plan $plan -Target Replica -BlueprintName main
Invoke-PERectify -Plan $promote -Target Master -BlueprintName main -ConfirmMasterWrite -Reason 'built in Dev first'
```

It returns `AuditPath`, `Applied`, `PartiallyApplied`, `ApplyResult` (the tool's result object), `RecheckFindings`,
`Warnings` and `BlueprintVersionCreated`. It throws only before the apply starts; after that every failure becomes a
warning and `result.json` is still written.

Order of operations:

1. **Preconditions** (nothing written yet). These must all hold:
   - The plan is not empty.
   - Every item was issued by `New-PERectifyPlan` **in this PowerShell session** and is unchanged. The registry is
     per process, so a plan saved to disk or made in another session is refused.
   - The plan has not been applied before. A plan is **single-use**: once a real apply is launched its items are
     consumed, and a second run throws `plan already applied; make a new plan`. A `-WhatIf` run, a declined
     `-Confirm` or a failed precondition does not consume it.
   - Target Master has no Remove item.
   - Target Master and any Promote item need `-ConfirmMasterWrite`. The error names the items.
   - Promote needs a non-empty `-Reason`.
   - Every item's check state comes from the Writer app's tenant: its `SourceIdentity.TenantId` must equal the
     `TenantId` of the Writer app JSON (case-insensitive), read with the apply tool's own `Get-PEApplyApp`. An empty
     or `unknown` tenant is refused.
   - Every item was planned against the **latest** version of `-BlueprintName`: the plan's blueprint version, and its
     ExportedAt when both are known. Otherwise: `blueprint changed since the plan was made; re-run the check`. A
     version file without `Meta.Version` counts as version 1.
2. **Generate and audit**: `ConvertTo-PEDscConfig` (`-ConfigurationName`, default `PERectify`), then `Save-PEAudit`
   (`-User`, default `$env:USERNAME`). The audit folder is never deleted afterwards. With `-WhatIf` (or a declined
   `-Confirm`) the run stops here: the preview goes to the host, `result.json` is written with `Preview = true`, and the
   result has `Applied = $false` and the audit path.
3. **Apply**: first the saved `config.ps1` is re-hashed and compared with `plan.json`'s `ConfigSha256` and with the
   registered configuration; a mismatch throws, and nothing is applied. Then `apply-started.txt` is written to the
   audit folder (so a preview, a crashed run and a hung run can be told apart) and the plan is consumed.
   `-ApplyScript` gets `-ConfigPath <audit>\config.ps1`, `-ExpectedResourceCount <plan items>` and
   `-ConfigurationName`, and returns the tool's result object. The default runs
   `<$PSHOME>\pwsh.exe -NoProfile -File tools\Invoke-PEApply.ps1 ... -Role Writer -Json` (this installation's
   pwsh, not the first on PATH) and reads stdout and stderr asynchronously and separately. The result is the last
   stdout line that parses as a JSON object with `Success` and `Resources`; stderr is never parsed (JSON there, such as
   a Graph error body, cannot replace the result) and is reported, capped, in a warning when the exit code is not 0 or
   no result was found. No result with exit code 0 or 2 is an `APPLY STATE UNKNOWN` (`PartiallyApplied = $null`). The child is
   killed with its whole process tree after `-ApplyTimeoutMinutes` (default 10 + 3 per plan item, 1 to 720); a
   timeout gives `Applied = $false`, `PartiallyApplied = $null` and an `APPLY STATE UNKNOWN` warning naming the audit
   folder. Warnings never stop the run once the apply has started (a caller's `-WarningAction Stop` included);
   they are always in the result and in `result.json`. The `apply-started.txt` marker is removed again if consuming
   the plan fails before the launch. The Writer app is used for both targets. Exit code 1 without JSON means nothing ran (a guard) or the
   child failed to start. The tool writes
   and deletes the thumbprint-bearing configuration data itself; its `OrganizationName` is the app's `TenantId`
   domain. The apply counts as `Applied` only when all of these hold:
   - `Success` is true.
   - There is one row per plan item.
   - The resource types match the plan's as a multiset. The tool itself only checks the count.
   - Every row is `Applied` or `InDesiredState`.

   Otherwise `Applied = $false`. `PartiallyApplied` comes from the tool; it is also `$true` when any row is
   `Applied`, and `$null` when the apply threw, timed out or returned nothing, or its result could not be processed.
4. **Recheck**, only after a verified apply. `-RecheckScript` gets `-Items` (the frozen plan item snapshots) and
   returns findings. The default (`Invoke-PERectifyRecheck`, Reader app):
   - **Create, Update, Promote**: re-exports those keys with `Export-PEDelta`, then runs `Compare-PEState` against a
     state of only the planned records, applying the decisions of `-DataRoot` (accepted-noise rules hide what they
     cover). A difference is `Changed`. An object that is not there makes the filtered export throw (no completion
     mark), so it shows as a recheck warning with `RecheckFindings = $null`, not as a `Missing` finding.
   - **Remove**: exports the whole type (`Export-PEDelta -WholeType`), because a filtered export of an absent object
     logs no completion mark and throws. A key that is still present is `TargetOnly`.

   `RecheckFindings` is `@()` when clean. It is `$null` when the recheck was skipped (failed apply) or threw. A
   recheck that throws does not undo `Applied = $true`; it only adds a warning.
5. **Promote**: runs only after a successful apply and a clean recheck. It builds a master state (the latest blueprint
   plus the promoted records). `Get-PEBlueprintChange` then yields one `Missing` per promoted key, and
   `Approve-PEBlueprintChange` accepts exactly those, with the `-Reason`. The result is one new blueprint version with
   only those items added. If this fails, `Applied` stays `$true` and a warning says the master and the blueprint are
   out of step, and how to fix it.

When the run ends, it writes `result.json` to the audit folder (`Preview` true or false): the outcome, the redacted apply result, the recheck
findings (kind, type, key and changed property names only) and the warnings.

Safety gates: no apply unless every precondition, the generation and the audit write succeeded. The Reader and
Writer certificate thumbprints and application ids are replaced by `<redacted>` in `ApplyResult`, the warnings and
`result.json`. `RecheckFindings` are tenant data and come back unchanged.

Limits:

- In v1, Replica and Master are the same tenant (the Writer app's). `-Target` only decides which actions the
  configuration may contain, so a Promote apply is an idempotent no-op that still creates the blueprint version.
- The recheck re-exports with the Reader app right after the apply. It relies on the apply's own Test-after-Set
  retries for eventual consistency.
- A Create whose object is missing at recheck time makes the filtered export throw. That surfaces as a recheck
  warning, not a `Missing` finding.
- The recheck compares against the planned record: a property that the record leaves out but the tenant reports with
  a non-empty value (for example a hand-built blueprint record) is a `Changed` finding, just as the next check would
  report it.
- Not thread-safe. The blueprint lock only guards the Promote approval.

### Live run (2026-10-22, test tenant)

Run from a temp data root (never `data\`), with a hand-built blueprint holding `PE-TEST-Rectify-1` (security group,
no members):

| Step | What ran | Result | Time |
| --- | --- | --- | --- |
| Target | `Export-PEDelta -WholeType` (Reader, 27 groups) | key not found; finding `Missing` | 26 s |
| WhatIf | `Invoke-PERectify -WhatIf` | audit saved, preview printed, nothing applied | 6 s |
| Create | `Invoke-PERectify -Target Replica` | compile 8.3 s, Test/Set/Test `Applied` 38 s; filtered recheck clean (`RecheckFindings` 0); Reader read shows the group | 84 s |
| Remove | blueprint without the group, Remove decision, `Invoke-PERectify -Target Replica` | `Applied`, 37 s; whole-type recheck clean; a separate whole-type read: key not found | 86 s |
| Cleanup | `DELETE directory/deletedItems/{id}` (Writer) | purged | |

The first attempt found a gap. A whole-type export through `Invoke-PELoggedCommand` writes instance `[1/n]` on the
Extracting line (after a literal `\r\n`). `Read-PEExportLog` therefore saw `[2/n]` as out of sequence and reported
the type `Incomplete`. The parser now records that first instance and treats the mark on the Extracting line as
provisional. It becomes Ok when the last `[n/n]` instance line completes, or, when no further instance line
follows, when a DSC-written line closes the block: the next component's Extracting line or the export summary
(`Export took ...`, `Successful exports`). A single exported object is printed as `[1/<property count>]` (for
example `[1/15]`), so the count alone cannot tell a one-object block from a cut-off one. A log that ends right after
the merged instance is Incomplete (tests in `tests\ExportLog.Tests.ps1`).
