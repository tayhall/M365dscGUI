# Overview and Drill-down Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the GUI Overview show how every tenant is drifting (cards with workload heat-cells, a Compare matrix, Alignment by workload above the type card) and make each graphic click through to the workload, type, and a policy page whose values can be filtered All / Drifted / Matching.

**Architecture:** Front-end only. Pure colour and count logic goes in one small new file, `gui/public/assets/heat.js`, tested with node from Pester. Screens stay in `app.js` and reuse the existing helpers (`layersOf`, `findingsOf`, `isOpenDrift`, `loadLayer`, `D.layerRows`, `path.*`, `link`, `esc`, `plural`, `tt`). No server, engine or view-model change.

**Tech Stack:** Vanilla JS and CSS (no build step, no third-party code), Pester 5.7.1 (`gui/tests`), node (for `heat.js` tests), Pode mock server (`gui/Start-PEGui.ps1 -Mock`).

**Spec:** `docs/superpowers/specs/2026-10-26-overview-drilldown-design.md`. Read its "Where the counts come from" section first.

## Global Constraints

- No build step, no third-party code, no charting library: rings are `conic-gradient`, bars are divs (`gui/README.md`).
- Colour is never the only signal: every cell, bar and slice shows its number or has an `aria-label`/`role="img"` text; "not checked" (`nc`, grey) is never counted as aligned.
- Excluded items stay outside every count.
- Thresholds (spec "Left to the builder", suggested values, used as decided): 0 drifted = `ok`; drifted share of managed up to 10% = `w1`; up to 30% = `w2`; above 30% = `w3`; not checked = `nc`.
- Card cells follow the card's headline layer: the master layer when the tenant has a layer with `sameAsOwn === false`, otherwise its own. The cell number is the drifted count; colour comes from drifted share of `managed` for that workload (from `status.json`); tooltip says "of N managed".
- Existing pages keep working in `-Mock` mode: `Invoke-Pester -Path gui/tests` passes after every task.
- Existing class names `.ring`, `.ringin`, `.seg`, `.bar`, `.s-ok`, `.s-dr`, `.s-nc`, `.tcards`, `.tcard` are taken; new CSS uses the prefixes `.hm-` (heat cells and matrix) and `.vt-` (view toggle).

## Review Focus

- A tenant that has never been checked (`layer.checked === false`, no `lastFullCheck`): its cells are all `nc`, not green.
- A workload with `managed === 0`: no division by zero; cell is `ok` with 0, or `nc` when nothing was checked.
- Master-layer rows not loaded yet (`D.layerRows` empty): cells render as a loading state and fill in after `loadLayer` re-renders; no error, no repeated requests.
- An offline tenant (`meta.offline`): cells still render from stored data; no "Check now" affordance is added by this work.
- One tenant only (`layersOf(meta).length === 1`): Compare has one row for it, and cards show a single set of cells.
- Item page with zero drifted rows (Aligned item) opens on the filter that has rows (Matching), not an empty Drifted table.

---

### Task 1: Pure heat helpers (`heat.js`)

**Files:**
- Create: `gui/public/assets/heat.js`
- Modify: `gui/public/index.html` (add `<script src="/assets/heat.js"></script>` before `app.js`, line 12)
- Test: `gui/tests/Heat.Tests.ps1`

**Interfaces:**
- Produces, on `window.PEHeat` (and `module.exports` when `module` exists, so node can load it):
  - `PEHeat.tone(drifted: number, managed: number, checked: boolean) -> 'ok'|'w1'|'w2'|'w3'|'nc'`
  - `PEHeat.countByWorkload(findings: Array<{workload: string}>, workloads: string[]) -> Record<string, number>` (every workload in `workloads` present, 0 when none)

- [ ] **Step 1: Write the failing tests** in `gui/tests/Heat.Tests.ps1`. Skip the whole file when `node` is not on PATH (`-Skip:(-not (Get-Command node -ErrorAction SilentlyContinue))`). Each `It` runs `node -e` with `require('<abs path to heat.js>')` and compares JSON output. Cases:
  - `tone(0, 40, true)` is `ok`; `tone(4, 40, true)` is `w1` (exactly 10%); `tone(5, 40, true)` is `w2`; `tone(12, 40, true)` is `w2` (exactly 30%); `tone(13, 40, true)` is `w3`.
  - `tone(3, 0, true)` is `w3` and `tone(0, 0, true)` is `ok` (managed 0 never divides by zero).
  - `tone(7, 40, false)` is `nc` (not checked wins over any count).
  - `countByWorkload([{workload:'Intune'},{workload:'Intune'},{workload:'Teams'}], ['Entra ID','Intune','Teams'])` equals `{"Entra ID":0,"Intune":2,"Teams":1}`; a finding whose workload is not in the list is ignored.
- [ ] **Step 2: Run** `pwsh -NoProfile -Command "Invoke-Pester -Path gui/tests/Heat.Tests.ps1 -Output Minimal"`. Expected: FAIL (module not found).
- [ ] **Step 3: Implement** both functions in `heat.js` as an IIFE that assigns `globalThis.PEHeat` and `module.exports`. `tone` returns `nc` first, then `ok` for 0 drifted, then compares `drifted / managed` (managed 0 with drifted > 0 gives `w3`).
- [ ] **Step 4: Run** the same command. Expected: PASS. Also add to `Assets.Tests.ps1` one `It` asserting `index.html` loads `heat.js` before `app.js` (regex on `heat\.js"></script>\s*<script src="/assets/app\.js`), and run the whole folder: `Invoke-Pester -Path gui/tests -Output Minimal`. Expected: all pass.
- [ ] **Step 5: Commit** `feat: pure heat helpers for the overview cells`.

### Task 2: Alignment by workload above the type card, clickable

**Files:**
- Modify: `gui/public/assets/app.js` `overview()` (around lines 504-534); `gui/public/assets/app.css`
- Test: `gui/tests/Assets.Tests.ps1`

**Interfaces:**
- Consumes: existing `path.workload(t, wl)`, `path.drift({tenant, workload})`, `link`.
- Produces: `function workloadBars(t: string): string` returning the "Alignment by workload" section HTML (extracted from the inline `bars` code in `overview()`), reused by Task 4's page order.

- [ ] **Step 1: Write the failing test**: in the `Overview in the GUI assets` Describe, assert that in `app.js` the string `${workloadBars(t)}` appears before `${typeCard ?` inside `overview()` (use a regex with `(?s)workloadBars\(t\).*?Check by resource type`), and that `function workloadBars(` exists.
- [ ] **Step 2: Run** `Invoke-Pester -Path gui/tests/Assets.Tests.ps1 -Output Minimal`. Expected: FAIL.
- [ ] **Step 3: Implement** `workloadBars(t)` by moving the `bars` mapping and the `<section class="card"><h2>Alignment by workload</h2>…` template out of `overview()`. Place `${workloadBars(t)}` directly after `${scopesCard()}` and before the type card. Make each of the three segments (aligned, drifted, not checked) its own link: aligned and drifted go to `path.workload(t, wl)`; drifted segment goes to `path.drift({ tenant: t, workload: wl })`; the not-checked segment goes to `path.workload(t, wl)`. Keep the `aria-label` text already on the bar. Add `.bar a.seg{display:block;height:100%}` and a focus outline.
- [ ] **Step 4: Run** the folder. Expected: PASS.
- [ ] **Step 5: Commit** `feat: Alignment by workload sits above Check by resource type and its segments click through`.

### Task 3: Tenant cards with a workload heat-cell row

**Files:**
- Modify: `gui/public/assets/app.js` (`tenantCards`, new `heatCells`, load master layers); `gui/public/assets/app.css`
- Test: `gui/tests/Assets.Tests.ps1`

**Interfaces:**
- Consumes: `PEHeat.tone`, `PEHeat.countByWorkload` (Task 1); `layersOf(meta)`; `D.layerRows[t + '|' + layerName]`; `loadLayer(t, name)`; `tenant(t).status.workloads`; `D.index.workloads`; `path.drift`, `path.workload`.
- Produces: `function headlineLayer(meta) -> {layer, own: boolean}` (the first layer with `sameAsOwn === false` and `checked`, else the last layer); `function heatRow(t: string): {wl: string, drifted: number|null, managed: number, tone: string}[]` (`drifted` is `null` while master-layer rows are loading); `function heatCells(t: string): string` (HTML).

- [ ] **Step 1: Write failing tests** in Assets.Tests.ps1: `function headlineLayer(`, `function heatRow(`, `function heatCells(` exist; `tenantCards` output includes `heatCells(`; CSS defines `.hm-cell`, `.hm-ok`, `.hm-w1`, `.hm-w2`, `.hm-w3`, `.hm-nc`.
- [ ] **Step 2: Run** the Assets tests. Expected: FAIL.
- [ ] **Step 3: Implement.** `heatRow`: for an own-layer headline, drifted per workload is `w.drifted` from `status.json`; for a master-layer headline, it is `PEHeat.countByWorkload(D.layerRows[t + '|' + layer.name].filter(isOpenDrift), D.index.workloads)`, `null` for every workload until that key exists (call `loadLayer` once; it already guards with `layerLoading` and re-renders). A tenant whose headline layer has `checked === false` yields tone `nc` for every cell. `heatCells` renders one `<a class="hm-cell hm-<tone>" data-link>` per workload (short label above, number inside, "…" while loading, "n/c" for `nc`), `href` = `path.drift({tenant: t, workload: wl, layer: own ? '' : layer.name})` when drifted > 0 else `path.workload(t, wl)`; `title` = "Intune: 41 drifted of 62 managed (vs master blueprint)"; a one-line label under the row names the layer ("vs master blueprint" / "vs its blueprint"). Insert it in `tenantCards` between `.rings` and the "full check" line; keep the card's tenant link and rings.
- [ ] **Step 4: Run** `Invoke-Pester -Path gui/tests -Output Minimal`. Expected: PASS. Then start the mock (`pwsh -NoProfile -File gui/Start-PEGui.ps1 -Mock`), open the printed address, and confirm with the Playwright tools or by eye: master card shows 5 workloads (own layer, "vs its blueprint"), replica card shows master-layer numbers summing to 12.
- [ ] **Step 5: Commit** `feat: tenant cards show a heat-cell row per workload`.

### Task 4: Compare view (matrix) and the Cards / Compare toggle

**Files:**
- Modify: `gui/public/assets/app.js` (`overview()`, new `compareMatrix`, click handler near line 1331, `ui` state at line 173); `gui/public/assets/app.css`
- Test: `gui/tests/Assets.Tests.ps1`

**Interfaces:**
- Consumes: `heatRow`, `headlineLayer` (Task 3), `layersOf`.
- Produces: `ui.view: 'cards'|'compare'` (persisted under `localStorage` key `pe.overviewView`, read and written inside try/catch like `readStoredTenant`); `function compareMatrix(): string`; `function layerRowsFor(t: string): {label: string, layerName: string, own: boolean}[]` (one entry per layer in `layersOf`, master layer first).

- [ ] **Step 1: Write failing tests**: `function compareMatrix(`, `data-act="overview-view"`, `pe.overviewView` in `app.js` guarded by `try {`; CSS has `.vt-toggle` and `.hm-matrix`.
- [ ] **Step 2: Run** Assets tests. Expected: FAIL.
- [ ] **Step 3: Implement.** A two-button toggle ("Cards", "Compare", `aria-pressed`) above the cards sets `ui.view` via `data-act="overview-view"` (add a branch in the click handler; call `render()`). `compareMatrix` renders a grid: header row = workload names, each a link to `path.drift({workload: wl})` with tenant `all`; one row per tenant and layer, row label = tenant label plus "vs master blueprint" or "vs own blueprint"; cells reuse `heatRow` rows (own rows from `status.json`, master rows from `layer-findings` via the same loading path) and the `hm-` classes; a final "Total" cell with the layer's `drifted`. The selected tenant's rows get the existing highlight style. Cells link like Task 3 (layer carried through for master rows).
- [ ] **Step 4: Run** the folder: PASS. In the mock, toggle to Compare: 3 rows (master vs blueprint; replica vs master; replica vs own) by 5 workloads; reload keeps the choice; clicking a replica-vs-master cell opens `/drift?tenant=replica&workload=…&layer=prod`.
- [ ] **Step 5: Commit** `feat: Compare matrix of tenants against workloads`.

### Task 5: Workload page click-throughs

**Files:**
- Modify: `gui/public/assets/app.js` `workload()` (around lines 536-563)
- Test: `gui/tests/Assets.Tests.ps1`

**Interfaces:**
- Consumes: `path.drift({tenant, workload, kind})`, `path.type`.

- [ ] **Step 1: Write failing test**: in `app.js`, the "Drift by kind" legend rows are links built with `path.drift({ tenant: r.t, workload: r.wl, kind: k.k })` (regex on `kind: k.k`).
- [ ] **Step 2: Run** Assets tests. Expected: FAIL.
- [ ] **Step 3: Implement.** The donut is a `conic-gradient` and cannot be hit-tested, so each legend row (`.kl`) becomes a link to the drift list filtered by that kind (rows with 0 stay plain text); the donut gets an `aria-label` that already lists the counts. Per-type bars already link to the type page; add `path.type(...)` hrefs to the bar track as well so the whole row is clickable if it is not.
- [ ] **Step 4: Run** the folder: PASS. In the mock, from Intune on the replica click "Changed": the drift list opens filtered to Intune and Changed.
- [ ] **Step 5: Commit** `feat: workload page kind and type graphics click through`.

### Task 6: Item page filter: All / Drifted / Matching

**Files:**
- Modify: `gui/public/assets/app.js` `itemPage()` (settings branch, lines 646-654), `ui` at line 173, reset at line 326, handler at line 1331
- Test: `gui/tests/Assets.Tests.ps1`

**Interfaces:**
- Produces: `ui.itemShow: 'all'|'drifted'|'matching'` replacing `ui.showSame`; `data-act="item-show"` with `data-show`.

- [ ] **Step 1: Write failing tests**: `ui.showSame` and `toggle-same` no longer appear in `app.js`; `data-act="item-show"` and `ui.itemShow` do; the three filter labels `All `, `Drifted `, `Matching ` appear in the template.
- [ ] **Step 2: Run** Assets tests. Expected: FAIL.
- [ ] **Step 3: Implement.** Replace the "Show N identical" button with a three-button group (`aria-pressed`) showing counts: "All N", "Drifted N", "Matching N". Default on opening an item: `drifted` when `diffs.length > 0`, else `matching` (reset where `ui.showSame = false` is reset today, line 326). When the item is not comparable (only one side exists), show all rows and hide the group. Matching rows render in the same grid with the green `m` row style from the mockup (add `.setg.ok`), drifted rows keep `.hl`. Keep the unreadable-properties footer and the "Ignore value as noise" button on drifted rows.
- [ ] **Step 4: Run** the folder: PASS. In the mock, open a Changed item: opens on Drifted with count, Matching shows the rest, All shows both; open an Aligned item: opens on Matching.
- [ ] **Step 5: Commit** `feat: item page filters settings by drifted and matching`.

### Task 7: Documentation and end-to-end check

**Files:**
- Modify: `gui/README.md` (files table: add `heat.js`), `docs/handover.md` (short section "Overview and drill-down (2026-10-26)": what changed, the approximation of the master-layer share, the Compare column header ending at the Drift review)

- [ ] **Step 1:** Update both docs, one paragraph each.
- [ ] **Step 2:** Run `Invoke-Pester -Path gui/tests -Output Minimal` and the repo's fast suite as the handover documents it. Expected: all pass.
- [ ] **Step 3:** With the mock running, walk the four-click path: Overview card cell → drift list (or workload page) → type page → item page, and the Compare path; check at 390 px width that the cells and matrix do not force horizontal page scroll.
- [ ] **Step 4: Commit and push** `docs: overview and drill-down` (push main, per the project's push-regularly rule).
