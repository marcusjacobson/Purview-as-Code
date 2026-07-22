#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Unit tests for scripts/Sync-SITCatalog.ps1 -- the SIT reference-catalog
    exporter and parity checker. Backfills a standing coverage gap (issue #48):
    the script had no dedicated test, only indirect ShippedDesiredState assertions.

.DESCRIPTION
    The body calls `az` and IPPS cmdlets, so it cannot be dot-sourced. These tests
    exercise the parameter-set surface via the AST and pin the contract points in
    source: the three modes (Apply / Export / Compare), the read-only Compare
    parity check and its NameDrift throw, and the removal of the stale
    "Wave 1 #65/#66/#67" / fingerprint-only-apply-path plan (superseded by
    Deploy-SITRulePackages.ps1 and ADR 0061).

    Reference: docs/adr/0061-custom-sit-rule-package-shape.md
    Reference: docs/adr/0056-template-ships-empty-desired-state.md
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Sync-SITCatalog.ps1'
    if (-not (Test-Path $script:ScriptPath)) { throw "Could not locate Sync-SITCatalog.ps1 at: $script:ScriptPath" }
    $script:SourceText = Get-Content -Raw -LiteralPath $script:ScriptPath

    $tokens = $null; $errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$tokens, [ref]$errors)
    $script:ParseErrors = $errors
    # Resolve the parameter block's ParameterAst list.
    $paramBlock = $script:Ast.ParamBlock
    if (-not $paramBlock) {
        # top-level script param() lives on the ScriptBlockAst
        $paramBlock = $script:Ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.ParamBlockAst] } | Select-Object -First 1
    }
    $script:Params = @{}
    foreach ($p in $script:Ast.ParamBlock.Parameters) {
        $sets = @($p.Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' } | ForEach-Object {
            ($_.NamedArguments | Where-Object { $_.ArgumentName -eq 'ParameterSetName' } | ForEach-Object { $_.Argument.Value })
        })
        $script:Params[$p.Name.VariablePath.UserPath] = $sets
    }
}

Describe 'Sync-SITCatalog.ps1 -- parses and has a clean parameter surface' {
    It 'parses without error' { $script:ParseErrors | Should -BeNullOrEmpty }

    It 'declares three parameter sets: Apply, Export, Compare' {
        $allSets = @($script:Params.Values | ForEach-Object { $_ } | Sort-Object -Unique)
        $allSets | Should -Contain 'Apply'
        $allSets | Should -Contain 'Export'
        $allSets | Should -Contain 'Compare'
    }

    It 'exposes -ExportCurrentState and -CompareWithTenant as distinct switches' {
        $script:Params.Keys | Should -Contain 'ExportCurrentState'
        $script:Params.Keys | Should -Contain 'CompareWithTenant'
    }

    It '-CompareWithTenant belongs only to the Compare set (mutually exclusive with Export)' {
        $script:Params['CompareWithTenant'] | Should -Be @('Compare')
        $script:Params['ExportCurrentState'] | Should -Be @('Export')
    }
}

Describe 'Compare mode -- read-only parity check (issue #48)' {
    It 'dispatches a Compare mode' {
        $script:SourceText | Should -Match "elseif \(\`$CompareWithTenant\.IsPresent\) \{ 'Compare' \}"
    }
    It 'joins catalog and tenant by GUID and emits the three parity categories' {
        $script:SourceText | Should -Match 'NameDrift'
        $script:SourceText | Should -Match 'MissingFromTenant'
        $script:SourceText | Should -Match 'NotInCatalog'
    }
    It 'throws (fails non-zero) on stable-GUID name drift' {
        $script:SourceText | Should -Match 'SIT catalog parity FAILED'
    }
    It 'runs Compare under -WhatIf (the dry-run short-circuit is Export-scoped)' {
        $script:SourceText | Should -Match "WhatIfPreference -and \`$mode -eq 'Export'"
    }
}

Describe 'Header/apply-path plan is corrected (ADR 0061, issue #48)' {
    It 'no longer cites the nonexistent Wave 1 #65/#66/#67 project-plan rows' {
        $script:SourceText | Should -Not -Match 'Wave 1 #65'
        $script:SourceText | Should -Not -Match '#65, #66, #67'
    }
    It 'points custom-SIT management at Deploy-SITRulePackages.ps1 / ADR 0061' {
        $script:SourceText | Should -Match 'Deploy-SITRulePackages\.ps1'
        $script:SourceText | Should -Match '0061-custom-sit-rule-package-shape'
    }
    It 'states the catalog has no apply path (read-only reference data)' {
        $script:SourceText | Should -Match 'no apply path'
    }
}

Describe 'Export path invariants preserved' {
    It 'still redacts a tenant-real publisher GUID to the zero GUID' {
        $script:SourceText | Should -Match '00000000-0000-0000-0000-000000000000'
    }
    It 'preserves header comments by line-splicing on the sits: key' {
        $script:SourceText | Should -Match "match '\^\\s\*sits\\s\*:'"
    }
    It 'refuses to clobber a non-empty catalog without -Force (Export only)' {
        $script:SourceText | Should -Match 'Refusing to overwrite without -Force'
    }
}
