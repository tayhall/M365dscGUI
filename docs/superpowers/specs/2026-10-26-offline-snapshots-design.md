# Offline snapshots and a configuration to realign a tenant

Date: 2026-10-26. Status: implemented (see `docs/handover.md`, "Offline snapshots"). Every item of "Calls made by me"
below was built as written; items 6 and 7 as corrected there. Added while building: the generator recomputes findings
and never creates a type the check did not read, and refuses a scope-patched check.

## Intent and why

Some tenants cannot be reached from this tool: no certificate, no Reader/Writer app, no network path. The people who run
them can still run `Export-M365DSCConfiguration` (for example in an ADO pipeline) for Entra, Intune, Teams, Security and
Compliance and Exchange, and run a DSC configuration against them. They want to use the same policy engine anyway:
compare one tenant with another (Production against PreProduction), keep a tenant aligned with a target over time, and
get a configuration file they can run to close the gap.

The loop:

1. Upload the export files of a tenant. They become that tenant's snapshot (a stored check).
2. The first upload can be saved as the tenant's own blueprint, as already done for a connected tenant
   (`Initialize-PETenantBlueprint -FromCheck`).
3. Drift is shown as today, against the layers the tenant follows (for example a Production blueprint, then its own).
4. The user decides each drifted item as today: leave it as drift, add it to the blueprint, or exclude it.
5. The tool writes a configuration from what is still drift. The user runs it on the offline tenant.
6. The user exports the offline tenant again and uploads the files. The new snapshot shows what changed.

## Goals

- An offline tenant is a normal tenant in the GUI and CLI: drift, layers, item pages, alignment by workload, decisions.
- Several export files (one per workload, or one for everything) form one snapshot.
- Every check says whether it was exported live or uploaded, and how old the data is.
- A generated configuration for the drifted resources, with removals in a separate file.
- No certificate, connection or app is needed to do any of this.

## Non-goals

- Connecting to the offline tenant, or running the configuration for the user.
- Importing the configuration through Intune/Exchange admin portals or any file format other than DSC's.
- Replacing DSC's export, schemas or apply. Resource names, keys and what can be removed come from the pinned module.

## Anti-goals (a failure even if it works)

- A removal that was not an explicit "leave as drift" decision.
- A failed or partial export read as "empty", which would make the tool claim real objects are missing and write a
  configuration that creates them.
- Lines in the configuration that DSC cannot run (no `Ensure = Absent` support, a resource that cannot be created
  from an export). These are listed as "needs manual action" instead.

## What exists and is reused

- `New-PEStateFromExport` / `Read-PEExport` / `Find-PEExportFile`: read an export into a normalised state.
- Checks, `Get-PECheck`, `Initialize-PETenantBlueprint -FromCheck`, layers, decisions, `Compare-PEState` with the
  cross-tenant rules (tenant-bound properties, domain translation, ignored properties, role group members).
- `Merge-PEExportPart` (merging resource blocks of one export file into another).
- `Rectify` / `Invoke-PERoundTrip`: how a drifted resource is turned into an applied change today.
- The GUI: tenants, Activity jobs, item pages.

## Decided with the user

- A snapshot is what a check already is. An uploaded set of files makes a check with `Source = Uploaded`.
- Uploads may cover only some workloads. Workloads not uploaded keep their previous data, as a scoped check does.
- A first upload can become the tenant's own blueprint.
- The configuration contains: changed values set to the target value; missing items created; extra items removed, but
  only those the user left as drift (an extra that was added to the blueprint or excluded is not drift and is untouched).
- Removals go in a separate, clearly labelled file, so "adds and changes" can be run first and removals as a second step.
- Where DSC cannot do something, the item is listed as needing manual action.
- The GUI shows where each check came from (exported live / uploaded) and its age.

- **GUI first.** The user will not run this from the command line. The work is built in steps (core functions, then the
  GUI upload page and Activity job), but it is delivered and used through the GUI. The command line is for tests.
- **Version must match.** Every uploaded file states its DSC version in the first line (`# Generated with
  Microsoft365DSC version 1.26.422.1`) and in `Import-DscResource ... -ModuleVersion`. An upload is accepted only when
  the version equals the pinned module version (`Data\Versions.psd1`, now 2.26.1015.1). Otherwise it is refused with a
  message naming both versions, and nothing is stored. The generated configurations use the pinned version too.
- **Known file format.** The header of a DSC export looks like this (an older version, the format is the same):

  ```
  # Generated with Microsoft365DSC version 1.26.422.1
  # For additional information on how to use Microsoft365DSC, please visit https://aka.ms/M365DSC
  param ( )
  Configuration Entra
  {
      param ( )
      $OrganizationName = $ConfigurationData.NonNodeData.OrganizationName
      Import-DscResource -ModuleName 'Microsoft365DSC' -ModuleVersion '1.26.422.1'
      Node localhost
      {
  ```

  The configuration name (`Entra`) is not used to decide a workload. The tenant name is not in the header
  (`$OrganizationName` comes from separate configuration data), so it is entered in the GUI when not found.

## Calls made by me (not agreed; the user should check these)

1. **No export log.** A pipeline export has no `export.log`, so a failed type cannot be told from an empty one.
   Rule for uploads without a log: a type with no records in the files is NotChecked (no drift claimed for it), not
   empty. Types with records are checked. If a log is present it is used as today.
2. **Which files make a snapshot.** Any number of `.ps1` DSC configuration files in one upload. Each resource block is
   read; the workload comes from the resource type, not the file name. Duplicate blocks of the same resource across
   files: the later file wins and a warning is shown.
3. **Tenant identity.** An uploaded tenant has no Reader app, so its tenant id comes from the files (the DSC export
   states the tenant in its header/`OrganizationName`); if absent, the user types it. Domain translation needs the
   tenant short name, so this matters for Production vs PreProduction.
4. **Configuration format.** A DSC configuration `.ps1` per file in the same style as DSC's own export, generated with
   the resource schemas of the pinned module, not hand-written text per resource.

5. **Source and age per workload.** One check, but it records for each workload whether its data was exported live or
   uploaded, and when. The GUI shows the oldest or per-workload age, not one age for a mixed snapshot.
6. **What the configuration closes the gap to (corrected after reading the code).** The tenant's own blueprint (its last
   layer), exactly as Revert does today: checks, reverts and promotes already work against that blueprint, and the
   findings in a check are against it. To bring an offline tenant in line with a layer above (Production), the user first
   moves the wanted items into the tenant's own blueprint with the existing move actions, then generates the file. An
   item added to the own blueprint matches it and is not drift, so it is not written.
7. **Values in the configuration (corrected).** The records come from the own blueprint, which was taken from the offline
   tenant itself, so they already carry its own domains; nothing is translated. Credentials are written as references to
   `$ConfigurationData.NonNodeData` (as `ConvertTo-PEDscConfig` does), so the pipeline supplies them. Properties on the
   ignored/secret lists are never written; an item that needs one goes to "needs manual action".
8. **Empty types.** An upload can mark a workload as complete ("a type with no records in it is really empty"). Without
   that mark, rule 1 applies.

## Constraints

- Thin wrapper over Microsoft365DSC: no copies of its resource lists or per-resource knowledge. Record every deliberate
  gap in `docs/handover.md`.
- Secrets stay in `~\.m365dsc-policy\`; uploaded files may contain tenant data and are stored under the data folder
  like exports.
- Tests first; the full suite stays green; push `main` after each finished piece.

## Left to the builder

- Where the upload lives (CLI first, then a GUI upload page and Activity job).
- How the offline tenant is registered and shown (a flag on the tenant record, no apps).
- How credential-like values in generated configurations are handled (DSC exports use placeholders; the builder
  should follow what DSC does and flag any value that must be supplied).
- Ordering inside the generated configuration where resources depend on each other.
- The layout of the "needs manual action" list.
