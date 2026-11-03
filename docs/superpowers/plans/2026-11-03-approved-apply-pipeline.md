# Approved-drift Apply (engine and pipeline) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An approved list (a committed JSON file of items) drives a new Apply pipeline that builds one MOF per resource type for only the approved items, with the spec's guards, and can be re-run until everything is done.

**Architecture:** New PolicyEngine functions read and validate the list, fingerprint and check exports, compare PreProd with Dev (extracted from the existing compare tool), and generate configuration per approved item through the engine's own `New-PERectifyPlan` / `ConvertTo-PEDscConfig`. A thin tool builds MOFs; a thin pipeline script applies them through the LCM. The GUI half is a separate plan (`2026-11-03-approved-apply-gui.md`); until it exists a list is made by `New-PEApprovedList`.

**Tech Stack:** PowerShell 7.6+, Pester 5.7.1, Microsoft365DSC 2.26.1021.1, Azure DevOps YAML.

**Spec:** `docs/superpowers/specs/2026-11-03-approved-drift-apply-design.md`

## Global Constraints

- PowerShell 7.6+, LF line endings, no C#. Function bodies use Allman braces, 4-space indent; Pester blocks keep the opening brace on the same line.
- Run tests with `pwsh -NoProfile -File tools\Invoke-PETests.ps1 -Path <file> -Fast`; run the whole suite (no `-Fast`) before the last commit of each task that touches existing code.
- Thin wrapper over DSC and the engine (`CLAUDE.md`): call `New-PERectifyPlan`, `ConvertTo-PEDscConfig`, `Sort-PERevertEntry`, `Compare-PEState`, `Invoke-M365DSCConfigurationBuild` and `tools\Invoke-PELcm.ps1`; do not copy their logic or any per-resource knowledge.
- The approved list names items and excluded property names only. It never holds a property value.
- Dev only. Test mode is the default. The Writer certificate is removed from the agent after every run.
- Pipeline YAML stays thin: one script call per step, checks inside the scripts. YAML sources are `*.yaml.template` with `__TOKENS__` filled by `pipelines\scripts\New-PipelineYaml.ps1`.
- Run outcomes per approved item are exactly: `Applied`, `NoActionRequired`, `NotGenerated`, `Failed`, `Skipped`.
- Commit messages end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Review Focus

- A list edited by hand to carry a property value, an unknown action or an unknown key is refused (Task 2).
- An export folder with no `export.log`, or with a line "Graph reported N items but only M were returned" where M < N, is not complete and the build refuses it (Tasks 1, 6).
- Re-running a list after a partial apply: an item already in Dev is `NoActionRequired` and the run continues (Task 5).
- An approved Remove of an object that PreProd also has is `Skipped` and never removed (Task 5).
- An export replaced by a different one under the same run id (fingerprint mismatch), or a Dev export older than the limit, stops the run before anything is written (Task 6); a run from a branch other than the default stops before any tenant access (Task 7).

---

### Task 1: Export fingerprint and completeness check

**Files:**
- Create: `src/PolicyEngine/Public/ExportIntegrity.ps1`
- Modify: `src/PolicyEngine/Public/New-PEStateFromExport.ps1` (add `ExportFingerprint` to the state's Meta, next to `ExportedAt` at line 75)
- Test: `tests/ExportIntegrity.Tests.ps1`

**Interfaces:**
- Produces: `Get-PEExportFingerprint -Path <string>` (folder holding `export.ps1`) returns a lowercase 64-character SHA-256 string of the file after UTF-8 decoding, removing a leading BOM and turning CRLF into LF.
- Produces: `Test-PEExportComplete -Path <string>` returns `[pscustomobject]@{ Complete = [bool]; LogPresent = [bool]; FailedComponents = [string[]]; Shortfalls = [string[]] }`. `Complete` is false when `export.log` is missing, when any component is not `Ok` (use `Read-PEExportLog`), or when a line matches `Graph reported (\d+) items but only (\d+) were returned` with the second number below the first (put that line in `Shortfalls`).
- Produces: state Meta key `ExportFingerprint` (string) from `New-PEStateFromExport`.

- [ ] **Step 1: Write the failing tests** in `tests/ExportIntegrity.Tests.ps1`: `'gives the same fingerprint for CRLF, LF and BOM copies of one export'`, `'gives a different fingerprint when one character changes'`, `'is complete for a log with no failures'`, `'is not complete without export.log'` (`LogPresent` false), `'reports a failed component by name'` (use `tests/fixtures/export-log.txt`, which has failures), `'reports a shortfall line'` (a log line `WARNING: [/deviceManagement/x] Graph reported 100 items but only 0 were returned (100% shortfall).` gives `Shortfalls.Count` 1 and `Complete` false), `'ignores a line where all items were returned'` (`reported 5 items but only 5 were returned`), and `'records ExportFingerprint in the state Meta'` (`(New-PEStateFromExport -Path $folder).Meta.ExportFingerprint | Should -Be (Get-PEExportFingerprint -Path $folder)`), plus one test that an upload staged by `New-PEUploadCheck` for `tests/fixtures/upload/entra.ps1` has the same fingerprint as the original folder.
- [ ] **Step 2: Run** `pwsh -NoProfile -File tools\Invoke-PETests.ps1 -Path tests\ExportIntegrity.Tests.ps1 -Fast`. Expected: FAIL (functions not defined).
- [ ] **Step 3: Implement** both functions in `ExportIntegrity.ps1` (dot-sourced like the other Public files) and add the Meta key. Use `[System.Security.Cryptography.SHA256]::HashData`.
- [ ] **Step 4: Run** the new test file, then the whole suite. Expected: all PASS (no existing test compares whole Meta objects; if one does, update that expectation).
- [ ] **Step 5: Commit** `feat: export fingerprint and completeness check`.

### Task 2: The approved list (format, save, read)

**Files:**
- Create: `src/PolicyEngine/Public/ApprovedList.ps1`
- Test: `tests/ApprovedList.Tests.ps1`

**Interfaces:**
- Produces: `New-PEApprovedList -Tenant <slug> -ApprovedBy <string> -Source <hashtable> -Target <hashtable> -Item <object[]> [-ModuleVersion <string>] [-CreatedUtc <datetime>]`. `Source` and `Target` are `@{ Run = '<digits>'; ExportedAt = '<UTC ISO 8601>'; Fingerprint = '<64 hex>' }`. An item is `@{ Action = 'Create'|'Update'|'Remove'; ResourceType; Key; ExcludedProperties = @() }`. Returns the list object `[pscustomobject]@{ Format = 1; CreatedUtc; ApprovedBy; Tenant; ModuleVersion; Source; Target; Items; Counts }` where `Counts` is a list of `@{ ResourceType; Action; Count }`, derived, not supplied. `ModuleVersion` defaults to `Get-PEPinnedVersion -Name Microsoft365DSC`.
- Produces: `Save-PEApprovedList -List <object> -Path <string>` writes UTF-8 without BOM, LF, indented JSON, creates the folder, and refuses to overwrite an existing file.
- Produces: `Read-PEApprovedList -Path <string>` returns the validated list or throws a message starting `Approved list <path>:`.
- Validation (applied by `Read-PEApprovedList`, and by `New-PEApprovedList` before it returns): `Format` is 1; Action in the three values; `ResourceType` matches `\A[A-Za-z][A-Za-z0-9]*\z`; `Key` is one line, 1 to 500 characters, no control characters; no duplicate (Action, ResourceType, Key), compared case-insensitively; `ExcludedProperties` names match `\A[A-Za-z0-9_.]+\z`; `Run` matches `\A\d{1,12}\z`; `Fingerprint` is 64 hex; `ApprovedBy` is 1 to 100 characters with no control characters; `Tenant` matches `(?-i)\A[a-z0-9][a-z0-9-]{0,39}\z`; no properties other than the documented ones at any level; `Counts` equals the recomputed counts.

- [ ] **Step 1: Write the failing tests**: `'round-trips a list through Save and Read'`, `'counts items per type and action'` (3 Create AADGroup + 1 Update gives two rows with 3 and 1), `'refuses to overwrite a saved list'`, and `'Read refuses <case>'` as a `-ForEach` table: unknown action `Delete`; an item with an extra `Value` property; an extra top-level property; duplicate item differing only in key case; a key with a newline; a bad fingerprint; a bad run id `12a`; a hand-edited `Counts`; `Format` 2; a `Tenant` of `Dev Tenant`; an `ExcludedProperties` entry `a b`.
- [ ] **Step 2: Run** `pwsh -NoProfile -File tools\Invoke-PETests.ps1 -Path tests\ApprovedList.Tests.ps1 -Fast`. Expected: FAIL.
- [ ] **Step 3: Implement** the three functions with a private validator used by both `New-` and `Read-`. Read the file with `ConvertFrom-Json`, then check properties against allow-lists of names.
- [ ] **Step 4: Run** the test file. Expected: PASS.
- [ ] **Step 5: Commit** `feat: approved list format with strict validation`.

### Task 3: Extract the export comparison into the module

**Files:**
- Create: `src/PolicyEngine/Public/Invoke-PEExportComparison.ps1`
- Modify: `tools/Invoke-PEPipelineCompare.ps1` (replace its `Invoke-ComparisonRun` function body with a call to the new function)
- Test: `tests/ExportComparison.Tests.ps1`

**Interfaces:**
- Produces: `Invoke-PEExportComparison -SourceExportPath <string> -TargetExportPath <string> -TargetTenantDomain <string> -DataRoot <string> [-CompleteWorkload <string[]>] [-WorkloadPrefix <string>] [-Decision <object[]>]` returns `[pscustomobject]@{ Findings; Check; Blueprint; DataRoot; SourceState }`. It does exactly what `Invoke-ComparisonRun` in the tool does today (source becomes blueprint `source`, tenant `target` is offline with its own blueprint, target export is uploaded, `Compare-PEState` runs with `-Decisions $Decision`), including the `CompleteWorkload` prefix-to-name mapping and filtering to the workloads the target has records of. `-WorkloadPrefix` restricts the source as the tool does.
- Consumes: `New-PEStateFromExport`, `Initialize-PEBlueprint`, `Set-PETenant`, `Initialize-PETenantBlueprint`, `New-PEUploadCheck`, `Get-PECheck`, `Get-PEBlueprint`, `Compare-PEState`.

- [ ] **Step 1: Write the failing test** using `tests/fixtures/upload/entra.ps1` as the source and `entra-drift.ps1` as the target (each copied into its own temp folder with an empty `export.log`): `'finds the missing, target-only and changed group'` asserts the findings are exactly `Missing AADGroup Finance`, `TargetOnly AADGroup Marketing` and `Changed AADGroup Sales` (property `MailNickname`), and `'passes decisions through'` (a `PropertyExcluded` decision for `Sales` / `MailNickname` / tenant `target` moves the difference out of `Differences`).
- [ ] **Step 2: Run** the test file. Expected: FAIL.
- [ ] **Step 3: Implement** the function by moving the tool's `Invoke-ComparisonRun` logic; make the tool call it. Behaviour of the tool must not change.
- [ ] **Step 4: Verify** with the test file, then run the tool on the same fixtures in both `-MofLayout` values and confirm the same files and `OpenFindings 3` as before; run the whole suite.
- [ ] **Step 5: Commit** `refactor: move the export comparison into the module`.

### Task 4: Shared safe configuration generation

**Files:**
- Create: `src/PolicyEngine/Private/ConfigSafe.ps1`
- Modify: `src/PolicyEngine/Public/New-PEOfflineConfig.ps1` (replace the `$accepted` / `$generate` script blocks with the new function)
- Test: `tests/ConfigSafe.Tests.ps1`; `tests/OfflineConfig.Tests.ps1` must stay green unchanged.

**Interfaces:**
- Produces: `ConvertTo-PEDscConfigSafe -Entry <object[]> -ConfigurationName <string> -Target <'Replica'|'Master'>` where each entry is `[pscustomobject]@{ Plan; Finding; Action }` (as `New-PEOfflineConfig` builds them). Returns `[pscustomobject]@{ Text = <string or $null>; Refused = @([pscustomobject]@{ Entry; Reason }) }`. It tries the whole list, and on an error narrows by halving down to single entries (the existing behaviour), so an entry the engine refuses lands in `Refused` and the rest is still generated.

- [ ] **Step 1: Write the failing tests** (in `InModuleScope PolicyEngine`, mocking `ConvertTo-PEDscConfig` to throw when the plan list contains the plan with `Key = 'bad'`): `'returns text for all entries when none is refused'`, `'refuses only the entry that fails and generates the rest'` (3 entries, `Refused.Count` 1, `Reason` equals the mocked message, mock called with the other two), `'returns null text when every entry is refused'`.
- [ ] **Step 2: Run** `pwsh -NoProfile -File tools\Invoke-PETests.ps1 -Path tests\ConfigSafe.Tests.ps1 -Fast`. Expected: FAIL.
- [ ] **Step 3: Implement** by moving the halving logic out of `New-PEOfflineConfig`; make that function use it and keep its output unchanged (`Manual` entries still carry the engine's message).
- [ ] **Step 4: Run** `tests\ConfigSafe.Tests.ps1` and `tests\OfflineConfig.Tests.ps1` (without `-Fast`), then the whole suite. Expected: PASS.
- [ ] **Step 5: Commit** `refactor: share the narrowing config generation`.

### Task 5: Build the approved configuration (the five outcomes)

**Files:**
- Create: `src/PolicyEngine/Public/New-PEApprovedConfig.ps1`
- Test: `tests/ApprovedConfig.Tests.ps1`

**Interfaces:**
- Consumes: `Invoke-PEExportComparison` (Task 3), `ConvertTo-PEDscConfigSafe` (Task 4), a list from `Read-PEApprovedList` / `New-PEApprovedList` (Task 2), `New-PERectifyPlan`, `Sort-PERevertEntry`, `Split-PEDscConfigText`.
- Produces: `New-PEApprovedConfig -List <object> -SourceExportPath <string> -TargetExportPath <string> -TargetTenantDomain <string> -DataRoot <string>` returns `[pscustomobject]@{ Items; Configs }`. `Items` has one row per approved item: `Action, ResourceType, Key, Outcome ('ToApply'|'NoActionRequired'|'NotGenerated'|'Skipped'), Reason, ResourceId` (`ResourceId` is the DSC instance as the LCM reports it, for example `[AADGroup]Finance`, set for `ToApply`). `Configs` is ordered for applying: `@{ ResourceType; Phase ('Changes'|'Removals'); Text; ItemCount }`, one per type and phase, Create and Update items in `Changes`, Remove items in `Removals`; order is `Sort-PERevertEntry` order (parents before children), Removals after all Changes.
- Outcome rules: the list's `ExcludedProperties` become in-memory `PropertyExcluded` decisions (tenant `target`) passed to the comparison and the plan. **Create**: Open Missing finding gives `ToApply`; no finding and the key present in the target state gives `NoActionRequired` ("exists and matches"); a Changed finding gives `Skipped` ("exists but differs, approve an Update"). **Update**: Open Changed gives `ToApply`; no finding and present gives `NoActionRequired`; Missing gives `Skipped` ("no longer exists in Dev"). **Remove**: Open TargetOnly with no hint gives `ToApply` (with an in-memory Remove decision, as `New-PEOfflineConfig` does); key absent from the target state gives `NoActionRequired` ("already gone"); present in both gives `Skipped` ("PreProd has it"). Any other finding kind (Ambiguous, PossibleRename, Excluded, NotChecked, Unkeyed) gives `Skipped` naming the kind. A refusal from `New-PERectifyPlan` or `ConvertTo-PEDscConfigSafe` gives `NotGenerated` with the engine's message. Nothing outside the list is ever planned.

- [ ] **Step 1: Write the failing tests** with source `entra.ps1`, target `entra-drift.ps1` (Finance missing, Marketing target-only, Sales changed in `MailNickname`), each in a temp folder with an empty `export.log`: `'creates, updates and removes only the approved items'` (list = Create Finance, Update Sales, Remove Marketing gives three `ToApply`, two `Changes` configs' worth and one `Removals` config, texts contain `Finance`, `Sales`, `Marketing` and no other group); `'does not plan a group that is not in the list'` (list = Create Finance only: no text mentions `Sales` or `Marketing`); `'is NoActionRequired for every item when Dev already matches'` (target = a copy of the source: same three items, all `NoActionRequired`, `Configs.Count` 0); `'skips a Remove of an object PreProd also has'` (Remove Finance with the target = source: `Skipped`, reason mentions PreProd); `'skips a Create that exists but differs'` (Create Sales); `'skips an Update whose object is gone'` (Update Finance against the drift target); `'keeps Dev''s value for an excluded property'` (Update Sales with `ExcludedProperties = @('MailNickname')`: item is `NoActionRequired` because the only difference is excluded); `'marks an engine refusal NotGenerated and generates the rest'` (mock `New-PERectifyPlan` to throw for `Sales`: that item `NotGenerated` with the message, `Finance` still `ToApply`); `'fills ResourceId for ToApply items'`. Mark tests that parse generated DSC with `-Tag Slow` like the existing ones.
- [ ] **Step 2: Run** `pwsh -NoProfile -File tools\Invoke-PETests.ps1 -Path tests\ApprovedConfig.Tests.ps1`. Expected: FAIL.
- [ ] **Step 3: Implement** `New-PEApprovedConfig`, generating per type and phase with `ConvertTo-PEDscConfigSafe -Target Replica` and naming the configuration `PE_<ResourceType>_<Phase>`. Get `ResourceId` from the item's block (`Split-PEDscConfigText`).
- [ ] **Step 4: Run** the test file (without `-Fast`) and the whole suite. Expected: PASS.
- [ ] **Step 5: Commit** `feat: build configuration for an approved list with five outcomes`.

### Task 6: The build tool with the run-level guards

**Files:**
- Create: `tools/Invoke-PEApprovedBuild.ps1`
- Test: `tests/ApprovedBuild.Tests.ps1`

**Interfaces:**
- Consumes: `Read-PEApprovedList`, `Test-PEExportComplete`, `Get-PEExportFingerprint` (Tasks 1, 2), `New-PEApprovedConfig` (Task 5).
- Produces: `tools\Invoke-PEApprovedBuild.ps1 -ListPath <string> -SourceExportPath <string> -TargetExportPath <string> -TargetTenantDomain <string> -OutputPath <string> [-MaxAgeDays <int> = 7] [-ApplicationId <string> -CertificateThumbprint <string> -OrganizationName <string>] [-NoCompile]`. It stops, writing nothing into `OutputPath`, when: either export is not complete (G1, message lists failed components and shortfall lines); either export's fingerprint differs from the list's `Source` / `Target` fingerprint (G7); the list's `Target.ExportedAt` is older than `MaxAgeDays` (G8). Otherwise it writes `outcomes.json` (the `Items`), `summary.json` (`Totals` per outcome, `ByTypeAction` rows `{ ResourceType; Action; Count }`, and `Lines`, strings like `Create 10 AADGroup`), `NN-<Type>-<Phase>.ps1` for each config in apply order (`NN` two digits), and unless `-NoCompile` a MOF per config at `MOF\NN-<Type>-<Phase>\` with `Invoke-M365DSCConfigurationBuild -Engine Standard -ConfigurationName PE_<Type>_<Phase>` and a `ConfigurationData.psd1` written with values single-quote-escaped as `tools\Invoke-PEPipelineCompare.ps1` does. It prints `summary.Lines` and the totals.

- [ ] **Step 1: Write the failing tests** (`-NoCompile`, fixtures as in Task 5, lists built with `New-PEApprovedList` using `Get-PEExportFingerprint`): `'writes outcomes, summary and one script per type and phase'`, `'summary lines show per type and action counts'` (`Create 1 AADGroup`), `'stops on a fingerprint mismatch and writes nothing'`, `'stops on an incomplete export and names the failed component'` (log from `tests/fixtures/export-log.txt`), `'stops on a Graph shortfall line'`, `'stops when the Dev export is older than MaxAgeDays'` (`Target.ExportedAt` 30 days ago, default 7), `'accepts it within MaxAgeDays'`. For each stop assert the thrown message and that `OutputPath` has no files.
- [ ] **Step 2: Run** `pwsh -NoProfile -File tools\Invoke-PETests.ps1 -Path tests\ApprovedBuild.Tests.ps1`. Expected: FAIL.
- [ ] **Step 3: Implement** the tool as a thin wrapper; run all guards before creating any output file.
- [ ] **Step 4: Run** the test file and the whole suite. Expected: PASS. (Compiling is not covered offline; it is checked in Task 8.)
- [ ] **Step 5: Commit** `feat: build tool for an approved list with run-level guards`.

### Task 7: The pipeline script, template and settings

**Files:**
- Create: `pipelines/scripts/Invoke-PipelineApprovedApply.ps1`, `pipelines/Apply-Approved-Dev.yaml.template`
- Modify: `pipelines/scripts/New-PipelineYaml.ps1` (tokens `__EXPORT_PREPROD_PIPELINE_ID__`, `__EXPORT_DEV_PIPELINE_ID__`, `__DEFAULT_BRANCH__` from settings `ExportPreProdPipelineId`, `ExportDevPipelineId` (digits only), `DefaultBranch` (default `main`, pattern `\A[A-Za-z0-9._/-]{1,100}\z`)), `pipelines/pipeline.settings.example.psd1`, `pipelines/README.md`
- Test: `tests/PipelineApprovedApply.Tests.ps1`, `tests/PipelineYaml.Tests.ps1`

**Interfaces:**
- Consumes: `tools\Invoke-PEApprovedBuild.ps1` (Task 6), `Connect-PipelineTenant.ps1` (`-Environment Dev -Role Writer -ExpectedThumbprint`), `Disconnect-PipelineTenant.ps1`, `Get-PipelineConfig.ps1`, `tools\Invoke-PELcm.ps1`.
- Produces: `Invoke-PipelineApprovedApply.ps1 -ListPath <string> -PreProdExportPath <string> -DevExportPath <string> -OutputPath <string> [-Mode Test|Apply = Test] [-IncludeRemovals True|False = False] [-MaxAgeDays <int> = 7] [-DefaultBranch <string> = main]`. Order: (1) **G9**: `$env:BUILD_SOURCEBRANCH` must equal `refs/heads/<DefaultBranch>`, and `ListPath` must resolve inside the repo's `approvals` folder, else stop; (2) `Get-PipelineConfig.ps1 -Environment Dev` and the Writer thumbprint (`Connect-PipelineTenant.ps1 -ThumbprintOnly`); (3) the build tool with compile; (4) print the summary lines (the G4 counts) and publish nothing yet; (5) import the Writer certificate with `-ExpectedThumbprint`; (6) for each MOF in order, `Invoke-PELcm.ps1 -Mode Test` and print the preview; (7) in `Apply` mode, apply each MOF in order, **carrying on after a failure**, skipping `Removals` unless `-IncludeRemovals True`; (8) in a `finally`, run `Disconnect-PipelineTenant.ps1 -Slug dev -Role Writer`; (9) write `result.json` mapping each item to one of the five outcomes (`Applied` for a `ToApply` item whose `ResourceId` is in the LCM's `InDesiredState` after apply, `Failed` with the DSC error otherwise) and print the five counts, which must add up to the number of approved items. If every item is `Applied` or `NoActionRequired` it ends normally; otherwise it prints `##vso[task.complete result=SucceededWithIssues;]` and lists the items left.
- Retention (spec G7): after the two downloads the script takes a retention lease on both export runs (`POST {collection}/{project}/_apis/build/retention/leases?api-version=7.1` with `$(System.AccessToken)`, owner `approved-apply`, `daysValid` 60, `protectPipeline` false), so the same list can be re-run later. It prints a clear warning, and carries on, if the call is refused (the build identity may lack permission). The lease is not testable offline; Task 8 checks it.
- The job is a `deployment` job in environment `__DEV_ENVIRONMENT__` (the existing approval gate, as in `Apply-Dev.yaml.template`), so the counts printed by the build appear in the log of a run waiting for approval only if the approval comes after a `Test` run; document in the README that the safe sequence is a `Test` run (counts and preview), then an `Apply` run that waits for approval.
- Template parameters: `approvalFile` (string, a path under `approvals/`), `mode` (Test|Apply, default Test), `includeRemovals` (boolean, default false), `maxAgeDays` (number, default 7). Steps (thin): checkout; a script step that reads `approvalFile` with `Read-PEApprovedList` and sets variables `PREPROD_RUN` and `DEV_RUN` from the list (digits, already validated); two `DownloadPipelineArtifact@2` steps with `buildType: specific`, `buildId: $(PREPROD_RUN)` / `$(DEV_RUN)`, `pipeline: __EXPORT_PREPROD_PIPELINE_ID__` / `__EXPORT_DEV_PIPELINE_ID__`, artifacts `PreProdExport` / `DevExport`; the `AzurePowerShell@5` step calling the script with Dev's service connection; an `always()` cleanup step as in `Apply-Dev.yaml.template`; `publish` of the output folder as `ApprovedApplyReport`. Free-form parameters reach scripts through `env:`, as in the other templates.

- [ ] **Step 1: Verify the task inputs** by reading Microsoft's page for `DownloadPipelineArtifact@2` (`buildType: specific`, `project`, `pipeline`, `buildId`, `artifact`, `targetPath`); write the verified input names into the template, and if `pipeline` needs a definition id, keep the two id tokens above.
- [ ] **Step 2: Write the failing tests.** `PipelineApprovedApply.Tests.ps1`: `'stops when the build is not on the default branch'` (`BUILD_SOURCEBRANCH=refs/heads/feature/x`), `'stops when the list is outside approvals'`, `'refuses an unknown mode'`. `PipelineYaml.Tests.ps1`: `'fills every token and leaves none'` (generate into a temp copy with fake settings including the new keys), `'refuses a non-numeric pipeline id'`, and, when the `powershell-yaml` module is present, `'generated Apply-Approved-Dev.yaml parses and has the cleanup step with condition always()'`.
- [ ] **Step 3: Run** both files. Expected: FAIL.
- [ ] **Step 4: Implement** the script, template, generator tokens and settings example. Add a README section "Approved apply" describing the flow, the five outcomes, the re-run behaviour, `approvals/` and the branch policy recommendation.
- [ ] **Step 5: Run** both test files and the whole suite; parse-check the new scripts. Expected: PASS.
- [ ] **Step 6: Commit** `feat: approved-list Apply pipeline`.

### Task 8: Verify in a real pipeline and document

**Files:**
- Modify: `docs/handover.md` (a section "Approved apply"), `docs/superpowers/specs/2026-11-03-approved-drift-apply-design.md` (Status line)

- [ ] **Step 1: On a machine with the module installed**, build a list with `New-PEApprovedList` from two real exports and run `tools\Invoke-PEApprovedBuild.ps1` without `-NoCompile`. Expected: one MOF folder per type and phase.
- [ ] **Step 2: In Azure DevOps**, create the pipeline from the generated `Apply-Approved-Dev.yaml` and run it in `Test` mode from the default branch with a committed list. Expected: the counts print, the previews show, nothing is written, the certificate is gone afterwards. Run again from another branch. Expected: stops at G9.
- [ ] **Step 2b: Check the retention lease** exists for both export runs after the Test run (Azure DevOps: run, "Retained by a lease"), or that the warning explains why not.
- [ ] **Step 3: Run `Apply` mode** on a list of one harmless item, then run it again. Expected: first `Applied`, second `NoActionRequired`, and the second run ends green.
- [ ] **Step 4: Write** the handover section (what it does, the guards, what is left: the GUI plan) and set the spec Status to "pipeline part implemented; GUI part pending". Run the whole suite one last time.
- [ ] **Step 5: Commit** `docs: approved apply handover`.
