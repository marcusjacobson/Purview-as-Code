#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for the ADR 0029 -DirectionPolicy / -SkipNames
    contract on scripts/Deploy-FilePlan.ps1.

.DESCRIPTION
    Locks in the Records-Management reconciler's adoption of the
    source-of-truth direction-policy contract per
    docs/adr/0029-source-of-truth-direction-policy.md and the
    workflow-baseline skip list per
    docs/adr/0035-records-seed-content-immovable.md.

    This file scopes ONLY the ADR 0029 retrofit (#584). Full helper-
    extraction coverage of ConvertTo-DesiredLabelHash /
    ConvertTo-TenantPropertyHash / Compare-PropertyField /
    Compare-RetentionLabel / Get-ComplianceTagSplat /
    Get-PropertyCreateSplat lands in #586 (Phase 3d hardening) per
    the v2 §5.3 split.

    Pattern (matches tests/scripts/Deploy-RetentionPolicies.Tests.ps1
    Describe 'DirectionPolicy parameter (ADR 0029) -- DLM' /
    Describe 'Apply-path direction policy branches (ADR 0029) -- DLM' /
    Describe 'SkipNames behavior (ADR 0029) -- DLM'):

      1. Source-text regex assertions on parameter declarations,
         info-line emission, audit short-circuit shape, marker shape,
         and module import. We do NOT dot-source the script itself --
         that would execute its top-level code and try to
         Connect-IPPSSession against the live tenant.
      2. Behavior tests against the shared
         scripts/modules/DirectionPolicy.psm1 module directly.

    Reference: https://pester.dev/docs/quick-start
    Reference: docs/adr/0029-source-of-truth-direction-policy.md
    Reference: docs/adr/0035-records-seed-content-immovable.md
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-FilePlan.ps1'
    if (-not (Test-Path -LiteralPath $script:ScriptPath)) {
        throw "Could not locate Deploy-FilePlan.ps1 at: $script:ScriptPath"
    }
    $script:ScriptText = Get-Content -LiteralPath $script:ScriptPath -Raw

    $script:ModulePath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'modules' 'DirectionPolicy.psm1'
    if (-not (Test-Path -LiteralPath $script:ModulePath)) {
        throw "Could not locate DirectionPolicy.psm1 at: $script:ModulePath"
    }
}

Describe 'DirectionPolicy parameter (ADR 0029) -- Records' {

    It 'declares a -DirectionPolicy parameter with the audit/portal-wins/repo-wins ValidateSet' {
        $script:ScriptText | Should -Match '\[ValidateSet\(\s*''audit''\s*,\s*''portal-wins''\s*,\s*''repo-wins''\s*\)\]\s*\r?\n\s*\[string\]\$DirectionPolicy\s*=\s*''portal-wins'''
    }

    It 'defaults -DirectionPolicy to portal-wins per ADR 0029' {
        $script:ScriptText | Should -Match '\[string\]\$DirectionPolicy\s*=\s*''portal-wins'''
    }

    It 'declares -SkipNames as a string[] defaulting to an empty array' {
        # Deploy-FilePlan.ps1 does not use named parameter sets in its
        # param block (the [CmdletBinding(... DefaultParameterSetName=''Apply'')]
        # is declared but no param decorates a ParameterSetName);
        # -SkipNames is therefore plain [Parameter()].
        $script:ScriptText | Should -Match '(?m)\[Parameter\(\)\]\s*\r?\n\s*\[string\[\]\]\$SkipNames\s*=\s*@\(\)'
    }

    It 'imports the shared DirectionPolicy.psm1 module rather than re-inlining the resolver' {
        $script:ScriptText | Should -Match 'Import-Module\s+\(Join-Path\s+\$PSScriptRoot\s+''modules/DirectionPolicy\.psm1''\)'
        $script:ScriptText | Should -Not -Match 'function\s+Resolve-DirectionPolicyAction'
    }

    It 'emits the DirectionPolicy info line at startup' {
        $script:ScriptText | Should -Match 'Write-Information \("DirectionPolicy : \{0\}"\s*-f\s*\$DirectionPolicy\)'
    }
}

Describe 'Apply-path direction policy branches (ADR 0029) -- Records' {

    BeforeAll {
        Import-Module $script:ModulePath -Force -ErrorAction Stop
    }

    It 'has an audit-mode short-circuit that emits [ADR0029-AUDIT] and sets $WhatIfPreference = $true' {
        $script:ScriptText | Should -Match '(?ms)if \(\$DirectionPolicy -eq ''audit''\) \{\s*\r?\n\s*Write-Information ''\[ADR0029-AUDIT\][^'']*''[^}]*\$WhatIfPreference\s*=\s*\$true\s*\r?\n\s*\}'
    }

    It 'emits one Write-Warning per drifted retention label on repo-wins' {
        $script:ScriptText | Should -Match 'Write-Warning \("Overwriting tenant on retention label '''
    }

    It 'emits a [ADR0029-SKIP] marker per skipped object for workflow consumption' {
        # Format must match `^\[ADR0029-SKIP\] (.+)$` per
        # github-actions.instructions.md.
        $script:ScriptText | Should -Match 'Write-Information \("\[ADR0029-SKIP\] \{0\}"\s*-f\s*\$s\.DisplayName'
    }

    It 'consults Resolve-DirectionPolicyAction on the property plan (SkipNames pre-pass)' {
        # Properties have no Set-* cmdlet, so HasDrift is always
        # false; the only direction-policy decision that applies to
        # properties is the SkipList match.
        $script:ScriptText | Should -Match '(?ms)foreach \(\$row in \$propertyPlan\)[\s\S]*?Resolve-DirectionPolicyAction'
    }

    It 'consults Resolve-DirectionPolicyAction on the label plan (full pass)' {
        $script:ScriptText | Should -Match '(?ms)foreach \(\$row in \$labelPlan\)[\s\S]*?Resolve-DirectionPolicyAction'
    }

    It 'returns Update when policy is repo-wins and drift is present' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'repo-wins' `
            -SkipList    @() `
            -DisplayName 'lab-fp-smoke-001' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Update'
        $decision.Reason | Should -BeNullOrEmpty
    }

    It 'returns Skip when policy is portal-wins and drift is present' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'portal-wins' `
            -SkipList    @() `
            -DisplayName 'lab-fp-smoke-001' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Skip'
        $decision.Reason | Should -Match 'portal-wins'
    }

    It 'returns Update when policy is portal-wins and no drift is present' {
        # The Records label plan calls the resolver with HasDrift=$false
        # for Create / NoChange / DriftWarn / Orphan rows so the only
        # mutation in those categories comes from SkipNames matches.
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'portal-wins' `
            -SkipList    @() `
            -DisplayName 'lab-fp-smoke-001' `
            -HasDrift    $false
        $decision.Action | Should -Be 'Update'
    }

    It 'returns Update for a property-style call (HasDrift always false) when SkipList does not match' {
        # Property rows are passed HasDrift=$false because no Set-*
        # cmdlet exists; only SkipNames matches mutate them.
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'portal-wins' `
            -SkipList    @('SomeOtherName') `
            -DisplayName 'lab-fp-cat-smoke-001' `
            -HasDrift    $false
        $decision.Action | Should -Be 'Update'
    }
}

Describe 'SkipNames behavior (ADR 0029) -- Records' {

    BeforeAll {
        Import-Module $script:ModulePath -Force -ErrorAction Stop
    }

    It 'Resolve-DirectionPolicyAction returns Skip when a name is in the skip list and HasDrift is true' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'repo-wins' `
            -SkipList    @('lab-fp-smoke-001') `
            -DisplayName 'lab-fp-smoke-001' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Skip'
        $decision.Reason | Should -Match 'Explicitly skipped'
    }

    It 'Resolve-DirectionPolicyAction returns Skip when a name is in the skip list and HasDrift is false' {
        # This is the Records-specific case: HasDrift=$false carries
        # property Orphan rows (the 31 Microsoft seeds) and label
        # Create / NoChange / DriftWarn / Orphan rows. SkipNames must
        # still mutate them to Skip so the workflow baseline can
        # suppress them.
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'portal-wins' `
            -SkipList    @('Finance') `
            -DisplayName 'Finance' `
            -HasDrift    $false
        $decision.Action | Should -Be 'Skip'
    }

    It 'matches SkipNames case-insensitively' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'repo-wins' `
            -SkipList    @('FINANCE') `
            -DisplayName 'Finance' `
            -HasDrift    $false
        $decision.Action | Should -Be 'Skip'
    }

    It 'does not match SkipNames as a substring' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'repo-wins' `
            -SkipList    @('Finan') `
            -DisplayName 'Finance' `
            -HasDrift    $false
        $decision.Action | Should -Be 'Update'
    }

    It 'does not error on an unknown name in -SkipNames (stale workflow list)' {
        { Resolve-DirectionPolicyAction `
                -Policy      'portal-wins' `
                -SkipList    @('NoSuchSeed') `
                -DisplayName 'Finance' `
                -HasDrift    $false } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# AST-extracted helper coverage (#586 Phase 3d hardening). Matches the
# precedent in tests/scripts/Deploy-RetentionPolicies.Tests.ps1 (PR #581).
# Reads the script via the language parser, extracts each helper function
# as a FunctionDefinitionAst, and dot-sources its source text into the
# test scope. Avoids dot-sourcing the script itself, which would attempt
# to Connect-IPPSSession against the live tenant.
# ---------------------------------------------------------------------------

Describe 'AST-extracted helper coverage -- Records' {

    BeforeAll {
        $script:HelperScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-FilePlan.ps1'
        if (-not (Test-Path -LiteralPath $script:HelperScriptPath)) {
            throw "Could not locate Deploy-FilePlan.ps1 at: $script:HelperScriptPath"
        }

        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:HelperScriptPath, [ref]$tokens, [ref]$errors)
        if ($errors) {
            throw ("Parse errors in {0}: {1}" -f $script:HelperScriptPath, ($errors -join '; '))
        }

        # Seed the one script-scope variable the helpers depend on
        # ($script:PropertyKinds). Find its assignment statement and
        # dot-source it.
        $kindsAssign = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$script:PropertyKinds'
            }, $true)
        if (-not $kindsAssign) { throw 'Failed to locate $script:PropertyKinds assignment in script AST.' }
        . ([ScriptBlock]::Create($kindsAssign.Extent.Text))
        if (-not $script:PropertyKinds -or $script:PropertyKinds.Count -ne 6) {
            throw 'Failed to seed $script:PropertyKinds from script AST.'
        }

        foreach ($fname in @(
                'ConvertTo-DesiredPropertyHash',
                'ConvertTo-DesiredLabelHash',
                'ConvertTo-TenantPropertyHash',
                'ConvertTo-TenantLabelHash',
                'Compare-PropertyField',
                'Compare-RetentionLabel',
                'Get-PropertyCreateSplat',
                'Get-ComplianceTagSplat')) {
            $fnAst = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $fname
                }, $true)
            if (-not $fnAst) { throw "$fname not found in $script:HelperScriptPath" }
            . ([ScriptBlock]::Create($fnAst.Extent.Text))
        }
    }

    Context 'ConvertTo-DesiredPropertyHash normalizes YAML property entries' {

        It 'returns name + display for a bare entry' {
            $h = ConvertTo-DesiredPropertyHash -Entry @{ name = 'lab-fp-cat-001' } -Display 'Category'
            $h.name    | Should -Be 'lab-fp-cat-001'
            $h.display | Should -Be 'Category'
            $h.Keys    | Should -HaveCount 2
        }

        It 'preserves url and jurisdiction extras on a Citation entry' {
            $h = ConvertTo-DesiredPropertyHash -Entry @{
                name         = 'lab-fp-cit-001'
                url          = 'https://example.com/standard'
                jurisdiction = 'US'
            } -Display 'Citation'
            $h.url          | Should -Be 'https://example.com/standard'
            $h.jurisdiction | Should -Be 'US'
        }

        It 'preserves parentCategory on a SubCategory entry' {
            $h = ConvertTo-DesiredPropertyHash -Entry @{
                name           = 'lab-fp-sub-001'
                parentCategory = 'lab-fp-cat-001'
            } -Display 'SubCategory'
            $h.parentCategory | Should -Be 'lab-fp-cat-001'
        }

        It 'ignores unknown keys silently' {
            $h = ConvertTo-DesiredPropertyHash -Entry @{
                name        = 'lab-fp-auth-001'
                strangeKey  = 'ignored'
            } -Display 'Authority'
            $h.ContainsKey('strangeKey') | Should -BeFalse
        }
    }

    Context 'ConvertTo-DesiredLabelHash normalizes YAML label entries' {

        It 'collapses missing optionals to documented defaults' {
            $h = ConvertTo-DesiredLabelHash -Entry @{
                name              = 'lab-fp-label-min'
                retentionDuration = 30
                retentionAction   = 'Keep'
                retentionType     = 'ModificationAgeInDays'
            }
            $h.name              | Should -Be 'lab-fp-label-min'
            $h.description       | Should -BeNullOrEmpty
            $h.notes             | Should -BeNullOrEmpty
            $h.isRecordLabel     | Should -BeFalse
            $h.regulatory        | Should -BeFalse
            $h.reviewerEmail     | Should -HaveCount 0
            $h.filePlanProperty  | Should -BeOfType [hashtable]
            $h.filePlanProperty.Count | Should -Be 0
        }

        It 'preserves a filePlanProperty.category binding' {
            $h = ConvertTo-DesiredLabelHash -Entry @{
                name              = 'lab-fp-label-bind'
                retentionDuration = 30
                retentionAction   = 'Keep'
                retentionType     = 'ModificationAgeInDays'
                filePlanProperty  = @{ category = 'lab-fp-cat-001' }
            }
            $h.filePlanProperty.category | Should -Be 'lab-fp-cat-001'
        }

        It 'deduplicates reviewerEmail entries case-sensitively but stably' {
            $h = ConvertTo-DesiredLabelHash -Entry @{
                name              = 'lab-fp-label-rev'
                retentionDuration = 30
                retentionAction   = 'Keep'
                retentionType     = 'ModificationAgeInDays'
                reviewerEmail     = @('a@contoso.com','b@contoso.com','a@contoso.com')
            }
            $h.reviewerEmail | Should -HaveCount 2
            $h.reviewerEmail | Should -Contain 'a@contoso.com'
            $h.reviewerEmail | Should -Contain 'b@contoso.com'
        }

        It 'honours isRecordLabel and regulatory when set' {
            $h = ConvertTo-DesiredLabelHash -Entry @{
                name              = 'lab-fp-label-record'
                isRecordLabel     = $true
                regulatory        = $true
                retentionDuration = 'Unlimited'
                retentionAction   = 'Keep'
                retentionType     = 'TaggedAgeInDays'
            }
            $h.isRecordLabel     | Should -BeTrue
            $h.regulatory        | Should -BeTrue
            $h.retentionDuration | Should -Be 'Unlimited'
        }

        It 'preserves Unlimited as a string for retentionDuration' {
            $h = ConvertTo-DesiredLabelHash -Entry @{
                name              = 'lab-fp-label-unlim'
                retentionDuration = 'Unlimited'
                retentionAction   = 'Keep'
                retentionType     = 'ModificationAgeInDays'
            }
            $h.retentionDuration | Should -BeOfType [string]
            $h.retentionDuration | Should -Be 'Unlimited'
        }

        It 'preserves integer retentionDuration as integer' {
            $h = ConvertTo-DesiredLabelHash -Entry @{
                name              = 'lab-fp-label-int'
                retentionDuration = 60
                retentionAction   = 'Keep'
                retentionType     = 'ModificationAgeInDays'
            }
            $h.retentionDuration | Should -BeOfType [int]
            $h.retentionDuration | Should -Be 60
        }
    }

    Context 'ConvertTo-TenantPropertyHash normalizes Get-FilePlanProperty* output' {

        It 'returns name + display for a bare Authority object' {
            $obj = [pscustomobject]@{ Name = 'Business' }
            $h = ConvertTo-TenantPropertyHash -Obj $obj -Display 'Authority'
            $h.name    | Should -Be 'Business'
            $h.display | Should -Be 'Authority'
            $h.Keys    | Should -HaveCount 2
        }

        It 'preserves CitationUrl and CitationJurisdiction on a Citation object' {
            $obj = [pscustomobject]@{
                Name                 = 'Sarbanes-Oxley Act of 2002'
                CitationUrl          = 'https://www.sec.gov/about/laws/soa2002.pdf'
                CitationJurisdiction = 'US'
            }
            $h = ConvertTo-TenantPropertyHash -Obj $obj -Display 'Citation'
            $h.url          | Should -Be 'https://www.sec.gov/about/laws/soa2002.pdf'
            $h.jurisdiction | Should -Be 'US'
        }

        It 'preserves ParentCategoryName on a SubCategory object' {
            $obj = [pscustomobject]@{
                Name               = 'lab-fp-sub-001'
                ParentCategoryName = 'lab-fp-cat-001'
            }
            $h = ConvertTo-TenantPropertyHash -Obj $obj -Display 'SubCategory'
            $h.parentCategory | Should -Be 'lab-fp-cat-001'
        }

        It 'falls back to ParentCategory when ParentCategoryName is absent' {
            $obj = [pscustomobject]@{
                Name           = 'lab-fp-sub-002'
                ParentCategory = 'lab-fp-cat-002'
            }
            $h = ConvertTo-TenantPropertyHash -Obj $obj -Display 'SubCategory'
            $h.parentCategory | Should -Be 'lab-fp-cat-002'
        }
    }

    Context 'ConvertTo-TenantLabelHash normalizes Get-ComplianceTag output' {

        It 'maps Comment to description and preserves int retentionDuration' {
            $tag = [pscustomobject]@{
                Name              = 'lab-fp-label-001'
                Comment           = 'A retention label.'
                IsRecordLabel     = $false
                Regulatory        = $false
                RetentionDuration = 30
                RetentionAction   = 'Keep'
                RetentionType     = 'ModificationAgeInDays'
            }
            $h = ConvertTo-TenantLabelHash -Tag $tag
            $h.name              | Should -Be 'lab-fp-label-001'
            $h.description       | Should -Be 'A retention label.'
            $h.retentionDuration | Should -BeOfType [int]
            $h.retentionDuration | Should -Be 30
        }

        It 'preserves Unlimited sentinel as string' {
            $tag = [pscustomobject]@{
                Name              = 'lab-fp-label-unlim'
                IsRecordLabel     = $false
                Regulatory        = $false
                RetentionDuration = 'Unlimited'
                RetentionAction   = 'Keep'
                RetentionType     = 'ModificationAgeInDays'
            }
            $h = ConvertTo-TenantLabelHash -Tag $tag
            $h.retentionDuration | Should -BeOfType [string]
            $h.retentionDuration | Should -Be 'Unlimited'
        }

        It 'parses FilePlanMetadata Settings[] JSON blob into filePlanProperty bindings' {
            # Documented tenant shape captured from a real Get-ComplianceTag
            # response during the PR #592 smoke against contoso.onmicrosoft.com.
            # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-compliancetag
            $meta = @{
                Settings = @(
                    @{ Key = 'FilePlanPropertyCategory';  Value = 'lab-fp-cat-001'  },
                    @{ Key = 'FilePlanPropertyAuthority'; Value = 'lab-fp-auth-001' }
                )
            } | ConvertTo-Json -Compress -Depth 5
            $tag = [pscustomobject]@{
                Name              = 'lab-fp-label-bound'
                IsRecordLabel     = $false
                Regulatory        = $false
                RetentionDuration = 30
                RetentionAction   = 'Keep'
                RetentionType     = 'ModificationAgeInDays'
                FilePlanMetadata  = $meta
            }
            $h = ConvertTo-TenantLabelHash -Tag $tag
            $h.filePlanProperty.category  | Should -Be 'lab-fp-cat-001'
            $h.filePlanProperty.authority | Should -Be 'lab-fp-auth-001'
        }

        It 'round-trips every documented FilePlanProperty kind from a single Settings[] array (multi-binding)' {
            $meta = @{
                Settings = @(
                    @{ Key = 'FilePlanPropertyAuthority';   Value = 'lab-fp-auth-001'   },
                    @{ Key = 'FilePlanPropertyCategory';    Value = 'lab-fp-cat-001'    },
                    @{ Key = 'FilePlanPropertySubCategory'; Value = 'lab-fp-sub-001'    },
                    @{ Key = 'FilePlanPropertyCitation';    Value = 'lab-fp-cite-001'   },
                    @{ Key = 'FilePlanPropertyDepartment';  Value = 'lab-fp-dept-001'   },
                    @{ Key = 'FilePlanPropertyReferenceId'; Value = 'lab-fp-ref-001'    }
                )
            } | ConvertTo-Json -Compress -Depth 5
            $tag = [pscustomobject]@{
                Name              = 'lab-fp-label-multi'
                IsRecordLabel     = $false
                Regulatory        = $false
                RetentionDuration = 30
                RetentionAction   = 'Keep'
                RetentionType     = 'ModificationAgeInDays'
                FilePlanMetadata  = $meta
            }
            $h = ConvertTo-TenantLabelHash -Tag $tag
            $h.filePlanProperty.authority   | Should -Be 'lab-fp-auth-001'
            $h.filePlanProperty.category    | Should -Be 'lab-fp-cat-001'
            $h.filePlanProperty.subCategory | Should -Be 'lab-fp-sub-001'
            $h.filePlanProperty.citation    | Should -Be 'lab-fp-cite-001'
            $h.filePlanProperty.department  | Should -Be 'lab-fp-dept-001'
            $h.filePlanProperty.referenceId | Should -Be 'lab-fp-ref-001'
        }

        It 'tolerates the legacy flat FilePlanMetadata shape as a defensive fallback' {
            # Legacy {FilePlanProperty<Kind>: {Name: '<v>'}} shape is accepted
            # for tenant heterogeneity; Settings[] takes precedence when both
            # are present. This guards against regressions if Microsoft ever
            # ships a tenant that returns the older shape.
            $meta = @{
                FilePlanPropertyCategory  = @{ Name = 'lab-fp-cat-legacy'  }
                FilePlanPropertyAuthority = @{ Name = 'lab-fp-auth-legacy' }
            } | ConvertTo-Json -Compress -Depth 5
            $tag = [pscustomobject]@{
                Name              = 'lab-fp-label-legacy'
                IsRecordLabel     = $false
                Regulatory        = $false
                RetentionDuration = 30
                RetentionAction   = 'Keep'
                RetentionType     = 'ModificationAgeInDays'
                FilePlanMetadata  = $meta
            }
            $h = ConvertTo-TenantLabelHash -Tag $tag
            $h.filePlanProperty.category  | Should -Be 'lab-fp-cat-legacy'
            $h.filePlanProperty.authority | Should -Be 'lab-fp-auth-legacy'
        }

        It 'tolerates absent FilePlanMetadata' {
            $tag = [pscustomobject]@{
                Name              = 'lab-fp-label-nometa'
                IsRecordLabel     = $false
                Regulatory        = $false
                RetentionDuration = 30
                RetentionAction   = 'Keep'
                RetentionType     = 'ModificationAgeInDays'
            }
            $h = ConvertTo-TenantLabelHash -Tag $tag
            $h.filePlanProperty       | Should -BeOfType [hashtable]
            $h.filePlanProperty.Count | Should -Be 0
        }

        It 'normalizes Regulatory: null to $false' {
            # Older tenants omit the Regulatory property entirely; the
            # helper defaults missing Regulatory to $false rather than
            # propagating $null.
            $tag = [pscustomobject]@{
                Name              = 'lab-fp-label-old'
                IsRecordLabel     = $false
                Regulatory        = $null
                RetentionDuration = 30
                RetentionAction   = 'Keep'
                RetentionType     = 'ModificationAgeInDays'
            }
            $h = ConvertTo-TenantLabelHash -Tag $tag
            $h.regulatory | Should -BeFalse
        }
    }

    Context 'Compare-PropertyField detects drift on extras only' {

        It 'returns empty list when name-only desired matches name-only tenant' {
            $diffs = Compare-PropertyField `
                -Desired @{ name = 'lab-fp-cat-001'; display = 'Category' } `
                -Tenant  @{ name = 'lab-fp-cat-001'; display = 'Category' }
            $diffs.Count | Should -Be 0
        }

        It 'detects url drift on a Citation' {
            $diffs = Compare-PropertyField `
                -Desired @{ name = 'lab-fp-cit-001'; url = 'https://example.com/new' } `
                -Tenant  @{ name = 'lab-fp-cit-001'; url = 'https://example.com/old' }
            $diffs | Should -Contain 'url'
        }

        It 'detects parentCategory drift on a SubCategory' {
            $diffs = Compare-PropertyField `
                -Desired @{ name = 'lab-fp-sub-001'; parentCategory = 'lab-fp-cat-new' } `
                -Tenant  @{ name = 'lab-fp-sub-001'; parentCategory = 'lab-fp-cat-old' }
            $diffs | Should -Contain 'parentCategory'
        }

        It 'ignores tenant-only extras when desired omits them' {
            # Asymmetric: desired says nothing about jurisdiction, tenant
            # has one. The helper compares YAML-declared fields only,
            # matching the DLM precedent's "declared-fields-only" rule.
            $diffs = Compare-PropertyField `
                -Desired @{ name = 'lab-fp-cit-001' } `
                -Tenant  @{ name = 'lab-fp-cit-001'; jurisdiction = 'US' }
            $diffs.Count | Should -Be 0
        }
    }

    Context 'Compare-RetentionLabel splits drift into Mutable vs Immutable buckets' {

        BeforeEach {
            $script:SyncHash = @{
                name              = 'lab-fp-label-sync'
                description       = $null
                notes             = $null
                isRecordLabel     = $false
                regulatory        = $false
                retentionDuration = 30
                retentionAction   = 'Keep'
                retentionType     = 'ModificationAgeInDays'
                reviewerEmail     = @()
                filePlanProperty  = @{}
            }
        }

        It 'returns both buckets empty when desired matches tenant' {
            $cmp = Compare-RetentionLabel -Desired $script:SyncHash -Tenant $script:SyncHash
            $cmp.Mutable.Count   | Should -Be 0
            $cmp.Immutable.Count | Should -Be 0
        }

        It 'classifies isRecordLabel drift as Immutable' {
            $tenant = $script:SyncHash.Clone()
            $tenant.isRecordLabel = $true
            $cmp = Compare-RetentionLabel -Desired $script:SyncHash -Tenant $tenant
            $cmp.Immutable | Should -Contain 'isRecordLabel'
            $cmp.Mutable.Count | Should -Be 0
        }

        It 'classifies regulatory drift as Immutable' {
            $tenant = $script:SyncHash.Clone()
            $tenant.regulatory = $true
            $cmp = Compare-RetentionLabel -Desired $script:SyncHash -Tenant $tenant
            $cmp.Immutable | Should -Contain 'regulatory'
        }

        It 'classifies retentionDuration drift as Mutable' {
            $tenant = $script:SyncHash.Clone()
            $tenant.retentionDuration = 60
            $cmp = Compare-RetentionLabel -Desired $script:SyncHash -Tenant $tenant
            $cmp.Mutable   | Should -Contain 'retentionDuration'
            $cmp.Immutable.Count | Should -Be 0
        }

        It 'classifies description drift as Mutable (when desired declares description)' {
            $desired = $script:SyncHash.Clone()
            $desired.description = 'updated copy'
            $tenant  = $script:SyncHash.Clone()
            $tenant.description  = 'old copy'
            $cmp = Compare-RetentionLabel -Desired $desired -Tenant $tenant
            $cmp.Mutable | Should -Contain 'description'
        }

        It 'classifies a filePlanProperty.category binding change as Mutable' {
            $desired = $script:SyncHash.Clone()
            $desired.filePlanProperty = @{ category = 'lab-fp-cat-new' }
            $tenant  = $script:SyncHash.Clone()
            $tenant.filePlanProperty  = @{ category = 'lab-fp-cat-old' }
            $cmp = Compare-RetentionLabel -Desired $desired -Tenant $tenant
            $cmp.Mutable | Should -Contain 'filePlanProperty.category'
        }

        It 'returns both Mutable and Immutable when drift spans both' {
            $tenant = $script:SyncHash.Clone()
            $tenant.retentionDuration = 60
            $tenant.isRecordLabel     = $true
            $cmp = Compare-RetentionLabel -Desired $script:SyncHash -Tenant $tenant
            $cmp.Mutable   | Should -Contain 'retentionDuration'
            $cmp.Immutable | Should -Contain 'isRecordLabel'
        }
    }

    Context 'Get-PropertyCreateSplat builds splats for the six kinds' {

        It 'emits Name only for a bare Authority' {
            $splat = Get-PropertyCreateSplat -Hash @{ name = 'lab-fp-auth-001' }
            $splat.Keys | Should -HaveCount 1
            $splat.Name | Should -Be 'lab-fp-auth-001'
        }

        It 'emits CitationUrl + CitationJurisdiction for a Citation' {
            $splat = Get-PropertyCreateSplat -Hash @{
                name         = 'lab-fp-cit-001'
                url          = 'https://example.com/std'
                jurisdiction = 'US'
            }
            $splat.CitationUrl          | Should -Be 'https://example.com/std'
            $splat.CitationJurisdiction | Should -Be 'US'
        }

        It 'emits ParentCategory for a SubCategory' {
            # Microsoft cmdlet param is -ParentCategoryName but the helper
            # historically emits -ParentCategory; this test pins the
            # current contract. If Microsoft revises the param name, both
            # the helper and this test update together.
            $splat = Get-PropertyCreateSplat -Hash @{
                name           = 'lab-fp-sub-001'
                parentCategory = 'lab-fp-cat-001'
            }
            $splat.ParentCategory | Should -Be 'lab-fp-cat-001'
        }

        It 'omits extras when the hash does not declare them' {
            $splat = Get-PropertyCreateSplat -Hash @{ name = 'lab-fp-dep-001' }
            $splat.ContainsKey('CitationUrl')          | Should -BeFalse
            $splat.ContainsKey('CitationJurisdiction') | Should -BeFalse
            $splat.ContainsKey('ParentCategory')       | Should -BeFalse
        }
    }

    Context 'Get-ComplianceTagSplat builds splat for New- (-Name) and Set- (-Identity)' {

        BeforeEach {
            $script:FullHash = @{
                name              = 'lab-fp-label-full'
                description       = 'desc'
                notes             = 'note'
                isRecordLabel     = $false
                regulatory        = $false
                retentionDuration = 30
                retentionAction   = 'Keep'
                retentionType     = 'ModificationAgeInDays'
                reviewerEmail     = @('a@contoso.com')
                filePlanProperty  = @{ category = 'lab-fp-cat-001' }
            }
        }

        It 'emits -Name on New- (default invocation)' {
            $splat = Get-ComplianceTagSplat -Hash $script:FullHash
            $splat.Name              | Should -Be 'lab-fp-label-full'
            $splat.ContainsKey('Identity') | Should -BeFalse
        }

        It 'emits -Identity on Set- (-ForSet)' {
            $splat = Get-ComplianceTagSplat -Hash $script:FullHash -ForSet
            $splat.Identity          | Should -Be 'lab-fp-label-full'
            $splat.ContainsKey('Name') | Should -BeFalse
        }

        It 'omits IsRecordLabel and Regulatory on the Set- splat (immutable post-create)' {
            $hash = $script:FullHash.Clone()
            $hash.isRecordLabel = $true
            $hash.regulatory    = $true
            $splat = Get-ComplianceTagSplat -Hash $hash -ForSet
            $splat.ContainsKey('IsRecordLabel') | Should -BeFalse
            $splat.ContainsKey('Regulatory')    | Should -BeFalse
        }

        It 'emits IsRecordLabel and Regulatory on the New- splat when the hash sets them' {
            $hash = $script:FullHash.Clone()
            $hash.isRecordLabel = $true
            $hash.regulatory    = $true
            $splat = Get-ComplianceTagSplat -Hash $hash
            $splat.IsRecordLabel | Should -BeTrue
            $splat.Regulatory    | Should -BeTrue
        }

        It 'emits FilePlanProperty as a JSON Settings[] array per Microsoft Learn (regression for #591)' {
            # Microsoft Learn New-ComplianceTag -FilePlanProperty docs:
            # https://learn.microsoft.com/en-us/powershell/module/exchange/new-compliancetag#-fileplanproperty
            # The required shape is { Settings: [ { Key, Value }, ... ] }.
            # The flat {Key:Value} shape (shipped by PR #590, replaced by
            # PR #591) is rejected by IPPS with:
            #   "Failed to parse File plan metadata value."
            $splat = Get-ComplianceTagSplat -Hash $script:FullHash
            $splat.FilePlanProperty | Should -BeOfType [string]
            $parsed = $splat.FilePlanProperty | ConvertFrom-Json
            $parsed.PSObject.Properties.Name | Should -Contain 'Settings'
            @($parsed.Settings).Count | Should -BeGreaterThan 0
            $parsed.Settings[0].PSObject.Properties.Name | Should -Contain 'Key'
            $parsed.Settings[0].PSObject.Properties.Name | Should -Contain 'Value'
            $parsed.Settings[0].Key   | Should -Be 'FilePlanPropertyCategory'
            $parsed.Settings[0].Value | Should -Be 'lab-fp-cat-001'
        }

        It 'emits a Settings[] entry for every documented FilePlanProperty kind (multi-binding)' {
            $hash = $script:FullHash.Clone()
            $hash.filePlanProperty = @{
                authority   = 'lab-fp-auth-001'
                category    = 'lab-fp-cat-001'
                subCategory = 'lab-fp-sub-001'
                citation    = 'lab-fp-cit-001'
                department  = 'lab-fp-dep-001'
                referenceId = 'lab-fp-ref-001'
            }
            $splat = Get-ComplianceTagSplat -Hash $hash
            $parsed = $splat.FilePlanProperty | ConvertFrom-Json
            @($parsed.Settings).Count | Should -Be 6
            $keys = @($parsed.Settings | ForEach-Object { $_.Key }) | Sort-Object
            $expectedKeys = @(
                'FilePlanPropertyAuthority',
                'FilePlanPropertyCategory',
                'FilePlanPropertyCitation',
                'FilePlanPropertyDepartment',
                'FilePlanPropertyReferenceId',
                'FilePlanPropertySubCategory'
            ) | Sort-Object
            $keys | Should -Be $expectedKeys
            # Spot-check one Value to confirm Key->Value pairing survives the round-trip
            $authoritySetting = $parsed.Settings | Where-Object Key -eq 'FilePlanPropertyAuthority'
            $authoritySetting.Value | Should -Be 'lab-fp-auth-001'
        }

        It 'omits FilePlanProperty when the binding hashtable is empty' {
            $hash = $script:FullHash.Clone()
            $hash.filePlanProperty = @{}
            $splat = Get-ComplianceTagSplat -Hash $hash
            $splat.ContainsKey('FilePlanProperty') | Should -BeFalse
        }
    }
}

# ---------------------------------------------------------------------------
# Source-text invariants on the apply loop (#586 Phase 3d hardening).
# These pin contracts that AST extraction cannot reach (loop structure,
# pruning order, etc.) without dot-sourcing the script body.
# ---------------------------------------------------------------------------

Describe 'Apply-loop invariants -- Records' {

    BeforeAll {
        $script:LoopScriptText = Get-Content -LiteralPath (
            Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-FilePlan.ps1') -Raw
    }

    It 'applies properties before labels (so labels can resolve their binding name)' {
        # The property apply loop block precedes the label apply loop block.
        $propIndex  = $script:LoopScriptText.IndexOf('foreach ($yamlBucket in $createOrder)')
        $labelIndex = $script:LoopScriptText.IndexOf("Where-Object { `$_.Action -in @('Create','Update','NoChange','DriftWarn','Skip') }")
        $propIndex  | Should -BeGreaterThan 0
        $labelIndex | Should -BeGreaterThan $propIndex
    }

    It 'prunes labels before properties (parent-before-children ordering)' {
        # Documented in the script header: labels are removed before
        # properties so a Remove-FilePlanProperty<Kind> call never fires
        # against a property that still has a label bound to it.
        $labelPruneIndex = $script:LoopScriptText.IndexOf("`$labelPlan | Where-Object { `$_.Action -eq 'Orphan' }")
        $propPruneIndex  = $script:LoopScriptText.IndexOf('$pruneOrder = @(')
        $labelPruneIndex | Should -BeGreaterThan 0
        $propPruneIndex  | Should -BeGreaterThan $labelPruneIndex
    }

    It 'prunes subCategories before categories within the property pruneOrder' {
        # The pruneOrder array enumerates subCategories first; subCategory
        # objects must be removed before their parent category, or the
        # parent-category removal fails with a referential-integrity error.
        $script:LoopScriptText | Should -Match "\`$pruneOrder = @\('subCategories','referenceIds','departments','citations','categories','authorities'\)"
    }

    It 'reports Skip plan rows as the Skipped report category for both labels and properties' {
        # Both apply switches gain a 'Skip' arm that emits Category='Skipped'
        # so the report stays distinct from 'NoChange' and 'WhatIf'.
        $skipArms = [regex]::Matches($script:LoopScriptText, "Category='Skipped'")
        $skipArms.Count | Should -BeGreaterOrEqual 2
    }
}

# ---------------------------------------------------------------------------
# Issue #13, part C batch 4: failure reporter ONLY. The ratio guard (guard 2)
# is deliberately NOT wired here -- a file-plan teardown legitimately prunes a
# majority of the property buckets (owner decision) -- and its absence is
# pinned below. The prune catches previously added a 'Failed' report row and
# moved on -- a failed prune exited 0. The reporter region is lifted from the
# REAL script source and executed against stubs.
# ---------------------------------------------------------------------------
Describe 'Prune failure reporter wiring -- reporter only, guard 2 pinned absent (issue #13, batch 4)' {

    BeforeAll {
        $script:B4Source = Get-Content -LiteralPath $script:ScriptPath -Raw
    }

    It 'imports the shared PruneGuard module' {
        $script:B4Source | Should -Match "Import-Module \(Join-Path \`$PSScriptRoot 'modules[\\/]PruneGuard\.psm1'\)"
    }
    It 'still calls guard 1 (empty-desired-set) -- earlier rollout not regressed' {
        $script:B4Source | Should -Match 'Assert-PruneDesiredSetNotEmpty'
    }
    It 'calls the failure reporter in the prune catches' {
        $script:B4Source | Should -Match 'Write-PruneFailure'
        $script:B4Source | Should -Match '\$pruneFailures'
    }
    It 'does NOT wire guard 2 (owner decision: file-plan teardown legitimately prunes a majority)' {
        $script:B4Source | Should -Not -Match 'Assert-PruneRatioWithinThreshold'
    }
    It 'does NOT acquire -AllowMajorityPrune / -MaxPruneRatio (no guard 2, no override surface)' {
        $cmd = Get-Command -Name $script:ScriptPath -CommandType ExternalScript
        $cmd.Parameters.Keys | Should -Not -Contain 'AllowMajorityPrune'
        $cmd.Parameters.Keys | Should -Not -Contain 'MaxPruneRatio'
    }
}

Describe 'Prune failure reporting executed through the script wiring (issue #13, batch 4)' {

    BeforeAll {
        $script:RepLines = @(Get-Content -LiteralPath $script:ScriptPath)
        $s = -1
        for ($i = 0; $i -lt $script:RepLines.Count; $i++) {
            if ($script:RepLines[$i] -match '^\s*\$pruneFailures = New-Object') { $s = $i; break }
        }
        if ($s -lt 0) { throw 'Could not locate the $pruneFailures declaration in Deploy-FilePlan.ps1; update the anchor in this test.' }
        $ifStart = -1
        for ($i = $s; $i -lt $script:RepLines.Count; $i++) {
            if ($script:RepLines[$i] -match '^\s*if \(\$pruneFailures\.Count -gt 0\) \{') { $ifStart = $i; break }
        }
        if ($ifStart -lt 0) { throw 'Could not locate the aggregate-throw block in Deploy-FilePlan.ps1; update the anchor in this test.' }
        $depth = 0; $e = -1
        for ($j = $ifStart; $j -lt $script:RepLines.Count; $j++) {
            $depth += ([regex]::Matches($script:RepLines[$j], '\{')).Count
            $depth -= ([regex]::Matches($script:RepLines[$j], '\}')).Count
            if ($depth -le 0) { $e = $j; break }
        }
        $script:ReporterRegion = ($script:RepLines[$s..$e] -join [Environment]::NewLine)
        $script:ReporterShouldProcessCount = ([regex]::Matches($script:ReporterRegion, '\$PSCmdlet\.ShouldProcess\(')).Count
        $script:ReporterRunnable = $script:ReporterRegion -replace '\$PSCmdlet\.ShouldProcess\(', '$ShouldProcessStub.ShouldProcess('

        function Invoke-PruneRegion {
            param([string[]]$LabelNames = @(), [string[]]$Fail = @())
            $attempted = New-Object 'System.Collections.Generic.List[string]'
            $reported  = New-Object 'System.Collections.Generic.List[string]'
            function Remove-ComplianceTag {
                [CmdletBinding(SupportsShouldProcess)]
                param([string]$Identity)
                $attempted.Add($Identity)
                if ($Fail -contains $Identity) { throw "TenantBlockerException: $Identity" }
            }
            function Write-PruneFailure { param([Parameter(Position = 0)][string]$Message) $reported.Add($Message) }
            $PruneMissing = [switch]$true
            $report = New-Object 'System.Collections.Generic.List[object]'
            $labelPlan = @($LabelNames | ForEach-Object { [pscustomobject]@{ Name = $_; Action = 'Orphan'; Reason = 'test' } })
            $propertyPlan = @()
            $script:PropertyKinds = @()
            $ShouldProcessStub = [pscustomobject]@{}
            $ShouldProcessStub | Add-Member -MemberType ScriptMethod -Name ShouldProcess -Value { param($Target, $Action) $null = $Target, $Action; $true }
            $null = $PruneMissing, $report, $labelPlan, $propertyPlan, $ShouldProcessStub
            $thrown = $null
            try { & ([scriptblock]::Create($script:ReporterRunnable)) 6>$null 3>$null } catch { $thrown = $_.Exception.Message }
            [pscustomobject]@{ Attempted = $attempted.ToArray(); Reported = $reported.ToArray(); Thrown = $thrown }
        }
    }

    It 'attempts every orphan label after a failure (no first-failure abort)' {
        $r = Invoke-PruneRegion -LabelNames @('l1', 'l2', 'l3') -Fail @('l1')
        $r.Attempted | Should -Be @('l1', 'l2', 'l3')
    }
    It 'reports each failure with the tenant''s own error text' {
        $r = Invoke-PruneRegion -LabelNames @('l1', 'l2') -Fail @('l2')
        $r.Reported.Count | Should -Be 1
        $r.Reported[0] | Should -Match 'TenantBlockerException: l2'
    }
    It 'throws one aggregate naming every failure (exit-0 defect fixed)' {
        $r = Invoke-PruneRegion -LabelNames @('l1', 'l2', 'l3') -Fail @('l1', 'l3')
        $r.Thrown | Should -Match "label 'l1'"
        $r.Thrown | Should -Match "label 'l3'"
        $r.Thrown | Should -Match '2 orphan file plan object'
    }
    It 'throws nothing when every prune succeeds' {
        $r = Invoke-PruneRegion -LabelNames @('l1', 'l2')
        $r.Thrown   | Should -BeNullOrEmpty
        $r.Reported | Should -BeNullOrEmpty
    }
    It 'keeps the deletes behind a ShouldProcess gate (substitution non-vacuous)' {
        $script:ReporterShouldProcessCount | Should -BeGreaterThan 0
    }
    It 'carries the reporter and the aggregate throw in the lifted region (mutation check vs pre-batch exit-0)' {
        $script:ReporterRegion | Should -Match 'Write-PruneFailure'
        $script:ReporterRegion | Should -Match 'throw'
        $script:ReporterRegion | Should -Not -Match '(?m)^\s*Write-Error'
    }
}
