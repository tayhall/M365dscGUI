# Per-tenant property exclusion: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On a tenant's drift review, the owner can exclude one property for that tenant (for example `SCDLPCompliancePolicy.Priority` in `contoso`): it stops counting as drift, stays visible in the item detail marked excluded, and a Revert never changes it. Other tenants are unaffected.

**Architecture:** One new decision kind, `PropertyExcluded`, stored per tenant with a property name and an optional item key (empty key means every item of the type). `Compare-PEState` moves matching differences from `Differences` to a new finding field `ExcludedDifferences`; a finding with nothing left to enforce gets State `Unmanaged` (so counts and Revert refusal reuse the existing paths). The Revert plan keeps the tenant's value of an excluded property. The GUI shows excluded rows, offers Exclude and Bring back, and lists them on the Exclusions page. No ignore list changes: `Priority` stays drift by default.

**Tech Stack:** PowerShell 7.6, Pester 5 (offline), Pode GUI (`gui/`).

**Agreed in chat 2026-10-27 (this is the spec):** per-tenant, per-property; scope "this item" or "every item of this type in this tenant"; excluded property stays visible in the detail; if it was the only difference the item stops counting as drift; Revert keeps the tenant's current value; other tenants still show it as drift; Unexclude brings it back. Out of scope: suggestions, encryption-switch rule, domain mapping, any change to `IgnoredProperties.psd1`.

## Global Constraints

- PowerShell 7.6+, LF line endings, Allman braces, 4-space indent; Pester blocks keep the opening brace on the same line (`docs/handover.md`, Conventions).
- Thin wrapper over Microsoft365DSC: no DSC logic copied (`CLAUDE.md`). Nothing here reads a tenant.
- Decision kinds are a closed `ValidateSet`; the new kind is `PropertyExcluded`. Its `Tenant` is required (never global); `Property` is required; `Key` is optional; `Value` is unused.
- A property exclusion applies to top-level properties of a matched pair only (that is the level `Differences` has), matched case-insensitively.
- Tests offline: `pwsh -NoProfile -Command "Invoke-Pester -Path tests\<File>.Tests.ps1 -Output Detailed"`; whole suite `pwsh -NoProfile -File tools\Invoke-PETests.ps1 -Fast`.

## Review Focus

- An exclusion for tenant A must not hide the property in tenant B (Task 2).
- A finding with one excluded and one real difference stays drift and lists both; with only the excluded one it stops counting but stays visible (Task 2).
- Revert of an item with an excluded property and another real difference writes the tenant's value for the excluded property and the blueprint's for the rest (Task 3).
- After Unexclude the property counts as drift again without a new tenant read (Task 4).
- An exclusion of a property that does not differ, or for an unknown item, changes nothing and does not error (Task 2).

---

### Task 1: Decision kind `PropertyExcluded`

**Files:**
- Modify: `src/PolicyEngine/Public/Decisions.ps1` (the three `ValidateSet('Unmanaged', 'Noise', 'Remove')`; Kind checks in `Set-PEDecision`, lines 30-50)
- Test: `tests/Decisions.Tests.ps1`

**Interfaces:**
- Produces: `Set-PEDecision -Kind PropertyExcluded -ResourceType <t> -Property <p> -Tenant <slug> -Reason <r> [-Key <k>] [-DataRoot]`; `Get-PEDecision -Kind PropertyExcluded`; `Remove-PEDecision -Kind PropertyExcluded -ResourceType -Property -Tenant [-Key]`. Identity is the existing (Kind, ResourceType, Key, Property, Tenant) via `Test-PEDecisionMatch`.

- [ ] **Step 1: Write failing tests** in `Decisions.Tests.ps1` (reuse the temp `DataRoot` pattern): without `-Tenant` it throws `*requires -Tenant*`; without `-Property` it throws `*requires -Property*`; a type-wide (no `-Key`) and an item-level (`-Key 'GDPR'`) exclusion for the same tenant and property are two decisions; setting the same identity twice keeps one; `Get-PEDecision -Kind PropertyExcluded -Tenant contoso` returns contoso's and not another tenant's; `Remove-PEDecision` with `-Key` removes only the item-level one.
- [ ] **Step 2: Run** `Invoke-Pester -Path tests\Decisions.Tests.ps1`; expected FAIL.
- [ ] **Step 3: Implement.** Add the kind to the three `ValidateSet`s; in `Set-PEDecision` require `-Property` and `-Tenant` for it, allow an empty `-Key`, keep `Property` (change `if ($Kind -ne 'Noise') { $Property = $null }` to also keep it for `PropertyExcluded`), store `Value = $null`.
- [ ] **Step 4: Run** `Decisions.Tests.ps1` and `Module.Tests.ps1`; `Grep "'Unmanaged', 'Noise'" src gui` and fix any other closed list; expected PASS.
- [ ] **Step 5: Commit** `feat: decision kind PropertyExcluded`.

### Task 2: `Compare-PEState` marks excluded differences

**Files:**
- Modify: `src/PolicyEngine/Public/Compare-PEState.ps1` (decision loop at line 305; matched-pair block ending at line 267; step 6 at line 402), `src/PolicyEngine/Private/Compare.ps1` (`New-PEFinding`: new `ExcludedDifferences` property, default empty array)
- Test: create `tests/PropertyExclusion.Tests.ps1`

**Interfaces:**
- Consumes: decisions already filtered to the tenant by the caller (`Get-PEDecision -Tenant`); the function also ignores a `PropertyExcluded` decision with an empty `Tenant`.
- Produces: findings of Kind `Changed` carry `Differences` (still enforced) and `ExcludedDifferences` (same shape `@{Property; Blueprint; Target}`); when `Differences` is empty and `ExcludedDifferences` is not, the finding is kept with `State = 'Unmanaged'` instead of being dropped; every other finding has `ExcludedDifferences = @()`.

- [ ] **Step 1: Write failing tests** (helpers `New-Rec`/`New-St` as in `CrossTenant.Tests.ps1`), type `SCDLPCompliancePolicy`, five pairs differing only in `Priority`, decision `[pscustomobject]@{ Kind='PropertyExcluded'; ResourceType='SCDLPCompliancePolicy'; Key=$null; Property='Priority'; Tenant='contoso' }`:
  - type-wide: 5 findings, each `State -eq 'Unmanaged'`, `Differences.Count -eq 0`, `ExcludedDifferences.Property -contains 'Priority'`, with both values kept.
  - item-level (`Key='GDPR'`): only that finding is `Unmanaged`, the other four stay `Open` with `Differences`.
  - mixed: a pair differing in `Priority` and `Mode` is `Open`, `Differences.Property -eq 'Mode'`, `ExcludedDifferences.Property -eq 'Priority'`.
  - a decision with `Tenant = $null` hides nothing; a decision for another property or an item that does not differ changes nothing and does not throw.
  - `Get-PEStatus` over the five `Unmanaged` findings counts them as excluded, not drifted (use the existing `Get-PEStatus` test style in `Status.Tests.ps1`).
  - no decisions: output identical to today (run `Compare.Tests.ps1` unchanged).
- [ ] **Step 2: Run** `Invoke-Pester -Path tests\PropertyExclusion.Tests.ps1`; expected FAIL.
- [ ] **Step 3: Implement.** In the decision loop collect `PropertyExcluded` decisions into a case-insensitive dictionary type to list of `{ Key; Property }`. In the matched-pair block, after `$differences` is final (after the tenant-name step), split it with the type's rules into enforced and excluded and pass `-ExcludedDifferences` to `New-PEFinding`; add a finding when either list is non-empty. In step 6, a `Changed` finding with no `Differences` left sets `State = 'Unmanaged'` (the Noise step keeps dropping findings it empties, as today). Update the help text.
- [ ] **Step 4: Run** `PropertyExclusion.Tests.ps1`, `Compare.Tests.ps1`, `CrossTenant.Tests.ps1`, `Status.Tests.ps1`, `ExcludeReplica.Tests.ps1`; expected PASS.
- [ ] **Step 5: Commit** `feat: Compare-PEState keeps excluded differences visible and not counted`.

### Task 3: Revert keeps the tenant's value of an excluded property

**Files:**
- Modify: `src/PolicyEngine/Public/Rectify.ps1` (`New-PERectifyPlan`, after the cross-tenant strip at line 220), `src/PolicyEngine/Private/Rectify.ps1` (`Get-PEPlanItemSnapshot` line 274: include `ExcludedDifferences` property names in the frozen finding so the audit records them)
- Test: `tests/Rectify.Tests.ps1`

**Interfaces:**
- Consumes: `finding.ExcludedDifferences` (Task 2).
- Produces: for an `Update` of a `Changed` finding, the plan item's record is the blueprint record with each excluded property replaced by the target value from the difference (property removed when that target value is `$null`); the snapshot's `Finding` gains `ExcludedProperties = [string[]]`.

- [ ] **Step 1: Write failing tests:** a `Changed` finding with `Differences = Mode` and `ExcludedDifferences = Priority (blueprint 1, target 4)`: the planned record has `Priority = 4` and the blueprint's `Mode`; a target value of `$null` removes `Priority` from the record; a finding with no excluded differences plans exactly as before; the audit snapshot lists `ExcludedProperties = @('Priority')`; a finding that is only excluded (State `Unmanaged`) is still refused for Update with the existing message.
- [ ] **Step 2: Run** `Invoke-Pester -Path tests\Rectify.Tests.ps1`; expected FAIL.
- [ ] **Step 3: Implement** the substitution on a copy of the record's property bag (never modify the finding's record) and the snapshot field.
- [ ] **Step 4: Run** `Rectify.Tests.ps1`, `InvokeRectify.Tests.ps1`, `Apply.Tests.ps1`; expected PASS.
- [ ] **Step 5: Commit** `feat: Revert leaves excluded properties as the tenant has them`.

### Task 4: GUI: exclude, show, bring back

**Files:**
- Modify: `src/PolicyEngine/Private/GuiFindingList.ps1` (row field `excludedDifferences`, same shape as `differences`), `src/PolicyEngine/Public/Export-PEGuiData.ps1` (`exclusions.json` gains `propertyExclusions`: `{ tenantId, resourceType, property, itemId (null when type-wide), reason, at }`), `src/PolicyEngine/Private/GuiRequest.ps1` (new cases `ExcludePropertyForTenant` and `IncludePropertyForTenant` beside `ExcludeProperty` at line 262), `gui/PEGui.psm1` (`Get-PEGuiAllowedAction` line 107: add `ExcludePropertyForTenant` for `Changed` findings; the place request actions are whitelisted, found with `Grep -a "ExcludeProperty" gui src`), `gui/public/assets/app.js` (drift detail near line 770 next to "Ignore value as noise…"; item detail near line 830; Exclusions screen; action labels near line 12)
- Test: `tests/GuiRequest.Tests.ps1`, `tests/GuiExport.Tests.ps1`, `tests/RevertBlocked.Tests.ps1` (its expected action string `'Promote,Exclude,ExcludeProperty'` gains the new action), `gui/tests/PEGui.Tests.ps1`

**Interfaces:**
- Consumes: `Set-PEDecision`/`Remove-PEDecision -Kind PropertyExcluded` (Task 1), `Update-PECheckForItems -Tenant -BlueprintName -Item` (`Private\Recompare.ps1`; recompares chosen items of the latest Full check with no tenant read), `ExcludedDifferences` (Task 2).
- Produces: request `@{ action='ExcludePropertyForTenant'; tenantId; reason; items=@(@{ itemId; property; scope='item'|'type' }) }` and `@{ action='IncludePropertyForTenant'; tenantId; items=@(@{ resourceType; property; itemId }) }`; the worker records or removes the decision, then recompares the affected items (for `scope='type'`, every item of that type in the tenant's latest Full check) with `Update-PECheckForItems` for the tenant's own blueprint (`& $ownBlueprint`), then returns `& $done`.

- [ ] **Step 1: Write failing tests:** the export row of a finding with excluded differences has `excludedDifferences` and `state = 'Unmanaged'` when nothing is left; `exclusions.json` lists `propertyExclusions` with `itemId = $null` for a type-wide one; `ExcludePropertyForTenant` with `scope='type'` for tenant `replica` records the decision for `replica` only and, after the refresh, the type's findings are `Unmanaged` while the same type in another tenant stays `Open`; a missing reason or tenant is refused; `IncludePropertyForTenant` removes the decision and the findings count as drift again; `Get-PEGuiAllowedAction` offers the new action only for `Changed` findings.
- [ ] **Step 2: Run** the four test files; expected FAIL.
- [ ] **Step 3: Implement** the export fields, the two worker cases and the whitelist. In `app.js`: a link **Exclude for this tenant…** beside each differing property (dialog: scope "this item" or "every item of this type in <tenant>", reason, note that other tenants are unaffected); in item detail show `excludedDifferences` as greyed rows reading "Excluded for <tenant>" with a **Bring back** link; on the Exclusions screen a **Property exclusions** list with **Bring back**. Leave the existing noise rule untouched.
- [ ] **Step 4: Run** the four files; then start the GUI (`/run` skill) on the demo data and take a screenshot of the drift detail, the item detail and the Exclusions list; expected: `Priority` excluded in `contoso` goes clean, stays visible greyed, and Bring back restores it.
- [ ] **Step 5: Commit** `feat: GUI exclude a property for one tenant`.

### Task 5: Documents and full run

**Files:**
- Modify: `docs/handover.md` (section "Excluding a property for one tenant (2026-10-27)": what it does, `ExcludedDifferences`, State `Unmanaged` reuse, Revert keeps the tenant value, top-level properties only, and the live finding that motivated it: `SCDLPCompliancePolicy.Priority` differs on all 5 shared policies between master and `contoso`, deliberately kept as drift), `docs/overview.md` ("Decisions and noise")

- [ ] **Step 1: Write the docs.**
- [ ] **Step 2: Run** `pwsh -NoProfile -File tools\Invoke-PETests.ps1 -Fast`; expected all pass.
- [ ] **Step 3: Commit** `docs: per-tenant property exclusion`; push `main` (project rule: push after each finished piece of work).
