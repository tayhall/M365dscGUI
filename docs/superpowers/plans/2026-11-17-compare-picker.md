# One Compare pipeline with a From and a To picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One Compare pipeline in which the user picks the `from` and `to` tenant (Dev, PreProd, Prod); only PreProd to Dev builds MOFs and an approvable report.

**Architecture:** The exports are found at run time by pipeline name and downloaded by run id, as Tenant-changes does, instead of fixed pipeline resources. Prod becomes a third (read-only) tenant. Any pair other than PreProd to Dev produces the comparison and a read-only drift report (every item non-approvable) and no MOFs.

**Tech Stack:** PowerShell 7.6, Pester 5, Azure DevOps YAML templates (`pipelines\*.yaml.template`) filled by `pipelines\scripts\New-PipelineYaml.ps1`.

**Spec:** `docs/superpowers/specs/2026-11-17-compare-picker-design.md`

## Global Constraints

- Thin wrapper over Microsoft365DSC (CLAUDE.md): reuse `Invoke-PEPipelineCompare.ps1`, `New-PEDriftReport.ps1`, `Resolve-TenantExports.ps1`; no new comparison logic.
- Only PreProd to Dev may build MOFs or an approvable report. Nothing may be applied to PreProd or Prod.
- Dev to Dev is refused (use Tenant changes). `from` equal to `to` stops before any download.
- Pipeline ids are never settings: pipelines are found by name at run time.
- Existing settings files with no Prod keys must still generate, and PreProd to Dev output (summary.json fields `PreProdExportRun`, `DevExportRun`, the MOFs, `approved.json` format) must stay identical.
- Prod is read-only (Reader app only), like PreProd. Its export artifact is named `ProdExport`; export run names are `<Tenant>-<Workload>-v<counter>` as now.
- Tests run with `pwsh -NoProfile -Command "Invoke-Pester <file> -Output Minimal"`; every task ends with the touched test files green.

## Review Focus

- `from` equals `to`, or Dev to Dev: stops with a message naming Tenant changes, before any export is looked up.
- Prod not configured (no `ProdServiceConnection`): Prod is absent from every picker and `Export-Prod.yaml` is not generated; old settings files generate as before.
- Prod to Dev (target Dev but source not PreProd): report only, every item non-approvable, no MOFs, no Writer certificate read.
- A tenant with no successful export (or deleted artifact): the error names that tenant and says to take a fresh export.
- A same-name pipeline missing or duplicated for Prod: the lookup step names the pipeline it could not find.

---

### Task 1: Prod as a tenant (config, scripts, settings, Export-Prod pipeline)

**Files:**
- Create: `pipelines/config/Prod.psd1`, `pipelines/Export-Prod.yaml.template`
- Modify: `pipelines/scripts/Connect-PipelineTenant.ps1`, `Get-PipelineConfig.ps1`, `Invoke-PipelineExport.ps1`, `Invoke-PipelineTenantChanges.ps1`, `Resolve-TenantExports.ps1`, `Test-PipelineSignIn.ps1`, `Resolve-ExportPipelineIds.ps1`, `New-PipelineYaml.ps1`; `pipelines/pipeline.settings.example.psd1`, `pipelines/Tenant-Changes.yaml.template`
- Test: `tests/PipelineYaml.Tests.ps1`, `tests/PipelineApprovalHelpers.Tests.ps1`, `tests/PipelineConfigCertSecret.Tests.ps1`

**Interfaces:**
- Produces: every `-Environment` / `-Tenant` / `-Role` parameter lists accept `'Dev','PreProd','Prod'`. `Resolve-ExportPipelineIds.ps1` gains `[string]$ProdName = ''`; when given it also sets `EXPORT_PROD_ID`. Settings gain optional `ProdServiceConnection` (setting it enables Prod) and `ExportProdPipeline` (default `'M365DSC - Export Prod tenant'`). Generator line-token `__TENANT_CHOICES__` expands to `- Dev`, `- PreProd` and `- Prod` only when Prod is enabled. `Export-Prod.yaml` is generated only when Prod is enabled. `Tenant-Changes.yaml` offers Prod and its `PE_TENANT_MAP` gains `Prod=$(EXPORT_PROD_ID)` only when enabled (a line-token such as `__PROD_MAP__` or equivalent; the builder chooses).

- [ ] **Step 1: Write failing tests.** In `PipelineYaml.Tests.ps1`: (a) `'generates Export-Prod.yaml and offers Prod only when ProdServiceConnection is set'` (settings with `ProdServiceConnection = 'sc-prod'`: file exists, `Tenant-Changes.yaml` contains `- Prod` and `Prod=$(EXPORT_PROD_ID)`; without it: file absent, no `Prod`); (b) `'Export-Prod publishes the ProdExport artifact with the sc-prod connection'`. In `PipelineApprovalHelpers.Tests.ps1`: `'Resolve-ExportPipelineIds sets EXPORT_PROD_ID when -ProdName is given'` (mock `Invoke-RestMethod` as the existing test does). In `PipelineConfigCertSecret.Tests.ps1`: `Get-PipelineConfig.ps1 -Environment Prod` reads a `Prod.psd1`.
- [ ] **Step 2: Run them; expected FAIL** (Prod not a valid value, token missing).
- [ ] **Step 3: Implement.** Widen the six `ValidateSet`s and the `$moved` regex (`Dev|PreProd|Prod`); `Prod.psd1` from `PreProd.psd1` (`TenantDomain`, `KeyVault`, `ShortName`, `ReaderAppId`, optional `ReaderCertSecret`, all `CHANGE-ME`); `Export-Prod.yaml.template` copied from `Export-PreProd.yaml.template` with `Prod` and `__PROD_SERVICE_CONNECTION__`/`__EXPORT_PROD_PIPELINE__`; generator: Prod enabled when `ProdServiceConnection` is in the settings, skip `Export-Prod.yaml.template` otherwise, add the two tokens and the line-tokens above (empty expansion when disabled), reject `ExportProdPipelineId`-style id settings the same way as the other ids.
- [ ] **Step 4: Run the three test files plus `AdoRepoExport.Tests.ps1`; expected PASS.**
- [ ] **Step 5: Commit** `feat: Prod as a read-only tenant (config, export pipeline, settings)`.

### Task 2: Find one tenant's latest export without needing a previous one

**Files:**
- Modify: `pipelines/scripts/Resolve-TenantExports.ps1`
- Test: `tests/ResolveTenantExports.Tests.ps1`

**Interfaces:**
- Produces: two new parameters on `Resolve-TenantExports.ps1`: `[switch]$NoPrevious` (skips the previous-run lookup and its refusals; result `.Previous` is `$null`) and `[string]$VariablePrefix = ''`. With `-SetVariables` and a non-empty prefix (for example `FROM_`) it writes `<prefix>DEFINITION_ID`, `<prefix>ARTIFACT_NAME`, `<prefix>RUN`, `<prefix>NAME` (the latest run) and no `LATEST_*`/`PREVIOUS_*`; with an empty prefix behaviour is unchanged.

- [ ] **Step 1: Write failing tests** in the existing mock style: `'-NoPrevious returns the latest run when no earlier export exists'`; `'-NoPrevious -VariablePrefix FROM_ -SetVariables writes FROM_RUN, FROM_NAME, FROM_DEFINITION_ID and FROM_ARTIFACT_NAME'`; `'a tenant with no successful export still stops, naming the tenant'` (with `-NoPrevious`); `'-ExportVersion v7 -NoPrevious picks that run'`.
- [ ] **Step 2: Run; expected FAIL** (unknown parameter).
- [ ] **Step 3: Implement** the two parameters; the "no earlier successful export" refusal applies only without `-NoPrevious`; the `Write-Host` line says `<tenant> export <name> (run <id>)` when `-NoPrevious`.
- [ ] **Step 4: Run `ResolveTenantExports.Tests.ps1` and `PipelineTenantChanges.Tests.ps1`; expected PASS** (existing behaviour unchanged).
- [ ] **Step 5: Commit** `feat: Resolve-TenantExports can find a single latest export (-NoPrevious, -VariablePrefix)`.

### Task 3: A read-only drift report

**Files:**
- Modify: `src/PolicyEngine/Private/DriftReportData.ps1` (`Get-PEDriftReportData`), `tools/New-PEDriftReport.ps1`
- Test: `tests/DriftReportData.Tests.ps1`, `tests/DriftReportTool.Tests.ps1`

**Interfaces:**
- Produces: `Get-PEDriftReportData ... -ReadOnlyReason <string>` and `New-PEDriftReport.ps1 ... -ReadOnlyReason <string>` (default empty). When given, every item has `Approvable = $false` and `Reason = $ReadOnlyReason`, nothing else changes (the page already shows non-approvable items with their reason and no checkbox).

- [ ] **Step 1: Write failing tests:** `'with -ReadOnlyReason every item is not approvable and carries the reason'`; `'without it the approvable items are unchanged'`; for the tool: `'-ReadOnlyReason produces a page with 0 approvable items'` (the tool already prints the approvable count).
- [ ] **Step 2: Run; expected FAIL.**
- [ ] **Step 3: Implement** by overriding `Approvable`/`Reason` after items are built, in `Get-PEDriftReportData`; pass the parameter through in the tool.
- [ ] **Step 4: Run `DriftReportData`, `DriftReportTool`, `DriftReportHtml`, `DriftReportPage` tests; expected PASS.**
- [ ] **Step 5: Commit** `feat: drift report can be built read-only`.

### Task 4: Compare script handles any pair

**Files:**
- Modify: `pipelines/scripts/Invoke-PipelineCompare.ps1`
- Test: `tests/PipelineCompare.Tests.ps1` (create; stub the called tools by the script's existing hook style or `Mock`/stub scripts)

**Interfaces:**
- Consumes: Task 1 tenants, Task 3 `-ReadOnlyReason`.
- Produces: `Invoke-PipelineCompare.ps1` gains `[ValidateSet('Dev','PreProd','Prod')][string]$SourceTenant = 'PreProd'` and `$TargetTenant = 'Dev'`, plus `$SourceRun`/`$TargetRun` as aliases of the existing `PreProdRun`/`DevRun` (defaults keep the current call working). Behaviour: same tenant stops with a message naming "Tenant changes"; PreProd to Dev runs exactly the existing path; any other pair skips `Connect-PipelineTenant`, `Invoke-PEPipelineCompare` and MOF building, reads the target's `TenantDomain` from `Get-PipelineConfig.ps1 -Environment <TargetTenant>`, runs `New-PEDriftReport.ps1` with `-Tenant <target slug> -SourceLabel <Source> -TargetLabel <Target> -ReadOnlyReason 'Read-only comparison: only PreProd to Dev can be applied.'`, and writes its own `summary.json` (`SourceTenant`, `TargetTenant`, `SourceExportRun`, `TargetExportRun`, `GeneratedAtUtc`).

- [ ] **Step 1: Write failing tests:** `'PreProd to Dev runs the existing compare with -Compile and the Writer certificate'`; `'Prod to PreProd reads no certificate, builds no MOF folder and writes a read-only report and summary'`; `'Prod to Dev is also read-only'`; `'the same tenant on both sides stops and names Tenant changes'`; `'the default call (no tenant parameters) still behaves as PreProd to Dev'`.
- [ ] **Step 2: Run; expected FAIL.**
- [ ] **Step 3: Implement** as described; keep the existing PreProd-to-Dev code path untouched.
- [ ] **Step 4: Run `PipelineCompare.Tests.ps1`, `PipelineApprovedApply.Tests.ps1`, `PipelineApplyTenant.Tests.ps1`; expected PASS.**
- [ ] **Step 5: Commit** `feat: Compare takes a source and a target tenant; only PreProd to Dev builds MOFs`.

### Task 5: The Compare YAML with pickers

**Files:**
- Modify: `pipelines/Compare-PreProd-to-Dev.yaml.template` (file and the `ComparePipeline` default name stay, because `Apply-Dev` reads this pipeline's artifacts by that name), `pipelines/scripts/New-PipelineYaml.ps1` (only if a token is missing)
- Test: `tests/PipelineYaml.Tests.ps1`

**Interfaces:**
- Consumes: Tasks 1, 2, 4. Produces: parameters `from`, `to` (`values:` from `__TENANT_CHOICES__`), `fromVersion`, `toVersion` (blank = latest successful Full export, or a name such as `v9`), `mofLayout` and the workload checkboxes as today; no `resources: pipelines`; steps: checkout, `Resolve-ExportPipelineIds.ps1`, `Resolve-TenantExports.ps1 -Tenant <from> -NoPrevious -VariablePrefix FROM_ -Workload Full` and the same for `TO_`, two `DownloadPipelineArtifact@2` steps (`FROM_DEFINITION_ID`/`FROM_RUN`/`FROM_ARTIFACT_NAME` into `$(Pipeline.Workspace)/from`, `TO_*` into `.../to`), install, the AzurePowerShell step with the service connection chosen by `to` at compile time, then `Invoke-PipelineCompare.ps1 -SourceTenant <from> -TargetTenant <to> -SourceExportPath '.../from/<artifact>' -TargetExportPath '.../to/<artifact>' -PreProdRun/-DevRun ... `; the run publishes the `DriftReport` artifact as today and updates the build number to `Compare <from> to <to>`.

- [ ] **Step 1: Write failing tests** in `PipelineYaml.Tests.ps1`: `'Compare has from and to pickers listing Dev and PreProd (and Prod only when enabled)'`; `'Compare has no pipeline resources and downloads both exports by the resolved ids'`; `'Compare chooses the service connection by the target tenant'`; `'Compare still publishes the DriftReport artifact that Apply-Dev reads'`; `'every token is filled'` (existing test must stay green).
- [ ] **Step 2: Run; expected FAIL.**
- [ ] **Step 3: Rewrite the template** to the interface above, copying the download and service-connection patterns from `Tenant-Changes.yaml.template`.
- [ ] **Step 4: Run `PipelineYaml.Tests.ps1` and generate with the sample settings (as in the earlier checks); the output must contain no `__TOKEN__`; expected PASS.**
- [ ] **Step 5: Commit** `feat: Compare pipeline picks the From and To tenants at run time`.

### Task 6: Docs, manifest, full run

**Files:**
- Modify: `pipelines/README.md`, `docs/handover.md`, `pipelines/ado-manifest.psd1` (new files are under `pipelines`, already included; confirm), `pipelines/pipeline.settings.example.psd1`
- Test: whole suite

- [ ] **Step 1:** Document in `pipelines/README.md`: the from/to pickers, which pair builds MOFs (PreProd to Dev only), Prod setup (`Prod.psd1`, an `Export-Prod` pipeline named as `ExportProdPipeline`, `ProdServiceConnection`), versions; add the deliberate gaps to `docs/handover.md` (apply is Dev-only; Prod to Dev is report-only; the Compare pipeline keeps its old name).
- [ ] **Step 2:** `pwsh -NoProfile -File tools\Invoke-PETests.ps1` (or `Invoke-Pester tests`): expected all pass.
- [ ] **Step 3:** Trial copy: `pwsh -NoProfile -File tools\Export-PEAdoRepo.ps1 -Destination <scratch> -RunTests`: expected all pass, nothing missing from the manifest.
- [ ] **Step 4: Commit and push** `docs: Compare picker and Prod tenant`.

---

Self-review: every design section maps to a task (pickers and run-time lookup: 2 and 5; Prod: 1; any pair report-only and PreProd to Dev unchanged: 3 and 4; labels/summary: 4; docs and the deliberate gaps: 6). Names used across tasks match (`-NoPrevious`, `-VariablePrefix`, `-ReadOnlyReason`, `SourceTenant`/`TargetTenant`, `FROM_*`/`TO_*`, `EXPORT_PROD_ID`, `ProdServiceConnection`, `ExportProdPipeline`).
