#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for the regex-safety validator, hashing helpers,
    and round-trip determinism of `scripts/Deploy-Classifications.ps1`.

.DESCRIPTION
    Issue #635 — Phase 1+2 reconciler per ADR 0026.

    Tests cover:
      - Regex-safety validator (anchored / bounded / no nested
        unbounded quantifier) per
        `.github/instructions/sample-data.instructions.md` §"Regex
        rules for classification patterns".
      - Per-rule validator (`Test-RuleRegexSafety`) including
        non-Regex `kind` rejection.
      - `ConvertTo-DesiredTypeHash` / `ConvertTo-DesiredRuleHash`
        validation including the orphan-name case.
      - `Get-RuleProperty` flattening of tenant `properties` wrapping.
      - `Compare-TypeHash` / `Compare-RuleHash` drift detection.
      - System-type filter (`Test-IsSystemType`) for the `MICROSOFT.*`
        prefix.

    The production script is a non-module that performs auth at
    import time, so we AST-extract the helper definitions and
    evaluate them into the test scope. Same pattern as
    `Deploy-Glossary.Tests.ps1`.

    Reference: https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/type
    Reference: https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/classification-rules
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-Classifications.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Deploy-Classifications.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)

    foreach ($fnName in @(
            'Test-RegexSafetyViolation',
            'Test-RuleRegexSafety',
            'Test-IsSystemType',
            'ConvertTo-CanonicalValue',
            'ConvertTo-ComparableJson',
            'ConvertTo-DesiredTypeHash',
            'ConvertTo-DesiredRuleHash',
            'ConvertTo-TenantTypeHash',
            'ConvertTo-TenantRuleHash',
            'Compare-TypeHash',
            'Compare-RuleHash',
            'Get-RuleProperty')) {

        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fnName
            }, $true)

        if (-not $fnAst) {
            throw "Function $fnName not found in $script:ScriptPath"
        }

        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }

    # Mirror script-scope state so AST-extracted functions behave the
    # same as in the production script.
    $script:SystemTypeNamePrefixes = @('MICROSOFT.')
    $script:TypeComputedFields = @(
        'guid', 'createTime', 'createdBy', 'updateTime', 'updatedBy',
        'version', 'typeVersion', 'lastModifiedTS',
        'serviceType', 'subTypes', 'options',
        'attributeDefs', 'superTypes', 'entityTypes'
    )
    $script:TypeYamlOnlyFields = @('category')
}

Describe 'Test-RegexSafetyViolation' {
    It 'accepts an anchored bounded pattern' {
        $v = Test-RegexSafetyViolation -Pattern '\bEMP-\d{4}\b' -Context 'unit'
        $v | Should -BeNullOrEmpty
    }

    It 'accepts an anchored pattern with bounded character-class repetition' {
        $v = Test-RegexSafetyViolation -Pattern '^[A-Z]{3}-\d{2,5}$' -Context 'unit'
        $v | Should -BeNullOrEmpty
    }

    It 'accepts an inline-flag prefix followed by anchors' {
        $v = Test-RegexSafetyViolation -Pattern '(?i)\bemployee[_\s-]{0,3}id\b' -Context 'unit'
        $v | Should -BeNullOrEmpty
    }

    It 'rejects an unanchored pattern' {
        $v = Test-RegexSafetyViolation -Pattern 'EMP-\d{4}' -Context 'unit'
        $v | Should -Not -BeNullOrEmpty
        ($v -join ' ') | Should -Match 'no \^'
    }

    It 'rejects an unanchored pattern with unbounded ".*"' {
        $v = Test-RegexSafetyViolation -Pattern '.*employee.*id.*' -Context 'unit'
        $v | Should -Not -BeNullOrEmpty
        ($v -join ' ') | Should -Match 'unanchored AND contains unbounded'
    }

    It 'rejects nested unbounded quantifier (x+)+' {
        $v = Test-RegexSafetyViolation -Pattern '^(a+)+$' -Context 'unit'
        $v | Should -Not -BeNullOrEmpty
        ($v -join ' ') | Should -Match 'nested unbounded quantifier'
    }

    It 'rejects nested unbounded quantifier (.*)+' {
        $v = Test-RegexSafetyViolation -Pattern '^(.*)+$' -Context 'unit'
        $v | Should -Not -BeNullOrEmpty
        ($v -join ' ') | Should -Match 'nested unbounded quantifier'
    }

    It 'rejects an empty pattern' {
        $v = Test-RegexSafetyViolation -Pattern '' -Context 'unit'
        $v | Should -Not -BeNullOrEmpty
        ($v -join ' ') | Should -Match 'empty'
    }
}

Describe 'Test-RuleRegexSafety' {
    It 'accepts the YAML scaffold rule unchanged' {
        $rule = @{
            name = 'CUSTOM.EmployeeIdRule'
            kind = 'Regex'
            classificationName = 'CUSTOM.EmployeeId'
            regex = @{ pattern = '\bEMP-\d{4}\b'; regexFlags = @{ ignoreCase = $true } }
            columnPatterns = @(@{ kind = 'Regex'; pattern = '(?i)\bemployee[_\s-]{0,3}id\b' })
        }
        $v = Test-RuleRegexSafety -Rule $rule
        $v | Should -BeNullOrEmpty
    }

    It 'rejects a rule whose row-level pattern is unanchored and unbounded' {
        $rule = @{
            name = 'Bad.Rule'
            kind = 'Regex'
            classificationName = 'CUSTOM.X'
            regex = @{ pattern = '.*foo.*' }
        }
        $v = Test-RuleRegexSafety -Rule $rule
        $v | Should -Not -BeNullOrEmpty
        ($v -join ' ') | Should -Match 'unanchored AND contains unbounded'
    }

    It 'rejects a rule whose columnPatterns entry is unsafe' {
        $rule = @{
            name = 'Bad.Cols'
            kind = 'Regex'
            classificationName = 'CUSTOM.X'
            regex = @{ pattern = '\bok\b' }
            columnPatterns = @(@{ kind = 'Regex'; pattern = '.*employee.*id.*' })
        }
        $v = Test-RuleRegexSafety -Rule $rule
        $v | Should -Not -BeNullOrEmpty
        ($v -join ' ') | Should -Match 'columnPatterns\[0\]'
    }

    It 'rejects a non-Regex rule kind (Phase 1+2 supports Regex only)' {
        $rule = @{
            name = 'SIT.Bridge'
            kind = 'SensitiveInformationType'
            classificationName = 'CUSTOM.X'
        }
        $v = Test-RuleRegexSafety -Rule $rule
        $v | Should -Not -BeNullOrEmpty
        ($v -join ' ') | Should -Match "kind 'SensitiveInformationType' is not supported"
    }

    It 'rejects a Regex rule missing the regex block' {
        $rule = @{ name = 'NoRegex'; kind = 'Regex'; classificationName = 'CUSTOM.X' }
        $v = Test-RuleRegexSafety -Rule $rule
        ($v -join ' ') | Should -Match "missing required block 'regex'"
    }
}

Describe 'Test-IsSystemType' {
    It 'classifies MICROSOFT.* prefix as system' {
        Test-IsSystemType -Name 'MICROSOFT.GOVERNMENT.US.SSN' | Should -BeTrue
    }

    It 'classifies operator-authored names as non-system' {
        Test-IsSystemType -Name 'CUSTOM.EmployeeId' | Should -BeFalse
        Test-IsSystemType -Name 'test'              | Should -BeFalse
    }
}

Describe 'ConvertTo-DesiredTypeHash (validation)' {
    It 'accepts the YAML scaffold shape' {
        $h = ConvertTo-DesiredTypeHash -Type @{ name = 'CUSTOM.EmployeeId'; description = 'Internal id.' }
        $h.name        | Should -Be 'CUSTOM.EmployeeId'
        $h.description | Should -Be 'Internal id.'
    }

    It 'throws when name is missing' {
        { ConvertTo-DesiredTypeHash -Type @{ description = 'oops' } } |
            Should -Throw -ExpectedMessage "*missing required field 'name'*"
    }

    It 'ignores YAML-only `category` field' {
        $h = ConvertTo-DesiredTypeHash -Type @{ name = 'CUSTOM.X'; category = 'Custom' }
        $h.ContainsKey('category') | Should -BeFalse
    }
}

Describe 'ConvertTo-DesiredRuleHash (validation)' {
    It 'fills defaults (kind, ruleStatus, minimumPercentageMatch)' {
        $h = ConvertTo-DesiredRuleHash -Rule @{
            name = 'R1'
            classificationName = 'CUSTOM.X'
            regex = @{ pattern = '\bx\b' }
        }
        $h.kind                   | Should -Be 'Regex'
        $h.ruleStatus             | Should -Be 'Enabled'
        $h.minimumPercentageMatch | Should -Be 60
    }

    It 'throws when classificationName is missing' {
        {
            ConvertTo-DesiredRuleHash -Rule @{ name = 'R'; regex = @{ pattern = '\bx\b' } }
        } | Should -Throw -ExpectedMessage "*missing required field 'classificationName'*"
    }
}

Describe 'Get-RuleProperty (tenant shape flattening)' {
    It 'flattens a `properties`-wrapped tenant rule' {
        $raw = @{
            name = 'R1'
            kind = 'Regex'
            properties = @{
                classificationName = 'CUSTOM.X'
                ruleStatus = 'Enabled'
                minimumPercentageMatch = 60
            }
        }
        $props = Get-RuleProperty -Raw $raw
        $props.classificationName     | Should -Be 'CUSTOM.X'
        $props.minimumPercentageMatch | Should -Be 60
    }

    It 'passes through a flat hashtable unchanged' {
        $flat = @{ classificationName = 'CUSTOM.X'; ruleStatus = 'Enabled' }
        $props = Get-RuleProperty -Raw $flat
        $props.classificationName | Should -Be 'CUSTOM.X'
    }
}

Describe 'Compare-TypeHash (drift detection)' {
    It 'returns no diffs when name + description match' {
        $d = @{ name = 'CUSTOM.X'; description = 'Same.' }
        $t = @{ name = 'CUSTOM.X'; description = 'Same.' }
        Compare-TypeHash -Desired $d -Tenant $t | Should -BeNullOrEmpty
    }

    It 'surfaces drift on description' {
        $d = @{ name = 'CUSTOM.X'; description = 'New.' }
        $t = @{ name = 'CUSTOM.X'; description = 'Old.' }
        $diffs = Compare-TypeHash -Desired $d -Tenant $t
        $diffs | Should -Contain 'description'
    }

    It 'treats absent description on both sides as no drift' {
        $d = @{ name = 'CUSTOM.X' }
        $t = @{ name = 'CUSTOM.X' }
        Compare-TypeHash -Desired $d -Tenant $t | Should -BeNullOrEmpty
    }
}

Describe 'Compare-RuleHash (drift detection)' {
    It 'returns no diffs when desired matches tenant exactly' {
        $body = @{
            name = 'R1'; kind = 'Regex'; classificationName = 'CUSTOM.X'
            ruleStatus = 'Enabled'; minimumPercentageMatch = 60
            regex = @{ pattern = '\bx\b'; regexFlags = @{ ignoreCase = $true } }
            columnPatterns = @(@{ kind = 'Regex'; pattern = '\bcol\b' })
        }
        $clone = ($body | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable)
        Compare-RuleHash -Desired $body -Tenant $clone | Should -BeNullOrEmpty
    }

    It 'surfaces drift on minimumPercentageMatch' {
        $d = @{ name = 'R1'; kind = 'Regex'; classificationName = 'CUSTOM.X'; ruleStatus = 'Enabled'; minimumPercentageMatch = 80 }
        $t = @{ name = 'R1'; kind = 'Regex'; classificationName = 'CUSTOM.X'; ruleStatus = 'Enabled'; minimumPercentageMatch = 60 }
        $diffs = Compare-RuleHash -Desired $d -Tenant $t
        $diffs | Should -Contain 'minimumPercentageMatch'
    }

    It 'surfaces drift on regex.pattern' {
        $d = @{ name = 'R1'; kind = 'Regex'; classificationName = 'CUSTOM.X'; ruleStatus = 'Enabled'; minimumPercentageMatch = 60; regex = @{ pattern = '\bnew\b' } }
        $t = @{ name = 'R1'; kind = 'Regex'; classificationName = 'CUSTOM.X'; ruleStatus = 'Enabled'; minimumPercentageMatch = 60; regex = @{ pattern = '\bold\b' } }
        $diffs = Compare-RuleHash -Desired $d -Tenant $t
        $diffs | Should -Contain 'regex'
    }

    It 'surfaces drift on classificationName (foreign-key change)' {
        $d = @{ name = 'R1'; kind = 'Regex'; classificationName = 'CUSTOM.New'; ruleStatus = 'Enabled'; minimumPercentageMatch = 60 }
        $t = @{ name = 'R1'; kind = 'Regex'; classificationName = 'CUSTOM.Old'; ruleStatus = 'Enabled'; minimumPercentageMatch = 60 }
        $diffs = Compare-RuleHash -Desired $d -Tenant $t
        $diffs | Should -Contain 'classificationName'
    }
}

Describe 'ConvertTo-TenantTypeHash (strip computed + YAML-only fields)' {
    It 'strips server-computed identity, timestamps, and YAML-only fields' {
        $raw = @{
            guid = '00000000-0000-0000-0000-000000000000'
            createTime = 1700000000000
            createdBy = 'ServiceAdmin'
            updatedBy = 'ServiceAdmin'
            version = 2
            attributeDefs = @()
            superTypes = @()
            category = 'CLASSIFICATION'
            name = 'CUSTOM.X'
            description = 'Same.'
        }
        $h = ConvertTo-TenantTypeHash -Type $raw
        $h.Keys | Should -Not -Contain 'guid'
        $h.Keys | Should -Not -Contain 'createTime'
        $h.Keys | Should -Not -Contain 'updatedBy'
        $h.Keys | Should -Not -Contain 'attributeDefs'
        $h.Keys | Should -Not -Contain 'superTypes'
        $h.Keys | Should -Not -Contain 'category'
        $h.name        | Should -Be 'CUSTOM.X'
        $h.description | Should -Be 'Same.'
    }
}

Describe 'Round-trip determinism (Tenant strip → desired compare)' {
    It 'a freshly-imported YAML triggers no Update rows against the same tenant payload' {
        $tenantRaw = @{
            guid = '00000000-0000-0000-0000-000000000000'
            createTime = 1700000000000
            updatedBy = 'ServiceAdmin'
            category = 'CLASSIFICATION'
            attributeDefs = @()
            superTypes = @()
            name = 'CUSTOM.EmployeeId'
            description = 'Internal employee identifier (EMP-####).'
        }
        $tenantH  = ConvertTo-TenantTypeHash -Type $tenantRaw
        $desiredH = ConvertTo-DesiredTypeHash -Type @{
            name = 'CUSTOM.EmployeeId'
            description = 'Internal employee identifier (EMP-####).'
        }
        Compare-TypeHash -Desired $desiredH -Tenant $tenantH | Should -BeNullOrEmpty
    }

    It 'a freshly-imported rule YAML triggers no Update rows against the same tenant payload' {
        $tenantRaw = @{
            name = 'CUSTOM.EmployeeIdRule'
            kind = 'Regex'
            properties = @{
                classificationName = 'CUSTOM.EmployeeId'
                ruleStatus = 'Enabled'
                minimumPercentageMatch = 60
                regex = @{ pattern = '\bEMP-\d{4}\b'; regexFlags = @{ ignoreCase = $true } }
                columnPatterns = @(@{ kind = 'Regex'; pattern = '(?i)\bemployee[_\s-]{0,3}id\b' })
            }
        }
        $tenantH  = ConvertTo-TenantRuleHash -Rule $tenantRaw
        $desiredH = ConvertTo-DesiredRuleHash -Rule @{
            name = 'CUSTOM.EmployeeIdRule'
            classificationName = 'CUSTOM.EmployeeId'
            ruleStatus = 'Enabled'
            kind = 'Regex'
            minimumPercentageMatch = 60
            regex = @{ pattern = '\bEMP-\d{4}\b'; regexFlags = @{ ignoreCase = $true } }
            columnPatterns = @(@{ kind = 'Regex'; pattern = '(?i)\bemployee[_\s-]{0,3}id\b' })
        }
        Compare-RuleHash -Desired $desiredH -Tenant $tenantH | Should -BeNullOrEmpty
    }
}


# ---------------------------------------------------------------------------
# ADR 0053 -- the foreign-author override is split out of -Force into its own
# switch, -OverwriteForeignAuthor.
#
# This is a Mechanism A script: before ADR 0053, Test-ConflictRow opened with
# `if ($ForceEnabled) { return $false }` and was called with
# `-ForceEnabled $Force.IsPresent`, so a -Force run SUPPRESSED the Conflict
# classification entirely and silently overwrote the portal-authored object as
# a plain Update. These tests pin the corrected contract:
#
#   * -Force alone            => Conflict row IS emitted, object NOT overwritten.
#   * -OverwriteForeignAuthor => overwrite permitted, Conflict row still emitted.
#   * the switch lives in the Apply parameter set only.
#
# Reference: docs/adr/0053-overwrite-foreign-author-switch.md
# ---------------------------------------------------------------------------
Describe 'ADR 0053 -- -OverwriteForeignAuthor (Deploy-Classifications.ps1)' {

    BeforeAll {
        $script:Adr0053Path = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-Classifications.ps1'
        if (-not (Test-Path $script:Adr0053Path)) {
            throw "Could not locate Deploy-Classifications.ps1 at: $script:Adr0053Path"
        }
        $script:Adr0053Source = Get-Content -Path $script:Adr0053Path -Raw

        $adr0053Tokens = $null
        $adr0053Errors = $null
        $script:Adr0053Ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:Adr0053Path, [ref]$adr0053Tokens, [ref]$adr0053Errors)
        if ($adr0053Errors.Count -gt 0) {
            throw ($adr0053Errors | ForEach-Object Message | Out-String)
        }

        foreach ($fnName in @('Get-LastModifiedByIdentity', 'Test-ConflictRow')) {
            $fnAst = $script:Adr0053Ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $fnName
                }, $true)
            if (-not $fnAst) { throw "Function $fnName not found in $script:Adr0053Path" }
            . ([ScriptBlock]::Create($fnAst.Extent.Text))
        }

        # A drifted classification type the PORTAL last touched, versus the deploy principal.
        $script:Adr0053ForeignRaw = [pscustomobject]@{
            name      = 'adr0053-fixture'
            updatedBy = 'portal-admin@contoso.onmicrosoft.com'
        }
        $script:Adr0053DeployIdentity = 'gh-oidc-purview-data-plane'
    }

    Context 'Parameter surface -- Apply set only' {

        It 'declares -OverwriteForeignAuthor in the Apply parameter set' {
            $cmd = Get-Command -Name $script:Adr0053Path -CommandType ExternalScript
            $apply = @($cmd.ParameterSets | Where-Object { $_.Name -eq 'Apply' })
            $apply.Count | Should -Be 1
            $apply[0].Parameters.Name | Should -Contain 'OverwriteForeignAuthor'
        }

        It 'does NOT declare -OverwriteForeignAuthor in the Export parameter set' {
            # The export path writes a local YAML file. No tenant object's
            # authorship is in question there, so the switch must be unbindable.
            $cmd = Get-Command -Name $script:Adr0053Path -CommandType ExternalScript
            $export = @($cmd.ParameterSets | Where-Object { $_.Name -eq 'Export' })
            $export.Count | Should -Be 1
            $export[0].Parameters.Name | Should -Not -Contain 'OverwriteForeignAuthor'
        }

        It 'keeps -Force bindable in BOTH parameter sets (the Export-path callers do not break)' {
            $cmd = Get-Command -Name $script:Adr0053Path -CommandType ExternalScript
            foreach ($setName in @('Apply', 'Export')) {
                $set = @($cmd.ParameterSets | Where-Object { $_.Name -eq $setName })
                $set[0].Parameters.Name | Should -Contain 'Force'
            }
        }
    }

    Context 'Test-ConflictRow consults -OverwriteForeignAuthor, never -Force' {

        It 'no longer exposes a -ForceEnabled parameter' {
            (Get-Command Test-ConflictRow).Parameters.Keys | Should -Not -Contain 'ForceEnabled'
        }

        It 'exposes -OverwriteForeignAuthor instead' {
            (Get-Command Test-ConflictRow).Parameters.Keys | Should -Contain 'OverwriteForeignAuthor'
        }

        It 'EMITS the Conflict row for a foreign-authored object when the override is absent (-Force alone)' {
            # The load-bearing assertion. -Force alone leaves
            # $OverwriteForeignAuthor.IsPresent = $false, so the classifier must
            # still return $true and the plan builder must emit a Conflict row
            # rather than an Update. Pre-ADR-0053 this returned $false under
            # -Force and the object was silently overwritten.
            Test-ConflictRow `
                -TenantRaw $script:Adr0053ForeignRaw `
                -DeployIdentity $script:Adr0053DeployIdentity `
                -OverwriteForeignAuthor $false | Should -BeTrue
        }

        It 'permits the overwrite only when -OverwriteForeignAuthor is supplied' {
            Test-ConflictRow `
                -TenantRaw $script:Adr0053ForeignRaw `
                -DeployIdentity $script:Adr0053DeployIdentity `
                -OverwriteForeignAuthor $true | Should -BeFalse
        }

        It 'does not flag an object the deploy principal itself last authored' {
            $ownRaw = [pscustomobject]@{
                name      = 'adr0053-fixture'
                updatedBy = $script:Adr0053DeployIdentity
            }
            Test-ConflictRow `
                -TenantRaw $ownRaw `
                -DeployIdentity $script:Adr0053DeployIdentity `
                -OverwriteForeignAuthor $false | Should -BeFalse
        }
    }

    Context 'Call-site binding' {

        It 'binds every Test-ConflictRow call from $OverwriteForeignAuthor and never from $Force' {
            $calls = @($script:Adr0053Ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.GetCommandName() -eq 'Test-ConflictRow'
                    }, $true))

            $calls.Count | Should -BeGreaterThan 0
            foreach ($call in $calls) {
                $callText = $call.Extent.Text
                $callText | Should -Match '-OverwriteForeignAuthor\s+\$OverwriteForeignAuthor\.IsPresent'
                $callText | Should -Not -Match '\$Force'
                $callText | Should -Not -Match '-ForceEnabled'
            }
        }

        It 'names -OverwriteForeignAuthor (not -Force) in the Conflict row Reason text' {
            $script:Adr0053Source | Should -Match 'Re-run with -OverwriteForeignAuthor to overwrite'
        }

        It 'carries no ambient $ConfirmPreference self-disarm (ADR 0053 section 4)' {
            # AST, not raw text -- see the note in the Mechanism B test files.
            $assignments = @($script:Adr0053Ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                        $node.Left.VariablePath.UserPath -eq 'ConfirmPreference'
                    }, $true))
            $assignments.Count | Should -Be 0
        }
    }
}
