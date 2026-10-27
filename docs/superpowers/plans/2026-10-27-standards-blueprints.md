# Standards blueprints Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only "standard" kind of blueprint (ASD Blueprint for Secure Cloud first) that a tenant can be checked against, promoted from, and have risks accepted on, as module commands and `tools/` scripts (no GUI).

**Architecture:** A standard is an ordinary blueprint folder (`data/blueprints/<name>/`, immutable versions, change records, lock) plus a `standard.json` that marks it read-only and holds source metadata, and a `coverage/vNNNN.json` per version listing what could not be mapped. The ASD DSC files are parsed with DSC's own parser (`Read-PEExport`, which already wraps `ConvertTo-DSCObject`). A tenant check exports only the standard's workloads and compares with a new `Compare-PEState -Subset` mode. Accept risk is a new decision kind; promote copies items into a blueprint through the existing crash-safe writer, with provenance on each record.

**Tech Stack:** PowerShell 7.6, Pester, Microsoft365DSC (pinned in `src/PolicyEngine/Data/Versions.psd1`), DSCParser 3.1.0.7, git.

**Spec:** `docs/superpowers/specs/2026-10-27-standards-blueprints-design.md`

## Global Constraints

- Thin wrapper over Microsoft365DSC (`CLAUDE.md`): parse with `Read-PEExport` (DSC's `ConvertTo-DSCObject`), derive resource properties and keys from the pinned module (`Get-PEDscResourceSchema`, `Get-PEResourceKey`); no parser, resource list or per-resource knowledge of our own. If a DSC command cannot do a job, stop and discuss.
- Standard files are untrusted downloads: parse them only, never dot-source or run them; keep them in their own folder under `data/sources/`.
- A standard is read-only. Every write path refuses it: no Promote into it, no Revert/apply from it, no Restore, no tenant layer, no master merge. Only `Import-PEStandard` writes versions.
- A tenant is only written from its own blueprint; nothing applies a standard to a tenant directly.
- Items with placeholders or properties the pinned module does not know are left out whole and counted as not covered (never guessed, never counted as passing).
- Accept risk records `ApprovedBy` and `Reason` only (plus the existing `At`); no expiry, evidence or workflow.
- Blueprint rules hold: immutable versions, a change record each, a reason for every change, crash-safe writes under the per-blueprint lock.
- ASCII only in generated text; match the surrounding code style (Allman braces, `[CmdletBinding()]`, comment-based help, `Get-PE*`/`Set-PE*` names). Offline Pester tests with fake exports only; no network in tests.
- CC BY 4.0: source name, URL, version and attribution are stored in `standard.json` and printed by the commands.
- Record deliberate gaps in `docs/handover.md`.

## Review Focus

Spec-implied inputs no task's headline tests would otherwise hit (each has its test in the owning task):

1. The tenant has two objects with the same key as a standard item: reported Ambiguous, not silent drift or a silent pass (Task 1).
2. The standard states `Description = ""` and the tenant omits the property: not a difference (Task 1).
3. A standard whose workload the Reader app cannot read (SharePoint): its items are `TypeNotReadable` in the coverage line, never Missing (Task 5).
4. An accepted risk whose standard value later changes: shown as open with a "needs another look" hint, not silently accepted (Task 6, Task 9).
5. A standard name used where a blueprint is written or applied (`Approve-PEBlueprintChange`, `Move-PEBlueprintItem -To`, `Restore-PEBlueprintVersion`, `Invoke-PERectify`, `Set-PETenant -Blueprints`): refused with a message naming the standard (Task 2).

## File Structure

| File | Responsibility |
| --- | --- |
| `src/PolicyEngine/Private/Compare.ps1`, `Public/Compare-PEState.ps1` | Modify: `-Subset` switch (Task 1); `RiskAccepted` handling (Task 6) |
| `src/PolicyEngine/Private/Standard.ps1` | New: standard metadata, read-only guard, placeholder and unknown-property classification |
| `src/PolicyEngine/Public/Import-PEStandard.ps1` | New: `Import-PEStandard`, `Get-PEStandard`, `Get-PEStandardCoverage`, `Get-PEStandardChange` |
| `src/PolicyEngine/Private/TenantExport.ps1` | New: `Get-PETenantExportState` extracted from `Invoke-PEFullCheck` (Task 4) |
| `src/PolicyEngine/Public/Invoke-PEStandardCheck.ps1` | New: `Invoke-PEStandardCheck` |
| `src/PolicyEngine/Public/Decisions.ps1`, `Private/DecisionStore.ps1` | Modify: `RiskAccepted` kind with `ApprovedBy`, `StandardHash` |
| `src/PolicyEngine/Public/Set-PERiskAcceptance.ps1` | New: `Set-PERiskAcceptance` |
| `src/PolicyEngine/Public/Copy-PEStandardItem.ps1` | New: `Copy-PEStandardItem`, `Get-PEStandardAdoption` |
| `tools/Import-PEStandard.ps1`, `tools/Invoke-PEStandardCheck.ps1` | New: thin CLI wrappers (the first also fetches a tagged ASD release) |
| `tests/CompareSubset.Tests.ps1`, `StandardGuard.Tests.ps1`, `StandardImport.Tests.ps1`, `StandardCheck.Tests.ps1`, `RiskAccepted.Tests.ps1`, `StandardPromote.Tests.ps1`, `StandardRecheck.Tests.ps1` | New |
| `tests/fixtures/asd-mini/` | New: three small DSC files trimmed from the real ASD files |
| `docs/handover.md`, `docs/overview.md`, `docs/superpowers/specs/2026-10-27-standards-blueprints-design.md` | Modify (Task 9) |

Run one test file with `pwsh -NoProfile -Command "Invoke-Pester ./tests/<File>.Tests.ps1 -Output Detailed"`; the whole suite with `pwsh -NoProfile -File tools/Invoke-PETests.ps1 -Fast`.

## Task 0 (done): spike

On 2026-10-27 `ConvertTo-DSCObject` (DSCParser 3.1.0.7) parsed all seven ASD v1.4.0 files without error: 133 objects (Purview 51, Teams 40, Entra 22, Intune 10, Exchange 4, SharePoint 4, Defender 2). It warns about properties that do not exist in the installed module version (for example Entra `DefaultUserRoleAllowedToCreateApps`, SharePoint `Ensure`, Teams `Identity` on the `*Configuration` singletons), and about missing mandatory properties (Teams `IsSingleInstance`, Intune `appId`). Placeholders arrive as strings such as `"$ConfigurationData.NonNodeData.CertificateThumbprint"` and `$PrivUsers`. No `Ensure = "Absent"` appears in any file. Task 3 builds on this.

---

### Task 1: `Compare-PEState -Subset`

**Files:**
- Modify: `src/PolicyEngine/Public/Compare-PEState.ps1` (new parameter and one call at the top)
- Modify: `src/PolicyEngine/Private/Compare.ps1` (new `Select-PESubsetTarget`)
- Test: `tests/CompareSubset.Tests.ps1`

**Interfaces:**
- Consumes: `New-PEState`, `Get-PEMatchKey`, `Get-PEPropertyBag` (existing, `Private/Compare.ps1`).
- Produces: `Compare-PEState -Blueprint -Target [-Subset]`. `Select-PESubsetTarget -Blueprint <state> -Target <state> -> state` (private): the target state reduced to the records whose match key the blueprint has, each with only the properties the blueprint's record names (case-insensitive). Ambiguous duplicates of a kept key are kept; `NotChecked` and `Meta` are carried over unchanged.

- [ ] **Step 1: Write the failing tests** in `tests/CompareSubset.Tests.ps1` (copy the `New-TestRecord` / `New-TestState` helpers from `tests/BlueprintMove.Tests.ps1`):
  - `It 'ignores target records the blueprint does not define'`: blueprint `g1`; target `g1`, `g2`; `Compare-PEState -Subset` returns no finding; without `-Subset` it returns one `TargetOnly` for `g2`.
  - `It 'ignores properties the blueprint does not state'`: blueprint `g1 { Description = 'a' }`; target `g1 { Description = 'a'; Visibility = 'Public' }`; `-Subset` gives no finding.
  - `It 'still reports a stated property that differs'`: `Description` `'a'` vs `'b'` gives one `Changed` whose single difference is `Description`.
  - `It 'reports a defined item the tenant lacks as Missing'`.
  - `It 'reports duplicate target keys of a defined item as Ambiguous'` (Review Focus 1): two target records with key `g1` give one `Ambiguous` finding.
  - `It 'does not count an empty stated string as different from an absent property'` (Review Focus 2): blueprint `Description = ''`, target without `Description`: no finding. If this fails with the existing comparison, fix it in `Select-PESubsetTarget` by adding the missing property as `''` to the projected target record, not in `Get-PEPropertyDifference`.
  - `It 'does not change results without -Subset'`: run the existing `tests/Compare.Tests.ps1` unchanged (Step 4).

- [ ] **Step 2: Run to see them fail** (`-Subset` is not a parameter): expect `A parameter cannot be found that matches parameter name 'Subset'`.

- [ ] **Step 3: Implement** `[switch]$Subset` on `Compare-PEState` and `Select-PESubsetTarget`; when `-Subset` is set, replace `$Target` with `Select-PESubsetTarget -Blueprint $Blueprint -Target $Target` before any other step. Add one line to the comment-based help describing the mode. No other change to the comparison.

- [ ] **Step 4: Run** `tests/CompareSubset.Tests.ps1` and `tests/Compare.Tests.ps1`; expect all pass.

- [ ] **Step 5: Commit** `feat: Compare-PEState -Subset compares only what the blueprint states`.

---

### Task 2: Standard marker and read-only guards

**Files:**
- Create: `src/PolicyEngine/Private/Standard.ps1`
- Modify: `Public/Blueprint.ps1` (`Approve-PEBlueprintChange`), `Public/Move-PEBlueprintItem.ps1`, `Public/Restore-PEBlueprintVersion.ps1`, `Public/Invoke-PERectify.ps1`, `Public/Invoke-PEFullCheck.ps1`, `Public/Invoke-PEScopeCheck.ps1`, `Public/Add-PEBlueprintType.ps1`, `Public/Tenants.ps1` (`Set-PETenant`, `-Blueprints`)
- Test: `tests/StandardGuard.Tests.ps1`

**Interfaces:**
- Produces (private): `Get-PEStandardInfo -Name <string> [-DataRoot <string>] -> pscustomobject | $null` reading `blueprints\<Name>\standard.json` (shape in Task 3); `Assert-PEBlueprintNotStandard -Name <string> -Action <string> [-DataRoot <string>]` throws `Blueprint '<Name>' is a standard (read-only): cannot <Action>.` when `Get-PEStandardInfo` returns a value.

- [ ] **Step 1: Write failing tests**: create a blueprint folder with `Initialize-PEBlueprint`, write a minimal `standard.json` beside it (`Kind = 'Standard'`), then assert each of the listed commands throws with `*is a standard (read-only)*`: `Approve-PEBlueprintChange`, `Move-PEBlueprintItem -To`, `Restore-PEBlueprintVersion`, `Invoke-PEFullCheck -BlueprintName` (message also says to use `Invoke-PEStandardCheck`), `Invoke-PEScopeCheck`, `Add-PEBlueprintType`, `Invoke-PERectify`, and `Set-PETenant -Blueprints @('<standard>')`. Also assert `Move-PEBlueprintItem -From <standard>` is not refused by the guard (it is the source of a promote). An ordinary blueprint with no `standard.json` is unaffected (existing suites).
- [ ] **Step 2: Run; expect FAIL** (the commands do not throw that message).
- [ ] **Step 3: Implement** the two private functions and one `Assert-PEBlueprintNotStandard` call at the top of each listed command after parameter validation (for `Set-PETenant`, once per name in `-Blueprints`). Use the command's own name as `-Action` text.
- [ ] **Step 4: Run** the new file plus `Blueprint`, `BlueprintMove`, `RestoreBlueprint`, `Tenants`, `FullCheck`, `Scopes`, `AddBlueprintType`, `InvokeRectify` tests; expect all pass.
- [ ] **Step 5: Commit** `feat: a standard is a read-only blueprint; guard every write path`.

---

### Task 3: Import a standard from DSC files

**Files:**
- Modify: `src/PolicyEngine/Private/Standard.ps1` (classification helpers)
- Create: `src/PolicyEngine/Public/Import-PEStandard.ps1`
- Create: `tests/fixtures/asd-mini/Entra.txt`, `Teams.txt`, `ConfigurationData.txt` (trim from the real ASD v1.4.0 files, keeping the `.txt` extension and header lines)
- Test: `tests/StandardImport.Tests.ps1`

The Entra fixture holds: one `AADNamedLocationPolicy` with nothing tenant-bound (covered); one `AADConditionalAccessPolicy` whose `IncludeGroups`/`ExcludeUsers` use `$ConditionalExclude` (placeholder); one `AADAuthorizationPolicy` with `DefaultUserRoleAllowedToCreateApps` (unknown property in the pinned module). The Teams fixture holds one `TeamsMeetingConfiguration` with `Identity = "Global"` (unknown property) and one `TeamsMessagingPolicy` that is clean.

**Interfaces:**
- Consumes: `Read-PEExport` (Private/Parse.ps1), `ConvertTo-PENormalizedRecord`, `New-PEState`, `Initialize-PEBlueprint`, `Write-PEBlueprintVersion`, `Enter-PEBlueprintLock`/`Exit-PEBlueprintLock`, `Get-PEDscResourceSchema` (Private/DscSchema.ps1), `Get-PEBlueprintChange`.
- Produces:
  - `Import-PEStandard -Name <string> -Path <folder> -SourceName <string> -SourceUrl <string> -SourceVersion <string> [-License <string> = 'CC BY 4.0'] [-Attribution <string>] [-Reason <string>] [-DataRoot <string>] -> [pscustomobject]@{ Name; Version (blueprint version); SourceVersion; Total; Covered; NotCovered; ByReason (hashtable); Added; Changed; Removed }`
  - `Get-PEStandard [-Name <string>] [-DataRoot <string>]` -> one object per standard: `Name`, `SourceName`, `SourceUrl`, `License`, `Attribution`, `Versions` (each `Version`, `SourceVersion`, `ImportedAt`, `Total`, `Covered`).
  - `Get-PEStandardCoverage -Name <string> [-Version latest|<int>] [-DataRoot <string>]` -> one row per not-covered item: `ResourceType`, `Key`, `Workload`, `Reason` (`Placeholder` | `UnknownProperty`), `Detail`.
  - `Get-PEStandardChange -Name <string> -FromVersion <int> -ToVersion <int> [-DataRoot <string>]` -> rows `Op` (Added|Changed|Removed), `ResourceType`, `Key`.
  - Private: `Get-PEStandardItemClass -Record <normalised record> -> $null | @{ Reason; Detail }`: `Placeholder` when any string value, at any depth, matches `\$[A-Za-z]` (variable reference); else `UnknownProperty` when a top-level property name is not in `Get-PEDscResourceSchema` for the record's type (detail lists the names). Placeholder wins.
  - `standard.json` shape: `{ Kind = 'Standard'; Name; SourceName; SourceUrl; License; Attribution; Versions = [ { Version; SourceVersion; ImportedAt; Total; Covered } ] }`. `coverage\v0001.json` holds the not-covered rows. Each stored record gains `Provenance = [ordered]@{ Standard = <Name>; SourceVersion = <string>; ControlId = $null }`. Version-file `Meta` gains `SourceVersion` and `Kind = 'Standard'`.

- [ ] **Step 1: Write failing tests** in `tests/StandardImport.Tests.ps1` (temp `-DataRoot`, fixture folder as `-Path`):
  - `It 'imports the clean items and counts the rest as not covered'`: result `Total = 5`, `Covered = 2`, `ByReason.Placeholder = 1`, `ByReason.UnknownProperty = 2`; `Get-PEBlueprint` holds exactly the two clean records.
  - `It 'strips connection settings and tenant ids'`: no stored record has `ApplicationId`, `CertificateThumbprint` or `TenantId` in `Properties` (the existing global ignore list does this; the test proves the ASD `$ConfigurationData...` values never reach a record).
  - `It 'puts provenance on every stored record'`: `Provenance.Standard`, `Provenance.SourceVersion` equal the arguments; `ControlId` is `$null`.
  - `It 'writes standard.json and coverage for the version'`; `Get-PEStandardCoverage` lists the three rows with reasons and a `Detail` naming `DefaultUserRoleAllowedToCreateApps`.
  - `It 'refuses to import the same source version twice'` (no empty version written).
  - `It 'imports a newer source version as the next blueprint version and reports what changed'`: change one property value and remove one item in a copy of the fixture; result `Version = 2`, `Changed = 1`, `Removed = 1`; `Get-PEStandardChange -FromVersion 1 -ToVersion 2` agrees.
  - `It 'reads files with the .txt extension and a byte-order mark'`.
  - `It 'never runs the files'`: a fixture file containing `New-Item <temp>\pwned.txt` as a top-level statement leaves no `pwned.txt`.
- [ ] **Step 2: Run; expect FAIL** (`Import-PEStandard` is not recognised).
- [ ] **Step 3: Implement** `Import-PEStandard`: copy each `*.txt`/`*.ps1` of `-Path` (not `ConfigurationData`) to a temp folder as `.ps1`; `Read-PEExport` each; normalise with `ConvertTo-PENormalizedRecord`; classify with `Get-PEStandardItemClass`; build the state of covered records (with `Provenance`) and `Meta` (`TenantId = 'standard'`, `ExportedAt` now, `Source = -SourceName`, `SourceVersion`, `Kind = 'Standard'`). Version 1: `Initialize-PEBlueprint`; later: take the lock and call `Write-PEBlueprintVersion` (not `Approve-PEBlueprintChange`, which refuses standards) with every Missing, TargetOnly and Changed finding of `Get-PEBlueprintChange`, with `-Reason` defaulting to `Import <SourceName> <SourceVersion>`. Then write `coverage\vNNNN.json` and update `standard.json` (create on first import). Print the attribution line with `Write-Host`. Pass the parser's warnings through `-WarningAction SilentlyContinue` and rely on `Get-PEStandardItemClass` for reasons.
- [ ] **Step 4: Run** `tests/StandardImport.Tests.ps1`; expect PASS.
- [ ] **Step 5: Smoke test against the real files** (not part of the suite): download the seven ASD v1.4.0 files into `data/sources/asd-v1.4.0/` (see Task 8) and run `Import-PEStandard`; record `Total`, `Covered` and `ByReason` in `docs/handover.md` (Task 9). Expect `Total = 133`.
- [ ] **Step 6: Commit** `feat: Import-PEStandard turns DSC configuration files into a read-only standard`.

---

### Task 4: Extract the tenant export step from `Invoke-PEFullCheck`

**Files:**
- Create: `src/PolicyEngine/Private/TenantExport.ps1`
- Modify: `src/PolicyEngine/Public/Invoke-PEFullCheck.ps1`
- Test: existing `tests/FullCheck.Tests.ps1`, `Scopes.Tests.ps1`, `UploadCheck.Tests.ps1` stay green (a refactor: no new behaviour)

**Interfaces:**
- Produces (private): `Get-PETenantExportState -Blueprint <state> -Workloads <string[]> -CheckId <string> -Tenant <string> -Root <string> [-ExportScript <scriptblock>] [-TargetTenantId <string>] -> [pscustomobject]@{ State; ExportPath; ExportedAt; TenantId; LogWarnings }`. It is the existing body from `$outputPath` through `New-PEState` (export, `Read-PEExport`, normalise, classify from `export.log`, blueprint types missing from the export become NotChecked), with `-Blueprint` used only for the "blueprint types with nothing in the export" rule. `Invoke-PEFullCheck` keeps its signature, check id logic, `Compare-PEState` call and `result.json` shape.

- [ ] **Step 1: Run the three existing suites; note they pass** (baseline).
- [ ] **Step 2: Move the code** into `Get-PETenantExportState` and call it from `Invoke-PEFullCheck`; do not change behaviour, messages or the document written.
- [ ] **Step 3: Run the three suites plus `tools/Invoke-PETests.ps1 -Fast`; expect identical results.**
- [ ] **Step 4: Commit** `refactor: extract Get-PETenantExportState from Invoke-PEFullCheck`.

---

### Task 5: `Invoke-PEStandardCheck`

**Files:**
- Create: `src/PolicyEngine/Public/Invoke-PEStandardCheck.ps1`
- Test: `tests/StandardCheck.Tests.ps1`

**Interfaces:**
- Consumes: `Get-PEBlueprint`, `Get-PEStandardInfo`, `Get-PEStandardCoverage`, `Get-PETenantExportState`, `Compare-PEState -Subset`, `Get-PEDecision`, `Write-PEJsonNew`.
- Produces: `Invoke-PEStandardCheck -StandardName <string> [-Version latest|<int>] [-Tenant <slug> = 'master'] [-ExportScript <scriptblock>] [-TargetTenantId <string>] [-DataRoot <string>] -> [pscustomobject]@{ CheckId; Findings; Coverage; State; Path }`. Writes `checks\<CheckId>\result.json` with `Kind = 'Standard'`, `TenantSlug`, `StandardName`, `StandardVersion`, `SourceVersion`, `Coverage = [ordered]@{ Total; Covered; Checked; NotCovered = <import reasons>; NotReadable; ByWorkload = @{ <workload> = @{ Total; Covered; Checked } } }`, `Findings`, `State`. `Checked = Covered - items whose type came back NotChecked/NotAvailable`; those items count under `NotReadable` (reason `TypeNotReadable`). `Get-PECheck -Latest -Kind Full` must not return it.

- [ ] **Step 1: Write failing tests** using the `-ExportScript` seam (return a folder holding a small `export.ps1` and `export.log`, as `tests/FullCheck.Tests.ps1` does) with a standard imported from `tests/fixtures/asd-mini`:
  - `It 'exports only the workloads the standard covers'`: the script receives `Workloads` equal to the distinct workloads of the standard's records.
  - `It 'reports a missing, a changed and a matching item'` and `It 'does not report tenant objects the standard does not define'`.
  - `It 'counts coverage per run: Total, Covered, Checked'`.
  - `It 'treats a type the export log marks Failed as not readable, not Missing'` (Review Focus 3): coverage `NotReadable` counts its items; no `Missing` finding for them.
  - `It 'saves Kind Standard and is ignored by Get-PECheck -Kind Full'`.
  - `It 'applies Unmanaged and Noise decisions like a full check'` (one `Noise` decision hides a Changed difference).
- [ ] **Step 2: Run; expect FAIL.**
- [ ] **Step 3: Implement** it from `Invoke-PEFullCheck`'s shape: new check id the same way, `Get-PETenantExportState` with the standard's records as `-Blueprint`, `Compare-PEState -Subset -Decisions`, then the coverage computation.
- [ ] **Step 4: Run** `tests/StandardCheck.Tests.ps1` and `tests/GetCheck.Tests.ps1`; expect PASS.
- [ ] **Step 5: Commit** `feat: Invoke-PEStandardCheck compares a tenant with a standard and reports coverage`.

---

### Task 6: Accept risk (decision kind and comparison)

**Files:**
- Modify: `src/PolicyEngine/Public/Decisions.ps1` (`Set-PEDecision`, `Get-PEDecision` `ValidateSet`, new `-ApprovedBy`, `-StandardHash`), `src/PolicyEngine/Private/DecisionStore.ps1` (`Test-PEDecisionMatch` treats `RiskAccepted` like `PropertyExcluded`: Kind, ResourceType, Key, Property, Tenant identify it)
- Modify: `src/PolicyEngine/Public/Compare-PEState.ps1`, `Private/Compare.ps1`
- Test: `tests/RiskAccepted.Tests.ps1`

**Interfaces:**
- Produces: decision `Kind = 'RiskAccepted'` with `Tenant` (required), `ResourceType`, `Key` (required), optional `Property`, `Reason` (required), `ApprovedBy` (required), `StandardHash` (optional string), `At`. `Get-PEDecisionHash -Record <record> -> string` (private; SHA-256 hex of `ConvertTo-PECanonicalValue` of the record's `Properties`). In `Compare-PEState`, for a `Missing` or `Changed` finding whose item has a matching `RiskAccepted` decision (tenant-limited by the caller, as `PropertyExcluded` is): item-level -> `State = 'Accepted'`, with `ApprovedBy`, `AcceptedReason`, `AcceptedAt` on the finding; property-level -> that difference moves from `Differences` to `AcceptedDifferences` (the finding is `Accepted` only when nothing is left in `Differences`). When the decision has a `StandardHash` that differs from `Get-PEDecisionHash` of the finding's `BlueprintRecord`, the finding stays `Open` and gets `Hint = 'Accepted risk needs another look: the standard has changed.'`.

- [ ] **Step 1: Write failing tests**:
  - `Set-PEDecision -Kind RiskAccepted` requires `-Tenant`, `-Key`, `-ApprovedBy` and `-Reason` (each missing one throws); a second call for the same item replaces the first.
  - `It 'marks a Changed finding Accepted with who and why'` and the item stays in the findings (visible).
  - `It 'accepts one property and leaves other differences open'`.
  - `It 'accepts a Missing item'`.
  - `It 'is for one tenant only'`: a decision for tenant `dev` does not change a `master` comparison.
  - `It 'reopens an acceptance when the standard value changed'` (Review Focus 4): decision with `StandardHash` from the old record, comparison with a record that has another value: `State = 'Open'` and the hint above.
  - Existing `tests/Decisions.Tests.ps1`, `PropertyExclusion.Tests.ps1`, `Compare.Tests.ps1` pass unchanged.
- [ ] **Step 2: Run; expect FAIL.**
- [ ] **Step 3: Implement.** Follow the `PropertyExcluded` handling in `Compare-PEState` (read it first) so the two behave alike; do not change `PropertyExcluded`.
- [ ] **Step 4: Run** the new file and the three existing suites; expect PASS.
- [ ] **Step 5: Commit** `feat: RiskAccepted decision (approved by, reason) shown as accepted in comparisons`.

---

### Task 7: `Set-PERiskAcceptance`

**Files:**
- Create: `src/PolicyEngine/Public/Set-PERiskAcceptance.ps1`
- Test: add to `tests/RiskAccepted.Tests.ps1`

**Interfaces:**
- Consumes: `Get-PEBlueprint`, `Get-PEDecisionHash`, `Set-PEDecision`, `Get-PEDecision`, `Remove-PEDecision`.
- Produces: `Set-PERiskAcceptance -Standard <string> -Tenant <slug> -ResourceType <string> -Key <string> [-Property <string>] -ApprovedBy <string> -Reason <string> [-DataRoot <string>]` writes a `RiskAccepted` decision with `StandardHash` taken from the standard's latest record for that item; throws when the standard has no such item. `Get-PEDecision -Kind RiskAccepted` lists them; `Remove-PEDecision` (existing) removes one.

- [ ] **Step 1: Write failing tests**: it writes the decision with the right hash; it throws `*has no item*` for an unknown key; run against a real `Invoke-PEStandardCheck` result so the finding comes back `Accepted` on the next check.
- [ ] **Step 2: Run; expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run; expect PASS.**
- [ ] **Step 5: Commit** `feat: Set-PERiskAcceptance records an accepted risk against a standard item`.

---

### Task 8: Promote from a standard, and adoption

**Files:**
- Create: `src/PolicyEngine/Public/Copy-PEStandardItem.ps1`
- Test: `tests/StandardPromote.Tests.ps1`

**Interfaces:**
- Consumes: `Get-PEBlueprint`, `Get-PEBlueprintDirectory`, `Get-PEBlueprintVersionNumber`, `Enter-PEBlueprintLock`/`Exit-PEBlueprintLock`, `Write-PEBlueprintVersion`, `New-PEState`, `Assert-PEBlueprintNotStandard`.
- Produces:
  - `Copy-PEStandardItem -Standard <string> -To <blueprint> (-Item <object[]> | -All) -Reason <string> -ExpectedVersion <int> [-DataRoot <string>] -> [int]` (the new version of `-To`). `-Item` entries have `ResourceType` and `Key`. Refuses a standard as `-To` and an item the standard does not have. A new item is added with the standard's record (including `Provenance`). For an item `-To` already has, the properties the standard states overwrite the same properties of `-To`'s record and every other property of `-To`'s record is kept; `Provenance` is set. Nothing in `-To` is removed. Written as one version under `-To`'s lock; throws when `-To` has moved past `-ExpectedVersion` (same rule and message as `Move-PEBlueprintItem`). Implementation note: build the target's records with the chosen items replaced or added, pass that as `-MasterState` to `Write-PEBlueprintVersion` with the resulting `Missing`/`Changed` findings.
  - `Get-PEStandardAdoption -Standard <string> -Blueprint <string> [-DataRoot <string>] -> rows` `ResourceType`, `Key`, `Adopted` (bool: the blueprint has the item with `Provenance.Standard` equal to the standard), `SourceVersion` (of the adopted copy, else `$null`).
  - Like `Move-PEBlueprintItem`, it needs no master confirmation; the GUI's two-step confirm covers that later (flag in handover).

- [ ] **Step 1: Write failing tests**: adds a new item with provenance; merges into an existing record keeping its other properties; `-All` copies every standard item; refuses `-To <standard>`; refuses an unknown item; refuses a stale `-ExpectedVersion`; the standard itself is unchanged; adoption shows adopted and not-adopted items and still counts an adopted item after its properties were edited in the blueprint.
- [ ] **Step 2: Run; expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run; expect PASS.**
- [ ] **Step 5: Commit** `feat: Copy-PEStandardItem promotes standard items into a blueprint with provenance`.

---

### Task 9: CLI tools, re-check across versions, docs

**Files:**
- Create: `tools/Import-PEStandard.ps1`, `tools/Invoke-PEStandardCheck.ps1`
- Test: `tests/StandardRecheck.Tests.ps1`
- Modify: `docs/handover.md`, `docs/overview.md`, the spec (counts)

**Interfaces:**
- `tools/Import-PEStandard.ps1 -Standard asd [-Tag <string>] [-Path <folder>] [-DataRoot <string>]`: without `-Path`, resolves the latest tag matching `^v\d+\.\d+\.\d+$` with `git ls-remote --tags --sort=-v:refname https://github.com/ASD-Blueprint/ASD-Blueprint-for-Secure-Cloud.git` (or uses `-Tag`), does `git clone --depth 1 --branch <tag>` into `data/sources/asd-<tag>` when absent, then calls `Import-PEStandard -Path <clone>\static\content\files\automation\dsc -SourceName 'ASD Blueprint for Secure Cloud' -SourceUrl <repo url> -SourceVersion <tag> -Attribution 'ASD Blueprint for Secure Cloud, Australian Signals Directorate, CC BY 4.0'` with `-Name asd`. Prints the summary and the coverage by reason. Same shape as `tools/Invoke-PEFullCheck.ps1`.
- `tools/Invoke-PEStandardCheck.ps1 -StandardName <string> [-Tenant <slug>] [-DataRoot <string>]`: prints `Check <id>: checked N of M settings (<not covered> not covered, <not readable> not readable)`, then findings by Kind and by workload.

- [ ] **Step 1: Write the failing end-to-end test** `tests/StandardRecheck.Tests.ps1` using the fixtures: import v1; run `Invoke-PEStandardCheck` (fake export with one differing item); `Set-PERiskAcceptance` on it; check again -> `Accepted`; import a v2 where that item's stated value changed; check again -> the item is `Open` with the "needs another look" hint and `Get-PEStandardChange` lists it as `Changed`; promote the other differing item with `Copy-PEStandardItem` and see it adopted.
- [ ] **Step 2: Run; expect FAIL until the earlier tasks are in; then PASS.**
- [ ] **Step 3: Write the two tool scripts** (thin wrappers only) and check each with `pwsh -NoProfile -File tools/<script>.ps1 -?` showing its help.
- [ ] **Step 4: Run the real-file smoke test** from Task 3 Step 5 through `tools/Import-PEStandard.ps1 -Standard asd` (network and git needed; not in the suite) and note the numbers.
- [ ] **Step 5: Docs.** `docs/overview.md`: a "Standards" paragraph under Tools (commands above, where data lives). `docs/handover.md`: a section "Standards blueprints (2026-10-27)" with the decisions (read-only kind, subset compare, whole-item exclusion, light sign-off), the smoke-test numbers, and the deliberate gaps: placeholder and unknown-property items not covered; Teams `*Configuration` singletons lose `Identity` in the pinned module and are not covered; no control IDs; SharePoint not readable by the Reader app; promote needs no master confirmation yet; CIS has no DSC-format source yet; GUI is next (mock-ups). Spec: correct the resource counts to Purview 51 / total 133.
- [ ] **Step 6: Run the whole suite** `tools/Invoke-PETests.ps1 -Fast`; expect no new failures.
- [ ] **Step 7: Commit and push** `feat: standards CLI tools, version re-check test and docs`.

---

## Self-review

- **Spec coverage:** goal 1 Task 2/3; 2 Task 0/3; 3 Task 1/5; 4 Task 3/5 (not covered, reasons); 5 Task 8; 6 Task 6/7; 7 Task 3 (`Get-PEStandardChange`), Task 6, Task 9; 8 (engine/CLI first) the whole plan, GUI left out; non-goals respected (no control-ID mapping, no expiry, no CIS). Provenance, coverage per tenant per run, read-only guard, version diff on parsed values: Tasks 8, 5, 2, 3.
- **Types:** `Get-PEStandardInfo`, `Assert-PEBlueprintNotStandard` (Task 2) are used by Tasks 3, 5, 8 with the same names; `Get-PEDecisionHash` (Task 6) is used by Task 7; `Get-PETenantExportState` (Task 4) by Task 5; `Provenance` fields match between Tasks 3 and 8.
- **Proportion:** each task is one reviewable deliverable with its tests; bodies are left to the implementer except for the two algorithms the signatures do not determine (the merge in Task 8, the classification order in Task 3).
