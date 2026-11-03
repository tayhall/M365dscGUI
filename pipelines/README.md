# Pipelines (Azure DevOps)

Headless: no GUI, no worker. They call the PolicyEngine module and Microsoft365DSC's own commands.

| Pipeline | Does |
| --- | --- |
| `Export-PreProd.yaml`, `Export-Dev.yaml` | Imports the tenant's Reader certificate from Key Vault, runs `tools\Export-M365DscTenant.ps1`, publishes `PreProdExport` / `DevExport`. |
| `Compare-PreProd-to-Dev.yaml` | Takes the latest of both exports, runs `tools\Invoke-PEPipelineCompare.ps1`, publishes `DriftReport` (`drift.csv`, `drift.json`, `Changes.ps1`, `Removals.ps1`, `Manual.json`, `MOF\Changes`, `MOF\Removals`). |
| `Apply-Dev.yaml` | Applies the MOFs to Dev through the LCM (`tools\Invoke-PELcm.ps1`). Default mode is `Test`; Removals only when asked; gated by the `m365-dev` environment approval. |

**MOF layout** (`mofLayout` on the compare pipeline, `Invoke-PEPipelineCompare.ps1 -MofLayout`):
- `Combined` (default): `MOF\Changes` and `MOF\Removals`. Run Apply-Dev with `workloads` empty.
- `PerWorkload`: `<Prefix>\MOF\Changes` and `<Prefix>\MOF\Removals` for each workload the PreProd export has records of. Run Apply-Dev with
  `workloads` such as `AAD,Intune,EXO,Teams`; they are applied in that order (all Changes first, then, if ticked, all Removals).
  Each workload is its own run of the same comparison with only that workload's PreProd records as the expected state. `drift.*` and
  `Manual.json` always come from the full comparison.

Shared pieces: `templates\install-dependencies.yml`, `templates\export-tenant.yml`, `scripts\Install-PipelineDependencies.ps1`
(pinned Microsoft365DSC, its dependency manifest and Microsoft.Graph.Authentication, saved to
`C:\Program Files\WindowsPowerShell\Modules`, added to the machine `PSModulePath`) and `scripts\Connect-PipelineTenant.ps1`
(certificate import plus the app details file the existing tools read).

## Making the YAML ready for Azure DevOps (once, then whenever the YAML here changes)
The YAML holds `__TOKEN__` placeholders, never real values.
1. Copy `pipelines\pipeline.settings.example.psd1` to `pipelines\pipeline.settings.psd1` (git-ignored) and fill in the pool, service
   connection, tenant domains, Key Vault names and the **names of the Key Vault secrets** that hold the certificates (base64 PFX), the
   app ids and the Dev Writer thumbprint. The app ids and thumbprints themselves are read from Key Vault when a pipeline runs; none
   of them, and nothing sensitive, goes in the file.
2. Run `pwsh -NoProfile -File pipelines\scripts\New-PipelineYaml.ps1`. It writes the finished files to `pipelines\dist\` (git-ignored) and
   stops on a missing value, an example value left in, or a token it does not know.
3. Copy the contents of `dist\` over the `pipelines\` folder of your ADO repo (`pipelines\scripts\` and `tools\` are used as they are).
   Create the four pipelines from the YAML files, named as in the settings file (the `resources:` blocks look them up by name), and create
   the `m365-dev` environment with an approval check.

## Agent needs
Windows, PowerShell 7.6+, local administrator (Program Files and the machine certificate store), internet access to the PowerShell Gallery.

## How the compare works
The PreProd export becomes a blueprint and the Dev export an uploaded snapshot, in a throwaway data folder, so the existing
`Compare-PEState` and `New-PEOfflineConfig` do the comparison and generation. Rules that come with that: Missing and Changed items
are written to `Changes`, only target-only items of a type PreProd has records of go to `Removals`, anything DSC cannot create or
remove goes to `Manual.json`, tenant-bound ids and each tenant's own domain name are not reported as drift.
