# HTML Drift Report (review and approve inside Azure DevOps) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Compare pipeline publishes one self-contained `drift-report.html` in which a reviewer ticks individual drifted items and downloads an `approved.json` that the approved-apply pipeline accepts.

**Architecture:** A module function turns the engine's comparison findings into a plain data object (items, eligibility, differences, totals). A second function embeds that object as JSON in an HTML template (inline CSS and JavaScript, no libraries) and writes the file. The page holds the selection and builds the approved list in the browser, in the exact format `Read-PEApprovedList` validates. The Compare pipeline script calls the generator after its existing comparison.

**Tech Stack:** PowerShell 7.6+, Pester 5.7.1, plain JavaScript (Node 22 for the logic tests, a browser for the page check), Azure DevOps YAML.

**Spec:** `docs/superpowers/specs/2026-11-03-html-drift-report-design.md` (amends `2026-11-03-approved-drift-apply-design.md`)

## Global Constraints

- **Prerequisite:** Tasks 1, 2 and 3 of `docs/superpowers/plans/2026-11-03-approved-apply-pipeline.md` are built first: `Get-PEExportFingerprint`, `Test-PEExportComplete`, `New-PEApprovedList` / `Save-PEApprovedList` / `Read-PEApprovedList` (format and validation rules are defined there) and `Invoke-PEExportComparison`. This plan consumes them and does not redo them.
- PowerShell 7.6+, LF line endings, Allman braces, 4-space indent in PowerShell; Pester blocks keep the opening brace on the same line.
- Run tests with `pwsh -NoProfile -File tools\Invoke-PETests.ps1 -Path <file> -Fast`; run the whole suite (no `-Fast`) before the last commit of a task that touches existing code.
- Thin wrapper (`CLAUDE.md`): no comparison logic in the report, in JavaScript or in a second script. Use `Invoke-PEExportComparison`, `Compare-PEState` findings and `New-PERectifyPlan` for eligibility.
- The report file has no external requests (no `http`/`https` in `src`/`href`, no `<link>`, no CDN), no `eval`, no `innerHTML` with tenant data: every tenant value is set with `textContent`. It must work from `file://`.
- `approved.json` names items and excluded property names only, never a value. The page produces exactly the format of `New-PEApprovedList` (Format 1).
- Matching resources are counted, never embedded.
- YAML stays thin; free-form parameters go through `env:` and are validated.
- Commit messages end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Review Focus

- A tenant value or key such as `</script><img src=x onerror=alert(1)>` or `"><b>` must render as text and must not break the embedded JSON (Tasks 2, 3).
- 496 drifted items across 40 types, and a stress page of 20,000 rows, stay responsive: sections collapsed, rows rendered on expand (Task 4).
- A downloaded list that Apply's `Read-PEApprovedList` rejects (an item key with a newline, an empty selection, no "Approved by") must be impossible to download or must be refused in the page (Tasks 3, 4).
- An item with no checkbox (Ambiguous, PossibleRename, Unkeyed, Excluded, NotChecked, NotAvailable) can never appear in the downloaded list (Tasks 1, 3).
- Removals are not selectable, and "select all in type" does not select them, until "Include removals" is on (Task 3).

---

### Task 1: Report data from the comparison

**Files:**
- Create: `src/PolicyEngine/Public/Get-PEDriftReportData.ps1`
- Test: `tests/DriftReportData.Tests.ps1`

**Interfaces:**
- Consumes: the object returned by `Invoke-PEExportComparison` (`Findings`, `Check`, `Blueprint`, `SourceState`; `Check` is the Dev check state the findings came from), `New-PERectifyPlan`, `Get-PEPinnedVersion`.
- Produces: `Get-PEDriftReportData -Comparison <object> -Tenant <string> -Source <hashtable> -Target <hashtable> [-GeneratedUtc <datetime>] [-MaxValueLength <int> = 4000]` where `Source` / `Target` are `@{ Run; ExportedAt; Fingerprint }` exactly as `New-PEApprovedList` takes them. Returns `[pscustomobject]@{ Meta; Totals; Items }`:
  - `Meta`: `Tenant`, `Source`, `Target`, `ModuleVersion`, `GeneratedUtc` (ISO 8601 UTC), `ReportId` (SHA-256 hex of `Source.Fingerprint + Target.Fingerprint`, used as the storage key by the page).
  - `Totals`: `Total`, `Matching`, `Create`, `Update`, `Remove`, `CannotApprove`. Invariant: `Matching + Create + Update + CannotApprove` equals the number of PreProd (source) records; `Remove` counts Dev-only objects and is outside that sum.
  - `Items`: one per drifted finding, `@{ Id = '<Action>|<ResourceType>|<Key>'; Action = 'Create'|'Update'|'Remove'|$null; Kind; ResourceType; Key; Workload; Approvable [bool]; Reason [string]; Differences = @(@{ Property; Dev; PreProd }) }`. Kind to Action: Missing = Create, Changed = Update, TargetOnly = Remove; every other kind (Ambiguous, PossibleRename, Unkeyed, Excluded, NotChecked, NotAvailable, Unreadable) has `Action = $null`, `Approvable = $false`, `Reason` = the finding's `Hint` or the Kind name. `Dev` / `PreProd` are display strings (compact JSON for objects and arrays, `$null` shown as `(none)`), cut at `MaxValueLength` with a trailing `…`. Excluded and accepted differences of the finding are not listed. Sorted by ResourceType, Key.
- Eligibility: an item with an Action is `Approvable` only if `New-PERectifyPlan` accepts that single finding (call it once per finding inside try/catch, with the same `-Source`, `-Blueprint` and in-memory `Remove` decision as `New-PEOfflineConfig` uses for a TargetOnly finding). A refusal makes `Approvable = $false` and `Reason` = the engine's message, trimmed to one line. Do not duplicate the engine's rules.

- [ ] **Step 1: Write the failing tests** using the fixtures of the approved-apply plan (`tests/fixtures/upload/entra.ps1` as PreProd, `entra-drift.ps1` as Dev, each in a temp folder with an empty `export.log`, compared with `Invoke-PEExportComparison`): `'lists Create Finance, Update Sales and Remove Marketing'` (exact Ids `Create|AADGroup|Finance`, `Update|AADGroup|Sales`, `Remove|AADGroup|Marketing`), `'shows the differing property with both values'` (Sales, `MailNickname`, Dev and PreProd strings), `'keeps the totals invariant'` (`Matching + Create + Update + CannotApprove` equals the PreProd record count), `'marks an item the engine refuses as not approvable with its reason'` (mock `New-PERectifyPlan` to throw `'refused for test'` for Sales: `Approvable` false, `Reason` `'refused for test'`, Finance still approvable), `'gives a non-actionable kind no action'` (build a duplicate-key target so one finding is Ambiguous: `Action` null, `Approvable` false, `Reason` contains `Key matches`), `'cuts a long value'` (a 10,000-character value with `-MaxValueLength 50` ends with `…` and has length 51 or less), `'does not embed matching resources'` (`Items.Count` is 3 for the fixtures), and `'ReportId is stable for the same fingerprints and changes with either one'`.
- [ ] **Step 2: Run** `pwsh -NoProfile -File tools\Invoke-PETests.ps1 -Path tests\DriftReportData.Tests.ps1 -Fast`. Expected: FAIL (function not defined).
- [ ] **Step 3: Implement** `Get-PEDriftReportData` in the new file (dot-sourced like the other Public files). Count PreProd records from `SourceState.Records`; take the property differences from each finding's `Differences` (`Blueprint` side = PreProd, `Target` side = Dev).
- [ ] **Step 4: Run** the test file, then the whole suite. Expected: PASS.
- [ ] **Step 5: Commit** `feat: report data from the export comparison`.

### Task 2: The HTML file (generator, template, embedded data)

**Files:**
- Create: `src/PolicyEngine/Public/New-PEDriftReportHtml.ps1`, `src/PolicyEngine/Data/DriftReport.template.html` (page skeleton, CSS and `<script>` placeholders; the JavaScript lives in `DriftReport.js` beside it and is inlined by the generator), `src/PolicyEngine/Data/DriftReport.js` (empty module with the `buildApprovedList` stub for now)
- Test: `tests/DriftReportHtml.Tests.ps1`

**Interfaces:**
- Consumes: the data object of Task 1.
- Produces: `New-PEDriftReportHtml -Data <object> -Path <string> [-Title <string>]` writes one UTF-8 (no BOM, LF) file and returns its path; refuses to overwrite. The data is embedded as `<script type="application/json" id="report-data">…</script>` with every `<` written as `<` and `&` as `&`, ` ` and ` ` escaped, so no tenant value can close the script or start a comment. The CSS and `DriftReport.js` are inlined.

- [ ] **Step 1: Write the failing tests**: `'writes a single file with no external references'` (no match for `(src|href)=["']https?:`, no `<link`, no `@import`, no `url(http`), `'embeds the data and nothing breaks the script block'` (the item key `</script><img src=x onerror=alert(1)>` leaves exactly one `</script>` per script block in the output, and the JSON block parsed back with `ConvertFrom-Json` after un-escaping equals the original key), `'does not overwrite'`, `'refuses a Data object without Items'`.
- [ ] **Step 2: Run** the test file. Expected: FAIL.
- [ ] **Step 3: Implement** the generator and the minimal template (title, a `<div id="app">`, the data block, the inlined script).
- [ ] **Step 4: Run** the test file. Expected: PASS.
- [ ] **Step 5: Commit** `feat: self-contained HTML report generator`.

### Task 3: Page logic (selection and approved.json), tested in Node

**Files:**
- Modify: `src/PolicyEngine/Data/DriftReport.js`
- Test: `tests/DriftReportJs.Tests.ps1` (runs `node` against the script; skipped with a clear reason when `node` is not on PATH), `tests/driftreport/logic.test.mjs` (the cases below, plain `node:assert`)

**Interfaces:**
- Produces, as pure functions on a `window.PEReport` object with no DOM access: `buildApprovedList(data, selection, approvedBy, includeRemovals, now)` returns the list object with exactly the `New-PEApprovedList` shape (`Format = 1`, `CreatedUtc`, `ApprovedBy`, `Tenant`, `ModuleVersion`, `Source`, `Target`, `Items` of `{ Action, ResourceType, Key, ExcludedProperties }`, `Counts` of `{ ResourceType, Action, Count }` recomputed) and throws a message beginning `Cannot download:` for: no items selected, empty `approvedBy` or one over 100 characters or with a control character, a selected item that is not `Approvable`, a Remove selected while `includeRemovals` is false, a key that is empty, over 500 characters, or has a newline or control character, a property name outside `[A-Za-z0-9_.]+`. `selection` is `{ [id]: { excluded: [propertyNames] } }`. `selectAll(data, filter, state)` returns the ids of all approvable items that match `filter` (`{ type, kind, text }`) and, when removals are off, are not Remove. `summarise(data, selection)` returns `{ lines, total }` with lines such as `Create 10 AADGroup`, ordered by type then Create, Update, Remove, equal to Apply's G4 lines.

- [ ] **Step 1: Write the failing tests** in `logic.test.mjs` with a small fixture data object: `'builds the exact approved list shape'` (deepEqual on the keys of the list and an item), `'counts per type and action'`, `'refuses an empty selection'`, `'refuses a missing or overlong or control-character approver'`, `'refuses a non-approvable item even if it is in the selection'`, `'refuses a Remove while removals are off'`, `'refuses a newline in a key'`, `'select all skips non-approvable and, with removals off, Remove items'`, `'select all honours type, kind and text filters'`, `'summary lines match the format Create 10 AADGroup'`. In the Pester file add `'the list the page builds is accepted by Read-PEApprovedList'`: have node write the built list (fixture with fingerprints, run ids and ExportedAt of valid shape) to a temp file and assert `Read-PEApprovedList -Path` returns without throwing, plus a counterpart that a list with a hand-added `Value` property on an item is rejected (proves the strictness is shared).
- [ ] **Step 2: Run** `pwsh -NoProfile -File tools\Invoke-PETests.ps1 -Path tests\DriftReportJs.Tests.ps1 -Fast`. Expected: FAIL.
- [ ] **Step 3: Implement** the three functions in `DriftReport.js` (plain JavaScript, strict mode, no libraries).
- [ ] **Step 4: Run** the test file. Expected: PASS.
- [ ] **Step 5: Commit** `feat: report selection logic and approved list builder`.

### Task 4: The page (UI)

**Files:**
- Modify: `src/PolicyEngine/Data/DriftReport.template.html`, `src/PolicyEngine/Data/DriftReport.js`
- Test: `tests/DriftReportPage.Tests.ps1` (static checks), plus the manual browser check in Step 4

**Interfaces:**
- Consumes: `PEReport` functions (Task 3) and the embedded data block.
- Behaviour (from the spec): summary cards (Total, Matching, Create, Update, Remove, Cannot be approved) in the style of the owner's report; one collapsed section per resource type with a count and a section checkbox that calls `selectAll` for that type; rows render only when a section is expanded (and in pages of 200 rows with a "Show more" button); each Update row expands to a Property / Dev / PreProd table with an "exclude" checkbox per property; not-approvable rows have no checkbox and show the reason; filters (kind buttons Create / Update / Remove, type dropdown, key text search) with "Select all shown" and "Clear"; an "Include removals" switch (off by default; turning it off clears selected Removes); an "Approved by" text field; an always-visible selection bar showing `summarise` lines and a **Download approved.json** button, disabled with a visible reason while `buildApprovedList` would throw. The download uses a `Blob` and an `<a download="approved.json">`. Selection (and the approver name, and the switch) persist in `localStorage` under `ReportId`, inside try/catch so the page works without storage; a stale or malformed stored value is ignored. All tenant text is set with `textContent`. Keyboard: checkboxes and expanders are real buttons/inputs; works at phone width and in dark mode (`prefers-color-scheme`).

- [ ] **Step 1: Write the static tests**: `'the page source never assigns innerHTML or uses eval or document.write'` (scan `DriftReport.js` and the template), `'every element that shows tenant data is created with textContent'` (a scan that fails on `innerHTML`, `insertAdjacentHTML`, `outerHTML`), and `'the template contains the data placeholder exactly once'`.
- [ ] **Step 2: Run** `pwsh -NoProfile -File tools\Invoke-PETests.ps1 -Path tests\DriftReportPage.Tests.ps1 -Fast`. Expected: FAIL.
- [ ] **Step 3: Implement** the UI in the template and `DriftReport.js`.
- [ ] **Step 4: Check in a browser** (Playwright MCP or any browser) with two generated reports: the fixture report, and a stress report made by a throwaway script with 20,000 drifted items across 40 types (not committed). Expected: the page opens in under two seconds; collapsed sections show counts; expanding a type renders its first 200 rows; ticking a type, filtering to Create, "Select all shown" and Download produce a file; `Read-PEApprovedList` accepts it; a key `</script><img src=x onerror=alert(1)>` in the fixture shows as text and no dialog appears; the Download button is disabled with a reason until "Approved by" is filled and an item is chosen; reloading the page keeps the selection.
- [ ] **Step 5: Run** the static tests and the whole suite. Expected: PASS.
- [ ] **Step 6: Commit** `feat: the drift report page`.

### Task 5: Wire it into the Compare pipeline

**Files:**
- Create: `tools/New-PEDriftReport.ps1`
- Modify: `pipelines/scripts/Invoke-PipelineCompare.ps1`, `pipelines/Compare-PreProd-to-Dev.yaml.template`, `pipelines/README.md`
- Test: `tests/DriftReportTool.Tests.ps1`

**Interfaces:**
- Produces: `tools\New-PEDriftReport.ps1 -SourceExportPath <string> -TargetExportPath <string> -TargetTenantDomain <string> -OutputPath <string> -SourceRun <digits> -TargetRun <digits> [-CompleteWorkload <string[]>]` thin tool: calls `Invoke-PEExportComparison`, `Get-PEExportFingerprint`, `Get-PEDriftReportData`, `New-PEDriftReportHtml`, writes `<OutputPath>\drift-report.html` and prints `Drift report: N items, M approvable`. `ExportedAt` of each side comes from the export's state Meta; `Tenant` is `dev`. `SourceRun` / `TargetRun` must match `\A\d{1,12}\z`.
- `Invoke-PipelineCompare.ps1` gets optional `-PreProdRunId` and `-DevRunId` (digits, default empty). When both are set it calls the tool after its existing comparison; when not, it skips the report and prints why. The template passes `$(resources.pipeline.preprodExport.runID)` and `$(resources.pipeline.devExport.runID)` through `env:` (verify the variable names in Microsoft's documentation for pipeline resources before writing them), and the existing publish step also publishes `drift-report.html` (in the same artifact as the other outputs, or as its own artifact `DriftReport`; the README says which).

- [ ] **Step 1: Write the failing tests**: `'writes drift-report.html and prints the counts'` (fixtures as in Task 1), `'refuses a non-numeric run id'`, `'the report data matches the comparison the existing tool makes'` (the item count equals `OpenFindings`-based expectations for the fixtures: 3 actionable items).
- [ ] **Step 2: Run** `pwsh -NoProfile -File tools\Invoke-PETests.ps1 -Path tests\DriftReportTool.Tests.ps1 -Fast`. Expected: FAIL.
- [ ] **Step 3: Implement** the tool, the script change and the template step; add a README section "Drift report" (open the artifact, tick items, download, commit to `approvals/`, run Apply).
- [ ] **Step 4: Run** the new test file, then the whole suite. Parse-check both scripts. Regenerate the YAML with `pipelines\scripts\New-PipelineYaml.ps1` against the example settings in a temp copy and confirm it fills every token. Expected: PASS.
- [ ] **Step 5: Commit** `feat: Compare pipeline publishes the HTML drift report`.

### Task 6: Verify in a real pipeline and document

**Files:**
- Modify: `docs/handover.md` (a section "HTML drift report"), the amendment spec's Status line

- [ ] **Step 1: Run the Compare pipeline** in Azure DevOps with real exports. Expected: the artifact contains `drift-report.html`; the log prints the item count.
- [ ] **Step 2: Open it** from the downloaded artifact (`file://`). Expected: the counts match the pipeline's summary; sections expand; a selection of one group downloads a list.
- [ ] **Step 3: Feed that list to the approved-apply pipeline** (`Test` mode) once it exists. Expected: the list is accepted and its counts are the ones the report showed.
- [ ] **Step 4: Write** the handover section and set the Status to "report implemented". Run the whole suite one last time.
- [ ] **Step 5: Commit** `docs: HTML drift report handover`.
