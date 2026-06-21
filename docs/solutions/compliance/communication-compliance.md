# Microsoft Purview Communication Compliance

Operational guide for [`scripts/Deploy-CommunicationCompliance.ps1`](../../../scripts/Deploy-CommunicationCompliance.ps1) and [`data-plane/communication-compliance/policies.yaml`](../../../data-plane/communication-compliance/policies.yaml). Microsoft Learn documents [Microsoft Purview Communication Compliance](https://learn.microsoft.com/en-us/purview/communication-compliance), but ADR 0019 makes this repo's posture drift-detection only.

## Purpose

This repo does not author Communication Compliance policies. Per [ADR 0019](../../adr/0019-cc-graph-pivot.md), Microsoft Learn documents no supported programmatic authoring surface for modern Communication Compliance policies, and the standing YAML state is `policies: []`.

The reconciler keeps read paths for `Get-SupervisoryReviewPolicyV2` and `Get-SupervisoryReviewRule` so operator-authored portal policies show up as drift. With the standing empty YAML, live policies appear as `Orphan` rows in `-WhatIf` output. Do not add policy entries to YAML unless ADR 0019 is superseded by a new accepted ADR.

## Default state

[`policies.yaml`](../../../data-plane/communication-compliance/policies.yaml) intentionally contains:

```yaml
policies: []
```

That empty list is the approved steady state, not a scaffold awaiting the first entry. Manual policy authoring happens in the Microsoft Purview portal, and this repo records only drift-detection evidence and role-group prerequisites.

## Authentication

The drift detector uses Security & Compliance PowerShell. Locally, it expects an active `az login` session and the Key Vault certificate access needed to sign the app-only token. `-VaultName`, `-CertificateName`, `-DataPlaneAppDisplayName`, and `-TenantDomain` resolve from `infra/parameters/lab.yaml` when omitted.

The caller must have the repo's automation prerequisites for Security & Compliance PowerShell. Human operators who create or manage policies do so in the Microsoft Purview portal with the appropriate Communication Compliance role-group membership.

## Inputs

| Parameter | Default / meaning |
|---|---|
| `-Path` | `data-plane/communication-compliance/policies.yaml` |
| `-PruneMissing` | Present on the script but not part of the approved Communication Compliance posture. Do not use unless ADR 0019 is superseded. |
| `-ParametersFile` | `infra/parameters/lab.yaml` resolved from repo root. |
| `-VaultName` | Key Vault containing the automation certificate; resolved from `-ParametersFile` when omitted. |
| `-CertificateName` | Key Vault certificate and key object; resolved from `-ParametersFile` when omitted. |
| `-DataPlaneAppDisplayName` | Microsoft Entra ID data-plane app display name; resolved from `-ParametersFile` when omitted. |
| `-TenantDomain` | Tenant primary domain passed to `Connect-IPPSSession`; resolved from `-ParametersFile` when omitted. |
| `-SkipSchemaValidation` | Bypasses JSON Schema validation. Do not use in CI. |
| `-WhatIf` | Supported by `SupportsShouldProcess`; use it for drift detection. |

## Manage Communication Compliance with this repo

1. Capture the current portal-authored posture as drift evidence.

   ```pwsh
   $env:PURVIEW_ACCOUNT_NAME = 'purview-contoso-lab'
   ./scripts/Deploy-CommunicationCompliance.ps1 `
     -ParametersFile ./infra/parameters/lab.yaml `
     -WhatIf
   ```

1. Keep [`policies.yaml`](../../../data-plane/communication-compliance/policies.yaml) at `policies: []`. Do not add reviewers, user UPNs, policy names, or rule conditions to this repo.

1. Create, edit, or remove Communication Compliance policies manually in the Microsoft Purview portal. Use synthetic values in docs and PRs, and record only non-sensitive evidence such as the count of expected portal policies.

1. Re-run the drift check after portal changes.

   ```pwsh
   ./scripts/Deploy-CommunicationCompliance.ps1 -WhatIf
   ```

   Expected portal-authored policies appear as `Orphan` rows because the YAML intentionally stays empty.

1. Do not apply policy authoring locally. A local run without `-PruneMissing` is a no-op with `policies: []`; a run with `-PruneMissing` is outside the approved posture.

1. Do not rely on [`deploy-data-plane.yml`](../../../.github/workflows/deploy-data-plane.yml) for Communication Compliance today. The workflow does not run this script. If a future CI PR wires it in, the step must be a drift check only and must preserve the `policies: []` contract.

1. Verify the cmdlet surface with the [Communication Compliance cmdlet surface runbook](../../runbooks/communication-compliance-cmdlet-surface.md) when Microsoft Learn or the Exchange Online PowerShell module changes.

## References

- **[Learn about Communication Compliance](https://learn.microsoft.com/en-us/purview/communication-compliance)**
  Fetch date: 2026-06-20
  > "Microsoft Purview Communication Compliance is an insider risk solution"
- **[Manage Communication Compliance policies](https://learn.microsoft.com/en-us/purview/communication-compliance-policies)**
  Fetch date: 2026-06-20
  > "PowerShell isn't supported for creating and managing Communication Compliance policies."
- **[Get-SupervisoryReviewPolicyV2](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-supervisoryreviewpolicyv2?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "Use the Get-SupervisoryReviewPolicyV2 cmdlet to view supervisory review policies in the Microsoft Purview compliance portal."
- **[Connect-IPPSSession](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "Use the Connect-IPPSSession cmdlet in the Exchange Online PowerShell module to connect to Security & Compliance PowerShell using modern authentication."
- [ADR 0019 — Communication Compliance authoring surface](../../adr/0019-cc-graph-pivot.md)
- [Communication Compliance cmdlet surface runbook](../../runbooks/communication-compliance-cmdlet-surface.md)
