# Offline Snapshots Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a tenant that cannot be reached be represented by uploaded DSC export files, compared like any other tenant, and brought into line with a generated DSC configuration (changes file and a separate removals file), all through the GUI.

**Architecture:** An offline tenant is a normal tenant record flagged `Offline`. An upload becomes a stored Full check (`New-PEUploadCheck`), with the same findings, layers and decisions as a live check, plus a per-workload source and age. The configuration comes from the existing rectify machinery (`New-PERectifyPlan`, `ConvertTo-PEDscConfig`), never a second generator. The GUI gets an upload job, a download of the generated files and "uploaded / live" labels.

**Tech Stack:** PowerShell 7, Pester 5, Microsoft365DSC 2.26.1015.1 (pinned), DSCParser 3.1.0.7, Pode GUI (`gui/server.ps1`, `gui/PEGui.psm1`, `gui/public/assets/app.js`).

**Spec:** `docs/superpowers/specs/2026-10-26-offline-snapshots-design.md`

## Global Constraints

- Thin wrapper over Microsoft365DSC: no copies of its resource lists, schemas or per-resource knowledge; record every deliberate gap in `docs/handover.md`.
- An upload is accepted only when the DSC version in every file equals `Get-PEPinnedVersion -Name Microsoft365DSC` (now `2.26.1015.1`); otherwise the whole upload is refused naming both versions and nothing is stored.
- Version is read from the first line `# Generated with Microsoft365DSC version <v>` and must agree with `Import-DscResource ... -ModuleVersion '<v>'`; a file with no such line is refused.
- A type with no records in an upload is NotChecked (never "empty") unless the upload marks its workload complete.
- The configuration targets the tenant's own blueprint (last layer), like Revert. Removals only for Open TargetOnly findings, in a separate file. Anything DSC cannot create or remove goes to "needs manual action".
- Credentials in generated files are `$ConfigurationData.NonNodeData` references, never values. Secrets stay in `~\.m365dsc-policy\`.
- Tests first (Pester 5; mock bodies see the test file's `$script:` scope, read module variables with `& (Get-Module PolicyEngine) { $script:X }`). Full suite stays green (`tools\Invoke-PETests.ps1`, 1065 passing at start). Commits end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Push `main` after each task.
- Working copies are CRLF with LF in git; edit with LF/CRLF-safe replacement (see earlier `Rep` helper pattern) or the Edit tool.

## Review Focus

- A file with a different DSC version, or no version line, in a set of otherwise good files: whole upload refused, no check written.
- The same resource in two files: the later file wins, a warning names it.
- A second upload covering only Entra after a full set: other workloads keep their records, each workload keeps its own source and date.
- A failed or empty type in a log-less upload: NotChecked, never a Missing finding, never a Create line in the configuration.
- A removal for anything that is not an Open TargetOnly item (Accepted, Excluded, renamed-hint items): never in the removals file.
- A property on the ignored/secret lists or a tenant-bound key (certificate keys) needed by an item: never written; the item is listed as needs manual action.
- A huge upload body (an 8 MB+ Entra export as JSON text): accepted by the server and stored once.

---

### Task 1: Offline tenant record

**Files:**
- Modify: `src/PolicyEngine/Public/Tenants.ps1` (`Get-PETenant`, `Set-PETenant`)
- Modify: `src/PolicyEngine/Public/Export-PEGuiData.ps1:112,330` (tenant entries gain `offline`)
- Test: `tests/Tenants.Tests.ps1`, `tests/GuiExport.Tests.ps1`

**Interfaces:**
- Produces: `Get-PETenant` objects gain `Offline` (`[bool]`, default `$false`); `Set-PETenant ... [-Offline]` writes it (a switch given on an existing tenant is kept when omitted); `tenants.json` entries gain `Offline`. GUI tenant entries gain `offline` (bool). The `master` tenant can never be offline (throws).

- [ ] **Step 1: Write failing tests** — `Set-PETenant -Slug pre -Offline` then `(Get-PETenant -Slug pre).Offline | Should -BeTrue`; a tenant registered without it is `$false`; `Set-PETenant -Slug pre -DisplayName x` keeps `Offline`; `Set-PETenant -Slug master -Offline` throws; an older tenants.json without the property reads as `$false`; `Export-PEGuiData` writes `offline = $true` for it.
- [ ] **Step 2: Run** `Invoke-Pester tests/Tenants.Tests.ps1,tests/GuiExport.Tests.ps1`; expect the new tests FAIL.
- [ ] **Step 3: Implement** the property in both functions and in the GUI tenant entries (both places that build `$tenantEntries`).
- [ ] **Step 4: Run** the same files; expect PASS.
- [ ] **Step 5: Commit** `feat: a tenant can be marked offline`.

---

### Task 2: Reading uploaded export files

**Files:**
- Create: `src/PolicyEngine/Private/Upload.ps1`
- Test: `tests/Upload.Tests.ps1`, fixtures `tests/fixtures/upload/` (three small DSC export files: one Entra, one Exchange, one with a different version; each starts with the two header comment lines, `Configuration <Name>`, `Node localhost`)

**Interfaces:**
- Produces:
  - `Get-PEExportFileVersion -Text <string> -> [string]` (the version from the `# Generated with Microsoft365DSC version` line; throws when the line is missing or when it disagrees with the `Import-DscResource ... -ModuleVersion` value).
  - `Assert-PEUploadVersion -File <object[]> -> void` (each item has `Name`, `Text`; throws `"<name> was exported with Microsoft365DSC <v>, but this installation is pinned to <pinned>. Export again with <pinned>."` listing every offending file; nothing is stored by this function).
  - `Write-PEUploadStage -File <object[]> -Path <string> -> string[]` (warnings): writes the files into `Path` as one export folder (`export.ps1`) by writing the first file and merging the rest with `Merge-PEExportPart`; returns a warning per resource instance that appears in more than one file. Creates no `export.log`.
- Consumes: `Merge-PEExportPart -Path -PartPath` (ExportTool.ps1), `Get-PEPinnedVersion`.

- [ ] **Step 1: Write failing tests** — version read from fixture; missing line throws; header/Import mismatch throws; `Assert-PEUploadVersion` throws naming both versions and the file for the other-version fixture, and accepts the two good ones; `Write-PEUploadStage` of Entra + Exchange gives an `export.ps1` that `Read-PEExport` reads with both workloads' records and the resource block count of the two files together; the same instance in both files returns one warning containing the type and instance name.
- [ ] **Step 2: Run** `Invoke-Pester tests/Upload.Tests.ps1`; expect FAIL (functions missing).
- [ ] **Step 3: Implement** the three functions in `Upload.ps1` (module loads Private files by dot-sourcing; follow `ExportTool.ps1`). Duplicate detection: match `^[ ]{8}<Type> "<instance>"` headers across the files before merging.
- [ ] **Step 4: Run** the file; expect PASS.
- [ ] **Step 5: Commit** `feat: read uploaded DSC export files, refusing a version other than the pinned one`.

---

### Task 3: The upload check

**Files:**
- Create: `src/PolicyEngine/Public/New-PEUploadCheck.ps1`
- Modify: `src/PolicyEngine/PolicyEngine.psd1` (export list, if it lists functions)
- Test: `tests/UploadCheck.Tests.ps1`

**Interfaces:**
- Produces: `New-PEUploadCheck -Tenant <slug> -File <object[]> [-TenantDomain <string>] [-CompleteWorkload <string[]>] [-BlueprintName <string>] [-DataRoot <string>] -> [pscustomobject]@{ CheckId; Findings; Warnings; Workloads }`.
  - Tenant must be offline (throws otherwise). `-TenantDomain` sets the tenant's `TenantId` via `Set-PETenant` when given (needed for domain translation; if neither given nor already set, throws asking for it).
  - Calls `Assert-PEUploadVersion`, stages the files into `exports\<CheckId>`, reads them with `Read-PEExport` + `ConvertTo-PENormalizedRecord`, keeps the last of duplicate `(ResourceType, Key)` records.
  - First upload (no Full check for the tenant): blueprint types of workloads that were not uploaded are NotChecked `'workload not uploaded'`. Later upload: workloads in the upload replace the earlier check's records of that workload; other workloads are kept from the latest Full check (as `Invoke-PEScopeCheck` folds a slice), and `Meta.PatchedFrom` names it.
  - A blueprint type of an uploaded workload with no records is NotChecked `'no records in the upload and no export log'` unless its workload is in `-CompleteWorkload` (then it is empty and the blueprint's records become Missing).
  - `BlueprintName` default: the tenant's own (last) blueprint, `@(Get-PETenantBlueprint ...)[-1]`; when the tenant has none yet, the check is written with no findings and `BlueprintName = $null`.
  - Writes `checks\<CheckId>\result.json` with `Kind = 'Full'`, `TenantSlug`, `Findings`, `State` whose `Meta` has `Source = 'Uploaded'`, `ExportedAt` (upload time, UTC), `ModuleVersion`, `TenantId`, and `Workloads = @{ <Workload> = @{ Source = 'Uploaded' | 'Live'; At = <UTC> } }` (workloads kept from an older check keep that check's Source and At; for a check made by `Invoke-PEFullCheck`/`Invoke-PEScopeCheck`, which write no `Workloads`, treat it as `Live` with `Meta.ExportedAt`).
- Consumes: Task 1 (`Offline`), Task 2, `Compare-PEState`, `Get-PEDecision`, `Write-PEJsonNew`, `Get-PECheck`.

- [ ] **Step 1: Write failing tests** (temp data root, fixtures from Task 2; blueprint built with `New-PEState`/existing blueprint test helpers in `tests/FullCheck.Tests.ps1`):
  - refused version → throws, `checks\` empty, no tenant change (Review Focus 1);
  - Entra + Exchange upload → Full check, `Meta.Source = 'Uploaded'`, `Meta.Workloads` has both workloads;
  - type with no records and no `-CompleteWorkload` → NotChecked with the reason, no Missing finding; with `-CompleteWorkload` → Missing finding;
  - second upload with only Entra → Exchange records kept, `Meta.Workloads.Exchange.At` unchanged, Entra's updated, `PatchedFrom` set;
  - a live tenant (not offline) → throws; no `-TenantDomain` and none stored → throws;
  - duplicate instance across files → `Warnings` carries it, one record remains.
- [ ] **Step 2: Run** `Invoke-Pester tests/UploadCheck.Tests.ps1`; expect FAIL.
- [ ] **Step 3: Implement** `New-PEUploadCheck`; reuse the structure of `Invoke-PEFullCheck` (records, NotChecked, `New-PEState`, `Compare-PEState`, document) and the fold of `Invoke-PEScopeCheck`; do not refactor those two.
- [ ] **Step 4: Run** the file and `tests/FullCheck.Tests.ps1`; expect PASS.
- [ ] **Step 5: Commit** `feat: an upload of DSC export files becomes a check`.

---

### Task 4: Upload and register through the GUI jobs

**Files:**
- Modify: `src/PolicyEngine/Private/GuiRequest.ps1` (new actions `UploadSnapshot`, and `Recheck` refuses an offline tenant)
- Modify: `gui/PEGui.psm1` (`New-PEGuiRequest` validation for the new action; request size)
- Modify: `gui/server.ps1` (body size limit for the requests route if Pode caps it)
- Test: `tests/GuiRequest.Tests.ps1`, `gui/tests/PEGui.Tests.ps1`

**Interfaces:**
- Produces: request `{ action = 'UploadSnapshot'; tenantId = <slug>; files = @(@{ name; text }); tenantDomain; completeWorkloads = @(); saveAsBlueprint = $bool; newTenant = @{ slug; displayName } | $null }`.
  - With `newTenant`: registers it with `Set-PETenant -Offline` (slug rules as `Set-PETenant`; `Blueprints` = the master blueprint), then uploads.
  - Runs `New-PEUploadCheck`; with `saveAsBlueprint` and a tenant that has no own blueprint, then `Initialize-PETenantBlueprint -Slug -MasterBlueprint -FromCheck` and re-runs the compare so the check holds findings against it (the first upload becomes the blueprint, so its drift is the layers above).
  - Outcome text: `"Snapshot uploaded (check <id>): <n> drifted item(s), <m> type(s) not checked."` plus any warnings.
  - `Recheck` of an offline tenant fails with `"Tenant '<slug>' is offline: upload a newer export instead."`
- Consumes: Tasks 1 and 3, `Initialize-PETenantBlueprint`, the job/worker flow of `Invoke-PEGuiRequest` (upload is a job like any other, not cancellable once running).

- [ ] **Step 1: Write failing tests** — `Send-Request` an `UploadSnapshot` for a new tenant with two fixture files and `saveAsBlueprint`: tenant exists and is offline, a check exists, the tenant has its own blueprint, job `Succeeded`; a wrong-version file: job `Failed` with both versions in the result and no tenant registered; `Recheck` on the offline tenant: job `Failed` with the message; `New-PEGuiRequest` rejects an upload with no files, a file without `name`/`text`, a bad slug; a request with an 8 MB text is created and read back intact (Review Focus 7).
- [ ] **Step 2: Run** `Invoke-Pester tests/GuiRequest.Tests.ps1,gui/tests/PEGui.Tests.ps1`; expect FAIL.
- [ ] **Step 3: Implement** the action in `Invoke-PEGuiRequestAction` (`switch ($action)`), validation in `New-PEGuiRequest`, and, if the live check in Task 6 shows Pode rejecting large bodies, the Pode limit in `server.ps1`.
- [ ] **Step 4: Run** the same files; expect PASS.
- [ ] **Step 5: Commit** `feat: upload a snapshot from the GUI job queue`.

---

### Task 5: Upload page and labels in the GUI

**Files:**
- Modify: `gui/public/assets/app.js` (connect dialog gains "Offline tenant (upload files)", tenant page gains "Upload newer snapshot", labels, Recheck hidden for offline tenants)
- Modify: `src/PolicyEngine/Public/Export-PEGuiData.ps1` (per-tenant `snapshot` object)
- Test: `gui/tests/Assets.Tests.ps1`, `tests/GuiExport.Tests.ps1`

**Interfaces:**
- Produces: tenant entries get `snapshot = @{ source = 'Uploaded' | 'Live' | $null; at = <UTC>; workloads = @(@{ workload; source; at }) }` from the latest Full check's `State.Meta` (Task 3 shape; older checks read as `Live` with `ExportedAt`). The GUI shows `Exported live <date>` or `Uploaded <date>` on the tenant card and per workload in the alignment bars, and the age of the oldest workload. The upload dialog reads the chosen files with `FileReader`, lists their versions, lets the user type the tenant domain, tick "this workload is complete" per detected workload and "use this as the tenant's blueprint" (only offered when the tenant has no own blueprint), and posts the `UploadSnapshot` request of Task 4.
- Consumes: Tasks 1, 3, 4.

- [ ] **Step 1: Write failing tests** — export data: a tenant with an uploaded check has `snapshot.source = 'Uploaded'` and per-workload entries; an old check reads as `Live`. Asset tests (pattern of the Cancel tests): `app.js` contains `data-act="upload-snapshot"`, the `FileReader` read, the Recheck button guarded by `!t.offline`, and the `Uploaded `/`Exported live ` labels.
- [ ] **Step 2: Run** `Invoke-Pester gui/tests/Assets.Tests.ps1,tests/GuiExport.Tests.ps1`; expect FAIL.
- [ ] **Step 3: Implement** the data and the page; follow the connect dialog's structure (`connect-mode`, `connect-submit`) and the job toast for progress.
- [ ] **Step 4: Run** the files; expect PASS. Then live (Playwright, an isolated data copy and a server on a spare port as in the Cancel test; the token goes on the root URL): create an offline tenant from the dialog with two fixture files, see the labels, see the version refusal for the other-version fixture, confirm a ~10 MB file uploads.
- [ ] **Step 5: Commit** `feat: upload page, snapshot labels and no recheck for offline tenants`.

---

### Task 6: Generate the configuration files

**Files:**
- Create: `src/PolicyEngine/Public/New-PEOfflineConfig.ps1`
- Modify: `src/PolicyEngine/Private/GuiRequest.ps1` (action `GenerateConfig`), `gui/PEGui.psm1` (`Invoke-PEGuiApi` route `GET /api/jobs/:jobId/config/:file`), `gui/server.ps1` (route registration), `gui/public/assets/app.js` (button on the tenant page and download links in the job)
- Test: `tests/OfflineConfig.Tests.ps1`, `tests/GuiRequest.Tests.ps1`, `gui/tests/PEGui.Tests.ps1`, `gui/tests/Assets.Tests.ps1`

**Interfaces:**
- Produces: `New-PEOfflineConfig -Tenant <slug> [-DataRoot <string>] -> [pscustomobject]@{ Changes = <string|$null>; Removals = <string|$null>; Manual = @([pscustomobject]@{ ResourceType; Key; Action; Reason }); CheckId; BlueprintName }`.
  - Source: latest Full check of the tenant, against the tenant's own blueprint (latest version). Findings Open and `Missing` → Create, `Changed` → Update (both in `Changes`, one `ConvertTo-PEDscConfig` call, `-Target Replica`, `-ConfigurationName 'PE_Changes'`); Open `TargetOnly` with no hint → Remove (in `Removals`, `-ConfigurationName 'PE_Removals'`, using in-memory Remove decisions shaped as `Get-PEGuiRevertConfig` builds them, never stored).
  - Anything `New-PERectifyPlan` or `ConvertTo-PEDscConfig` refuses for one item (no `Ensure`, unknown property, secret/ignored property, tenant-bound key, PossibleRename) is retried alone as `Get-PEGuiRevertConfig` does, and the item that fails goes to `Manual` with the error as `Reason`; one bad item never blocks the file.
  - NotChecked types, Excluded, Accepted and Unmanaged findings are not planned. An empty list gives `$null` for that file.
  - Both files are stamped with the pinned module version through `ConvertTo-PEDscConfig`.
- GUI: action `GenerateConfig` (`tenantId`) runs it as a job and stores `configs\<jobId>\Changes.ps1`, `Removals.ps1`, `Manual.json` (written once with `Write-PETextNew`/`Write-PEJsonNew`); the job result says how many items each file has and how many need manual action; `GET /api/jobs/<jobId>/config/<Changes|Removals|Manual>` returns the file (name from a fixed list, the job must be a `GenerateConfig` job). The tenant page offers "Generate configuration" for offline tenants, the job links to the files, and the Manual list is shown with reasons.
- Consumes: `New-PERectifyPlan`, `ConvertTo-PEDscConfig`, `Get-PEGuiRevertConfig` (read it for the decision shape), `Get-PETenantBlueprint`, `Get-PEDecision`, `Get-PECheck`.

- [ ] **Step 1: Write failing tests** (fixtures: a blueprint and a check state with one Missing, one Changed, two TargetOnly of which one is Accepted by a decision, one NotChecked type, one item with a property on the ignored list):
  - `Changes` contains the Create and the Update block and parses without errors; `Removals` contains only the Open TargetOnly block with `Ensure = 'Absent'`; the Accepted one is in neither (Review Focus 5);
  - nothing from the NotChecked type appears anywhere (Review Focus 4);
  - the item needing an ignored/secret property is in `Manual` with a reason and not in either file, and the files still generate (Review Focus 6);
  - the files carry `ModuleVersion '2.26.1015.1'` and contain no credential values, only `$ConfigurationData.NonNodeData.` references;
  - no drift → both `$null`; an offline tenant is not required (a live tenant works the same);
  - GUI: the job writes the three files; the route returns them; an unknown file name and a job of another action return 404/400.
- [ ] **Step 2: Run** the four test files; expect FAIL.
- [ ] **Step 3: Implement** `New-PEOfflineConfig`, the job action, the route and the page. Registered plan items live in this process only: generate inside one call, in the worker process.
- [ ] **Step 4: Run** the files; expect PASS. Then live as in Task 5: make drift on the fixture tenant, generate, open the three files in the browser, and check `Changes.ps1` with `[System.Management.Automation.Language.Parser]::ParseFile`.
- [ ] **Step 5: Commit** `feat: generate the configuration for an offline tenant, removals in their own file`.

---

### Task 7: Documentation and full run

**Files:**
- Modify: `docs/handover.md`, `docs/overview.md`, `gui/README.md`, `docs/gui-handoff.md` (only where it lists actions or routes)
- Modify: `docs/superpowers/specs/2026-10-26-offline-snapshots-design.md` (status: implemented; list the calls as built)

- [ ] **Step 1: Write** a handover section: the offline flow, the version rule, the NotChecked rule for log-less uploads, per-workload ages, what goes to "needs manual action" and why (DSC's limit, not ours), that the configuration targets the own blueprint and how to move items from a layer above first, and the request size limit.
- [ ] **Step 2: Run** the full suite `tools\Invoke-PETests.ps1`; expect all passing (1065 plus the new ones, none failing).
- [ ] **Step 3: Commit and push** `docs: offline snapshots`.
