# Drift policy engine web GUI (Pode): design and scope

Date: 2026-10-21. Status: draft for review.

Items marked **(my call)** are decisions made while writing this document, not agreed in conversation. Check these first.

Companion to `2026-10-21-drift-policy-engine-design.md`. Terms (blueprint, master, replica, Missing, Changed, Target-only, unmanaged, noise, rectify, promote) mean what they mean there.

## Intent

A local web GUI, served by Pode, that shows how far each tenant is from the blueprint and lets a person act on the drift. It goes from a high-level picture (two tenants, four workloads, aligned versus drifted) down to one policy and the setting that differs.

This scope covers the GUI only: its screens, navigation, visual design, the data files it reads, and the action requests it emits. It is not connected to the engine. It runs entirely on mock data, and every action button goes through a stub that pretends to run a job. Wiring the stubs to the PowerShell scripts is a later, separate piece of work.

## Goals

1. **Overview of both tenants.** For each tenant (master and replica) and each workload (Entra ID, Intune, Exchange Online, Teams, then Other), show how many items are under management, how many are aligned (no drift), how many have drifted, how many are excluded, and how many could not be checked. Show the age of the last full check and quick scan next to every number, so a scan is never read as full alignment.
2. **Drill down** from overview → tenant workload → resource type → single item (policy, group, setting), with a breadcrumb at every level.
3. **Item detail** shows the blueprint and tenant versions side by side, with differing settings highlighted and unchanged ones collapsible.
4. **Manage drift.** For each drifted item: **accept** the difference, which brings the tenant back in line with the blueprint; **promote** the change, which takes the drift to the master and its blueprint; or **exclude** the item (stop managing it, or ignore one property value as noise). Approval is per item; several items can be selected at once but each one is listed in the confirm step.
5. **Review queue.** One filterable list of all open drift across both tenants, for working through drift without drilling into each workload.
6. **History.** Blueprint versions (with **revert** to an earlier version), exclusions with their reasons, and an activity log of every action requested, with the generated config (mock text for now).

## Non-goals (this scope)

- Calling the engine or any PowerShell script that touches a tenant. Actions write a request file and a mock job; nothing else.
- Sign-in, users or roles. Single user on `localhost`. Entra sign-in comes later.
- Editing policies in the GUI. The GUI decides what happens to drift; it never edits settings.
- Workloads beyond the four, other than an "Other" bucket for anything else in the data.
- Hosting in Azure, containers or pipelines.

## Anti-goals (a failure even if it works)

- An action that writes to the master without a separate, explicit confirm step that names the master tenant.
- Offering accept, promote or exclude on a finding the engine says cannot be acted on (Ambiguous, Not checked, Not available, Unkeyed, Unreadable).
- Showing a workload as "aligned" when some of its components were not checked. Not checked is its own state, never green.
- Colour as the only signal. Every status also has a label or icon.
- The GUI changing its own data files. It reads view-model files and writes only action requests.

## Tenants and what the actions mean

Both tenants are compared against the same blueprint. Three actions apply to a drifted item (agreed with the user):

- **Accept** the difference between the blueprint and the tenant. The tenant is then brought in line with the blueprint (the engine's rectify). The blueprint does not change.
- **Promote** the change. The drift becomes the new intended state: it is applied to the master (if the master does not have it already) and written into the blueprint for that item. The replica then counts as aligned.
- **Exclude** the item from management, or mark one property value as noise.

What each action does in practice, by tenant and finding kind:

| Tenant | Finding | Accept (tenant → blueprint) | Promote (drift → master + blueprint) | Exclude |
| ------ | ------- | ------ | ------ | ------- |
| Replica | Missing | Create the item in the replica | Delete it from the master and the blueprint **(my call: offered, with the master-write confirm)** | Exclude item |
| Replica | Changed | Update the replica to the blueprint | Apply the replica's settings to the master; update the blueprint item | Exclude item, or mark a property value as noise |
| Replica | Target-only | Remove from the replica | Create in the master; add to the blueprint | Keep as unmanaged |
| Master | Missing | Re-create in the master | Remove from the blueprint (the master already lacks it) | Exclude item |
| Master | Changed | Update the master to the blueprint | Update the blueprint item to the master's settings | Exclude item, or mark a property value as noise |
| Master | Target-only | Remove from the master | Add to the blueprint | Keep as unmanaged |
| Either | Possible rename | Shown as a pair. Actions apply to the pair, never to one half alone. Remove is not offered until the user has looked at the pair. | | |
| Either | Ambiguous, Not checked, Not available, Unkeyed, Unreadable | No actions. The row explains why and what would fix it. | | |

Promote always ends with the blueprint changed, so every promote creates a new blueprint version and the dialog shows the version number it will create. Promote from the master only touches the blueprint; promote from the replica also writes to the master.

Rules the GUI enforces:

- Any action that writes to the master (Accept on the master, Promote from the replica) needs a second confirm screen that names the master tenant, lists every item, and shows the generated config preview.
- Accept is disabled for a workload while any of its components are Not checked, except for a selected item whose own component exported. The disabled button shows the reason.
- Promote and Exclude ask for a reason. It is required, and is shown in the blueprint change record and the exclusions list.

### Revert the blueprint

**Revert** goes back to a previous blueprint version. It is a blueprint action, not a drift action, so it lives on the Blueprint page and on an item's History tab, not in the drift bar.

- **Whole blueprint:** pick an earlier version and revert to it. **(my call)** Versions are immutable, so a revert never deletes or rewrites anything: it creates a new version (for example v8) whose content equals the chosen one (v5), with a change record "Reverted to v5" and the reason. Reverting the revert is just another revert.
- **Single item:** on an item's History tab, "Restore this item from v5" creates a new version with only that item taken from v5 (or removed, if v5 did not have it). **(my call)**
- Before confirming, the dialog shows what will change between the current version and the target: items added, changed and removed, per workload, with the same setting-level diff as the item page.
- A reason is required.
- **Revert changes only the blueprint.** No tenant is written to. After a revert, both tenants are compared with the restored blueprint on the next check, so whatever now differs shows up as drift and goes through Accept, Promote or Exclude as usual. The dialog says this, and shows an estimate of the drift it will cause in each tenant (the items whose blueprint content changes). **(my call)** The alternative, reverting and applying to the tenants in one step, would write to the master from the Blueprint page and skip per-item approval.
- Exclusions and noise rules are not reverted. They are separate decisions with their own history.

In v1 of the engine one tenant plays both roles. The GUI must work with one tenant entry as well as two (the overview then shows one column).

## Navigation

```
Top bar:  [Overview]  [Drift review (n)]  [Blueprint]  [Exclusions]  [Activity]        Blueprint "prod" v7 · Jobs (1 running)

Overview  /
└─ Tenant workload  /tenants/{tenant}/workloads/{workload}
   └─ Resource type  /tenants/{tenant}/workloads/{workload}/types/{type}
      └─ Item detail  /tenants/{tenant}/items/{itemId}

Drift review     /drift?tenant=&workload=&kind=&type=&q=
Blueprint        /blueprint            (versions, pending master changes)
  ├─ Version     /blueprint/versions/{n}
  └─ Compare     /blueprint/compare?from={n}&to={m}
Exclusions       /exclusions           (unmanaged items, noise rules)
Activity         /activity             (jobs and action history)
  └─ Job         /activity/{jobId}
```

- Every page below Overview has a breadcrumb: `Overview › Replica › Intune › IntuneDeviceConfigurationPolicyWindows10 › Baseline - Win10`.
- Every number on Overview and on the workload page is a link to the filtered list it counts (for example "Drifted 12" opens the review queue filtered to that tenant and workload).
- URLs carry all filter state, so any view can be bookmarked or shared.
- A tenant switcher sits in the breadcrumb at workload level and below, so the same workload can be looked at in the other tenant in one click.

## Screens

### 1. Overview

```
┌ Blueprint "prod" v7 (accepted 2026-10-20) ─────────────── Last full check: 9 h ago · Last scan: 12 min ago ┐
│                                                                                                               │
│            MASTER  contoso.onmicrosoft.com                   REPLICA  contoso-dev.onmicrosoft.com              │
│            ●●●●●●●●○○ 94% aligned                           ●●●●●●○○○○ 71% aligned                            │
│                                                                                                               │
│ Workload    Managed  Aligned  Drifted  Excl.  Not chk     Managed  Aligned  Drifted  Excl.  Not chk          │
│ Entra ID       182      180        2      3       0          182      151       31      9       0            │
│ Intune          64       64        0      0       2           64       40       24      1       2  ⚠         │
│ Exchange        41       35        6      0       0           41       41        0      0       0            │
│ Teams           23       23        0      1       0           23       18        5      0       0            │
│ Other            9        9        0      0       0            9        9        0      0       0            │
│                                                                                                               │
│ [stacked bar per workload: aligned | drifted | not checked, master above replica]                            │
└───────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

- Two tenant columns with an overall aligned percentage, plus a workload matrix. Each cell is a link.
- Under the matrix, one horizontal stacked bar per workload and tenant (aligned, drifted, not checked). Excluded items are listed in the matrix but not in the bar, because they are outside the counts.
- A row with Not checked components shows a warning icon; hovering it gives the count and the failed component names.
- If the last full check is older than a threshold (default 36 h, mock setting), the timestamp turns amber with "full check overdue".

**Count definitions** (match `Get-PEStatus` in the plan, Task 8):

- *Managed:* blueprint items in the workload, minus excluded items.
- *Aligned:* managed items with no open drift.
- *Drifted:* distinct items with an open Missing, Changed, Target-only, Possible rename or Ambiguous finding.
- *Excluded:* unmanaged items plus excluded blueprint items. Never counted as aligned or drifted.
- *Not checked:* resource types whose export failed (count of types, not items).
- Target-only items count as drifted although they are not in the blueprint, so Drifted can exceed Managed − Aligned. The tooltip on Drifted says so.

### 2. Tenant workload

Header: tenant, workload, the same five counts, check ages, and two charts:

- a donut of drift by kind (Missing, Changed, Target-only, Possible rename, Ambiguous);
- a bar of drift per resource type (top 10, then "show all").

Below, a table of resource types: type, friendly name, items, aligned, drifted, excluded, status. Not checked types sit at the top with the export error. Clicking a row opens the resource type.

A **"Review drift in this workload"** button opens the review queue filtered to this tenant and workload.

### 3. Resource type

A table of every item of the type in this tenant and the blueprint: key (display name), status chip, drift kind, number of differing settings, last change seen, a checkbox for drifted rows, and Accept / Promote / Exclude buttons on every row the engine can act on (rows it cannot act on say why). Filters by status. A bulk action bar (Accept selected, Promote selected, Exclude selected) is always shown above the table and is enabled once rows are ticked. A row with a request in progress shows a small marker linking to its job and its actions are disabled until the job finishes.

### 4. Item detail

```
Overview › Replica › Intune › Device configuration (Windows 10) › Baseline - Win10           [Master | Replica]

Status: Changed · 3 settings differ · seen in full check 2026-10-21 02:00 (check 2026-10-21T0200)
[Accept (bring replica in line)] [Promote to master] [Exclude…]

Setting                      Blueprint (v7)          Replica
──────────────────────────────────────────────────────────────────────
PasswordMinimumLength        14                      8                ◀ differs
DefenderScanType             full                    quick            ◀ differs
Assignments                  Group: All Devices      Group: Pilot     ◀ differs
▸ 47 settings identical (show)
Unreadable: WiFiPreSharedKey (not compared)
```

- Side-by-side table; differing rows first and highlighted; identical rows collapsed; unreadable values listed but never shown as drift.
- Long values (arrays, nested hashtables) show as an inline diff.
- Tabs: **Settings** (above), **Raw** (both property bags as formatted JSON), **History** (actions and blueprint versions that touched this item), **Exclusions** (noise rules that apply).
- Target-only: only the tenant column. Missing: only the blueprint column. Possible rename: both halves with a "Possible rename of …" banner and a link to the other half.
- Next to each differing setting, an "Ignore this value as noise…" link that opens the exclude dialog pre-filled at property level.

### 5. Drift review

The work queue. A table of open findings across both tenants, grouped by tenant then workload, with filters for tenant, workload, kind, resource type and text. Columns: tenant, workload, type, item, kind, settings differing, first seen. Rows expand inline to show the differing settings without leaving the page. Per-row actions, row checkboxes and the bulk action bar work as on the resource type page; a bulk selection across both tenants becomes one request per tenant. A counter in the top bar shows the open total.

### 6. Blueprint

- Current version, when and why it was accepted, item counts per workload.
- **Pending master changes:** a panel listing what the latest master check found against the blueprint, with Accept / Promote / Exclude per item (the master rows of the actions table). Promoting here is how a master change is taken into the blueprint.
- Version list. Each version shows its change record (items added, changed, removed, reason, date), and whether it came from a promote or a revert. Older versions are read-only.
- **Compare** any two versions: the same added, changed and removed view as the revert dialog.
- **Revert to this version…** on every version but the current one (see "Revert the blueprint").

### 7. Exclusions

Two tables, each with reason and date and a **Bring back under management** action:

- Unmanaged items (tenant, type, key).
- Noise rules (type, property, value, optional item scope).

### 8. Activity

Every action request with status (Queued, Running, Succeeded, Failed), the items it covered, the generated config preview, and the re-check result. A running job shows progress in a slide-out panel reachable from the top bar on any page. In mock mode jobs move Queued → Running → Succeeded after a few seconds, and one mock job fails, so the failure state is designed and tested.

## Action flow

```
select item(s) → choose action → dialog
   ├─ lists every item and what will happen to it
   ├─ reason field (required for Promote and Exclude)
   ├─ generated config preview (any action that writes to a tenant; mock text in this scope)
   ├─ master-write warning + second confirm (when it writes to the master)
   └─ [Confirm] → request written → job appears in Activity → toast with link
```

The dialog never offers an action that is invalid for any listed item. Items made invalid since the page loaded (for example a newer check) are shown struck through with the reason.

## Data the GUI reads

**(my call)** The GUI does not parse DSC exports. A separate processing step (part of the engine work, out of this scope) turns engine output into view-model JSON files in one folder. The GUI reads only that folder, so it has no dependency on the module and starts fast. The 8 MB export takes minutes to parse; the view models are small. The folder defaults to `data/gui/` and is a startup parameter, so the GUI can point at the mock set instead.

```
<gui data root>/
  index.json                          blueprint summary, tenants, workloads, generatedAt
  tenants/<tenantId>/status.json      per-workload and per-type counts, check ages, not-checked list
  tenants/<tenantId>/findings.json    open and unmanaged findings (Finding shape + id, firstSeen)
  tenants/<tenantId>/items.json       every item in the tenant or the blueprint (itemId, type, key, workload, inBlueprint)
  tenants/<tenantId>/items/<itemId>.json   item detail: blueprint and tenant property bags, unreadable list
  blueprint/versions.json             version list with change records (op, resourceType, key, itemId)
  exclusions.json                     unmanaged items and noise rules (Decision shape)
  activity/<jobId>.json               written by the GUI's action stub (mock) or the engine (later)
  requests/<requestId>.json           written by the GUI only
```

Shapes follow the plan's "Shared types" (Record, State, Finding, Decision) and Task 8's status rows, with these GUI additions:

- `itemId`: a stable, URL-safe id derived from `ResourceType` and `Key` (for example `IntuneDeviceConfigurationPolicyWindows10~Baseline-Win10` with the key percent-encoded). Same id in both tenants, so the tenant switcher keeps you on the same item.
- `tenantId`: a short slug (`master`, `replica`) mapped to the real tenant name in `index.json`. The GUI never shows a tenant GUID.
- Each tenant entry has `role` (`Master` or `Replica`) because the actions depend on it.
- Friendly names per resource type (for example `AADConditionalAccessPolicy` → "Conditional access policy") live in `gui/ResourceTypes.json`, not in the data.
- Pending master changes are not a file: they are the master's open findings.
- `index.json` may carry `mockNow`, the clock the GUI uses for check ages, so the mock set never goes stale.

**Action request** (the only thing the GUI writes):

```json
{
  "requestId": "2026-10-21T10-14-03-a1b2",
  "requestedAt": "2026-10-21T10:14:03Z",
  "tenantId": "replica",
  "action": "Accept | Promote | Exclude | ExcludeProperty | Unexclude | RevertBlueprint",
  "items": [{ "itemId": "...", "resourceType": "...", "key": "...", "findingKind": "Changed", "property": null, "value": null }],
  "reason": "text",
  "confirmedMasterWrite": false
}
```

For `RevertBlueprint` the request also carries `targetVersion`; `items` is empty for a whole-blueprint revert, or holds the one item for an item restore.

Later, the action stub is replaced by calls to the engine scripts that read these requests. Until then the stub writes the request plus a mock job file and nothing else.

## Technical approach

**(my call)** Pode serves a JSON API and static pages; the pages are plain HTML, CSS and JavaScript with no build step.

- *Why not Pode.Web:* it builds pages from PowerShell and is quick for standard admin screens, but the side-by-side diff, inline-expanding review rows, paired rename rows and the two-step master confirm are custom layouts it would fight. Plain pages keep the design under our control and the PowerShell side small. Worth a one-day spike if the developer prefers it.
- Front end: one vanilla JavaScript file with a render function per screen and a small router on the URL paths above; no build step and no third-party code. The donut, rings and bars are drawn with CSS (`conic-gradient` and widths), which was enough, so Chart.js was dropped.
- Rules live on the server: `GET .../findings` adds `allowedActions` to every finding, and the page only shows those. Before a dialog opens, the page asks `POST /api/requests/preview` what the request would do (per-item effect, master write, new blueprint version, mock config), so effect texts and rules are written once, in PowerShell.
- Pode: listens on `http://localhost:8080` only. Routes: `GET /api/index`, `GET /api/resource-types`, `GET /api/tenants/{t}/status`, `GET /api/tenants/{t}/findings`, `GET /api/tenants/{t}/items`, `GET /api/tenants/{t}/item?id={itemId}`, `GET /api/blueprint`, `GET /api/blueprint/compare?from=&to=`, `GET /api/exclusions`, `GET /api/activity`, `GET /api/activity/active`, `POST /api/requests/preview`, `POST /api/requests`. Page URLs serve the app shell so deep links work. Every route passes straight to `Invoke-PEGuiApi` in `PEGui.psm1`, so the API is tested without Pode.
- The API reads files on each request (they are small) so a new processing run shows up on refresh without restarting.
- Mock jobs run as a Pode timer that advances job status (Queued, then Running after 1 s, then Succeeded after 4 s). Mock jobs do not change the view-model files; the item shows "awaiting next check" until real processing runs. No PowerShell module beyond Pode is imported.
- Version compares are computed by the server as the net change per item (added then removed again is no change), so the Compare screen and a Revert describe the same thing.
- Job numbering, blueprint version numbers and job files are written under a lock on the data folder, and files are replaced atomically, because Pode serves requests on several threads alongside the mock timer. Each Promote or Revert gets its own blueprint version number, even when several are queued before the blueprint is updated.
- `-Mock` copies `gui/mock-data` to `data/gui-mock` (git-ignored) on every start, so requests and jobs never touch the committed set.

Layout:

```
gui/
  Start-PEGui.ps1        -DataRoot <path> (default data/gui) -Port 8080 -Mock
  server.ps1             Pode server: routes and the mock job timer, nothing else
  PEGui.psm1             all server logic: reading view models, allowed actions, request validation, mock jobs
  ResourceTypes.json     friendly names and workloads per DSC resource type
  public/                index.html and assets/ (app.css, app.js)
  mock-data/             a complete fixture set (see below)
  tests/                 Pester tests for PEGui.psm1 and every API route, against mock-data
```

## Visual design

- Light theme first, dark theme later. Neutral background, one accent colour for links and primary buttons.
- Status palette, always with a label or icon:
  - Aligned: green, check icon.
  - Drifted: amber, triangle icon. Sub-kinds use the same amber with a kind label (Missing, Changed, Target-only).
  - Possible rename / Ambiguous: purple, question icon. Needs a person to look.
  - Not checked / Not available: grey, slash icon. Never green.
  - Excluded / Unmanaged: blue-grey, eye-off icon.
- Actions that delete or write to the master (Accept on Target-only, Accept on the master, Promote from the replica) use a red confirm button; everything else uses the accent colour.
- Dense tables (this is an admin tool), 14 px base font, sticky table headers, right-aligned numbers.
- Works from 1280 px wide upwards; below that the overview matrix scrolls horizontally rather than wrapping. A phone layout is not needed.

## Mock data

`gui/mock-data/` is a hand-made, realistic set that exercises every state the GUI must render:

- Two tenants (master and replica), blueprint v7 with earlier versions (one of them created by a revert) and pending master changes.
- All four workloads plus Other, with a few hundred items in total, so tables and charts look like the real thing.
- At least one of each finding kind in each tenant: Missing, Changed (one with an array diff, one with a nested hashtable), Target-only, Possible rename pair, Ambiguous, Not checked (with an export error), Not available, Unkeyed, Unreadable.
- A workload with Not checked components, so the disabled Accept and the warning are visible.
- Unmanaged items and noise rules; activity with succeeded, running and failed jobs.
- A full check that is overdue in one tenant.

The mock set is fake data. It contains no real tenant names, IDs or settings.

## Scope and phases

**This scope (GUI phase 1):** all eight screens, navigation, action dialogs, request files and mock jobs, mock data set, API tests. Done when:

1. `gui/Start-PEGui.ps1 -Mock` starts the server and every screen renders from `gui/mock-data/` with no other module loaded.
2. From Overview, every count links to the list it counts, and every item is reachable in at most four clicks.
3. Every row in the actions table above offers exactly the listed actions, and none on non-actionable kinds.
4. A master-write action cannot be submitted without the second confirm; a request file records `confirmedMasterWrite: true`.
5. Not checked is never shown green or counted as aligned.
6. Pester tests cover each API route and the request validation (invalid action for a finding kind is rejected server-side, not only hidden in the page).

**Phase 2 (later):** the processing step that writes `data/gui/` from engine output; replacing the action stub with calls to the engine scripts; real job progress.

**Phase 3 (later):** Entra sign-in, a dark theme, more workloads.

## Open questions

- **Exclude on blueprint items.** The engine's `Unmanaged` decision is defined for Target-only items. The GUI offers Exclude on Missing and Changed items too. Does the engine support excluding a blueprint item, or should Exclude only appear on Target-only (plus property-level noise everywhere)?
- **Accept on the master.** It writes to production. Should the GUI offer it, or only Promote and Exclude on the master?
- **Promote a replica Missing item.** That deletes the item from the master. Offer it, or leave only Accept and Exclude?
- **Engine support for revert.** The engine plan has no revert command (`Approve-PEBlueprintChange` only adds accepted changes). Whole and single-item revert need one before phase 2.
- **Thresholds.** How old a full check (and a scan) may be before it is flagged overdue.
