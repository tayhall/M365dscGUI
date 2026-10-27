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
aligned; run a full check to refresh everything. Revert still fails with a message (no engine command yet).
Engine v1 has one tenant, shown as the master; a second tenant is optional. `firstSeen` is the check time and
blueprint versions are labelled Initial or Accept.

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
Known gap: the server accepts any Host header (no sign-in yet); keep it on localhost.

## Not done yet

- A blueprint revert command, two-tenant data, Entra sign-in, a Host header check.

## Blueprint layers

Each tenant in `index.json` has `layers`: the blueprints it follows, master blueprint first, the tenant's own last
(`name`, `version`, `role` master/tenant/layer, `sameAsOwn`, `checked`, `problem`, and `drifted`, `aligned`, `changed`,
`missing`, `targetOnly` counted from the tenant's latest Full check against that blueprint). A tenant with no stored
list has one layer, the master blueprint. `tenants/<id>/findings.json` holds the findings against the tenant's own
blueprint; for every other layer `tenants/<id>/layers/<blueprint>/findings.json` holds the same rows, each with its
`layer`. A tenant never checked, or a layer whose blueprint cannot be read, has `checked: false`.
