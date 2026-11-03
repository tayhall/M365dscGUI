# Approved-drift apply: review in the GUI, apply only what was approved

Status: draft for approval. Date: 2026-11-03.

## Intent and why

The Azure DevOps pipelines (`pipelines/`) export PreProd and Dev, compare them and build MOF files that would change Dev to match
PreProd. At the moment that means *everything that differs*, in one Changes file and one Removals file (or one pair per workload). The
owner wants the control the GUI already gives: look at the differences, say for example "10 groups are missing in Dev, create them, and
nothing else", and have only that applied, at the level of the resource type (groups, Conditional Access policies, ...).

So the review stays human and item by item, in the local GUI, and what the pipeline applies is exactly the list of items that were
approved there, committed to the repository.

## What the owner decided

- The item-by-item review happens in the **local GUI** (not in Azure DevOps).
- The **approved list is committed to the repo**.
- Applying is split down to the **resource type**, and there are guards that stop a run that is not what was reviewed.
- The local blueprint is updated from the PreProd export, as in the GUI today; the review is Dev against it.

## The flow

1. **Export.** The existing pipelines export PreProd and Dev and publish the exports.
2. **Review (local, GUI).** Download both exports. Upload them as snapshots (the GUI's offline-tenant flow); the PreProd export updates the
   local blueprint. In the Drift review of Dev, choose the items to accept in the Selection list and **save an approved list** (new GUI action).
3. **Commit.** The approved list (one small file) is committed to `approvals/` in the project folder of the ADO repo. The commit or pull
   request is the human record of who approved what.
4. **Apply (pipeline).** The Apply pipeline takes one approved list, rebuilds the comparison from the exports it names with the same engine,
   keeps **only** the approved items, builds one MOF per resource type, shows the counts, tests, and (if asked) applies to Dev.

## The approved list

A JSON file. It names items, never values:

- format version, created (UTC), approved by, the tenant (`dev`), the module version;
- the two exports it was made from: pipeline run id, ExportedAt and a SHA-256 of each `export.ps1`;
- `Items`: `{ Action: Create | Update | Remove, ResourceType, Key, ExcludedProperties }`, and counts per type and action.
  `ExcludedProperties` are the properties the reviewer excluded for that item in the GUI (the engine's existing `PropertyExcluded`
  decision); an Update then keeps Dev's value for them. They are the only decisions the list carries.

Values (properties of the resource) are not in the list. They always come from the PreProd export at apply time, so a list cannot
carry a changed setting into Dev.

## What the project already answers

- **Identity of an item.** An item is the engine's (ResourceType, Key); the key comes from the engine's key map. A key that appears more
  than once (an Ambiguous finding, for example two policies with one display name), an Unkeyed or Excluded or NotChecked finding, and a
  PossibleRename cannot be approved: `New-PERectifyPlan` refuses them, and the GUI action does not offer them.
- **What an Update writes.** DSC sets a whole resource, so an approved Update writes the PreProd definition of that resource, except the
  properties on the ignore lists (never written) and the item's `ExcludedProperties` (Dev's value is kept). This is what the GUI's Revert
  does today. The review shows the differences; properties that are equal change nothing.
- **Items DSC cannot create or remove** are decided by the engine, not by this repo: `New-PERectifyPlan` and `ConvertTo-PEDscConfig`
  refuse an item with no Ensure, an unknown or secret property, or a type that cannot be reverted. Cross-tenant ids and the tenant's
  own domain name are already handled by the comparison.
- **Same comparison in the GUI and the pipeline.** The pipeline compares the Dev export with the PreProd export directly; the GUI compares
  the Dev snapshot with the master blueprint. They agree when the master blueprint *is* that PreProd export, with no promoted or edited
  items. The GUI action therefore saves a list only when it can show that (the blueprint's source export matches the export named in the
  list) and refuses otherwise. Decisions other than `PropertyExcluded` (Unmanaged, Remove) are not needed by the pipeline: an approved
  Remove is itself the confirmation.

## Apply: the guards

Each guard fails the run, with a message that names the items, unless it says otherwise.

- **G1 Complete exports.** Neither export may have a failed component (`Failed exports` above 0 in `export.log`) or a Graph shortfall
  warning ("Graph reported N items but only M were returned"). Re-export instead of overriding.
- **G2 Still valid.** Every approved item must still be an Open finding of the same kind in the new comparison (for example "Missing group
  X" is still missing). An item that no longer differs, or now differs in another way, is reported as stale and stops the run.
- **G3 Only what was approved, all or nothing.** Nothing outside the list is written. The configuration is generated for every approved
  item first. If any approved item cannot be generated (the engine refuses it, see above), nothing is applied: the run fails with the items
  and reasons, and the list is corrected and committed again. The number of resources generated must equal the approved count.
- **G4 Counts at the gate.** The log and the pipeline summary show per type and action, for example `Create 10 AADGroup`, `Update 2
  AADConditionalAccessPolicy`, before the environment approval and again before applying.
- **G5 Test first, then stop on the first failure.** The LCM test runs for every type before any apply. Apply then goes type by type in a
  fixed order and stops at the first type that fails; later types do not run. The run ends red and reports which types were applied, which
  failed and which were skipped. There is no rollback (DSC has none); the Test run is the prediction, not a guarantee.
- **G6 Removals only if approved and asked for.** A `Remove` item needs to be in the list and the `includeRemovals` option ticked.
- **G7 Pinned, unchanged exports.** Apply uses the export runs named in the list, and their SHA-256 must match the list. If a run's
  artifact is gone (retention) or differs, the run fails and says so. The two runs an approval names are marked to be retained when the list
  is committed.
- **G8 Not too old.** The Dev export in the list must not be older than a maximum age (a setting, default 7 days), because Dev can change
  after it was exported. The live Test run at apply time also shows the real state.
- **G9 Only from a protected place.** The pipeline runs only from the default branch, and the list must be committed there. Requiring a
  pull request review on `approvals/` is an Azure DevOps branch policy, recommended, and not something the pipeline can enforce.

## Goals, non-goals, anti-goals

Goals: item-level review and apply; resource-type MOFs; guards G1 to G9; no new copy of what DSC or the engine already does.

Non-goals: the GUI inside Azure DevOps; automating the approval; other tenants than PreProd to Dev; changing how the exports work;
removing the existing Compare pipeline (it stays as the drift report).

Anti-goals (a failure even if it technically works): applying anything that was not reviewed; a partly applied run that ends green; an
approval that can be reused after the tenant has changed.

## Constraints

- Thin wrapper over DSC and the engine (`CLAUDE.md`). Reuse: the GUI Drift review and Selection list; `New-PERectifyPlan` (it already
  refuses stale findings, changed blueprints and unsafe items); `ConvertTo-PEDscConfig`; `Invoke-M365DSCConfigurationBuild`; the LCM
  scripts. The new parts are only the approved-list format and its GUI action, a pipeline command that applies a list, the G1 check
  and the per-type split.
- Same safety rules as today: Dev only, Test by default, certificates removed from the agent after every run.
- The pipelines keep working while this is built; Apply switches over when the new one works.

## Calls I made (change any of them)

- The list holds no property values (above), only the item and its excluded properties.
- A stale approved item fails the run; there is no "skip stale" option.
- G1 has no override.
- Apply pins the exports named in the list rather than taking the latest, and checks them by hash.
- No dependency analysis between resources (for example a Conditional Access policy that names a group). A reference to something missing in
  Dev is caught by DSC and by the Test run, and the per-type order (a short fixed list, groups before the types that reference them) puts the
  usual dependencies first. Approving the group and the policy in one list is the way to do both.
- An approved list that cannot be fully generated applies nothing (G3).
- A run stops at the first failing type and ends red (G5); no rollback.
- The new Apply is a **new pipeline beside the existing Apply-Dev**, not a replacement. The old one stays until the owner decides to remove
  it. Compare stays as the drift report.

## Left to the builder

- The look of the GUI action ("Save approved list") and where it writes before the owner copies it into the repo.
- Exact JSON layout.
- How the Apply pipeline fetches specific earlier export runs in Azure DevOps.
- The order the per-type MOFs are applied in (for example groups before things that reference them), and whether the engine's own ordering
  is enough.
- How the PreProd export becomes the local blueprint and how an accepted item reaches "Dev's own blueprint" in the GUI's existing move
  and Revert actions.
