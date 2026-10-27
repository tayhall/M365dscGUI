@{
    # Properties removed by ConvertTo-PENormalizedRecord (names match case-insensitively). See docs\key-coverage.md,
    # section 'Excluded types and nested ignores'.
    #
    # An entry is one of:
    # - a top-level property name ('Members');
    # - a dotted path into a nested value ('Settings.member');
    # - a conditional entry @{ Path = '<name or dotted path>'; When = 'PastExport' }: the value is removed only when it is
    #   empty or a date at or before the export time of the state the record comes from (Microsoft365DSC's
    #   IgnoreWhenPast). A future date, or one that cannot be parsed, is kept and compared. Without a known export time
    #   (no Meta.ExportedAt) a conditional entry is not applied.
    # A path is followed through nested hashtables / ordered dictionaries (the DSC parser's CIM instances),
    # PSCustomObjects (the same data read back from JSON) and real CimInstances; an array on the way is walked element by
    # element (the same path applied to each element, so 'Assignments.groupId' would remove groupId from every
    # assignment). Only the last member is removed: its parent object stays with its remaining members, and a parent
    # OBJECT that the removal leaves empty (no members, or only the parser's CIMInstance class name) is dropped from its
    # parent object. Array elements are never dropped, even when emptied, so the length of an array still compares.
    # A path that does not exist, or that runs into a scalar value, changes nothing.
    # Paths are also applied when Compare-PEState compares a matched pair (conditional ones with each state's own
    # Meta.ExportedAt), so stored blueprints taken before an entry was added need no new version.
    # ConvertTo-PEDscConfig's safety check refuses ignored TOP-LEVEL names in a generated configuration; nested paths are
    # not checked there (normalisation has already removed them from the records it renders).

    # Removed from every record: connection/auth settings, secrets, and tenant-specific ids that are not policy.
    Global = @(
        'Id', 'TenantId', 'ApplicationId', 'CertificateThumbprint', 'CertificatePath', 'CertificatePassword',
        'Credential', 'ApplicationSecret', 'ManagedIdentity', 'AccessTokens', 'Password'
    )

    # Removed only for the named resource type.
    ByType = @{
        # Membership and user lists are data about users, not configuration (users are out of scope).
        AADGroup                         = @('Members', 'Owners', 'MemberOf')
        # Members: users, groups and devices of the unit (MSFT_MicrosoftGraphMember[]).
        AADAdministrativeUnit            = @('Members')
        # AppRoleAssignedTo: users and groups assigned to the app (MSFT_AADServicePrincipalRoleAssignment[]);
        # Owners: UPNs or object ids of the owners.
        AADServicePrincipal              = @('AppRoleAssignedTo', 'Owners')
        # Owners: UPNs or object ids of the app's owners.
        AADApplication                   = @('Owners')
        # Members: the group's member list (user identities).
        EXODistributionGroup             = @('Members')
        # Members of an Exchange role group and of a Security and Compliance role group: users, not configuration. The roles
        # of the group (Roles) are still compared, as a set.
        EXORoleGroup                     = @('Members')
        SCRoleGroupMember                = @('Members')
        # Owner: the team's owners (UPNs).
        TeamsTeam                        = @('Owner')
        # A permanent assignment exports the time of the export as its start time, so it changed on every export
        # (acceptance run, docs\acceptance-v1.md). Only a start at or before the export time is ignored, as the DSC
        # resource itself does (IgnoreWhenPast); a future start is a real setting and stays compared.
        AADRoleAssignmentScheduleRequest = @(@{ Path = 'ScheduleInfo.startDateTime'; When = 'PastExport' })
    }

    # Properties that belong to one tenant: ids Microsoft generates per tenant and values that name the tenant's own objects.
    # Unlike the lists above they are NOT removed from stored states or blueprints, and a check of a tenant against a
    # blueprint taken from THAT SAME tenant compares them (a deleted and recreated app or team shows as drift). They are left
    # out only when the target is a different tenant from the blueprint's (Meta.TenantId of the two states differ), because
    # there they can never match: a dev tenant checked against the production blueprint. The same paths are left out of the
    # records rendered into a Revert configuration for a different tenant, so the source tenant's ids are never written to it.
    # Same entry forms as above (plain names are matched at the top level of the record, dotted paths into nested values).
    #
    # Deliberately NOT here: pre-authorised applications and Intune assignments. A difference there is real in every tenant and
    # is shown as drift. (Two things used to be on this list and are not any more: an app's certificate keys are tenant-bound
    # below, and the member lists of role groups are users, ignored in every tenant, see ByType above.)
    TenantBound = @{
        # The id of the group an assignment targets: DSC applies an assignment by groupDisplayName when the groupId is not found in the tenant, and the
        # record carries both, so the name is what is compared and sent.
        Global = @('Assignments.groupId')
        ByType = @{
            # The Id of this type is the tenant's own GUID (the Id is kept for the Revert, see OwnIds in IdentityReferences.psd1).
            IntuneDeviceEnrollmentPlatformRestriction = @('Id')
            # ObjectID and ServicePrincipalNames (which hold the application's own id) are generated per tenant.
            AADServicePrincipal = @('ObjectID', 'ServicePrincipalNames')
            # AppId, ObjectId and the ids of the app's permission scopes are generated per tenant; so are its certificate keys
            # (made in each tenant, so another tenant can never match them). Against the tenant the blueprint came from a
            # changed or added key is still drift.
            AADApplication      = @('AppId', 'ObjectId', 'Api.Oauth2PermissionScopes.id', 'KeyCredentials')
            # GroupID: the id of the team's Microsoft 365 group; TeamId likewise; Configuration holds the tab's own links.
            TeamsTeam           = @('GroupID')
            TeamsChannel        = @('GroupID')
            TeamsChannelTab     = @('TeamId', 'Configuration')
            # Addresses embed an id generated per group (SPO:SPO_<guid>@...).
            EXOGroupSettings    = @('EmailAddresses')
            # Where the group sits in the tenant's directory (the Exchange server it was created on).
            EXODistributionGroup = @('OrganizationalUnit')
            EXOMailContact      = @('OrganizationalUnit')
            # The licensing endpoint holds a GUID generated per tenant and the region the tenant lives in.
            EXOIRMConfiguration = @('LicensingLocation')
            # Identity carries a generated suffix; RetentionId is a GUID.
            EXOMailboxPlan      = @('Identity')
            EXOCASMailboxPlan   = @('Identity')
            EXORetentionPolicy  = @('RetentionId')
            # Set by the system when the resource is added to the catalog (who, when, and a link holding the group's id).
            AADEntitlementManagementAccessPackageCatalogResource = @('Url', 'AddedOn', 'AddedBy')
            # The ids of the role/scope pairs (<role>_<scope>) are generated when the package is created. Left in a Revert configuration
            # they stop DSC's own Test from ever reporting the package as in its desired state.
            AADEntitlementManagementAccessPackage = @('AccessPackageResourceRoleScopes.Id')
        }
    }
}
