@{
    # Properties that point at another resource of the blueprint, by the other resource's Key (DSC exports most of them as the
    # other object's display name, which is what lets them work in another tenant). Used to
    # - put the blocks of a Revert configuration in dependency order (parents first when creating or changing, children first when removing),
    # - turn a GUID reference into the parent's Key when DSC exports the id instead (ResolveGuid, see Read-PEExport).
    # DSC ships relation templates (Modules\M365DSCRelationTemplates.json of the module: which property of a resource names which other
    # resource, for export naming) but they are not an apply order: they are broad and cyclic (a group "depends on" users, roles and
    # service principals; 169 relations), so ordering from them put types in the wrong depth (checked 2026-10-24). This list is what
    # a Revert needs, so it is deliberately small:
    # add a type here when a Revert of it needs its parent to exist first. A parent that is not part of the Revert is not added: run the
    # Revert again after the re-check (DSC reports the existing items as already correct). Docs: docs\handover.md, 'Revert of dependent items'.
    #
    # Type = @( @{ Property = '<name or dotted path>'; ParentType = '<type>'; ResolveGuid = $true (optional) } )
    References = @{
        # A policy names the groups it includes and excludes; they have to exist first (DSC: Couldn't find group '<name>', couldn't add to policy).
        AADConditionalAccessPolicy = @(
            @{ Property = 'IncludeGroups'; ParentType = 'AADGroup' }
            @{ Property = 'ExcludeGroups'; ParentType = 'AADGroup' }
        )
        AADEntitlementManagementAccessPackageCatalogResource = @(
            # DSC's export writes the catalog's GUID here (the other entitlement resources write names); ResolveGuid swaps it for the
            # catalog's Key using the Id of the catalog in the same export.
            @{ Property = 'CatalogId'; ParentType = 'AADEntitlementManagementAccessPackageCatalog'; ResolveGuid = $true }
            @{ Property = 'OriginId'; ParentType = 'AADGroup' }
        )
        AADEntitlementManagementAccessPackage = @(
            @{ Property = 'CatalogId'; ParentType = 'AADEntitlementManagementAccessPackageCatalog' }
            @{ Property = 'AccessPackageResourceRoleScopes.AccessPackageResourceOriginId'; ParentType = 'AADEntitlementManagementAccessPackageCatalogResource' }
        )
        AADEntitlementManagementAccessPackageAssignmentPolicy = @(
            @{ Property = 'AccessPackageId'; ParentType = 'AADEntitlementManagementAccessPackage' }
        )
    }
}
