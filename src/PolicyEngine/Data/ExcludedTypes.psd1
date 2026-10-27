@{
    # Resource types (or, with a RecordRule, records of a type) the engine deliberately does not compare
    # (Compare-PEState, Get-PEStatus). An entry is a reason string (the whole type is excluded) or
    # @{ Reason = '...'; RecordRule = '<rule>' }: a rule implemented in Private\Compare.ps1 (Test-PERecordKeptByRule)
    # that keeps some records compared; only KeepCustomRoleEntries exists. Records of these types
    # are kept in exports, states and blueprints; the exclusion is applied only when comparing, so lifting an exclusion
    # needs no new blueprint. A compare ignores their records on both sides and reports one finding of Kind 'Excluded'
    # per excluded type that has records on either side (or is in either NotChecked list: Excluded wins over
    # NotChecked/NotAvailable), with the reason below as its Hint. Get-PEStatus leaves their records out of
    # Total/Aligned/Drifted and counts the types under 'Excluded (types)'. Compare-PEState -IncludeTypes compares
    # chosen types anyway for one call. Excluded findings are never rectified or approved into a blueprint.
    # See docs\key-coverage.md, section 'Excluded types and nested ignores'.
    #
    # The design (docs\superpowers\specs\2026-10-21-drift-policy-engine-design.md) puts users, mailboxes and anything
    # bound to a specific user out of scope; the per-mailbox and per-user types are excluded for that reason. Types that
    # grant administrative roles to users (role assignments and eligibilities, role groups, group policy assignments)
    # are NOT excluded, so that privilege changes stay visible (docs\key-coverage.md, 'Not excluded on purpose').
    # Tenant-wide Exchange policy types (mailbox plans, OWA/ActiveSync/mobile policies, role groups, role assignments,
    # transport and protection policies, distribution groups, ...) are compared as usual.
    Types = @{
        # Record-level: entries of custom roles stay compared (see RecordRule below).
        EXOManagementRoleEntry            = @{
            Reason     = 'Entries of built-in management roles are not compared: they are Microsoft-defined role definitions, not tenant policy, and the export repeats them unstably (duplicate records per Identity that change run to run: 996 to 1,996 Ambiguous plus Missing/TargetOnly noise in the acceptance run). Entries of custom roles (an EXOManagementRole with a Parent in the same state) are compared as usual.'
            RecordRule = 'KeepCustomRoleEntries'
        }
        EXOMailboxSettings                = 'Out of scope (mailboxes): settings of one mailbox (time zone, locale, ...). Its Identity is also exported as the user name in one run and as the mailbox GUID in another, which gave a false PossibleRename pair in the acceptance run.'
        EXOCASMailboxSettings             = 'Out of scope (mailboxes): client access settings (OWA, ActiveSync, POP, IMAP, MAPI) of one mailbox.'
        EXOCalendarProcessing             = 'Out of scope (mailboxes): calendar processing of one (resource) mailbox.'
        EXOMailboxAuditBypassAssociation  = 'Out of scope (users): mailbox audit bypass setting of one user or computer account; the export has one record per account.'
        EXOMailboxAutoReplyConfiguration  = 'Out of scope (mailboxes): automatic replies of one mailbox.'
        EXOMailboxCalendarConfiguration   = 'Out of scope (mailboxes): calendar settings of one mailbox.'
        EXOMailboxCalendarFolder          = 'Out of scope (mailboxes): publishing settings of one mailbox calendar folder.'
        EXOMailboxFolderPermission        = 'Out of scope (mailboxes): permissions on a folder of one mailbox.'
        EXOMailboxIRMAccess               = 'Out of scope (mailboxes and users): IRM access of one user to one mailbox.'
        EXOMailboxPermission              = 'Out of scope (mailboxes and users): permissions of one user on one mailbox.'
        EXORecipientPermission            = 'Out of scope (mailboxes and users): Send As permission of one trustee on one recipient.'
        EXOSharedMailbox                  = 'Out of scope (mailboxes): a shared mailbox is a mailbox.'
        EXOPlace                          = 'Out of scope (mailboxes): metadata of one room or workspace, which is a resource mailbox.'
        EXOFocusedInbox                   = 'Out of scope (mailboxes): Focused Inbox setting of one mailbox.'
        EXOSweepRule                      = 'Out of scope (mailboxes): a Sweep rule inside one mailbox.'
        EXOAuthenticationPolicyAssignment = 'Out of scope (users): assignment of an authentication policy to one user (the policies themselves, EXOAuthenticationPolicy, are compared).'
        AADUser                           = 'Out of scope (users): one user account.'
        AADAuthenticationRequirement      = 'Out of scope (users): per-user MFA requirement of one user.'
        TeamsUser                         = 'Out of scope (users): membership of one user in one team.'
        TeamsUserCallingSettings          = 'Out of scope (users): calling settings (forwarding, delegation) of one user.'
        TeamsOnlineVoicemailUserSettings  = 'Out of scope (users): voicemail settings of one user.'
        TeamsOnlineVoiceUser              = 'Out of scope (users): phone number and location assignment of one user.'
        TeamsUserPolicyAssignment         = 'Out of scope (users): Teams policies assigned directly to one user (group policy assignments, TeamsGroupPolicyAssignment, are compared).'
    }
}
