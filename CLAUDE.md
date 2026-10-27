# M365dscGUI

Exploring a policy engine for Microsoft 365 tenants, built on Microsoft365DSC.

## References

- `Microsoft365DSC/` — local clone of https://github.com/Microsoft365DSC/Microsoft365DSC (source of truth for resource schemas and implementation). Git-ignored here: clone it separately into this folder.
- https://microsoft365dsc.com/ — official Microsoft365DSC documentation site (resource docs, concepts, guides). Fetch it when you need documented behavior rather than source code.

## Architecture principles

- **Be a thin wrapper over Microsoft365DSC.** The project is a small policy layer (blueprints, scopes, tenants, checks, a GUI) on top of DSC, not a second implementation of it. Where DSC already has a command or script for something (export, `Get-M365DSCCompiledPermissionList`, `Update-M365DSCAzureAdApplication`, `New-M365DSCDeltaReport`, applying with `Invoke-DscResource`, the resource schemas and keys), call it and wrap it thinly. Do not copy its logic, its resource lists or its per-resource knowledge into this repo.
- **Why:** DSC and the Graph change constantly. Every DSC command we re-implement is code that can drift from DSC's behaviour and break on a new release, and every DSC resource we special-case is maintenance. A small project that calls DSC's own commands keeps working when the module is updated.
- **When DSC's tools fall short, stop and discuss** before writing our own replacement: say what the DSC command does and where it is limited, and propose options (for example a thin bootstrap step, a workaround, or accepting the limit). Prefer the smallest addition that lets DSC's command do the work. Record any deliberate gap in `docs/handover.md`.
- Derive from DSC at run time instead of copying: resource names and keys come from the pinned module (`ResourcePermissions.json`, `SchemaDefinition.json`), and the module version is pinned and guarded (`Data\Versions.psd1`, `Set-PEBlueprintModule`).
- Our own code is for what DSC does not do: blueprints and their versions, scopes and schedules, multi-tenant comparison, decisions and noise rules, the GUI and its worker, and the safety rules around applying changes.

## Layout

See `docs/overview.md` for the full folder map and a summary of the tools.

- `tools/` — PowerShell setup and command-line scripts (for example `New-PETenantApps.ps1`, which signs in with a device code and creates the Reader/Writer app registrations of a tenant, and `Export-M365DscTenant.ps1`).
- Secrets and certificates live outside the repo in `~\.m365dsc-policy\`.
