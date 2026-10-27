# Tenant-vs-blueprint GUI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show each tenant against the blueprint layers it follows (master blueprint, then its own tenant blueprint), let people move items between tenants and blueprints on purpose, rename a tenant on the Tenants page, and fix the long-text layout.

**Architecture:** A tenant record gains an ordered `Blueprints` list. Drift against any layer is `Compare-PEState` of the tenant's latest check state against that blueprint, so no new tenant read is needed. Blueprint-to-blueprint moves reuse `Get-PEBlueprintChange` / `Approve-PEBlueprintChange` (they take any State, so a blueprint's state can be the "master state"). A tenant is only written from its own blueprint, through the existing `Accept` path. The GUI is the existing vanilla JS/CSS app; backend actions go through `Invoke-PEGuiRequestAction`.

**Tech Stack:** PowerShell 7 module `src/PolicyEngine` (Pester tests in `tests/`), GUI worker `gui/PEGui.psm1` (tests in `gui/tests/`), vanilla JS/CSS in `gui/public/assets/`.

**Spec:** `docs/superpowers/specs/2026-10-24-tenant-vs-blueprint-gui-design.md`

## Global Constraints

- Thin wrapper over Microsoft365DSC (`CLAUDE.md`): no copied DSC logic, resource lists or per-resource knowledge. Anything DSC cannot do: stop and discuss; record deliberate gaps in `docs/handover.md`.
- A tenant is only ever written from its own blueprint. No action applies the master blueprint to a tenant.
- Two layers have screens and tests; the data is an ordered list so a third layer needs no redesign. UI wording says "layer".
- Blueprints are immutable numbered versions; every move writes a new version with a reason via the existing crash-safe writer (`Approve-PEBlueprintChange`).
- Item (resource type plus key) is the unit of every move. Promote takes the tenant's side: tenant-only item added, changed item takes the tenant's values, item in the blueprint but missing from the tenant removed from the blueprint.
- Every blueprint move shows a preview (added/changed/removed) and is refused if the target blueprint has a newer version than the one the review used.
- Rename lives on the Tenants page only (max 80 characters, same rule as `gui/PEGui.psm1:432`); the slug is immutable; the blueprint name is never renamed.
- Overview wording says "drifted"; no "experiments" or "backfill" labels.
- Labels: "Update tenant blueprint" (pull down), "Promote to tenant blueprint", "Promote to master blueprint".
- Commit messages end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Push main after each finished task (project rule); live writes to the test tenant are covered by the project memory authorisations, nothing else writes to a tenant.
- Run tests with `Invoke-Pester -Path tests, gui/tests -Output Detailed` (single file: `-Path tests/Tenants.Tests.ps1`).

## Review Focus

- A rename to empty, whitespace-only or over-80-character text is refused and the stored name is unchanged (Task 3).
- A tenant record with no `Blueprints` field (every existing install) behaves as `[<master blueprint>]`, and its Overview shows both panels on the same blueprint without error (Tasks 2, 5, 8).
- A tenant that has never been checked shows "not checked", never "0 drifted" (Tasks 4, 8).
- A blueprint move whose target gained a newer version after the preview is refused with a message and writes no version (Task 6).
- Keys, values and domains of 200+ characters with no spaces never make the page scroll sideways (Task 1, 9).

---

### Task 1: Long-text helpers and the shrink fix

**Files:**
- Modify: `gui/public/assets/app.css` (new utilities; fix duplicate `.tabs` at about lines 27 and 143; `.cards2` minimum)
- Modify: `gui/public/assets/app.js` (`fmt()` at line 47; `.lnk.strong` key cells at about lines 338, 438, 511; id/domain/path cells at about lines 306, 534, 648, 719)
- Test: `gui/tests/Guard.Tests.ps1` (read it first; it guards the static assets)

**Interfaces:**
- Produces: CSS classes `.trunc` (one line, ellipsis), `.wrap` (`overflow-wrap:anywhere`), `.clamp2` (two-line clamp), rule `.gr > * { min-width: 0 }`; JS `tt(text) -> string` (HTML for a `.trunc` span with `title` set to the full text, escaped via `esc`) and `fmt(value, max = 80) -> string` returning a clipped display string.

- [ ] **Step 1: Write the failing test** in `gui/tests/Guard.Tests.ps1`: `It 'defines the shrink and truncate rules'` asserting app.css contains `.gr > *`, `.trunc`, `.wrap`, `.clamp2`, and `It 'clips long values'` asserting app.js defines `const tt =` and that `fmt` takes a second `max` parameter.
- [ ] **Step 2: Run** `Invoke-Pester -Path gui/tests/Guard.Tests.ps1`. Expected: the two new tests FAIL.
- [ ] **Step 3: Implement** the CSS utilities and the helpers; apply `.clamp2.wrap` to item keys, `tt()` to ids, domains, request paths and error text; show the domain on the Tenants page only when it differs from the name; give `.dl` `.old`/`.new` cells `overflow-wrap:anywhere`.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Verify visually** (run skill / Playwright): put a 200-character unbroken key in a mock item, load Type and Item pages at 1280px and 800px width, confirm no page-level horizontal scroll.
- [ ] **Step 6: Commit** `fix: long keys, values and ids shrink and truncate with a tooltip`.

### Task 2: Layer list on the tenant record

**Files:**
- Modify: `src/PolicyEngine/Public/Tenants.ps1` (`Get-PETenant` line 1, `Set-PETenant` line 45)
- Create: `src/PolicyEngine/Public/Initialize-PETenantBlueprint.ps1`
- Modify: `src/PolicyEngine/PolicyEngine.psd1` (export the new command), `docs/overview.md`
- Test: `tests/Tenants.Tests.ps1`, create `tests/TenantBlueprint.Tests.ps1`

**Interfaces:**
- Produces:
  - `Get-PETenant` objects gain `Blueprints [string[]]` (ordered, master blueprint first); absent field reads as an empty array.
  - `Set-PETenant -Blueprints [string[]]` stores the list and keeps the existing list when the parameter is not passed.
  - `Get-PETenantBlueprint -Tenant <slug> -MasterBlueprint <name> -DataRoot -> string[]` (private helper): the stored list, or `@($MasterBlueprint)` when empty. The last element is the tenant's own blueprint.
  - `Initialize-PETenantBlueprint -Slug <slug> -MasterBlueprint <name> [-DataRoot] -> string`: creates blueprint `<slug>` as a copy of the master blueprint's latest version via `Get-PEBlueprint` and `Initialize-PEBlueprint`, sets `Blueprints = @(<master>, <slug>)`, returns the new blueprint name. No-op returning the name when it already exists. Throws for slug `master`.

- [ ] **Step 1: Write failing tests** in `tests/TenantBlueprint.Tests.ps1` using a temp `-DataRoot`: (a) `Get-PETenantBlueprint` for a tenant with no list returns `@('prod')`; (b) after `Initialize-PETenantBlueprint -Slug dev -MasterBlueprint prod`, `Get-PETenant -Slug dev` has `Blueprints` `@('prod','dev')` and `Get-PEBlueprint -Name dev` has the same records as `prod` latest; (c) calling it twice creates no second version; (d) slug `master` throws; (e) `Set-PETenant -Slug dev -DisplayName 'X'` keeps `Blueprints`.
- [ ] **Step 2: Run** `Invoke-Pester -Path tests/TenantBlueprint.Tests.ps1`. Expected: FAIL (commands missing).
- [ ] **Step 3: Implement** the signatures above. The copy keeps the master's `Meta` (so tenant-bound properties stay ignored cross-tenant); version 1 is written by `Initialize-PEBlueprint`.
- [ ] **Step 4: Run** the new file and `tests/Tenants.Tests.ps1`. Expected: PASS.
- [ ] **Step 5: Commit** `feat: tenants follow an ordered list of blueprints; create a tenant blueprint from the master`.

### Task 3: Rename a tenant on the Tenants page

**Files:**
- Modify: `src/PolicyEngine/Private/GuiRequest.ps1` (new `'RenameTenant'` case in `Invoke-PEGuiRequestAction`)
- Modify: `gui/PEGui.psm1` (known actions list at line 361; validation in `Get-PEGuiRequestPreview`, 80-character rule near line 432)
- Modify: `src/PolicyEngine/Public/Export-PEGuiData.ps1:95` (stored name wins over `-TenantDisplayName`)
- Modify: `gui/public/assets/app.js` (`tenantsPage`, line 647; click/input handlers at 776 and 816)
- Test: `tests/GuiRequest.Tests.ps1`, `tests/GuiExport.Tests.ps1`, `gui/tests/PEGui.Tests.ps1`

**Interfaces:**
- Produces: request `{ action = 'RenameTenant'; tenantId = <slug>; displayName = <text> }`, no reason required, `Refresh = $true`. It calls `Set-PETenant -Slug $tenantId -DisplayName $displayName` and writes to no tenant. Preview validation errors: `A name is required.` and `The name is longer than 80 characters.`; an unknown slug errors.

- [ ] **Step 1: Write failing tests**: (a) GuiRequest: renaming `dev` to `Robs tenant` changes `Get-PETenant -Slug dev` DisplayName and keeps TenantId and Blueprints; (b) preview rejects `'   '`, `''` and an 81-character name; (c) GuiExport: master with stored DisplayName `Production` exports `displayName = 'Production'` even when `-TenantDisplayName` is passed.
- [ ] **Step 2: Run** the three test files. Expected: FAIL.
- [ ] **Step 3: Implement** the action, the preview rules and the export precedence (stored non-empty name first, then the override, then the slug).
- [ ] **Step 4: Implement the UI**: each Tenants row shows the name, `slug: <slug>` and a Rename control that turns the name into an inline input with Save and Cancel (Enter saves, Escape cancels, 80-character `maxlength`); Master included. No rename control on the Overview.
- [ ] **Step 5: Run** the three test files. Expected: PASS. Then rename a tenant in the running GUI and confirm the new name shows in the top bar after the refresh.
- [ ] **Step 6: Commit** `feat: rename a tenant's friendly name from the Tenants page`.

### Task 4: Drift against each layer in the exported GUI data

**Files:**
- Modify: `src/PolicyEngine/Public/Export-PEGuiData.ps1` (per-tenant block from line 90; add a `-MasterBlueprint` meaning for the layer list; keep `-BlueprintName`)
- Create: `src/PolicyEngine/Private/GuiLayerView.ps1`
- Modify: `gui/mock-data/index.json`, `gui/mock-data/tenants/*` (add `layers`), `gui/README.md` (data contract)
- Test: `tests/GuiExport.Tests.ps1`, `gui/tests/PEGui.Tests.ps1`

**Interfaces:**
- Consumes: `Get-PETenantBlueprint` (Task 2); `Compare-PEState -Blueprint <state> -Target $check.State -Decisions <decisions>`.
- Produces: `Get-PEGuiLayerView -Tenant <tenant object> -Check <check or $null> -LayerNames <string[]> -DataRoot -> object[]`, one entry per layer: `@{ name; version; role = 'master'|'tenant'; sameAsOwn [bool]; checked [bool]; drifted [int]; aligned [int]; changed [int]; missing [int]; targetOnly [int] }`.
  - `index.json` tenants gain `layers` (that array). The last layer is the tenant's own; for a one-layer tenant (Production) both panels read the same layer.
  - Findings for layers other than the own one are written to `tenants/<slug>/layers/<blueprintName>/findings.json` in the same shape as `findings.json`, each finding carrying `layer = <blueprintName>`.

- [ ] **Step 1: Write failing tests**: (a) a replica with layers `prod`, `dev` where `dev` has one extra record exports `layers[0]` (prod) with drifted count including that record and `layers[1]` (dev) with 0 drifted; (b) a never-checked tenant exports every layer with `checked = $false`; (c) a tenant with no stored list exports one layer; (d) a layer blueprint missing on disk exports that layer as `checked = $false` with a `problem` text, and the export still completes.
- [ ] **Step 2: Run** `Invoke-Pester -Path tests/GuiExport.Tests.ps1`. Expected: FAIL.
- [ ] **Step 3: Implement** `Get-PEGuiLayerView` and call it per tenant; reuse the existing per-finding conversion for the layer findings files rather than duplicating it (extract it into `GuiLayerView.ps1` if that is what it takes).
- [ ] **Step 4: Update mock data and README** so the mock GUI has a master tenant (one layer) and a replica (two layers, different counts).
- [ ] **Step 5: Run** `Invoke-Pester -Path tests, gui/tests`. Expected: PASS.
- [ ] **Step 6: Commit** `feat: export drift against every blueprint layer of a tenant`.

### Task 5: Checks and Revert use the tenant's own blueprint

**Files:**
- Modify: `src/PolicyEngine/Private/GuiRequest.ps1` (`Recheck` line 73, `Promote` line 140, `Accept` line 161)
- Modify: `gui/PEGui.psm1` (`Get-PEGuiEffect` at 249, `Test-PEGuiWritesMaster` at 285, `Get-PEGuiConfigEntry` at 290, line 463 target tenant)
- Test: `tests/GuiRequest.Tests.ps1`, `gui/tests/PEGui.Tests.ps1`

**Interfaces:**
- Consumes: `Get-PETenantBlueprint`. In `Invoke-PEGuiRequestAction` the existing `-BlueprintName` is the master blueprint; the tenant's own blueprint is the last element of `Get-PETenantBlueprint -Tenant $tenant -MasterBlueprint $BlueprintName`.
- Produces: `Recheck` (full and scope), `Promote` and `Accept` all use the tenant's own blueprint. `Promote` is allowed for any tenant (it writes only the blueprint) and the "Promote from a Replica would write to the master tenant" restriction is removed. `Accept` keeps its master-write confirmation for the Master. `Test-PEGuiWritesMaster` no longer treats Replica Promote as a master write.

- [ ] **Step 1: Write failing tests**: (a) Recheck for replica `dev` compares against blueprint `dev` (the saved check's `BlueprintName` is `dev`); (b) `Promote` of a Changed item from `dev` writes version 2 of blueprint `dev`, leaves `prod` at version 1 and calls no apply script; (c) `Accept` on `dev` plans from blueprint `dev`; (d) master behaviour is unchanged.
- [ ] **Step 2: Run** `Invoke-Pester -Path tests/GuiRequest.Tests.ps1, gui/tests/PEGui.Tests.ps1`. Expected: FAIL.
- [ ] **Step 3: Implement** the own-blueprint lookup in the three cases and update the effect text and master-write rules.
- [ ] **Step 4: Run** the same command and `tests/Scopes.Tests.ps1`, `tests/FullCheck.Tests.ps1`. Expected: PASS.
- [ ] **Step 5: Commit** `feat: checks, promote and revert work against the tenant's own blueprint`.

### Task 6: Blueprint-to-blueprint moves (promote up, update tenant blueprint)

**Files:**
- Create: `src/PolicyEngine/Public/Move-PEBlueprintItem.ps1`
- Modify: `src/PolicyEngine/PolicyEngine.psd1`, `src/PolicyEngine/Private/GuiRequest.ps1` (cases `'PromoteUp'`, `'PullDown'`; replace the `'RevertBlueprint'` stub only if nothing else uses it, else leave it), `gui/PEGui.psm1` (known actions, `ReasonRequired`, preview with added/changed/removed list, `Get-PEGuiEffect`)
- Test: create `tests/BlueprintMove.Tests.ps1`; extend `tests/GuiRequest.Tests.ps1`, `gui/tests/PEGui.Tests.ps1`

**Interfaces:**
- Produces: `Get-PEBlueprintMovePreview -From <name> -To <name> -Item <object[]> [-DataRoot] -> object[]` (one row per item: `@{ ResourceType; Key; Op = 'Added'|'Changed'|'Removed' }`, derived from `Get-PEBlueprintChange -Name $To -MasterState (Get-PEBlueprint -Name $From)`; an item that is not a change throws).
  `Move-PEBlueprintItem -From <name> -To <name> -Item <object[]> -Reason <string> -ExpectedVersion <int> [-DataRoot] -> int` (new version of `-To`): throws without writing when the latest version of `-To` is not `-ExpectedVersion`; otherwise `Approve-PEBlueprintChange`. Reuse of existing commands only; no copy logic.
  GUI requests: `{ action = 'PromoteUp'|'PullDown'; tenantId; items = @(@{ itemId }); reason; expectedVersion }`. `PromoteUp` = from the tenant's own blueprint to the master blueprint; `PullDown` = from the master blueprint to the tenant's own blueprint. Neither is offered for a tenant with one layer. Previews include `moves` (the preview rows) and `targetBlueprint`, `targetVersion`.

- [ ] **Step 1: Write failing tests** (`tests/BlueprintMove.Tests.ps1`): (a) pulling a record that exists only in `prod` into `dev` writes `dev` v2 containing it and leaves `prod` at v1; (b) promoting a changed record up replaces it in `prod`; (c) promoting an item that `dev` lacks but `prod` has, up, removes it from `prod` and the preview row says `Removed`; (d) `-ExpectedVersion` older than latest throws and writes nothing; (e) an item that is not a change throws; (f) no reason throws.
- [ ] **Step 2: Run** `Invoke-Pester -Path tests/BlueprintMove.Tests.ps1`. Expected: FAIL.
- [ ] **Step 3: Implement** the two public functions as thin wrappers over `Get-PEBlueprintChange` / `Approve-PEBlueprintChange`.
- [ ] **Step 4: Write failing GUI-request tests** (both new actions succeed and report "No tenant was changed."; preview lists the moves; a stale `expectedVersion` fails the job; a one-layer tenant is refused), run them (FAIL), then implement the request cases and preview rules.
- [ ] **Step 5: Run** `Invoke-Pester -Path tests, gui/tests`. Expected: PASS.
- [ ] **Step 6: Commit** `feat: promote items between blueprint layers with preview and stale guard`.

### Task 7: Selected tenant everywhere

**Files:**
- Modify: `gui/public/assets/app.js` (`curTenant` line 30, `topbar` 168, `crumbs` 182, `tenantTabs` 602, `route` 141, every `role(t)` use about 20 places, page headers of workload, type, item, drift, activity)
- Modify: `gui/public/assets/app.css`
- Test: `gui/tests/Guard.Tests.ps1`, plus a Playwright check (Step 5)

**Interfaces:**
- Produces: `ui.tenant` is read from `?tenant=<slug>` and `localStorage` (wrapped in try/catch) and written back on change; `contextStrip(t) -> string` (HTML: tenant friendly name, role badge, layers with versions, aligned percentage; shown on every page below the top bar); `tenantLabel(t) -> string` returns the friendly name and replaces `role(t)` as the visible label (the role remains a badge). The top bar holds the tenant picker; the Drift review badge counts the selected tenant only.

- [ ] **Step 1: Write failing guard tests** asserting app.js defines `contextStrip` and `tenantLabel` and no longer renders `role(` as a label in headings (assert the count of `role(` label uses dropped to the badge sites; builder picks the exact check after reading the file).
- [ ] **Step 2: Run** `Invoke-Pester -Path gui/tests/Guard.Tests.ps1`. Expected: FAIL.
- [ ] **Step 3: Implement** URL and storage handling, the picker, the strip and the label swap; an unknown `?tenant=` falls back to the first tenant.
- [ ] **Step 4: Run** the guard test. Expected: PASS.
- [ ] **Step 5: Verify visually**: switch tenants, reload, open a link with `?tenant=`; the strip and page headers show the friendly name on every page.
- [ ] **Step 6: Commit** `feat: one selected tenant in the top bar, URL and every page header`.

### Task 8: Overview with two panels and the tenant table

**Files:**
- Modify: `gui/public/assets/app.js` (`overview` line 260, `scopeActions` 682, `scopesCard` 692, `typeScopesCard` 709, `drift` 415 layer filter, `dialogView` 561 for the move preview, `openDialog` 543)
- Modify: `gui/public/assets/app.css`
- Test: `gui/tests/Guard.Tests.ps1`, Playwright check

**Interfaces:**
- Consumes: `tenant.meta.layers` (Task 4); actions `PromoteUp`, `PullDown`, `Promote`, `Accept` (Tasks 5, 6); `contextStrip` (Task 7).
- Produces: `layerPanel(t, layer, own) -> string` and a new Overview: header card (name, role badge, slug and domain, layers with versions, last full check; no rename); two panels side by side, own blueprint then master blueprint, each with drifted/aligned counts and a changed/missing/extra breakdown, worded "drifted".
  - Own panel actions: Review (Drift page filtered to the tenant), Promote to tenant blueprint, Promote to master blueprint, Revert (opens the existing scope/item picker with every drifted item pre-selected).
  - Master panel actions: Review, Update tenant blueprint.
  - A one-layer tenant shows one panel naming both roles with a note that the master and tenant blueprint are the same.
  - A never-checked tenant shows "Not checked yet" and a Check button.
  - Below: all-tenants table (name, drifted against each layer, last check, link `?tenant=`), then the existing workload bars and scopes; "Check by resource type" collapsed unless something drifted.
  - Drift page gains a layer filter; findings of the master layer are read-only except the pull-down action. The move dialog shows the preview rows and sends `expectedVersion` from the preview.

- [ ] **Step 1: Write failing guard tests** asserting app.js defines `layerPanel`, contains the strings `Update tenant blueprint`, `Promote to master blueprint`, `Not checked yet`, and does not contain `experiments` or `backfill` (case-insensitive).
- [ ] **Step 2: Run** `Invoke-Pester -Path gui/tests/Guard.Tests.ps1`. Expected: FAIL.
- [ ] **Step 3: Implement** the Overview, the layer filter and the move dialog.
- [ ] **Step 4: Run** `Invoke-Pester -Path tests, gui/tests`. Expected: PASS.
- [ ] **Step 5: Verify visually** against the mock data: master (one panel), replica (two panels), a never-checked tenant, and the stale-move error shown in the dialog.
- [ ] **Step 6: Commit** `feat: Overview shows the selected tenant against its blueprint layers`.

### Task 9: Tenants page rows, responsive tables, spacing scale

**Files:**
- Modify: `gui/public/assets/app.js` (`tenantsPage` 647; table markup in `drift`, `blueprint`, `exclusions`, `workload`, `typePage`; inline `style=` attributes)
- Modify: `gui/public/assets/app.css`
- Test: `gui/tests/Guard.Tests.ps1`, Playwright check

**Interfaces:**
- Produces: CSS variables `--s1:4px; --s2:8px; --s3:12px; --s4:16px; --s5:24px; --s6:32px` used by padding and gaps; classes `.note`, `.sub`, `.stack` replacing the inline `margin`/`font-size` styles; table minimum widths (980, 1180, 1000, 900, 760px) replaced by column budgets (fixed small columns, `1fr` text columns); below 900px a `.gr` row stacks as a card. The Drift table merges Type under Item as a muted second line and moves "First seen" into the expanded row. Tenants rows show drifted counts per layer and Open, Check, Rename.

- [ ] **Step 1: Write failing guard tests** asserting app.css defines `--s1` to `--s6` and a `@media (max-width: 900px)` rule for `.gr`, and that app.js contains no `min-width:980px`, `min-width:1180px`, `min-width:1000px`, `min-width:900px` or `min-width:760px`.
- [ ] **Step 2: Run** `Invoke-Pester -Path gui/tests/Guard.Tests.ps1`. Expected: FAIL.
- [ ] **Step 3: Implement** the scale, the classes, the column budgets and the stacked layout; replace the inline styles in the touched pages.
- [ ] **Step 4: Run** `Invoke-Pester -Path gui/tests`. Expected: PASS.
- [ ] **Step 5: Verify visually** at 1280px, 900px and 375px on every page: no page-level horizontal scroll; Drift readable at 900px.
- [ ] **Step 6: Commit** `fix: responsive tables, one spacing scale, richer Tenants rows`.

### Task 10: Migrate the existing install and update the docs

**Files:**
- Create: `tools/Initialize-PETenantBlueprints.ps1` (thin script: for every registered replica without its own blueprint, call `Initialize-PETenantBlueprint`; prints what it did; supports `-WhatIf`)
- Modify: `docs/overview.md`, `docs/handover.md` (record: layers are full copies, one tenant blueprint per tenant, the Promote-takes-the-tenant's-side rule), `gui/README.md`
- Test: `tests/TenantBlueprint.Tests.ps1`

- [ ] **Step 1: Write failing test** running the script's logic against a temp `-DataRoot` with `master` and two replicas: afterwards both replicas have their own blueprint and `Blueprints` list, a second run changes nothing.
- [ ] **Step 2: Run** `Invoke-Pester -Path tests/TenantBlueprint.Tests.ps1`. Expected: FAIL.
- [ ] **Step 3: Implement** the script and update the three docs.
- [ ] **Step 4: Run** `Invoke-Pester -Path tests, gui/tests`. Expected: all PASS.
- [ ] **Step 5: Run the script with `-WhatIf` against the real data folder** and show the output to the owner before running it for real (it creates blueprint folders under `data/`).
- [ ] **Step 6: Commit** `feat: migrate existing replicas to their own blueprint; docs`.

---

## Self-review

- **Spec coverage:** model and rules (Tasks 2, 5, 6), global selected tenant and context strip (7), Overview Option A with "drifted" wording and no rename (8), rename on the Tenants page with export fix (3), long-text and spacing fixes (1, 9), per-layer drift in the export (4), migration and docs (10), Production as one layer (2, 4, 8), stale guard and preview (6, 8). Non-goals (three-layer screens, tenant A vs B, blueprint rename) have no task.
- **Types:** `Get-PETenantBlueprint`, `Get-PEGuiLayerView`, `Move-PEBlueprintItem`, `Get-PEBlueprintMovePreview`, `layerPanel`, `contextStrip`, `tenantLabel` and the actions `RenameTenant`, `PromoteUp`, `PullDown` are named identically wherever they are used.
- **Not read before planning:** `gui/server.ps1`, the per-tenant finding conversion in `Export-PEGuiData.ps1` lines 116-340 and the bodies of `app.js` pages. The implementer reads them at the start of the task that edits them; if the finding conversion cannot be shared cleanly, split it as part of Task 4.
