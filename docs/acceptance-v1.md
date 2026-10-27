# Acceptance of the drift policy engine v1 (Task 13)

End-to-end run of the engine on the live test tenant `<test-tenant>.onmicrosoft.com`, which acts as both master and
replica (see the design, "Test setup"). Run on 2026-10-22 from branch `feature/policy-engine` in `pwsh` 7.6, not
elevated. Reads use the Reader app, tenant writes the Writer app (certificate auth). Every object created for the run
is named `PE-TEST-*`. The blueprint, checks, decisions and audit folders live in the git-ignored `data\` folder
(blueprint `test`); nothing from `data\` is in the repository.

This file is a running log: it was committed in pieces while the run went on.

## Scenario

| Step | What | Expected |
| --- | --- | --- |
| 0 | Baseline objects created before the blueprint: groups `PE-TEST-Baseline-Group`, `PE-TEST-Delete-Me`, `PE-TEST-Rename-Me`; Conditional Access policy `PE-TEST-CA-ReportOnly` (report-only); Intune policy `PE-TEST-Intune-Win10` assigned to `PE-TEST-Baseline-Group` | all in the blueprint |
| 1 | Full Reader export, blueprint `test` v1, status against the same export | v1; everything aligned |
| 2 | Drift via the Writer app: new group, deleted group, renamed group, CA setting, Intune setting | |
| 3 | Quick scan, delta export | new/removed/renamed groups; no CA/Intune report |
| 4 | Full check | CA and Intune `Changed`, assignment by group name; licence failures NotChecked/NotAvailable |
| 5 | Decide and rectify (Unmanaged, Create, Remove, Update) with `Invoke-PERectify` | next Full check aligned |
| 6 | Promote; blueprint change approval | v2 (promote), v3 (approval) |
| 7 | Scheduled tasks | a Scan result appears; tasks removed |
| 8 | Cleanup | no `PE-TEST-*` object left |

## Step 0: baseline objects

Tenant before the run (Reader read): no `PE-TEST-*` groups (live or deleted), three Microsoft-provided Conditional
Access policies, two Intune device configurations, one compliance policy, no settings-catalog policies. The tenant has
Intune (the first export already held Intune device configuration and compliance policies), so the Intune test needs no
substitute resource.

Created with the Writer app by direct Graph calls (`Invoke-MgGraphRequest`, certificate auth; a scratch script, not in
the repo):

| Object | Graph call | Settings |
| --- | --- | --- |
| `PE-TEST-Baseline-Group`, `PE-TEST-Delete-Me`, `PE-TEST-Rename-Me` | `POST /v1.0/groups` | security group, not mail-enabled, description `Policy engine acceptance test (<name>)`, no members |
| `PE-TEST-CA-ReportOnly` | `POST /v1.0/identity/conditionalAccess/policies` | state `enabledForReportingButNotEnforced`; users: include group `PE-TEST-Baseline-Group` only (no members); applications: All; client apps: all; grant: MFA. Report-only and memberless, so it cannot block anyone |
| `PE-TEST-Intune-Win10` | `POST /beta/deviceManagement/deviceConfigurations` (`windows10GeneralConfiguration`), then `POST .../{id}/assign` | `cameraBlocked = true`; assigned to `PE-TEST-Baseline-Group` (group assignment target) |

Read back with the Reader app: all five present, the CA policy in report-only state, the Intune policy with one
assignment.

## Step 1: blueprint `test` v1

- Full Reader export: `pwsh -NoProfile -File tools\Export-M365DscTenant.ps1 -OutputPath data\exports\blueprint-test-<ts>`,
  run in the background. **28 min 24 s**; export.log: 400 successful, 29 failed components (the same 29 licence,
  feature and permission failures as the first export: Entra Internet Access / filtering / remote network (403),
  B2C / self-service sign-up, Lifecycle Workflows (Governance licence), Verified ID (401), Windows 365 (accessDenied),
  EXO cmdlets missing from the tenant, EXOMessageClassification server error, EXOSweepRule read scope,
  EXODynamicDistributionGroup email-address-policy permission).
- There was no command that builds a State from an export folder (`Invoke-PEFullCheck` does it only internally,
  against an existing blueprint), so two NEW files were added: `src\PolicyEngine\Public\New-PEStateFromExport.ps1`
  (same rules as the full check: Failed/Incomplete components from export.log go to NotChecked and their records are
  dropped; export.log is required unless `-AllowMissingLog`) with `tests\StateFromExport.Tests.ps1`, and
  `tools\New-PEBlueprint.ps1` (wrapper over it and `Initialize-PEBlueprint`).
- `pwsh -NoProfile -File tools\New-PEBlueprint.ps1 -Name test -ExportPath data\exports\blueprint-test-<ts>`: **version 1**,
  17 s, **5,426 records**: Entra ID 678, Exchange Online 4,305, Intune 45, Teams 398. All five `PE-TEST-*` objects are
  in it.
- **NotChecked: 40 types**, not 29. 28 of them are the real failures. 11 are false (export-log parsing, see defect D1):
  `AADFederationConfiguration`, `AADRoleEligibilityScheduleRequest`, `AADRoleManagementPolicyRule`,
  `EXOApplicationAccessPolicy`, `EXOAvailabilityAddressSpace`, `EXOGlobalAddressList`, `EXOMailboxFolderPermission`,
  `TeamsCallParkPolicy`, `TeamsCallQueue`, `TeamsChannelsPolicy`, `TeamsChannelTab` (`EXOApplicationAccessPolicy` and
  `EXOGlobalAddressList` print a yellow "tenant is not registered" notice and no completion mark, so NotChecked is
  defensible for those two). One real failure, `AADFilteringPolicy`, is **not** in the list. 8 log warnings (7
  out-of-sequence, 1 "error line with no Extracting entry"). The same result was obtained with the parser before and
  after the Task 11 fix round (commit 4db8874).
- Smoke test: `Invoke-PEFullCheck -BlueprintName test -ExportScript { <the same export folder> }` (20 s) then
  `Get-PEStatus | Format-PEStatus`: no Missing, Changed, TargetOnly or PossibleRename; 40 NotAvailable (failed on both
  sides); 996 Ambiguous, all `EXOManagementRoleEntry` (the known real duplicates, 678 in the first export). Status:

  ```text
  Workload        Total Aligned Drifted TargetOnly Unmanaged Unkeyed NotChecked (types)
  Entra ID          678     678       0          0         0       0                 18
  Intune             45      45       0          0         0       0                  6
  Exchange Online  4305    2313     996          0         0       0                 12
  Teams             398     398       0          0         0       0                  4
  ```

  Everything aligned except the known Ambiguous `EXOManagementRoleEntry` records (which `Get-PEStatus` counts as not
  aligned).

### The Intune assignment in the export (the "untested GUID case")

The blueprint record of `PE-TEST-Intune-Win10` (241 properties) carries its assignment as

```text
Assignments = MSFT_DeviceManagementConfigurationPolicyAssignments {
    dataType = '#microsoft.graph.groupAssignmentTarget'; groupId = '<group GUID>'; groupDisplayName = 'PE-TEST-Baseline-Group'
    deviceAndAppManagementAssignmentFilterType = 'none' }
```

so the group is exported **by GUID and by name**. Conditional Access, by contrast, exports `IncludeGroups` by name only.
See the conclusion under step 4.

## Step 2: drift made in the tenant (Writer app, Graph), 05:24 to 05:25 local

| Change | Graph call | Expected finding |
| --- | --- | --- |
| (a) create `PE-TEST-New-Group` | `POST /v1.0/groups` | TargetOnly |
| (b1) delete `PE-TEST-Delete-Me` and purge it | `DELETE /v1.0/groups/{id}`, `DELETE /v1.0/directory/deletedItems/{id}` (the purge returned 404 for about 10 s after the delete, then succeeded) | Missing |
| (b2) rename `PE-TEST-Rename-Me` to `PE-TEST-Renamed` | `PATCH /v1.0/groups/{id}` | Missing + TargetOnly, PossibleRename |
| (c) `PE-TEST-CA-ReportOnly` grant control `mfa` -> `block` (still report-only) | `PATCH /v1.0/identity/conditionalAccess/policies/{id}` | Changed (`BuiltInControls`) |
| (d) `PE-TEST-Intune-Win10` `cameraBlocked` true -> false | `PATCH /beta/deviceManagement/deviceConfigurations/{id}` | Changed (`CameraBlocked`) |

A Reader read straight after the writes still showed the old name and grant control (eventual consistency); a read
about a minute later showed the new values.

## Step 3: quick scan and delta

- `pwsh -NoProfile -File tools\Invoke-PEQuickScan.ps1 -BlueprintName test`: **3 s**. 4 findings on scanned types, all
  `PossibleRename` (AADGroup `PE-TEST-Delete-Me`, `PE-TEST-New-Group`, `PE-TEST-Rename-Me`, `PE-TEST-Renamed`) with the
  hint "Missing and new objects of this type exist; cannot tell rename from add+remove without a Full check" (the
  conservative rule, as designed). 206 blueprint types listed as not covered (no quick-scan provider). **No report of
  the CA or Intune change** (the scan's documented limit). Saved as a `Scan` check.
- `-ExportDelta`: "No TargetOnly findings; no delta to export". Because the conservative rule turned the new group into
  PossibleRename, the delta path cannot export it while any group of the same type is missing (defect D2, usability).
- Workaround (documented manual step): the scan's `PE-TEST-New-Group` finding passed to `Export-PEDelta` as a
  TargetOnly finding. **27 s**; filter `DisplayName eq 'PE-TEST-New-Group'`; exactly **one** record exported
  (`AADGroup 'PE-TEST-New-Group'`), nothing not found.

## Step 4: full check (check 1)

- `pwsh -NoProfile -File tools\Invoke-PEFullCheck.ps1 -BlueprintName test` **failed after 1 s** (defect D3): the
  default export path passes `-Workloads` as an array to `pwsh -File`, which splits it into positional arguments, so
  `Intune` lands in `-Role`: `Cannot validate argument on parameter 'Role'. The argument "Intune" does not belong to
  the set "Reader,Writer"`. The scheduled full-check task uses the same path and fails the same way.
- Workaround (documented manual step): `Invoke-PEFullCheck -BlueprintName test -TargetTenantId <Reader tenant>
  -ExportScript { param($a) & pwsh -NoProfile -File tools\Export-M365DscTenant.ps1 -OutputPath $a.OutputPath; $a.OutputPath }`
  (the tool's default workloads are the same four). `-TargetTenantId` is needed because with `-ExportScript` the
  check's TenantId is otherwise `unknown`, and Invoke-PERectify now refuses a plan whose source tenant is not the
  Writer app's.
- Check `20261022-042718`: **31 min 47 s**; export 400 ok / 29 failed; 2,408 findings; 40 types NotChecked on the
  target, all 40 reported as **NotAvailable** (failed on both sides), none as Missing. The 8 LogWarnings are the same
  as on the blueprint export (defect D1).

| Kind | Type | Count | What |
| --- | --- | --- | --- |
| Changed | AADConditionalAccessPolicy | 1 | `PE-TEST-CA-ReportOnly`: `BuiltInControls` blueprint `mfa`, target `block` (as made) |
| Changed | IntuneDeviceConfigurationPolicyWindows10 | 1 | `PE-TEST-Intune-Win10`: `CameraBlocked` blueprint `true`, target `false` (as made); the assignment is unchanged and not reported |
| Missing | AADGroup | 1 | `PE-TEST-Delete-Me` |
| TargetOnly | AADGroup | 1 | `PE-TEST-New-Group` (not a rename candidate of `PE-TEST-Delete-Me`: similarity below 0.8) |
| PossibleRename | AADGroup | 2 | `PE-TEST-Rename-Me` <-> `PE-TEST-Renamed`, each hinting at the other (the full check's similarity rule, as designed) |
| Changed | AADRoleAssignmentScheduleRequest | 11 | **noise**: `ScheduleInfo.startDateTime` is the export time (blueprint `03:54:24Z`, check `04:28:43Z`) for every permanent assignment |
| Missing / TargetOnly / Ambiguous | EXOManagementRoleEntry | 81 / 274 / 1,996 | **noise**: the type's duplicate records are not stable between exports (996 Ambiguous in the blueprint export) |

The quick scan's limit is confirmed: the CA and Intune changes appear only here.

### Untested GUID case: conclusion

- What is exported: Intune assignments carry **both** `groupId` (GUID) and `groupDisplayName`. On a single tenant the
  GUID is stable, so the Intune finding showed only the real setting change (`CameraBlocked`); the assignment produced
  no finding. In the two-tenant case the GUIDs differ, so every assigned Intune policy would show `Assignments` as
  Changed.
- What DSC does with it (`M365DSCIntuneUtil.psm1`, assignment conversion): Set looks the group up by `groupId` first and
  falls back to `groupDisplayName` when the id is not found (it skips the assignment with a warning when the name is
  missing or not unique). So applying a master record to a replica works by name; only the comparison is affected.
- What the engine does: compares the CIM instance as a whole, `groupId` included. The ignore lists
  (`Data\IgnoredProperties.psd1`) are top-level only, so no pure data change can drop a nested property; nothing was
  changed. **Proposal (for the two-tenant phase)**: a nested ignore rule, e.g. `ByCimClass = @{
  MSFT_DeviceManagementConfigurationPolicyAssignments = @('groupId') }`, applied in normalisation, so the comparison
  and the generated config both use `groupDisplayName` only (DSC then resolves the group by name in the target).
  Conditional Access needs nothing: it exports groups by name.

## Step 5: decide and rectify (08:04 to 08:18 UTC)

Code under test: commit 4db8874 (Task 11 review round 1) plus the uncommitted round-2 changes to
`Invoke-PERectify.ps1` / `InvokeRectify.ps1` that were in the working tree at the time. One `pwsh` session per run
(scratch script): read check 1's `result.json` (module `Read-PEJson`), rebuild the State, set decisions, recompute the
findings with `Compare-PEState -Decisions`, `New-PERectifyPlan`, then `Invoke-PERectify -WhatIf` followed by the real
`Invoke-PERectify -Target Replica -BlueprintName test`.

Decisions (`data\decisions.json`):

- `Set-PEDecision -Kind Unmanaged -ResourceType AADGroup -Key PE-TEST-New-Group`: the finding became
  `TargetOnly [Unmanaged]`; status: Entra ID Unmanaged 1, and it is no longer in Drifted or TargetOnly.
- `Set-PEDecision -Kind Remove -ResourceType AADGroup -Key PE-TEST-Renamed` (the rename is resolved as "not a rename":
  remove the new name, create the old one).

Status from check 1 after the decisions (`Format-PEStatus`):

```text
Workload        Total Aligned Drifted TargetOnly Unmanaged Unkeyed NotChecked (types)
Entra ID          678     664      15          0         1       0                 18
Intune             45      44       1          0         0       0                  6
Exchange Online  4305    1684    2351        274         0       0                 12
Teams             398     398       0          0         0       0                  4
```

(Entra ID drift = CA + 3 group findings + 11 AADRoleAssignmentScheduleRequest noise; Exchange = EXOManagementRoleEntry
noise.)

| Run | Plan | WhatIf | Apply | Recheck |
| --- | --- | --- | --- | --- |
| groups | Create `PE-TEST-Delete-Me` (Missing); Create `PE-TEST-Rename-Me` and Remove `PE-TEST-Renamed` (PossibleRename, `-ConfirmNotRenamed`, Remove decision) | 6 s, audit saved, config shown | **Applied** in 239 s: compile 9.7 s, apply 139 s (59 / 42 / 38 s per resource) | clean (filtered delta per created key, whole-type export for the Remove) |
| ca | Update `PE-TEST-CA-ReportOnly` (Changed) | 4 to 5 s | **Failed twice** (08:09, 08:13): `Internal Server Error` from Graph during Set; `Applied False`, recheck skipped, audit and `result.json` kept. Third attempt (08:17, new plan from the same check) **Applied** in 73 s | clean |
| intune | Update `PE-TEST-Intune-Win10` (Changed; 241 properties incl. the assignment CIM instance with groupId + groupDisplayName) | 4 s | **Applied** in 87 s (compile 8.3 s, Set 45 s) | clean (whole-type export: Intune device configurations have no key filter) |

The CA failures: the same Graph endpoint also returned a 500 to a plain Reader `GET` of the CA policies at 08:03, and
the same configuration applied cleanly at 08:17, so this was a transient service error, not an engine defect. The
engine behaved correctly on failure (no recheck, `PartiallyApplied False`, warning naming the audit folder, the plan
consumed so a new plan was needed). While diagnosing it, a direct `Invoke-DscResource -Method Set` with the blueprint
record's properties (outside the engine) succeeded at 08:16 and set the policy back to `mfa`; it was then set to
`block` again with Graph so that the third engine run had real drift to fix. Recorded so the audit trail is complete.

Every apply was preceded by `-WhatIf`, and every audit folder (`data\audit\<stamp>`: plan.json, config.ps1, who.txt,
result.json) is kept. The generated Intune config carries the assignment as
`MSFT_DeviceManagementConfigurationPolicyAssignments{ dataType; deviceAndAppManagementAssignmentFilterType;
groupDisplayName; groupId }`; DSC applied it unchanged.

Before full check 2, `PE-TEST-Promote-Me` (security group) was created with Graph (Writer) for step 6.

## Step 7: scheduling (done while full check 2 ran, 09:18 local)

- `pwsh -NoProfile -File tools\Register-PESchedule.ps1 -BlueprintName test`: two tasks, `PE-QuickScan-test` (every 30
  min, next run 09:48) and `PE-FullCheck-test` (daily 02:00), both `pwsh.exe -NoProfile -File
  <repo>\tools\Invoke-PE*.ps1 -BlueprintName test`, state Ready.
- `Start-ScheduledTask PE-QuickScan-test`: finished in about 10 s, LastTaskResult 0, and a new
  `data\checks\20261022-081858\result.json` appeared with **Kind `Scan`**: `PE-TEST-New-Group` TargetOnly
  `[Unmanaged]`, `PE-TEST-Promote-Me` TargetOnly `[Open]` (created a minute earlier), no other group findings (the
  step 5 group rectify held), the rest NotChecked (no provider).
- `-Unregister`: `Get-ScheduledTask -TaskName 'PE-*'` returns nothing afterwards.
- Not run: the `PE-FullCheck-test` task. It runs `tools\Invoke-PEFullCheck.ps1` without arguments beyond the
  blueprint, so it would fail exactly like step 4's first attempt (defect D3) until that is fixed.

### Full check 2 (verification of step 5)

Check `20261022-081818` (workaround script, **30 min**), against blueprint v1, with the decisions:

- `PE-TEST-Delete-Me`, `PE-TEST-Rename-Me`, `PE-TEST-CA-ReportOnly` and `PE-TEST-Intune-Win10`: **no findings**
  (aligned). `PE-TEST-Renamed`: gone.
- `PE-TEST-New-Group`: `TargetOnly [Unmanaged]`, listed under Unmanaged only, not in Drifted or TargetOnly.
- `PE-TEST-Promote-Me`: TargetOnly (created for step 6).
- Remaining drift is noise: 11 `AADRoleAssignmentScheduleRequest` Changed (`ScheduleInfo`), `EXOManagementRoleEntry`
  (Ambiguous 1,149, Missing 125, TargetOnly 820), and a new one: `EXOMailboxSettings` PossibleRename between
  `<user>@$OrganizationName` (blueprint) and a mailbox GUID (this export), i.e. DSC exported that mailbox's `Identity`
  as a GUID this time (per-mailbox type, out of scope by the design; see Noise below).

```text
Workload        Total Aligned Drifted TargetOnly Unmanaged Unkeyed NotChecked (types)
Entra ID          678     667      12          1         1       0                 18
Intune             45      45       0          0         0       0                  6
Exchange Online  4305    2034    2096        820         0       0                 12
Teams             398     398       0          0         0       0                  4
```

## Step 6: promote and blueprint update

### Promote (08:49 UTC)

From check 2: `New-PERectifyPlan -Action Promote` for `AADGroup 'PE-TEST-Promote-Me'`, then:

- without `-ConfirmMasterWrite`: refused ("Target Master writes to the master tenant; pass -ConfirmMasterWrite ...");
- without `-Reason`: refused ("Promote changes the blueprint; pass -Reason ...");
- `-WhatIf`: 6 s, audit saved, nothing applied;
- `Invoke-PERectify -Target Master -ConfirmMasterWrite -Reason '...'`: **69 s**, `Applied True`; the resource was
  `InDesiredState` before (no Set: the idempotent no-op expected on one tenant), recheck clean,
  **`BlueprintVersionCreated 2`**;
- reusing the plan: refused ("plan already applied; make a new plan ...").

`data\blueprints\test` now holds `v0001.json`, `v0002.json` and `changes\v0002.json`. The change record: Version 2,
the Reason, User, At, and exactly **one** change: `Missing AADGroup 'PE-TEST-Promote-Me'` (Kind relative to the
inverted comparison, i.e. "new in the master"). v2 has 5,427 records (v1 5,426). `MasterExportedAt` is `null` in the
record (the promote path does not pass a master export time; minor).

### Blueprint change approval (master-side change), 08:51 to 09:19 UTC

- Master-side change with Graph (Writer): `PE-TEST-CA-ReportOnly` grant control `mfa` -> `block` (08:51 UTC).
- Full check 3 (`20261022-085116`, workaround script, **27 min**) against v2: `PE-TEST-CA-ReportOnly` Changed
  (`BuiltInControls` blueprint `mfa`, target `block`); `PE-TEST-Promote-Me` aligned (it is in v2);
  `PE-TEST-New-Group` Unmanaged only. Its State is used as the fresh master state.
- `Get-PEBlueprintChange -Name test -MasterState <check 3 state>`: 2,930 findings, of which the real one is
  `Changed AADConditionalAccessPolicy 'PE-TEST-CA-ReportOnly'` (master `block`, stored `mfa`). The rest is noise (11
  `AADRoleAssignmentScheduleRequest`, `EXOManagementRoleEntry`) plus `Missing AADGroup 'PE-TEST-New-Group'`: on one
  tenant the Unmanaged replica-only group is also "new in the master", and decisions are not applied to the master
  comparison (known deferred note).
- `Approve-PEBlueprintChange -Accept <the CA finding only> -Reason '...'` -> **version 3**. Change record
  `changes\v0003.json`: Reason, User, At, `MasterExportedAt 2026-10-22T09:18:23Z`, one change: `Changed
  AADConditionalAccessPolicy 'PE-TEST-CA-ReportOnly'`, `BuiltInControls` Previous `mfa`, New `block`. Latest
  `BuiltInControls` = `block`; `Get-PEBlueprintChange` against the same master state no longer lists the CA policy;
  comparing check 3 with v3, the only `PE-TEST-*` finding left is `PE-TEST-New-Group [Unmanaged]`.

Blueprint `test` ends with v1 (5,426 records), v2 (+ `PE-TEST-Promote-Me`, reason recorded), v3 (CA approved, reason
recorded).

## Step 8: cleanup (09:19 UTC)

With the Writer app (Graph): deleted the Intune policy `PE-TEST-Intune-Win10`, the CA policy `PE-TEST-CA-ReportOnly`,
the groups `PE-TEST-Baseline-Group`, `PE-TEST-Delete-Me`, `PE-TEST-New-Group`, `PE-TEST-Promote-Me`,
`PE-TEST-Rename-Me`, then purged all six soft-deleted `PE-TEST-*` groups (those five plus `PE-TEST-Renamed`, removed by
the step 5 rectify) from `directory/deletedItems`. Scheduled tasks: none left (step 7). Kept locally (git-ignored):
`data\blueprints\test` (v1 to v3), `data\checks\*`, `data\decisions.json`, `data\audit\*`, `data\exports\*`.

## Defects found

None of these was fixed in this task (the files are reviewed code owned by other tasks); each has a workaround or is
harmless for v1.

### D1. Export-log parser: false NotChecked for 11 types, one real failure missed (`Private\ExportLog.ps1`)

Repro: `New-PEStateFromExport -Path <a full export>` (or any full check) on the test tenant; the same with the parser
of commit 4adffe8 and of 4db8874. Expected: NotChecked = the 29 components that report an error. Actual: 40, of which
11 are false (`AADFederationConfiguration`, `AADRoleEligibilityScheduleRequest`, `AADRoleManagementPolicyRule`,
`EXOAvailabilityAddressSpace`, `EXOMailboxFolderPermission`, `TeamsCallParkPolicy`, `TeamsCallQueue`,
`TeamsChannelsPolicy`, `TeamsChannelTab`, plus `EXOApplicationAccessPolicy` / `EXOGlobalAddressList`, which only print
a yellow "not registered" notice), and the real failure `AADFilteringPolicy` is missing. The set varies between runs
(check 3 also had `EXOMailboxPermission` out-of-sequence and `EXOMailboxSettings` "failed (no error text)" while the
error belonged to `EXOMailboxIRMAccess`). Safe direction for most (types become NotChecked, never Missing), but real
drift in those types is hidden, and a missed failure on the target could produce Missing findings.

Three log shapes cause it (values invented, structure exact; `\r\n` is the literal text the export writes):

```text
(a) two Extracting entries on one line; the error belongs to the second
[52/400] Extracting [ResA] using {CertificateThumbprint}...\r\n[53/400] Extracting [ResB] using {CertificateThumbprint}...❌
    An error occurred while exporting resource {ResB}: Forbidden: ...
  -> ResA marked Failed "no error text"; "Ignored an error line for 'ResB', which has no Extracting entry"

(b) a resource prints its outer loop BEFORE its own Extracting line (AADRoleManagementPolicyRule, TeamsChannel)
[83/400] Extracting [ResC] using {CertificateThumbprint}...✅
    |---[1/145] Role One
[84/400] Extracting [ResD] using {CertificateThumbprint}...\r\n        |---[1/17] Role One_Rule_A✅
  -> ResC Incomplete (an instance line after its completion mark)

(c) nested counters (team -> channel -> tab) at deeper indentation, and the next component's outer loop printed
    under the previous one
[372/400] Extracting [ResE] using {CertificateThumbprint}...\r\n    |---[1/1] Global✅
    |---[1/13] Team {Team A}
[373/400] Extracting [ResF] using {CertificateThumbprint}...\r\n[374/400] Extracting [ResG] using {CertificateThumbprint}...\r\n        |---[1/2] General
    |---[2/13] Team {Team B}
  -> ResE / ResF "out-of-sequence instances", Incomplete
```

Suggested fix: split every line on the literal `\r\n` first and handle each `[n/m] Extracting [X]` segment on its own
(a new Extracting entry closes the previous one: Ok if it had a completion mark or no error); attribute an error line
to the resource named in `{...}` of "exporting resource {X}" rather than to the current component; count instance
numbers only at the component's own indentation depth; and treat instance lines that appear before a component's
Extracting line as belonging to the next component. The lasting fix (already noted in the handover) is structured
per-component status from the export wrapper instead of parsing console text.

Fixed in Task 14B (commits bdbb136 and fix round 1). An entry that logs nothing before the next one starts stays
Incomplete, because a completion mark is still required. Of the 11 types, 5 now read Ok. AADFederationConfiguration,
TeamsCallQueue, EXOApplicationAccessPolicy, EXOGlobalAddressList and EXOMailboxFolderPermission stay NotChecked because
the log shows no completion. EXOAvailabilityAddressSpace is a real failure (a red X "no permissions" notice that names
no type). AADFilteringPolicy reads Failed. Components listed on the log's first line with no visible Extracting entry
read NotChecked ('not in export log'). Known safe-direction coverage loss: SharePoint, Planner and Security & Compliance
resources print instance lines without a marker, so they read Incomplete; they are outside the default workloads.
EXOMailboxPermission reads Incomplete whenever it is visible.

### D2. Quick scan + `-ExportDelta` cannot export a new object while any object of the same type is missing

Repro: one group deleted and one created, `tools\Invoke-PEQuickScan.ps1 -BlueprintName test -ExportDelta`. Expected
(Task 13 plan): the new group is delta-exported. Actual: every AADGroup finding is PossibleRename (conservative rule),
`Select-PEDeltaFinding` selects only TargetOnly, so "No TargetOnly findings; no delta to export". Workaround used: pass
the finding to `Export-PEDelta` as TargetOnly by hand (exported exactly that group, 27 s). Suggested fix: let the delta
(read-only) also export target-side PossibleRename findings of a scan (keys that exist in the tenant), so the user can
judge the pair with settings; keep them non-removable as now.

### D3. Default full check fails: `-Workloads` array passed to `pwsh -File` (`Public\Invoke-PEFullCheck.ps1`, line 59)

Repro: `pwsh -NoProfile -File tools\Invoke-PEFullCheck.ps1 -BlueprintName test`. Expected: a full export and check.
Actual, after 1 s: `Export-M365DscTenant.ps1: Cannot validate argument on parameter 'Role'. The argument "Intune" does
not belong to the set "Reader,Writer"` then `Export failed with exit code 1.` `& pwsh -NoProfile -File $tool -Workloads
$Workloads ...` passes the array as separate arguments, so `-Workloads AAD` is followed by positional `Intune`, `EXO`,
`Teams` (the first positional parameter of the tool is `-Role`). The `PE-FullCheck-<name>` scheduled task uses this
path too, so scheduled full checks would fail. The unit tests always pass `-ExportScript`, so they never run this line.
Suggested fix: `-Workloads ($Workloads -join ',')` with the tool splitting a single comma-separated value, or run the
tool in-process (`& $tool -Workloads $Workloads -OutputPath ...`) inside a child `pwsh -Command`; plus a test that runs
the default path against a stub tool. Workaround used: `Invoke-PEFullCheck -ExportScript` running the tool without
`-Workloads` and `-TargetTenantId <Reader tenant>` (without it the check's tenant is `unknown`, which Invoke-PERectify
refuses).

### D4. Minor

- No public command reads a saved check back (State + Findings) for planning; the run used the module's private
  `Read-PEJson` and `New-PEState` through the module scope. Suggest `Get-PECheck -CheckId <id> [-Latest -Kind Full]`.
- `Initialize-PEBlueprint` writes no `Meta.Version` into v0001 (later versions have it; readers treat a missing
  version as 1, so it works).
- The Promote change record has `MasterExportedAt: null` (the approval record has it).

### Not a defect: transient Graph 500 on Conditional Access

Two applies of the CA Update failed with Graph `Internal Server Error` (and a Reader GET of the CA policies returned
500 in the same period); the third, with an identical configuration, succeeded. The engine reported it correctly.

## DSC non-idempotent noise (Noise decision proposals)

| Type | What changes between exports with no tenant change | Proposal |
| --- | --- | --- |
| `AADRoleAssignmentScheduleRequest` (11, every permanent role assignment) | `ScheduleInfo.startDateTime` = the time of the export | A Noise decision cannot cover it: Noise rules match the target value, and the value is new every export. Tried: 11 Noise decisions (Key-scoped, `ScheduleInfo`, the check 2 value) removed the findings from check 2 and none from check 3. Proposal: a nested ignore rule (`ScheduleInfo.startDateTime` when `expiration.type = noExpiration`), or a Noise rule kind that ignores a property whatever its value |
| `EXOManagementRoleEntry` | the number and set of duplicate records changes run to run (Ambiguous 996 / 1,996 / 1,149 / 1,621; Missing and TargetOnly in the hundreds) | Exclude the type from comparison (or compare it as a set per `Identity`), and list it as "not compared" in the status; it is built-in role data, not tenant configuration |
| `EXOMailboxSettings` (one mailbox in check 2) | `Identity` exported as the UPN in one run and as the mailbox GUID in another, giving a PossibleRename pair | Per-mailbox types are user-bound and out of scope by the design: exclude them by type (open item in the handover) |

The 11 Noise decisions were left in `data\decisions.json` as evidence; they are harmless (value-scoped).

## Conclusion

| Step | Result |
| --- | --- |
| 0 Baseline objects | pass |
| 1 Blueprint v1 + status smoke test | pass, with D1 (11 false NotChecked, 1 missed failure) |
| 2 Drift | pass |
| 3 Quick scan | pass (adds/removes/renames seen, CA/Intune not seen, 3 s); delta via -ExportDelta blocked by D2, manual delta exported exactly the new group |
| 4 Full check | pass with workaround for D3; CA and Intune Changed; Intune assignment exported with groupId and groupDisplayName (GUID case concluded above); licence failures NotAvailable, never Missing |
| 5 Decide and rectify | pass: Unmanaged excluded from counts; Create, ConfirmNotRenamed Create/Remove, CA and Intune Update applied with audit and clean recheck (CA after two transient Graph 500s); full check 2 aligned for every rectified item |
| 6 Promote and approve | pass: v2 (promote, one item, reason), v3 (approved CA change, reason) |
| 7 Scheduling | pass for the quick-scan task; the full-check task would hit D3 |
| 8 Cleanup | pass (see the final read below) |

Final Reader read (09:22 UTC, two minutes after the purge; a read straight after the purge still listed three deleted
groups, eventual consistency): no `PE-TEST-*` groups, live or deleted; Conditional Access: the three Microsoft-provided
policies only; Intune: the two original device configurations and the one compliance policy. The tenant is as it was
before the run.
