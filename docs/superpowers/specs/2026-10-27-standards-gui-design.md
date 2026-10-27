# Standards in the GUI

Date: 2026-10-27. Status: draft for approval. Builds on `docs/superpowers/specs/2026-10-27-standards-blueprints-design.md` (the engine, merged) and the approved mock-ups `docs/gui-mockups/standards.html` (open in a browser; four screens, example data).

## Intent and why

The engine can import a standard, check a tenant against it, accept a risk and promote settings into a blueprint, but only from the command line. People who use the GUI need to see how much of a standard a tenant meets, decide on each difference, and read what could not be checked, without leaving the GUI. The GUI is where the decisions get made; the engine stays the single place that does the work.

## What is built (the approved design)

Four screens, as in the mock-ups, plus the plumbing behind them:

1. **Standards** (`/standards`): the loaded standards (source, version, licence, attribution), the selected tenant's latest check against each (the "Checked N of M" headline, a coverage bar, a per-workload table), how many settings the tenant's blueprint has adopted, an "Import a standard" button, and a banner when a newer upstream release is known.
2. **Check against a standard** (`/standards/<name>`): the differences of the selected tenant, each with what the standard says and what the tenant has. Statuses: Differs, Missing, Accepted (who approved it and why), Look again (accepted, but the standard has since changed). Filters: Needs a decision, Accepted, All differences. Per row: **Adopt** and **Accept risk** (plus **Remove** on an accepted row). A **Check again** button.
3. **Not covered** (`/standards/<name>/not-covered`): the items the engine left out of the standard, by reason (Placeholder, Unknown property, Unkeyed), with the detail.
4. **Accept risk dialog**: setting, standard value, tenant value, "Approved by", "Why", and the line that this is a note kept next to the check, not a risk register.

Behaviour decided with the mock-ups:

- The standard-to-blueprint action is called **Adopt**, because Promote already means tenant to blueprint.
- Adopt and Accept risk follow the Selection list rule of Revert, Promote and Exclude: clicking adds to the list; nothing changes until the list is run. Remove (an accepted risk) acts at once, as Unexclude does.
- Accepted has its own status colour (teal), next to the existing green, amber, purple, grey and blue-grey.
- To change a tenant after adopting, the person uses Revert on Drift review as today. The Standards page never writes a tenant.

## Goals

1. Export view models for standards (index, per-tenant check, coverage) from `Export-PEGuiData`, from the latest `Kind = 'Standard'` check of each tenant, as atomic JSON files next to the existing ones, and serve them through new read-only API routes.
2. Add the requests the worker needs, each calling the engine command that already exists: `StandardCheck` (`Invoke-PEStandardCheck`), `Adopt` (`Copy-PEStandardItem`), `AcceptRisk` (`Set-PERiskAcceptance`), `RemoveRisk` (`Remove-PEDecision -Kind RiskAccepted`), `ImportStandard` (import a release) and `CheckStandardRelease` (find the latest upstream tag). Validation, preview text, reason rules and the master-write confirmation work as they do for the existing actions.
3. Add the four screens to the front end, the Standards item in the navigation, and the new actions in the Selection list (grouping, effect text, run order, export).
4. Keep the engine as the one implementation: the GUI code reads view models and queues requests; it does not recompute coverage, compare, or hold rules the engine owns.
5. Document the new files, routes and requests in `gui/README.md` and `docs/overview.md`.

## Non-goals (for now)

- No editing of a standard, no per-tenant values for placeholders, no display or editing of control IDs, no history list of standard checks (the latest per tenant and standard only).
- No scheduled standard checks (Register-PESchedule stays CLI), and no standard check for an offline (uploaded snapshot) tenant: the Check button is disabled for it with a reason.
- No Revert or apply from the Standards page; it never writes a tenant.
- No CIS or NIST content (still no DSC-format source) and no second standard beyond what `Import-PEStandard` already supports; the screens are built for several standards, with ASD the only one that exists.
- No new front-end framework, build step, external font or network call from the browser.

## Anti-goals (a failure even if it works)

- Showing a setting that was not checked as passing: not covered and not readable are always separate from "match" and never merged into it.
- An accepted risk that disappears from view: it stays listed with who approved it and why, and it reopens as "Look again" when the standard changed.
- Adopt writing the master blueprint without the same two-step confirmation Promote needs, or a replica with no blueprint of its own adopting into the master blueprint.
- GUI-side re-implementation of the engine (coverage maths, subset comparison, hashing of the standard record).

## Constraints

- Thin wrapper (`CLAUDE.md`): the worker and API call the engine's public commands; no copy of DSC or engine logic. Resolving the latest upstream tag and cloning it moves from `tools/Import-PEStandard.ps1` into a module function so the tool and the worker share it (a refactor with its tests, no behaviour change).
- Follow the GUI's patterns (`gui/README.md`, `docs/gui-handoff.md`): view models are JSON files replaced atomically; the browser reads `/api/...`; actions are queued requests (`requests\`, `activity\J-*.json`) processed by the worker; the Selection list lives in the browser's local storage per blueprint and the server re-checks everything when it runs; startup token and Host header checks stay as they are.
- Offline Pester tests with fake data for everything on the PowerShell side (`tests/GuiExport.Tests.ps1`, `tests/GuiRequest.Tests.ps1` style). The front end has no automated tests today: it is verified in a real browser against a seeded data folder (Playwright is available), and the steps are written down.
- Light and dark themes must both work, as for the existing pages; keep the colour tokens of the mock-up.
- The Windows path limit and "files from the internet are only parsed, never run" rules of the engine design apply to the import request.
- Record deliberate gaps in `docs/handover.md`.

## Decided by the user

- The four screens, their content, the names (Adopt, Accept risk, Look again, Not covered), the Selection list behaviour and the teal Accepted colour, as shown in the approved mock-ups.
- The banner "a newer release is available" and the "Import a standard" button are part of the design.
- Engine and command line first, GUI second (done: the engine is merged).

## My calls (to check while reading)

- View-model files: `standards/index.json`, `standards/<name>/coverage.json`, `tenants/<id>/standards/<name>.json`; routes `/api/standards`, `/api/standards/<name>/coverage`, `/api/tenants/<id>/standards/<name>`. The rows carry `itemId` (the existing `ConvertTo-PEGuiItemId`), `allowedActions` (`Adopt`, `AcceptRisk`, `RemoveRisk`) and the engine's own words (kind, state, hint), so the front end only displays them.
- "Match" in the headline is `Checked` minus the items that are Missing or Changed (open or accepted); it is worked out at export from the check document, never in the browser.
- Adopt targets the tenant's own blueprint (the last in its list, as Promote does); the master tenant's own blueprint is the master blueprint, so it needs the master-write confirmation, and a replica without a blueprint of its own is refused. Adopt carries a reason (like Promote). It carries no `expectedVersion`: what is reviewed is the standard's value, which Adopt overwrites with the standard's own, so a changed blueprint does not make the review stale. The worker reads the blueprint's latest version at run time and passes it to `Copy-PEStandardItem`, which still refuses if the blueprint moves in between.
- Accept risk takes `approvedBy` and `why` per item (collected in the dialog when the item is picked and kept with the queue entry); it has no request-level reason. It records for the tenant of the request, against the standard of the page, optionally for one property.
- The new item-level actions are validated by a new function beside `Get-PEGuiRequestPreview` and called from its top, so the long existing function is not modified for them.
- The front-end code for the four screens goes in a new file `gui/public/assets/standards.js`; `app.js` gets only the hooks (route, navigation, selection list, dialog host).
- The release banner reads a small file the worker writes when `CheckStandardRelease` runs (`git ls-remote`, no clone); nothing in the browser or the export touches the network.
- Run order of a selection list: exclusions and accepted risks first (cheap decisions), then blueprint changes (Promote, Adopt), then Revert.

## Left to the builder

- The exact JSON field names beyond those above (follow the style of the existing view models), the CSS, the wording of effect text and error messages (plain and short, like the existing ones), and how the standards page reads the selected tenant from the existing top bar.
- How the dialog and the queue entries carry `approvedBy`, `why` and `property` (the queue entry shape is local to the browser).
- Where in `Export-PEGuiData` the new section sits and how its failures are reported (a standard that cannot be read must not stop the rest of the export; it is a warning, as for layers).
- The demo and seeding tools for the browser check.

## Success

A person opens Standards, sees ASD v1.4.0 with "Checked 87 of 133" for the master tenant and the split of what was not checked, opens the check, adds three differences to Adopt and one to Accept risk (entering who approved it and why), runs the Selection list, and sees the blueprint at a new version with the three settings (provenance kept), the three rows marked Adopted, and the accepted risk shown as Accepted with its approver, all without reading the tenant again. The adopted rows still differ from the tenant until the person reverts them on Drift review and checks again; then they match. After importing a newer release, the accepted risk whose standard value changed shows as Look again.

## Rulings from the builder check (my calls)

- **One request per group, one write per request.** The Selection list groups entries by action, tenant and standard, as it groups by action and tenant today. One Adopt request carries all its items and makes one `Copy-PEStandardItem` call (one blueprint version). Groups run one after another, so an Adopt and a Promote for the same blueprint each write their own version.
- **Queue entries carry their tenant and standard.** The list stays keyed by blueprint, in the same list as Drift-review entries; each Standards entry adds `standard` (and, for Accept risk, `approvedBy`, `why` and optional `properties`). Switching the tenant in the top bar does not clear the list; the list page shows the tenant of each entry.
- **A row is one resource instance.** Its view-model entry lists the differing properties (`property`, `standard` value, `tenant` value; the engine's Blueprint and Target are renamed at export). Adopt copies the whole item as the standard states it. Accept risk is for the whole item by default; when a row has several differing properties the dialog lists them with a checkbox each, and a partial selection writes one decision per ticked property.
- **ImportStandard** takes `standard` (a name the engine supports; `asd`) and an optional `tag` (default: the latest release). It has no tenant, goes through the same request and activity journal, needs no confirmation (it only adds an immutable version of a read-only standard; older versions are kept, so "Look again" keeps working), and shows as a running job on the Standards page. **CheckStandardRelease** takes `standard`, runs `git ls-remote` only, and writes `data\sources\<name>-latest.json`.
- **StandardCheck** takes `tenantId` and `standard`, does a live Reader-app export through `Invoke-PEStandardCheck` as `Recheck` does, and is shown as a running job the same way. Its button is disabled, with the reason, for an offline tenant, a tenant the Reader app is not connected to (the same rule as Recheck), and when no version of the standard is imported.
- **Numbers per tenant.** `standards/index.json` holds each standard's metadata, versions and `latestRelease`. The Standards page also loads `tenants/<id>/standards/<name>.json` for the selected tenant: headline numbers, per-workload table, adoption count, rows. A tenant with no check yet gets a file with `checked = false`, shown as "Not checked yet" with the Check button. `coverage.json` is the standard's own not-covered list for its latest version, not tenant-specific.
- **Look again comes from the engine.** `Compare-PEState` marks a finding whose accepted risk went stale with `AcceptanceStale = $true` (a small engine change with a test); the export maps it to the status Look again. The GUI never compares hashes.
- **After a run, the check updates at once without reading the tenant.** After Adopt, Accept risk or Remove, the worker re-compares the saved standard check with the standard and the current decisions and saves the result as a patched Standard check (`Meta.PatchedFrom`), as is done after a Promote. Adopted rows show an "Adopted" chip (from `Get-PEStandardAdoption`) and stay in "Needs a decision" while the tenant still differs, with the note that Revert on Drift review changes the tenant.
