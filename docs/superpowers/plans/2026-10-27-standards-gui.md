# Standards in the GUI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show standards in the GUI as approved in the mock-ups: a Standards page, a check page with Adopt and Accept risk, a Not covered page and the Accept risk dialog, backed by view models, API routes and worker requests that call the existing engine commands.

**Architecture:** `Export-PEGuiData` writes standards view models (index, per-tenant check, coverage) next to the existing ones; `gui/PEGui.psm1` serves them and previews and validates six new request actions; the worker (`Private/GuiRequest.ps1`) runs them through the engine's public commands (`Invoke-PEStandardCheck`, `Copy-PEStandardItem`, `Set-PERiskAcceptance`, `Import-PEStandard`); the front end gets a new `standards.js` (screens) and `standards-model.js` (pure helpers, tested with node), hooked into `app.js` (route, navigation, Selection list, dialogs).

**Tech Stack:** PowerShell 7.6, Pester 5, Pode (server, not needed for tests), plain JavaScript (no build step), node for the pure-helper tests, Playwright for the browser check.

**Spec:** `docs/superpowers/specs/2026-10-27-standards-gui-design.md` (mock-ups: `docs/gui-mockups/standards.html`; engine: `docs/superpowers/specs/2026-10-27-standards-blueprints-design.md`).

## Global Constraints

- Thin wrapper over the engine: the GUI reads view models and queues requests; coverage maths, subset comparison and record hashing stay in the engine. The only engine additions are the ones named in Tasks 1 to 3.
- Follow the GUI's patterns (`gui/README.md`): view-model JSON replaced atomically, `/api/...` read routes through `Invoke-PEGuiApi`, actions as queued requests and jobs processed by the worker, the Selection list in the browser's local storage per blueprint with the server re-checking everything at run time, startup token and Host header checks unchanged.
- Not covered and not readable are never merged into "match" (headline, bar, table and rows).
- A standard is read-only. Adopt writes only the tenant's own blueprint (master-write confirmation when that is the master blueprint; a replica without its own blueprint is refused). The Standards page never writes a tenant.
- Accept risk needs `approvedBy` and `why` per item; Adopt needs a reason; no expiry or evidence.
- Names that become paths (standard name, tenant id) are validated; a release tag must match `^v\d+\.\d+\.\d+$` before it reaches `git`.
- Files from the internet are only parsed, never run; the import clones with a sparse checkout (Windows path limit).
- No new framework, build step, external font or browser network call. Light and dark themes both work; reuse the colour tokens of the mock-up (`--accept` teal and friends).
- PowerShell tests are offline (fake data, scriptblock seams). Match surrounding code style; ASCII in generated text; commit messages end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Record deliberate gaps in `docs/handover.md`.

## Review Focus

Inputs the spec implies that no task's headline tests would otherwise hit (each has its test in the owning task):

1. Items not covered or not readable are counted in `notCovered`/`notReadable` and never in `match` (Task 4); the bar and table show them apart (Task 7).
2. Adopt for a replica with no blueprint of its own is refused at preview and at run; Adopt into the master blueprint is flagged `writesMaster` and refused without the confirmation (Tasks 5 and 6).
3. Accept risk without `approvedBy` or `why`, with a property that does not differ, or with a partial property selection (one decision per property) (Tasks 5 and 6).
4. A standard name or tenant id with path characters on the new routes, and a release tag that is not `vX.Y.Z`, are refused (Tasks 3 and 5).
5. A Drift-review pick and a Standards pick for the same item id never replace each other in the Selection list; an accepted risk whose standard changed shows as Look again and offers Remove, Adopt and Accept risk (Tasks 4 and 8).

## File Structure

| File | Responsibility |
| --- | --- |
| `src/PolicyEngine/Public/Compare-PEState.ps1`, `Private/Compare.ps1` | Modify: `AcceptanceStale` flag on findings (Task 1) |
| `src/PolicyEngine/Public/Get-PECheck.ps1`, `Public/Invoke-PEStandardCheck.ps1`, `Public/Update-PEStandardCheck.ps1`, `Private/Standard.ps1` | Modify and create: `-Standard` filter, decision filter helper, `Update-PEStandardCheck` (Task 2) |
| `src/PolicyEngine/Data/StandardSources.psd1`, `Public/StandardRelease.ps1`, `tools/Import-PEStandard.ps1` | Create and modify: release lookup, sparse clone, import by tag (Task 3) |
| `src/PolicyEngine/Private/GuiStandards.ps1`, `Public/Export-PEGuiData.ps1` | Create and modify: standards view models (Task 4) |
| `gui/PEGui.psm1`, `gui/tests/PEGui.Tests.ps1` (or a new `gui/tests/Standards.Api.Tests.ps1`) | Modify: routes, preview and validation, mock job results (Task 5) |
| `src/PolicyEngine/Private/GuiRequest.ps1`, `Public/Invoke-PEGuiRequest.ps1` | Modify: six handlers (Task 6) |
| `gui/public/assets/standards-model.js`, `standards.js`, `app.js`, `app.css`, `index.html` | Create and modify: front end (Tasks 7 and 8) |
| `gui/mock-data/**`, `gui/README.md`, `docs/overview.md`, `docs/handover.md` | Modify: mock data for `Start-PEGui -Mock`, docs (Task 9) |
| `tests/StandardEngineGui.Tests.ps1`, `tests/StandardRelease.Tests.ps1`, `tests/GuiStandardExport.Tests.ps1`, `tests/GuiStandardRequest.Tests.ps1`, `gui/tests/Standards.Tests.ps1` | New tests (names are the builder's call within these folders) |

Run one test file with `pwsh -NoProfile -Command "Invoke-Pester ./tests/<File>.Tests.ps1 -Output Minimal"`; the engine suite with `pwsh -NoProfile -File tools/Invoke-PETests.ps1 -Fast`; the GUI tests with `pwsh -NoProfile -Command "Invoke-Pester -Path gui/tests -Output Minimal"`.

---

### Task 1: Stale acceptances are flagged by the engine

**Files:**
- Modify: `src/PolicyEngine/Private/Compare.ps1` (`New-PEFinding`), `src/PolicyEngine/Public/Compare-PEState.ps1`
- Test: `tests/RiskAccepted.Tests.ps1` (add cases)

**Interfaces:**
- Produces: every finding has `AcceptanceStale` (`[bool]`, default `$false`); `$true` exactly when an accepted risk was set aside because the standard's record hash changed (the case that sets `Hint = 'Accepted risk needs another look: the standard has changed.'`).

- [ ] **Step 1: Write the failing tests** in `tests/RiskAccepted.Tests.ps1`: in the existing "reopens an acceptance when the standard value changed" scenario assert `$stale.AcceptanceStale | Should -BeTrue` and that the unchanged-standard Accepted finding and a plain Changed finding have `AcceptanceStale -eq $false`; add the same assertion for a property-level acceptance gone stale.
- [ ] **Step 2: Run it; expect FAIL** (`AcceptanceStale` is null).
- [ ] **Step 3: Implement**: add `[bool]$AcceptanceStale = $false` to `New-PEFinding` and the output object; in `Compare-PEState` pass `-AcceptanceStale ($null -ne $changedHint)` where the Changed finding is built and set `$finding.AcceptanceStale = $true` where the item-level stale hint is set.
- [ ] **Step 4: Run** `RiskAccepted`, `Compare`, `CompareSubset`, `GuiExport` tests; expect PASS.
- [ ] **Step 5: Commit** `feat: findings say when an accepted risk went stale`.

---

### Task 2: Filter standard checks by standard, and re-compare a saved check

**Files:**
- Modify: `src/PolicyEngine/Public/Get-PECheck.ps1`, `src/PolicyEngine/Public/Invoke-PEStandardCheck.ps1`, `src/PolicyEngine/Private/Standard.ps1`
- Create: `src/PolicyEngine/Public/Update-PEStandardCheck.ps1`
- Test: `tests/StandardEngineGui.Tests.ps1`

**Interfaces:**
- Produces:
  - `Get-PECheck -Latest -Kind Standard [-Standard <string>] [-Tenant <slug>]`: with `-Standard`, only checks whose `StandardName` equals it (case-sensitive) are considered; the error text names the standard.
  - `Get-PEStandardDecision -Tenant <slug> -StandardName <string> [-DataRoot <string>] -> object[]` (private): the tenant's decisions with every `RiskAccepted` decision of another standard removed (the filter now inline in `Invoke-PEStandardCheck`, which calls this instead).
  - `Update-PEStandardCheck -Tenant <slug> -StandardName <string> [-DataRoot <string>] -> [string]` (new CheckId): re-compares the latest Standard check of the tenant (its saved `State`) with the same standard version (`Get-PEBlueprint -Version <StandardVersion>`) and the current decisions (`Compare-PEState -Subset`), saves a copy of the check document with the new `Findings`, a new CheckId greater than the old one (`New-PECheckId`), and `State.Meta.PatchedFrom` / `PatchedAt`. `Coverage`, `State.Records` and the export time are unchanged. No tenant is read.

- [ ] **Step 1: Write the failing tests** (`tests/StandardEngineGui.Tests.ps1`; build a standard with `Import-PEStandard` from `tests/fixtures/asd-mini` and a check with `Invoke-PEStandardCheck` and the `New-TenantExport` helper in `tests/StandardTestHelper.ps1`, as `tests/StandardCheck.Tests.ps1` does): `Get-PECheck -Latest -Kind Standard -Standard 'asd'` returns the asd check and throws for `-Standard 'nist'`; after `Set-PERiskAcceptance` and `Update-PEStandardCheck` the new check's named-location finding is Accepted and the new id is greater; after `Remove-PEDecision -Kind RiskAccepted` and another update it is Open; the original checks are untouched; `Update-PEStandardCheck` throws `*No Standard check*` for a tenant with none; a decision accepted against another standard is ignored.
- [ ] **Step 2: Run; expect FAIL.**
- [ ] **Step 3: Implement** the three items above; reuse `Write-PEJsonNew` and the document-copy approach of `New-PEPatchedCheck` (`Private/GuiPatchedCheck.ps1`).
- [ ] **Step 4: Run** the new file plus `StandardCheck`, `StandardRecheck`, `GetCheck`; expect PASS.
- [ ] **Step 5: Commit** `feat: Update-PEStandardCheck re-compares a saved standard check after decisions change`.

---

### Task 3: Release lookup and import by tag, shared by the tool and the worker

**Files:**
- Create: `src/PolicyEngine/Data/StandardSources.psd1`, `src/PolicyEngine/Public/StandardRelease.ps1`
- Modify: `tools/Import-PEStandard.ps1`
- Test: `tests/StandardRelease.Tests.ps1`

**Interfaces:**
- Produces:
  - `Data\StandardSources.psd1`: `asd = @{ Repository = 'https://github.com/ASD-Blueprint/ASD-Blueprint-for-Secure-Cloud.git'; Url = 'https://github.com/ASD-Blueprint/ASD-Blueprint-for-Secure-Cloud'; DscPath = 'static/content/files/automation/dsc'; SourceName = 'ASD Blueprint for Secure Cloud'; Attribution = 'ASD Blueprint for Secure Cloud, Australian Signals Directorate, CC BY 4.0' }` (the only place that knows a source).
  - `Get-PEStandardLatestTag -Standard <'asd'> [-Git <scriptblock>] -> [string]`: the highest tag matching `^v\d+\.\d+\.\d+$` from `git ls-remote --tags --sort=-v:refname <Repository> refs/tags/v*`; throws when none or when the standard is unknown.
  - `Save-PEStandardRelease -Standard <'asd'> -Tag <string> [-DataRoot <string>] [-Git <scriptblock>] -> [pscustomobject]@{ Standard; Tag; Path; SourceName; SourceUrl; Attribution }`: `-Tag` must match `^v\d+\.\d+\.\d+$` (validated before any git call); sparse-clones (`git clone --depth 1 --branch <tag> --filter=blob:none --sparse`, then `git -C <clone> sparse-checkout set <DscPath>`) into `<DataRoot>\sources\<standard>-<tag>` unless that folder exists; `Path` is the DSC folder.
  - `Import-PEStandardRelease -Standard <'asd'> [-Tag <string>] [-DataRoot <string>] [-Git <scriptblock>] -> (the Import-PEStandard summary)`: resolves the latest tag when none, saves the release, then `Import-PEStandard` with the source's name, url, attribution and `-SourceVersion <tag>`.
  - The `-Git` seam: a scriptblock called with `[string[]]$Arguments`, returning `[pscustomobject]@{ ExitCode = <int>; Output = <string[]> }`; the default runs `git @Arguments` and captures both.

- [ ] **Step 1: Write the failing tests** with a fake `-Git`: the latest tag is chosen from a `refs/tags/` listing that includes `^{}` peeled lines and a non-matching tag; a bad `-Tag` (`'v1.4'`, `'main'`, `'v1.4.0; calc'`) throws before the fake is called; the sparse-clone arguments are exactly as above (assert the recorded argument arrays); an existing clone folder is not cloned again; a failing fake (`ExitCode 128`) throws a message naming the step; `Import-PEStandardRelease` with a fake that copies `tests/fixtures/asd-mini/*` into the sparse folder imports and returns `Total = 5`.
- [ ] **Step 2: Run; expect FAIL.**
- [ ] **Step 3: Implement**; reduce `tools/Import-PEStandard.ps1` to parameter handling, a call to `Import-PEStandardRelease` (or `Import-PEStandard` when `-Path` is given) and the same printed summary as today.
- [ ] **Step 4: Run** the new file and `StandardImport`; then `pwsh -NoProfile -File tools/Import-PEStandard.ps1 -Standard asd -Path <fixture> -Tag v1.4.0 -DataRoot <temp>` prints the summary line.
- [ ] **Step 5: Commit** `refactor: release lookup and import by tag live in the module`.

---

### Task 4: Export the standards view models

**Files:**
- Create: `src/PolicyEngine/Private/GuiStandards.ps1`
- Modify: `src/PolicyEngine/Public/Export-PEGuiData.ps1`
- Test: `tests/GuiStandardExport.Tests.ps1`

**Interfaces:**
- Consumes: `Get-PEStandard`, `Get-PEStandardCoverage`, `Get-PEStandardAdoption`, `Get-PECheck -Kind Standard -Standard`, `Get-PETenantBlueprint`, `ConvertTo-PEGuiItemId`, the `$write` scriptblock of `Export-PEGuiData`.
- Produces: `Export-PEGuiStandardData -Tenant <object[]> -MasterBlueprint <string> -DataRoot <string> -Write <scriptblock>` (private), called once from `Export-PEGuiData` after the tenant loop; a failure for one standard or tenant is a warning, never stops the export. Files (JSON, camelCase like the existing view models):
  - `standards/index.json`: array, one entry per standard: `name`, `sourceName`, `sourceUrl`, `license`, `attribution`, `versions[]` (`version`, `sourceVersion`, `importedAt`, `total`, `covered`), `latest` (the last entry of `versions`), `latestRelease` (`{ tag, checkedAt }` read from `data\sources\<name>-latest.json`, else `null`). `@()` when there are no standards.
  - `standards/<name>/coverage.json`: `{ standard, version, sourceVersion, total, covered, byReason{<Reason>:<n>}, rows[ { resourceType, key, workload, reason, detail } ] }` for the latest version.
  - `tenants/<id>/standards/<name>.json` for every registered tenant and standard: `{ standard, tenantId, checked: <bool> }`; when checked: `checkId`, `checkedAt`, `standardVersion`, `sourceVersion`, `patched` (the check has `Meta.PatchedFrom`), `newerVersionImported` (a later version of the standard exists), `headline { total, covered, checked, match, differ, accepted, lookAgain, notReadable, notCovered }`, `notCoveredByReason{}`, `byWorkload[ { workload, total, checked, match, differ, accepted, notReadable, notCovered } ]`, `adoption { blueprint, adopted, covered }`, `rows[]`.
  - A row: `itemId`, `resourceType`, `key`, `workload`, `kind` (`Missing` or `Changed`), `status` (`differs` | `missing` | `lookAgain` | `accepted`), `differences[ { property, standard, tenant } ]` (the engine's Blueprint and Target values renamed), `acceptedDifferences[]` (same shape), `approvedBy`, `acceptedReason`, `acceptedAt`, `hint`, `adopted` (bool), `adoptedFrom` (source version or `$null`), `allowedActions[]`.
  - Rules: `differ` = rows with status differs, missing or lookAgain; `accepted` = rows with status accepted; `lookAgain` is the subset of `differ` with `AcceptanceStale`; `match = checked - differ - accepted` (never below 0); `notReadable = covered - checked`; `notCovered = total - covered`; per workload the same from the coverage `ByWorkload` and the rows of that workload. `allowedActions`: differs/missing -> `Adopt`, `AcceptRisk`; lookAgain -> `Adopt`, `AcceptRisk`, `RemoveRisk`; accepted -> `RemoveRisk`; an adopted row loses `Adopt`. Rows are only Missing or Changed findings; other kinds are not rows.

- [ ] **Step 1: Write the failing tests** (a data root with `asd` imported from `tests/fixtures/asd-mini`, a registered tenant, a Standard check from the `New-TenantExport` helper with one Changed and one Missing item, then `Export-PEGuiData -BlueprintName main ...`): the three files exist with the shapes above; `headline` numbers satisfy the rules (Review Focus 1: a standard with 3 not-covered items and 1 not-readable type has them in `notCovered`/`notReadable` and `match + differ + accepted + notReadable + notCovered = total`); a risk accepted with `Set-PERiskAcceptance` and `Update-PEStandardCheck` moves its row to `accepted` with `approvedBy`/`acceptedReason`; a stale acceptance gives `status = 'lookAgain'`; after `Copy-PEStandardItem` the row is `adopted` and lacks `Adopt`; a tenant with no Standard check gets `{ checked = false }`; with no standards `index.json` is `[]`; a standard whose coverage file is unreadable gives a warning and the rest of the export still happens.
- [ ] **Step 2: Run; expect FAIL.**
- [ ] **Step 3: Implement** `Export-PEGuiStandardData` and the one call in `Export-PEGuiData` (guarded so existing tests and data folders without standards are unaffected).
- [ ] **Step 4: Run** the new file and `GuiExport`; expect PASS.
- [ ] **Step 5: Commit** `feat: Export-PEGuiData writes standards view models`.

---

### Task 5: API routes, request preview and validation

**Files:**
- Modify: `gui/PEGui.psm1`
- Test: `gui/tests/PEGui.Tests.ps1` (add a `Describe` for standards) or a new file beside it

**Interfaces:**
- Consumes: the view-model files of Task 4 through `Read-PEGuiFile`; `Get-PEGuiOwnBlueprint`, `Get-PEGuiNextBlueprintVersion`, `Get-PEGuiProperty`.
- Produces:
  - Routes (GET, via `Invoke-PEGuiApi`): `/api/standards`, `/api/standards/<name>/coverage`, `/api/tenants/<id>/standards/<name>`. `<name>` must match `^[A-Za-z0-9][A-Za-z0-9._-]*$` and `<id>` the existing tenant-id rule; a miss is a 400 with `error`, as for the other routes.
  - Request actions added to the known list: `StandardCheck`, `Adopt`, `AcceptRisk`, `RemoveRisk`, `ImportStandard`, `CheckStandardRelease`. `Adopt` is added to `$script:ReasonRequired`.
  - `Get-PEGuiStandardRequestPreview -DataRoot <string> -Request <object> -> preview` (same shape as `Get-PEGuiRequestPreview`'s output), called from the top of `Get-PEGuiRequestPreview` for the six actions so the long existing function is not changed. Item-level requests (`Adopt`, `AcceptRisk`, `RemoveRisk`) carry `tenantId`, `standard` and `items` of `{ itemId, properties?, approvedBy?, why? }`; each item must be a row of `tenants/<id>/standards/<standard>.json` and the action must be in the row's `allowedActions` (error text names the item and the reason). `Adopt`: refused for a replica whose own blueprint is the master blueprint (same text as Promote); `writesMaster` is true when the tenant's own blueprint is the master blueprint; `blueprintName` and `blueprintVersionAfter` are the tenant's own blueprint and its next version. `AcceptRisk`: every item needs non-empty `approvedBy` and `why`; each `properties` entry must be a property of the row's `differences`; no request-level reason. `RemoveRisk`: items must have status `accepted` or `lookAgain`. `StandardCheck`: needs `tenantId` and `standard`, refused for an offline tenant, a standard that is not in `standards/index.json`, or a tenant without a checked-in Reader app per the same rule `Recheck` uses. `ImportStandard`: `standard` must be known to the engine (`asd`); optional `tag` must match `^v\d+\.\d+\.\d+$`. `CheckStandardRelease`: `standard` as above. Each preview carries a plain-language `effect` per item (Adopt: "Copies the standard's setting into blueprint <name>. The tenant is not changed."; AcceptRisk: "Records that <approvedBy> accepted this difference: <why>."; RemoveRisk: "The difference counts again.").
  - `Add-PEGuiRequest` claims the next blueprint version for `Adopt` as it does for `Promote`.
  - The mock job timer (the `Applied (mock)` switch) has a result text for each new action.

- [ ] **Step 1: Write the failing tests** (seed a GUI data folder with the Task 4 files for a master and a replica; the existing `PEGui.Tests.ps1` shows how): the three GET routes return the files and refuse a name such as `..\x` or `a/b` (Review Focus 4); previews are valid for good Adopt, AcceptRisk, RemoveRisk, StandardCheck, ImportStandard and CheckStandardRelease requests; refused with the stated error for: Adopt on an `accepted` row, Adopt without a reason, Adopt from a replica with no own blueprint, AcceptRisk without `approvedBy`, without `why`, with a property that does not differ, RemoveRisk on a `differs` row, StandardCheck for an offline tenant, ImportStandard with `tag = 'main'` and with `tag = 'v1.4.0; calc'`; Adopt into the master blueprint has `writesMaster = $true`, a replica's own blueprint does not; `New-PEGuiRequest` writes the request and job for a valid Adopt and returns `created = $false` plus errors otherwise.
- [ ] **Step 2: Run; expect FAIL.**
- [ ] **Step 3: Implement** as above.
- [ ] **Step 4: Run** `gui/tests` (all files) and `tests/GuiRequest`, `tests/GuiExport`; expect PASS.
- [ ] **Step 5: Commit** `feat: API routes and request validation for standards`.

---

### Task 6: Worker handlers

**Files:**
- Modify: `src/PolicyEngine/Private/GuiRequest.ps1`, `src/PolicyEngine/Public/Invoke-PEGuiRequest.ps1` (help text, a `-GitScript` seam passed through to `Import-PEStandardRelease`)
- Test: `tests/GuiStandardRequest.Tests.ps1`

**Interfaces:**
- Consumes: Tasks 2 and 3, `Copy-PEStandardItem`, `Set-PERiskAcceptance`, `Remove-PEDecision`, `Invoke-PEStandardCheck`, `Get-PEDecision`; the handler conventions of `Private/GuiRequest.ps1` (`& $done`, `$ownBlueprint`, `$tenant`).
- Produces handlers (same job result and refresh behaviour as the existing ones):
  - `StandardCheck`: offline tenant refused; `Invoke-PEStandardCheck -StandardName <standard> -Tenant <tenant> -ExportScript <seam>`; result "Checked N of M settings (check <id>): ..." from `Coverage`.
  - `Adopt`: a replica whose own blueprint is the master blueprint is refused; reads the own blueprint's latest version; `Copy-PEStandardItem -Standard -To <own> -Item <items> -Reason -ExpectedVersion <latest>`; then `Update-PEStandardCheck`; result "Blueprint v<n> recorded in '<own>' from <standard>. No tenant was changed." Master confirmation: `confirmedMasterWrite` required when the own blueprint is the master blueprint, as for Promote.
  - `AcceptRisk`: per item, `Set-PERiskAcceptance` (once per ticked property, or once for the whole item), then `Update-PEStandardCheck`.
  - `RemoveRisk`: removes the item's `RiskAccepted` decisions (`Get-PEDecision -Kind RiskAccepted -Tenant` filtered by type, key and standard; `Remove-PEDecision` for each), then `Update-PEStandardCheck`.
  - `ImportStandard`: `Import-PEStandardRelease -Standard -Tag`; result with the summary numbers; no tenant.
  - `CheckStandardRelease`: `Get-PEStandardLatestTag`; writes `<DataRoot>\sources\<standard>-latest.json` `{ tag, checkedAt }`.
  - Every handler re-validates what the preview validated (the server re-checks at run time) and throws plain-language errors.

- [ ] **Step 1: Write the failing tests** (create requests through the API as `tests/GuiRequest.Tests.ps1` does with `Send-Request`, then run `Invoke-PEGuiRequest` with seams): Adopt writes the next version of the tenant's own blueprint with provenance and the saved check's row becomes `adopted`; Adopt for a replica without its own blueprint fails the job with the Promote-style text and writes nothing; Adopt into the master blueprint without `confirmedMasterWrite` fails; AcceptRisk writes one decision for the whole item, and two (one per property) for a partial selection, with `ApprovedBy`, `Reason` and the standard; RemoveRisk deletes them and the row is open again; StandardCheck with an `ExportScript` seam saves a Standard check and the job result names the numbers; ImportStandard with the `-GitScript` fake imports (Total 5) and `tag = 'v1.4.0; calc'` fails; CheckStandardRelease writes the latest-tag file; after each decision handler `Get-PECheck -Latest -Kind Standard` is the patched check.
- [ ] **Step 2: Run; expect FAIL.**
- [ ] **Step 3: Implement** the six handlers.
- [ ] **Step 4: Run** the new file, `GuiRequest`, `GuiExport`, `GuiStandardExport`; expect PASS.
- [ ] **Step 5: Commit** `feat: worker handlers for standards requests`.

---

### Task 7: Front end, part 1: the three pages

**Files:**
- Create: `gui/public/assets/standards-model.js`, `gui/public/assets/standards.js`
- Modify: `gui/public/index.html` (two script tags before `app.js`), `gui/public/assets/app.js` (hooks only), `gui/public/assets/app.css` (tokens and the few new classes)
- Test: `gui/tests/Standards.Tests.ps1` (runs node on `standards-model.js`, as `gui/tests/Heat.Tests.ps1` does for `heat.js`)

**Interfaces:**
- Produces in `standards-model.js` (pure, no DOM, exported on `window.PEStandards` and `module.exports`): `statusOf(row) -> 'differs'|'missing'|'lookAgain'|'accepted'`; `filterRows(rows, filter)` for `filter` in `'decide'` (status differs, missing, lookAgain), `'accepted'`, `'all'`; `filterCounts(rows) -> { decide, accepted, all }`; `barSegments(headline) -> [ { key, count, percent } ]` in the order match, differ, accepted, notReadable, notCovered, with percents of `headline.total` that sum to 100 within rounding and a zero segment omitted; `headlineText(headline) -> 'Checked 87 of 133 settings'`; `subText(headline) -> '68 match, 13 differ, 6 are accepted risks'`; `reasonLabel(reason)` (`Placeholder` -> 'Placeholder', `UnknownProperty` -> 'Unknown property', `Unkeyed` -> 'No key'); `valueText(v)` (scalars, arrays joined by ', ', objects as compact JSON).
- Produces in `standards.js` (global functions used by `app.js`): `standardsPage()`, `standardCheckPage(r)`, `notCoveredPage(r)`, and `loadStandards()` / `loadTenantStandard(t, name)` (fetch `/api/standards`, `/api/tenants/<id>/standards/<name>`, `/api/standards/<name>/coverage` with a cache cleared when `loadAll` runs).
- Hooks in `app.js`: `route()` gets `/standards` -> `{ screen: 'standards' }`, `/standards/<name>` -> `{ screen: 'standard', name, filter }` (`?show=decide|accepted|all`, default `decide`), `/standards/<name>/not-covered` -> `{ screen: 'notcovered', name, reason }`; the `screens` map in `render()`; the nav list in `topbar()` gets `['standards', 'Standards', '/standards']`; `crumbs()` for the two sub-pages; the click handler gets `data-act` values `std-check`, `std-import`, `std-release`, `std-filter`; the tenant picker keeps working (the pages show the selected tenant, as `drift` does); `rechecking()`-style helper `standardBusy(kind)` marks a running StandardCheck / ImportStandard job from `D.activity` and disables its button with the text "Checking..." / "Importing...".
- Screens match the approved mock-ups: Standards (cards per standard with the version, source, licence line, adoption line "N of M are in blueprint <name>", the selected tenant's headline, bar with legend, per-workload table; a banner "ASD Blueprint <tag> is available. You have <version>." with an Import button when `latestRelease.tag` differs from the latest imported `sourceVersion`; an "Import a standard" button; a "Check again" or "Check <tenant> against it" button, disabled with the reason for an offline tenant, "Not checked yet" when `checked = false`); Check page (filter pills with counts, the table of rows with status pills, the standard/tenant values, the Adopted chip, the accepted line "by <approvedBy>, <date>" with the reason, the Look again hint, per-row buttons by `allowedActions`; the buttons are inert placeholders until Task 8 except Remove, which is Task 8 too); Not covered page (reason cards with counts, filter pills, table with detail). Use the `--accept` and related tokens from `docs/gui-mockups/standards.html` in light and dark.

- [ ] **Step 1: Write the failing tests** (`gui/tests/Standards.Tests.ps1` calling node, pattern of `Heat.Tests.ps1`): `statusOf`, `filterRows` and `filterCounts` on a table of rows (a lookAgain row is in `decide`, an accepted row only in `accepted`, both in `all`); `barSegments` for the mock-up numbers (87 checked of 133: 68, 13, 6, 4, 42) gives percents 51.1, 9.8, 4.5, 3.0, 31.6, omits a zero segment and never lets match overlap notCovered (Review Focus 1); `headlineText` and `subText` produce the mock-up strings; `valueText` for an array, a boolean, a null and an object.
- [ ] **Step 2: Run; expect FAIL** (file missing).
- [ ] **Step 3: Implement** `standards-model.js`; run the tests to PASS.
- [ ] **Step 4: Implement** `standards.js`, the `app.js` hooks, the CSS and the `index.html` tags. Keep `app.js` edits to the hooks listed.
- [ ] **Step 5: Verify in the browser** after Task 9 has the mock data (or earlier with a hand-made data folder): `./gui/Start-PEGui.ps1 -Mock`, open the printed address, click Standards: the headline, bar, legend and table show; the Check page filters change the rows and counts; Not covered lists reasons; the banner and buttons appear; light and dark both read well; at 400px wide nothing scrolls sideways. Record what was seen.
- [ ] **Step 6: Run** `gui/tests` fully; expect PASS. **Commit** `feat: Standards, check and Not covered pages`.

---

### Task 8: Front end, part 2: Adopt, Accept risk, Remove and the Selection list

**Files:**
- Modify: `gui/public/assets/standards.js`, `gui/public/assets/app.js` (queue and dialog hooks), `gui/public/assets/standards-model.js`, `gui/public/assets/app.css`
- Test: `gui/tests/Standards.Tests.ps1` (node cases for the new pure helpers)

**Interfaces:**
- Produces in `standards-model.js`: `queueIdentity(entry) -> string` (tenant, standard-or-empty and itemId, so a Drift-review entry and a Standards entry never share an identity); `groupStandardEntries(entries) -> [ { action, tenantId, standard, items[] } ]` (entries with `standard` set, grouped by action, tenant and standard, items in the order picked); `riskItems(entry) -> { itemId, properties?, approvedBy, why }`; `riskDialogProblem(d) -> string` ('' when valid: `approvedBy` and `why` non-blank, at least one property ticked when the row has several differing properties).
- Selection list: `REQUEST_ACTION` and `PICKS` gain `Adopt` and `AcceptRisk`; queue entries gain `standard` (and, for AcceptRisk, `approvedBy`, `why`, `properties`); `queuePick`, `chosenAction`, `queueRemove` and `loadQueue` use `queueIdentity` so a standards pick never replaces a Drift-review pick of the same item (Review Focus 5); `ACTION_TITLE`, `ACTION_SUB`, `ACTION_TIP` get texts for both ("Adopt: copy the standard's setting into the blueprint. The tenant is not changed. Revert it afterwards on Drift review." / "Accept risk: leave the tenant as it is and note who approved it and why."); the list page shows the tenant and standard of each entry; `Run` sends one request per group (`action`, `tenantId`, `standard`, `items`, and `reason` for Adopt) after exclusions and AcceptRisk groups and before Revert groups; the preview dialog and the master two-step confirm work for Adopt like for Promote; Export of the DSC configuration ignores these actions.
- Accept risk dialog (`ui.riskDialog`): opened by a row's Accept risk button; shows the setting, standard value, tenant value, tenant, a property checklist when the row has several differing properties (all ticked = whole item), "Approved by" (prefilled from `localStorage` key `pe.approvedBy`, written back on confirm; empty when storage is blocked), "Why", the "not your risk register" note, and "Add to selection list"; Escape and Cancel close it; the confirm button is disabled while `riskDialogProblem` is not empty. Remove on an accepted or lookAgain row acts at once (`RemoveRisk` request), like Unexclude, and shows the usual toast with a link to the job.

- [ ] **Step 1: Write the failing node tests**: `queueIdentity` differs for the same item id with and without `standard` and for two standards; `groupStandardEntries` groups three Adopt entries for one tenant and standard into one group and keeps a second tenant apart; `riskItems` carries `properties` only for a partial selection; `riskDialogProblem` flags blank `approvedBy`, blank `why` (whitespace only) and zero ticked properties and accepts a valid dialog.
- [ ] **Step 2: Run; expect FAIL.**
- [ ] **Step 3: Implement** the helpers, then the app hooks and dialog.
- [ ] **Step 4: Verify in the browser** (mock data): on the Check page pick Adopt on two rows and Accept risk on one (dialog: try to confirm with an empty "Why", see it blocked, fill it, confirm); the Selection list shows the three entries with tenant and standard; adding the same item on Drift review does not replace the Standards entry; Run shows the preview with the blueprint version and, for the master, the two-step confirm; the mock job completes and the page shows the rows Adopted and Accepted; Remove on the accepted row acts at once; reload the page: the list survives (local storage) and a blocked-storage run (open the page in a private window) still works. Record what was seen.
- [ ] **Step 5: Run** `gui/tests` fully. **Commit** `feat: Adopt and Accept risk in the Selection list`.

---

### Task 9: Mock data, docs and the whole-feature check

**Files:**
- Modify: `gui/mock-data/**` (add `standards/index.json`, `standards/asd/coverage.json`, `tenants/master/standards/asd.json`, `tenants/replica/standards/asd.json`, and a `latest` release entry), `gui/PEGui.psm1` (mock job results if not done in Task 5), `gui/README.md`, `docs/overview.md`, `docs/handover.md`
- Create: `tools/PEDemoStandards.ps1` (seeds a real data folder: imports the fixture standard, runs a standard check with a fake export, so the real (non-mock) GUI shows the pages; thin wrapper over the engine commands)

**Interfaces:**
- The mock data uses the example numbers of the mock-ups (87 of 133; 13 differ, 6 accepted; Look again on one row) so `Start-PEGui -Mock` shows the approved screens.

- [ ] **Step 1: Write the mock data and the demo script**; add a `gui/tests` case that every mock standards file parses and that `headline.match + differ + accepted + notReadable + notCovered = total` for each (so the mock cannot drift from the rules).
- [ ] **Step 2: Docs.** `gui/README.md`: the new files, routes and request actions in the existing tables. `docs/overview.md`: a paragraph under GUI. `docs/handover.md`: a section "Standards in the GUI" with what was built, decisions, and the deliberate gaps: no standard check for offline tenants, latest check only (no history), no scheduled standard checks, no Revert from the Standards page, the front end has node tests for its pure helpers only and is otherwise verified in a browser, Adopt needs no `expectedVersion`.
- [ ] **Step 3: Whole-feature browser check with real data**: `tools/PEDemoStandards.ps1` against a temp data folder, `Export-PEGuiData`, start the GUI on it, then: open Standards; Adopt two rows and Accept risk one through the list; run the worker (`tools/Start-PEGuiWorker.ps1`) and confirm the page shows the new blueprint version, the Adopted chips and the Accepted row with its approver; import a second fixture version through the Import button path (fake git is not available in the browser: use `-Path` via the demo script instead) and confirm the accepted row becomes Look again. Record the observations in the handover.
- [ ] **Step 4: Run everything**: `pwsh -NoProfile -File tools/Invoke-PETests.ps1 -Fast` and `Invoke-Pester -Path gui/tests`; expect no failures.
- [ ] **Step 5: Commit and push** `feat: standards in the GUI: mock data, demo script, docs`.

---

## Self-review

- **Spec coverage:** four screens (Tasks 7 and 8); view models and routes (4, 5); requests and the engine commands they call (5, 6, with 2 and 3 as the small engine additions); Look again from the engine (1); patched check after decisions (2, 6); release banner and Import (3, 4, 6, 7); Selection list integration, grouping, run order, queue identity (8); docs and gaps (9). Non-goals respected: no history, no schedule, no offline check, no Revert from the page.
- **Types:** `AcceptanceStale` (Task 1) is read by Task 4; `Get-PECheck -Standard`, `Get-PEStandardDecision`, `Update-PEStandardCheck` (Task 2) are used by Tasks 4 and 6; `Import-PEStandardRelease`, `Get-PEStandardLatestTag`, `-Git` seam (Task 3) by Task 6 (`-GitScript` passes through); row fields and `allowedActions` (Task 4) are read by Tasks 5, 7 and 8; action names `StandardCheck`, `Adopt`, `AcceptRisk`, `RemoveRisk`, `ImportStandard`, `CheckStandardRelease` are the same in Tasks 5, 6 and 8.
- **Proportion:** nine tasks for a smaller project than the engine; the front end is the largest and carries node tests only for pure helpers, with the browser check written down as steps.
