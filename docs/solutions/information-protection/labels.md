# Information Protection — sensitivity labels

Operational guide for [`scripts/Deploy-Labels.ps1`](../../../scripts/Deploy-Labels.ps1) — the reconciler that
materializes [`data-plane/information-protection/labels.yaml`](../../../data-plane/information-protection/labels.yaml)
against the [Microsoft Purview sensitivity labels](https://learn.microsoft.com/en-us/purview/sensitivity-labels)
surface. Use this page before changing the taxonomy, content marking, encryption, or label-level client-side
auto-apply shape.

## Purpose

Reconciles the `Get-Label`, `New-Label`, `Set-Label`, and `Remove-Label` Security & Compliance PowerShell cmdlet
surface against the declared label taxonomy. It reads every visible label, resolves parent/sublabel order, compares
tracked fields, emits a plan, and writes only when the caller authorizes the change.

Tracked drift includes label text fields, content-type scope, content markings, encryption settings, and supported
client-side `autoApplicationOf` shape. The planner emits `Create`, `Update`, `NoChange`, `Orphan`, `NoOp`, `Skip`,
`Blocked`, and `NeedsPortalAction` decisions. `NeedsPortalAction` is reserved for removing client-side auto-apply
conditions until Microsoft documents an in-band `Set-Label` clearing path; follow
[`labels-manual-portal-actions.md`](../../runbooks/labels-manual-portal-actions.md) when that row appears.

## Default state

The shipped YAML represents the lab taxonomy as a mix of top-level labels, sublabels, pilot fixtures, content
marking, and encryption settings:

- Top-level tiers include `Public`, `General`, `Confidential`, and `Highly Confidential`.
- `Confidential` and `Highly Confidential` carry audience-specific sublabels for internal, partner, and external
  collaboration. Restricted tier-4 sublabels use stronger visual markings.
- Pilot labels exercise the lab's encryption matrix without adding real principals; committed rights definitions use
  `user@contoso.com` placeholders.
- Client-side auto-apply conditions for selected labels are treated as portal-managed watch-list state, not as
  tenant identifiers in the YAML.

## Authentication

The script uses the same Security & Compliance PowerShell app-only path as the other Microsoft 365 reconcilers in
this repo:

1. Resolve the data-plane Microsoft Entra ID app and Key Vault certificate from
   [`infra/parameters/lab.yaml`](../../../infra/parameters/lab.yaml) unless the caller overrides the parameters.
2. Call [`Get-PurviewIPPSAccessToken.ps1`](../../../scripts/Get-PurviewIPPSAccessToken.ps1), which signs the
   client assertion with the Key Vault-backed certificate key.
3. Connect with `Connect-IPPSSession -AccessToken -Organization <tenant-domain> -ShowBanner:$false`.

In CI, GitHub Actions uses `azure/login@v2` with OpenID Connect before the script signs the Security & Compliance
PowerShell assertion. Sensitivity labels are applied by
[`deploy-labels.yml`](../../../.github/workflows/deploy-labels.yml) — the per-solution workflow that owns this
surface and nothing else, per [ADR 0051](../../adr/0051-per-solution-workflow-unit-of-data-plane-apply.md). It is
the **only** forward-apply path for labels, and it carries the full ADR 0029 `direction_policy` and label-prune
ceremony.

## Inputs

| Parameter | Default source |
|---|---|
| `-Path` | `data-plane/information-protection/labels.yaml` |
| `-ParametersFile` | `infra/parameters/lab.yaml` |
| `-VaultName` | `resources.keyVault.name` in the parameters file |
| `-CertificateName` | `automation.apps.dataPlane.certificateName` in the parameters file |
| `-DataPlaneAppDisplayName` | `automation.apps.dataPlane.displayName` in the parameters file |
| `-TenantDomain` | `automation.tenantDomain` in the parameters file |
| `-PruneMissing` | switch — DESTRUCTIVE: remove tenant labels absent from YAML |
| `-Force` | switch — only allows `-ExportCurrentState` to overwrite a non-empty `labels:` block |
| `-ExportCurrentState` | switch — export live labels into the YAML and exit without tenant writes |
| `-RedactIdentities` | switch — with `-ExportCurrentState`, replace exported rights identities with `user@contoso.com` |
| `-DirectionPolicy` | `portal-wins`; accepts `audit`, `portal-wins`, `repo-wins` per [ADR 0029](../../adr/0029-source-of-truth-direction-policy.md) |
| `-SkipNames` | empty string array; workflow-supplied skip list for `portal-wins` |
| `-SkipSchemaValidation` | switch — emergency bypass for schema validation, not for CI |
| `-WhatIf` | common `SupportsShouldProcess` switch; previews without `New-Label`, `Set-Label`, or `Remove-Label` writes |

## Manage sensitivity labels with this repo

1. **Export current state before first apply or before adopting portal edits.** Review the diff before committing.

   ```pwsh
   $purviewAccountName = 'purview-contoso-lab'
   ./scripts/Deploy-Labels.ps1 `
     -ParametersFile .\infra\parameters\lab.yaml `
     -ExportCurrentState `
     -RedactIdentities `
     -InformationAction Continue
   ```

   If `labels:` is already populated and the export is intentional, add `-Force` locally after saving a copy of the
   current file.

2. **Edit [`labels.yaml`](../../../data-plane/information-protection/labels.yaml).**

   - Add a label by appending a `labels[]` entry. For a sublabel, set `parent:` to the top-level display name.
   - Modify a label by changing tracked fields such as `tooltip`, `comment`, `contentType`, `contentMarking`, or
     `encryption`.
   - Remove a label by deleting the YAML entry, then preview and apply with `-PruneMissing`. Do not prune a label
     that a label policy or auto-label policy still references.

3. **Preview drift.** Use audit mode for a read-only evidence run, and add `-PruneMissing` only when previewing a
   destructive removal.

   ```pwsh
   $purviewAccountName = 'purview-contoso-lab'
   ./scripts/Deploy-Labels.ps1 `
     -DirectionPolicy audit `
     -InformationAction Continue

   ./scripts/Deploy-Labels.ps1 `
     -WhatIf `
     -PruneMissing `
     -InformationAction Continue
   ```

4. **Apply locally or by workflow dispatch.**

   ```pwsh
   $purviewAccountName = 'purview-contoso-lab'
   ./scripts/Deploy-Labels.ps1 `
     -DirectionPolicy portal-wins `
     -InformationAction Continue
   ```

   For a YAML-first correction that must overwrite portal drift, use `repo-wins` only after the PR explains why YAML
   is authoritative:

   ```pwsh
   gh workflow run deploy-labels.yml `
     --ref main `
     --field direction_policy=repo-wins `
     --field 'confirm_overwrite=overwrite portal'
   ```

   `deploy-labels.yml` is the only dispatch for this surface. The monolithic data-plane workflow that once
   carried a `plan_labels_only` taxonomy step was retired by
   [ADR 0051](../../adr/0051-per-solution-workflow-unit-of-data-plane-apply.md) — it never once executed, and it
   never exposed the full label direction-policy surface anyway. Use `direction_policy=audit` above for a
   read-only plan.

5. **Verify.** Re-run audit mode and inspect the plan for `NoChange`, `Skip`, `Blocked`, or `NeedsPortalAction`.
   Use [`labels-direction-policy.md`](../../runbooks/labels-direction-policy.md) for the ADR 0029 workflow modes,
   [`labels-prune-dispatch.md`](../../runbooks/labels-prune-dispatch.md) for destructive label removal, and
   [`labels-manual-portal-actions.md`](../../runbooks/labels-manual-portal-actions.md) for client-side auto-apply
   removal. Use [`Verify-SetLabelAutoApply.ps1`](../../../scripts/Verify-SetLabelAutoApply.ps1) only for a targeted
   tenant probe of the `Set-Label` auto-apply parameter surface, not as a routine deploy command.

## References

- **[Learn about sensitivity labels](https://learn.microsoft.com/en-us/purview/sensitivity-labels)**
  Fetch date: 2026-06-20
  > "Sensitivity labels from Microsoft Purview Information Protection let you classify and protect your organization's data"
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
- **[New-Label](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-label?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "Use the New-Label cmdlet to create sensitivity labels in your organization."
- **[Set-Label](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-label?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "Use the Set-Label cmdlet to modify sensitivity labels in your organization."
- **[Remove-Label](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/remove-label?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "Use the Remove-Label cmdlet to remove sensitivity labels from your organization."
- [ADR 0017 — Per-label client-side auto-application shape](../../adr/0017-label-auto-application-shape.md)
- [ADR 0027 — Sensitivity-label autoApplicationOf removal watch list](../../adr/0027-autoapplication-removal-watch-list.md)
- [ADR 0029 — Source-of-truth direction policy](../../adr/0029-source-of-truth-direction-policy.md)
