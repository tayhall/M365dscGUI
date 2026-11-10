# Workload Checkboxes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The export pipelines and the compare pipeline pick workloads with one checkbox each (Entra ID, Intune, Exchange Online, Teams, Security and Compliance) instead of a typed list such as `AAD,Intune,EXO,Teams`.

**Architecture:** Azure DevOps runtime parameters render a boolean as a checkbox (there are no radio buttons; a string with `values` is a dropdown). `pipelines\scripts\New-PipelineYaml.ps1` expands two new tokens in the `*.yaml.template` files into one boolean parameter per workload of `src/PolicyEngine/Data/Workloads.psd1` (the engine's own list, default ticked = its `Default` flag) and the matching `PE_WL_<Prefix>` environment entries. A new script `Get-WorkloadSelection.ps1` turns those environment values back into the comma list the existing scripts take, so the YAML stays thin and the workload list has one source.

**Tech Stack:** PowerShell 7.6, Pester 5.7.1 (`tools\Invoke-PETests.ps1`), Azure DevOps YAML.

**Spec:** none (UI change). Existing behaviour: `docs/overview.md` and `pipelines/README.md` ("The YAML stays thin").

## Global Constraints

- The workload list comes only from `src/PolicyEngine/Data/Workloads.psd1` (`Prefix`, `Name`, `Default`); nothing in the YAML templates or scripts lists workloads by hand.
- Parameter names are the DSC prefixes exactly (`AAD`, `Intune`, `EXO`, `Teams`, `SC`); the environment entries are `PE_WL_<Prefix>`; a ticked box reaches the script as the text `True`.
- `Invoke-PipelineExport.ps1 -Workloads <list>` and `Invoke-PipelineCompare.ps1 -CompleteWorkloads <list>` keep working for manual runs; the checkboxes are used only when the list is not given.
- Generated YAML must contain no leftover `__TOKEN__` and must not splice parameter values into script text (they travel as environment variables).
- `Apply-Dev.yaml`'s `workloads` stays a typed, ordered list (it is an apply order, not a selection).
- Run tests with `pwsh -NoProfile -File tools\Invoke-PETests.ps1 -Path <file> -Fast` (one file per call); the full suite once before each commit. Do not write log files outside the worktree.

## Review Focus

- No workload ticked in an export: the run stops with a clear message before connecting to the tenant. Task 1.
- Compare with no box ticked is allowed (nothing is treated as complete) and differs from "no `PE_WL_` variable at all" (manual run: the old default list). Task 1.
- A new workload added to `Workloads.psd1` appears in the generated YAML with no other edit. Task 2.
- SC is unticked by default because its `Default` is false; the others are ticked. Task 2.
- The generator keeps refusing leftover tokens and never deletes anything. Task 2.

---

### Task 1: Turn the ticked boxes into the workload list

**Files:**
- Create: `pipelines/scripts/Get-WorkloadSelection.ps1`
- Modify: `pipelines/scripts/Invoke-PipelineExport.ps1`, `pipelines/scripts/Invoke-PipelineCompare.ps1`
- Test: `tests/WorkloadSelection.Tests.ps1`

**Interfaces:**
- Produces: `pipelines\scripts\Get-WorkloadSelection.ps1 [-AllowNone] [-WorkloadsPath <string>]` returns a `[string]` comma list of the prefixes whose environment variable `PE_WL_<Prefix>` is `True` (case-insensitive), in the order of `Workloads.psd1` (`-WorkloadsPath` defaults to `src\PolicyEngine\Data\Workloads.psd1`). With nothing ticked it throws `No workload is ticked. Tick at least one workload.` unless `-AllowNone` (then it returns an empty string).
- `Invoke-PipelineExport.ps1`: `-Workloads` is no longer mandatory; when empty it uses `Get-WorkloadSelection.ps1`, and does so before connecting to the tenant. When both are given the typed value wins.
- `Invoke-PipelineCompare.ps1`: when `-CompleteWorkloads` is not bound and at least one `PE_WL_*` environment variable exists, it uses `Get-WorkloadSelection.ps1 -AllowNone`; otherwise it keeps its current default.

- [ ] **Step 1: Write failing tests** in `tests/WorkloadSelection.Tests.ps1` (set and clear `PE_WL_*` environment variables in `BeforeEach`/`AfterEach`; use a temp copy of a `Workloads.psd1` for the order and new-workload cases): `returns the ticked prefixes in Workloads.psd1 order`, `reads True case-insensitively and ignores any other value`, `throws when nothing is ticked`, `returns an empty string with -AllowNone`, `ignores PE_WL_ variables that are not in the workload list`, `picks up a workload added to the list without any other change`. Add that `Invoke-PipelineExport.ps1` stops with the no-workload message before it tries to connect (use the repo's test style for pipeline scripts, see `tests/ApplyScriptParams.Tests.ps1`) and that a typed `-Workloads` still wins.

- [ ] **Step 2: Run them to see them fail.**

- [ ] **Step 3: Implement** the script and the two script changes.

- [ ] **Step 4: Run `tests\WorkloadSelection.Tests.ps1` and the existing tests of the two scripts; all pass.**

- [ ] **Step 5: Commit** `feat: pipeline scripts read the workload checkboxes`.

### Task 2: Generate the checkboxes into the pipeline YAML

**Files:**
- Modify: `pipelines/scripts/New-PipelineYaml.ps1`, `pipelines/Export-Dev.yaml.template`, `pipelines/Export-PreProd.yaml.template`, `pipelines/Compare-PreProd-to-Dev.yaml.template`, `pipelines/README.md`
- Test: `tests/PipelineYaml.Tests.ps1`

**Interfaces:**
- Consumes: Task 1's `PE_WL_<Prefix>` convention.
- Produces: three generator tokens, each alone on its line in a template and replaced by the lines it expands to with the token line's own indentation kept:
  - `__EXPORT_WORKLOAD_PARAMETERS__`: per workload `- name: <Prefix>`, `displayName: '<Name> (<Prefix>)'`, `type: boolean`, `default: <true|false from the Default flag>`.
  - `__COMPLETE_WORKLOAD_PARAMETERS__`: the same with `displayName: 'Complete in the Dev export: <Name> (<Prefix>)'`.
  - `__WORKLOAD_ENV__`: per workload `PE_WL_<Prefix>: ${{ parameters.<Prefix> }}`.
- The Export templates drop the `workloads` string parameter and `PE_WORKLOADS`; the Compare template drops `completeWorkloads` and `PE_COMPLETE_WORKLOADS`; the script text no longer passes `-Workloads` / `-CompleteWorkloads`.

- [ ] **Step 1: Write failing tests** in `tests/PipelineYaml.Tests.ps1`: `the export pipelines have one boolean parameter per workload of Workloads.psd1, ticked as its Default says` (SC default false, the other four true), `the export and compare pipelines pass each workload to the script as a PE_WL_ environment variable`, `the export pipelines no longer have a workloads text parameter and the compare pipeline no longer has completeWorkloads`, `the compare pipeline labels its boxes as complete in the Dev export`, `a workload added to a temp Workloads.psd1 appears in every generated pipeline that uses the tokens` (point the generator at a temp copy; add a `-WorkloadsPath` parameter to `New-PipelineYaml.ps1` for this, default the repo file), `no parameter value is spliced into the script text`. Keep the existing "fills every token" test green.

- [ ] **Step 2: Run them to see them fail.**

- [ ] **Step 3: Implement** the generator expansion (read `Workloads.psd1` with `Import-PowerShellDataFile`; keep the generator's rules: it stops on leftover tokens, never deletes) and the three template edits.

- [ ] **Step 4: Update `pipelines/README.md`** (the export and compare rows and the "Configuration" text): workloads are checkboxes generated from `Workloads.psd1`; SC is unticked by default; after a change to the workload list, regenerate the YAML.

- [ ] **Step 5: Run `tests\PipelineYaml.Tests.ps1`, then the full suite; all pass.**

- [ ] **Step 6: Commit** `feat: workload checkboxes in the export and compare pipelines`.

### Task 3: Rollout (confirm before running)

**Files:** none in this repo; the ADO copy of the project (`M365dscGUI/` in the `DSCGui` repo).

- [ ] **Step 1: Apply Tasks 1 and 2 to the ADO copy**, regenerate the YAML there with its `pipeline.settings.psd1`, reapply the hosted-pool `vmImage` edit to every generated file, validate the three pipelines with Azure DevOps' preview endpoint (it expands the YAML without running it) and check the checkboxes appear, then commit and push (needs the user's go-ahead).
- [ ] **Step 2: Prove it** with one export run with a single box ticked.
