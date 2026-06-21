# Runbook: Local-cert provisioning for the data-plane IPPS auth path

Use this runbook when you need to provision, verify, rotate, or revoke
the **local signing cert** for the Microsoft Purview data-plane Entra app
on the lab owner's workstation. The local cert is the co-equal counterpart
to the Key-Vault-signed credential and lets every IPPS-authenticated
script run without a Key Vault firewall toggle. See
[ADR 0028](../adr/0028-co-equal-local-cert-credential.md) for the design
rationale.

> [!IMPORTANT]
> Hosted GitHub runners have no `Cert:\CurrentUser\My`. The local-cert
> path is exclusively for interactive runs from the lab owner's
> Windows account. Every CI workflow continues to use the
> Key-Vault-signed credential per [ADR 0011](../adr/0011-certificate-lifecycle.md).

## When to use this runbook

- You are about to iterate on a `Connect-IPPSSession`-bearing script
  ([`Deploy-Labels.ps1`](../../scripts/Deploy-Labels.ps1), the other 16
  IPPS callers listed in ADR 0028 Context) and want to skip the
  per-run KV unlock cost.
- Your existing local cert is approaching its `NotAfter` and you want
  to rotate it ahead of time.
- The lab owner's workstation has been compromised (or is suspected
  to have been) and you need to revoke the local credential while
  keeping CI working.

## When NOT to use this runbook

- You are running a CI workflow. Workflows authenticate via the
  KV-signed credential and ignore `$env:PURVIEW_LOCAL_CERT_THUMBPRINT`
  because the env var is not exported into the runner.
- You are running against a tenant other than `contoso.onmicrosoft.com`. The
  scripts are scoped to the lab tenant per
  [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md)
  ("Environment and identifier boundaries").

## Provision (one-time per workstation)

> [!NOTE]
> The script writes the private key directly into
> `Cert:\CurrentUser\My` with `KeyExportPolicy NonExportable`. There is
> no PFX file on disk on the happy path. The `.gitignore` patterns for
> `*.pfx` / `*.p12` / `*.key` / `*.pem` are defensive only.

```pwsh
# 1. Sign in to Azure CLI (must be the lab owner identity).
az login --tenant contoso.onmicrosoft.com --only-show-errors

# 2. Preview the change first.
./scripts/New-LocalAutomationCertificate.ps1 -WhatIf

# 3. Provision the cert and upload the public .cer as an additional
#    keyCredential on gh-oidc-purview-data-plane.
./scripts/New-LocalAutomationCertificate.ps1
```

The script prints two lines on success — the thumbprint and the env-var
shape downstream scripts read. Persist the env var across PowerShell
sessions for the current user with:

```pwsh
[Environment]::SetEnvironmentVariable(
    'PURVIEW_LOCAL_CERT_THUMBPRINT',
    '<thumbprint printed by the script>',
    'User')
```

Open a fresh PowerShell session before continuing so `$env:PURVIEW_LOCAL_CERT_THUMBPRINT`
is loaded from the user environment.

## Verify

Confirm the cert exists locally with the expected shape:

```pwsh
Get-ChildItem Cert:\CurrentUser\My |
    Where-Object { $_.Subject -like 'CN=gh-oidc-purview-data-plane-local-*' } |
    Select-Object Subject, Thumbprint, HasPrivateKey, NotAfter
```

Expected:

- One row.
- `HasPrivateKey: True`.
- `NotAfter` ~24 months in the future.

Confirm the public cert is registered on the data-plane Entra app:

```pwsh
az ad app list `
    --display-name gh-oidc-purview-data-plane `
    --query "[0].keyCredentials[].{displayName:displayName, endDateTime:endDateTime, customKeyIdentifier:customKeyIdentifier}" `
    -o table
```

Expected: at least two rows — one for the KV-signed credential
(`CN=gh-oidc-purview-data-plane`) and one for the local credential
(`CN=gh-oidc-purview-data-plane-local-<user>-<machine>`). The KV credential
must still be present per ADR 0028 §4.

Confirm a sample IPPS-authenticated script picks the local path:

```pwsh
./scripts/Deploy-Labels.ps1 -WhatIf -Verbose 2>&1 |
    Select-String -Pattern 'Auth path:'
```

Expected: `VERBOSE: Auth path: Local cert (Cert:\CurrentUser\My)`. If
you see `Auth path: Key Vault (...)`, your env var is not set in this
shell session.

## Rotate (annually, or whenever you choose)

```pwsh
az login --tenant contoso.onmicrosoft.com --only-show-errors

# Preview first.
./scripts/New-LocalAutomationCertificate.ps1 -RemoveExisting -WhatIf

# Apply.
./scripts/New-LocalAutomationCertificate.ps1 -RemoveExisting
```

`-RemoveExisting` removes the matching local cert from
`Cert:\CurrentUser\My`, generates a new one, and uploads the new public
cert as an additional `keyCredential` on the data-plane Entra app. The
old `keyCredential` is **not** removed from the app by this step — the
public cert listing is now accumulating, which is fine for normal
rotation but worth pruning during a security review. See "Revoke" below
for the pruning recipe.

Update `$env:PURVIEW_LOCAL_CERT_THUMBPRINT` to the new value:

```pwsh
[Environment]::SetEnvironmentVariable(
    'PURVIEW_LOCAL_CERT_THUMBPRINT',
    '<new thumbprint>',
    'User')
```

Open a fresh PowerShell session.

## Revoke (workstation compromise or routine cleanup)

> [!CAUTION]
> Revoke is destructive on the Microsoft Graph side. Do not delete the
> KV-signed credential by accident — that breaks every CI workflow.
> Always cross-reference the `customKeyIdentifier` you intend to remove
> against the verify recipe above.

```pwsh
az login --tenant contoso.onmicrosoft.com --only-show-errors

# 1. Identify the local cert's customKeyIdentifier on the Entra app.
$appObjectId = az ad app list --display-name gh-oidc-purview-data-plane --query "[0].id" -o tsv

$keyCreds = az ad app show --id $appObjectId --query keyCredentials -o json | ConvertFrom-Json
$keyCreds | Format-Table displayName, customKeyIdentifier, endDateTime

# 2. Build a new keyCredentials list that EXCLUDES the local cert(s)
#    but PRESERVES the KV credential.
$kept = $keyCreds | Where-Object { $_.displayName -notlike 'CN=gh-oidc-purview-data-plane-local-*' }

# 3. PATCH the application with the pruned list.
$body = @{ keyCredentials = $kept } | ConvertTo-Json -Depth 6
$tmp = (New-TemporaryFile).FullName + '.json'
Set-Content -Path $tmp -Value $body -Encoding utf8 -NoNewline
try {
    az rest --method PATCH `
            --uri "https://graph.microsoft.com/v1.0/applications/$appObjectId" `
            --headers 'Content-Type=application/json' `
            --body "@$tmp" `
            --only-show-errors
}
finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}

# 4. Remove the matching local cert from Cert:\CurrentUser\My.
Get-ChildItem Cert:\CurrentUser\My |
    Where-Object { $_.Subject -like 'CN=gh-oidc-purview-data-plane-local-*' } |
    ForEach-Object { Remove-Item -LiteralPath ("Cert:\CurrentUser\My\{0}" -f $_.Thumbprint) -Force }

# 5. Unset the env var.
[Environment]::SetEnvironmentVariable('PURVIEW_LOCAL_CERT_THUMBPRINT', $null, 'User')
```

After revoke the scripts fall through to the Key Vault path automatically
on their next run (Step 4 of the verify recipe will report
`Auth path: Key Vault (...)` instead).

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `LocalCertThumbprint '...' not found in Cert:\CurrentUser\My.` | Env var is set but the cert is on a different machine, in `LocalMachine\My`, or has been removed. | Re-run [`scripts/New-LocalAutomationCertificate.ps1`](../../scripts/New-LocalAutomationCertificate.ps1) or unset the env var. |
| `LocalCertThumbprint '...' was found in Cert:\CurrentUser\My but HasPrivateKey is False.` | The cert was imported from a `.cer` (public only) or the private key has been deleted. | Re-run the provisioning script with `-RemoveExisting`. |
| `LocalCertThumbprint '...' expired on YYYY-MM-DDT...` | Cert past `NotAfter`. | Re-run with `-RemoveExisting` to rotate. |
| `Auth path: Key Vault` even though env var is set | The env var was set in a different PowerShell session. | Confirm with `$env:PURVIEW_LOCAL_CERT_THUMBPRINT` in the current session; re-open the shell if needed. |
| `AADSTS700016: Application with identifier ... was not found in the directory` | The data-plane app does not yet carry the local cert's public key. | Confirm with the verify recipe; re-run provisioning if the Graph PATCH was skipped. |

## References

- **[ADR 0028 — Co-equal local-cert credential](../adr/0028-co-equal-local-cert-credential.md)**
  Design rationale, threat model, and re-open triggers for this credential.
- **[ADR 0011 — Certificate lifecycle](../adr/0011-certificate-lifecycle.md)**
  The KV-signed credential this local cert is co-equal to. Unchanged.
- **[ADR 0010 — Automation identity subject model](../adr/0010-automation-identity-subject-model.md)**
  Defines `gh-oidc-purview-data-plane`, the Entra app that holds both
  credentials.
- **[New-SelfSignedCertificate](https://learn.microsoft.com/en-us/powershell/module/pki/new-selfsignedcertificate)**
  Microsoft Learn reference for the local cert generation parameters.
- **[keyCredential resource (Microsoft Graph)](https://learn.microsoft.com/en-us/graph/api/resources/keycredential)**
  Microsoft Learn reference for the Entra `keyCredentials` array shape.
- **[Update application (Microsoft Graph)](https://learn.microsoft.com/en-us/graph/api/application-update)**
  Microsoft Learn reference for the PATCH semantics this runbook relies on.
- **[`scripts/New-LocalAutomationCertificate.ps1`](../../scripts/New-LocalAutomationCertificate.ps1)** — provisioning helper.
- **[`scripts/Get-PurviewIPPSAccessToken.ps1`](../../scripts/Get-PurviewIPPSAccessToken.ps1)** — auth-path resolver.
