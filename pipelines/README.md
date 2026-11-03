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

**The YAML stays thin.** Each pipeline is: install modules, one script step, publish. The logic and the checks live in the scripts, not in the YAML:
- `scripts\Install-PipelineDependencies.ps1`: pinned Microsoft365DSC, its dependency manifest and Microsoft.Graph.Authentication, saved to
  `C:\Program Files\WindowsPowerShell\Modules` and added to the machine `PSModulePath`.
- `scripts\Invoke-PipelineExport.ps1`, `Invoke-PipelineCompare.ps1`, `Invoke-PipelineApply.ps1`: the three pipeline steps. They read the config file,
  call `Connect-PipelineTenant.ps1` (certificate from Key Vault; the thumbprint is taken from the certificate) and remove the certificate again in a
  `finally`; a last `condition: always()` step in each pipeline removes it again even if the agent process was killed (timeout, hard cancel).
- `scripts\Get-PipelineConfig.ps1`: reads and validates `config\<Environment>.psd1`.
- Apply logs which compare run (and which PreProd and Dev export runs) it is applying, so an approver can see what they are approving. It stops,
  instead of applying nothing, when `workloads` does not match the compare run's layout (Combined or PerWorkload, from the report's `summary.json`) or
  names a workload with no folder. It also refuses a report with no valid certificate thumbprint, and checks that the Writer certificate is the one the
  MOFs were compiled with. A run with no drift ends with "Nothing to apply". In Apply mode a resource still not in the desired state fails the step and
  Removals do not follow; in Test mode differences are only reported.
- When you queue Apply by hand, Azure DevOps lets you pick which compare run to use (Resources); the default is the latest.

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

## Where the project sits in the ADO repo
The project can live in a folder of a repo that holds other things (for example `M365dscGUI\`, with `pipelines\`, `src\`, `tools\` and the rest
beneath it). Nothing else in the repo is touched or read.
- **`RepoFolder`** in `pipeline.settings.psd1` (default `M365dscGUI`; use forward slashes for a deeper folder, `.` for the repo root) is put in front of
  every script path in the YAML: `$(Build.SourcesDirectory)/M365dscGUI/pipelines/scripts/...`. Change it and run `New-PipelineYaml.ps1` again if you
  use another folder name.
- **The scripts need no setting.** They find `src\`, `tools\` and `config\` relative to their own location, so they work from any folder.
- **Creating each pipeline in ADO:** choose the existing YAML file at `M365dscGUI/pipelines/<name>.yaml`. The pipeline's own YAML path is the only other
  place the folder name appears.
- **Copy the `.gitignore` as well** (it goes in `M365dscGUI\`, where it applies to that folder only): it keeps `pipelines\pipeline.settings.psd1`, `pipelines\dist\`
  and `data\` out of the repo. Do not commit the settings file or `dist\`; `dist\` is only what you paste into the repo.
- The checkout is the whole repo, so a large legacy repo is cloned each run; shallow fetching is available if that is slow.

## Agent needs
Windows, PowerShell 7.6+, local administrator (Program Files and the machine certificate store), internet access to the PowerShell Gallery.

## How the compare works
The PreProd export becomes a blueprint and the Dev export an uploaded snapshot, in a throwaway data folder, so the existing
`Compare-PEState` and `New-PEOfflineConfig` do the comparison and generation. Rules that come with that: Missing and Changed items
are written to `Changes`, only target-only items of a type PreProd has records of go to `Removals`, anything DSC cannot create or
remove goes to `Manual.json`, tenant-bound ids and each tenant's own domain name are not reported as drift.
