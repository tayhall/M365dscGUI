# Overview: tenants, drift and drill-down (design)

Date: 2026-10-26. Scope: the GUI (`gui/public/assets/app.js`, `app.css`, and the view-model data the pages already read). No change to the engine, DSC calls or blueprint logic.

## Intent

The person running the policy engine wants one holistic view of how the tenants are doing by drift, then to follow drift down: tenant, then workload, then resource type, then a single policy with its matching and drifting values side by side. Today the Overview shows tenant cards with only a ring or two, and the per-workload breakdown sits far down the page below "Check by resource type", so the first question ("which tenant is drifting, and where?") takes scrolling and several clicks to answer.

Success: from the Overview, in at most four clicks, they can reach any single policy and see every property of it, drifted values first and matching values available, without leaving the GUI. Tenants can be compared at a glance.

## Decisions made with the user

- **Alignment by workload moves above "Check by resource type"** on the Overview (the user's first request).
- **Tenant cards stay the default top view**, and each card carries a row of coloured workload cells inside it (the heat-map idea), so one card shows a tenant's identity, its drift figures and where the drift is.
- **A Cards / Compare toggle** above the tenant cards. Compare shows the same data as a matrix: tenants (one row per tenant and layer: against the master blueprint, against its own blueprint) down the side, workloads across, colour by share drifted.
- **Everything is clickable and drills down**: ring or tenant name opens the tenant; a workload cell opens that tenant's workload page; a Compare column header opens that workload across tenants; a bar or donut slice opens the drift list filtered to that workload or kind; a resource-type bar opens that type's page.
- **The single-policy view is a side-by-side table** of blueprint value and tenant value for every property, drifted rows first, with matching rows and a drifted/matching/all filter.

## Goals

1. Overview top: per-tenant card with ring, drift counts for both layers, last-check age, and a workload cell row (colour and number per workload; "not checked" is its own grey cell, never counted as aligned).
2. Compare view of the same data.
3. Alignment by workload placed above the resource-type card, bars clickable.
4. Workload page: keep the existing donut by kind and bars per type, and make slices and bars clickable (kind filter on the drift list, type page).
5. Item page: matching values are visible, not hidden. A filter (All N / Drifted N / Matching N) replaces today's "Show N identical" link; the default stays Drifted so a drifted policy opens on what differs.

## Non-goals

- No new data from the engine: counts and per-property values already exist in the view-model (`status.json` workloads and types, `findings.json`, `layer-findings`, `items/*`). See "Where the counts come from".
- No charting library. The page is dependency-free (see `gui/README.md`); rings are `conic-gradient`, bars are divs, as today.
- No change to actions (Review, Revert, Promote, Exclude) or their rules.
- No drift-over-time or history charts (not asked for).

## Anti-goals

- Colour must never be the only signal: every cell and bar also shows its number, and "not checked" must stay distinguishable from "aligned" (the existing rule that unchecked items are never shown as aligned).
- Must not make a drifted tenant look healthy by averaging: a cell's colour comes from the share drifted of what was checked, and a workload with nothing checked is grey.

## Constraints

- Vanilla JS, no build step, no third-party code; must keep working in `-Mock` mode and pass `gui/tests` (including `Assets.Tests.ps1`).
- Existing accessibility pattern: `aria-label`/`role="img"` text for graphics, links as `data-link`, keyboard reachable.
- Works with one tenant and with many: Compare is the view that scales; cards wrap.
- Excluded items stay outside every count, as the page text already says.

## Mockups

Layout mockups agreed in the session: `.superpowers/brainstorm/3645-1793022740/content/combined-drilldown.html` (git-ignored; the four steps: Overview cards and toggle, workload alignment, workload page, single policy). Numbers in them are made up.

## What already exists (so the builder does not rebuild it)

- `overview()`, `tenantCards()`, `layerRing()`: tenant cards with rings (`app.js` around 470-535).
- `workload()`: donut by kind and bars per type. `typePage()`: item list with filters. `itemPage()`: a Settings tab with a Setting / Blueprint / Tenant table, differing rows first, and a "Show N identical" toggle.
- The remaining work is mainly the Overview layout and Compare view, click-throughs, and the filter on the item page.

## Where the counts come from

Checked against the mock data: `status.json` workload counts (managed, aligned, drifted, notChecked) describe the tenant against **its own blueprint** only, and `meta.layers` has only whole-tenant totals per layer. Per-workload drift against the **master** blueprint is derived on the client from `layer-findings?layer=<master>` (each finding carries its `workload`), loaded on demand as the page already does for the Drift review. Consequences:

- Card cells follow the card's headline layer: against the master blueprint when the tenant has one (the first ring), otherwise against its own. A small label on the cell row says which.
- The number in a cell is the drifted count. Colour is the drifted share of the tenant's managed items in that workload (`managed` from `status.json`). For the master layer this denominator is the tenant's managed count, an approximation; the cell's tooltip says "of N managed".
- A workload with nothing checked is grey and shows "n/c".
- Compare has one row per tenant and layer (own-layer rows from `status.json`, master-layer rows from `layer-findings`).
- A click from a master-layer cell carries the layer: it opens the workload page or Drift review with `layer=<master>`, as `path.drift` already supports. The workload page itself shows own-layer counts unless a layer is given; if that proves awkward, open the Drift review filtered by workload and layer instead.
- No engine or view-model change is needed.

## Left to the builder

- Colour thresholds for cells (suggest: 0 drifted = green, up to 10% amber, up to 30% orange, above red; grey for not checked) and the exact palette, which must pass contrast in the existing theme.
- Whether the Compare toggle is remembered (suggest: in `ui` state like other view choices).
- Cell and card sizing, responsive wrapping, and the order of tenants.
- Slice, bar and segment click targets (suggest: the donut slice opens the drift list with `workload` and `kind`; each segment of an alignment bar links on its own, with "not checked" opening the not-checked components).
- Whether Compare and the cards follow the tenant switcher (suggest: both show all tenants and highlight the selected one).
- Where a cross-tenant "this workload across tenants" page lives; if it needs a new route, say so and keep it a thin page over existing data, or open the Drift review filtered by workload instead.

## My calls (not discussed with the user)

- Default item filter is Drifted; Matching rows shown via the filter, not by default.
- Thresholds above are a starting suggestion.
- Compare rows use one row per tenant and layer, matching the two checks the cards already show.
- Card cells follow the headline layer, and the master-layer denominator is the tenant's managed count (see "Where the counts come from").
- The four-click goal applies to the card path; a Compare column header may end at the Drift review filtered by workload.
- Scale: the user expects about 6 tenants, not tens or hundreds. Cards stay the default (about 3 per row, two rows) and Compare is the side-by-side view; no paging, search or grouping is needed.
