@{
    # Single source for pinned dependency versions. Read by the module (Get-PEPinnedVersion) and directly, as a plain
    # data file, by tools\Export-M365DscTenant.ps1. Always import these modules by explicit version: an older
    # Microsoft365DSC 1.x is installed system-wide.
    Microsoft365DSC              = '2.26.1021.1'
    MicrosoftGraphAuthentication = '2.41.1'
}