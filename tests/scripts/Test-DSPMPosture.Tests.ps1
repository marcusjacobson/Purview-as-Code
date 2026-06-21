#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for scripts/Test-DSPMPosture.ps1
    (v2 §5.4 / Issue #366).

.DESCRIPTION
    Locks in the deterministic, parse-only contract of the verifier:

      1. `New-PostureReport` returns a List[object] sink.
      2. `Add-PostureRow` appends rows with Check/Status/Detail; only
         accepts Status in OK/Warn/Fail.
      3. `dspm-config.yaml` schema-validates against
         `dspm-config.schema.json`.
      4. `dspm-config.yaml` does NOT enumerate sit-catalog.yaml under
         `scope.sits.sources` (v2 §5.4 drift closure — see
         dspm-config.yaml comment block and dspm-config.schema.json
         `sits` description).

    Pattern: AST-extract helper function definitions from the script
    and evaluate them into the test scope. We deliberately do NOT
    dot-source the script — that would execute its top-level code
    and may attempt to load Exchange Online tooling.

    Reference: docs/adr/0021-dspm-content-explorer-cadence.md
    Reference: https://learn.microsoft.com/en-us/purview/dspm
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Test-DSPMPosture.ps1'
    $script:YamlPath   = Join-Path $PSScriptRoot '..' '..' 'data-plane' 'dspm' 'dspm-config.yaml'
    $script:SchemaPath = Join-Path $PSScriptRoot '..' '..' 'data-plane' 'dspm' 'dspm-config.schema.json'

    foreach ($p in @($script:ScriptPath, $script:YamlPath, $script:SchemaPath)) {
        if (-not (Test-Path $p)) { throw "Required file missing: $p" }
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        throw ("Parse errors in {0}: {1}" -f $script:ScriptPath, ($errors -join '; '))
    }

    foreach ($fname in @('New-PostureReport', 'Add-PostureRow', 'Resolve-DSPMSourceEntryName', 'Resolve-DSPMIncludedScope', 'Get-DSPMScopeCeilingStatus')) {
        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fname
            }, $true)
        if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }

    if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
        Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module 'powershell-yaml' -ErrorAction Stop
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
        ($r | Where-Object Status -EQ 'Warn').Count | Should -Be 1
        ($r | Where-Object Status -EQ 'Fail').Count | Should -Be 1
    }

    It 'rejects any Status outside OK/Warn/Fail' {
        $r = New-PostureReport
        { Add-PostureRow -Report $r -Check 'C' -Status 'Pass' -Detail 'd' } | Should -Throw
    }
}

Describe 'dspm-config.yaml schema contract' {
    It 'is valid against dspm-config.schema.json' {
        $doc = Get-Content -LiteralPath $script:YamlPath -Raw | ConvertFrom-Yaml
        $schema = Get-Content -LiteralPath $script:SchemaPath -Raw
        $json = $doc | ConvertTo-Json -Depth 10
        { $json | Test-Json -Schema $schema -ErrorAction Stop } | Should -Not -Throw
    }
}

Describe 'v2 §5.4 drift closure — scope.sits.sources excludes sit-catalog.yaml' {
    BeforeAll {
        $script:Doc = Get-Content -LiteralPath $script:YamlPath -Raw | ConvertFrom-Yaml
    }

    It 'does not enumerate sit-catalog.yaml under scope.sits.sources' {
        $sources = @($script:Doc.scope.sits.sources)
        $sources | Should -Not -Contain 'data-plane/classifications/sit-catalog.yaml'
    }

    It 'still enumerates the lab-authored classifications.yaml' {
        $sources = @($script:Doc.scope.sits.sources)
        $sources | Should -Contain 'data-plane/classifications/classifications.yaml'
    }
}

Describe 'Resolve-DSPMSourceEntryName' {
    It 'returns @() for $null doc' {
        @(Resolve-DSPMSourceEntryName -YamlDoc $null -Kind 'labels').Count | Should -Be 0
    }

    It 'reads labels by displayName' {
        $doc = @{ labels = @(@{ displayName = 'Confidential' }, @{ displayName = 'Public' }) }
        @(Resolve-DSPMSourceEntryName -YamlDoc $doc -Kind 'labels') | Should -Be @('Confidential', 'Public')
    }

    It 'reads labels under the sensitivityLabels alias' {
        $doc = @{ sensitivityLabels = @(@{ displayName = 'Internal' }) }
        @(Resolve-DSPMSourceEntryName -YamlDoc $doc -Kind 'labels') | Should -Be @('Internal')
    }

    It 'reads SITs by name across all candidate keys, deduped and sorted' {
        $doc = @{
            classifications = @(@{ name = 'CUSTOM.EmployeeId' })
            sits = @(@{ name = 'CUSTOM.EmployeeId' }, @{ name = 'CUSTOM.LabId' })
        }
        @(Resolve-DSPMSourceEntryName -YamlDoc $doc -Kind 'sits') | Should -Be @('CUSTOM.EmployeeId', 'CUSTOM.LabId')
    }

    It 'falls back from displayName to name for SITs' {
        $doc = @{ classifications = @(@{ displayName = 'CUSTOM.FallbackDisplay' }) }
        @(Resolve-DSPMSourceEntryName -YamlDoc $doc -Kind 'sits') | Should -Be @('CUSTOM.FallbackDisplay')
    }

    It 'skips blank entries' {
        $doc = @{ labels = @(@{ displayName = 'A' }, @{ displayName = '' }, @{ displayName = $null }) }
        @(Resolve-DSPMSourceEntryName -YamlDoc $doc -Kind 'labels') | Should -Be @('A')
    }
}

Describe 'Resolve-DSPMIncludedScope' {
    It "expands include='all' to every upstream name" {
        $miss = $null
        $r = Resolve-DSPMIncludedScope -Include 'all' -UpstreamNames @('A','B','C') -MissingOut ([ref]$miss)
        @($r) | Should -Be @('A','B','C')
        @($miss).Count | Should -Be 0
    }

    It 'returns the intersection when include is an explicit array' {
        $miss = $null
        $r = Resolve-DSPMIncludedScope -Include @('B','A') -UpstreamNames @('A','B','C') -MissingOut ([ref]$miss)
        @($r | Sort-Object) | Should -Be @('A','B')
        @($miss).Count | Should -Be 0
    }

    It 'reports missing entries via MissingOut' {
        $miss = $null
        $r = Resolve-DSPMIncludedScope -Include @('A','U.S. Social Security Number (SSN)') -UpstreamNames @('A','B') -MissingOut ([ref]$miss)
        @($r) | Should -Be @('A')
        @($miss) | Should -Be @('U.S. Social Security Number (SSN)')
    }

    It 'is case-insensitive on the upstream set' {
        $miss = $null
        $r = Resolve-DSPMIncludedScope -Include @('public') -UpstreamNames @('Public') -MissingOut ([ref]$miss)
        @($r) | Should -Be @('public')
        @($miss).Count | Should -Be 0
    }

    It 'returns @() for an unrecognised include shape' {
        $miss = $null
        $r = Resolve-DSPMIncludedScope -Include 42 -UpstreamNames @('A') -MissingOut ([ref]$miss)
        @($r).Count | Should -Be 0
    }
}

Describe 'Get-DSPMScopeCeilingStatus (ADR 0021 guard rail)' {
    It 'returns OK for an empty scope' {
        $r = Get-DSPMScopeCeilingStatus -EntryCount 0 -WorkloadCount 4
        $r.Status | Should -Be 'OK'
        $r.Detail | Should -Match '0 .*0 \(item, Workload\) pairs'
    }

    It 'returns OK at the 25-entry boundary' {
        (Get-DSPMScopeCeilingStatus -EntryCount 25 -WorkloadCount 4).Status | Should -Be 'OK'
    }

    It 'returns Warn one entry above the 25-entry boundary' {
        $r = Get-DSPMScopeCeilingStatus -EntryCount 26 -WorkloadCount 4
        $r.Status | Should -Be 'Warn'
        $r.Detail | Should -Match 'ADR 0021'
        $r.Detail | Should -Match 'paging-per-workload'
    }

    It 'returns Warn at the 100-entry boundary' {
        (Get-DSPMScopeCeilingStatus -EntryCount 100 -WorkloadCount 4).Status | Should -Be 'Warn'
    }

    It 'returns Fail one entry above the 100-entry boundary' {
        $r = Get-DSPMScopeCeilingStatus -EntryCount 101 -WorkloadCount 4
        $r.Status | Should -Be 'Fail'
        $r.Detail | Should -Match 'Refusing to validate'
    }

    It 'returns Fail for the pre-drift-closure 337-entry catastrophic case' {
        # 10 labels + 327 catalog SITs = 337 entries (the case
        # issue #366 closed). Must be a hard Fail going forward.
        (Get-DSPMScopeCeilingStatus -EntryCount 337 -WorkloadCount 4).Status | Should -Be 'Fail'
    }

    It 'computes the pair count as entries x workloads' {
        $r = Get-DSPMScopeCeilingStatus -EntryCount 11 -WorkloadCount 4
        $r.Detail | Should -Match '44 \(item, Workload\) pairs'
    }
}
