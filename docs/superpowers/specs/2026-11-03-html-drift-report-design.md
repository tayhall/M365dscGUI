# Drift report in HTML: review and approve inside Azure DevOps

Status: draft for approval. Date: 2026-11-03. Amends `2026-11-03-approved-drift-apply-design.md` (read that first).

## Intent and why

The approved-drift apply design has the item-by-item review in the local Pode GUI. The owner needs the whole workflow inside Azure DevOps,
with no GUI and no Pode. The GUI stays for people who like it. This amendment adds a second way to produce the **same approved list**: a
self-contained HTML report built by the Compare pipeline, in which a reviewer ticks individual items and downloads `approved.json`.

Only the review step changes. The approved list format, the guards G1 to G9, the per-type MOFs and the Apply pipeline are as in the
original design.

## The flow

1. Export Dev and PreProd (existing pipelines).
2. **Compare pipeline** builds `drift-report.html` from the two export runs and publishes it as an artifact, with the same exports'
   fingerprints (original design: G7) embedded.
3. The reviewer opens the file locally (no server, no network), ticks items, and clicks **Download approved.json**.
4. The reviewer commits `approved.json` to `approvals/` in the project folder (pull request recommended; branch policy is G9).
5. The Apply pipeline from the original design builds and applies one MOF per type for only those items.

## The report

One `.html` file with inline CSS and JavaScript, no external requests, works from `file://`. Built by a PowerShell script from the engine's
findings, so what is shown is what Apply will build from.

- **Header cards:** totals as in the owner's existing report (`D:\Projects\driftrep\Compare-TenantExports.ps1`): total, matching, Create,
  Update, Remove, cannot be approved.
- **One section per resource type**, collapsed by default, each with a count and a section checkbox that selects all approvable rows of
  that type (honouring the filters below).
- **Rows:** Missing in Dev = **Create**; Changed = **Update**; Only in Dev = **Remove**. Each row has a checkbox, the key, and for an Update an
  expandable list of the differing properties (name, Dev value, PreProd value). Each property has an "exclude" checkbox: ticked properties go
  into that item's `ExcludedProperties` (Dev's value is kept).
- **Cannot be approved** rows (Ambiguous, PossibleRename, Unkeyed, Excluded, NotChecked, NotAvailable) are listed with the engine's reason and
  have no checkbox.
- **Filters:** by kind (Create / Update / Remove), type, and a text search on the key. "Select all shown" and "Clear".
- **Selection bar** (always visible): counts per type and action, exactly as Apply will show them (G4), and the **Download approved.json**
  button. Remove items are only selectable when a "Include removals" switch is on (mirrors G6).
- **Values are shown only in the report**, never written to `approved.json` (original design: names only). The report itself is a build
  artifact and may contain tenant data; it is not committed.
- **Approved by:** a text field in the report (required to download); it goes into the list. It is a label, not authentication; the
  commit is the record.
- Selection survives a page reload (browser local storage, per report id). Keys, not row numbers, identify items.

## What the report must not do

- Not run any DSC or Graph call. Not read anything but the findings it was built from.
- Not write values into the approved list. Not offer an item the engine would refuse (`New-PERectifyPlan` is the authority).
- Not become a second comparison engine: no comparison logic in JavaScript or in a second PowerShell script. The comparison is the engine's
  (`Invoke-PEExportComparison`, `Compare-PEState`).

## Goals, non-goals, anti-goals

Goals: item-level selection in a browser with no server; the same `approved.json` as the GUI; an ADO-only workflow; large reports stay usable
(the owner's Entra export has 21,786 resources and 496 drifted items, so the page must stay responsive with thousands of rows).

Non-goals: authentication in the report; uploading the list from the browser to ADO (a commit is the handoff); replacing the GUI;
a second apply path.

Anti-goal: a report whose list Apply then refuses for reasons the report could have shown.

## Constraints

- Thin wrapper (`CLAUDE.md`): reuse `Invoke-PEExportComparison`, `New-PEApprovedList`/`Read-PEApprovedList`, `New-PERectifyPlan`. The new
  code is the report generator and its inline page only.
- The approved list's `Source`/`Target` (run id, ExportedAt, fingerprint) come from the Compare run; the report embeds them so the download
  is complete. The Compare pipeline passes the run ids; the fingerprints come from the export files.
- Plain JavaScript, no libraries (the file must be self-contained and work offline). No `eval`, text set with `textContent` (tenant values
  are untrusted input; an item name such as `<img onerror=...>` must render as text).
- The existing Compare pipeline keeps producing its MOF drift outputs; the report is added to it as one more artifact.

## Calls I made (change any of them)

- Report built from the engine's findings, not from the owner's older script.
- Sections collapsed by default for performance; rows rendered on expand.
- Remove needs an explicit switch, as G6.
- Selection saved in local storage so a reload does not lose work.
- Round-trip check: the download is validated by `Read-PEApprovedList` in a test (same rules as Apply reads), so the report cannot produce a
  list Apply rejects on format.

## Answers to the builder check

- **Order of work.** The report depends on the first apply plan's Tasks 1 to 3 (export fingerprint, approved list format, `Invoke-PEExportComparison`).
  They are built first. The report plan does not redo them.
- **Run ids and fingerprints.** The Compare pipeline already downloads two named export runs; Apply pinning (G7) records their ids. The report
  gets the run ids as parameters and the fingerprints from the export files via Task 1.
- **Comparison basis.** The report compares the Dev export with the PreProd export directly, as the pipeline does. It does not use the master
  blueprint, so the GUI's "blueprint must match" rule does not apply.
- **Cannot be approved.** The generator runs the engine's own eligibility check (`New-PERectifyPlan` rules) on the drifted items only
  (hundreds, not the 21,000 matching resources) and shows refusals as "cannot be approved" with the engine's reason.
- **Update details.** `Compare-PEState` findings already carry per-property `Differences` with both values; no new comparison code.
- **Size.** Matching resources are counted, never embedded. Only drifted items and their differences go into the page.
- **Agent.** The Compare pipeline already installs and runs the engine, so the generator runs there.

## Left to the builder

- Exact HTML/CSS design; keep the owner's card look where it helps.
- How the generated JavaScript receives its data (embedded JSON block is expected).
- How the Compare pipeline passes run ids and publishes the artifact.
- The in-page row virtualisation or pagination approach.
