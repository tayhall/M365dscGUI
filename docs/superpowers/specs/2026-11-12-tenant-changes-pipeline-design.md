# Tenant changes pipeline: what changed in one tenant since its last export

Status: design, awaiting approval. Date: 2026-11-12.

## Intent and the why

Today the compare pipeline answers "how does Dev differ from PreProd?" and the drift report is where a person picks items, downloads
`approved.json` and commits it in a pull request. That is the right tool for aligning two tenants, but it buries a different and more
common question: **what did someone change in this tenant since we last looked?**

The aim is to handle that question with pipeline runs only: queue a run, read one report that shows only the local tenant's own changes,
then do one of two things with the result:

1. the change is wrong: apply the **revert** configuration to put the tenant back;
2. the change is intended: keep the **change** configuration as the thing to promote to PreProd and Prod (a later pipeline, not this one).

No report download plus `approved.json` pull request is needed for this path.

## Shape

One new pipeline, **`Tenant-Changes`**, queued by hand (`trigger: none`; nothing triggers it). Parameters:

| Parameter | Meaning |
| --- | --- |
| `tenant` | Dev, PreProd or Prod: the tenants that have a config file and an export pipeline id in the settings. |
| `exportVersion` | Optional. The "after" export, as a friendly name (`v9`) or numeric run id. Blank = the latest successful export of that tenant. |
| `previousVersion` | Optional. The "before" export, same forms. Blank = the successful export run just before the "after" one. |

The pipeline compares the tenant's **previous** export (what it should look like) with the **latest** export (what it looks like now),
using the existing comparison, `tools\Invoke-PEPipelineCompare.ps1`, unchanged in how it compares. It is a thin wrapper: the same engine
that compares PreProd with Dev, fed two exports of one tenant.

## Outputs

Artifact `TenantChanges`. File names follow what the compare pipeline already writes; where a name carries the tenant it is prefixed
with it (`Dev`):

- **`DevChanges.html`**: the existing drift report, built from the previous-to-latest comparison, labelled with the two export names
  (for example "Dev v8" and "Dev v9"). It shows what is new, changed or gone in the tenant.
- **Revert** (compare direction: previous = expected, latest = target; this is exactly the existing flow): `Changes.ps1`, `Removals.ps1`,
  `Manual.json`, `drift.*`, `summary.json` and, when compiled, `MOF\Changes`, `MOF\Removals`. Applied to the tenant these return it to
  the previous export; items created since go to `Removals`. Published as `RevertDevChanges.*` where a single file name is needed.
- **Changes** (compare direction swapped: latest = expected, previous = target): `DevChanges.ps1` and `DevRemovals.ps1`, the
  configuration that takes a tenant in the previous state to the latest. This is what a later promote pipeline will turn into
  `PreProdChanges.mof`. **My call:** it is published as configuration text, **not compiled to a MOF** here, because a MOF embeds the
  identity (application id, certificate thumbprint, organisation) of the tenant it will be applied to, and that tenant is not known
  until the promote pipeline runs. The promote pipeline compiles it with the destination's identity.
- A first line in the log, in `summary.json` and in the report header says what was compared, for example `Dev changes: v8 -> v9`.
  The run renames itself the same way (`##vso[build.updatebuildnumber]`), so the run list shows what each run compared.

## Readable export names

Export runs are currently all named `M365DSC - Export Dev tenant`, so nothing in the picker or run list tells them apart. Change the
export templates' run name to a counter, for example `name: 'Dev-export-v$(Rev:r)'` (and `PreProd-export-v...`). `$(Rev:r)` counts
up per distinct name, so each tenant counts on its own. Notes the builder must respect:

- The counter also counts failed and cancelled runs, so "previous = number minus one" is wrong. Previous is **looked up**, not calculated.
- Old runs keep their old names and have no `vN`. They can still be the "previous" run (by numeric id, or as the latest successful run
  before the "after" one).
- ADO cannot fill queue-form defaults from run history, so blank means latest/previous and the script resolves it. The run shows the
  resolution as soon as it starts.

## Resolving the two exports (new, small)

A script (`pipelines\scripts\Resolve-TenantExports.ps1`, name is the builder's) uses the pipeline's own access token over the ADO
REST API (`_apis/build/builds`, `api-version 7.1`, the same token mechanism `New-ExportRetentionLease.ps1` uses) to:

- find the tenant's export pipeline by the id in `pipeline.settings.psd1` (`ExportDevPipelineId`, `ExportPreProdPipelineId`;
  `ExportProdPipelineId` is added the same way);
- turn `v9` / `v8` / a numeric id into a run id, and the blank defaults into "latest successful" and "successful just before the latest";
- refuse, with a clear message, a name that does not exist, a run that did not succeed, a run of another pipeline, an "after" that is not
  newer than the "before", or an export whose artifact has been deleted by retention;
- write the two run ids and their friendly names as pipeline variables for the next steps (`DownloadPipelineArtifact@2` with a specific
  run, as `Apply-Approved-Dev` already does) and into `summary.json`.

Numeric run ids stay the internal identity (the report and the apply checks already pin exports by id and SHA-256). Friendly names are
only labels and input.

## Applying a revert

The revert MOF is applied by the existing mechanism (LCM, `tools\Invoke-PELcm.ps1`) behind the existing environment approval. How
`Apply-Dev` is pointed at a `TenantChanges` artifact instead of a `DriftReport` is the builder's call, with these constraints:

- Dev only for now: Dev is the only tenant that has a Writer app and certificate. For PreProd and Prod the pipeline still produces
  the report and the configuration text, and skips compiling and applying (**my call**: compile only when the tenant's config has a
  Writer app id and the Writer certificate secret exists).
- None of `Apply-Dev`'s guards may be weakened: Test is the default mode, the environment approval, the check of the Writer
  certificate against the MOFs, the workload-layout check, the refusal of a report without a valid thumbprint.
- Test mode before Apply mode stays the documented order.
- **A tenant check is added.** `Invoke-PipelineApply.ps1` is hard-wired to Dev and reads only the report's layout and the MOF folder from
  the artifact; it does not check which tenant the artifact came from. A `TenantChanges` artifact of PreProd would otherwise be
  applied to Dev. So `summary.json` of this pipeline carries `Tenant` and the two export run ids, and the apply step refuses unless
  `Tenant` is `Dev` and the MOFs' thumbprint check passes. The same field is how `Apply-Approved-Dev` refuses a list built from this report.

## Decisions made while checking the design (my calls)

- **Same-tenant compare is tried first.** The plan starts with a spike: two fake exports of one tenant through
  `Invoke-PEPipelineCompare.ps1`. The rule "the tenant's own domain is not drift" is harmless when both sides share a domain. If the
  spike shows the compare cannot do this without a change, stop and discuss (see Constraints) before going on.
- **The swapped (Changes) direction needs no identity.** It runs without `-Compile`, so it needs no Writer identity or thumbprint.
  Only the revert direction compiles, and only for a tenant with a Writer app.
- **No usable previous export is an error, not a partial result.** The run stops with a plain message that names the cause (no earlier
  successful export, or the earlier export was made with another DSC pin) and tells the user to take a fresh export first. It does not
  produce a report with only the "after" state.
- **Only configured tenants are offered.** Dev and PreProd have a config file today. There is no Prod config and no Prod export
  pipeline in the repo, and creating them is not part of this work. The `tenant` parameter lists the tenants that have an export
  pipeline id in the settings, so Prod appears when its config, settings id and export pipeline exist.
- **Prerequisite, not a task:** the build service identity must be able to read builds and artifacts of the export pipelines (View
  builds), as the retention lease already needs. The resolve step fails with a message saying so if it cannot.

## Goals

- One run, one tenant, one readable report of only that tenant's own changes.
- Revert and promote both come from the same run; no `approved.json` pull request on this path.
- No second implementation of DSC or of the comparison: the same comparison and generator, called with two exports of one tenant.
- Readable run names; the run states what it compared.

## Non-goals

- No automatic triggering or schedule.
- No promote pipeline (`PreProdChanges.mof`): a later piece. This design only makes sure its input exists.
- No per-item selection of what to revert or promote; a configuration applies everything in it. Per-item choice stays with the
  existing `approved.json` route. That route does not take lists from this report: the report's selection controls are hidden if that
  is cheap, otherwise left, but `Apply-Approved-Dev` must refuse such a list (it names the wrong source pipeline and tenant check
  should fail); the builder verifies that and adds a test.
- No new apply machinery, no rollback (DSC has none), no change to the DSC pin guard.
- No translation of tenant-specific object ids (a policy assigned to a group id) when a change is promoted: this is a known limit, listed
  in `Manual.json` where the engine already cannot generate, and recorded in `docs/handover.md`.

## Anti-goals (a failure even if it technically works)

- A run that silently compares the wrong two exports. The resolved names and ids must be visible before anything is applied.
- A revert applied against a different tenant than the exports came from.
- A baseline that quietly moves so a change is only ever shown once. Here it does not: each run names its two exports explicitly, and
  anyone can compare against an older export by typing its name. (The alternative "last reviewed" baseline was considered and
  declined in favour of this simpler, explicit one.)

## Constraints

- Thin wrapper (CLAUDE.md): call `Invoke-PEPipelineCompare.ps1`, `New-PEDriftReport.ps1` and DSC's own build; do not copy their logic.
  If two exports of one tenant need something the compare cannot do (it was written for two tenants, for example the "tenant's own
  domain is not drift" rule and the `TargetTenantDomain` parameter), **stop and discuss** rather than fork it.
- Exports made with a different DSC pin are refused by the existing tools; a first run after a pin bump has no usable "previous" and must
  say so plainly rather than fail obscurely.
- Pipeline YAML stays thin (install, one script step, publish); logic and checks live in scripts. YAML is generated from `.yaml.template`
  files by `pipelines\scripts\New-PipelineYaml.ps1`; add tokens there, with the same validation.
- Tests are offline Pester tests with fake exports, run with `tools\Invoke-PETests.ps1`. REST calls are tested against a fake
  responder; testing in ADO is the final check.
- Update `pipelines\README.md`, `docs\overview.md` if tools change, and `docs\handover.md` for any deliberate gap.

## Left to the builder

- Script and file names beyond those given; the exact REST queries and paging.
- How the report header and file names carry the tenant and versions.
- How `Apply-Dev` (or a sibling) reads the `TenantChanges` artifact, within the constraints above.
- Whether the changes configuration reuses one more comparison run in `Invoke-PEPipelineCompare.ps1` or a second call of it.
- Whether `PerWorkload` layout is offered here (the existing parameter); default Combined.
