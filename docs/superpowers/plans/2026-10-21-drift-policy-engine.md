# Drift Policy Engine (v1, single tenant) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A local PowerShell module that exports a tenant with Microsoft365DSC, compares it with a locked, versioned blueprint, reports three kinds of drift, and rectifies approved items through generated, audited DSC configs.

**Architecture:** A module `PolicyEngine` (`src/PolicyEngine/`, function prefix `PE`) holds all logic and knows nothing about a GUI. State is plain JSON under the git-ignored `data/` folder. Thin scripts in `tools/` call it. A "state" is the parsed export: records keyed by resource type plus a human-readable key, and a list of components that were not checked.

**Tech Stack:** PowerShell 7.6+, Microsoft365DSC 2.26.1015.1, DSCParser 3.1.0.7 (`ConvertTo-DSCObject`, `ConvertFrom-DSCObject`), Pester 5.7.1.

**Spec:** `docs/superpowers/specs/2026-10-21-drift-policy-engine-design.md`

## Global Constraints

- PowerShell 7.6+. Import Microsoft365DSC with `-RequiredVersion 2.26.1015.1` every time (a 1.x copy is installed system-wide).
- Authentication is certificate-based, no interactive sign-in at run time. The Reader app (`~\.m365dsc-policy\M365DSC-Policy-Reader.json`) is used for every export, scan and check. The Writer app is used only by apply.
- Users and user assignments are out of scope. Everything else is compared.
- Match objects by the human-readable key (DisplayName, Name, or the DSC resource's own identity field), never a GUID. If a type has no reliable key, report it as `Unkeyed` and do not match it.
- Nothing is changed in a tenant without the user having approved that specific change. Promote is the only action that writes to the master and needs one explicit confirm plus a saved config.
- Exports, generated configs, decisions and the audit trail live in `data/` only. Never commit secrets, certificates, tenant data or exports.
- Scripts developed here live in the repo (`src/`, `tools/`, `tests/`), not in scratch locations.
- Approval and rectify are per resource instance. Setting-level differences are shown.
- Unmanaged items are excluded from alignment counts and listed separately.
- A component that failed to export never produces a `Missing` or `TargetOnly` finding and cannot be rectified.
- Passwords and values DSC cannot read back are not compared or stored.

## Review Focus

Failure modes the spec implies but that need a test to pin them (each is covered by a named test in the owning task):

1. A group's `Members` and `Owners` list users, so they would show as drift on every user change. They are ignored (Task 3).
2. Two objects of one type share a DisplayName. They must be `Ambiguous` and never offered for Remove (Task 5).
3. A component failed to export on the target. Its blueprint items must not turn into `Missing` (Task 5, Task 7).
4. A type exports zero instances (valid, empty) versus a type that was never exported. Only the first means "none exist" (Task 7).
5. The 8 MB full export parses very slowly or exhausts memory with `ConvertTo-DSCObject` (Task 2).
6. A Missing item and a TargetOnly item that is the same object renamed would lead to deleting the renamed one (Task 5).

---

## File Structure

```
src/PolicyEngine/PolicyEngine.psd1          module manifest
src/PolicyEngine/PolicyEngine.psm1          dot-sources Private/ and Public/
src/PolicyEngine/Data/KeyMap.psd1           per-type key overrides
src/PolicyEngine/Data/IgnoredProperties.psd1 global and per-type ignored properties
src/PolicyEngine/Private/Store.ps1          JSON store helpers
src/PolicyEngine/Private/Parse.ps1          export -> state
src/PolicyEngine/Private/Normalize.ps1      keys and ignored properties
src/PolicyEngine/Private/Compare.ps1        state vs state -> findings
src/PolicyEngine/Public/*.ps1               one file per exported command
src/PolicyEngine/Providers/*.ps1            quick-scan inventory providers
tests/*.Tests.ps1                           Pester tests (one file per Private/Public file)
tests/fixtures/                             hand-made tiny exports and logs
tools/Invoke-PEFullCheck.ps1, tools/Invoke-PEQuickScan.ps1, tools/Register-PESchedule.ps1
docs/apply-mechanics.md                     how a generated config is applied (written in Task 11)
```

Run all tests: `pwsh -NoProfile -Command "Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester -Path tests -Output Detailed"`

## Shared types

- **Record** `[pscustomobject]@{ ResourceType; Key; Workload; Properties }` (`Properties` is an ordered hashtable). `Key` is `$null` for an unkeyed type.
- **State** `[pscustomobject]@{ Records = Record[]; NotChecked = @{ResourceType; Reason}[]; Meta = @{TenantId; ExportedAt; Source} }`
- **Finding** `[pscustomobject]@{ Kind; ResourceType; Key; Workload; Differences; Hint; State }`. `Kind` is one of `Missing, Changed, TargetOnly, Ambiguous, PossibleRename, NotChecked, NotAvailable, Excluded, Unkeyed, Unreadable` (`Excluded` added after the acceptance run: a type in `Data\ExcludedTypes.psd1`, see `docs/key-coverage.md`). `Differences` is `@{Property; Blueprint; Target}[]`. `State` is `Open` or `Unmanaged`.
- **Decision** `@{ Kind='Unmanaged'|'Noise'|'Remove'; ResourceType; Key; Property; Value; Reason; At }`

---

### Task 1: Module skeleton and JSON store

**Files:**
- Create: `src/PolicyEngine/PolicyEngine.psd1`, `src/PolicyEngine/PolicyEngine.psm1`, `src/PolicyEngine/Private/Store.ps1`
- Test: `tests/Store.Tests.ps1`

**Interfaces:**
- Produces: `Get-PEDataRoot [-Override <string>] -> string` (default `<repo>\data`, created if missing); `Write-PEJson -Path <string> -InputObject <object>` (creates parent folders, UTF-8, depth 20); `Read-PEJson -Path <string> -> object` (returns `$null` if the file is absent).

- [ ] **Step 1: Write the failing test** in `tests/Store.Tests.ps1` with `BeforeAll { Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force }`:
  - `Write-PEJson then Read-PEJson round-trips nested objects` (a hashtable with an array and a nested object compares equal after reading).
  - `Read-PEJson returns null for a missing file`.
  - `Get-PEDataRoot honours -Override and creates the folder`.
- [ ] **Step 2: Run the test file; expected FAIL** ("module not found").
- [ ] **Step 3: Implement the manifest (RootModule `PolicyEngine.psm1`, `PowerShellVersion = '7.6'`), the psm1 that dot-sources `Private\*.ps1` and `Public\*.ps1` and exports `Public` function names, and the three functions in `Store.ps1`.**
- [ ] **Step 4: Run the test file; expected PASS (3 tests).**
- [ ] **Step 5: Commit** `feat: module skeleton and JSON store`.

---

### Task 2: Parse an export into a state (with benchmark)

**Files:**
- Create: `src/PolicyEngine/Private/Parse.ps1`, `tests/fixtures/mini-export.ps1`
- Test: `tests/Parse.Tests.ps1`

**Interfaces:**
- Consumes: `Import-Module DSCParser -RequiredVersion 3.1.0.7`; `ConvertTo-DSCObject -Path`.
- Produces: `Read-PEExport -Path <string> [-TenantId <string>] -> Record[]`; `Get-PEWorkload -ResourceType <string> -> string` (`AAD` -> `Entra ID`, `Intune` -> `Intune`, `EXO` -> `Exchange Online`, `Teams` -> `Teams`, else `Other`). Records have `Key = $null` and the full property bag; keys are assigned in Task 3.

- [ ] **Step 1: Create the fixture** `tests/fixtures/mini-export.ps1`: a hand-written DSC configuration with three `AADGroup` instances (DisplayName `Sales`, `Finance`, `Finance` again with different `Id`; each with `Id`, `Members = @("a@x.com")`, `TenantId = $ConfigurationData.NonNodeData.TenantId`) and one `AADConditionalAccessPolicy` (`DisplayName = "Require MFA"`). Copy the layout of a real instance block from a recent export, with invented values.
- [ ] **Step 2: Write the failing tests:** `Read-PEExport returns one record per instance` (4 records); `ResourceType comes from the DSC resource name` (3 `AADGroup`); `Properties keep the exported values` (`Sales` record has `Properties.DisplayName -eq 'Sales'`); `Get-PEWorkload maps prefixes` (`AADGroup` -> `Entra ID`, `EXOAcceptedDomain` -> `Exchange Online`, `TeamsMeetingPolicy` -> `Teams`, `IntuneX` -> `Intune`, `SPOSite` -> `Other`).
- [ ] **Step 3: Run; expected FAIL.**
- [ ] **Step 4: Implement both functions.** Use `ConvertTo-DSCObject`; map `ResourceName` to `ResourceType`. Discard `ResourceName` and `ResourceInstanceName` from `Properties` here.
- [ ] **Step 5: Run; expected PASS.**
- [ ] **Step 6: Benchmark.** Run `Read-PEExport` on `data\exports\first-full-reader\full-export.ps1` (8 MB, about 7,900 instances) and record elapsed time and peak memory in the commit message. Earlier 38 objects took 9.4 s, which may be start-up cost or per-object cost. **If it takes over 10 minutes or over 4 GB,** replace `ConvertTo-DSCObject` for large files with a streaming split of the file on resource blocks, parsing each block separately, and keep the same output. Add the test `Read-PEExport handles 2,000 instances in under 60 seconds` against a generated fixture.
- [ ] **Step 7: Commit** `feat: parse DSC exports into records`.

---

### Task 3: Keys and ignored properties

**Files:**
- Create: `src/PolicyEngine/Private/Normalize.ps1`, `src/PolicyEngine/Data/KeyMap.psd1`, `src/PolicyEngine/Data/IgnoredProperties.psd1`
- Test: `tests/Normalize.Tests.ps1`

**Interfaces:**
- Consumes: Record from Task 2.
- Produces: `Get-PEResourceKey -ResourceType <string> -Properties <hashtable> -> string|$null`; `ConvertTo-PENormalizedRecord -Record <Record> -> Record` (sets `Key`, removes ignored properties); `New-PEState -Records <Record[]> -NotChecked <object[]> -Meta <hashtable> -> State`.
- `KeyMap.psd1` is `@{ Default = @('DisplayName','Name','Identity'); Overrides = @{ ... } }`. `IgnoredProperties.psd1` is `@{ Global = @('Id','TenantId','ApplicationId','CertificateThumbprint','CertificatePath','CertificatePassword','Credential','ApplicationSecret','ManagedIdentity','AccessTokens'); ByType = @{ AADGroup = @('Members','Owners','MemberOf') } }`.

- [ ] **Step 1: Write the failing tests:** `Key is the first of DisplayName, Name, Identity that is non-empty`; `Key is null when no key property exists` (Unkeyed); `Overrides win over the default order`; `Global ignored properties are removed` (`Id`, `TenantId` absent after normalising); `AADGroup Members and Owners are removed` (Review Focus 1); `Other types keep a property named Members`; `Secret-like values are not kept` (a `Credential` property is absent).
- [ ] **Step 2: Run; expected FAIL.**
- [ ] **Step 3: Implement.** Data files are read once with `Import-PowerShellDataFile` and cached in a script variable. Comparison of keys is case-insensitive; store the key as exported.
- [ ] **Step 4: Run; expected PASS.**
- [ ] **Step 5: Commit** `feat: keys and ignored properties`.

---

### Task 4: Decisions store

**Files:**
- Create: `src/PolicyEngine/Public/Decisions.ps1`
- Test: `tests/Decisions.Tests.ps1`

**Interfaces:**
- Produces: `Set-PEDecision -Kind <Unmanaged|Noise|Remove> -ResourceType <string> [-Key <string>] [-Property <string>] [-Value <object>] -Reason <string> [-DataRoot <string>] -> Decision`; `Get-PEDecision [-Kind <string>] [-DataRoot <string>] -> Decision[]`; `Remove-PEDecision -Kind -ResourceType [-Key] [-Property] [-DataRoot]` (used to put an item back under management). Stored in `<DataRoot>\decisions.json`.
- A `Noise` decision needs `ResourceType`, `Property` and `Value`; `Key` optional (instance scope). `Unmanaged` and `Remove` need `ResourceType` and `Key`.

- [ ] **Step 1: Write the failing tests:** `Set-PEDecision persists and Get-PEDecision returns it`; `Setting the same decision twice does not duplicate it`; `Noise without Property or Value throws`; `Unmanaged without Key throws`; `Remove-PEDecision deletes only the matching decision`; `every decision records a timestamp and reason`.
- [ ] **Step 2: Run; expected FAIL.**
- [ ] **Step 3: Implement** over `Read-PEJson` / `Write-PEJson`. Identity of a decision is (Kind, ResourceType, Key, Property).
- [ ] **Step 4: Run; expected PASS.**
- [ ] **Step 5: Commit** `feat: decisions store`.

---

### Task 5: Compare two states into findings

**Files:**
- Create: `src/PolicyEngine/Private/Compare.ps1`, `src/PolicyEngine/Public/Compare-PEState.ps1`
- Test: `tests/Compare.Tests.ps1`

**Interfaces:**
- Consumes: State (Task 3), Decision (Task 4).
- Produces: `Compare-PEState -Blueprint <State> -Target <State> [-Decisions <Decision[]>] [-RenameThreshold <double> = 0.8] -> Finding[]`.
- Rules (spec section "Rules settled during review"): match on (ResourceType, Key, case-insensitive). Blueprint-only -> `Missing`; both with different normalised properties -> `Changed` with `Differences`; target-only -> `TargetOnly`. A key that appears more than once in either state -> one `Ambiguous` finding and no other finding for that key. A `Missing` and a `TargetOnly` of the same type whose property equality is at least `RenameThreshold` -> both get `Hint = 'Possible rename of <other key>'` and Kind `PossibleRename`. Types listed in `Target.NotChecked` -> one `NotChecked` finding per type and no `Missing` or `TargetOnly` for that type. A type in both `NotChecked` lists -> `NotAvailable`. Records with `Key = $null` -> `Unkeyed`. A matching `Unmanaged` decision sets `State = 'Unmanaged'`. A matching `Noise` decision removes that difference (a different value still shows); a `Changed` finding with no differences left is dropped.

- [ ] **Step 1: Write the failing tests**, building states with `New-PEState` and tiny records:
  - `identical states produce no findings`
  - `blueprint-only record is Missing`
  - `target-only record is TargetOnly`
  - `different property is Changed and names the property with both values`
  - `key match ignores case`
  - `duplicate key in the target is Ambiguous and produces no Missing or TargetOnly` (Review Focus 2)
  - `duplicate key in the blueprint is Ambiguous`
  - `type in Target.NotChecked yields NotChecked and never Missing` (Review Focus 3)
  - `type in both NotChecked lists is NotAvailable`
  - `Missing plus similar TargetOnly of same type become PossibleRename` (Review Focus 6)
  - `dissimilar Missing and TargetOnly stay separate`
  - `Unmanaged decision marks a TargetOnly finding Unmanaged`
  - `Noise decision hides the matching value but not a different value`
  - `Unkeyed record yields Unkeyed`
- [ ] **Step 2: Run; expected FAIL.**
- [ ] **Step 3: Implement** with hashtables keyed by `Type|key.ToLowerInvariant()`; similarity = shared equal properties / union of property names.
- [ ] **Step 4: Run; expected PASS.**
- [ ] **Step 5: Commit** `feat: compare states into findings`.

---

### Task 6: Versioned, reviewed blueprints

**Files:**
- Create: `src/PolicyEngine/Public/Blueprint.ps1`
- Test: `tests/Blueprint.Tests.ps1`

**Interfaces:**
- Consumes: `Compare-PEState`, `Read-PEJson`, `Write-PEJson`.
- Produces: `Initialize-PEBlueprint -Name <string> -State <State> [-DataRoot] -> int` (writes `blueprints\<Name>\v0001.json`, returns 1; throws if it exists); `Get-PEBlueprint -Name -Version <int|'latest'> [-DataRoot] -> State`; `Get-PEBlueprintChange -Name -MasterState <State> [-DataRoot] -> Finding[]` (comparison of the current version against a fresh master state); `Approve-PEBlueprintChange -Name -MasterState <State> -Accept <Finding[]> -Reason <string> [-DataRoot] -> int` (writes a new immutable version containing the accepted changes only, plus `blueprints\<Name>\changes\v0002.json` listing what changed, when and why; returns the version number).
- Accepting a `Missing` finding (new in the master) adds the record; `TargetOnly` here means "removed from the master" and removes it; `Changed` replaces the record.

- [ ] **Step 1: Write the failing tests:** `Initialize creates v1 and refuses to overwrite`; `Get-PEBlueprint latest returns the highest version`; `Get-PEBlueprintChange reports a new master record as Missing relative to the blueprint`; `Approve with a subset of changes leaves the others out of the new version`; `older versions are never modified` (file hash of v0001 is unchanged after approving); `each approval writes a change record with reason and timestamp`; `Approve with no findings throws`.
- [ ] **Step 2: Run; expected FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run; expected PASS.**
- [ ] **Step 5: Commit** `feat: versioned blueprints with reviewed updates`.

---

### Task 7: Full check (export, failure capture, check result)

**Files:**
- Modify: `tools/Export-M365DscTenant.ps1` (also write the console output to `export.log` next to the export)
- Create: `src/PolicyEngine/Private/ExportLog.ps1`, `src/PolicyEngine/Public/Invoke-PEFullCheck.ps1`, `tools/Invoke-PEFullCheck.ps1`, `tests/fixtures/export-log.txt`
- Test: `tests/ExportLog.Tests.ps1`, `tests/FullCheck.Tests.ps1`

**Interfaces:**
- Produces: `Read-PEExportLog -Path <string> -> @{ResourceType; Status = 'Ok'|'Failed'; Reason}[]` (one entry per line matching `^\[\d+/\d+\] Extracting \[(\w+)\]`, status from a trailing `❌`, reason from the following `An error occurred while exporting resource {X}: ...` line); `Invoke-PEFullCheck -BlueprintName <string> [-Role Reader] [-Workloads <string[]>] [-ExportScript <scriptblock>] [-DataRoot] -> @{ CheckId; Findings; State; Path }`. The `-ExportScript` parameter is how tests avoid calling a tenant: it returns the path of an export folder. A check result is written to `checks\<CheckId>\result.json` with the target state and findings.
- A type that exported with zero instances is `Ok` and absent from the records; a `Failed` type goes to `NotChecked`.

- [ ] **Step 1: Create `tests/fixtures/export-log.txt`** by copying the real console output shape from `data\exports\first-full-reader` run logs: three components, one `Ok` with instances, one `Ok` with no instances (`...✅` and no instance lines), one `Failed` with an `An error occurred while exporting resource {EXOFocusedInbox}` line.
- [ ] **Step 2: Write the failing tests:** `Read-PEExportLog marks a ❌ component Failed with its reason`; `a component with no instances is Ok` (Review Focus 4); `Invoke-PEFullCheck puts failed components in NotChecked and not in Missing` (with a fake `-ExportScript` and a blueprint that has an `EXOFocusedInbox` record); `Invoke-PEFullCheck writes result.json with findings and the export time`.
- [ ] **Step 3: Run; expected FAIL.**
- [ ] **Step 4: Implement** both, and make `tools/Export-M365DscTenant.ps1` tee its output to `export.log`. The tool script stays a thin wrapper over the module.
- [ ] **Step 5: Run tests; expected PASS.**
- [ ] **Step 6: Live check (manual):** run `tools\Invoke-PEFullCheck.ps1 -BlueprintName test` against the test tenant after a blueprint exists (Task 13 step 1). Expected: the 29 known failures appear as `NotChecked` or `NotAvailable`, none as `Missing`.
- [ ] **Step 7: Commit** `feat: full check with failure capture`.

---

### Task 8: Status report

**Files:**
- Create: `src/PolicyEngine/Public/Status.ps1`
- Test: `tests/Status.Tests.ps1`

**Interfaces:**
- Produces: `Get-PEStatus -Blueprint <State> -Findings <Finding[]> [-LastFullCheck <datetime>] -> @{ Workload; Total; Aligned; Drifted; Unmanaged; NotChecked }[]` (Total counts blueprint records in the workload; Drifted counts distinct (type,key) among `Missing, Changed, TargetOnly, PossibleRename, Ambiguous` in `Open` state; `Unmanaged` is shown separately and never counted as drifted or aligned; `NotChecked` counts types not checked); `Format-PEStatus -Status <object[]> -> string` (a console table, one row per workload, with the age of the last full check on the last line).

- [ ] **Step 1: Write the failing tests:** `all-aligned workload shows Aligned equals Total`; `Missing and Changed count as Drifted`; `Unmanaged TargetOnly is excluded from Drifted and counted under Unmanaged`; `workloads with no records are omitted`; `Format-PEStatus prints the age of the last full check`.
- [ ] **Step 2: Run; expected FAIL.** **Step 3: Implement.** **Step 4: Run; expected PASS.**
- [ ] **Step 5: Commit** `feat: workload status report`.

---

### Task 9: Quick scan and delta export

**Files:**
- Create: `src/PolicyEngine/Providers/AADGroup.ps1`, `src/PolicyEngine/Public/Invoke-PEQuickScan.ps1`, `src/PolicyEngine/Public/Export-PEDelta.ps1`, `tools/Invoke-PEQuickScan.ps1`
- Test: `tests/QuickScan.Tests.ps1`

**Interfaces:**
- A provider file returns `@{ ResourceType = 'AADGroup'; GetInventory = { param($App) ... -> @{Key; Modified}[] } }`, listing keys cheaply (Microsoft Graph `GET /groups?$select=displayName,id`, authenticated with the app certificate).
- `Invoke-PEQuickScan -BlueprintName <string> [-Role Reader] [-Provider <object[]>] [-DataRoot] -> Finding[]`: for each provider whose type is in the blueprint, compare the blueprint's keys with the inventory keys and emit `Missing`, `TargetOnly`, `Ambiguous`, `PossibleRename` (by the Task 5 rules, using key only). Types with no provider are listed as `NotChecked` with reason `no quick-scan provider; Full check required`.
- `Export-PEDelta -Findings <Finding[]> [-Role Reader] [-ExportScript <scriptblock>] -> State` exports only the findings' objects: for each (type, key) call `Export-M365DSCConfiguration` with `-Components <type>` and `-Filters @{ <type> = "DisplayName eq '<key>'" }` when the resource supports a `Filter` (check with `Test-M365DSCResourceProperty`), otherwise export the whole type, then keep only the requested keys. Keys are escaped for single quotes.

- [ ] **Step 1: Write the failing tests** with fake providers and a fake `-ExportScript`: `quick scan reports a new group as TargetOnly`; `quick scan reports a deleted group as Missing`; `a type without a provider is NotChecked and not Missing`; `a group renamed in the target is reported as PossibleRename`; `Export-PEDelta asks for only the requested key` (assert the filter string, including a key containing a single quote); `Export-PEDelta falls back to the whole type and filters records when the resource has no Filter support`.
- [ ] **Step 2: Run; expected FAIL.** **Step 3: Implement** the provider, scan, delta. **Step 4: Run; expected PASS.**
- [ ] **Step 5: Live check (manual):** create a group in the test tenant, run `tools\Invoke-PEQuickScan.ps1`, expect one `TargetOnly` for it in under 2 minutes, then run the delta and confirm the result holds exactly that group.
- [ ] **Step 6: Commit** `feat: quick scan and delta export`.

---

### Task 10: Rectify plan and generated config

**Files:**
- Create: `src/PolicyEngine/Public/Rectify.ps1`
- Test: `tests/Rectify.Tests.ps1`

**Interfaces:**
- Produces: `New-PERectifyPlan -Findings <Finding[]> -Action <'Create'|'Update'|'Remove'|'Promote'> -Source <State> [-Decisions <Decision[]>] -> PlanItem[]` where `PlanItem = @{ Action; ResourceType; Key; Record }`. Rules: `Create` only for `Missing`; `Update` only for `Changed`; `Remove` only for `TargetOnly` with a `Remove` decision; `Promote` only for `TargetOnly` (and the item is copied from the target state). `Ambiguous`, `NotChecked`, `NotAvailable`, `Unkeyed` and `Unreadable` findings always throw.
- `ConvertTo-PEDscConfig -Plan <PlanItem[]> -ConfigurationName <string> -Target <'Replica'|'Master'> -> string` builds the configuration text (via `ConvertFrom-DSCObject`) containing only the planned instances; `Remove` items get `Ensure = 'Absent'`.
- `Save-PEAudit -Plan <PlanItem[]> -Config <string> -User <string> [-DataRoot] -> string` writes `audit\<timestamp>\config.ps1`, `plan.json` and `who.txt`, and returns the folder.

- [ ] **Step 1: Write the failing tests:** `Create is refused for a Changed finding`; `Remove is refused without a Remove decision`; `Remove for an Ambiguous finding throws` (anti-goal: never delete on a name collision); `the config contains only the planned instances` (assert two of four instances present by DisplayName); `Remove items get Ensure Absent`; `Save-PEAudit writes config, plan and user`.
- [ ] **Step 2: Run; expected FAIL.** **Step 3: Implement.** **Step 4: Run; expected PASS.**
- [ ] **Step 5: Commit** `feat: rectify plan and audited config generation`.

---

### Task 11: Apply a generated config

**Files:**
- Create: `docs/apply-mechanics.md`, `src/PolicyEngine/Public/Invoke-PERectify.ps1`
- Test: `tests/InvokeRectify.Tests.ps1`

**Interfaces:**
- Consumes: Task 10 functions.
- Produces: `Invoke-PERectify -Plan <PlanItem[]> -Target <'Replica'|'Master'> [-Role Writer] [-ApplyScript <scriptblock>] [-Confirm] [-WhatIf] -> @{ AuditPath; Applied; RecheckFindings }`. It generates the config, saves the audit folder before applying, applies via `-ApplyScript` (default: the commands recorded in `docs/apply-mechanics.md`), then re-runs a delta check of the same items. `Target Master` or any `Promote` item requires `-Confirm` explicitly and uses the Writer app; with `-WhatIf` it only generates and saves.

- [ ] **Step 1: Discover how to apply (manual, recorded):** hand-write a one-group configuration, then compile it (`Invoke-M365DSCConfigurationBuild` from Windows PowerShell, per the module warning) and run it (`Start-DscConfiguration` or the v2 equivalent) with the Writer certificate against the test tenant. Write the exact commands, working directory and prerequisites to `docs/apply-mechanics.md`. This is the one place the plan cannot specify code before the commands are proven.
- [ ] **Step 2: Write the failing tests** using a fake `-ApplyScript`: `audit is saved before apply runs` (the fake asserts the audit folder exists when called); `WhatIf generates and saves but does not call apply`; `Promote without -Confirm throws`; `a failed apply is reported and the audit folder remains`; `after apply a delta re-check is run for the same keys`.
- [ ] **Step 3: Run; expected FAIL.** **Step 4: Implement**, wrapping the commands from Step 1. **Step 5: Run; expected PASS.**
- [ ] **Step 6: Commit** `feat: apply generated configs with audit and recheck`.

---

### Task 12: Scheduling

**Files:**
- Create: `tools/Register-PESchedule.ps1`
- Test: manual (scheduled tasks).

**Interfaces:**
- `Register-PESchedule.ps1 -BlueprintName <string> [-ScanEveryMinutes 30] [-FullCheckAt '02:00'] [-Unregister]` registers two Windows scheduled tasks (`PE-QuickScan-<name>`, `PE-FullCheck-<name>`) that run `pwsh -NoProfile -File tools\Invoke-PEQuickScan.ps1 ...` and `tools\Invoke-PEFullCheck.ps1 ...` as the current user. `-Unregister` removes them.

- [ ] **Step 1: Implement** with `Register-ScheduledTask`; refuse to run if the blueprint does not exist.
- [ ] **Step 2: Verify manually:** register, run `Start-ScheduledTask PE-QuickScan-test`, confirm a new `checks\` result appears, then `-Unregister`.
- [ ] **Step 3: Commit** `feat: scheduling for scans and full checks`.

---

### Task 13: End-to-end acceptance on the test tenant

**Files:**
- Create: `docs/acceptance-v1.md` (the scenario and the observed results)

- [ ] **Step 1: Blueprint.** Run a Full check export of the test tenant, then `Initialize-PEBlueprint -Name test`. Expected: version 1.
- [ ] **Step 2: Manual changes** in the tenant: create a group; edit a Conditional Access policy setting; create an Intune policy assigned to a group (closes the untested GUID case in the spec); delete or rename a group.
- [ ] **Step 3: Quick scan.** Expect the new and removed/renamed groups within minutes; expect no report of the Conditional Access change (scan limit).
- [ ] **Step 4: Full check.** Expect the Conditional Access setting as `Changed` and the Intune policy with its group assignment shown by group name, not GUID. If a GUID appears, add an ignored property or key rule and re-run.
- [ ] **Step 5: Decide and rectify.** Mark the new group `Unmanaged` (it disappears from drift and counts), `Remove` one object (with an audit folder created first), `Update` the Conditional Access setting. Expect the next Full check to show these aligned.
- [ ] **Step 6: Promote and blueprint update.** Promote one TargetOnly item (needs `-Confirm`), approve a blueprint change, and confirm a new version `v0002` with a change record.
- [ ] **Step 7: Record** what happened, including any DSC non-idempotent noise found (add `Noise` decisions), in `docs/acceptance-v1.md`, and commit.

---

## Self-review notes

- **Spec coverage:** three drift kinds (Task 5); remove, unmanaged, promote (Tasks 4, 10, 11); rectify with audit and re-check (Tasks 10, 11); full and quick checks on a schedule with delta (Tasks 7, 9, 12); versioned reviewed blueprint (Task 6); status per workload with unmanaged excluded and full-check age (Task 8); rules from review: ambiguity, rename hint, per-instance approval, noise rules, failed-export handling, secrets (Tasks 3, 4, 5, 7, 10). Not in v1 by design: GUI, two-tenant translation, pipelines, containers.
- **Names are consistent** across tasks: `Compare-PEState`, `New-PEState`, `Get-PEBlueprint`, `Approve-PEBlueprintChange`, `Invoke-PEFullCheck`, `Invoke-PEQuickScan`, `Export-PEDelta`, `New-PERectifyPlan`, `Invoke-PERectify`.
- **Plan calls (not in the spec):** membership lists (`Members`, `Owners`, `MemberOf`) on groups are ignored in v1 because they contain users; rename similarity threshold 0.8; quick-scan providers are written one type at a time (only `AADGroup` in v1); the apply commands are discovered in Task 11 step 1 rather than assumed.
