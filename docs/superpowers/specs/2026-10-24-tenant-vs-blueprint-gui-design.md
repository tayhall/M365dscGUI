# GUI: each tenant against its blueprint layers

Date: 2026-10-24. Status: draft for approval.

## Intent and why

The main job of the GUI is to show, for any tenant, how it has drifted from the
blueprints it follows, and to let people move changes between tenants and
blueprints on purpose. Two situations drive this:

- **Dev as a proving ground.** Changes are tried in a Dev tenant. Good ones are
  promoted into the Dev blueprint and then into the master blueprint. Bad ones
  are reverted and Dev goes back to where it was.
- **Production changes all the time.** People edit production directly. Those
  changes are accepted into the master blueprint. Dev then needs to catch up so
  it stays representative of production.

Today the GUI has one global blueprint, no per-tenant context, no clear
"selected tenant", messy long text, and no way to rename a tenant outside the
connect form. The GUI review (read-only, 2026-10-24) found these in
`gui/public/assets/app.js`, `app.css` and `gui/PEGui.psm1`.

## The model (decided)

1. **One rule: a tenant is only ever written from its own blueprint.** No
   action applies the master blueprint directly to a tenant.
2. **Two layers now:** the **master blueprint** and the **tenant blueprint**.
   Production's tenant blueprint is the same blueprint as the master blueprint,
   so its two panels show identical numbers.
3. **Layers are an ordered list per tenant.** Store each tenant's blueprints as
   an ordered list (master first, tenant-specific last) so a regional layer
   (Global, then European, then country) can be added later by adding to the
   list. Only two layers get screens and tests now. UI wording says "layer".
4. **Three moves**, all explicit and logged as jobs:
   - **Promote (tenant to its blueprint).** A change in the tenant is taken into
     its tenant blueprint. Also how Production's direct changes are accepted.
   - **Promote up / Pull down (blueprint to blueprint).** Promote up takes an
     item from the tenant blueprint into the master blueprint. Pull down takes
     an item from the master blueprint into the tenant blueprint. Neither
     touches any tenant.
   - **Apply / Revert (blueprint to tenant).** Brings the tenant back in line
     with its own tenant blueprint only. Existing apply/revert machinery is
     reused.
5. After a promote or pull down, the affected tenants show drift against their
   own blueprint. Aligning them is a separate, deliberate Apply.

## Screens

### Global selected tenant

- The selected tenant is chosen in the top bar and kept in the URL
  (`?tenant=<slug>`) and in browser storage, so reload and links keep it.
- Every page shows a context strip: tenant name, role, the layers it follows
  with versions, and its alignment.
- Pages show the tenant's friendly name. The role (Master/Replica) is a badge,
  not the label. (Today `role(t)` appears about 20 times as the label.)

### Overview (Option A, chosen from mockups)

- Header card: tenant friendly name, role badge, slug and domain, the layers it
  follows with versions, last full check time. **No rename here.**
- Two panels side by side, both worded only as "drifted" (we do not know why an
  item differs, so no "experiments" or "backfill" labels):
  - **Against its own blueprint** (for example Dev v3): count drifted, count
    aligned, breakdown (changed, missing, extra). Actions: Review, Promote to
    the tenant blueprint, Revert (apply the blueprint to the tenant).
  - **Against the master blueprint** (for example Production v6): count
    drifted, count aligned, breakdown. Actions: Review, Update tenant blueprint
    (pull down). No action writes to the tenant.
- Below the panels: a table of all tenants with drift against each layer and
  last check. Each row links to that tenant.
- The existing workload bars, scopes and per-type checks stay for the selected
  tenant. "Check by resource type" collapses unless something has drifted.
- For Production (tenant blueprint is the master blueprint) the two panels show
  the same blueprint and the same numbers.

### Tenants page (rename lives here only)

- Each tenant row gets an inline rename of the friendly name (`DisplayName`,
  maximum 80 characters, same rule as `PEGui.psm1:432`). The slug stays
  immutable and is shown beside the name.
- Rename applies to the Master tenant too.
- Rows also show alignment and drift counts and link to the Overview.
- Backend: a small `RenameTenant` GUI action that calls `Set-PETenant -Slug
  -DisplayName` (it already updates in place and keeps TenantId) and then
  refreshes the exported GUI data. It writes to no tenant. Fix
  `Export-PEGuiData.ps1:95` so `-TenantDisplayName` does not override the stored
  name for the Master.
- The blueprint name stays an immutable folder name. No blueprint rename.

### Long-text and spacing fixes

- Root cause: grid children do not shrink. Add `min-width:0` on grid children,
  a truncate-with-tooltip class, and a wrap class for prose.
- Item keys wrap over two lines with a tooltip. IDs, domains, thumbprints and
  paths truncate with a tooltip and a copy button.
- Setting values are clipped for display with the full value on hover or in an
  expandable block.
- Replace the 900-1180px minimum-width tables with column budgets and fewer
  columns on the Drift page. Below about 900px, rows stack as cards.
- One spacing scale as CSS variables, replacing the roughly 30 inline styles.
  Fix the duplicate `.tabs` rule and the oversized `.cards2` minimum.
- Confirm each problem visually (screenshots) before and after.

## Goals

- Anyone can see, for the selected tenant, how it differs from each layer it
  follows, and act on it.
- The blueprint-to-blueprint and blueprint-to-tenant moves are explicit and
  safe, with the existing confirmation rules for anything that writes to a
  tenant.
- Adding a third layer later needs data and screen additions, not a redesign.

## Non-goals

- Screens for more than two layers, or a regional layer.
- A side-by-side tenant A versus tenant B view.
- Renaming blueprints.
- A one-click "revert everything" for a whole tenant (stays per scope).

## Anti-goals (failure even if it works)

- Any path that writes the master blueprint's content straight to a tenant.
- Reimplementing DSC logic. This stays a thin layer over Microsoft365DSC
  (see `CLAUDE.md`). Blueprint moves operate on our own blueprint files and
  existing compare results; tenant writes go through the existing apply.
- Layer-specific wording or data shapes that hard-code exactly two layers.

## Constraints

- Thin wrapper principle in `CLAUDE.md`; deliberate gaps recorded in
  `docs/handover.md`.
- Existing GUI is vanilla JS/CSS served by `gui/PEGui.psm1`. Build on it; no
  framework change.
- Live writes to the test tenant and merging to main are covered by the project
  memory authorisations; anything beyond that needs asking.

## Left to the builder

- Exact data shape for the ordered layer list and where it is stored (a field
  on the tenant record in `tenants.json` is the likely place).
- How "Pull down" and "Promote up" pick and copy items between blueprint
  folders, reusing existing blueprint and compare code.
- Visual styling, copy, and the spacing scale values.
- Whether the per-tenant data export (`Export-PEGuiData`) is extended to emit
  drift against each layer, or the comparison runs per layer on demand.
- Test approach and delivery order. A sensible order: long-text fixes, global
  selection and context strip, rename, Overview panels, then the blueprint
  moves.

## Facts from the existing code

- Blueprints are already immutable, numbered versions, each with a reason and an
  accepted-at record (`Blueprint.ps1`, `Export-PEGuiData.ps1`). Version numbers
  in the UI ("Dev v3") are these.
- `Compare-PEState` takes any blueprint object and already handles a different
  tenant from the blueprint's own (`-CrossTenant`, tenant-bound properties).
  `Export-PEGuiData` takes a single `-BlueprintName`, so drift against a second
  layer needs the export (or an on-demand check) to run per layer. That is
  backend work, not only GUI work.

## Rules for the moves (writer's calls, please check)

- **Layers are full blueprints, not overlays.** A tenant blueprint is a complete
  blueprint of its own, created as a copy of the master blueprint's latest
  version. Layering later is a decision for then; the ordered list only records
  which blueprints a tenant follows.
- **Every blueprint move writes a new version** of the target blueprint with a
  reason, using the existing crash-safe writer. Nothing edits a version in place.
  Undo is a later move that restores earlier content, not a special feature.
- **Granularity is the item (type plus key)**, the same unit as today's findings,
  with bulk selection on top. Promote takes the tenant's side: a tenant-only item
  is added to the blueprint, a changed item takes the tenant's values, and an
  item that is in the blueprint but missing from the tenant is removed from the
  blueprint. Pull down does the same from the master blueprint into the tenant
  blueprint.
- **Preview and confirm every blueprint move.** It lists what will be added,
  changed and removed. The move is refused if the target blueprint has a newer
  version than the one the review was based on (stale check); the user re-checks
  and tries again.
- **Production's layer list is just the master blueprint.** Its two panels show
  the same blueprint and the same numbers, with a note saying so. Pull down is
  disabled for it. Promote and Promote up are one and the same operation there.
- **One tenant blueprint per tenant for now.** Several tenants following one
  shared blueprint is for the layered future; the list design allows it.
- **The panel Revert** opens the existing scope picker with every drifted item
  pre-selected. It keeps today's per-scope behaviour and confirmations.
- **Migration:** the current blueprint becomes the master blueprint. The master
  tenant's layer list is `[master]`. Each existing replica gets a tenant
  blueprint created as a copy of the master blueprint's latest version, so it
  starts with no drift against its own blueprint.
- **Roles:** Replica is the Dev-style role; the badge keeps Master/Replica.
- Labels: "Update tenant blueprint" (pull down), "Promote to tenant blueprint",
  "Promote to master blueprint".
- Delivery order as above.
