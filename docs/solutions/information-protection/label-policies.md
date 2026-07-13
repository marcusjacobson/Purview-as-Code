# Information Protection — label policies

Operational guide for [`scripts/Deploy-LabelPolicies.ps1`](../../../scripts/Deploy-LabelPolicies.ps1) — the
reconciler that materializes
[`data-plane/information-protection/label-policies.yaml`](../../../data-plane/information-protection/label-policies.yaml)
against the [Microsoft Purview label policy](https://learn.microsoft.com/en-us/purview/create-sensitivity-labels)
surface. Run the label taxonomy reconciler first; policy entries resolve their label references through the live
tenant.

## Purpose

Reconciles the `Get-LabelPolicy`, `New-LabelPolicy`, `Set-LabelPolicy`, and `Remove-LabelPolicy` Security &
Compliance PowerShell cmdlet surface against declared publishing policies. The script also reads `Get-Label` so YAML
label references can resolve to the immutable label identifiers returned by the tenant.

Tracked drift includes policy mode, Exchange locations, Modern Group locations, included administrative units,
Power BI compliance information, label membership, and allowlisted advanced settings. The planner emits `Create`,
`Update`, `NoChange`, `Orphan`, `NoOp`, `Skip`, and `Blocked` decisions. Under `portal-wins`, shared-property drift
is skipped and can be re-imported through the workflow's drift-back PR; under `repo-wins`, YAML overwrites tenant
drift after the typed workflow confirmation.

## Default state

The shipped YAML represents two enabled publishing policies:

- A default policy that publishes the lower-sensitivity labels and carries default-label advanced settings.
- A broader policy that publishes the confidential and highly confidential taxonomy, including sublabels.

Both policies currently target `exchangeLocation: [All]`, carry empty `modernGroupLocation: []` and
`includedAdministrativeUnits: []` arrays, enable the `powerBIComplianceInformation` boolean field, and declare only
allowlisted `advancedSettings` keys. The YAML describes policy shape only; it does not contain real tenant IDs,
subscription IDs, object IDs, or UPNs.

## Authentication

The script uses the Security & Compliance PowerShell app-only path shared with the label taxonomy reconciler:

1. Resolve Key Vault, certificate, data-plane app display name, and tenant domain from
   [`infra/parameters/lab.yaml`](../../../infra/parameters/lab.yaml) unless overridden.
2. Call [`Get-PurviewIPPSAccessToken.ps1`](../../../scripts/Get-PurviewIPPSAccessToken.ps1) to obtain an app-only
   access token backed by the Key Vault certificate.
3. Connect with `Connect-IPPSSession -AccessToken -Organization <tenant-domain> -ShowBanner:$false`.

CI uses GitHub Actions OpenID Connect for the Azure login context before the Security & Compliance PowerShell token
is minted. Label policies are applied by the dedicated
[`deploy-label-policies.yml`](../../../.github/workflows/deploy-label-policies.yml) workflow — the per-solution
workflow that owns this surface and nothing else, per
[ADR 0051](../../adr/0051-per-solution-workflow-unit-of-data-plane-apply.md).

## Inputs

| Parameter | Default source |
|---|---|
| `-Path` | `data-plane/information-protection/label-policies.yaml` |
| `-ParametersFile` | `infra/parameters/lab.yaml` |
| `-VaultName` | `resources.keyVault.name` in the parameters file |
| `-CertificateName` | `automation.apps.dataPlane.certificateName` in the parameters file |
| `-DataPlaneAppDisplayName` | `automation.apps.dataPlane.displayName` in the parameters file |
| `-TenantDomain` | `automation.tenantDomain` in the parameters file |
| `-PruneMissing` | switch — DESTRUCTIVE: remove tenant label policies absent from YAML |
| `-Force` | switch — only allows `-ExportCurrentState` to overwrite a non-empty `labelPolicies:` block |
| `-ExportCurrentState` | switch — export live label policies into the YAML and exit without tenant writes |
| `-VerifyPublished` | switch — read-only publish-status verification for desired policies |
| `-CompareWithTenant` | switch — read-only structural comparison of YAML and tenant state |
| `-DirectionPolicy` | `portal-wins`; accepts `audit`, `portal-wins`, `repo-wins` per [ADR 0029](../../adr/0029-source-of-truth-direction-policy.md) |
| `-SkipNames` | empty string array; workflow-supplied skip list for `portal-wins` |
| `-SkipSchemaValidation` | switch — emergency bypass for schema validation, not for CI |
| `-WhatIf` | common `SupportsShouldProcess` switch; previews without `New-LabelPolicy`, `Set-LabelPolicy`, or `Remove-LabelPolicy` writes |

## Manage label policies with this repo

1. **Export current state before first apply or when adopting portal-authored policies.**

   ```pwsh
   $purviewAccountName = 'purview-contoso-lab'
   ./scripts/Deploy-LabelPolicies.ps1 `
     -ParametersFile .\infra\parameters\lab.yaml `
     -ExportCurrentState `
     -InformationAction Continue
   ```

   Use `-Force` only when you intentionally replace an existing `labelPolicies:` block after reviewing the local diff.

2. **Edit [`label-policies.yaml`](../../../data-plane/information-protection/label-policies.yaml).**

   - Add a policy by appending a `labelPolicies[]` entry with a unique `name`, `mode`, locations, label references,
     and allowlisted settings.
   - Modify a policy by changing tracked fields such as `mode`, `exchangeLocation`, `modernGroupLocation`,
     `includedAdministrativeUnits`, `powerBIComplianceInformation`, `labels`, or `advancedSettings`.
   - Remove a policy by deleting the YAML entry, then previewing and applying `-PruneMissing` locally. The dedicated
     workflow does not expose a prune input for label policies.

3. **Preview drift.**

   ```pwsh
   $purviewAccountName = 'purview-contoso-lab'
   ./scripts/Deploy-LabelPolicies.ps1 `
     -DirectionPolicy audit `
     -InformationAction Continue

   ./scripts/Deploy-LabelPolicies.ps1 `
     -WhatIf `
     -PruneMissing `
     -InformationAction Continue
   ```

4. **Apply locally or by workflow dispatch.**

   ```pwsh
   $purviewAccountName = 'purview-contoso-lab'
   ./scripts/Deploy-LabelPolicies.ps1 `
     -DirectionPolicy portal-wins `
     -InformationAction Continue
   ```

   For CI, dispatch the dedicated workflow:

   ```pwsh
   gh workflow run deploy-label-policies.yml `
     --ref main `
     --field direction_policy=portal-wins
   ```

   For a YAML-first correction, use `repo-wins` only after reviewing the audit plan and documenting why the YAML value
   should overwrite the tenant value:

   ```pwsh
   gh workflow run deploy-label-policies.yml `
     --ref main `
     --field direction_policy=repo-wins `
     --field 'confirm_overwrite=overwrite portal'
   ```

5. **Verify.** Confirm the freshly applied policies have published or are present as expected:

   ```pwsh
   ./scripts/Deploy-LabelPolicies.ps1 -VerifyPublished -InformationAction Continue
   ./scripts/Deploy-LabelPolicies.ps1 -CompareWithTenant -InformationAction Continue
   ```

   Use [`labels-direction-policy.md`](../../runbooks/labels-direction-policy.md) for the shared ADR 0029 mode
   vocabulary. Use [`labels-prune-dispatch.md`](../../runbooks/labels-prune-dispatch.md) only for taxonomy label
   pruning; label-policy destructive removal is currently a local `-PruneMissing` operation.

## References

- **[Create and publish sensitivity labels](https://learn.microsoft.com/en-us/purview/create-sensitivity-labels)**
  Fetch date: 2026-06-20
  > "Then, create one or more label policies that contain the labels and policy settings that you configure."
- **[Manage Sensitivity Labels in Office Apps](https://learn.microsoft.com/en-us/purview/sensitivity-labels-office-apps)**
  Fetch date: 2026-06-20
  > "When you have published sensitivity labels from the Microsoft Purview portal, they start to appear in Office apps"
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
- **[Get-LabelPolicy](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-labelpolicy?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "Use the Get-LabelPolicy cmdlet to view sensitivity label policies in your organization."
- **[New-LabelPolicy](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-labelpolicy?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "Use the New-LabelPolicy cmdlet to create sensitivity label policies in your organization."
- **[Set-LabelPolicy](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "Use the Set-Label cmdlet to modify sensitivity label policies in your organization."
- **[Remove-LabelPolicy](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/remove-labelpolicy?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "Use the Remove-LabelPolicies cmdlet to remove sensitivity label policies from your organization."
- [ADR 0015 — Sensitivity label policy shape](../../adr/0015-label-policy-shape.md)
- [ADR 0029 — Source-of-truth direction policy](../../adr/0029-source-of-truth-direction-policy.md)
- [ADR 0040 — Default label for documents](../../adr/0040-default-label-for-documents.md)
- [ADR 0041 — Label-policy Fabric and Power BI compliance information](../../adr/0041-label-policy-fabric-powerbi.md)
- [ADR 0042 — Label-policy admin units scope](../../adr/0042-label-policy-admin-units.md)
