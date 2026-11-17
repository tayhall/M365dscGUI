# Identifiers for the Prod tenant, read by the pipelines at run time (scripts\Get-PipelineConfig.ps1). Never put a secret here:
# certificates stay in Key Vault. Values that say CHANGE-ME are refused. Prod is only ever read, so there is no Writer app.
@{
    TenantDomain = 'CHANGE-ME-prod.onmicrosoft.com'
    KeyVault     = 'CHANGE-ME'                           # Key Vault holding <ShortName>-Cert-Reader (base64 PFX)
    ShortName    = 'CHANGE-ME'
    ReaderAppId  = 'CHANGE-ME'                           # application (client) id, a GUID
    # Optional: the Key Vault secret name of the certificate. Left out, it is <ShortName>-Cert-Reader.
    # ReaderCertSecret = 'prod-Cert-Reader'
}
