@{
    # Types whose own Id is the DSC [Key] and has to be supplied to create or update the object, but would not be in the blueprint (the blueprint
    # keeps names, and Id is removed from records because it is normally a tenant-generated GUID). For these the Id IS kept in the record. When a
    # Revert targets a tenant other than the one the blueprint came from, the Id is looked up there: DSC's own export of the type from the target
    # (Reader app) gives the Id of the object with the same key (name); when the object does not exist the blueprint's Id is sent as it is. Only
    # these types are looked up, once per Revert. Where DSC itself accepts a name beside the id (Intune assignments carry groupDisplayName, Teams
    # channels TeamName) nothing is looked up: the id is ignored across tenants (IgnoredProperties.psd1, TenantBound) and DSC resolves the name.
    OwnIds = @(
        'AADPermissionGrantPolicy'
        'IntuneDeviceEnrollmentPlatformRestriction'
    )

    # Properties holding user sets (@{ odataType = '#microsoft.graph.singleUser'; Id = '<user principal name>' }) that DSC exports as a
    # user principal name and is supposed to turn back into the user's object id when it applies them, by looking the user up in the
    # tenant. In Microsoft365DSC 2.26.1015.1 that lookup came back empty when a policy was created from a Revert (Mgx 'ArgumentException:
    # ObjectId', J-22, 2026-10-23) and the same configuration worked with the object id in place of the name. A Revert therefore looks the
    # user up itself (Reader app of the target tenant) and renders the object id. A deliberate deviation, agreed with the project owner;
    # docs\handover.md, 'Revert of dependent items'. Remove an entry when DSC no longer needs it.
    # Type = @( '<dotted path to a user set or a collection of them>' )
    UserSets = @{
        AADEntitlementManagementAccessPackageAssignmentPolicy = @(
            'RequestApprovalSettings.ApprovalStages.PrimaryApprovers'
            'RequestApprovalSettings.ApprovalStages.EscalationApprovers'
            'RequestorSettings.AllowedRequestors'
            'AccessReviewSettings.Reviewers'
        )
    }
}
