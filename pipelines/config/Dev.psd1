# Identifiers for the Dev tenant, read by the pipelines at run time (scripts\Get-PipelineConfig.ps1). Never put a secret here:
# certificates stay in Key Vault, and the thumbprint is taken from the certificate. Values that say CHANGE-ME are refused.
@{
    TenantDomain     = 'CHANGE-ME-dev.onmicrosoft.com'
    OrganizationName = 'CHANGE-ME-dev.onmicrosoft.com'   # Exchange organization name (usually the onmicrosoft.com domain)
    KeyVault         = 'CHANGE-ME'                       # Key Vault holding <ShortName>-Cert-Reader and <ShortName>-Cert-Writer (base64 PFX)
    ShortName        = 'CHANGE-ME'
    ReaderAppId      = 'CHANGE-ME'                       # application (client) id, a GUID
    WriterAppId      = 'CHANGE-ME'
}
