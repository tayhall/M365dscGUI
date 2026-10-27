# Standards blueprints (ASD Blueprint first)

Date: 2026-10-27. Status: draft for approval.

## Intent and why

Customers want to know how their tenant compares with a published security
standard (the Australian ASD Blueprint for Secure Cloud now; NIST controls,
other government guidelines and the CIS benchmarks later), and to act on the
answer. A **standards blueprint** is a new kind of blueprint that holds such a
standard as a read-only reference set. A person can:

- **Check** a tenant against it, and re-run the check as new versions of the
  standard are published (CIS and ASD both release regularly).
- **Promote** some or all of its controls into one of their own blueprints,
  then apply that blueprint to the tenant as they do today.
- **Decide** on each difference: apply the change (Promote, then Revert as
  today), or **Accept risk**: leave the tenant as it is and record who approved
  it and why.

The tool helps people reach and keep a standard. It is not their system of
record for compliance or risk. Anything heavier than "approved by, and why"
(expiry, review dates, evidence, workflow) is out of scope until the tool has
matured.

## First source: the ASD Blueprint for Secure Cloud

- Repo: `ASD-Blueprint/ASD-Blueprint-for-Secure-Cloud` (a Hugo site). The DSC
  files are in `static/content/files/automation/dsc/`: `BlueprintEntraDsc.txt`,
  `BlueprintIntuneDsc.txt`, `BlueprintExoDsc.txt`, `BlueprintTeamsDsc.txt`,
  `BlueprintDefenderDsc.txt`, `BlueprintPurviewDsc.txt`, `BlueprintSpoDsc.txt`,
  and `ConfigurationData.txt`. They are plain DSC configuration scripts
  (`Configuration M365TenantConfig`, one resource block per object).
- 133 resource blocks (spike, 2026-10-27): Purview 51 (sensitivity labels, retention, DLP),
  Teams 40, Entra 22 (15 Conditional Access policies, named locations,
  authorisation policy), Intune 10, Exchange 4, SharePoint 4, Defender 2.
- Releases are tagged (v1.4.0 on 2026-09-18; "ISM updates" quarterly) with a
  changelog at `content/en/changelog.md`. The standard's version is the repo tag.
- Licence CC BY 4.0: the standard's metadata must carry the attribution (source
  name, URL, version) and the GUI shows it.
- The files carry no control IDs. The mapping from a setting to an ISM or
  Essential Eight control exists only in the website's prose pages (one page per
  policy). Control IDs are therefore optional in v1 (see Non-goals).
- The files were generated with older Microsoft365DSC versions (1.24.424.1 to
  1.25.827.1; this repo pins 2.26.x in `Data\Versions.psd1`), and use
  placeholders and tenant-specific values (`$ConditionalExclude`, `$PrivUsers`,
  `$TermsOfUse`, `TenantId`, `OrganizationName`, certificate settings).

## Goals

1. A blueprint has a **kind**: `Standard` or the existing ordinary kind. A
   standard is read-only (no Promote *into* it, no Revert *to* it, no
   Restore), is versioned by the standard's own release (for example
   `ASD Blueprint v1.4.0`), and carries source metadata (name, URL, version,
   licence/attribution).
2. **Import the ASD files into a standard** through DSC's own parser, not ours
   (CLAUDE.md, thin-wrapper rule): `ConvertTo-DSCObject` in the pinned
   Microsoft365DSC, to be confirmed against the pinned module; if it cannot do
   the job, stop and discuss before writing a parser.
3. **Check** a tenant against a standard using the existing comparison
   (`Compare-PEState`), restricted to the items the standard defines. Things the
   tenant has that the standard does not mention are not drift. The result
   states **coverage**: how many of the standard's items were checked and how
   many were left out, with the reason per left-out item.
4. **Leave out what cannot be mapped easily.** Items that depend on a
   placeholder or per-tenant value we cannot fill in (the ASD parameters and
   tenant-specific ids) are excluded from the check and counted as "not
   covered", not guessed. Coverage below 100% is expected and is future work,
   not a defect.
5. **Promote from a standard**: copy chosen items (one, a type, or all) into a
   tenant's own blueprint (or the master, with the existing master
   confirmation), as a new blueprint version with a reason. Each promoted item
   keeps a **provenance link** to its standard, standard version and control ID
   when known, so the tool can say which of a blueprint's settings came from
   which standard and which items of a standard are not yet adopted.
6. **Accept risk** as a new decision kind next to Unmanaged, Remove, Noise and
   PropertyExcluded in `decisions.json`: for one tenant and one item (and
   optionally one property) of a standard, with **who approved it** and **why**
   (the existing `Reason` plus an `ApprovedBy` field) and the existing `At`
   time stamp. An accepted difference is shown as accepted, not counted as open
   drift, and stays visible. Nothing else is recorded (no expiry, no evidence).
7. **Re-check against a newer version** of a standard: load the new version as a
   new version of the same standard, compare it with the previous one, and
   re-run the check. Accepted risks are matched by item key and stay accepted
   while the item's standard value is unchanged; if the standard's value for an
   accepted item has changed, the acceptance is shown as needing a new look.
8. **Engine and command line first (decided).** Everything above ships as
   module commands and `tools/` scripts. The GUI page (list standards and
   versions, a tenant's coverage and differences, Promote and Accept risk per
   item, following the Drift review and Selection list patterns) is a second
   step: mock-ups are discussed after the engine works. The engine's output
   (coverage, differences, decisions) should be shaped so the GUI can read it
   later through `Export-PEGuiData` without rework.

## Non-goals (for now)

- Not a compliance record: no expiry or review dates, no evidence, no approval
  workflow, no sign-off audit report.
- No control-ID mapping built by us. Where a source gives control IDs in
  machine-readable form they are stored; where it does not (ASD today) the
  field stays empty. Scraping ASD's prose pages for ISM or Essential Eight IDs
  is a later step.
- No 100% coverage. Placeholder- and tenant-bound items are left out.
- No NIST or CIS content yet. CIS is a stated goal, but no DSC-format source has
  been identified; finding one (or building a thin mapping onto DSC resources)
  is a separate piece of work and is not assumed here.
- No SharePoint or Security and Compliance apply. SharePoint is not reachable
  with the current Reader app permissions, and Security and Compliance types
  are check-only (existing safety rule). Standards items of those types can be
  checked where the tenant can be read, and are never applied.
- No applying a standard directly to a tenant. The existing rule stands: a
  tenant is only written from its own blueprint, so adoption is always
  Promote, then Revert/apply.

## Anti-goals (a failure even if it technically works)

- Reimplementing DSC: a hand-written parser for the ASD files, a copy of DSC's
  resource lists, or per-resource special cases.
- Guessing placeholder values so the numbers look better, or counting
  unchecked items as passing.
- A standard that can be edited or applied by accident, or that silently
  becomes part of the master blueprint.
- Accept risk that hides a difference: an accepted item must remain visible
  with who and why.

## Constraints

- Thin wrapper over Microsoft365DSC (`CLAUDE.md`): parse, export and apply with
  DSC's own commands; resource names and keys come from the pinned module
  (`ResourcePermissions.json`, `SchemaDefinition.json`).
- The module pin is guarded (`Data\Versions.psd1`, `Set-PEBlueprintModule`).
  The ASD files name older module versions: the import must not simply trust
  them. Whether a property written for 1.24/1.25 is still valid in the pinned
  version is checked with the existing round-trip classifier
  (`Invoke-PERoundTrip`, `docs/gap-analysis.md`) and unknown properties are
  reported.
- Existing blueprint rules hold: immutable versions, a change record each,
  crash-safe writes under a per-blueprint lock, a reason for every change.
- Existing layer rule holds (`tenants.json` `Blueprints` list per tenant). A
  standard is not a layer a tenant follows for apply purposes; whether a tenant
  can be "assigned" a standard to be checked on a schedule is left to the
  builder (see below).
- Runtime data (`data/`) stays git-ignored. Secrets stay in
  `~\.m365dsc-policy\`.
- Record any deliberate gap in `docs/handover.md` (CLAUDE.md).

## Decided by the user

- Standards are a new type of blueprint; ASD is the first source.
- Use: check a tenant, promote some or all controls into a blueprint and apply
  it, re-check regularly against the latest version, accept a difference with a
  sign-off or apply the change.
- Sign-off is light: who approved it and why. The tool is not their record.
- Items that cannot be mapped easily (placeholders and similar) are left out of
  the check for now; improving coverage is future work.

## My calls (to check while reading)

- A standard is a blueprint with `Kind = Standard` stored in the same
  `data/blueprints/` structure (reuses versioning, change records, locking and
  the comparison), rather than a separate store.
- The standard's version is the upstream release tag, not a counter we invent;
  our own blueprint version numbers still increment per import.
- Accept risk is a decision (in `decisions.json`), not a property of the
  standard, so the standard itself stays identical to its source.
- Coverage is reported per workload and in total, with a reason code per
  left-out item (`Placeholder`, `TenantBound`, `UnknownProperty`,
  `TypeNotReadable`, `NotInPinnedModule`).
- ASD's licence requires attribution; it is stored in the standard's metadata.

Added after the builder check (all my calls):

- **Item and key.** An item is one resource instance: DSC resource type plus its
  key, exactly as in an ordinary blueprint (`KeyMap.psd1`, schema keys). Accept
  risk and provenance are matched on type + key (+ property for Accept risk).
- **Partial items.** The ASD files state only some properties. The check
  compares only the properties the standard states; a property it omits is not
  drift. Promote copies the item as the standard states it. The builder must
  confirm `Compare-PEState` can compare a subset of properties; if it needs a
  new mode, stop and discuss (thin-wrapper rule).
- **Phase 0 is a spike.** Before anything else, try `ConvertTo-DSCObject` (or
  whatever the pinned module offers) on the seven ASD files. If it cannot parse
  them, stop and discuss before writing a parser. The rest of the plan is
  conditional on the spike.
- **Placeholders drop the whole item**, not just the property, so a standard
  item is never checked half-filled. Coverage counts these as not covered.
- **Matching by key.** A tenant object renamed away from the standard's key
  reads as Missing (the standard's item) plus Target-only (ignored). That is
  accurate, and is what the existing `PossibleRename` finding is for.
- **Read-only guard.** `Kind` absent means an ordinary blueprint (no backfill
  of existing `data/` files). Every write path (Promote into, Revert, Restore,
  master merge, tenant layer lists, schedules, apply) refuses a `Standard`.
- **Provenance** is a snapshot at promote time (standard, version, control ID).
  Editing the promoted item afterwards keeps the link; adoption counts the item
  as adopted. Provenance does not move to newer standard versions on its own.
- **Version changes** are compared on parsed, placeholder-free property values,
  not file text. An accepted risk needs another look when any property the
  standard states for that item has changed (not only the accepted property).
- **Coverage is per tenant per run** (readability depends on the tenant's
  permissions and licences), stored with the check, not with the standard.

## Left to the builder

- Exactly how the ASD files are turned into items (which DSC command, how
  placeholders are detected, how `Ensure`, `ApplicationId`, `CertificateThumbprint`
  and `TenantId` lines are stripped).
- How a standard is fetched: from a tagged release of the ASD repo at run time,
  or from a local clone (as `Microsoft365DSC/` is), and how "latest version" is
  detected.
- The data layout of a standard, the shape of provenance links and the new
  decision, and the GUI details of the standards page.
- Whether a tenant can be assigned a standard for scheduled re-checks now, or
  only checked on demand in v1.
- Tests (offline Pester with fake exports, as elsewhere).

## Success

A person with a connected tenant can load ASD v1.4.0, see "checked N of 133
settings" with the unchecked ones listed and why, see the differences grouped
by workload, promote three Conditional Access policies into their blueprint and
apply them through the existing Revert path, accept one difference with an
approver and a reason, and, when ASD releases a new version, load it and see
what changed and which accepted risks need another look.
