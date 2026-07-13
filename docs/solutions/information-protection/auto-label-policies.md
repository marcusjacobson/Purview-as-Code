# Information Protection — auto-label policies

Operational guide for [`scripts/Deploy-AutoLabelPolicies.ps1`](../../../scripts/Deploy-AutoLabelPolicies.ps1) — the
reconciler that materializes
[`data-plane/information-protection/auto-label-policies.yaml`](../../../data-plane/information-protection/auto-label-policies.yaml)
against the [Microsoft Purview auto-labeling](https://learn.microsoft.com/en-us/purview/apply-sensitivity-label-automatically)
surface. Run the sensitivity-label taxonomy and label-policy reconcilers before enabling service-side auto-labeling.

## Purpose

Reconciles the `Get/New/Set/Remove-AutoSensitivityLabelPolicy` and
`Get/New/Set/Remove-AutoSensitivityLabelRule` Security & Compliance PowerShell cmdlet surfaces against declared
auto-label policies and rules. The script also reads `Get-Label` so each `applyLabel` composite key resolves to the
live label value required by the policy cmdlets.

Tracked drift includes policy mode, applied label, Exchange scope, rule-to-policy relationship, and
`contentContainsSensitiveInformation` rule conditions. The planner emits `Create`, `Update`, `NoChange`, `Orphan`,
`NoOp`, `Skip`, and `Blocked` decisions across both policy and rule rows. Policies write before rules so the rule
foreign key resolves, and rules are removed before parent policies during pruning.

## Default state

The shipped YAML represents two service-side auto-labeling policies and two matching rules:

- One policy is in simulation mode without notifications for the built-in Credit Card Number Sensitive Information
  Type and targets the `Confidential/Partner` label.
- One policy is enabled for the built-in U.S. Social Security Number Sensitive Information Type and targets the same
  label.
- Both policies use `exchangeLocation: [All]`, empty `advancedSettings: {}`, and rule thresholds with a minimum count
  and confidence value.

The YAML uses Microsoft-published Sensitive Information Type references from the repo's classification catalog. It
must not contain real mailbox addresses, tenant IDs, subscription IDs, object IDs, or UPNs.

## Authentication

The script uses the same Security & Compliance PowerShell app-only authentication pattern as the label-policy
reconciler:

1. Resolve Key Vault, certificate, data-plane app display name, and tenant domain from
   [`infra/parameters/lab.yaml`](../../../infra/parameters/lab.yaml) unless overridden.
2. Call [`Get-PurviewIPPSAccessToken.ps1`](../../../scripts/Get-PurviewIPPSAccessToken.ps1) to obtain an app-only
   access token backed by the Key Vault certificate.
3. Connect with `Connect-IPPSSession -AccessToken -Organization <tenant-domain> -ShowBanner:$false`.

CI uses GitHub Actions OpenID Connect for Azure before the Security & Compliance PowerShell token is minted.
Auto-label policies are applied by the dedicated
[`deploy-auto-label-policies.yml`](../../../.github/workflows/deploy-auto-label-policies.yml) workflow — the
per-solution workflow that owns this surface and nothing else, per
[ADR 0051](../../adr/0051-per-solution-workflow-unit-of-data-plane-apply.md).

## Inputs

| Parameter | Default source |
|---|---|
| `-Path` | `data-plane/information-protection/auto-label-policies.yaml` |
| `-ParametersFile` | `infra/parameters/lab.yaml` |
| `-VaultName` | `resources.keyVault.name` in the parameters file |
| `-CertificateName` | `automation.apps.dataPlane.certificateName` in the parameters file |
| `-DataPlaneAppDisplayName` | `automation.apps.dataPlane.displayName` in the parameters file |
| `-TenantDomain` | `automation.tenantDomain` in the parameters file |
| `-PruneMissing` | switch — DESTRUCTIVE: remove tenant auto-label policies and rules absent from YAML |
| `-Force` | switch — only allows `-ExportCurrentState` to overwrite non-empty `policies:` / `rules:` blocks |
| `-ExportCurrentState` | switch — export live auto-label policies and rules into YAML and exit without tenant writes |
| `-VerifyPublished` | switch — read-only status verification for desired policies |
| `-DirectionPolicy` | `portal-wins`; accepts `audit`, `portal-wins`, `repo-wins` per [ADR 0029](../../adr/0029-source-of-truth-direction-policy.md) |
| `-SkipNames` | empty string array; workflow-supplied skip list for `portal-wins` |
| `-SkipSchemaValidation` | switch — emergency bypass for schema validation, not for CI |
| `-WhatIf` | common `SupportsShouldProcess` switch; previews without auto-label policy or rule writes |

## Manage auto-label policies with this repo

1. **Export current state before first apply or when adopting portal-authored auto-labeling.**

   ```pwsh
   $purviewAccountName = 'purview-contoso-lab'
   ./scripts/Deploy-AutoLabelPolicies.ps1 `
     -ParametersFile .\infra\parameters\lab.yaml `
     -ExportCurrentState `
     -InformationAction Continue
   ```

   Use `-Force` only when you intentionally replace existing `policies:` and `rules:` blocks after reviewing the diff.

2. **Edit [`auto-label-policies.yaml`](../../../data-plane/information-protection/auto-label-policies.yaml).**

   - Add a policy under `policies[]`, then add one or more `rules[]` entries whose `policy:` value matches the new
     policy name.
   - Modify a policy by changing `mode`, `applyLabel`, `exchangeLocation`, or rule conditions. Promotion from
     simulation to enabled mode is a high-impact operational change; document the preview evidence in the PR.
   - Remove a policy or rule by deleting its YAML entry, then previewing and applying `-PruneMissing` locally. Remove
     rules before parent policies when splitting the change manually; the script handles this order on prune.

3. **Preview drift.**

   ```pwsh
   $purviewAccountName = 'purview-contoso-lab'
   ./scripts/Deploy-AutoLabelPolicies.ps1 `
     -DirectionPolicy audit `
     -InformationAction Continue

   ./scripts/Deploy-AutoLabelPolicies.ps1 `
     -WhatIf `
     -PruneMissing `
     -InformationAction Continue
   ```

4. **Apply locally or by workflow dispatch.**

   ```pwsh
   $purviewAccountName = 'purview-contoso-lab'
   ./scripts/Deploy-AutoLabelPolicies.ps1 `
     -DirectionPolicy portal-wins `
     -InformationAction Continue
   ```

   For CI, dispatch the dedicated workflow:

   ```pwsh
   gh workflow run deploy-auto-label-policies.yml `
     --ref main `
     --field direction_policy=portal-wins
   ```

   For a YAML-first correction that should overwrite portal drift on a policy or rule, use `repo-wins` with the typed
   confirmation token:

   ```pwsh
   gh workflow run deploy-auto-label-policies.yml `
     --ref main `
     --field direction_policy=repo-wins `
     --field 'confirm_overwrite=overwrite portal'
   ```

5. **Verify.** Confirm status and run a final audit pass:

   ```pwsh
   ./scripts/Deploy-AutoLabelPolicies.ps1 -VerifyPublished -InformationAction Continue
   ./scripts/Deploy-AutoLabelPolicies.ps1 -DirectionPolicy audit -InformationAction Continue
   ```

   Use [`labels-direction-policy.md`](../../runbooks/labels-direction-policy.md) for the shared ADR 0029 mode
   vocabulary. Use [`labels-manual-portal-actions.md`](../../runbooks/labels-manual-portal-actions.md) only for
   label-level client-side auto-apply removal; service-side auto-label policies are managed by this reconciler.

## Round-trip and scope semantics (ADR 0016 §12)

The closed loop — portal change → `-ExportCurrentState` → sync PR → apply — reverse-exports only tenant state the
reconciler can then forward-apply. Two behaviors keep the loop closed:

- **Export-scope exclusion.** [ADR 0016](../../adr/0016-auto-label-policy-shape.md) models only SIT-based
  `contentContainsSensitiveInformation` (CCSI). A tenant rule whose conditions resolve to an empty CCSI — Exact Data
  Match (EDM), trainable classifier, document fingerprint, or any non-SIT condition — is non-representable.
  `-ExportCurrentState` builds rules first and skips any rule with an empty resolved CCSI (one warning per skip), then
  builds policies and skips any left with zero surviving rules (one warning per skip). The non-representable rules and
  policies are reported as skipped orphans, never written to YAML, so the regenerated file forward-deploys to
  all-`NoChange` for the representable (SIT-based, SharePoint/OneDrive-scoped) policies.

- **NoChange-only location semantics.** A SharePoint/OneDrive-only policy legitimately exports as
  `exchangeLocation: []`. The `exchangeLocation` key is required but its array may be empty; the schema no longer floors
  it at `minItems: 1` (the CCSI floor is unchanged), and the input-validation guard requires the key present but allows
  the empty array. Both hash converters default `exchangeLocation` to an empty array, so a SP/OD-only policy yields
  desired `[]` == tenant `[]` → `NoChange` and no cmdlet fires. On `Create`, an empty value omits `-ExchangeLocation`
  (the cmdlet then fails loudly on the genuinely-missing location, since SP/OD location fields are deferred per ADR 0016
  §2); on `Update`, an empty value skips the location write rather than clearing the tenant scope.

## References

- **[Automatically apply a sensitivity label to Microsoft 365 data](https://learn.microsoft.com/en-us/purview/apply-sensitivity-label-automatically)**
  Fetch date: 2026-06-20
  > "Use an auto-labeling policy."
- **[Connect-IPPSSession](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "Use the Connect-IPPSSession cmdlet in the Exchange Online PowerShell module to connect to Security & Compliance PowerShell using modern authentication."
- **[App-only authentication in Exchange Online PowerShell and Security & Compliance PowerShell](https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "Certificate based authentication (CBA) or app-only authentication as described in this article supports unattended script and automation scenarios"
- **[Authenticate to Azure from GitHub Actions by OpenID Connect](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect)**
  Fetch date: 2026-06-20
  > "Set up Azure Login with OpenID Connect authentication in GitHub Actions workflows"
- **[Get-Label](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-label?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "Use the Get-Label cmdlet to view sensitivity labels in your organization."
- **[Get-AutoSensitivityLabelPolicy](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-autosensitivitylabelpolicy?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "Use the Get-AutoSensitivityLabelPolicy cmdlet to view auto-labeling policies in your organization."
- **[New-AutoSensitivityLabelPolicy](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-autosensitivitylabelpolicy?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "Use the New-AutoSensitivityLabelPolicy cmdlet to create auto-labeling policies in your organization."
- **[Set-AutoSensitivityLabelPolicy](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-autosensitivitylabelpolicy?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "Use the Set-AutoSensitivityLabelPolicy cmdlet to modify auto-labeling policies in your organization."
- **[Remove-AutoSensitivityLabelPolicy](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/remove-autosensitivitylabelpolicy?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "Use the Remove-AutoSensitivityLabelPolicy cmdlet to remove auto-labeling policies from your organization."
- **[New-AutoSensitivityLabelRule](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-autosensitivitylabelrule?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "Use the New-AutoSensitivityLabelRule cmdlet to create auto-labeling rules and associate then with auto-labeling policies in your organization."
- **[Get-AutoSensitivityLabelRule](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-autosensitivitylabelrule?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "This cmdlet is available only in Security & Compliance PowerShell."
- **[Set-AutoSensitivityLabelRule](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-autosensitivitylabelrule?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "This cmdlet is available only in Security & Compliance PowerShell."
- **[Remove-AutoSensitivityLabelRule](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/remove-autosensitivitylabelrule?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "This cmdlet is available only in Security & Compliance PowerShell."
- **[Credit card number entity definition](https://learn.microsoft.com/en-us/purview/sit-defn-credit-card-number)**
  Fetch date: 2026-06-20
  > "Must pass the Luhn test."
- **[U.S. social security number (SSN) entity definition](https://learn.microsoft.com/en-us/purview/sit-defn-us-social-security-number)**
  Fetch date: 2026-06-20
  > "nine digits, which may be in a formatted or unformatted pattern"
- [ADR 0016 — Auto-labeling policy shape](../../adr/0016-auto-label-policy-shape.md)
- [ADR 0029 — Source-of-truth direction policy](../../adr/0029-source-of-truth-direction-policy.md)
