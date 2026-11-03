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

## Configuration: two places
**1. Tenant config files, read at run time: `pipelines\config\Dev.psd1` and `PreProd.psd1`.** Fill in the tenant domain, Key Vault name,
the environment's short name and the Reader (and, for Dev, Writer) application (client) ids; Dev also has the Exchange organization name.
Commit them to your ADO repo: they hold identifiers only, never a secret. `scripts\Get-PipelineConfig.ps1` reads them as data, allows only
those keys, checks each value (GUID, domain, name) and refuses `CHANGE-ME`, so a typo or a pasted secret stops the run. Changing a value
needs no regenerating: edit the file and run the pipeline.
Certificates are read from Key Vault: the secret `<ShortName>-Cert-Reader` (and `<ShortName>-Cert-Writer` for Dev) holds the certificate as a
base64 PFX without a password, read with `Get-AzKeyVaultSecret`. The thumbprint is taken from the certificate itself and is not stored.

**2. Settings for the YAML itself (once, then whenever the YAML here changes).** Azure DevOps needs the agent pool, the service connection,
the environment and the pipeline names before any script runs, so those are tokens (`__POOL__` and so on) in the YAML.
1. Copy `pipelines\pipeline.settings.example.psd1` to `pipelines\pipeline.settings.psd1` (git-ignored) and fill in the pool and service connection.
2. Run `pwsh -NoProfile -File pipelines\scripts\New-PipelineYaml.ps1`. It writes the finished files to `pipelines\dist\` (git-ignored) and
   stops on a missing value, an example value left in, or a token it does not know. Old tenant keys in the settings file are ignored with a warning.
3. Copy the contents of `dist\` over the `pipelines\` folder of your ADO repo (`pipelines\config\`, `pipelines\scripts\` and `tools\` are used as
   they are). Create the four pipelines from the YAML files, named as in the settings file (the `resources:` blocks look them up by name), and create
   the `m365-dev` environment with an approval check.

## Agent needs
Windows, PowerShell 7.6+, local administrator (Program Files and the machine certificate store), internet access to the PowerShell Gallery.

## How the compare works
The PreProd export becomes a blueprint and the Dev export an uploaded snapshot, in a throwaway data folder, so the existing
`Compare-PEState` and `New-PEOfflineConfig` do the comparison and generation. Rules that come with that: Missing and Changed items
are written to `Changes`, only target-only items of a type PreProd has records of go to `Removals`, anything DSC cannot create or
remove goes to `Manual.json`, tenant-bound ids and each tenant's own domain name are not reported as drift.
