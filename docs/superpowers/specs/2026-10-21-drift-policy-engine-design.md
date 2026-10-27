# Drift policy engine for Microsoft 365 tenants: design

Date: 2026-10-21. Status: draft for review.

Items marked **(my call)** are decisions made while writing this document, not agreed in conversation. Check these first.

## Intent and why

Microsoft365DSC converges only the resources a configuration declares. If production (the master tenant) has no group B or policy B, and Dev (the replica) does, no configuration mentions it, so DSC never notices. Separately, parts of DSC are not truly idempotent: some resources report drift or reapply on every run when nothing has changed.

The engine keeps a **replica tenant (Dev) representative of a master tenant (production)**. Changes made in production appear in Dev. Differences, including items that exist only in Dev, are surfaced for a person to decide on, never silently changed. The same mechanism also brings a single tenant back in line when a change skipped change control.

## Concepts

- **Master / replica.** Master is the source of truth (production, live changes). Replica is Dev.
- **Blueprint.** A full DSC export of the master, locked. It changes only through an explicit "update blueprint" action. Drift never overwrites it. Everything is compared against the blueprint.
- **Blueprint versions.** Updating the blueprint is a **reviewed** action. A fresh master export is compared with the current blueprint and the user accepts or rejects the changes (all, or per resource instance). Accepting creates a new immutable version with a timestamp and a record of what changed; old versions are kept. Changes accepted into the blueprint then show up as Missing or Changed on the replica and flow to it through the normal check and rectify path. (Decided with the user.)
- **Delta.** A DSC export and config limited to specific resource instances. DSC's `Export-M365DSCConfiguration` has a `-Filters` hashtable (resource name to OData filter) for resources that support a `Filter`, and `-Components` to limit to resource types; types without filter support fall back to exporting that one resource type. To be confirmed per resource type.
- **Drift.** A difference between the blueprint and a target tenant, in one of three forms:
  - *Missing:* in the blueprint, not in the target.
  - *Changed:* in both, with different settings.
  - *Target-only:* in the target, not in the blueprint. This is the case DSC cannot see.
- **Unmanaged.** A target-only item the user has chosen to leave alone. The decision is remembered.
- **Check.** Export the target, normalise, compare against the blueprint.
- **Rectify.** Generate a DSC configuration containing only the selected changes, save it, apply it, then re-check.

## Goals

1. Detect all three forms of drift, per workload and per resource, with the setting-level difference visible.
2. Target-only items are flagged first. The user then chooses:
   - **Remove** from the replica (deleted after approval).
   - **Keep as unmanaged.**
   - **Promote** to the master (replica-originated work such as a new policy built in Dev first).
3. Rectify produces a DSC config for approved changes only, saves it for audit, applies it, then re-checks the same scope.
4. Two check types, both **run on a schedule** and on demand:
   - **Full check:** a full DSC export of the in-scope workloads (about 25 minutes for the four workloads in a sparse tenant). Compares every setting.
   - **Quick check (scan):** a lightweight scan of what exists in the tenant, compared against the blueprint's inventory of resource types and keys. It does not export every setting. It reports new objects, missing objects and possible renames within minutes. For anything it finds, the engine then does a **delta**: it exports only those objects (a small DSC file), and rectify applies only that delta to the other tenant, so a new group does not need a 25-minute export plus a 25-minute apply.
   - **Limit of the scan (my call):** it sees added, removed and renamed objects. It cannot see a changed setting inside an object that still exists, unless the API exposes a last-modified time (some Intune policies do; to be confirmed per type). Setting-level drift is found only by the Full check, so the Full check still runs on a schedule (for example daily) and the scan runs more often (for example every 30 minutes). Report the age of the last Full check next to the status so nobody reads a scan as full alignment.
5. Users and user assignments are out of scope. All other settings are in scope.
6. Idempotent in effect: after a successful rectify, the next check shows aligned. Where DSC itself reports drift on unchanged settings, the user can record a per-property "accepted noise" rule so it stops showing. **(my call)**
7. Workload status view: for each workload (Entra ID, Intune, Exchange Online, Teams first), how many resources are aligned and which have drifted. Unmanaged items are excluded from these counts and shown in their own list.

## Non-goals (for now)

- Web GUI. It comes after the drift system works (see "Later"). The first version is local PowerShell scripts producing a drift report.
- Entra sign-in, multiple users, roles. One user.
- Running in Azure DevOps or containers. Design for it; do not build it yet.
- Workloads beyond Entra ID, Intune, Exchange Online and Teams. SharePoint, Defender, Purview and Power Platform come later.
- Users, mailboxes and anything bound to a specific user.

## Anti-goals (a failure even if it technically works)

- Deleting or changing anything in a tenant without the user having seen and approved that specific change.
- Writing to the master without an explicit confirm. Promotion is the only action that does, and it needs one click plus a saved config.
- Showing licence- or feature-gated resources the tenant doesn't have as drift.
- Secrets, certificates, tenant data or exports in the repo.
- Silently matching the wrong objects across tenants. If a resource type has no reliable key, flag it instead of guessing.

## Matching and normalisation

- Match objects across tenants by a human-readable key, not a GUID: the DisplayName, Name or unique description field that the DSC resource already uses as its identity. The DSC resource definitions are the guide per type.
- Findings from a first full export of a sparse test tenant (400 of 429 components exported; this is a reading of that export, not confirmed against the DSC code):
  - Many references are already exported by name (for example roles in Conditional Access policies).
  - `TenantId`, `ApplicationId` and `CertificateThumbprint` are parameters in `$ConfigurationData`, so one config can target another tenant by changing that data file.
  - Each resource's own `Id` is tenant-specific. Ignore it in comparison.
  - Built-in role GUIDs (`AADRoleManagementPolicyRule.PolicyId`, `AADRoleDefinition.TemplateId`) look the same in every tenant.
  - Service principals and Teams carry tenant-specific object IDs. Key them by name.
- **Untested:** the test tenant has no Intune policies and no assignments to specific groups. The case where an export refers to a group by GUID is not yet seen. The first real changes should include an Intune policy assigned to a group.

## Constraints and decisions

- **Language and runtime:** PowerShell 7.6+ (Microsoft365DSC 2.x requires it). Scripts run locally for now. They later run in Azure DevOps pipelines and Linux containers (the DSC repo ships a Linux Dockerfile).
- **DSC version:** Microsoft365DSC 2.26.1015.1 with its pinned dependencies (Microsoft.Graph.Authentication 2.41.1, M365DSC.PSDesiredStateConfiguration 3.1.10). Always import by explicit version, because an older 1.x is also installed system-wide.
- **Authentication:** certificate-based app registrations, no interactive sign-in at run time.
  - *Reader:* DSC's read permissions with write-level ones swapped for read variants where Graph has them (64 granted; 8 write-level permissions have no read variant). Directory role Global Reader.
  - *Writer:* DSC's full update permissions (79 granted). Global Administrator on the test tenant only; narrower roles for production.
  - Certificates live in the Windows user store locally and in Key Vault in pipelines. Details are written to `~\.m365dsc-policy\`, outside the repo.
- **Daily pipeline (later):** full export on a schedule with access to both tenants. Only the apply pipeline may hold the Writer certificate.
- **Repo layout:** scripts and tools in `tools/`; exports and run data in `data/` (git-ignored). Scripts developed during this work live in the repo, not in scratch locations.
- **Test setup:** one tenant (`contoso.onmicrosoft.com`) acts as both master and replica. Export it as the locked blueprint, make manual changes, and the engine reports them as drift and rectifies them. This is also the "tenant changed outside change control" case.

## Rules settled during review (all **my call**)

- **Scope of v1.** v1 proves the engine on the single test tenant (tenant acting as both master and replica). The two-tenant case (production to Dev) is the next phase, and nothing in v1 may preclude it. The GUID-to-name translation layer and an Intune-policy-with-group-assignment test are built when we reach that phase, not before. The first manual changes should still include one such policy so the gap is seen early.
- **Duplicate or renamed keys.** If a key is not unique within a type in either tenant, those objects are reported as *ambiguous* and are never offered for Remove or Rectify. A *Missing* item and a *Target-only* item of the same type with near-identical settings are shown together as a "possible rename" before any Remove is offered.
- **Promote mechanics.** Promote exports the item from the replica, generates a DSC config that targets the master, saves it, and applies it with the Writer certificate after the confirm click. Because the master has then changed on purpose, the blueprint is updated **for that item only** as part of the same action, and the replica item becomes managed. This is the one item-level exception to "the blueprint only changes through an explicit update". Production needs its own, narrower Writer role set before this is used for real.
- **Granularity.** The report shows setting-level differences, but approval and rectify are per resource instance, because DSC applies whole resources. The audit trail records one entry per approved instance with the generated config.
- **Accepted-noise rules.** A rule is scoped to resource type plus property, and optionally to one resource instance. It also records the value it applies to, so a *different* value still shows as drift. Rules are listed in one place, with the reason and date.
- **Failed exports.** A component that fails to export from a target cannot produce *Missing* or *Target-only* findings, and cannot be rectified. It is shown as "not checked", with the error. Licence- and feature-gated failures that also fail the same way on the blueprint side are recorded as "not available in this tenant". Rectify for a workload is blocked while any of its components are "not checked", unless the user rectifies a selected resource whose component exported successfully.
- **Reader risk.** The Reader app holds 8 write-level permissions that have no read variant. Accepted for v1, because no Reader code path writes. The engine only ever calls the export and read commands with the Reader certificate. Revisit before production.
- **Secrets and sensitive values.** Passwords, client secrets and other values DSC cannot read back are not compared and not stored. They are shown as "unreadable" and never count as drift. Exports, generated configs and the audit trail live in the git-ignored `data/` folder only.

## Current state (done)

- PowerShell 7.6.7; Microsoft365DSC 2.26.1015.1 and all pinned dependencies installed; `tools/Install-M365DscDependencies.ps1`.
- Reader and Writer app registrations, certificates, consent and directory roles; `tools/New-M365DscAppRegistration.ps1`, `tools/Set-M365DscAppRoles.ps1`.
- `tools/Export-M365DscTenant.ps1`: certificate-based export. A first full Reader export took roughly 25 minutes: 400 components exported, 29 failed because of features or licences the tenant lacks, and it produced an 8 MB file.
- Repo at https://github.com/Tayhall/M365dscGUI.

## Later

A web GUI with the views already shown: a workload overview with aligned/drifted status, a drift review per workload with per-row choices, and a rectify action that shows the generated config before applying. A thin web layer over the engine, in PowerShell (Pode is the leading candidate), with long jobs run in the background. The engine must not depend on it. Entra sign-in comes after a single-user version.

## Left to the builder

- How state is stored: JSON files or SQLite for the blueprint, check results, unmanaged decisions, accepted-noise rules and the audit trail of generated configs.
- Module and script layout, and the command names.
- How to compare: write it ourselves, or reuse the compiled `Compare`, `Converter` and `Relations` components in the DSC repo's `src/` (not yet read).
- How to run a quick check efficiently, and how to apply a generated config (LCM relay versus direct).
- The format of the drift report in the script-only version.
- How to detect "not available in this tenant" as distinct from a real error.
