# Tests

PowerShell unit tests for `scripts/**` helpers. Uses [Pester 5.x](https://pester.dev/docs/quick-start).

## Layout

```text
tests/
  Run-Pester.ps1                       # Entry point (installs Pester ≥5.5.0, runs suite, writes JUnit XML)
  README.md                            # This file
  results/                             # Generated test output (gitignored)
  scripts/                             # One *.Tests.ps1 per script under test
    Deploy-LabelPolicies.Tests.ps1     # Worked example
```

## Run locally

```pwsh
./tests/Run-Pester.ps1
```

Test results land in `tests/results/pester.xml` (JUnit XML).

## Conventions

- **No live tenant.** Tests must never call `Connect-IPPSSession`, `Connect-AzAccount`, or any cmdlet from `ExchangeOnlineManagement` / `Az.*` against a real subscription. Live assertions belong in PR-time lab-smoke evidence, not here.
- **No script execution.** The production scripts (`scripts/Deploy-*.ps1`) execute top-level code at import time. Tests AST-extract the function under test via `[System.Management.Automation.Language.Parser]::ParseFile()` and evaluate just the `FunctionDefinitionAst.Extent.Text` into the test scope. See `Deploy-LabelPolicies.Tests.ps1` for the pattern. This keeps production scripts untouched.
- **Stub script-scoped dependencies.** If the function references `$script:Foo` or calls a sibling function defined elsewhere in the script, stub those in the `BeforeAll` block rather than evaluating more of the script.
- **Synthetic identifiers only.** Use the zero-GUID placeholder pattern (`00000000-0000-0000-0000-0000000000NN`) for any label, policy, or principal GUID a test needs. Real tenant identifiers are forbidden per `.github/copilot-instructions.md` "Environment and identifier boundaries".

## Pester version pin

`tests/Run-Pester.ps1` enforces `Pester >= 5.5.0`. Bump deliberately, not opportunistically. The CI job in `.github/workflows/validate.yml` honors the same minimum.

## References

- [Pester quick start](https://pester.dev/docs/quick-start)
- [`about_classes` — PowerShell parser AST](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_classes)
- [`Install-Module`](https://learn.microsoft.com/en-us/powershell/module/powershellget/install-module)
