# Identifiers for the PreProd tenant, read by the pipelines at run time (scripts\Get-PipelineConfig.ps1). Never put a secret here:
# certificates stay in Key Vault. Values that say CHANGE-ME are refused. PreProd is only ever read, so there is no Writer app.
@{
    TenantDomain = 'CHANGE-ME-preprod.onmicrosoft.com'
    KeyVault     = 'CHANGE-ME'                           # Key Vault holding <ShortName>-Cert-Reader (base64 PFX)
    ShortName    = 'CHANGE-ME'
    ReaderAppId  = 'CHANGE-ME'                           # application (client) id, a GUID
}
