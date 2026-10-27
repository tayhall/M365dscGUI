# Key coverage

Every record is matched across states by `(ResourceType, Key)`. The key comes from `src/PolicyEngine/Data/KeyMap.psd1`:
the `Overrides` entry for the type (a single property, or several properties joined with ` | ` as a composite key, where
an empty part makes the record Unkeyed), otherwise the first non-empty of `DisplayName`, `Name`, `Identity`, otherwise
`(singleton)` for tenant-wide settings resources keyed only by `IsSingleInstance`.

Overrides were chosen from the `[DscProperty(Key)]` properties in the Microsoft365DSC resource definitions and checked
against a real tenant export so that the key is unique in the data. Readable properties are preferred over GUIDs. This
file holds only type names and counts; no tenant data. Regenerate the numbers with
`tools/Measure-PEKeyCoverage.ps1 -Path <export>`.

Inside a composite key each part is escaped before joining (`\` becomes `\\`, `|` becomes `\|`), so two different
tuples of parts can never produce the same key string, for example `('a | b', 'c')` and `('a', 'b | c')`. Parts without
`|` or `\` are unchanged, so existing composite keys stay stable. Single-property keys and `(singleton)` are never
escaped, which keeps them identical to the full export.

## Summary (first full Reader export, 7,954 records, 171 types)

| | Before | After |
|---|---|---|
| Unkeyed records | 2,719 (across 17 types) | 0 |
| Ambiguous groups / records | 715 groups / 1,491 records (5 types) | 678 groups / 1,356 records (1 type) |

Self-comparison of the normalised export with `Compare-PEState` yields no Changed, Missing, TargetOnly or Unkeyed
findings; only the 678 Ambiguous findings below remain.

(The earlier figures "5,438 Unkeyed and 715 Ambiguous" counted both sides of the self-comparison, so the Unkeyed
records are 2,719 per side.)

## Remaining Ambiguous

- `EXOManagementRoleEntry` (678 groups): the DSC key is `Identity` only (`<Role>\<Cmdlet>`), and the export contains
  records that are identical in every property, including `Identity`, `Type` and `Parameters`; there is no other
  property to tell them apart. They are real duplicates, so they stay Ambiguous (allow-listed in
  `tests/KeyCoverage.Tests.ps1`). Since the acceptance run entries of built-in roles are excluded from comparison (see
  [Excluded types and nested ignores](#excluded-types-and-nested-ignores)), so checks no longer report these.

## Keys that are not human-readable

- `AADOrganizationCertificateBasedAuthConfiguration`, `AADCrossTenantAccessPolicy` and `EXOExternalInOutlook` are
  one-per-tenant objects whose identity is the connected tenant's own GUID, so it never matches across tenants. They are
  listed under `Singletons` in `KeyMap.psd1` and always get the key `(singleton)`.
- `AADCrossTenantAccessPolicyConfigurationPartner` is keyed by `PartnerTenantId` (a partner tenant's ID, not the connected tenant's own); no readable alternative exists.

## Types that stay Unkeyed

None in the first export. A type with no reliable key would be listed here instead of guessing one.

## Types that cannot be rectified yet

These types have `Id` as their DSC `[Key]` parameter in the Microsoft365DSC 2.26.1015.1 schema (`SchemaDefinition.json`).
Normalisation removes `Id` from every record (`Data\IgnoredProperties.psd1`, because most resources use it for a
tenant-specific GUID), so the stored records lack the key. `ConvertTo-PEDscConfig` therefore refuses them with "the Key
property 'Id' is missing from the record". This is a safe failure: they are still compared and reported, but Rectify
and Promote cannot generate a configuration for them until the ignore list gets a per-type exception for `Id` on types
where it is a readable, tenant-independent name.

- `AADAuthenticationMethodPolicyAuthenticator`, `AADAuthenticationMethodPolicyEmail`, `AADAuthenticationMethodPolicyFido2`,
  `AADAuthenticationMethodPolicyHardware`, `AADAuthenticationMethodPolicyQRCodeImage`, `AADAuthenticationMethodPolicySms`,
  `AADAuthenticationMethodPolicySoftware`, `AADAuthenticationMethodPolicyTemporary`, `AADAuthenticationMethodPolicyVoice`,
  `AADAuthenticationMethodPolicyX509` (Id is the method name, for example `MicrosoftAuthenticator`; also the match key)
- `AADDomain` (Id is the domain name; also the match key)
- `IntuneDeviceManagementEnrollmentAndroidGooglePlay` (match key `Id`)
- `AADRoleManagementPolicyRule` (match key `RoleDisplayName | Id`)
- `AADPermissionGrantPolicy`, `IntuneDeviceEnrollmentPlatformRestriction` (DSC key `Id`; matched by `DisplayName`)

`AADAttributeSet` (keyed by `Id` in `KeyMap.psd1`) is in the same position but has no records in the first export. The
list was derived by intersecting each exported type's `Key`/`Required` schema parameters with the ignore lists; no other
exported type has a key or required parameter on the ignore lists.

## Excluded types and nested ignores

Two data-only mechanisms remove noise found by the live acceptance run (`docs/acceptance-v1.md`, "DSC non-idempotent
noise"). Both are applied by the engine; no tenant change and no new blueprint is needed.

### Nested ignore paths (`Data\IgnoredProperties.psd1`)

An entry in `Global` or `ByType` may be a dotted path into a nested value, for example `Assignments.groupId`, or a
conditional entry `@{ Path = '<name or path>'; When = 'PastExport' }`.

- Names and segments match case-insensitively. The path is followed through hashtables / ordered dictionaries (the DSC
  parser's CIM instances), PSCustomObjects (the same data read back from JSON) and real CimInstances. An array on the
  way is walked element by element: the same remaining path is applied to every element.
- Only the last member is removed. Its parent stays with its remaining members. A parent OBJECT that the removal leaves
  empty (no members, or only the parser's `CIMInstance` class name) is dropped from its own parent object. Array
  elements are never dropped, even when emptied: the array keeps its length and order, so `[g1, g2]` against `[g1]`, or
  against no array, is still a difference. (Arrays still compare as sets: two elements that differ ONLY in the ignored
  member become equal and count once.) Containers that were empty before are left alone.
- `When = 'PastExport'` mirrors Microsoft365DSC's `IgnoreWhenPast`: the value is removed only when it is empty or a
  date at or before the export time of the state the record comes from (`Meta.ExportedAt`; dates are parsed invariant,
  without an offset as UTC). A future date, or one that cannot be parsed, is kept and compared. Without a known export
  time the entry is not applied. Every caller that normalises an export passes the time: `New-PEStateFromExport` and
  `Invoke-PEFullCheck` the export file's write time, `Export-PEDelta` each delta export file's write time, and the
  rectify recheck uses the recheck time for the planned records.
- A path that does not exist, or that runs into a scalar (string, number, bool, `$null`), changes nothing.
- The input record is never modified: the containers along the path are copied; everything off the path is shared.
- An entry with an empty segment (`A..b`) is a data error and throws.
- Applied twice: in `ConvertTo-PENormalizedRecord` (new exports, deltas, blueprints) and by `Compare-PEState` to both
  records of a matched pair before their properties are compared, so a blueprint stored before an entry was added does
  not show the removed member as Changed. Conditional entries use each state's own `Meta.ExportedAt` there. The records
  attached to a finding are the stored ones, unchanged.
- Limitation: `ConvertTo-PEDscConfig`'s safety check refuses ignored TOP-LEVEL names in a generated configuration only;
  nested and conditional paths are not checked inside the rendered property tree (normalisation has removed them from
  the records, and a future `startDateTime` must be rendered).

Entries:

| Type | Path | Why |
| --- | --- | --- |
| `AADRoleAssignmentScheduleRequest` | `ScheduleInfo.startDateTime`, `When = 'PastExport'` | A permanent assignment exports the time of the export as its start time, so every assignment was Changed on every check; a value-scoped Noise decision cannot cover a value that is new every time. Only a start at or before the export time is ignored, as the DSC resource does (`IgnoreWhenPast`); a future start is a real setting (a rectify without it would activate the role at once), so it is kept, compared and rendered. |

Top-level user-list ignores (same rationale as `AADGroup` `Members` / `Owners` / `MemberOf`: users are out of scope;
each property checked in the Microsoft365DSC resource and none is a Key or mandatory parameter):
`AADAdministrativeUnit.Members` (users, groups, devices), `AADServicePrincipal.AppRoleAssignedTo` (users and groups
assigned to the app) and `AADServicePrincipal.Owners`, `AADApplication.Owners`, `EXODistributionGroup.Members`,
`TeamsTeam.Owner` (the resource's property is `Owner`, not `Owners`).

Proposal, not implemented (two-tenant phase): `groupId` in Intune assignments. Across two tenants the group GUID
differs while `groupDisplayName` matches, so every assigned Intune policy would be Changed. The nested path support
covers it as a `ByType` entry per Intune type, for example `Assignments.groupId` (the path is applied to every element of
the `Assignments` array). It is not added now: in a single tenant the GUIDs are stable, and the generated configuration
relies on `groupId` today (DSC Set resolves the group by `groupId` first and falls back to `groupDisplayName`). A
per-CIM-class form (ignore a member wherever a given CIM class appears) is not needed for this and does not exist.

### Excluded types (`Data\ExcludedTypes.psd1`)

Resource types the engine deliberately does not compare, each with a reason. An entry may instead be
`@{ Reason; RecordRule }`: then only the records the named rule (code in `Private\Compare.ps1`,
`Test-PERecordKeptByRule`) does not keep are excluded, and the kept records are compared as usual (NotChecked and
NotAvailable apply to the type as for any other; the Excluded finding appears only when records were left out, with
the counts of excluded records). The only rule is `KeepCustomRoleEntries`.

- `Compare-PEState` ignores their records on both sides: no Missing, TargetOnly, Changed, Ambiguous, PossibleRename or
  Unkeyed findings. Each excluded type that has records on either side, or that is in either NotChecked list, gets ONE
  finding of Kind `Excluded` (`Key` empty, `Hint` = the reason, `BlueprintCount` / `TargetCount` = how many records of
  the type each side has).
- Excluded wins over NotChecked and NotAvailable: a type that is excluded and also failed to export is reported only
  as Excluded (it would not be compared even if it had exported).
- `Compare-PEState -IncludeTypes <string[]>` compares the named types anyway for that one call (case-insensitive), for
  anyone who wants to look at them. The rectify recheck passes the planned types this way, so a plan made from such a
  comparison is verified like any other.
- `Get-PEStatus` takes the excluded types from the `Excluded` findings: their blueprint records are not counted in
  Total, Aligned or Drifted, and each workload has an `Excluded` count of types, shown by `Format-PEStatus` as
  `Excluded (types)`.
- `New-PERectifyPlan` refuses Excluded findings for every action (as NotChecked), `Approve-PEBlueprintChange` refuses
  them (only Missing, TargetOnly and Changed are accepted), and `Select-PEDeltaFinding` / `Export-PEDelta` never select
  or accept them.
- The exclusion is applied only at compare and status time. Exports, check states and blueprints
  (`New-PEStateFromExport`, `Invoke-PEFullCheck`) keep the records of excluded types, so lifting
  an exclusion later needs no new blueprint. The full check and the scope check compare through `Compare-PEState` and
  inherit the exclusion. Blueprint updates (`Get-PEBlueprintChange`) do not compare these types either, so their
  records stay in the blueprint as they were taken.

Excluded types and why (the design puts users, mailboxes and anything bound to a specific user out of scope):

| Type | Reason |
| --- | --- |
| `EXOManagementRoleEntry` (record rule `KeepCustomRoleEntries`) | Entries of BUILT-IN roles are excluded: Microsoft-defined role definitions whose duplicate records change run to run (996 / 1,996 / 1,149 / 1,621 Ambiguous, plus hundreds of Missing / TargetOnly, in the acceptance run). Entries of CUSTOM roles stay compared: an entry whose role (the part of `Identity` before the first `\`) is an `EXOManagementRole` record of the same state with a non-empty `Parent`. Each side is judged by its own roles, so removing a custom role shows its entries Missing. |
| `EXOMailboxSettings` | Settings of one mailbox. Its `Identity` also flips between the user name and the mailbox GUID between exports (a false PossibleRename pair in the acceptance run). |
| `EXOCASMailboxSettings` | Client access settings of one mailbox. |
| `EXOCalendarProcessing` | Calendar processing of one (resource) mailbox. |
| `EXOMailboxAuditBypassAssociation` | Audit bypass of one user or computer account (one record per account). |
| `EXOMailboxAutoReplyConfiguration` | Automatic replies of one mailbox. |
| `EXOMailboxCalendarConfiguration` | Calendar settings of one mailbox. |
| `EXOMailboxCalendarFolder` | Publishing settings of one mailbox calendar folder. |
| `EXOMailboxFolderPermission` | Permissions on a folder of one mailbox. |
| `EXOMailboxIRMAccess` | IRM access of one user to one mailbox. |
| `EXOMailboxPermission` | Permissions of one user on one mailbox. |
| `EXORecipientPermission` | Send As permission of one trustee on one recipient. |
| `EXOSharedMailbox` | A shared mailbox is a mailbox. |
| `EXOPlace` | A room or workspace, which is a resource mailbox. |
| `EXOFocusedInbox` | Focused Inbox setting of one mailbox. |
| `EXOSweepRule` | A Sweep rule inside one mailbox. |
| `EXOAuthenticationPolicyAssignment` | Assignment of an authentication policy to one user (the policies themselves are compared). |
| `AADUser` | One user account. |
| `AADAuthenticationRequirement` | Per-user MFA requirement. |
| `TeamsUser` | Membership of one user in one team. |
| `TeamsUserCallingSettings` | Calling settings of one user. |
| `TeamsOnlineVoicemailUserSettings` | Voicemail settings of one user. |
| `TeamsOnlineVoiceUser` | Phone number and location of one user. |
| `TeamsUserPolicyAssignment` | Teams policies assigned directly to one user. |

The key rules in `KeyMap.psd1` (for example `AADUser` by `UserPrincipalName`, `TeamsUser` by `TeamName | User`) stay
as they are: records are still keyed, they are just not compared, and nothing rectifies an Excluded finding.

Not excluded on purpose (they grant administrative power, so a change must stay visible even when it names a user):

| Type | Why it stays compared |
| --- | --- |
| `AADRoleAssignmentScheduleRequest` | Active Entra admin-role assignments. |
| `AADRoleEligibilityScheduleRequest` | Eligible (PIM) Entra admin-role assignments. |
| `EXOManagementRoleAssignment` | Exchange role assignments to users, groups and policies. |
| `EXORoleGroup` | Exchange role groups and their roles (members are not compared). |
| `IntuneRoleAssignment` | Intune RBAC assignments. |
| `TeamsGroupPolicyAssignment` | Teams policies assigned through groups (tenant policy, not one user). |

Also not excluded, because they are tenant-wide policy or group configuration: mailbox and CAS mailbox plans, OWA,
ActiveSync and mobile device mailbox policies, management roles, distribution groups and group settings, mail
contacts, and every transport, protection, retention and sharing policy.

`Compare-PEState -IncludeTypes` warns once per call about names that are not excluded. The check tools list Excluded findings apart from the checked ones.

## Per type

| Type | Records | Key used | Unkeyed | Ambiguous |
|---|---|---|---|---|
| AADAccessReviewPolicy | 1 | `(singleton)` | 0 | 0 |
| AADAdminConsentRequestPolicy | 1 | `(singleton)` | 0 | 0 |
| AADApplication | 7 | default (DisplayName, Name, Identity) | 0 | 0 |
| AADAuthenticationFlowPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| AADAuthenticationMethodPolicy | 1 | `(singleton)` | 0 | 0 |
| AADAuthenticationMethodPolicyAuthenticator | 1 | `Id` | 0 | 0 |
| AADAuthenticationMethodPolicyEmail | 1 | `Id` | 0 | 0 |
| AADAuthenticationMethodPolicyFido2 | 1 | `Id` | 0 | 0 |
| AADAuthenticationMethodPolicyHardware | 1 | `Id` | 0 | 0 |
| AADAuthenticationMethodPolicyQRCodeImage | 1 | `Id` | 0 | 0 |
| AADAuthenticationMethodPolicySms | 1 | `Id` | 0 | 0 |
| AADAuthenticationMethodPolicySoftware | 1 | `Id` | 0 | 0 |
| AADAuthenticationMethodPolicyTemporary | 1 | `Id` | 0 | 0 |
| AADAuthenticationMethodPolicyVoice | 1 | `Id` | 0 | 0 |
| AADAuthenticationMethodPolicyX509 | 1 | `Id` | 0 | 0 |
| AADAuthenticationRequirement | 34 | `UserPrincipalName` | 0 | 0 |
| AADAuthorizationPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| AADConditionalAccessPolicy | 3 | default (DisplayName, Name, Identity) | 0 | 0 |
| AADCrossTenantAccessPolicy | 1 | `(singleton)` (Singletons list) | 0 | 0 |
| AADCrossTenantAccessPolicyConfigurationDefault | 1 | `(singleton)` | 0 | 0 |
| AADDeviceRegistrationPolicy | 1 | `(singleton)` | 0 | 0 |
| AADDomain | 1 | `Id` | 0 | 0 |
| AADEntitlementManagementAccessPackage | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| AADEntitlementManagementAccessPackageCatalog | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| AADEntitlementManagementAccessPackageCatalogResource | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| AADEntitlementManagementSettings | 1 | `(singleton)` | 0 | 0 |
| AADExternalIdentityPolicy | 1 | `(singleton)` | 0 | 0 |
| AADGroup | 27 | default (DisplayName, Name, Identity) | 0 | 0 |
| AADGroupsSettings | 1 | `(singleton)` | 0 | 0 |
| AADIdentityProtectionPolicySettings | 1 | `(singleton)` | 0 | 0 |
| AADMultiTenantOrganizationIdentitySyncPolicyTemplate | 1 | `(singleton)` | 0 | 0 |
| AADNamedLocationPolicy | 4 | default (DisplayName, Name, Identity) | 0 | 0 |
| AADOnPremisesPublishingProfilesSettings | 1 | `(singleton)` | 0 | 0 |
| AADOrganizationCertificateBasedAuthConfiguration | 1 | `(singleton)` (Singletons list) | 0 | 0 |
| AADPasswordRuleSettings | 1 | `(singleton)` | 0 | 0 |
| AADPermissionGrantPolicy | 14 | default (DisplayName, Name, Identity) | 0 | 0 |
| AADRoleAssignmentScheduleRequest | 13 | `Principal | RoleDefinition | DirectoryScopeId` (composite) | 0 | 0 |
| AADRoleDefinition | 145 | default (DisplayName, Name, Identity) | 0 | 0 |
| AADRoleManagementPolicyRule | 2465 | `RoleDisplayName | Id` (composite) | 0 | 0 |
| AADRoleSetting | 145 | default (DisplayName, Name, Identity) | 0 | 0 |
| AADSecurityDefaults | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| AADServicePrincipal | 207 | default (DisplayName, Name, Identity) | 0 | 0 |
| AADTenantAppManagementPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| AADTenantDetails | 1 | `(singleton)` | 0 | 0 |
| AADUser | 34 | `UserPrincipalName` | 0 | 0 |
| EXOAcceptedDomain | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOActiveSyncMailboxPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOActiveSyncOrganizationSettings | 1 | `(singleton)` | 0 | 0 |
| EXOAntiPhishPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOArcConfig | 1 | `(singleton)` | 0 | 0 |
| EXOATPBuiltInProtectionRule | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOAtpPolicyForO365 | 1 | `(singleton)` | 0 | 0 |
| EXOCalendarProcessing | 28 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOCASMailboxPlan | 4 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOCASMailboxSettings | 28 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXODataClassification | 225 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXODistributionGroup | 11 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXODnssecForVerifiedDomain | 1 | `DomainName` | 0 | 0 |
| EXOEmailTenantSettings | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOExternalInOutlook | 1 | `(singleton)` (Singletons list) | 0 | 0 |
| EXOGroupSettings | 15 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOHostedConnectionFilterPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOHostedContentFilterPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOHostedOutboundSpamFilterPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOIRMConfiguration | 1 | `(singleton)` | 0 | 0 |
| EXOMailboxAuditBypassAssociation | 176 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOMailboxAutoReplyConfiguration | 28 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOMailboxCalendarConfiguration | 28 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOMailboxCalendarFolder | 28 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOMailboxFolderPermission | 14 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOMailboxPermission | 49 | `Identity | User | InheritanceType` (composite) | 0 | 0 |
| EXOMailboxPlan | 4 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOMailboxSettings | 28 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOMailContact | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOMalwareFilterPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOManagementRole | 5 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOManagementRoleAssignment | 212 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOManagementRoleEntry | 3149 | `Identity` | 0 | 678 groups / 1356 records |
| EXOMobileDeviceMailboxPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOOMEConfiguration | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOOrganizationConfig | 1 | `(singleton)` | 0 | 0 |
| EXOOwaMailboxPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOPerimeterConfiguration | 1 | `(singleton)` | 0 | 0 |
| EXOPlace | 8 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOPolicyTipConfig | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOQuarantinePolicy | 4 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXORecipientPermission | 188 | `Identity | Trustee` (composite) | 0 | 0 |
| EXORemoteDomain | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOReportSubmissionPolicy | 1 | `(singleton)` | 0 | 0 |
| EXORetentionPolicy | 3 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXORetentionPolicyTag | 18 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXORoleAssignmentPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXORoleGroup | 31 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOSafeAttachmentPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOSafeLinksPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOSharingPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| EXOTeamsProtectionPolicy | 1 | `(singleton)` | 0 | 0 |
| EXOTransportConfig | 1 | `(singleton)` | 0 | 0 |
| EXOTransportRule | 3 | default (DisplayName, Name, Identity) | 0 | 0 |
| IntuneAppCategory | 9 | default (DisplayName, Name, Identity) | 0 | 0 |
| IntuneAppConfigurationPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| IntuneAppProtectionPolicyAndroid | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| IntuneAppProtectionPolicyiOS | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| IntuneCustomizationBrandingProfile | 1 | `ProfileName` | 0 | 0 |
| IntuneDeviceCompliancePolicyiOs | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| IntuneDeviceConfigurationPolicyiOS | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| IntuneDeviceConfigurationPolicyWindows10 | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| IntuneDeviceEnrollmentLimitRestriction | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| IntuneDeviceEnrollmentPlatformRestriction | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| IntuneDeviceEnrollmentStatusPageWindows10 | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| IntuneDeviceManagementComplianceSettings | 1 | `(singleton)` | 0 | 0 |
| IntuneDeviceManagementDeviceDiagnosticSettings | 1 | `(singleton)` | 0 | 0 |
| IntuneDeviceManagementEnrollmentAndroidGooglePlay | 1 | `Id` | 0 | 0 |
| IntuneMobileAppsStoreApp | 8 | default (DisplayName, Name, Identity) | 0 | 0 |
| IntuneRoleDefinition | 10 | default (DisplayName, Name, Identity) | 0 | 0 |
| IntuneWindowsAutopilotDeploymentProfileAzureADJoined | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| IntuneWindowsBackupForOrganizationConfiguration | 1 | `(singleton)` | 0 | 0 |
| IntuneWindowsDataProcessingSettings | 1 | `(singleton)` | 0 | 0 |
| IntuneWindowsHelloForBusinessGlobalPolicy | 1 | `(singleton)` | 0 | 0 |
| TeamsAIPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsAppPermissionPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsAppSetupPolicy | 2 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsAudioConferencingPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsCallHoldPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsCallingPolicy | 5 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsCallParkPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsChannel | 24 | `TeamName | DisplayName` (composite) | 0 | 0 |
| TeamsChannelsPolicy | 2 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsChannelTab | 61 | `TeamName | ChannelName | DisplayName` (composite) | 0 | 0 |
| TeamsClientConfiguration | 1 | `(singleton)` | 0 | 0 |
| TeamsComplianceRecordingPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsCortanaPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsDialInConferencingTenantSettings | 1 | `(singleton)` | 0 | 0 |
| TeamsEmergencyCallingPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsEmergencyCallRoutingPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsEnhancedEncryptionPolicy | 3 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsEventsPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsFederationConfiguration | 1 | `(singleton)` | 0 | 0 |
| TeamsFeedbackPolicy | 4 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsFilesPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsGuestCallingConfiguration | 1 | `(singleton)` | 0 | 0 |
| TeamsGuestMeetingConfiguration | 1 | `(singleton)` | 0 | 0 |
| TeamsGuestMessagingConfiguration | 1 | `(singleton)` | 0 | 0 |
| TeamsIPPhonePolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsMeetingBroadcastConfiguration | 1 | `(singleton)` | 0 | 0 |
| TeamsMeetingBroadcastPolicy | 2 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsMeetingConfiguration | 1 | `(singleton)` | 0 | 0 |
| TeamsMeetingPolicy | 7 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsMessagingConfiguration | 1 | `(singleton)` | 0 | 0 |
| TeamsMessagingPolicy | 4 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsMobilityPolicy | 2 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsNetworkRoamingPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsNotificationAndFeedsPolicy | 1 | `(singleton)` | 0 | 0 |
| TeamsOnlineVoicemailPolicy | 4 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsOnlineVoicemailUserSettings | 34 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsOnlineVoiceUser | 20 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsOrgWideAppSettings | 1 | `(singleton)` | 0 | 0 |
| TeamsShiftsPolicy | 2 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsTargetingPolicy | 1 | `(singleton)` | 0 | 0 |
| TeamsTeam | 13 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsTemplatesPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsTenantDialPlan | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsUpdateManagementPolicy | 2 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsUpgradeConfiguration | 1 | `(singleton)` | 0 | 0 |
| TeamsUpgradePolicy | 11 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsUser | 194 | `TeamName | User` (composite) | 0 | 0 |
| TeamsUserCallingSettings | 34 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsVdiPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsVoiceRoute | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsVoiceRoutingPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
| TeamsWorkloadPolicy | 1 | default (DisplayName, Name, Identity) | 0 | 0 |
