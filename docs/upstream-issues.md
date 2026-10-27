# Upstream (Microsoft365DSC) issues found while building the engine

Pinned module: Microsoft365DSC 2.26.1015.1. Filed means a public issue exists; candidates are findings with evidence that have not been filed (decide, then sanitise: no tenant names or ids).

## Filed

| Issue | Summary |
| --- | --- |
| [#7563](https://github.com/Microsoft365DSC/Microsoft365DSC/issues/7563) | `SC*` resources fail with "Object reference not set to an instance of an object" in `Connect-ExchangeOnline` when invoked through the LCM; the same connection works as SYSTEM, inside the `PowerShell.7` endpoint, in-process through DSC, and for `EXO*` resources through the LCM. The engine refuses to revert `SC*` types meanwhile (`Data\RevertBlocked.psd1`); remove that rule when this is fixed. |

## Candidates (not filed)

1. **`AADEntitlementManagementAccessPackageCatalogResource` export writes the catalog GUID in `CatalogId`**, where the package and policy resources write names. The engine swaps it for the name (`ResolveGuid`, `Data\References.psd1`).
2. **`AADEntitlementManagementAccessPackageAssignmentPolicy` does not resolve an approver given by user principal name when creating the policy**: Mgx `ArgumentException: ObjectId`; the same configuration works with the object id. The engine renders the id (`Data\IdentityReferences.psd1`, `UserSets`).
3. **`AADEntitlementManagementAccessPackage` Test can never pass after the package is created from a configuration**: it compares the generated id of each role/scope pair (`<roleId>_<scopeId>`).
4. **Dependency list incomplete**: the dependency manifest pins `Microsoft.Graph.Authentication` only, but `AAD*` resources call `Get-MgApplicationOwner` (`Microsoft.Graph.Applications`) and fail with "module could not be loaded" next to an older Graph module; installing `Microsoft.Graph.Applications` 2.41.1 for all users fixed 25 types.
5. **`EXOHostedOutboundSpamFilterPolicy` Test**: "A parameter cannot be found that matches parameter name 'Identity'" through the LCM.
6. **Settings that DSC's export lists as Present but `Get` reads as `Ensure = Absent`** (`AADPasswordRuleSettings`, `AADGroupsSettings`, `AADOrganizationCertificateBasedAuthConfiguration`, `EXOReportSubmissionPolicy`): their Test never passes until the setting is created.
7. **`IntuneCustomizationBrandingProfile` export omits the mandatory `DisplayName`** of the default profile (DSC itself warns about the missing mandatory property).
8. **`EXOGroupSettings` looks a group up by a display name that two groups share** and returns the other group.
9. **`Test-DscConfiguration -ReferenceConfiguration` is documented as returning True/False only**; here it returns per-resource lists (useful, but undocumented behaviour that the engine relies on for test-only runs).
10. **One export process cannot read every workload**: `Export-M365DSCConfiguration` runs components alphabetically in one process. An `AAD*`/`Intune*` (Graph) component before an `SC*` component makes the first SC connect fail ("Object reference not set to an instance of an object", `ExoPowershellSnapin.NewEXOModule.ProcessRecord()`); an `SC*` component before a `Teams*` one makes Teams fail ("the module could not be loaded"). Each works alone. Minimal repro: `-Components AADAccessReviewPolicy,SCRoleGroup` (fails), `-Components SCRoleGroup` (works). Possibly the same cause as #7563.
