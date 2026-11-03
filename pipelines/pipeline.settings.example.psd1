# Copy to pipeline.settings.psd1 (git-ignored) and fill in. Then run:
#   pwsh -NoProfile -File pipelines\scripts\New-PipelineYaml.ps1
# Nothing sensitive goes here and no app id or thumbprint either: those are read from Key Vault when the pipeline runs. This file
# holds only names (of the pool, the service connection, the Key Vaults and the secrets in them). Every value that still says
# CHANGE-ME is refused by the script.
@{
    # Required
    Pool                       = 'CHANGE-ME agent pool'              # Windows, pwsh 7.6+, local admin
    ServiceConnection          = 'CHANGE-ME service connection'      # ADO service connection that can read secrets in the Key Vaults below

    DevTenantDomain            = 'CHANGE-ME-dev.onmicrosoft.com'
    DevOrganizationName        = 'CHANGE-ME-dev.onmicrosoft.com'     # Exchange organization name (usually the onmicrosoft.com domain)
    DevKeyVault                = 'CHANGE-ME-dev-keyvault'
    DevReaderCertSecret        = 'CHANGE-ME'                         # secret holding the Reader certificate as a base64 PFX
    DevReaderAppIdSecret       = 'CHANGE-ME'                         # secret holding the Reader application (client) id
    DevWriterCertSecret        = 'CHANGE-ME'                         # secret holding the Writer certificate as a base64 PFX
    DevWriterAppIdSecret       = 'CHANGE-ME'
    DevWriterThumbprintSecret  = 'CHANGE-ME'                         # secret holding the Writer certificate thumbprint

    PreProdTenantDomain        = 'CHANGE-ME-preprod.onmicrosoft.com'
    PreProdKeyVault            = 'CHANGE-ME-preprod-keyvault'
    PreProdReaderCertSecret    = 'CHANGE-ME'
    PreProdReaderAppIdSecret   = 'CHANGE-ME'

    # Optional (these are the defaults). The pipeline names must match the names you give the pipelines in Azure DevOps.
    DevEnvironment             = 'm365-dev'                          # ADO environment with an approval check
    ExportPreProdPipeline      = 'M365DSC - Export PreProd tenant'
    ExportDevPipeline          = 'M365DSC - Export Dev tenant'
    ComparePipeline            = 'M365DSC - Compare PreProd to Dev and build MOFs'
}
