# Copy to pipeline.settings.psd1 (git-ignored) and fill in. Then run:
#   pwsh -NoProfile -File pipelines\scripts\New-PipelineYaml.ps1
# The ready-to-paste YAML is written to pipelines\dist\. None of these values are secrets (no certificates or passwords):
# the certificates stay in Key Vault, only their secret names are listed here.
@{
    # Required
    Pool                       = 'Windows 2022 - General - Dev'      # agent pool: Windows, pwsh 7.6+, local admin
    ServiceConnection          = 'my-azure-service-connection'       # ADO service connection with Key Vault secret read access

    DevTenantDomain            = 'contoso-dev.onmicrosoft.com'
    DevOrganizationName        = 'contoso-dev.onmicrosoft.com'       # Exchange organization name (usually the onmicrosoft.com domain)
    DevKeyVault                = 'dev-kv-m365'
    DevReaderCertSecret        = 'dev-reader-cert'                   # Key Vault secret holding the Reader certificate as base64 PFX
    DevReaderAppId             = '00000000-0000-0000-0000-000000000000'
    DevWriterCertSecret        = 'dev-writer-cert'
    DevWriterAppId             = '00000000-0000-0000-0000-000000000000'
    DevWriterThumbprint        = '0000000000000000000000000000000000000000'

    PreProdTenantDomain        = 'contoso-preprod.onmicrosoft.com'
    PreProdKeyVault            = 'preprod-kv-m365'
    PreProdReaderCertSecret    = 'preprod-reader-cert'
    PreProdReaderAppId         = '00000000-0000-0000-0000-000000000000'

    # Optional (these are the defaults). The pipeline names must match the names you give the pipelines in Azure DevOps.
    DevEnvironment             = 'm365-dev'                          # ADO environment with an approval check
    ExportPreProdPipeline      = 'M365DSC - Export PreProd tenant'
    ExportDevPipeline          = 'M365DSC - Export Dev tenant'
    ComparePipeline            = 'M365DSC - Compare PreProd to Dev and build MOFs'
}
