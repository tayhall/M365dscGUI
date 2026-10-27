# M365dscGUI

A policy engine and GUI for Microsoft 365 tenants, built as a thin layer on top of [Microsoft365DSC](https://github.com/Microsoft365DSC/Microsoft365DSC). It adds blueprints and their versions, scopes, multi-tenant comparison, decisions and noise rules, and a GUI; DSC does the exporting and applying.

See `docs/overview.md` for the folder map and a summary of the tools.

## Setup

Clone Microsoft365DSC into `Microsoft365DSC/` in this folder (it is git-ignored). Secrets and certificates live outside the repo in `~\.m365dsc-policy\`.

## Licence

MIT, see `LICENSE`.
