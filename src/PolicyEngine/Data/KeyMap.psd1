@{
    # Identity candidates tried in order; the first non-empty scalar value becomes the record Key.
    Default   = @('DisplayName', 'Name', 'Identity')

    # One-per-tenant types whose own identity is the connected tenant's GUID (it never matches across tenants): they are
    # treated like IsSingleInstance resources and always get the key '(singleton)'.
    Singletons = @(
        'AADOrganizationCertificateBasedAuthConfiguration'
        'AADCrossTenantAccessPolicy'
        'EXOExternalInOutlook'
    )

    # This list is intentionally partial. An entry with several properties is a composite key: the parts are joined
    # with ' | ' in the order given and any empty part makes the record Unkeyed. Singleton resources (IsSingleInstance
    # only) get '(singleton)'.
    # Each entry replaces the default order for a type whose DSC [Key] is not DisplayName/Name/Identity.
    # Evidence: [DscProperty(Key)] in Microsoft365DSC\Modules\Microsoft365DSC\DscResources\MSFT_<Type>\MSFT_<Type>.psm1.
    # GUID keys (e.g. AADServicePrincipal AppId) are deliberately not overridden: DisplayName is more readable.
    Overrides = @{
        AADUser                                           = @('UserPrincipalName')
        # Security and Compliance: DSC declares Name as the [Key] of these (MSFT_SC*.psm1: 'the unique name'); DisplayName is not unique (sub-labels of
        # different parents share one) or is empty. Name is the readable internal name for DLP, role groups and custom labels, and a tenant-generated
        # id for portal-created labels (so those do not match across tenants).
        SCDLPCompliancePolicy                             = @('Name')
        SCDLPComplianceRule                               = @('Name')
        SCInsiderRiskEntityList                           = @('Name')
        SCRoleGroup                                       = @('Name')
        SCSensitivityLabel                                = @('Name')
        # Policies are called 'Initial Policy' in every access package (the system's default name): the package is part of the key.
        AADEntitlementManagementAccessPackageAssignmentPolicy = @('AccessPackageId', 'DisplayName')
        AADAttributeSet                                   = @('Id')
        AADDomain                                         = @('Id')
        AADDomainFederation                               = @('DomainId')
        # Tenant ID: no readable alternative exists for this type.
        AADCrossTenantAccessPolicyConfigurationPartner    = @('PartnerTenantId')
        # Id is a readable policy name here (for example MicrosoftAuthenticator), not a GUID.
        AADAuthenticationMethodPolicyAuthenticator        = @('Id')
        AADAuthenticationMethodPolicyEmail                = @('Id')
        AADAuthenticationMethodPolicyFido2                = @('Id')
        AADAuthenticationMethodPolicyHardware             = @('Id')
        AADAuthenticationMethodPolicyQRCodeImage          = @('Id')
        AADAuthenticationMethodPolicySms                  = @('Id')
        AADAuthenticationMethodPolicySoftware             = @('Id')
        AADAuthenticationMethodPolicyTemporary            = @('Id')
        AADAuthenticationMethodPolicyVoice                = @('Id')
        AADAuthenticationMethodPolicyX509                 = @('Id')
        AADAuthenticationRequirement                      = @('UserPrincipalName')
        AADRoleAssignmentScheduleRequest                  = @('Principal', 'RoleDefinition', 'DirectoryScopeId')
        AADRoleManagementPolicyRule                       = @('RoleDisplayName', 'Id')
        EXOAuthenticationPolicyAssignment                 = @('UserName')
        EXODnssecForVerifiedDomain                        = @('DomainName')
        EXOMailboxPermission                              = @('Identity', 'User', 'InheritanceType')
        EXOManagementRoleEntry                            = @('Identity')
        EXORecipientPermission                            = @('Identity', 'Trustee')
        EXOSmtpDaneInbound                                = @('DomainName')
        EXOTenantAllowBlockListSpoofItems                 = @('SpoofedUser')
        IntuneCustomizationBrandingProfile                = @('ProfileName')
        # Id is a fixed readable name (androidManagedStoreAccountEnterpriseSettings), not a GUID.
        IntuneDeviceManagementEnrollmentAndroidGooglePlay = @('Id')
        SPOSite                                           = @('Url')
        SPOHubSite                                        = @('Url')
        SPOSiteDesign                                     = @('Title')
        SPOSiteScript                                     = @('Title')
        TeamsChannel                                      = @('TeamName', 'DisplayName')
        TeamsChannelTab                                   = @('TeamName', 'ChannelName', 'DisplayName')
        TeamsPstnUsage                                    = @('Usage')
        TeamsUser                                         = @('TeamName', 'User')
    }
}
