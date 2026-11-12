# Tenant Changes Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A hand-queued Azure DevOps pipeline, `Tenant-Changes`, that compares one tenant's latest export with its previous export and publishes a report of only that tenant's own changes, a revert configuration (compiled for Dev) and a promote configuration.

**Architecture:** A small resolver script finds the two export runs over the ADO REST API; the existing `tools\Invoke-PEPipelineCompare.ps1` and `tools\New-PEDriftReport.ps1` do all comparing and report building (called twice, once per direction). A thin tool arranges the outputs; the YAML stays thin. The existing apply step is pointed at the revert output and gains a tenant check.

**Tech Stack:** PowerShell 7.6, Pester 5.7.1 (`tools\Invoke-PETests.ps1`), Azure DevOps YAML pipelines, Microsoft365DSC (pinned in `src\PolicyEngine\Data\Versions.psd1`).

**Spec:** `docs/superpowers/specs/2026-11-12-tenant-changes-pipeline-design.md`

## Global Constraints

- Thin wrapper (CLAUDE.md): call the existing compare, report and DSC build; do not copy their logic. If two exports of one tenant need something the compare cannot do, **stop and discuss**, do not fork it.
- Run name of an export: `Dev-export-v$(Rev:r)` / `PreProd-export-v$(Rev:r)`. Friendly input is `v9` (a leading `v`); bare digits are a numeric run id.
- "Previous" is looked up (the newest successful run with its artifact before "after", by run id), never calculated as number minus one.
- `trigger: none`; nothing triggers the pipeline. Parameters: `tenant`, `exportVersion` (blank = latest successful), `previousVersion` (blank = successful run just before "after").
- Artifact `TenantChanges`. Names: `DevChanges.html`, `DevChanges.ps1`, `DevRemovals.ps1` (promote direction, **never compiled**), `Revert\` (a valid `-ReportPath` for `Invoke-PipelineApply.ps1`: `summary.json`, `ConfigurationData.psd1`, `MOF\Changes`, `MOF\Removals`, `Changes.ps1`, `Removals.ps1`, `Manual.json`, `drift.*`) plus copies `RevertDevChanges.mof` and `RevertDevRemovals.mof` at the top level. The tenant name is the prefix.
- `summary.json` carries `Tenant`, `PreviousRun`, `LatestRun`, `PreviousName`, `LatestName`. The log's first line, the report header and the run name say `Dev changes: v8 -> v9`.
- Revert is compiled only for a tenant whose config has a valid `WriterAppId` (Dev). Apply is Dev only; none of `Apply-Dev`'s guards are weakened.
- The report's tenant slug is `<slug>-changes` (for example `dev-changes`), so `Apply-Approved-Dev` (expects `dev`) refuses a list made from this report.
- No usable previous export (none exists, or made with another DSC pin) is an error with a plain message, not a partial report.
- Values reach scripts through environment variables, never inside command text; every parameter has a validation pattern. Tests are offline Pester tests; REST is mocked. New tool files go in `pipelines\ado-manifest.psd1`.
- Commits end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Work on branch `tenant-changes-pipeline`.

## Review Focus

- Two identical exports: zero findings, no configurations, no MOF, the run **succeeds** saying "No changes" (most likely to bite: it fails or emits empty MOFs).
- Two exports that differ only in volatile content (header comments, timestamps, resource order, trailing whitespace): zero findings. Anything that shows up here is tooling noise.
- One extra group in "latest": exactly one item in each direction (a Remove in Revert, a Create in Changes) and nothing else.
- `exportVersion` older than or equal to `previousVersion`, or the same run twice: refused.
- A run that failed between v8 and v9 (a gap in the counter), or whose artifact retention deleted: skipped for the defaults, refused when named.
- A `TenantChanges` artifact of PreProd given to the Dev apply: refused.
- First export of a tenant (nothing before it) and a previous export with another DSC pin: plain messages naming the cause and the fix.

---

### Task 1: Same-tenant noise baseline (the spike)

**Files:**
- Create: `tests/TenantChangesNoise.Tests.ps1`, `tests/fixtures/upload/entra-plus-group.ps1` (copy of `entra.ps1` with one extra `AADGroup`), `tests/fixtures/upload/entra-noisy.ps1` (copy of `entra.ps1` with volatile differences)
- Read first: `tools\Export-M365DscTenant.ps1` and `tests/fixtures/upload/entra.ps1` to see what an export contains that varies between runs (generation stamp, header, order).

**Interfaces:**
- Consumes: `tools\Invoke-PEPipelineCompare.ps1 -SourceExportPath -TargetExportPath -TargetTenantDomain -OutputPath -CompleteWorkload AAD` (no `-Compile`); it writes `summary.json` (`OpenFindings`, `ByKind`), `drift.json`, and `Changes.ps1` / `Removals.ps1` only when there is something to write.
- Produces: the proven fact that the existing compare is quiet on same-tenant exports, or a list of noise sources to fix.

- [ ] **Step 1: Write the failing tests.** In `Describe 'same-tenant compare of two exports'`, using the copy-to-temp-folder helper style of `tests/DriftReportTool.Tests.ps1` (each export folder gets `export.ps1` and an empty `export.log`), with `TargetTenantDomain 'contoso-dev.onmicrosoft.com'` on both sides:
  - `It 'finds nothing when the two exports are the same'` — `entra.ps1` vs `entra.ps1`: `OpenFindings` is 0, `Changes.ps1` and `Removals.ps1` do not exist.
  - `It 'finds nothing when the exports differ only in volatile content'` — `entra.ps1` vs `entra-noisy.ps1`: `OpenFindings` is 0.
  - `It 'finds exactly the one new group, as a Remove, in the revert direction'` — source `entra.ps1`, target `entra-plus-group.ps1`: `OpenFindings` is 1, `ByKind` is `TargetOnly=1`, and `Removals.ps1` names the group.
  - `It 'finds exactly the one new group, as a Create, in the promote direction'` — source `entra-plus-group.ps1`, target `entra.ps1`: `OpenFindings` is 1, `ByKind` is `Missing=1`, `Changes.ps1` names the group.
- [ ] **Step 2: Run** `pwsh -NoProfile -File tools\Invoke-PETests.ps1 -Path tests\TenantChangesNoise.Tests.ps1 -Fast`. Expected: the fixture-dependent tests fail only for missing fixtures; after the fixtures exist, any remaining failure is noise.
- [ ] **Step 3: Create the two fixtures.** The noisy one changes only things a real re-export varies (what Step 0's reading found: stamps, comments, resource order, whitespace), never a property value of a resource.
- [ ] **Step 4: Fix real noise, if any.** If a test fails because of tooling behaviour, fix it in the smallest place (a `Data\` ignore list before code); if only a change to the compare itself would work, **stop and discuss**.
- [ ] **Step 5: Run the file; all four pass.** Commit `test: same-tenant compare is quiet and finds only a new group`.

### Task 2: The tool that arranges the outputs

**Files:**
- Create: `tools/Invoke-PETenantChanges.ps1`, `tests/TenantChangesTool.Tests.ps1`
- Modify: `pipelines/ado-manifest.psd1` (add the tool under `Include`)

**Interfaces:**
- Consumes: `Invoke-PEPipelineCompare.ps1` (above, with `-Compile -ApplicationId -CertificateThumbprint -OrganizationName` for the revert direction only); `New-PEDriftReport.ps1` (Task 3 adds the call).
- Produces: `tools\Invoke-PETenantChanges.ps1 -Tenant <string, \A[A-Za-z0-9-]{1,24}\z> -PreviousExportPath <string> -LatestExportPath <string> -TargetTenantDomain <string> -OutputPath <string> -PreviousRun <numeric string> -LatestRun <numeric string> -PreviousName <string> -LatestName <string> [-CompleteWorkload <string[]>] [-ApplicationId <string> -CertificateThumbprint <string> -OrganizationName <string>]` writing the layout in Global Constraints. Compiles the revert only when the three identity values are given. Prints `Dev changes: v8 -> v9` first and `No changes` when `OpenFindings` is 0 in both directions (exit 0, no MOF).

- [ ] **Step 1: Write failing tests** (no `-Compile` identity, fixtures from Task 1): the output has `Revert\summary.json` and `DevChanges.ps1` for the extra-group pair; identical exports give `No changes` printed and no `DevChanges.ps1`; top-level `summary.json` has `Tenant`, `PreviousRun`, `LatestRun`, `PreviousName`, `LatestName`; `DevChanges.ps1` is a configuration text and no `MOF` folder exists outside `Revert\`; the first printed line is `Dev changes: v8 -> v9`.
- [ ] **Step 2: Run to see them fail** (`-Path tests\TenantChangesTool.Tests.ps1 -Fast`): "tool not found".
- [ ] **Step 3: Implement the tool** as two calls of `Invoke-PEPipelineCompare.ps1` (revert into `<Output>\Revert`, promote into a work folder from which `Changes.ps1` / `Removals.ps1` are copied as `DevChanges.ps1` / `DevRemovals.ps1`), then the summary and, when MOFs exist, the two top-level `RevertDev*.mof` copies.
- [ ] **Step 4: Pin message.** Find where an export made with another DSC pin is refused (the state loader / `New-PEUploadCheck` path). Add a test with an export carrying another version that expects a message naming "made with another Microsoft365DSC version" and "take a fresh export"; make the tool catch and re-throw it plainly.
- [ ] **Step 5: Run the file; all pass.** Commit `feat: tool that compares two exports of one tenant and arranges revert and promote outputs`.

### Task 3: The report, labelled, and refused by Approved Apply

**Files:**
- Modify: `tools/Invoke-PETenantChanges.ps1`
- Test: `tests/TenantChangesTool.Tests.ps1`

**Interfaces:**
- Consumes: `New-PEDriftReport.ps1 -SourceExportPath -TargetExportPath -TargetTenantDomain -OutputPath -SourceRun -TargetRun -Tenant -SourceLabel -TargetLabel` (labels match `\A[\w .()-]{1,40}\z`).
- Produces: `<Tenant>Changes.html` (copy of `drift-report.html`), built with `-Tenant '<slug>-changes'`, `-SourceLabel '<Tenant> <PreviousName>'`, `-TargetLabel '<Tenant> <LatestName>'`.

- [ ] **Step 1: Write failing tests:** `DevChanges.html` exists and its embedded report data has `Meta.Tenant` equal to `dev-changes`, `Meta.Source.Run` the previous run and `Meta.Target.Run` the latest; the `Invoke-PEApprovedBuild.ps1` tenant check (`-ExpectedTenant dev`) throws for a list whose tenant is `dev-changes` ("is for tenant 'dev-changes'"). The report is an extra: if it cannot be built the rest is still written and a warning issued (same as `Invoke-PipelineCompare.ps1`).
- [ ] **Step 2: Run, see them fail. Step 3: Implement.** **Step 4: Run, pass.** Commit `feat: tenant changes report, refused by approved apply`.

### Task 4: Resolve the two export runs

**Files:**
- Create: `pipelines/scripts/Resolve-TenantExports.ps1`, `tests/ResolveTenantExports.Tests.ps1`

**Interfaces:**
- Produces: `Resolve-TenantExports.ps1 -Tenant <Dev|PreProd> -TenantMap <string "Dev=22;PreProd=21"> [-ExportVersion <string, '' | \Av\d{1,6}\z | \A\d{1,12}\z>] [-PreviousVersion <same>]`; returns `[pscustomobject]@{ DefinitionId; ArtifactName; Latest = @{ RunId; Name }; Previous = @{ RunId; Name } }` and, with `-SetVariables`, writes `##vso[task.setvariable variable=...]` for `DEFINITION_ID`, `ARTIFACT_NAME`, `LATEST_RUN`, `PREVIOUS_RUN`, `LATEST_NAME`, `PREVIOUS_NAME`. `ARTIFACT_NAME` is `<Tenant>Export`. Reads `SYSTEM_COLLECTIONURI`, `SYSTEM_TEAMPROJECT`, `SYSTEM_ACCESSTOKEN` like `New-ExportRetentionLease.ps1`. REST: `GET _apis/build/builds?definitions=<id>&statusFilter=completed&resultFilter=succeeded&queryOrder=queueTimeDescending&$top=100&api-version=7.1` with the continuation-token header, and `GET _apis/build/builds/<id>/artifacts?artifactName=<name>&api-version=7.1` (404 = no artifact).

- [ ] **Step 1: Write failing tests** (`Mock Invoke-RestMethod`, a list of fake builds with ids, `buildNumber` like `Dev-export-v9`, and an artifact map):
  - blank/blank returns the newest and the one just before it, skipping a run with no artifact and a gap where v8 failed (only successful builds are listed);
  - `v8` resolves by `buildNumber` ending `-v8` (case-sensitive `v`); a bare `4817` resolves by run id, including an old-style name with no `vN`;
  - a name that does not exist, a run of another pipeline, an unsuccessful run, a run with no artifact (named explicitly) each throw a message naming the cause;
  - "after" not newer than "before" (by run id), or the same run twice, throws;
  - only one export exists: throws "no earlier successful export of <Tenant>; take a fresh export first";
  - a 401/403 throws a message containing "View builds";
  - `-SetVariables` writes all six variables; a `Tenant` with no entry in `-TenantMap` throws.
- [ ] **Step 2: Run to see them fail** (`-Path tests\ResolveTenantExports.Tests.ps1 -Fast`).
- [ ] **Step 3: Implement.** Order and compare by run id; paging until enough builds are found.
- [ ] **Step 4: Run, pass.** Commit `feat: resolve a tenant's latest and previous export runs`.

### Task 5: The pipeline script

**Files:**
- Create: `pipelines/scripts/Invoke-PipelineTenantChanges.ps1`, `tests/PipelineTenantChanges.Tests.ps1`

**Interfaces:**
- Consumes: `Get-PipelineConfig.ps1 -Environment <Dev|PreProd> -Require TenantDomain`, `Connect-PipelineTenant.ps1 -Environment Dev -Role Writer -ThumbprintOnly`, Task 2's tool.
- Produces: `Invoke-PipelineTenantChanges.ps1 -Tenant <Dev|PreProd> -PreviousExportPath -LatestExportPath -OutputPath -PreviousRun -LatestRun -PreviousName -LatestName`. Compiles only when the tenant's config has a `WriterAppId` that is not `CHANGE-ME` (and `OrganizationName`); then it passes the Writer identity. Emits `##vso[build.updatebuildnumber]Dev changes v8 -> v9` (the run-name pattern `\A[\w .#()>-]{1,100}\z`) and a warning line with the counts, like `Invoke-PipelineCompare.ps1`.

- [ ] **Step 1: Write failing tests** with a temp config folder and the tool mocked: Dev with a Writer app passes the identity; PreProd without one does not (no `-ApplicationId`); the rename line appears once; a missing `TenantDomain` throws.
- [ ] **Step 2: Run to see them fail. Step 3: Implement. Step 4: Run, pass.** Commit `feat: pipeline script for the tenant changes run`.

### Task 6: YAML, generator and readable export names

**Files:**
- Create: `pipelines/Tenant-Changes.yaml.template`
- Modify: `pipelines/Export-Dev.yaml.template`, `pipelines/Export-PreProd.yaml.template` (`name: 'Dev-export-v$(Rev:r)'`, `'PreProd-export-v$(Rev:r)'`), `pipelines/scripts/New-PipelineYaml.ps1` (token `TenantMap` = `Dev=<ExportDevPipelineId>;PreProd=<ExportPreProdPipelineId>`, built by the script from the two ids, validated like them; add a `TenantChangesPipeline` token default `'M365DSC - Tenant changes'` only if the Apply template needs it in Task 7), `pipelines/pipeline.settings.example.psd1` if a new setting appears, `tests/PipelineYaml.Tests.ps1`

**Interfaces:**
- Produces: a template with `trigger: none`; parameters `tenant` (values `Dev`, `PreProd`), `exportVersion`, `previousVersion` (strings, default ''); steps in order: checkout; `Resolve-TenantExports.ps1 -SetVariables` (env `PE_TENANT`, `PE_EXPORT_VERSION`, `PE_PREVIOUS_VERSION`, `SYSTEM_ACCESSTOKEN`); two `DownloadPipelineArtifact@2` (`definition: '$(DEFINITION_ID)'`, `pipelineId: '$(LATEST_RUN)'` / `'$(PREVIOUS_RUN)'`, `artifactName: '$(ARTIFACT_NAME)'`, targets `latest` and `previous`); `Install-PipelineDependencies.ps1`; one `AzurePowerShell@5` step running Task 5's script, its `azureSubscription` chosen at compile time (`${{ if eq(parameters.tenant, 'Dev') }}` the Dev connection token, otherwise the PreProd one); publish `TenantChanges`. Adding Prod later is one more value and one more map entry.

- [ ] **Step 1: Write failing tests** in `PipelineYaml.Tests.ps1`: every token filled for `Tenant-Changes.yaml`; it has `trigger: none`, the three parameters with the right defaults, `TenantChanges` as the artifact name, the map `Dev=22;PreProd=21` for the example settings, no `$(LATEST_RUN)` inside a command line (only in task inputs and env); the export templates' generated YAML starts the run name with `Dev-export-v` and `PreProd-export-v`; `ExportDevPipelineId` missing makes the generator say which setting the template needs.
- [ ] **Step 2: Run to see them fail** (`-Path tests\PipelineYaml.Tests.ps1 -Fast`). **Step 3: Implement.** **Step 4: Run, pass.** Commit `feat: Tenant-Changes pipeline template and readable export run names`.

### Task 7: Apply the revert (tenant check)

**Files:**
- Modify: `pipelines/scripts/Invoke-PipelineApply.ps1`, `pipelines/Apply-Dev.yaml.template`
- Test: `tests/PipelineApplyTenant.Tests.ps1`

**Interfaces:**
- Produces: `Invoke-PipelineApply.ps1 ... [-RequireTenant]`: when the report's `summary.json` has a `Tenant` it must be `Dev` (case-sensitive) or the script throws "this report is for tenant '<x>'; this pipeline applies to Dev" before any certificate is touched; with `-RequireTenant` a missing `Tenant` also throws. The log line for such a report reads `Tenant changes of Dev: previous <name> (run <id>), latest <name> (run <id>)` instead of the PreProd/Dev export line. `Apply-Dev.yaml.template` gains parameter `source` (`Compare` default, `TenantChanges`) and a second pipeline resource `tenantChanges` (source token `__TENANT_CHANGES_PIPELINE__`, default `'M365DSC - Tenant changes'`); at compile time only the chosen artifact is downloaded, `TenantChanges` giving `-ReportPath '.../tenantChanges/TenantChanges/Revert'` and `-RequireTenant`. The compare path is unchanged.

- [ ] **Step 1: Write failing tests** (a fake report folder, `Connect-PipelineTenant.ps1` never reached): a `Tenant` of `PreProd` throws before connecting; no `Tenant` passes the check when `-RequireTenant` is absent and throws when present; `Tenant` of `Dev` passes; generated `Apply-Dev.yaml` has both resources and the compile-time download choice, and every token is filled.
- [ ] **Step 2: Run to see them fail** (`-Path tests\PipelineApplyTenant.Tests.ps1 -Fast`). **Step 3: Implement.** **Step 4: Run, pass; then the whole suite** `pwsh -NoProfile -File tools\Invoke-PETests.ps1 -Fast` (existing apply tests must still pass). Commit `feat: Apply-Dev can apply a tenant changes revert, and refuses another tenant's`.

### Task 8: Documents

**Files:**
- Modify: `pipelines/README.md` (table row, a "Tenant changes" section: parameters, outputs, how to revert or promote, the run-name counter, the permission prerequisite "View builds"), `docs/overview.md` (tools list), `docs/handover.md` (deliberate gaps: promote configuration not compiled; object ids that differ between tenants are not translated; Prod not offered until its config and export pipeline exist; old export runs have no `vN`; the first run after a pin bump has no usable previous)

- [ ] **Step 1: Write the three edits. Step 2: Run** `pwsh -NoProfile -File tools\Invoke-PETests.ps1 -Fast` (the ADO manifest test checks the tool path exists). **Step 3: Commit** `docs: tenant changes pipeline`.

### Task 9: Live acceptance in ADO (with the user)

The rule being proved: **export, make one small change (create a group), export again, and the only thing in the changes is that group. Anything else is noise in our tooling and must be fixed.**

- [ ] **Step 1:** Merge the branch to `main`, regenerate the YAML (`pipelines\scripts\New-PipelineYaml.ps1`), copy to the ADO repo (`tools\Export-PEAdoRepo.ps1`), create the `M365DSC - Tenant changes` pipeline from `Tenant-Changes.yaml`, re-save `Apply-Dev`. Confirm the build identity has View builds on the export pipelines.
- [ ] **Step 2:** Run `Export Dev` twice with no tenant change between them; run `Tenant-Changes` (Dev, blank, blank). Expected: the log's first line `Dev changes: v<n-1> -> v<n>`, `No changes`, a green run. Every finding shown is **noise**: record each item and property, fix the cause in the tooling (a `Data\` ignore list first), add a regression fixture to Task 1's file, merge, and repeat until it reports no changes.
- [ ] **Step 3:** In the Dev tenant create one group (the user, or Claude if the live write to the test tenant is authorised), run `Export Dev`, run `Tenant-Changes`. Expected: `DevChanges.html` lists exactly that group; `DevChanges.ps1` creates it; `Revert\Removals.ps1` removes it. Anything else is noise: same loop as Step 2.
- [ ] **Step 4:** `Apply-Dev` with `source: TenantChanges`, mode Test, then Apply with removals (after approval): the group is gone and the next `Export Dev` plus `Tenant-Changes` shows no changes. Run `Tenant-Changes` for PreProd once: report and configuration text only, no MOF, green.
- [ ] **Step 5:** Record results and any deliberate gap in `docs/handover.md`; push `main`.

---

## Self-review

- **Spec coverage:** shape and parameters (Tasks 4, 6); outputs and names (2, 3); readable run names (6); resolver and refusals (4); apply, Dev only, tenant check, Approved Apply refusal (3, 7); non-goals respected (no trigger, no promote pipeline, no per-item choice); constraints (thin wrapper, Task 1 stop rule, pin message in 2, YAML thin, generator tokens, docs and handover in 8); your noise test is Task 1 offline and Task 9 live.
- **One deviation from the design:** the `tenant` list is fixed at Dev and PreProd in the template, not generated from the settings (Prod has no config or export pipeline yet; adding it is one template value and one map entry). Task 6 says so.
- **Type consistency:** the variable names set by Task 4 (`DEFINITION_ID`, `ARTIFACT_NAME`, `LATEST_RUN`, `PREVIOUS_RUN`) are the ones Task 6 consumes; Task 2's tool parameters are the ones Task 5 passes; `summary.json` fields are those Task 7 reads.
