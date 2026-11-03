# Copy to pipeline.settings.psd1 (git-ignored) and fill in. Then run:
#   pwsh -NoProfile -File pipelines\scripts\New-PipelineYaml.ps1
# Only what Azure DevOps must know before any script runs is here: the agent pool, the service connections, the environment and the
# pipeline names. The tenant identifiers (domain, Key Vault, short name, app ids) are in pipelines\config\Dev.psd1 and PreProd.psd1,
# which the pipelines read at run time. Every value that still says CHANGE-ME is refused by the script.
@{
    # Required
    Pool                     = 'CHANGE-ME agent pool'              # Windows, pwsh 7.6+, local admin
    # One service connection per tenant, each able to read the secrets in that tenant's Key Vault.
    DevServiceConnection     = 'CHANGE-ME dev service connection'      # Export Dev, Compare (Dev's certificate thumbprint) and Apply
    PreProdServiceConnection = 'CHANGE-ME preprod service connection'  # Export PreProd

    # Optional (these are the defaults). The pipeline names must match the names you give the pipelines in Azure DevOps.
    RepoFolder            = 'M365dscGUI'                    # folder of this project inside the ADO repo ('.' if it is at the repo root)
    DevEnvironment        = 'm365-dev'                      # ADO environment with an approval check
    ExportPreProdPipeline = 'M365DSC - Export PreProd tenant'
    ExportDevPipeline     = 'M365DSC - Export Dev tenant'
    ComparePipeline       = 'M365DSC - Compare PreProd to Dev and build MOFs'
}
