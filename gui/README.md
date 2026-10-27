# Drift engine GUI (Pode)

Phase 1 of the web GUI described in `docs/superpowers/specs/2026-10-21-pode-gui-design.md`: every screen, the
action dialogs and the request files, running on a fake data set. Nothing here talks to a tenant or to the
`PolicyEngine` module.

## Run it

```powershell
Install-PSResource -Name Pode -Scope CurrentUser   # once; 2.12 or later
./gui/Start-PEGui.ps1 -Mock                         # http://localhost:8080
```

**Access.** The server only answers localhost host names and carries a per-run token: Start-PEGui prints an address like `http://localhost:8080/?token=...`; open it once and the browser keeps the token in a cookie. Requests with another host name, another origin or no token are refused (401/403), so a web page or another process on the machine cannot drive it. `-Token` fixes the token for scripted use.

`-Mock` copies `gui/mock-data` to `data/gui-mock` (git-ignored) on every start, and serves that. Without `-Mock`
it serves `data/gui`, which the engine's processing step will write in phase 2.

## Test it

```powershell
Import-Module Pester -RequiredVersion 5.7.1
Invoke-Pester -Path gui/tests -Output Detailed
```

The tests cover the server logic and every API route through `Invoke-PEGuiApi`, without starting Pode.

## How it fits together

| File | What it does |
| ---- | ------------ |
| `Start-PEGui.ps1` | Checks for Pode, picks the data folder, starts `server.ps1`. |
| `server.ps1` | Pode routes and the mock job timer. Every API route passes the request to `Invoke-PEGuiApi`. |
| `PEGui.psm1` | All server logic: reads the view-model files, works out `allowedActions` per finding, previews and validates action requests, writes `requests/` and `activity/`, advances mock jobs. |
| `ResourceTypes.json` | Friendly names and workloads per DSC resource type. |
| `public/` | The page: `index.html`, `assets/app.css`, `assets/app.js`, and `assets/heat.js` (the pure colour and count helpers of the Overview heat cells, tested with node by `tests/Heat.Tests.ps1`). No build step, no third-party code. |
| `mock-data/` | The fake data set: two tenants, every finding kind, blueprint v1 to v7, exclusions, a few jobs. |

Rules (which actions a finding allows, what each action does, when the master confirm is needed) are written once,
in `PEGui.psm1`. The page shows what `/api/requests/preview` returns and the server re-checks every request.

## Connecting it to the engine (phase 2)

```powershell
# 1. After a full check, write the view models from the engine output (data/gui by default)
Import-Module ./src/PolicyEngine/PolicyEngine.psd1
Export-PEGuiData -BlueprintName demo -TenantDisplayName <name>
# 2. Serve them, and process the requests the GUI queues (two terminals)
./gui/Start-PEGui.ps1
pwsh -NoProfile -File tools/Start-PEGuiWorker.ps1 -BlueprintName demo
```

The **Re-check now** button (top bar) queues a Recheck job: the worker reads the tenant again with the Reader app (a full check scoped to the resource types the blueprint holds), rewrites the view models, and the page reloads its data when the job finishes. Drift then appears in Drift review, where Accept is the rectify step. The worker prints each job as it runs.

The worker (`Invoke-PEGuiRequest`) also runs: Exclude, Noise rules and Unexclude (decisions); Promote (a blueprint-only
change of the tenant's own blueprint from its latest full check); PromoteUp and PullDown (items moved between the tenant
blueprint and the master blueprint, with the reviewed target version); RenameTenant (the friendly name only); and **Accept**, which restores the tenant to the approved
blueprint with `Invoke-PERectify` (Create for Missing, Update for Changed, Remove for Target-only) using the Writer
app, then re-checks the same objects with the Reader app. Accept needs the GUI's two-step master-write confirm. After
a clean re-check the worker saves a patched copy of the check (`Meta.PatchedFrom`) so the GUI shows the items
aligned; run a full check to refresh everything. A blueprint restore (`RevertBlueprint`) runs `Restore-PEBlueprintVersion`.
The Overview lists the master and any number of replicas. `firstSeen` is the check time and
blueprint versions are labelled Initial, Promote or Restore (stored as Initial, Accept and Revert).

### Offline tenants: upload and generate

A tenant the tool cannot reach is registered from the **Tenants** page ("Offline tenant (upload files)") or gets a newer snapshot through **Upload newer snapshot** (Overview, top bar, Tenants list). The form reads the files in the browser, checks that each one carries the pinned Microsoft365DSC version in its first line (the server also checks the `Import-DscResource` line) and lists the workloads it finds (by the engine's workload prefixes, `workloadPrefixes` in `index.json`), each with a "these files are complete" tick (a type with no records is then really empty; otherwise it is NotChecked). The first upload can be saved as the tenant's own blueprint. Recheck buttons are not shown for an offline tenant.

**Generate configuration** (top bar, tenant page, Tenants list; disabled until the tenant has its own blueprint) queues a `GenerateConfig` job. When it succeeds, the Activity page links `Changes.ps1`, `Removals.ps1` (only when something is to be removed) and `Manual.json`, and lists the items that need manual action. Nothing is written to a tenant. See `docs/handover.md`, "Offline snapshots".

New request actions (`POST /api/requests`, run by the worker):
- `UploadSnapshot`: `tenantId`, `files` (1 to 50 of `{ name, text }`), `tenantDomain`, `completeWorkloads`, `saveAsBlueprint`, and `newTenant` (`{ slug, displayName }`) for a tenant that is not registered yet. Only a queued upload can be cancelled.
- `GenerateConfig`: `tenantId` of any tenant other than the master that has its own blueprint (offline or connected; the page offers the button for offline tenants). Accept (Revert) is not offered, and is refused, for an offline tenant.

New route: `GET /api/jobs/:jobId/config/:file` serves `Changes`, `Removals` or `Manual` of a Succeeded GenerateConfig job as a download (`<jobId>-<file>.ps1` or `.json`). Anything else, a job of another action or an unfinished job is a 404. The files live in `<GuiRoot>\configs\<jobId>` and are never pruned.

### Scopes

```powershell
Set-PEScope -Name ca-policies -Types AADConditionalAccessPolicy -Description 'Conditional Access policies'
Set-PEScope -Name groups-sg  -Types AADGroup -Keys 'sg-*' -Description 'Role-style groups'
Export-PEGuiData -BlueprintName demo -TenantDisplayName <name>     # the Overview now lists both
pwsh -NoProfile -File tools/Register-PEScopeSchedule.ps1 -BlueprintName demo -Scope ca-policies -EveryMinutes 60
```

Each scope has a **Check now** button on the Overview; it re-reads only its own types (about 20 seconds for these two).
See `docs/handover.md`, "Scopes and scheduled scope checks".
### Demo on a dummy tenant

```powershell
pwsh -NoProfile -File tools/PEDemoTenant.ps1 -Action Setup      # PE-DEMO-* groups and a report-only CA policy
pwsh -NoProfile -File tools/Export-M365DscTenant.ps1 -Workloads AADGroup,AADConditionalAccessPolicy -OutputPath data/exports/demo-baseline
pwsh -NoProfile -File tools/New-PEBlueprint.ps1 -Name demo -ExportPath data/exports/demo-baseline   # the approved blueprint
pwsh -NoProfile -File tools/PEDemoTenant.ps1 -Action Drift      # edit, disable, delete, add
# full check on the same types, Export-PEGuiData, start the GUI and worker, Accept the four items
pwsh -NoProfile -File tools/PEDemoTenant.ps1 -Action Cleanup    # when finished
```

Checked on real Pode 2.14: JSON posts arrive parsed, deep links serve the app shell, no console errors.
Known gap: no user sign-in yet. The server checks the Host header, the origin and a startup token, but keep it on localhost.

## Not done yet

- User sign-in (for example Entra ID).

## Blueprint layers

Each tenant in `index.json` has `layers`: the blueprints it follows, master blueprint first, the tenant's own last
(`name`, `version`, `role` master/tenant/layer, `sameAsOwn`, `checked`, `problem`, and `drifted`, `aligned`, `changed`,
`missing`, `targetOnly` counted from the tenant's latest Full check against that blueprint). A tenant with no stored
list has one layer, the master blueprint. `tenants/<id>/findings.json` holds the findings against the tenant's own
blueprint; for every other layer `tenants/<id>/layers/<blueprint>/findings.json` holds the same rows, each with its
`layer`. A tenant never checked, or a layer whose blueprint cannot be read, has `checked: false`.

## Standards

The Standards pages (design: `docs/superpowers/specs/2026-10-27-standards-gui-design.md`; mock-ups: `docs/gui-mockups/standards.html`) show how a tenant compares with a published standard (the ASD Blueprint for Secure Cloud first). They only read what the engine exports; the server decides what each row allows.

**View models** (written by `Export-PEGuiData`, camelCase JSON):
- `standards/index.json`: the standards (source, licence, attribution, imported `versions`, `latestRelease` from `data\sources\<name>-latest.json` when the worker looked).
- `standards/<name>/coverage.json`: what could not be covered in the latest version (`byReason`, `rows` with `reason` and `detail`).
- `tenants/<id>/standards/<name>.json`: the tenant's latest check: `headline` (`total`, `covered`, `checked`, `match`, `differ`, `accepted`, `lookAgain`, `notReadable`, `notCovered`), `byWorkload`, `adoption`, and `rows` (`status` differs, missing, lookAgain or accepted; `state` Open or Accepted and `firstSeen`, the fields of a Drift review row; `differences` as `property`, `standard`, `blueprint`; `adopted`; `allowedActions`), `blueprint` (`name`, `version` of the blueprint that was compared). `{ checked: false }` when there is no check yet.

**Routes** (GET): `/api/standards`, `/api/standards/:name/coverage`, `/api/tenants/:tenantId/standards/:name`. Page URLs: `/standards` and `/standards/:name/not-covered` (`?reason=`). The differences are not a page of their own: they are the Drift review (`/drift?tenant=&layer=standard:<name>&workload=`), where the standard is one more choice in Compared with, next to the master blueprint. Its rows have the same filters (workload, kind, search), expand and layout; the buttons are Adopt, Accept risk and Remove instead of Revert tenant, Promote and Exclude, and they add to the same Selection list.

**Request actions** (`POST /api/requests`, run by the worker; none writes a tenant):
- `StandardCheck` (`tenantId`, `standard`): `Invoke-PEStandardCheck` compares the tenant's own blueprint with the standard. Nothing is read from the tenant (a tenant is managed against its blueprint), so it works for an offline tenant and is quick.
- `Adopt` (`tenantId`, `standard`, `reason`, `items`): `Copy-PEStandardItem` into the tenant's own blueprint, one version per request; the master blueprint needs the master-write confirmation; a replica with no blueprint of its own is refused.
- `AcceptRisk` (`tenantId`, `standard`, `items` of `{ itemId, approvedBy, why, properties? }`): `Set-PERiskAcceptance`, for the whole item or one decision per listed property.
- `RemoveRisk` (`tenantId`, `standard`, `items`): removes the item's accepted risks.
- `ImportStandard` (`standard`, optional `tag` vX.Y.Z; default the latest): `Import-PEStandardRelease`.
- `CheckStandardRelease` (`standard`): `git ls-remote` only; writes the latest tag for the banner.
After Adopt, Accept risk and Remove the worker compares the blueprint with the standard again, so the page shows the result at once (an adopted setting then matches). To change the tenant, revert it to its blueprint on Drift review. Adopt and Accept risk are added to the Selection list like Revert, Promote and Exclude (entries carry their `standard`, so they never replace a Drift review pick of the same item); Remove acts at once.

**Try it.** `Start-PEGui.ps1 -Mock` shows the example numbers of the mock-ups. For real engine data without a tenant: `pwsh -NoProfile -File tools/PEDemoStandards.ps1 -DataRoot data/demo-standards` (add `-NewVersion` to see "Look again"), then start the GUI on `<DataRoot>\gui` and the worker with `-DataRoot <DataRoot>`.

**Tests.** `gui/tests/Standards.Tests.ps1` runs node on `standards-model.js` (headline words, bar segments, queue identity and grouping, the dialog's checks) and checks the server routes and that the Drift review lists the standard; `gui/tests/StandardsApi.Tests.ps1` covers the routes, previews and the mock data; `tests/GuiStandardExport.Tests.ps1` and `tests/GuiStandardRequest.Tests.ps1` cover the export and the worker. `standards.js` itself is verified in a browser.
