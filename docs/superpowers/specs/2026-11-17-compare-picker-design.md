# One Compare pipeline with a From and a To picker (Dev, PreProd, Prod)

Status: for approval. Date: 2026-11-17.

## Intent

Today `Compare-PreProd-to-Dev.yaml` is fixed: PreProd is the source, Dev the target. To look at Dev against PreProd, Prod against PreProd,
Dev against Prod and so on, the user would need one pipeline per pair. They want **one** Compare pipeline in which they choose the two
tenants when they run it.

## Goals

- One Compare pipeline with `from` and `to` pickers over the tenants **Dev, PreProd, Prod**. Any two different tenants can be compared.
- The two exports are found at run time **by pipeline name** (no ids in settings), the latest successful export of each tenant, or a
  named version, using the code the Tenant-changes pipeline already has.
- Prod is added as a tenant: `pipelines\config\Prod.psd1`, an `Export-Prod` pipeline (Reader app only, like PreProd), and the settings
  `ProdServiceConnection` and `ExportProdPipeline`.
- The pipeline names stay a setting; the pickers are generated from the one tenant list, so adding a tenant later is a settings entry plus
  its config file and export pipeline, not a new pipeline.

## Non-goals

- No applying to PreProd or Prod. Only Dev has a Writer app; writing stays Dev-only.
- No change to the approved-apply flow. `Apply-Approved-Dev` and `approved.json` keep working for **PreProd to Dev** exactly as now.
- Dev to Dev is not offered: that is the Tenant-changes pipeline (two exports of one tenant).
- No change to how exports are made, to the DSC pin, or to the drift report's layout.

## Anti-goals (a failure even if it technically works)

- Any pair other than PreProd to Dev producing MOF files or an approved list that could be applied to the wrong tenant.
- A compare that silently uses the wrong tenant's export, or an export of another workload series.
- Re-implementing the comparison: the same comparison tool is called with two exports.

## Constraints

- Thin wrapper over DSC (CLAUDE.md): the comparison, the MOF generation and the report generator are existing commands; only the choosing,
  finding and labelling is new.
- Pipeline resources in YAML are fixed when the YAML is compiled, so a run-time choice cannot use them. The exports are downloaded by
  `DownloadPipelineArtifact@2` from run ids found over the Azure DevOps API, as Tenant-changes does.
- The service connection for the target is chosen when the YAML is compiled (`${{ if eq(parameters.to, ...) }}`), as in Tenant-changes.
- Tenant lists are hard-coded `ValidateSet('Dev', 'PreProd')` in six places today (`Get-PipelineConfig`, `Connect-PipelineTenant`,
  `Resolve-TenantExports`, the export and tenant-changes scripts and their templates). Prod has to be added to each.

## Approaches considered

- **A. One pipeline, pickers, exports found at run time (chosen).** Reuses the Tenant-changes code. A rewrite of the Compare YAML, but small
  new logic.
- B. Keep pipeline resources, declare one per tenant. Waits on or fails for every tenant's export, including ones with no run, and
  downloads every pair. Rejected as fragile.
- C. Generate one YAML per pair. The many-pipelines setup the user wants to avoid. Rejected.

## Design

**Parameters:** `from` and `to` (values Dev, PreProd, Prod, from the tenant list), `fromVersion` and `toVersion` (optional: blank = latest
successful Full export, or a name such as `v9`), `mofLayout` and the workload checkboxes as today. `from` equal to `to` stops the run with a
clear message ("use Tenant changes to compare two exports of one tenant").

**Finding the exports:** the first step looks up the export pipelines by name (the existing `Resolve-ExportPipelineIds.ps1`, extended to the
tenant list), then `Resolve-TenantExports.ps1` finds the run for each side (once for `from`, once for `to`), then two
`DownloadPipelineArtifact@2` steps. The Full export series is used, since a comparison needs complete exports.

**What a run produces:**

| from, to | MOF files and Changes/Removals | drift report | approved list (Apply-Approved) |
|---|---|---|---|
| PreProd to Dev | yes, as today | yes, with selection controls | yes, as today |
| any other pair | no (nothing could be applied) | yes, read-only (no selection controls, labels name the two tenants) | no |

**Labels:** the report and `summary.json` name the real tenants (`Dev`, `Prod`, ...) instead of the fixed PreProd/Dev, and record the two
run ids. For PreProd to Dev the existing fields (`PreProdExportRun`, `DevExportRun`) stay, so `Apply-Approved-Dev` and `Apply-Dev` are
unchanged.

**Config and identity:** the target's `pipelines\config\<Tenant>.psd1` and service connection are used only when MOFs are built (target
Dev). For other targets nothing is signed in to except what the export lookup needs.

## Left to the builder

The exact YAML conditionals, how the read-only report hides its selection controls (cheap, or `Apply-Approved-Dev` refuses a list whose
source or target is not PreProd to Dev, with a test), and the tests: pickers generated from the list, same-tenant refusal, an unsupported
pair builds no MOFs and no approved list, PreProd to Dev output identical to today's, Prod added to every tenant list.

## Calls I made (to check while reading)

1. Only PreProd to Dev builds MOFs and approved lists; every other pair is comparison and report only. This is the safe reading of
   "Dev only is writable"; a later step can open more.
2. Dev to Dev is excluded (Tenant-changes covers it).
3. Latest successful **Full** export is the default, with an optional version.
4. Prod is read-only like PreProd (Reader app only).
