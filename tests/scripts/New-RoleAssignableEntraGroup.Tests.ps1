#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Unit tests for scripts/New-RoleAssignableEntraGroup.ps1 helper functions
    (Issue #412).

.DESCRIPTION
    AST-extracts the four pure helper functions from the script and
    exercises them with synthetic inputs. No live tenant, no Microsoft
    Graph calls -- per `.github/instructions/tests.instructions.md`.
    Synthetic GUIDs follow the `00000000-0000-0000-0000-0000000000NN`
    pattern.

    Functions under test:
      * Format-EntraIdentifier
          - Redacts a GUID-shaped string to first-8-chars + ellipsis.
          - Passes non-GUID input through unchanged.
          - Returns the `<none>` placeholder for null / empty / whitespace.
      * Test-IsAddMemberAlreadyExistsError
          - Recognises the Graph 400 "object references already exist"
            response as idempotent success.
          - Returns false for unrelated error bodies and for empty input.
      * Wait-MembershipConsistent
          - Returns true on the first probe when the target id is present.
          - Returns true on a later probe after eventual-consistency catch-up.
          - Returns false when MaxAttempts is exhausted without the target id.
      * Assert-ActionLabel
          - Accepts valid label combinations.
          - Throws when either label is still the null sentinel.
          - Throws when a label is outside the allow-list.

    Reference: https://pester.dev/docs/quick-start
    Reference: https://learn.microsoft.com/en-us/graph/api/group-post-members
    Reference: https://learn.microsoft.com/en-us/graph/aad-advanced-queries
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'New-RoleAssignableEntraGroup.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate New-RoleAssignableEntraGroup.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)

    foreach ($fn in @('Format-EntraIdentifier', 'Test-IsAddMemberAlreadyExistsError', 'Wait-MembershipConsistent', 'Assert-ActionLabel')) {
        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fn
            }, $true)
        if (-not $fnAst) {
            throw "Function '$fn' not found in $($script:ScriptPath)."
        }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }
}

Describe 'Format-EntraIdentifier' {

    It 'redacts a GUID-shaped value to the first 8 chars plus ellipsis' {
        $result = Format-EntraIdentifier -Value '00000000-0000-0000-0000-000000000042'
        $result | Should -Be '00000000-...'
    }

    It 'redacts a mixed-case GUID-shaped value' {
        $result = Format-EntraIdentifier -Value 'AbCdEf01-1234-5678-9ABC-DEF012345678'
        $result | Should -Be 'AbCdEf01-...'
    }

    It 'returns <none> placeholder for $null' {
        $result = Format-EntraIdentifier -Value $null
        $result | Should -Be '<none>'
    }

    It 'returns <none> placeholder for the empty string' {
        $result = Format-EntraIdentifier -Value ''
        $result | Should -Be '<none>'
    }

    It 'returns <none> placeholder for whitespace' {
        $result = Format-EntraIdentifier -Value "   "
        $result | Should -Be '<none>'
    }

    It 'passes a non-GUID display name through unchanged' {
        $result = Format-EntraIdentifier -Value 'sg-purview-data-plane-compliance-admin'
        $result | Should -Be 'sg-purview-data-plane-compliance-admin'
    }

    It 'does not redact a value that is too short to be a GUID' {
        $result = Format-EntraIdentifier -Value '00000000-0000'
        $result | Should -Be '00000000-0000'
    }
}

Describe 'Test-IsAddMemberAlreadyExistsError' {

    It 'returns true for the canonical Graph response' {
        $body = '{"error":{"code":"Request_BadRequest","message":"One or more added object references already exist for the following modified properties: members."}}'
        Test-IsAddMemberAlreadyExistsError -ErrorBody $body | Should -BeTrue
    }

    It 'returns true when the canonical phrases are split across the body' {
        $body = 'HTTP 400 Bad Request: Request_BadRequest ... object references already exist'
        Test-IsAddMemberAlreadyExistsError -ErrorBody $body | Should -BeTrue
    }

    It 'returns false when only Request_BadRequest is present (different cause)' {
        $body = '{"error":{"code":"Request_BadRequest","message":"Invalid object identifier."}}'
        Test-IsAddMemberAlreadyExistsError -ErrorBody $body | Should -BeFalse
    }

    It 'returns false when only the already-exists phrase is present without the code' {
        $body = 'Something else: object references already exist for unrelated reasons'
        Test-IsAddMemberAlreadyExistsError -ErrorBody $body | Should -BeFalse
    }

    It 'returns false for an unrelated 403 forbidden body' {
        $body = '{"error":{"code":"Authorization_RequestDenied","message":"Insufficient privileges."}}'
        Test-IsAddMemberAlreadyExistsError -ErrorBody $body | Should -BeFalse
    }

    It 'returns false for the empty string' {
        Test-IsAddMemberAlreadyExistsError -ErrorBody '' | Should -BeFalse
    }

    It 'returns false for $null' {
        Test-IsAddMemberAlreadyExistsError -ErrorBody $null | Should -BeFalse
    }
}

Describe 'Wait-MembershipConsistent' {

    It 'returns true when the target id is present on the first probe' {
        $script:Calls = 0
        $probe = {
            $script:Calls++
            @('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002')
        }
        $result = Wait-MembershipConsistent `
            -Probe $probe `
            -TargetId '00000000-0000-0000-0000-000000000002' `
            -MaxAttempts 5 `
            -DelayMs 0
        $result | Should -BeTrue
        $script:Calls | Should -Be 1
    }

    It 'returns true after a Graph eventual-consistency catch-up on attempt 3' {
        $script:Calls = 0
        $probe = {
            $script:Calls++
            if ($script:Calls -lt 3) { return @() }
            return @('00000000-0000-0000-0000-000000000042')
        }
        $result = Wait-MembershipConsistent `
            -Probe $probe `
            -TargetId '00000000-0000-0000-0000-000000000042' `
            -MaxAttempts 5 `
            -DelayMs 0
        $result | Should -BeTrue
        $script:Calls | Should -Be 3
    }

    It 'returns false when the target id never appears within MaxAttempts' {
        $script:Calls = 0
        $probe = {
            $script:Calls++
            @('00000000-0000-0000-0000-000000000099')
        }
        $result = Wait-MembershipConsistent `
            -Probe $probe `
            -TargetId '00000000-0000-0000-0000-000000000042' `
            -MaxAttempts 4 `
            -DelayMs 0
        $result | Should -BeFalse
        $script:Calls | Should -Be 4
    }

    It 'does not emit a false-negative warning when the probe eventually succeeds' {
        # Regression guard for Issue #412 defect 2: the previous
        # implementation took a single GET after POST and surfaced
        # Write-Error when the eventually-consistent Graph response
        # returned empty. The new helper absorbs the consistency window
        # inside the probe loop.
        $script:Calls = 0
        $probe = {
            $script:Calls++
            if ($script:Calls -lt 2) { return @() }
            return @('00000000-0000-0000-0000-000000000001')
        }
        $warnings = @()
        $errors   = @()
        $result = Wait-MembershipConsistent `
            -Probe $probe `
            -TargetId '00000000-0000-0000-0000-000000000001' `
            -MaxAttempts 3 `
            -DelayMs 0 `
            -WarningVariable warnings `
            -ErrorVariable   errors
        $result   | Should -BeTrue
        $warnings | Should -BeNullOrEmpty
        $errors   | Should -BeNullOrEmpty
    }
}

Describe 'Assert-ActionLabel' {

    It 'accepts a valid (Create, AddMember) combination' {
        { Assert-ActionLabel -GroupAction 'Create' -MemberAction 'AddMember' } |
            Should -Not -Throw
    }

    It 'accepts a valid (NoChange, NoOp) combination' {
        { Assert-ActionLabel -GroupAction 'NoChange' -MemberAction 'NoOp' } |
            Should -Not -Throw
    }

    It 'accepts a valid (NoChange, NotRequested) combination' {
        { Assert-ActionLabel -GroupAction 'NoChange' -MemberAction 'NotRequested' } |
            Should -Not -Throw
    }

    It 'accepts a valid (Create, NotRequested) combination' {
        { Assert-ActionLabel -GroupAction 'Create' -MemberAction 'NotRequested' } |
            Should -Not -Throw
    }

    It 'accepts a valid (WhatIf, WhatIf-NotRequested) combination' {
        { Assert-ActionLabel -GroupAction 'WhatIf' -MemberAction 'WhatIf-NotRequested' } |
            Should -Not -Throw
    }

    It 'accepts a valid (WhatIf, WhatIf) combination' {
        { Assert-ActionLabel -GroupAction 'WhatIf' -MemberAction 'WhatIf' } |
            Should -Not -Throw
    }

    It 'throws when groupAction is still the null sentinel' {
        # Regression guard for Issue #412 defect 3: catch any code path
        # that emits the summary without setting an action label.
        { Assert-ActionLabel -GroupAction $null -MemberAction 'NoOp' } |
            Should -Throw -ExpectedMessage '*groupAction was not set before emit*'
    }

    It 'throws when memberAction is still the null sentinel' {
        { Assert-ActionLabel -GroupAction 'Create' -MemberAction $null } |
            Should -Throw -ExpectedMessage '*memberAction was not set before emit*'
    }

    It 'throws when groupAction is the empty string' {
        { Assert-ActionLabel -GroupAction '' -MemberAction 'NoOp' } |
            Should -Throw -ExpectedMessage '*groupAction was not set before emit*'
    }

    It 'throws when groupAction is whitespace' {
        { Assert-ActionLabel -GroupAction "  " -MemberAction 'NoOp' } |
            Should -Throw -ExpectedMessage '*groupAction was not set before emit*'
    }

    It 'throws when groupAction is outside the allow-list' {
        { Assert-ActionLabel -GroupAction 'Pending' -MemberAction 'NoOp' } |
            Should -Throw -ExpectedMessage "*groupAction 'Pending' is not one of*"
    }

    It 'throws when memberAction is outside the allow-list' {
        { Assert-ActionLabel -GroupAction 'Create' -MemberAction 'Pending' } |
            Should -Throw -ExpectedMessage "*memberAction 'Pending' is not one of*"
    }
}
