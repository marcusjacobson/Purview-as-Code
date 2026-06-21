## Summary

<!-- One or two sentences. Name the plane (control / data / ci / docs) and the outcome. -->

## Plane and scope

- [ ] `infra/**` (control plane, Bicep)
- [ ] `data-plane/**` (data plane, YAML)
- [ ] `scripts/**` (data-plane apply logic)
- [ ] `.github/workflows/**` (CI/CD)
- [ ] `docs/**` or `README.md` (documentation)

<!-- If more than one box is ticked, explain why this PR spans planes. -->

## Change detail

<!--
One bullet per logical change. Every bullet that introduces a new resource, cmdlet, `az` command, REST endpoint, or action version must end with a Microsoft Learn citation.
Example:
- Add `Microsoft.Purview/accounts/privateEndpointConnections` ([Microsoft.Purview/accounts — privateEndpointConnections](https://learn.microsoft.com/en-us/azure/templates/microsoft.purview/accounts/privateendpointconnections))
-->

## Validation evidence

<!-- Paste fenced command output. See .github/copilot-instructions.md "Pre-commit checklist". -->

```text
<paste output here>
```

## Security review

- [ ] No secrets, keys, tokens, or real tenant/subscription/object IDs in the diff
- [ ] New identities use managed identity or OIDC federated credentials (no stored client secrets)
- [ ] Any `publicNetworkAccess: 'Enabled'` is justified below with a Learn citation
- [ ] Role assignments are scoped to the narrowest resource that works

<!-- Justifications, if any, go here. -->

## Rollback plan

<!-- One or two sentences. For data-plane PRs, describe the reverse operation. -->

## Destructive change?

- [ ] This PR deletes or prunes existing state (collection, term, classification, data source, scan, policy, role assignment)
- [ ] If ticked: PR is labeled `destructive` and a qualified reviewer has approved
