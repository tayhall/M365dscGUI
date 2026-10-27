# Handoff: web GUI (Pode)

Notes for the developer building the web layer over the `PolicyEngine` module.

## Read first

- GUI spec and scope: `docs/superpowers/specs/2026-10-21-pode-gui-design.md`. This is the brief for the GUI work.
- Engine design: `docs/superpowers/specs/2026-10-21-drift-policy-engine-design.md`.
- Engine plan: `docs/superpowers/plans/2026-10-21-drift-policy-engine.md` (the data shapes come from its "Shared types").

The GUI is built against mock data and is not connected to the engine. It reads view-model JSON files and writes
only action requests (see the GUI spec, "Data the GUI reads"). Phase 1 is in `gui/`; start with `gui/README.md`.

## Secrets and data

- Nothing in the repo holds secrets. App details live in `~\.m365dsc-policy\` (for example
  `M365DSC-Policy-Reader.json`), but the private keys are in the Windows certificate store
  (`Cert:\CurrentUser\My`, subject `CN=M365DSC-Policy-Reader` / `-Writer`). Copying the folder alone does not
  authenticate. Either export and import the certificate as well, or create your own app registrations with
  `tools/New-PETenantApps.ps1`.
- `data/` is git-ignored, so you start with no exports, blueprints or decisions. GUI work needs no tenant access:
  it runs on the fake data set in `gui/mock-data/`.
