# Copy to pipeline.settings.psd1 (git-ignored) and fill in. Then run:
#   pwsh -NoProfile -File pipelines\scripts\New-PipelineYaml.ps1
# Nothing sensitive goes here. Certificates are read from Key Vault when a pipeline runs, and the thumbprint is taken from the
# certificate itself, so no thumbprint is stored. The application (client) ids are identifiers, not secrets. Every value that still says
# CHANGE-ME is refused by the script.
@{
    # Required
    Pool                       = 'CHANGE-ME agent pool'              # Windows, pwsh 7.6+, local admin
    ServiceConnection          = 'CHANGE-ME service connection'      # ADO service connection that can read secrets in the Key Vaults below

    DevTenantDomain            = 'CHANGE-ME-dev.onmicrosoft.com'
    DevOrganizationName        = 'CHANGE-ME-dev.onmicrosoft.com'     # Exchange organization name (usually the onmicrosoft.com domain)
    DevKeyVault                = 'CHANGE-ME-dev-keyvault'
    DevShortName               = 'CHANGE-ME'                         # secrets read: <ShortName>-Cert-Reader and <ShortName>-Cert-Writer (base64 PFX)
    DevReaderAppId             = 'CHANGE-ME'                         # application (client) id GUID of the Reader app registration
    DevWriterAppId             = 'CHANGE-ME'                         # application (client) id GUID of the Writer app registration

    PreProdTenantDomain        = 'CHANGE-ME-preprod.onmicrosoft.com'
    PreProdKeyVault            = 'CHANGE-ME-preprod-keyvault'
    PreProdShortName           = 'CHANGE-ME'                         # secret read: <ShortName>-Cert-Reader
    PreProdReaderAppId         = 'CHANGE-ME'

    # Optional (these are the defaults). The pipeline names must match the names you give the pipelines in Azure DevOps.
    DevEnvironment             = 'm365-dev'                          # ADO environment with an approval check
    ExportPreProdPipeline      = 'M365DSC - Export PreProd tenant'
    ExportDevPipeline          = 'M365DSC - Export Dev tenant'
    ComparePipeline            = 'M365DSC - Compare PreProd to Dev and build MOFs'
}
