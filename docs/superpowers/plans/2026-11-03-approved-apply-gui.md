# Approved-drift Apply (GUI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In the GUI's Drift review, a reviewer can mark items "Approve" in the Selection list and save an approved list file (`approvals/*.json`) that the Apply pipeline from the first plan consumes.

**Architecture:** A new selection action `Approve` (alongside Revert, Promote, Exclude) that is allowed for the drift of a tenant against the master blueprint, offline tenants included. The server builds the list with `New-PEApprovedList` and returns it as a download, after checking that the master blueprint really is the export named in the list. The browser asks for the approver and the two pipeline run ids, then downloads the file.

**Tech Stack:** PowerShell 7.6+, Pode, Pester 5.7.1, plain browser JavaScript (no build step).

**Spec:** `docs/superpowers/specs/2026-11-03-approved-drift-apply-design.md`. **Depends on:** `docs/superpowers/plans/2026-11-03-approved-apply-pipeline.md`, Tasks 1 and 2 (`Get-PEExportFingerprint`, `Meta.ExportFingerprint`, `New-PEApprovedList`, `Save-PEApprovedList`).

## Global Constraints

- PowerShell 7.6+, LF line endings, no C#, Allman braces with 4-space indent; Pester blocks keep the opening brace on the same line. No build step and no third-party code in `gui/public`.
- The server re-checks everything the page sends (`gui/README.md`: "the server re-checks every request"). The page never builds the list itself.
- Rules for which actions a finding allows live once, in `gui/PEGui.psm1` (`Get-PEGuiAllowedAction`).
- The GUI tests read page source with regular expressions (`gui/tests/Assets.Tests.ps1`); keep new page code matching the existing style so those tests keep passing, and add tests for the new code.
- An offline tenant keeps having no Revert; `Approve` must work for it.
- The approved list holds no property values (see the first plan).
- Run `Invoke-Pester -Path gui/tests -Output Detailed` (Pester 5.7.1) and the engine suite `pwsh -NoProfile -File tools\Invoke-PETests.ps1` before each commit.
- Commit messages end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Review Focus

- A request to save a list for items that are not approvable now (stale finding, Ambiguous, PossibleRename, Excluded, NotChecked, no key) is refused with those items named (Task 2).
- A master blueprint not made from an export (no `ExportFingerprint`) is refused, so a list never names an export it cannot identify; a wrong run id typed by the reviewer is caught later by the pipeline's fingerprint check (Task 2).
- Approving an item and then choosing another action for it replaces it (one action per item), and the saved list holds only the Approve items (Task 3).
- The approver name and run ids typed in the page are validated by the server (digits only for run ids), and a bad value never produces a file (Tasks 2, 3).
- The new action does not change what Run or Export do for Revert, Promote and Exclude items (Task 3).

---

### Task 1: Read what the code does today (no code changes)

**Files:** Read `gui/PEGui.psm1` (`Get-PEGuiAllowedAction`, `Get-PEGuiFinding`, `Get-PEGuiLayerFinding`, `Get-PEGuiRequestPreview`, `Get-PEGuiConfigFile`, `Invoke-PEGuiApi`), `gui/server.ps1`, `gui/public/assets/app.js` (`PICKS`, `REQUEST_ACTION`, `loadQueue`, `queueExport`, `exportScript`), `docs/handover.md` ("Offline snapshots", "Overview and drill-down").

- [ ] **Step 1: Answer these in a short note appended to this plan** (under a heading "Findings of Task 1"), with file and line for each: (a) which function returns the tenant's findings against the **master** layer, and what fields a finding carries (kind, state, key, hint, resource type); (b) how `allowedActions` is computed and where an offline tenant loses Revert; (c) how a download is returned by `Invoke-PEGuiApi` (the `Text`, `ContentType`, `FileName` reply used by `Get-PEGuiConfigFile`) and how `server.ps1` writes it; (d) where the tenant's latest check, its staged export folder (`exports\<CheckId>`) and the master blueprint's Meta can be read in the GUI's data root; (e) how the page asks for who approved and why (the Accept risk dialog) so the same dialog style can be reused.
- [ ] **Step 2: Fix the names** used in Tasks 2 and 3 below to what Step 1 found (the signatures in those tasks are the intent; adjust only function names and fields, not behaviour), and commit the note: `docs: findings for the approve action`.

### Task 2: Server: the `Approve` action and the approved-list download

**Files:**
- Modify: `gui/PEGui.psm1` (allowed actions, new function, route in `Invoke-PEGuiApi`), `gui/server.ps1` (write the download if the existing route does not already cover it)
- Test: `gui/tests/PEGui.Tests.ps1` (new `Describe 'Approved list'`)

**Interfaces:**
- Consumes: `New-PEApprovedList`, `Save-PEApprovedList`-style JSON writing (Task 2 of the first plan), `Get-PEExportFingerprint`, `Meta.ExportFingerprint`.
- Produces: `Get-PEGuiAllowedAction` returns `'Approve'` for a finding of the tenant against the master layer whose State is Open, Kind is Missing, Changed or TargetOnly, with a key and no Hint, for every tenant including offline ones.
- Produces: `Get-PEGuiApprovedList -DataRoot <string> -TenantId <string> -Item <object[]> -ApprovedBy <string> -SourceRun <string> -TargetRun <string>` where each item is `@{ ResourceType; Key; Action }`; `Action` is the finding's list action (`Create` for Missing, `Update` for Changed, `Remove` for TargetOnly). It returns `@{ StatusCode = 200; Text = <list JSON>; ContentType = 'application/json'; FileName = '<yyyyMMdd-HHmmss>-<tenant>.json' }`, or throws a message naming every refused item and the reason. It refuses: an item that is not an Open, approvable finding now; a master blueprint whose `Meta.ExportFingerprint` is missing; a tenant check whose staged export cannot be fingerprinted. `Source` of the list is the master blueprint's Meta (`ExportedAt`, `ExportFingerprint`) with `Run = $SourceRun`; `Target` is the tenant's latest Full check Meta `ExportedAt` with the fingerprint of its staged export and `Run = $TargetRun`. `ExcludedProperties` of each item are the tenant's `PropertyExcluded` decisions for that item.
- Produces: route `POST /api/tenants/{id}/approved-list` with body `{ items: [{ resourceType, key, action }], approvedBy, sourceRun, targetRun }`, answered with the download; a 400 with `{ error }` on any refusal.

- [ ] **Step 1: Write the failing tests** against `Invoke-PEGuiApi` using the existing offline-tenant test setup in `gui/tests/PEGui.Tests.ps1` (the `GenerateConfig` tests show how to build a replica tenant with a check): `'offers Approve for an open Missing, Changed and TargetOnly finding of an offline tenant'` and `'does not offer Approve for an Ambiguous, PossibleRename or hinted finding'`; `'returns a list as a download'` (status 200, `ContentType` `application/json`, `FileName` matching `\A\d{8}-\d{6}-replica\.json\z`, the text round-trips through `Read-PEApprovedList` after saving to a temp file, `Items.Count` equals what was sent, no item has a property named `Value`); `'refuses a stale item and names it'`; `'refuses when the master blueprint has no export fingerprint'`; `'refuses a run id that is not digits'`; `'refuses an approver with a newline'`; `'puts the tenant''s excluded properties into the item'`.
- [ ] **Step 2: Run** `Invoke-Pester -Path gui/tests/PEGui.Tests.ps1 -Output Detailed`. Expected: new tests FAIL.
- [ ] **Step 3: Implement** the allowed action, `Get-PEGuiApprovedList` and the route. Validate `approvedBy`, `sourceRun`, `targetRun` by building the list with `New-PEApprovedList` (its validation is the single source of the rules).
- [ ] **Step 4: Run** `Invoke-Pester -Path gui/tests -Output Detailed` and the engine suite. Expected: PASS.
- [ ] **Step 5: Commit** `feat: approve action and approved-list download on the server`.

### Task 3: Page: the Approve pick and "Save approved list"

**Files:**
- Modify: `gui/public/assets/app.js`, `gui/public/assets/app.css` (only if the new button needs a rule), `gui/README.md`
- Test: `gui/tests/Assets.Tests.ps1`

**Interfaces:**
- Consumes: the route from Task 2.
- Produces in the page: `Approve` added to `PICKS` as `['Approve', 'Approve']` and to `REQUEST_ACTION` and `ACTION_TIP` (tip: "Approve: this item will be created, updated or removed in the tenant by the Apply pipeline. Saved to an approved list; nothing is changed now."); the Selection list's `Run` and the existing `Export DSC configuration` ignore Approve items (Run must tell the user that Approve items are saved, not run); a button `data-act="save-approved"` labelled "Save approved list (.json)" next to the Export button, enabled when at least one Approve item exists; `saveApproved()` asks for the approver and the two pipeline run ids with the same dialog style as Accept risk, posts to `/api/tenants/{id}/approved-list`, and downloads the returned file the way `queueExport` downloads its files, showing the server's error text in the toast on a 400.

- [ ] **Step 1: Write the failing tests** in the style of the existing page tests: `'offers Approve on a drifted item and adds it to the selection list'`, `'has a Save approved list button that posts to the approved-list route and downloads the file'`, `'keeps Approve items out of Run and out of the DSC configuration export'`, and `'a second action on an approved item replaces it'` (behavioural, with node if available like `Standards.Tests.ps1`).
- [ ] **Step 2: Run** `Invoke-Pester -Path gui/tests/Assets.Tests.ps1 -Output Detailed`. Expected: new tests FAIL.
- [ ] **Step 3: Implement** the page changes; send only `resourceType`, `key` and `action` per item, never record data.
- [ ] **Step 4: Run** `Invoke-Pester -Path gui/tests -Output Detailed`. Expected: PASS. Start the GUI with `./gui/Start-PEGui.ps1 -Mock`, choose Approve on two drifted items, save the list and open the file: it has two items and no values.
- [ ] **Step 5: Document** the new action and the saved file in `gui/README.md`.
- [ ] **Step 6: Commit** `feat: Approve pick and Save approved list in the GUI`.

### Task 4: End to end and handover

**Files:** Modify `docs/handover.md` and the spec Status line.

- [ ] **Step 1: With real exports** (a PreProd and a Dev export from the pipelines): create the PreProd blueprint from the export (`tools\New-PEBlueprint.ps1`), register Dev as an offline tenant, upload the Dev export, approve a few items in Drift review and save the list. Expected: the list's `Source` / `Target` fingerprints equal `Get-PEExportFingerprint` of the two export folders.
- [ ] **Step 2: Commit the list** under `approvals/` in the ADO repo and run `Apply-Approved-Dev` in `Test` mode (first plan, Task 8). Expected: the counts shown match the items approved.
- [ ] **Step 3: Update** `docs/handover.md` and set the spec Status to "implemented". Run both test suites.
- [ ] **Step 4: Commit** `docs: approved apply end to end`.
