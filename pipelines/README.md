# Pipelines (Azure DevOps)

Headless: no GUI, no worker. They call the PolicyEngine module and Microsoft365DSC's own commands.

| Pipeline | Does |
| --- | --- |
| `Export-PreProd.yaml`, `Export-Dev.yaml` (generated from the `.yaml.template` files) | Imports the tenant's Reader certificate from Key Vault, runs `tools\Export-M365DscTenant.ps1`, publishes `PreProdExport` / `DevExport`. |
| `Compare-PreProd-to-Dev.yaml` | Takes the latest of both exports, runs `tools\Invoke-PEPipelineCompare.ps1`, publishes `DriftReport` (`drift-report.html`, `drift.csv`, `drift.json`, `Changes.ps1`, `Removals.ps1`, `Manual.json`, `MOF\Changes`, `MOF\Removals`). |
| `Apply-Dev.yaml` | Applies the MOFs to Dev through the LCM (`tools\Invoke-PELcm.ps1`). Default mode is `Test`; Removals only when asked; gated by the `m365-dev` environment approval. |
| `Apply-Approved-Dev.yaml` | Applies exactly the items of one approved list (`approvals/*.json`, from the drift report). Default mode `Test`; gated by the `m365-dev` environment approval. See "Approved apply" below. |
| `Tenant-Changes.yaml` | What changed in ONE tenant between two of its own exports. See "Tenant changes" below. |
| `Bump-Dsc-Pin.yaml` | Changes the pinned Microsoft365DSC (and optionally Microsoft.Graph.Authentication) version in `src\PolicyEngine\Data\Versions.psd1` and opens a pull request. See "Bumping the DSC pins" below. |

**Drift report (choose what to apply, in the browser).** The compare pipeline also publishes `drift-report.html` in the `DriftReport` artifact
(`tools\New-PEDriftReport.ps1`, built from the engine's own comparison, not a second one).
1. Download the `DriftReport` artifact and open `drift-report.html` (a double click; it is one file, needs no server and makes no network calls).
   It has three screens, and the browser's back button works between them:
   - **Overview**: totals, then one row per workload (records in each export, how many are missing, different or only in the target, cannot be
     approved, not compared, and how many you have selected). Every number is a link into Review.
   - **Review**: workload, then resource type, then item, each level collapsible and with its own totals ("master 100 / replica 98 / 5 drifted")
     and its own select box. Filters: workload, resource type, kind and a key search. Workloads start collapsed.
   - **One resource** (Details on an item): every property of both exports side by side, with a state per property (different, same, only in one
     side, ignored because the engine does not compare it). Only drifted resources are listed; matching ones are only counted.
2. Open a resource type (for example `AADGroup`) and tick the items to create, update or remove. The type checkbox ticks everything shown; the
   filters (Create / Update / Remove / Cannot be approved / Not compared, a type list and a key search) narrow what "Select all shown" ticks. On an
   Update, open "differences" and tick "Keep ... value" for a property you do not want changed. Removals are only selectable after ticking
   "Include removals". Items that cannot be approved (a key that matches more than one object, a type PreProd does not cover, anything the engine
   refuses) show the reason and have no checkbox. What the comparison did not look at (out of scope, not in the export, export log incomplete) is
   listed apart under "Not compared": it is information, not drift, and nothing there can be approved.
3. Type your name in "Approved by" and click **Download approved.json**. The button says why it is disabled until the list is valid. The page
   remembers your ticks if you reload it.
4. Commit `approved.json` to `approvals/` in the project folder (a pull request lets someone else review the list). It names items only, never
   values; the values always come from the PreProd export at apply time.
5. The approved-apply pipeline reads that list (plan `docs/superpowers/plans/2026-11-03-approved-apply-pipeline.md`; not built yet).

Outside the pipeline (for example two local exports) run `tools\New-PEDriftReport.ps1` yourself; `-SourceLabel`, `-TargetLabel` and `-Tenant` name the two
sides in the page and the list (the defaults are PreProd, Dev and `dev`). The report needs the two export run ids; the compare pipeline passes them.
A manual run of `Invoke-PipelineCompare.ps1` without numeric `-PreProdRun` / `-DevRun` skips the report and says so.

**Approved apply (`Apply-Approved-Dev.yaml`): apply only what was approved.** Parameters: `approvalFile` (a path inside `approvals/`, starting at `approvals/` and not at the project folder; prefilled with `approvals/approved.json`, editable), `mode`
(Test or Apply), `includeRemovals`, `maxAgeDays` (default 7). The safe order is a `Test` run first, then an `Apply` run:
1. **Before anything else**: the run must be on the default branch (setting `DefaultBranch`, default `main`) and the list must be inside
   `approvals/` and pass the strict format rules. It then downloads the two export runs the list names (by run id, from the pipelines whose
   numbers are in `ExportPreProdPipelineId` / `ExportDevPipelineId`) and asks Azure DevOps to keep them, so the same list can be applied again later
   (a warning, not a failure, if the build identity may not manage retention).
2. **The build** (`tools\Invoke-PEApprovedBuild.ps1`) stops before writing anything if an export is incomplete (a failed component, a Graph
   "reported N items but only M were returned" line, or no `export.log`), if an export is not the one the list names (SHA-256), if the Dev export is
   older than `maxAgeDays`, or if the list is for another tenant than `dev`. Then it compiles one MOF per resource type and phase for the approved
   items only, and prints the counts per type and action ("Create 10 AADGroup") before the approval and again at the end.
3. **Test mode** runs the LCM test of every configuration (the preview of what would change) and writes nothing to Dev. **Apply mode** runs every
   test first, then applies the configurations in order (all Changes, then Removals only with `includeRemovals`), and carries on after a failed
   resource: it applies what it can and reports what is left. There is no rollback (DSC has none).
4. **Every approved item ends in exactly one outcome**, listed in `result.json` (artifact `ApprovedApplyReport`): `Applied`, `NoActionRequired`
   (Dev already had the approved outcome), `NotGenerated` (the engine refused it; the reason is given), `Failed` (DSC's error) or `Skipped` (Dev
   was not in the state the approval expected, or a Remove without `includeRemovals`). The run is green only when every item is `Applied` or
   `NoActionRequired`; otherwise it finishes **with issues** and lists what is left. Running the same list again only has the rest to do: the LCM test at run time
   finds what is already in the desired state (`NoActionRequired`), because the exported Dev the list was reviewed against does not know what a
   first run already did. An item is only `Applied` when the LCM reports its resource (`[Type]Name`) in the desired state; if it does not, the item
   is `Failed` with that reason, never silently green.
Settings: add `ExportPreProdPipelineId`, `ExportDevPipelineId` (and optionally `DefaultBranch`) to `pipeline.settings.psd1`; the other pipelines
generate without them. In Azure DevOps, a branch policy that requires a pull request review on `approvals/` is recommended: the pipeline checks the
branch and the folder, not who reviewed the change.

**MOF layout** (`mofLayout` on the compare pipeline, `Invoke-PEPipelineCompare.ps1 -MofLayout`):
- `Combined` (default): `MOF\Changes` and `MOF\Removals`. Run Apply-Dev with `workloads` empty.
- `PerWorkload`: `<Prefix>\MOF\Changes` and `<Prefix>\MOF\Removals` for each workload the PreProd export has records of. Run Apply-Dev with
  `workloads` such as `AAD,Intune,EXO,Teams`; they are applied in that order (all Changes first, then, if ticked, all Removals).
  Each workload is its own run of the same comparison with only that workload's PreProd records as the expected state. `drift.*` and
  `Manual.json` always come from the full comparison.

**The YAML stays thin.** Each pipeline is: install modules, one script step, publish. The logic and the checks live in the scripts, not in the YAML:
- `scripts\Install-PipelineDependencies.ps1`: pinned Microsoft365DSC, its dependency manifest and Microsoft.Graph.Authentication, saved to
  `C:\Program Files\WindowsPowerShell\Modules` and added to the machine `PSModulePath`.
- `scripts\Invoke-PipelineExport.ps1`, `Invoke-PipelineCompare.ps1`, `Invoke-PipelineApply.ps1`: the three pipeline steps. They read the config file,
  call `Connect-PipelineTenant.ps1` (certificate from Key Vault; the thumbprint is taken from the certificate) and remove the certificate again in a
  `finally`; a last `condition: always()` step in each pipeline removes it again even if the agent process was killed (timeout, hard cancel).
- `scripts\Get-PipelineConfig.ps1`: reads and validates `config\<Environment>.psd1`.
- Apply logs which compare run (and which PreProd and Dev export runs) it is applying, so an approver can see what they are approving. It stops,
  instead of applying nothing, when `workloads` does not match the compare run's layout (Combined or PerWorkload, from the report's `summary.json`) or
  names a workload with no folder. It also refuses a report with no valid certificate thumbprint, and checks that the Writer certificate is the one the
  MOFs were compiled with. A run with no drift ends with "Nothing to apply". In Apply mode a resource still not in the desired state fails the step and
  Removals do not follow; in Test mode differences are only reported.
- When you queue Apply by hand, Azure DevOps lets you pick which compare run to use (Resources); the default is the latest.

## Tenant changes (`Tenant-Changes.yaml`): what changed in this tenant since the last export
Queue it by hand (nothing triggers it). Parameters: `tenant` (Dev or PreProd), `exportVersion` and `previousVersion` (both optional).
It compares the tenant's **previous** export (what it should look like) with its **latest** export (what it looks like), with the same comparison as the
compare pipeline, so the report shows only the tenant's own changes, not differences between tenants.
- **Which exports.** Blank means the newest successful export that still has its artifact, and the successful one just before it. A failed or cancelled run in between is
  skipped. To look further back type a name such as `v7` (the counter in the run name `Dev-export-v7`; the export pipelines now name their runs this way, each tenant
  counting on its own) or, for an old run whose name has no counter, its numeric run id. "Previous" is looked up over the Azure DevOps API, not calculated as the number minus one, because the
  counter also counts failed runs. The run renames itself to what it compared (`Dev changes v8 to v9`) and says so first in the log.
- **Outputs** (artifact `TenantChanges`): `<Tenant>Changes.html` (the drift report; its list cannot be applied by `Apply-Approved-Dev`, the tenant in it is `dev-changes`),
  `Revert\` (previous = expected: `Changes.ps1`, `Removals.ps1`, `Manual.json`, `drift.*`, `summary.json`, and for a tenant with a Writer app (Dev) the MOFs and
  `ConfigurationData.psd1`; the layout of a compare run), `RevertDevChanges.mof` and `RevertDevRemovals.mof` (copies), and `DevChanges.ps1` / `DevRemovals.ps1` (the
  other direction: the configuration that takes a tenant in the previous state to the latest, the thing to promote). The promote configuration is **not compiled**: a
  MOF holds the identity of the tenant it will be applied to.
- **Revert.** Run `Apply-Dev` with `source` = `TenantChanges` and pick the Tenant changes run in Resources. It applies `Revert\` through the usual approval, Test before
  Apply. It refuses a report of another tenant (the report's `summary.json` carries `Tenant`).
- **Nothing changed** is a green run that says `No changes`.
- **Refusals, each with its reason:** a name that does not exist, a run that did not succeed, a run of another pipeline, an export whose artifact retention deleted, an
  "after" that is not newer than the "before", no earlier successful export (take a fresh export first), an export made with another Microsoft365DSC version, and a run name with
  characters other than letters, digits, space, dot, hyphen and round brackets.
- **Prerequisite:** the project's build service identity needs **View builds** on the export pipelines (the same identity that creates the retention leases).
- **Setting up:** both export pipeline ids must be in `pipeline.settings.psd1` (`ExportDevPipelineId`, `ExportPreProdPipelineId`); the generator builds the tenant map from them. Create the pipeline
  from `Tenant-Changes.yaml`, named as `TenantChangesPipeline` (default `M365DSC - Tenant changes`), and generate again so `Apply-Dev.yaml` can find it.
- **Prod** is not offered yet: it has no config file or export pipeline. Adding it is one more value of `tenant` and one more entry of the map.

## Bumping the DSC pins
`Bump-Dsc-Pin.yaml` (`pipelines\scripts\Update-DscPin.ps1`) moves the versions pinned in `src\PolicyEngine\Data\Versions.psd1`, the one file every pipeline,
tool and the module install from. It checks the versions, edits only the value on the pin line (comments, the other pin and the line endings stay),
creates the branch `dsc-pin/<version>`, commits, pushes, and opens a pull request into the default branch. It **never pushes to `main`** (or any
default branch) and never overrides a pin at run time: the change takes effect when somebody merges the pull request.

Parameters (queue it by hand, from the default branch):
- `version` (required): the Microsoft365DSC version, four numbers such as `2.26.1104.1`.
- `graphAuthenticationVersion` (optional): the Microsoft.Graph.Authentication version, three numbers such as `2.41.1`; empty keeps the current one
  (when given, the branch is `dsc-pin/<version>-graph-<graph version>`).

What it refuses or does on its own: a version of the wrong shape or one the PowerShell Gallery does not have stops it before anything is changed; the
version already pinned is "nothing to do" (no branch, no pull request); a branch for that version that already exists is not duplicated (it prints
the open pull request's address instead); a lower version is allowed but the log, the title and the description say `DOWNGRADE`. The parameters travel to
the script as environment variables, never inside the command text.

**Permissions.** The project's build service identity (`<Project> Build Service (<Organization>)`) needs these on the repository: **Contribute**,
**Create branch** and **Contribute to pull requests**. The step uses `persistCredentials` for git and `System.AccessToken` for the REST call, so no
secret is stored. If a branch policy on the default branch needs reviewers, they are added to the pull request in the usual way. If the project uses "Limit job authorization scope" or "Protect access to repositories in YAML pipelines", the build identity (and the repository) may need access granted explicitly.
The pipeline refuses to run from any commit other than the tip of the default branch, so queue it from the default branch.

**After merging the pull request:**
- Take fresh exports: an export made with another pin is refused.
- Run the install step (`pipelines\scripts\Install-PipelineDependencies.ps1`) on the agents so they have the pinned module versions.
- See "When the Microsoft365DSC pin changes" in `docs\handover.md`.

## Configuration: two places
**1. Tenant config files, read at run time: `pipelines\config\Dev.psd1` and `PreProd.psd1`.** Fill in the tenant domain, Key Vault name,
the environment's short name and the Reader (and, for Dev, Writer) application (client) ids; Dev also has the Exchange organization name.
Commit them to your ADO repo: they hold identifiers only, never a secret. `scripts\Get-PipelineConfig.ps1` reads them as data, allows only
those keys, checks each value (GUID, domain, name) and refuses `CHANGE-ME`, so a typo or a pasted secret stops the run. Changing a value
needs no regenerating: edit the file and run the pipeline.
Certificates are read from Key Vault: the secret `<ShortName>-Cert-Reader` (and `<ShortName>-Cert-Writer` for Dev) holds the certificate as a
base64 PFX without a password, read with `Get-AzKeyVaultSecret`. The thumbprint is taken from the certificate itself and is not stored.

**2. Settings for the YAML itself (once, then whenever a template or a setting changes).** Azure DevOps needs the agent pool, the service connections,
the environment and the pipeline names before any script runs, so those are tokens (`__POOL__` and so on) in the **`*.yaml.template`** files.
The templates are not YAML as far as Azure DevOps is concerned, so they never show up when you pick an existing pipeline file; only the generated
`*.yaml` do.
1. Copy `pipelines\pipeline.settings.example.psd1` to `pipelines\pipeline.settings.psd1` (git-ignored) and fill in the pool and one service connection per tenant (`DevServiceConnection`, used by Export Dev, Compare and Apply, and `PreProdServiceConnection`, used by Export PreProd). An old single `ServiceConnection` line still works as the default for both.
2. Run `pwsh -NoProfile -File pipelines\scripts\New-PipelineYaml.ps1`. It writes `Export-Dev.yaml`, `Export-PreProd.yaml`, `Compare-PreProd-to-Dev.yaml`
   and `Apply-Dev.yaml` next to the templates, each with a header line saying it is generated. It stops on a missing value, an example value left in,
   or a token it does not know, and it never deletes anything. Old tenant keys in the settings file are ignored with a warning.
3. Create the four pipelines in Azure DevOps from those `*.yaml` files, named as in the settings file (the `resources:` blocks look them up by name),
   and create the `m365-dev` environment with an approval check.

## Where the project sits in the ADO repo
The project can live in a folder of a repo that holds other things (for example `M365dscGUI\`, with `pipelines\`, `src\`, `tools\` and the rest
beneath it). Nothing else in the repo is touched or read.
- **Do the setup inside the ADO repo.** Copy the project in (the `.template` files and `pipeline.settings.example.psd1` come with it, your own settings file
  does not), make `pipeline.settings.psd1` there, run the generator there, and commit the generated `*.yaml` together with the `config\` files.
- **`.gitignore`:** copy it into `M365dscGUI\` (it applies to that folder only). It keeps `pipelines\pipeline.settings.psd1` and `data\` out of the repo and
  also ignores the generated `pipelines\*.yaml`, which is right for the GitHub repo but not for ADO: **delete the `pipelines/*.yaml` line** (it has a
  comment above it) in the ADO copy so the generated files are committed. Do not commit the settings file.
- **`RepoFolder`** in `pipeline.settings.psd1` (default `M365dscGUI`; use forward slashes for a deeper folder, `.` for the repo root) is put in front of
  every script path in the YAML: `$(Build.SourcesDirectory)/M365dscGUI/pipelines/scripts/...`. Change it and generate again if you use another folder name.
- **The scripts need no setting.** They find `src\`, `tools\` and `config\` relative to their own location, so they work from any folder.
- **Creating each pipeline in ADO:** choose the existing YAML file at `M365dscGUI/pipelines/<name>.yaml`. The pipeline's own YAML path is the only other
  place the folder name appears.
- The checkout is the whole repo, so a large legacy repo is cloned each run; shallow fetching is available if that is slow.

## Agent needs
Windows, PowerShell 7.6+, local administrator (Program Files and the machine certificate store), internet access to the PowerShell Gallery.

## How the compare works
The PreProd export becomes a blueprint and the Dev export an uploaded snapshot, in a throwaway data folder, so the existing
`Compare-PEState` and `New-PEOfflineConfig` do the comparison and generation. Rules that come with that: Missing and Changed items
are written to `Changes`, only target-only items of a type PreProd has records of go to `Removals`, anything DSC cannot create or
remove goes to `Manual.json`, tenant-bound ids and each tenant's own domain name are not reported as drift.
