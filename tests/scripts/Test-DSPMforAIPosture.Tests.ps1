#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for scripts/Test-DSPMforAIPosture.ps1
    (Wave 3b Phase 2 / Issue #75).

.DESCRIPTION
    Locks in the deterministic, parse-only contract of the verifier:

      1. `New-PostureReport` returns a List[object] sink.
      2. `Add-PostureRow` appends rows with Check/Status/Detail; only
         accepts Status in OK/Warn/Fail.
      3. `Get-LabelDisplayNames` returns sorted-unique displayName
         values; empty/null input yields @().
      4. `Resolve-IncludedLabels` honours include='all' and the
         array-form selector, surfacing missing names via the
         out-parameter.

    Pattern: AST-extract function definitions from the script and
    evaluate them into the test scope. We deliberately do NOT
    dot-source the script -- that would execute its top-level code
    and attempt to load Exchange Online tooling / acquire a token.

    Reference: docs/adr/0022-dspm-for-ai-authoring-surface.md
    Reference: https://learn.microsoft.com/en-us/purview/dspm-for-ai
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Test-DSPMforAIPosture.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Test-DSPMforAIPosture.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        throw ("Parse errors in {0}: {1}" -f $script:ScriptPath, ($errors -join '; '))
    }

    foreach ($fname in @('New-PostureReport', 'Add-PostureRow', 'Get-LabelDisplayName', 'Resolve-IncludedLabel')) {
        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fname
            }, $true)
        if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }
}

Describe 'New-PostureReport' {
    It 'returns an empty List[object] sink' {
        $r = New-PostureReport
        ,$r | Should -BeOfType 'System.Collections.Generic.List[object]'
        $r.Count | Should -Be 0
    }

    It 'returns distinct lists on successive calls' {
        $a = New-PostureReport
        $b = New-PostureReport
        [object]::ReferenceEquals($a, $b) | Should -BeFalse
    }
}

Describe 'Add-PostureRow' {
    It 'appends a row carrying Check / Status / Detail' {
        $r = New-PostureReport
        Add-PostureRow -Report $r -Check 'C1' -Status 'OK' -Detail 'd1'
        $r.Count | Should -Be 1
        $r[0].Check  | Should -Be 'C1'
        $r[0].Status | Should -Be 'OK'
        $r[0].Detail | Should -Be 'd1'
    }

    It 'accepts Warn and Fail' {
        $r = New-PostureReport
        Add-PostureRow -Report $r -Check 'C2' -Status 'Warn' -Detail 'd'
        Add-PostureRow -Report $r -Check 'C3' -Status 'Fail' -Detail 'd'
        $r.Count | Should -Be 2
        ($r | Where-Object Status -EQ 'Warn').Count | Should -Be 1
        ($r | Where-Object Status -EQ 'Fail').Count | Should -Be 1
    }

    It 'rejects any Status outside OK/Warn/Fail' {
        $r = New-PostureReport
        { Add-PostureRow -Report $r -Check 'C' -Status 'Pass' -Detail 'd' } | Should -Throw
    }
}

Describe 'Get-LabelDisplayName' {
    It 'returns @() for $null input' {
        @(Get-LabelDisplayName -YamlDoc $null).Count | Should -Be 0
    }

    It 'returns @() for a doc without a labels key' {
        @(Get-LabelDisplayName -YamlDoc @{ other = 'x' }).Count | Should -Be 0
    }

    It 'returns @() for a doc whose labels list is empty' {
        @(Get-LabelDisplayName -YamlDoc @{ labels = @() }).Count | Should -Be 0
    }

    It 'returns sorted-unique displayName values, skipping blanks' {
        $doc = @{
            labels = @(
                @{ displayName = 'Confidential' }
                @{ displayName = 'Public' }
                @{ displayName = 'Confidential' }
                @{ displayName = '' }
                @{ name        = 'Internal' }
                @{ displayName = 'Internal' }
            )
        }
        $names = @(Get-LabelDisplayName -YamlDoc $doc)
        $names | Should -Be @('Confidential', 'Internal', 'Public')
    }
}

Describe 'Resolve-IncludedLabel' {
    It "expands include='all' to every upstream name" {
        $miss = $null
        $r = Resolve-IncludedLabel -Include 'all' -UpstreamNames @('A', 'B', 'C') -MissingOut ([ref]$miss)
        @($r) | Should -Be @('A', 'B', 'C')
        @($miss).Count | Should -Be 0
    }

    It 'returns the intersection when include is an explicit array' {
        $miss = $null
        $r = Resolve-IncludedLabel -Include @('B', 'A') -UpstreamNames @('A', 'B', 'C') -MissingOut ([ref]$miss)
        @($r | Sort-Object) | Should -Be @('A', 'B')
        @($miss).Count | Should -Be 0
    }

    It 'reports missing entries via MissingOut' {
        $miss = $null
        $r = Resolve-IncludedLabel -Include @('A', 'Zeta') -UpstreamNames @('A', 'B') -MissingOut ([ref]$miss)
        @($r) | Should -Be @('A')
        @($miss) | Should -Be @('Zeta')
    }

    It 'is case-insensitive on the upstream set' {
        $miss = $null
        $r = Resolve-IncludedLabel -Include @('public') -UpstreamNames @('Public') -MissingOut ([ref]$miss)
        @($r) | Should -Be @('public')
        @($miss).Count | Should -Be 0
    }

    It 'returns @() for an unrecognised include shape' {
        $miss = $null
        $r = Resolve-IncludedLabel -Include 42 -UpstreamNames @('A') -MissingOut ([ref]$miss)
        @($r).Count | Should -Be 0
    }
}
