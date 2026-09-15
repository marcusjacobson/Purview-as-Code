#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    THE GUARD TEST THAT WOULD ACTUALLY HAVE CAUGHT #225.

    `sync-labels-from-tenant.yml` exports `labels.yaml` unconditionally with
    `-RedactIdentities`. `Deploy-Labels.ps1`'s `Compare-LabelHash` mitigates the
    resulting placeholder-vs-real-tenant mismatch with an opaque-comparison path:
    when EVERY desired `encryption.rightsDefinitions[].Identity` matches the
    redaction pattern, it compares by count + sorted `Rights` instead of by
    identity, and declares no drift. That mitigation is all-or-nothing — one
    real identity in the committed file disables it, and every scheduled sync
    on that branch drifts back forever (issue #225).

    Nothing in tests/scripts/Deploy-Labels.Tests.ps1 reads the actual committed
    `data-plane/information-protection/labels.yaml`; it unit-tests the
    reconciler's functions against synthetic fixtures. So a real identity could
    land in the committed file — by a manual edit, or a future export change —
    and every existing test would stay green while the scheduled sync silently
    started drifting back again. This file closes that gap by asserting a
    property of the SHIPPED artefact itself, the same lineage as
    ShippedDesiredState.Tests.ps1's ADR 0055/0056 guards.

    CLAIM 1 (the fix holds). Every `Identity` committed under
    `data-plane/information-protection/labels.yaml`'s `encryption.rightsDefinitions`
    matches the redaction pattern `Deploy-Labels.ps1` checks for.
    CLAIM 2 (the check has teeth). A real identity string does NOT match the
    pattern — proving CLAIM 1 is not vacuously true for any input.

    Branch-aware per ADR 0057: `main` ships `labels.yaml` empty (ADR 0056), so
    there is nothing to check there — the assertion skips cleanly rather than
    passing vacuously on zero entries. `dev` and `lab` carry populated files and
    are exactly the branches issue #225 was found on.

    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-label
    Reference: https://pester.dev/docs/quick-start
#>

BeforeDiscovery {
    $script:TargetBranch = $null
    if ($env:GITHUB_BASE_REF) { $script:TargetBranch = $env:GITHUB_BASE_REF }
    elseif ($env:GITHUB_REF_NAME) { $script:TargetBranch = $env:GITHUB_REF_NAME }
    else {
        try {
            $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
            $script:TargetBranch = [string](& git -C $repoRoot rev-parse --abbrev-ref HEAD 2>$null)
        }
        catch { $script:TargetBranch = $null }
    }
    if (-not $script:TargetBranch) { $script:TargetBranch = 'main' }
    $script:IsOperatorBranch = $script:TargetBranch.Trim() -in @('dev', 'lab')
}

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    Import-Module 'powershell-yaml' -ErrorAction Stop

    # Same literal as `$script:RedactedIdentityPattern` in
    # scripts/Deploy-Labels.ps1 (and stubbed identically in
    # tests/scripts/Deploy-Labels.Tests.ps1) — both need to recognize the
    # same synthetic placeholders for the mitigation and this guard to agree.
    $script:RedactedIdentityPattern = '(?i)@(contoso|fabrikam|adatum)\.com$|@example\.(com|org)$'

    # Well-known SYMBOLIC identities are a legitimate THIRD category, neither
    # a real principal nor a redacted placeholder: they are Microsoft
    # rights-management constants (the content owner; any authenticated user)
    # that are identical in every tenant and carry no tenant information.
    # -RedactIdentities preserves them verbatim (issue #225), so this guard
    # must accept them -- the first revision of this file did not, and failed
    # the moment dev's real IPC_USER_ID_OWNER entry was committed.
    #
    # Read the allow-list out of production source rather than restating it,
    # so the two cannot silently diverge.
    $script:LabelsScriptPath = Join-Path $script:RepoRoot 'scripts' 'Deploy-Labels.ps1'
    $symbolicBlock = [regex]::Match(
        (Get-Content -LiteralPath $script:LabelsScriptPath -Raw),
        '\$script:WellKnownSymbolicIdentities\s*=\s*@\(([^)]*)\)')
    $script:WellKnownSymbolicIdentities = @(
        [regex]::Matches($symbolicBlock.Groups[1].Value, "'([^']+)'") |
            ForEach-Object { $_.Groups[1].Value })

    $script:LabelsYamlPath = Join-Path $script:RepoRoot 'data-plane' 'information-protection' 'labels.yaml'
    if (-not (Test-Path -LiteralPath $script:LabelsYamlPath)) {
        throw "labels.yaml not found at: $script:LabelsYamlPath"
    }

    function Get-CommittedRightsIdentity {
        $yaml = (Get-Content -LiteralPath $script:LabelsYamlPath -Raw) | ConvertFrom-Yaml
        $identities = [System.Collections.Generic.List[string]]::new()
        foreach ($label in @($yaml.labels)) {
            $rights = $label.encryption.rightsDefinitions
            if (-not $rights) { continue }
            foreach ($rd in @($rights)) {
                if ($rd.Identity) { $identities.Add([string]$rd.Identity) }
            }
        }
        return $identities
    }
    $script:GetCommittedRightsIdentity = ${function:Get-CommittedRightsIdentity}
}

Describe 'Committed labels.yaml encryption identities stay redacted (issue #225)' {

    It 'CLAIM 2 — the redaction pattern rejects a tenant-qualified identity (the check has teeth)' {
        'owner@contoso-dev.cloud' | Should -Not -Match $script:RedactedIdentityPattern
        'allcompany@contoso.onmicrosoft.com' | Should -Not -Match $script:RedactedIdentityPattern
    }

    It 'CLAIM 2 — the redaction pattern accepts the synthetic placeholder' {
        'user@contoso.com' | Should -Match $script:RedactedIdentityPattern
    }

    It 'CLAIM 1 — every committed encryption.rightsDefinitions[].Identity is a redacted placeholder or a well-known symbolic identity, never a real principal' {
        $identities = Get-CommittedRightsIdentity
        if (-not $script:IsOperatorBranch -and $identities.Count -eq 0) {
            Set-ItResult -Skipped -Because ("branch '{0}' ships labels.yaml empty (ADR 0056); nothing to check" -f $script:TargetBranch)
            return
        }
        if ($script:IsOperatorBranch) {
            # Non-vacuity: dev/lab are exactly the branches issue #225 was found
            # on, and both carry populated encryption sections. A zero-count
            # result here would mean this test stopped checking anything.
            $identities.Count | Should -BeGreaterThan 0 -Because 'dev/lab carry populated rightsDefinitions; a zero count means this check is reading the wrong file or the fixture regressed'
        }
        foreach ($identity in $identities) {
            $isRedacted = $identity -match $script:RedactedIdentityPattern
            $isSymbolic = $script:WellKnownSymbolicIdentities -contains $identity
            ($isRedacted -or $isSymbolic) | Should -BeTrue -Because ("'{0}' is neither a redacted placeholder nor a well-known symbolic identity, so it is a real principal committed under labels.yaml; export with -RedactIdentities before committing (issue #225)" -f $identity)
        }
    }

    It 'CLAIM 2 — the symbolic allow-list parses out of production source and never acquits a principal' {
        # Non-vacuity in both directions. If the regex stopped matching, the
        # list would silently empty and CLAIM 1 would tighten (noisy, safe);
        # if it over-matched it would gut the guard (quiet, unsafe). Pin both.
        $script:WellKnownSymbolicIdentities.Count | Should -BeGreaterThan 0 -Because 'the allow-list must parse out of Deploy-Labels.ps1, or this guard silently stops accepting the symbolic identities the exporter now preserves'
        $script:WellKnownSymbolicIdentities | Should -Contain 'IPC_USER_ID_OWNER' -Because 'this is the value the dev tenant actually returns for the A1 admin-pre-assigned fixture label'
        $script:WellKnownSymbolicIdentities | Should -Not -Contain 'owner@contoso-dev.cloud' -Because 'the allow-list must never acquit a real principal'
        foreach ($symbolic in $script:WellKnownSymbolicIdentities) {
            # A service constant is not addressable. Anything carrying an @ is
            # a UPN or SMTP address and belongs in the redaction path instead.
            $symbolic | Should -Not -Match '@' -Because ("'{0}' looks like a principal, not a rights-management constant" -f $symbolic)
        }
    }
}
