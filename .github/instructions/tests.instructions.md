---
description: "Conventions for PowerShell Pester unit tests under tests/."
applyTo: "tests/**/*.ps1"
---

# Pester unit-test rules

Extends [`.github/copilot-instructions.md`](../copilot-instructions.md) and [`powershell.instructions.md`](powershell.instructions.md). Applies to every test file under `tests/`.

## File layout

- **`tests/scripts/<ScriptName>.Tests.ps1`** — one `*.Tests.ps1` per script under test. These are **fixture-based**: they build their own in-memory input and assert against it. This is the bulk of the suite.
- **`tests/data-plane/<Topic>.Tests.ps1`** — **guard tests that read the SHIPPED `data-plane/**` YAMLs** rather than a fixture. Added by [ADR 0055](../../docs/adr/0055-identifier-shaped-residual-scan.md).
- Test discovery is driven by [`tests/Run-Pester.ps1`](../../tests/Run-Pester.ps1) (which walks all of `tests/`); do not invoke `Invoke-Pester` directly with ad-hoc paths.

### When to write a `tests/data-plane/` guard test instead of a fixture test

**When the hazard is in the DATA, the test must read the DATA.** A fixture test is structurally blind to a defect in a shipped artefact, however thorough it is.

ADR 0055 is the worked example. [`Deploy-PurviewRoleGroups.Tests.ps1`](../../tests/scripts/Deploy-PurviewRoleGroups.Tests.ps1) has ~20 `It` blocks and pins revoke-everything-on-empty-members as a required contract — and the shipped `role-groups.yaml` carried ~50 `members: []` rows *and* 15 real Entra group object IDs into a public repo anyway. The reconciler was correct. Its fixtures were correct. Nothing read the file.

Write a guard test under `tests/data-plane/` when a property of a **committed** desired-state file is load-bearing for safety or privacy — e.g. "the privileged root lists ship empty", "no raw principal object ID appears under any principal key" ([ADR 0023](../../docs/adr/0023-identifier-resolution.md) Category 3).

**Template awareness:** this repo is a tenant-neutral template ([ADR 0045](../../docs/adr/0045-template-kickoff-spinoff-model.md)). A guard test asserting a **shipped-empty default** is a *template* assertion and will fail in a tailored spin-off that legitimately adopts the solution — say so in the test, and keep the assertions that must hold in **every** copy (no raw identifiers, ever) in a separate `Describe` block.

## Pester version

- Pin the minimum acceptable Pester version in [`tests/Run-Pester.ps1`](../../tests/Run-Pester.ps1) (`-PesterMinimumVersion`). Tests may rely on the documented `5.x` API.
- Do not float the minimum to "whatever is latest". Bump the value in the same PR that introduces a test requiring a newer feature.

## No live tenant, no live subscription

Tests must not:

- Call `Connect-IPPSSession`, `Connect-ExchangeOnline`, `Connect-AzAccount`, `Connect-Graph`, or any other connection cmdlet.
- Call any cmdlet from `ExchangeOnlineManagement`, `Az.*`, `Microsoft.Graph.*`, or `MicrosoftTeams` against a real subscription.
- Read from Azure Key Vault, environment variables that hold real identifiers, or any path under `~/.azure/`.

Live-tenant assertions belong in PR-time lab-smoke evidence (pasted into the PR body under "Validation evidence"), never in `tests/`.

## Function-under-test extraction pattern

The production scripts (`scripts/Deploy-*.ps1`) execute top-level code at import time -- dot-sourcing one would attempt to load `ExchangeOnlineManagement` and connect to a tenant. Extract just the function under test:

```pwsh
BeforeAll {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot ".." ".." "scripts" "<Script>.ps1"),
        [ref]$tokens, [ref]$errors)

    $fnAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "<Function>"
    }, $true)

    # Stub any script-scoped variables or sibling functions the
    # extracted function references.
    $script:SomeAllowlist = @()
    function Some-Helper { param($x) $x }

    . ([ScriptBlock]::Create($fnAst.Extent.Text))
}
```

See [`Deploy-LabelPolicies.Tests.ps1`](../../tests/scripts/Deploy-LabelPolicies.Tests.ps1) for the worked example.

## Synthetic identifiers only

Any GUID, principal ID, label ID, or tenant ID a test needs must use the documented placeholder pattern. Recommended: `00000000-0000-0000-0000-0000000000NN` where `NN` is a per-test-case sequence number (`01`, `02`, ...). Real tenant identifiers are forbidden per the "Environment and identifier boundaries" section of [`copilot-instructions.md`](../copilot-instructions.md).

## Lint clean

- `Invoke-ScriptAnalyzer -Path tests/ -Recurse -Severity Warning` must produce no output.
- `tests/**` files honor the same secrets-scan as `scripts/**` (see [`pre-commit.instructions.md`](pre-commit.instructions.md)).

## CI integration

- The `pester` job in [`validate.yml`](../workflows/validate.yml) runs on `windows-latest` (PowerShell 7.4+ via `shell: pwsh`).
- Results are uploaded as the `pester-results` artifact (`tests/results/pester.xml`, JUnit XML).
- A failed test fails the workflow; do not catch `Invoke-Pester` errors to keep CI green.

## Reference

- [Pester quick start](https://pester.dev/docs/quick-start)
- [`about_classes` -- PowerShell parser AST](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_classes)
