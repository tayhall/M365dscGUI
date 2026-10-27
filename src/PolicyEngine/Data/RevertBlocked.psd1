@{
    # Resource types a Revert (create, update or remove through the Local Configuration Manager) is refused for, with the reason. The type is still
    # exported, checked and compared, and Promote and Exclude still work: only applying it to a tenant is blocked, and the GUI says why instead of
    # letting the apply fail. Remove a rule when the cause is fixed. Pattern is a regular expression on the resource type name.
    Rules = @(
        @{
            Pattern = '^SC'
            Reason  = 'Security and Compliance resources fail with a null reference inside Connect-ExchangeOnline when the Local Configuration Manager invokes them, although the same connection works everywhere else (reported to Microsoft365DSC as issue 7563). They can be checked but not reverted until that is fixed.'
            Issue   = 'https://github.com/Microsoft365DSC/Microsoft365DSC/issues/7563'
        }
    )
}
