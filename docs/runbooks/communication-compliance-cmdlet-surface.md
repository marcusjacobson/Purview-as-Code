# Runbook: Communication Compliance cmdlet surface (live IPPS probe)

Captures the live `*-SupervisoryReview*` cmdlet inventory the
`ExchangeOnlineManagement` module exposes via implicit remoting after
`Connect-IPPSSession`, and resolves the open question from issue
[#271](https://github.com/contoso/Purview-as-Code-Generic/issues/271)
about whether `Remove-SupervisoryReviewRule` exists despite Microsoft
Learn returning 404 for that page.

This runbook is referenced from
[`data-plane/communication-compliance/policies.yaml`](../../data-plane/communication-compliance/policies.yaml)
and [`scripts/Deploy-CommunicationCompliance.ps1`](../../scripts/Deploy-CommunicationCompliance.ps1).

## Probe date and module version

- **Probe date:** 2026-05-16
- **Tenant:** `contoso.onmicrosoft.com`
- **Module:** `ExchangeOnlineManagement` **3.9.0**
- **Auth:** Key Vault-signed JWT via
  [`scripts/Get-PurviewIPPSAccessToken.ps1`](../../scripts/Get-PurviewIPPSAccessToken.ps1)
  (ADR 0011), then `Connect-IPPSSession -AccessToken`.
- **Proxy module:** Implicit remoting surfaces the real cmdlets through
  a per-session `tmpEXO_<random>` module. `Get-Command -Module
  ExchangeOnlineManagement *SupervisoryReview*` returns zero results on
  its own; the probe targets `*SupervisoryReview*` across all loaded
  modules.

## How to reproduce

```pwsh
# Pre-req: PIM activation that grants Key Vault read on kv-contoso-lab-01.
az login --tenant contoso.onmicrosoft.com
az account set --subscription <lab-subscription-id>

# Temp-open Key Vault (close in finally; see deploy-labels-prune-pitfalls memory note).
az keyvault update --name kv-contoso-lab-01 --resource-group rg-purview-lab `
  --public-network-access Enabled --default-action Allow --only-show-errors -o none
Start-Sleep -Seconds 30

try {
  $appId = az ad app list --display-name gh-oidc-purview-data-plane --query "[0].appId" -o tsv
  $tok = & .\scripts\Get-PurviewIPPSAccessToken.ps1 `
    -VaultName       kv-contoso-lab-01 `
    -CertificateName gh-oidc-purview-data-plane `
    -AppId           $appId `
    -TenantId        <tenant-id>
  Import-Module ExchangeOnlineManagement
  Connect-IPPSSession -AccessToken $tok.AccessToken -Organization contoso.onmicrosoft.com -ShowBanner:$false

  Get-Module ExchangeOnlineManagement | Select-Object Name, Version
  Get-Command *SupervisoryReview* | Select-Object Name, CommandType, Source
  Get-Command Remove-SupervisoryReviewRule -ErrorAction SilentlyContinue
  Get-SupervisoryReviewPolicyV2
} finally {
  az keyvault update --name kv-contoso-lab-01 --resource-group rg-purview-lab `
    --public-network-access Disabled --default-action Deny --only-show-errors -o none
}
```

## Live cmdlet inventory

The full set of `*SupervisoryReview*` cmdlets surfaced by
`ExchangeOnlineManagement` 3.9.0 via the implicit-remoting proxy
module:

| Verb-Noun | CommandType | Microsoft Learn |
|---|---|---|
| `Get-SupervisoryReviewActivity` | Function | not separately documented under exchange/ |
| `Get-SupervisoryReviewOverallProgressReport` | Function | not separately documented under exchange/ |
| `Get-SupervisoryReviewPolicyReport` | Function | not separately documented under exchange/ |
| `Get-SupervisoryReviewPolicyV2` | Function | [link](https://learn.microsoft.com/en-us/powershell/module/exchange/get-supervisoryreviewpolicyv2) |
| `Get-SupervisoryReviewReport` | Function | not separately documented under exchange/ |
| `Get-SupervisoryReviewRule` | Function | [link](https://learn.microsoft.com/en-us/powershell/module/exchange/get-supervisoryreviewrule) |
| `Get-SupervisoryReviewTopCasesReport` | Function | not separately documented under exchange/ |
| `New-SupervisoryReviewPolicyMailboxFolders` | Function | not separately documented under exchange/ |
| `New-SupervisoryReviewPolicyV2` | Function | [link](https://learn.microsoft.com/en-us/powershell/module/exchange/new-supervisoryreviewpolicyv2) |
| `New-SupervisoryReviewRule` | Function | [link](https://learn.microsoft.com/en-us/powershell/module/exchange/new-supervisoryreviewrule) |
| `Remove-SupervisoryReviewPolicyV2` | Function | [link](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-supervisoryreviewpolicyv2) |
| `Set-SupervisoryReviewPolicyV2` | Function | [link](https://learn.microsoft.com/en-us/powershell/module/exchange/set-supervisoryreviewpolicyv2) |
| `Set-SupervisoryReviewRule` | Function | [link](https://learn.microsoft.com/en-us/powershell/module/exchange/set-supervisoryreviewrule) |

> Reporting / activity cmdlets (`*Activity`, `*Report`, `*ReportTop*`)
> and `New-SupervisoryReviewPolicyMailboxFolders` are surfaced by the
> module but are out of scope for the reconciler in
> [`scripts/Deploy-CommunicationCompliance.ps1`](../../scripts/Deploy-CommunicationCompliance.ps1).
> They are listed here for completeness only.

## `Remove-SupervisoryReviewRule` — confirmed absent

`Get-Command Remove-SupervisoryReviewRule` against the live IPPS
session returned no result. Microsoft Learn's
[`remove-supervisoryreviewrule`](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-supervisoryreviewrule)
page also returns HTTP 404. There is no documented or undocumented
alias.

### Consequence for the reconciler

[`scripts/Deploy-CommunicationCompliance.ps1`](../../scripts/Deploy-CommunicationCompliance.ps1)
deliberately implements only **Create** and **Update** branches for
rules:

- Orphan rules (present in the tenant, absent from
  `policies.yaml`) are reported with category `RuleOrphan` but not
  deleted.
- The only way to remove a Supervisory Review rule is to remove its
  **parent policy** via `Remove-SupervisoryReviewPolicyV2`. Rules
  cascade with their parent.

### Workaround when a rule must go

1. Confirm the parent policy is itself an orphan (or you accept its
   removal).
2. Re-run `Deploy-CommunicationCompliance.ps1 -PruneMissing` to remove
   the parent policy. The parent removal cascades to its rules.
3. Re-declare the parent in `policies.yaml` (without the unwanted rule)
   on the next apply pass to re-create the policy and its remaining
   rules.

If the rule must be removed but the parent policy must stay, the only
option is to perform the rule deletion through the Microsoft Purview
portal (Communication Compliance > Policies > Policy > Edit > Conditions)
and re-run the reconciler to confirm zero drift.

## Property-name capture — deferred (path (b))

The probe found **zero existing Supervisory Review policies** in the
lab tenant on 2026-05-16. The defensive `PSObject.Properties.Match`
fallbacks in
`ConvertTo-TenantCommunicationCompliancePolicyHash` and
`ConvertTo-TenantCommunicationComplianceRuleHash` therefore remain in
place. Property-name tightening (AC#2 of issue #271) is deferred to
the same PR that lands the first declarative policy under
[`data-plane/communication-compliance/policies.yaml`](../../data-plane/communication-compliance/policies.yaml).

When that PR lands, capture an unredacted `Get-SupervisoryReviewPolicyV2 |
Format-List` against the new policy, reduce reviewer UPNs to
`<REDACTED-reviewer-count=N>`, and append the output as a new section
under "Property dumps" in this runbook.

## References

- **[Get-SupervisoryReviewPolicyV2](https://learn.microsoft.com/en-us/powershell/module/exchange/get-supervisoryreviewpolicyv2)**
  Fetch date: 2026-05-16
  > "Use the Get-SupervisoryReviewPolicyV2 cmdlet to view supervisory review policies in the Microsoft Purview compliance portal."
- **[New-SupervisoryReviewPolicyV2](https://learn.microsoft.com/en-us/powershell/module/exchange/new-supervisoryreviewpolicyv2)**
  Fetch date: 2026-05-16
- **[Set-SupervisoryReviewPolicyV2](https://learn.microsoft.com/en-us/powershell/module/exchange/set-supervisoryreviewpolicyv2)**
  Fetch date: 2026-05-16
- **[Remove-SupervisoryReviewPolicyV2](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-supervisoryreviewpolicyv2)**
  Fetch date: 2026-05-16
- **[Get-SupervisoryReviewRule](https://learn.microsoft.com/en-us/powershell/module/exchange/get-supervisoryreviewrule)**
  Fetch date: 2026-05-16
- **[New-SupervisoryReviewRule](https://learn.microsoft.com/en-us/powershell/module/exchange/new-supervisoryreviewrule)**
  Fetch date: 2026-05-16
- **[Set-SupervisoryReviewRule](https://learn.microsoft.com/en-us/powershell/module/exchange/set-supervisoryreviewrule)**
  Fetch date: 2026-05-16
- **`Remove-SupervisoryReviewRule`** — Microsoft Learn URL
  `https://learn.microsoft.com/en-us/powershell/module/exchange/remove-supervisoryreviewrule`
  returned HTTP 404 on 2026-05-16, and `Get-Command` against the live
  session returned no result. The cmdlet does not exist.
- **[Connect-IPPSSession](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession)**
  Fetch date: 2026-05-16
