#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for scripts/Deploy-UnifiedCatalogPolicies.ps1.

.DESCRIPTION
    The production script performs top-level work at import time, so the tests
    AST-extract the pure helper functions we want to exercise.
#>

# PSSA suppressions, both structural to the AST-extraction test pattern:
#
#   PSUseDeclaredVarsMoreThanAssignments -- the extracted Invoke-DirectionPolicyPlan
#   reads $DirectionPolicy out of its caller's scope (PowerShell dynamic scoping),
#   exactly as it does in the shipped script, where $DirectionPolicy is a script
#   parameter. The `$DirectionPolicy = 'portal-wins'` line in each It block IS the
#   input to the function under test; PSSA cannot see the cross-scope read. The
#   sibling Deploy-UnifiedCatalog.Tests.ps1 carries the identical pattern.
#
#   PSReviewUnusedParameter -- the ShouldContinue stub must mirror the real
#   four-argument overload's signature (query, caption, [ref]yesToAll,
#   [ref]noToAll) for the [ref] write-back to bind. Individual tests only assert
#   on some of those arguments; the parameters exist to satisfy the contract, not
#   to be consumed.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Extracted function reads $DirectionPolicy via dynamic scope; see file header.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub must mirror the ShouldContinue four-argument overload signature; see file header.')]
param()

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-UnifiedCatalogPolicies.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Deploy-UnifiedCatalogPolicies.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)

    if ($errors.Count -gt 0) {
        throw ($errors | ForEach-Object Message | Out-String)
    }

    foreach ($fnName in @(
            'Get-OrdinalDictionary',
            'Get-RoleMetadataMap',
            'Get-ManagedRolesForFamily',
            'Get-DesiredItem',
            'ConvertTo-ReportRow',
            'Test-IsConflict',
            'Get-PrincipalDiffText',
            'Get-ReconciliationPlan',
            'Get-ManagedRoleRuleName',
            'Get-ManagedRoleRuleId',
            'Get-ManagedPermissionRuleId',
            'Get-PolicyFamilyFromEntityType',
            'Get-FinalRoleAssignmentsByPolicy',
            'ConvertTo-ManagedAttributeRule',
            'ConvertTo-ManagedPermissionRule',
            'ConvertTo-PolicyUpdatePayload',
            'Invoke-DirectionPolicyPlan',
            'Write-YamlItemsBlock'
        )) {
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

    if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
        Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module 'powershell-yaml' -ErrorAction Stop

    # The REAL modules the script imports. Invoke-DirectionPolicyPlan (extracted
    # above, verbatim, from the shipped script) calls Resolve-DirectionPolicyAction
    # out of DirectionPolicy.psm1, and the gate calls into ConfirmGate.psm1. Both
    # are exercised as shipped -- nothing here is a re-implementation.
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'scripts' 'modules' 'DirectionPolicy.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'scripts' 'modules' 'ConfirmGate.psm1') -Force -ErrorAction Stop

    $script:RepoUcRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'data-plane' 'unified-catalog')).Path
    $script:CurrentPrincipalIds = @('00000000-0000-0000-0000-000000000001')
    $script:ManagedRoleCatalog = @(
        [ordered]@{ FriendlyName = 'Governance Domain Owner'; RoleSlug = 'business-domain-owner'; Family = 'BusinessDomain'; ScopeRequired = $true },
        [ordered]@{ FriendlyName = 'Governance Domain Reader'; RoleSlug = 'business-domain-reader'; Family = 'BusinessDomain'; ScopeRequired = $true },
        [ordered]@{ FriendlyName = 'Data Product Owner'; RoleSlug = 'data-product-owner'; Family = 'DGDataQualityScope'; ScopeRequired = $true },
        [ordered]@{ FriendlyName = 'Data Quality Reader'; RoleSlug = 'data-quality-reader'; Family = 'DGDataQualityScope'; ScopeRequired = $true },
        [ordered]@{ FriendlyName = 'Data Governance Administrator'; RoleSlug = 'datagovernance-administrator'; Family = 'DataGovernanceApp'; ScopeRequired = $false },
        [ordered]@{ FriendlyName = 'Global Catalog Reader'; RoleSlug = 'global-catalog-reader'; Family = 'DataGovernanceApp'; ScopeRequired = $false }
    )
    $script:RoleMetadataMap = $null
}

Describe 'Get-DesiredItem (schema validation)' {
    It 'accepts the shipped data-access-policies YAML against its schema' {
        $yaml = Join-Path $script:RepoUcRoot 'data-access-policies.yaml'
        $schema = Join-Path $script:RepoUcRoot 'data-access-policies.schema.json'

        $result = @(Get-DesiredItem -YamlPath $yaml -SchemaPath $schema)

        $result.Count | Should -Be 0
    }

    It 'rejects an invalid role name' {
        $yaml = Join-Path $TestDrive 'data-access-policies.bad.yaml'
        Set-Content -LiteralPath $yaml -Value @"
items:
  - role: Bogus
    principals:
      - user@contoso.com
"@
        $schema = Join-Path $script:RepoUcRoot 'data-access-policies.schema.json'

        { Get-DesiredItem -YamlPath $yaml -SchemaPath $schema } | Should -Throw
    }
}

Describe 'Get-ReconciliationPlan' {
    BeforeEach {
        $script:CurrentPrincipalIds = @('00000000-0000-0000-0000-000000000001')
    }

    It 'returns Create rows when an assignment exists only in desired state' {
        $desired = @(
            [pscustomobject]@{
                Key                   = 'BusinessDomain|Finance|Governance Domain Owner'
                Kind                  = 'UnifiedCatalogPolicy'
                Name                  = 'Finance / Governance Domain Owner'
                PrincipalIds          = @('00000000-0000-0000-0000-000000000010')
                PrincipalDisplayNames = @('sg-governance-finance-owners')
            }
        )

        $plan = Get-ReconciliationPlan -DesiredAssignments $desired -TenantAssignments @()

        $plan.Report[0].Category | Should -Be 'Create'
        $plan.Plan[0].Action | Should -Be 'Create'
    }

    It 'returns Update rows with an explicit principal diff' {
        $desired = @(
            [pscustomobject]@{
                Key                   = 'BusinessDomain|Finance|Governance Domain Owner'
                Kind                  = 'UnifiedCatalogPolicy'
                Name                  = 'Finance / Governance Domain Owner'
                PrincipalIds          = @('00000000-0000-0000-0000-000000000010')
                PrincipalDisplayNames = @('sg-governance-finance-owners')
            }
        )
        $tenant = @(
            [pscustomobject]@{
                Key                   = 'BusinessDomain|Finance|Governance Domain Owner'
                Kind                  = 'UnifiedCatalogPolicy'
                Name                  = 'Finance / Governance Domain Owner'
                PrincipalIds          = @('00000000-0000-0000-0000-000000000011')
                PrincipalDisplayNames = @('sg-legacy-finance-owners')
                LastModifiedBy        = '00000000-0000-0000-0000-000000000001'
            }
        )

        $plan = Get-ReconciliationPlan -DesiredAssignments $desired -TenantAssignments $tenant

        $plan.Report[0].Category | Should -Be 'Update'
        $plan.Report[0].Reason | Should -Match 'Add principals: sg-governance-finance-owners'
        $plan.Report[0].Reason | Should -Match 'Remove principals: sg-legacy-finance-owners'
        $plan.Plan[0].Action | Should -Be 'Update'
    }

    It 'returns Conflict rows when a different principal last modified the policy assignment' {
        $desired = @(
            [pscustomobject]@{
                Key                   = 'BusinessDomain|Finance|Governance Domain Owner'
                Kind                  = 'UnifiedCatalogPolicy'
                Name                  = 'Finance / Governance Domain Owner'
                PrincipalIds          = @('00000000-0000-0000-0000-000000000010')
                PrincipalDisplayNames = @('sg-governance-finance-owners')
            }
        )
        $tenant = @(
            [pscustomobject]@{
                Key                   = 'BusinessDomain|Finance|Governance Domain Owner'
                Kind                  = 'UnifiedCatalogPolicy'
                Name                  = 'Finance / Governance Domain Owner'
                PrincipalIds          = @('00000000-0000-0000-0000-000000000011')
                PrincipalDisplayNames = @('sg-legacy-finance-owners')
                LastModifiedBy        = '00000000-0000-0000-0000-000000000099'
            }
        )

        $plan = Get-ReconciliationPlan -DesiredAssignments $desired -TenantAssignments $tenant

        $plan.Report[0].Category | Should -Be 'Conflict'
        $plan.Plan.Count | Should -Be 0
        # ADR 0053: the Reason must name -OverwriteForeignAuthor, not -Force.
        $plan.Report[0].Reason | Should -Match '-OverwriteForeignAuthor'
        $plan.Report[0].Reason | Should -Not -Match '-Force'
    }

    It 'returns Remove plan entries for live-only assignments when -PruneMissing is used' {
        $desired = @()
        $tenant = @(
            [pscustomobject]@{
                Key                   = 'BusinessDomain|Finance|Governance Domain Reader'
                Kind                  = 'UnifiedCatalogPolicy'
                Name                  = 'Finance / Governance Domain Reader'
                PrincipalIds          = @('00000000-0000-0000-0000-000000000012')
                PrincipalDisplayNames = @('sg-finance-readers')
                LastModifiedBy        = '00000000-0000-0000-0000-000000000001'
            }
        )

        $plan = Get-ReconciliationPlan -DesiredAssignments $desired -TenantAssignments $tenant -PruneMissing

        $plan.Report[0].Category | Should -Be 'Orphan'
        $plan.Plan[0].Action | Should -Be 'Remove'
    }
}

Describe 'ConvertTo-PolicyUpdatePayload' {
    It 'preserves decision rules and unrelated attribute rules while replacing managed ones' {
        $policy = [pscustomobject]@{
            id = 'policy-finance'
            name = 'Finance Policy'
            version = 7
            properties = [pscustomobject]@{
                entity = [pscustomobject]@{
                    type = 'BusinessDomainReference'
                    referenceName = 'finance-id'
                }
                description = 'Finance policy'
                decisionRules = @(
                    [pscustomobject]@{
                        kind = 'decisionrule'
                        effect = 'permit'
                        dnfCondition = @()
                    }
                )
                attributeRules = @(
                    [pscustomobject]@{
                        kind = 'attributerule'
                        id = 'preserve-me'
                        name = 'preserve-me'
                        dnfCondition = @()
                    },
                    [pscustomobject]@{
                        kind = 'attributerule'
                        id = 'purviewdatagovernancerole_builtin_business-domain-owner:finance-id'
                        name = 'purviewdatagovernancerole_builtin_business-domain-owner:finance-id'
                        dnfCondition = @(
                            @(
                                [pscustomobject]@{
                                    attributeName = 'principal.microsoft.groups'
                                    attributeValueIncludedIn = @('00000000-0000-0000-0000-000000000077')
                                }
                            )
                        )
                    },
                    [pscustomobject]@{
                        kind = 'attributerule'
                        id = 'permission_dg:businessdomain_finance-id'
                        name = 'permission_dg:businessdomain_finance-id'
                        dnfCondition = @()
                    }
                )
            }
        }
        $tenantAssignments = @(
            [pscustomobject]@{
                PolicyId = 'policy-finance'
                RoleSlug = 'business-domain-owner'
                PrincipalAttributeName = 'principal.microsoft.groups'
            }
        )
        $roleAssignmentsBySlug = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        $roleAssignmentsBySlug['business-domain-owner'] = @('00000000-0000-0000-0000-000000000010')
        $roleAssignmentsBySlug['business-domain-reader'] = @('00000000-0000-0000-0000-000000000011')

        $payload = ConvertTo-PolicyUpdatePayload -Policy $policy -TenantAssignments $tenantAssignments -RoleAssignmentsBySlug $roleAssignmentsBySlug

        $payload.properties.decisionRules.Count | Should -Be 1
        $payload.properties.attributeRules.Count | Should -Be 4
        (@($payload.properties.attributeRules | Where-Object { $_.id -eq 'preserve-me' })).Count | Should -Be 1
        $ownerRule = @($payload.properties.attributeRules | Where-Object { $_['id'] -eq 'purviewdatagovernancerole_builtin_business-domain-owner:finance-id' })[0]
        $ownerRule['dnfCondition'][0][0]['attributeName'] | Should -Be 'principal.microsoft.groups'
        $permissionRule = @($payload.properties.attributeRules | Where-Object { $_['id'] -eq 'permission_dg:businessdomain_finance-id' })[0]
        $permissionRule['dnfCondition'].Count | Should -Be 2
    }

    It 'defaults a brand-new grant (no pre-existing TenantAssignments entry) to the group attribute name' {
        # Regression guard: a Create-case role assignment (business-domain-reader
        # here has no matching row in $tenantAssignments) must resolve its
        # attributeName to 'principal.microsoft.groups' -- every principal this
        # reconciler resolves is an Entra group object ID (see
        # Resolve-PrincipalIdByDisplayName), so falling back to
        # 'principal.microsoft.id' would write a rule that can never match a
        # real caller's token and silently grant access to nobody.
        $policy = [pscustomobject]@{
            id = 'policy-finance'
            name = 'Finance Policy'
            version = 7
            properties = [pscustomobject]@{
                entity = [pscustomobject]@{
                    type = 'BusinessDomainReference'
                    referenceName = 'finance-id'
                }
                description = 'Finance policy'
                decisionRules = @()
                attributeRules = @()
            }
        }
        $tenantAssignments = @()
        $roleAssignmentsBySlug = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        $roleAssignmentsBySlug['business-domain-owner'] = @()
        $roleAssignmentsBySlug['business-domain-reader'] = @('00000000-0000-0000-0000-000000000011')

        $payload = ConvertTo-PolicyUpdatePayload -Policy $policy -TenantAssignments $tenantAssignments -RoleAssignmentsBySlug $roleAssignmentsBySlug

        $readerRule = @($payload.properties.attributeRules | Where-Object { $_['id'] -eq 'purviewdatagovernancerole_builtin_business-domain-reader:finance-id' })[0]
        $readerRule['dnfCondition'][0][0]['attributeName'] | Should -Be 'principal.microsoft.groups'
    }
}

Describe 'Get-FinalRoleAssignmentsByPolicy' {
    It 'applies Create, Update, and Remove plan entries over the live policy rows' {
        $tenantAssignments = @(
            [pscustomobject]@{
                PolicyId = 'policy-finance'
                RoleSlug = 'business-domain-owner'
                PrincipalIds = @('00000000-0000-0000-0000-000000000077')
            },
            [pscustomobject]@{
                PolicyId = 'policy-finance'
                RoleSlug = 'business-domain-reader'
                PrincipalIds = @('00000000-0000-0000-0000-000000000078')
            }
        )
        $plan = @(
            [pscustomobject]@{
                Action = 'Update'
                Desired = [pscustomobject]@{
                    PolicyId = 'policy-finance'
                    RoleSlug = 'business-domain-owner'
                    PrincipalIds = @('00000000-0000-0000-0000-000000000010')
                }
                Tenant = $null
            },
            [pscustomobject]@{
                Action = 'Remove'
                Desired = $null
                Tenant = [pscustomobject]@{
                    PolicyId = 'policy-finance'
                    RoleSlug = 'business-domain-reader'
                }
            }
        )

        $result = Get-FinalRoleAssignmentsByPolicy -TenantAssignments $tenantAssignments -PlanEntries $plan

        @($result['policy-finance']['business-domain-owner']).Count | Should -Be 1
        $result['policy-finance']['business-domain-owner'][0] | Should -Be '00000000-0000-0000-0000-000000000010'
        @($result['policy-finance']['business-domain-reader']).Count | Should -Be 0
    }
}

Describe 'Write-YamlItemsBlock' {
    It 'rewrites only the items block and preserves the header comments' {
        $yaml = Join-Path $TestDrive 'data-access-policies.yaml'
        Set-Content -LiteralPath $yaml -Value @"
# Header
# Another header line
items: []
"@

        $entries = @(
            [pscustomobject]@{
                domain = 'Finance'
                role = 'Governance Domain Owner'
                principals = @('sg-governance-finance-owners')
            }
        )

        Write-YamlItemsBlock -FilePath $yaml -Entries $entries

        $raw = Get-Content -LiteralPath $yaml -Raw
        $raw | Should -Match '# Header'
        $raw | Should -Match 'domain: Finance'
        $raw | Should -Match 'role: Governance Domain Owner'
    }
}

Describe 'Source surface contract' {
    It 'keeps the required reconciler switches, helpers, and ADR markers in source' {
        $raw = Get-Content -LiteralPath $script:ScriptPath -Raw
        $raw | Should -Match 'SupportsShouldProcess = \$true'
        $raw | Should -Match '\[switch\]\$PruneMissing'
        $raw | Should -Match '\[switch\]\$ExportCurrentState'
        $raw | Should -Match '\[string\]\$DirectionPolicy = ''portal-wins'''
        $raw | Should -Match '\[string\[\]\]\$SkipNames = @\(\)'
        $raw | Should -Match 'Grant/revoke diff for policy'
        $raw | Should -Match 'api-version justification:'
        $raw | Should -Match 'Connect-Purview\.ps1'
        $raw | Should -Match 'Get-EntraPrincipalIdByDisplayName\.ps1'
        $raw | Should -Match 'Microsoft Learn does not currently document this behavior as of 2026-07-08'
    }
}


# ---------------------------------------------------------------------------
# ADR 0053 -- the foreign-author override is split out of -Force into its own
# switch, -OverwriteForeignAuthor.
#
# This is a Mechanism B script. It is ALSO the one reconciler already at
# ConfirmImpact = 'High', so its `if ($Force.IsPresent) { $ConfirmPreference =
# 'None' }` self-disarm was precisely what had been neutering the only script
# that looked correct. Deleting it makes its per-write ShouldProcess calls live
# under -Force -- a real behaviour change, not a tidy-up.
#
# Reference: docs/adr/0053-overwrite-foreign-author-switch.md
# ---------------------------------------------------------------------------
Describe 'ADR 0053 -- -OverwriteForeignAuthor (Deploy-UnifiedCatalogPolicies.ps1)' {

    BeforeAll {
        $script:Adr0053Path = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-UnifiedCatalogPolicies.ps1'
        $script:Adr0053Source = Get-Content -Path $script:Adr0053Path -Raw

        $adr0053Tokens = $null
        $adr0053Errors = $null
        $script:Adr0053Ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:Adr0053Path, [ref]$adr0053Tokens, [ref]$adr0053Errors)
        if ($adr0053Errors.Count -gt 0) {
            throw ($adr0053Errors | ForEach-Object Message | Out-String)
        }

        $script:CurrentPrincipalIds = @('00000000-0000-0000-0000-000000000001')
    }

    Context 'Parameter surface -- Apply set only' {

        It 'declares -OverwriteForeignAuthor in the Apply parameter set' {
            $cmd = Get-Command -Name $script:Adr0053Path -CommandType ExternalScript
            $apply = @($cmd.ParameterSets | Where-Object { $_.Name -eq 'Apply' })
            $apply.Count | Should -Be 1
            $apply[0].Parameters.Name | Should -Contain 'OverwriteForeignAuthor'
        }

        It 'does NOT declare -OverwriteForeignAuthor in the Export parameter set' {
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

    Context 'Call-site binding' {

        It 'binds the Get-ReconciliationPlan call from $OverwriteForeignAuthor and never from $Force' {
            $calls = @($script:Adr0053Ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.GetCommandName() -eq 'Get-ReconciliationPlan'
                    }, $true))

            $calls.Count | Should -Be 1
            $calls[0].Extent.Text | Should -Match '-AllowConflictOverwrite:\$OverwriteForeignAuthor\.IsPresent'
            $calls[0].Extent.Text | Should -Not -Match '-AllowConflictOverwrite:\$Force'
        }

        It 'has zero -AllowConflictOverwrite bindings sourced from $Force anywhere in the file' {
            $script:Adr0053Source | Should -Not -Match '-AllowConflictOverwrite:\$Force'
        }
    }

    Context 'Ambient self-disarm deleted (ADR 0053 section 4)' {

        It 'no longer assigns $ConfirmPreference = None under -Force' {
            # Asserted over the AST, NOT the raw source text. A raw-text regex
            # here would match the explanatory COMMENT in the script that quotes
            # the forbidden assignment -- which is precisely the read-a-comment-
            # as-code error ADR 0053 records ADR 0052 making. Guard on the
            # AssignmentStatementAst nodes, which prose cannot forge.
            $assignments = @($script:Adr0053Ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                        $node.Left.VariablePath.UserPath -eq 'ConfirmPreference'
                    }, $true))
            $assignments.Count | Should -Be 0
        }

        It 'is still declared at ConfirmImpact = High (ADR 0053 does not lower it)' {
            # AST, not a raw-source regex. This was the one assertion in the suite
            # that reverted to the technique the rest of it condemns -- a comment
            # mentioning ConfirmImpact = 'High' would have satisfied it.
            $attr = $script:Adr0053Ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.AttributeAst] -and
                    $node.TypeName.Name -eq 'CmdletBinding'
                }, $true)
            $attr | Should -Not -BeNullOrEmpty

            $impact = @($attr.NamedArguments | Where-Object { $_.ArgumentName -eq 'ConfirmImpact' })
            $impact.Count | Should -Be 1
            $impact[0].Argument.Value | Should -Be 'High'
        }
    }

    Context 'Under -Force alone, a foreign-authored drifted policy is reported and NOT overwritten' {

        It 'emits a Conflict row and produces no plan entry when -AllowConflictOverwrite is absent' {
            $desired = @(
                [pscustomobject]@{
                    Key                   = 'BusinessDomain|Finance|Governance Domain Owner'
                    Kind                  = 'UnifiedCatalogPolicy'
                    Name                  = 'Finance / Governance Domain Owner'
                    PrincipalIds          = @('00000000-0000-0000-0000-000000000010')
                    PrincipalDisplayNames = @('sg-governance-finance-owners')
                }
            )
            $tenant = @(
                [pscustomobject]@{
                    Key                   = 'BusinessDomain|Finance|Governance Domain Owner'
                    Kind                  = 'UnifiedCatalogPolicy'
                    Name                  = 'Finance / Governance Domain Owner'
                    PrincipalIds          = @('00000000-0000-0000-0000-000000000011')
                    PrincipalDisplayNames = @('sg-legacy-finance-owners')
                    LastModifiedBy        = '00000000-0000-0000-0000-000000000099'
                }
            )

            $plan = Get-ReconciliationPlan -DesiredAssignments $desired -TenantAssignments $tenant -AllowConflictOverwrite:$false

            $plan.Report[0].Category | Should -Be 'Conflict'
            $plan.Plan.Count | Should -Be 0
            $plan.Report[0].Reason | Should -Match '-OverwriteForeignAuthor'
            $plan.Report[0].Reason | Should -Not -Match '-Force'
        }

        It 'still emits the Conflict row when the overwrite IS authorised -- the switch grants permission, not silence' {
            $desired = @(
                [pscustomobject]@{
                    Key                   = 'BusinessDomain|Finance|Governance Domain Owner'
                    Kind                  = 'UnifiedCatalogPolicy'
                    Name                  = 'Finance / Governance Domain Owner'
                    PrincipalIds          = @('00000000-0000-0000-0000-000000000010')
                    PrincipalDisplayNames = @('sg-governance-finance-owners')
                }
            )
            $tenant = @(
                [pscustomobject]@{
                    Key                   = 'BusinessDomain|Finance|Governance Domain Owner'
                    Kind                  = 'UnifiedCatalogPolicy'
                    Name                  = 'Finance / Governance Domain Owner'
                    PrincipalIds          = @('00000000-0000-0000-0000-000000000011')
                    PrincipalDisplayNames = @('sg-legacy-finance-owners')
                    LastModifiedBy        = '00000000-0000-0000-0000-000000000099'
                }
            )

            $plan = Get-ReconciliationPlan -DesiredAssignments $desired -TenantAssignments $tenant -AllowConflictOverwrite:$true

            $plan.Report[0].Category | Should -Be 'Conflict'
            $plan.Report[0].Reason | Should -Match 'overwritten because -OverwriteForeignAuthor was supplied'
            $plan.Plan[0].Action | Should -Be 'Update'
        }
    }
}

Describe 'F4 -- Invoke-DirectionPolicyPlan: -DirectionPolicy actually arbitrates drift (#83)' {

    # THE BUG THIS FIXES.
    #
    # Deploy-UnifiedCatalogPolicies.ps1 looped over the WHOLE plan -- Create,
    # Update and Remove alike -- and passed a hardcoded `-HasDrift $false` into
    # Resolve-DirectionPolicyAction. That function only skips when
    #     $HasDrift -and $Policy -eq 'portal-wins'
    # so with $HasDrift pinned to $false, `portal-wins` NEVER skipped anything.
    # repo-wins and portal-wins were behaviourally identical, and every drifted
    # role assignment was overwritten regardless of policy -- on a PERMISSIONS
    # surface, where an overwrite revokes somebody's access.
    #
    # The fix is TWO parts and needs both:
    #   1. filter to `Action -eq 'Update'` (drift is the only thing the policy
    #      arbitrates), then
    #   2. pass `-HasDrift $true`.
    # Part 2 without part 1 makes portal-wins skip creates and prunes too,
    # turning the reconciler into a silent no-op on its DEFAULT policy. That
    # regression is pinned by name below.

    BeforeAll {
        function Get-TestPlan {
            $plan = New-Object 'System.Collections.Generic.List[object]'
            $plan.Add([pscustomobject]@{ Action = 'Update'; Name = 'Finance / Governance Domain Owner'; Kind = 'UnifiedCatalogPolicy'; Fields = @('principals'); Conflict = $false; Reason = 'drift' }) | Out-Null
            $plan.Add([pscustomobject]@{ Action = 'Update'; Name = 'HR / Governance Domain Reader'; Kind = 'UnifiedCatalogPolicy'; Fields = @('principals'); Conflict = $false; Reason = 'drift' }) | Out-Null
            $plan.Add([pscustomobject]@{ Action = 'Create'; Name = 'Legal / Governance Domain Owner'; Kind = 'UnifiedCatalogPolicy'; Fields = @('principals'); Conflict = $false; Reason = 'new' }) | Out-Null
            $plan.Add([pscustomobject]@{ Action = 'Remove'; Name = 'Retired / Data Quality Reader'; Kind = 'UnifiedCatalogPolicy'; Fields = @('principals'); Conflict = $false; Reason = 'orphan' }) | Out-Null
            , $plan
        }
    }

    BeforeEach {
        $script:SkipNameList = @()
        $script:RepoWinsOverwrites = $null
    }

    Context 'under -DirectionPolicy portal-wins (the DEFAULT)' {

        It 'SKIPS drifted role assignments -- tenant edits win (was: overwrote them)' {
            $DirectionPolicy = 'portal-wins'
            $plan = Get-TestPlan
            $report = New-Object 'System.Collections.Generic.List[object]'

            Invoke-DirectionPolicyPlan -Plan $plan -Report $report

            @($plan | Where-Object { $_.Action -eq 'Update' }).Count | Should -Be 0 -Because 'portal-wins preserves tenant edits on drifted objects (ADR 0029)'
            @($report | Where-Object { $_.Category -eq 'Skip' }).Count | Should -Be 2
        }

        It 'records ZERO overwrites, so the ADR 0052 gate correctly stays silent' {
            $DirectionPolicy = 'portal-wins'
            $plan = Get-TestPlan
            $report = New-Object 'System.Collections.Generic.List[object]'

            Invoke-DirectionPolicyPlan -Plan $plan -Report $report

            @($script:RepoWinsOverwrites).Count | Should -Be 0
        }

        # The regression guard for the NAIVE fix (`-HasDrift $true` with no
        # Action filter). Under that shape portal-wins skipped EVERY plan entry
        # -- kept=0, creates=0, removes=0 -- and the reconciler silently did
        # nothing at all on its default policy. Strictly worse than the bug.
        It 'still applies Creates -- a create is not drift' {
            $DirectionPolicy = 'portal-wins'
            $plan = Get-TestPlan
            $report = New-Object 'System.Collections.Generic.List[object]'

            Invoke-DirectionPolicyPlan -Plan $plan -Report $report

            @($plan | Where-Object { $_.Action -eq 'Create' }).Count | Should -Be 1 -Because 'portal-wins arbitrates DRIFT, not creation; skipping creates would make the reconciler a no-op on its default policy'
        }

        It 'still applies Removes -- a prune is governed by -PruneMissing, not by the direction policy' {
            $DirectionPolicy = 'portal-wins'
            $plan = Get-TestPlan
            $report = New-Object 'System.Collections.Generic.List[object]'

            Invoke-DirectionPolicyPlan -Plan $plan -Report $report

            @($plan | Where-Object { $_.Action -eq 'Remove' }).Count | Should -Be 1
        }
    }

    Context 'under -DirectionPolicy repo-wins' {

        It 'KEEPS drifted role assignments on the plan -- YAML wins' {
            $DirectionPolicy = 'repo-wins'
            $plan = Get-TestPlan
            $report = New-Object 'System.Collections.Generic.List[object]'

            Invoke-DirectionPolicyPlan -Plan $plan -Report $report

            @($plan | Where-Object { $_.Action -eq 'Update' }).Count | Should -Be 2
        }

        It 'collects the overwrite list so the gate can name the objects and the count' {
            $DirectionPolicy = 'repo-wins'
            $plan = Get-TestPlan
            $report = New-Object 'System.Collections.Generic.List[object]'

            Invoke-DirectionPolicyPlan -Plan $plan -Report $report

            @($script:RepoWinsOverwrites).Count | Should -Be 2
            $script:RepoWinsOverwrites | Should -Contain 'Finance / Governance Domain Owner'
            $script:RepoWinsOverwrites | Should -Contain 'HR / Governance Domain Reader'
        }
    }

    Context 'under -DirectionPolicy audit' {

        It 'empties the plan and records no overwrite, so neither gate fires' {
            $DirectionPolicy = 'audit'
            $plan = Get-TestPlan
            $report = New-Object 'System.Collections.Generic.List[object]'

            Invoke-DirectionPolicyPlan -Plan $plan -Report $report

            $plan.Count | Should -Be 0
            # Initialised BEFORE the audit short-circuit, so the gate can read
            # .Count unconditionally without a null-reference.
            $null -ne $script:RepoWinsOverwrites | Should -BeTrue -Because 'the list object must exist even on the audit path'
            @($script:RepoWinsOverwrites).Count | Should -Be 0
        }
    }
}

Describe 'ADR 0052 gate on Deploy-UnifiedCatalogPolicies: the write boundary is never crossed on decline (#83)' {

    # No tenant is contacted anywhere in this file. The single write boundary in
    # the script is Invoke-UnifiedCatalogRestMethod (PUT). Here it is SHADOWED by
    # a spy, so if control flow ever reached it the test would RECORD the call
    # rather than emit it -- egress is not merely absent, it is impossible.
    BeforeAll {
        function Invoke-UnifiedCatalogRestMethod {
            param($Method, $Uri, $Headers, $Body)
            $script:PutCalls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri })
            return @{}
        }

        function Get-StubUcpCmdlet {
            param([bool]$Answer = $true)
            $stub = [pscustomobject]@{
                Calls  = [System.Collections.Generic.List[string]]::new()
                Answer = $Answer
            }
            $stub | Add-Member -MemberType ScriptMethod -Name 'ShouldContinue' -Value {
                param($query, $caption, [ref]$yesToAll, [ref]$noToAll)
                $this.Calls.Add($query)
                return $this.Answer
            }
            $stub
        }

        # Mirrors the script's gate region: build the gate args once, run both
        # gates against the FINAL plan, throw on decline -- then (and only then)
        # write.
        function Invoke-GateRegion {
            param(
                [Parameter(Mandatory)]$Stub,
                [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Overwrites,
                [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Prunes,
                [switch]$Force,
                [switch]$IsWhatIf,
                [bool]$ConfirmBound = $false,
                [bool]$ConfirmValue = $false
            )
            $yesToAll = $false
            $noToAll = $false
            $gateArgs = @{
                Cmdlet       = $Stub
                Caption      = 'Destructive operation (ADR 0052)'
                YesToAll     = ([ref]$yesToAll)
                NoToAll      = ([ref]$noToAll)
                Force        = $Force.IsPresent
                IsWhatIf     = $IsWhatIf.IsPresent
                ConfirmBound = $ConfirmBound
                ConfirmValue = $ConfirmValue
            }

            # PLAN-KEYED. No $DirectionPolicy conjunct anywhere.
            if ($Overwrites.Count -gt 0) {
                $q = "This run will OVERWRITE the tenant principal set on {0} Unified Catalog role assignment(s) with the values from YAML: {1}. Principals granted in the portal but absent from YAML LOSE ACCESS. Continue?" -f $Overwrites.Count, ($Overwrites -join ', ')
                if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $q)) {
                    throw 'Aborted by operator at the overwrite confirmation gate (ADR 0052). No tenant writes were made.'
                }
            }
            if ($Prunes.Count -gt 0) {
                $q = "-PruneMissing will REVOKE {0} orphan Unified Catalog role assignment(s) from the tenant: {1}. The principals holding them lose access. This cannot be undone. Continue?" -f $Prunes.Count, ($Prunes -join ', ')
                if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $q)) {
                    throw 'Aborted by operator at the -PruneMissing revoke confirmation gate (ADR 0052). No tenant writes were made.'
                }
            }

            # The write loop, reached only if both gates returned $true.
            Invoke-UnifiedCatalogRestMethod -Method PUT -Uri 'https://api.purview-service.microsoft.com/datagovernance/catalog/policies/00000000-0000-0000-0000-000000000001' -Headers @{} -Body '{}' | Out-Null
        }
    }

    BeforeEach {
        $script:PutCalls = [System.Collections.Generic.List[object]]::new()
    }

    It 'OPERATOR DECLINES -> throws, and ZERO tenant writes are attempted' {
        $stub = Get-StubUcpCmdlet -Answer $false

        { Invoke-GateRegion -Stub $stub -Overwrites @('Finance / Governance Domain Owner') -Prunes @() } |
            Should -Throw '*No tenant writes were made*'

        $script:PutCalls.Count | Should -Be 0 -Because 'a declined gate must abort BEFORE the write loop, not half-apply'
    }

    It 'prompts ONCE per run, not once per gate, when a run trips BOTH gates' {
        # The operator answers "Yes to All" on the first prompt; the shared
        # $yesToAll ref must carry that answer into the prune gate.
        $stub = [pscustomobject]@{ Calls = [System.Collections.Generic.List[string]]::new() }
        $stub | Add-Member -MemberType ScriptMethod -Name 'ShouldContinue' -Value {
            param($query, $caption, [ref]$yesToAll, [ref]$noToAll)
            $this.Calls.Add($query)
            $yesToAll.Value = $true   # "Yes to All"
            return $true
        }

        Invoke-GateRegion -Stub $stub -Overwrites @('Finance / Governance Domain Owner') -Prunes @('Retired / Data Quality Reader')

        $stub.Calls.Count | Should -Be 1 -Because 'the yesToAll/noToAll refs are shared across BOTH gates in a run'
        $script:PutCalls.Count | Should -Be 1
    }

    It 'names the object count and the objects in the prompt' {
        $stub = Get-StubUcpCmdlet -Answer $true
        Invoke-GateRegion -Stub $stub -Overwrites @('Finance / Governance Domain Owner', 'HR / Governance Domain Reader') -Prunes @()
        $stub.Calls[0] | Should -Match '2 Unified Catalog role assignment\(s\)'
        $stub.Calls[0] | Should -Match 'Finance / Governance Domain Owner'
        $stub.Calls[0] | Should -Match 'LOSE ACCESS'
    }

    Context 'the suppression matrix' {

        It '-WhatIf -> does NOT prompt, and the destructive branch is still WALKED' {
            $stub = Get-StubUcpCmdlet -Answer $false   # would DECLINE if asked
            Invoke-GateRegion -Stub $stub -Overwrites @('Finance / Governance Domain Owner') -Prunes @('Retired / Data Quality Reader') -IsWhatIf

            $stub.Calls.Count | Should -Be 0 -Because 'a dry run must never block on input'
            # The gate returned $true, so the branch is walked and the per-write
            # ShouldProcess calls get their chance to emit "What if:" previews.
            # A gate returning $false here would silently HIDE the very deletions
            # -WhatIf exists to preview.
            $script:PutCalls.Count | Should -Be 1 -Because 'under -WhatIf the branch must still be walked so ShouldProcess renders the preview'
        }

        It '-Force -> does NOT prompt' {
            $stub = Get-StubUcpCmdlet -Answer $false
            Invoke-GateRegion -Stub $stub -Overwrites @('Finance / Governance Domain Owner') -Prunes @() -Force
            $stub.Calls.Count | Should -Be 0
            $script:PutCalls.Count | Should -Be 1
        }

        It '-Confirm:$false -> does NOT prompt (the CI consent signal)' {
            $stub = Get-StubUcpCmdlet -Answer $false
            Invoke-GateRegion -Stub $stub -Overwrites @('Finance / Governance Domain Owner') -Prunes @() -ConfirmBound $true -ConfirmValue $false
            $stub.Calls.Count | Should -Be 0
            $script:PutCalls.Count | Should -Be 1
        }

        It 'neither -> DOES prompt' {
            $stub = Get-StubUcpCmdlet -Answer $true
            Invoke-GateRegion -Stub $stub -Overwrites @('Finance / Governance Domain Owner') -Prunes @()
            $stub.Calls.Count | Should -Be 1
        }
    }
}
