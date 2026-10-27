# Overview: folder structure and tools

A short map of the repo. For status, decisions and open items read `handover.md`; for the principles read `CLAUDE.md`.

## Folder structure

| Path | What it holds |
| --- | --- |
| `Microsoft365DSC/` | Local clone of the DSC repo, the source of truth for resource schemas. Git-ignored; clone it separately. |
| `src/PolicyEngine/` | The PowerShell module, our policy layer. `Public/` has the exported commands, `Private/` the internals, `Data/` small config files (`Versions.psd1` pins the DSC version; `KeyMap`, `IgnoredProperties`, `ExcludedTypes`, `RevertBlocked`, `References` and similar). |
| `tools/` | Command-line entry points and setup scripts. Thin wrappers that call the module or DSC. |
| `gui/` | The local web GUI: `server.ps1` and `Start-PEGui.ps1` serve it, `PEGui.psm1` holds the logic, `public/` the front end, `README.md` the startup token and request checks. |
| `tests/` | Offline Pester tests (fake exports). Run with `tools/Invoke-PETests.ps1` (`-Fast` skips the slow ones). |
| `data/` | Runtime state, git-ignored: `blueprints/`, `checks/`, `exports/`, `audit/`, `decisions.json`, `scopes.json`, `tenants.json`. |
| `docs/` | `handover.md` (main status file), `acceptance-v1.md`, `apply-mechanics.md`, `key-coverage.md`, `gap-analysis.md`, `upstream-issues.md`, `gui-handoff.md`, and the design and plan under `superpowers/`. |

Secrets and certificates live outside the repo, in `~\.m365dsc-policy\`.

## Tools on top of Microsoft365DSC

**Setup and tenants**
- `New-PETenantApps`, `Connect-PETenant`, `Get-PETenantSetup`: create or connect the Reader and Writer app registrations, using DSC's permission lists and `Update-M365DSCAzureAdApplication` where it can do the job.
- `Install-M365DscDependencies` and `Set-PEBlueprintModule`: install the pinned DSC version and guard against drift.

**Blueprints**
- `Initialize-PETenantBlueprint`: gives a replica its own blueprint (a copy of the master blueprint's latest version); `tenants.json` keeps each tenant's ordered `Blueprints` list, master blueprint first, and a tenant with no list follows the master blueprint alone.
- `New-PEBlueprint`, `Add-PEBlueprintType`: build a blueprint from a DSC export. Blueprints are versioned, reviewed and written crash-safely.

**Checking drift**
- `Invoke-PEFullCheck`: full DSC export compared with the blueprint.
- `Invoke-PEScopeCheck`: one resource type or a slice of keys; much faster than a full check.
- `Export-PEDelta`: re-exports chosen objects through DSC (using its `Filter` where the type supports it), for quick re-reads after an apply.
- `Compare-PEState`: the comparison itself (keys, ignored properties, finding kinds such as Missing, Changed, PossibleRename).

**Offline tenants (uploaded snapshots)**
- `New-PEUploadCheck`: turns DSC export files of a tenant the tool cannot reach into a Full check (`Meta.Source = Uploaded`; refused unless every file carries the pinned Microsoft365DSC version). `Set-PETenant -Offline` marks such a tenant.
- `New-PEOfflineConfig`: from the tenant's own blueprint and its latest check, writes `Changes.ps1` (create and update), `Removals.ps1` (only items left as drift, of types the blueprint has records of) and a list of items that need manual action, for the pipeline owner to run. The GUI does both through the `UploadSnapshot` and `GenerateConfig` requests. See `docs/handover.md`, "Offline snapshots".

**Multiple tenants**
- One blueprint, taken from the master, is compared against any number of replicas (`-Tenant`). `tenants.json` is the registry.

**Decisions and noise**
- Findings can be marked Unmanaged, Remove or Promote. Noise rules are global.
- A property can be excluded for one tenant (decision kind `PropertyExcluded`, for one item or every item of a type): it stays visible in the item, is not counted as drift, and a Revert leaves it as the tenant has it. See `docs/handover.md`, "Excluding a property for one tenant".

**Applying changes**
- **Selection list** (GUI): Revert, Promote and Exclude (hover for what each means) add a drifted item to the selection list instead of acting at once. Revert puts the tenant back (a DSC configuration), Promote takes the drift into the tenant's blueprint, Exclude ignores it. The list page shows what they add up to, including the combined DSC configuration. Run applies it (Exclude, then Promote, then Revert; one job per action, tenant and workload). Export saves the DSC configuration of the Revert items per tenant and workload as a `.ps1` (the same text as the review) plus a `.psd1` of placeholders (ApplicationId, CertificateThumbprint, OrganizationName, TenantGuid, TenantId, laid out like a Microsoft365DSC export) to fill in and apply by hand.
- `Invoke-PERectify`: builds a plan, saves an audit folder, generates a DSC config, compiles it with `Invoke-M365DSCConfigurationBuild` and applies it through the Local Configuration Manager (`Start-DscConfiguration`, `tools/Invoke-PEApply.ps1`, `tools/Invoke-PELcm.ps1`).
- Safety rules: plans are single-use, writing to the master needs `-ConfirmMasterWrite`, Security and Compliance types are check-only.

**Scheduling**
- `Register-PESchedule`, `Register-PEScopeSchedule`: Windows scheduled tasks for full checks and scope checks.

**GUI**
- `Start-PEGui` serves the interface; `Start-PEGuiWorker` runs the checks and reverts it requests. Pages: Overview (the selected tenant against the blueprints it follows), Drift review, Blueprint, Exclusions, Tenants (connect, rename), Activity. The tenant is chosen once, in the top bar.
- `tools/Initialize-PETenantBlueprints.ps1`: gives every replica its own blueprint (use `-WhatIf` first). A replica without one cannot promote (it would change the master blueprint).

**Verification**
- `Invoke-PERoundTrip`, `Measure-PEKeyCoverage`: check that a blueprint exports and compares cleanly, and how well its keys are covered.

## Words used in the GUI

- **Snapshot**: a stored reading of a tenant at one moment (the code calls it a Full check, `Kind = 'Full'`). It covers the resource types the blueprint holds.
- **New snapshot**: a full re-read of the tenant (the top-bar button; `Recheck` request without a scope). The result has no `PatchedFrom`: nothing carries over from the old snapshot.
- **Refresh**: a partial re-read of one resource type or scope (`Recheck` with a scope, `Invoke-PEScopeCheck`). It is saved as a new snapshot built from the latest one with the fresh slice swapped in (`Meta.PatchedFrom`), so a snapshot can hold parts of different ages; the snapshot line names the older workload.
- **Compare**: a snapshot against a blueprint version. The result is **drift**. A Promote compares just the promoted items again without reading the tenant, so the snapshot's data and time stay as they were.
- **Revert tenant** changes a tenant to match the blueprint; **Restore blueprint version** changes the blueprint back to an earlier version; **Promote** takes tenant drift into the blueprint. A blueprint version made by Promote is stored with source `Accept` and shown as "Promote".
- "Delta" is not used for any of these: DSC means a diff of two configurations by it (`New-M365DSCDeltaReport`).

Blueprint commands added with the snapshot work: `New-PETenantBaseline` (a replica's own blueprint becomes what its latest snapshot read) and `Restore-PEBlueprintVersion` (a new version that copies an older one, or one item of it).
