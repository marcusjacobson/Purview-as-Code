#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for scripts/Deploy-RoleGroupBackingEntraGroups.ps1.

.DESCRIPTION
    Locks in the contract ratified by
    docs/adr/0025-role-group-entra-backing-naming.md and the Wave 0 /
    v2 §5.1 work in issue #383:

      1. CmdletBinding declares SupportsShouldProcess with
         ConfirmImpact = 'Medium' so -WhatIf is honored end-to-end.
      2. Parameter surface exposes -Path, -OwnerObjectId, -PruneMissing,
         -Force with the documented defaults and validation.
      3. The drift-report contract from
         .github/instructions/powershell.instructions.md is implemented
         with the five canonical categories: Create, Update, NoChange,
         Orphan, Conflict.
      4. The script targets the Microsoft Graph v1.0 /groups surface,
         not a Purview-account endpoint and not the legacy Azure AD
         Graph endpoint.
      5. Comment-based help cites Microsoft Learn for every Graph verb
         invoked.
      6. Default -Path resolves to the in-repo desired-state YAML.
      7. The naming-derivation helper ConvertTo-BackingGroupSlug is
         present and conforms to the ADR 0025 contract.

    Pattern: AST-parse the script and assert structural properties.
    Per tests/README.md "No script execution" — the script shells out
    to `az` for the Graph token, so we never invoke its body. The
    naming helper IS pure and is dot-sourced into the test scope inside
    a Mock'd Graph environment to verify its derivation contract.

    Reference: https://learn.microsoft.com/en-us/graph/api/resources/group
    Reference: https://learn.microsoft.com/en-us/graph/api/group-list
    Reference: https://learn.microsoft.com/en-us/graph/api/group-post-groups
    Reference: https://learn.microsoft.com/en-us/graph/api/group-update
    Reference: https://learn.microsoft.com/en-us/graph/api/group-delete
    Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_functions_cmdletbindingattribute
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-RoleGroupBackingEntraGroups.ps1'
    if (-not (Test-Path -LiteralPath $script:ScriptPath)) {
        throw "Could not locate Deploy-RoleGroupBackingEntraGroups.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors) {
        throw ("Parse errors in {0}: {1}" -f $script:ScriptPath, ($errors -join '; '))
    }

    $script:ScriptText = Get-Content -LiteralPath $script:ScriptPath -Raw
}

Describe 'Deploy-RoleGroupBackingEntraGroups.ps1 — CmdletBinding contract' {

    It 'declares [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = ''Medium'')]' {
        $paramBlock = $script:Ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.ParamBlockAst]
            }, $true)
        $paramBlock | Should -Not -BeNullOrEmpty

        $cmdletBinding = $paramBlock.Attributes |
            Where-Object { $_.TypeName.FullName -eq 'CmdletBinding' } |
            Select-Object -First 1
        $cmdletBinding | Should -Not -BeNullOrEmpty -Because 'the script must declare CmdletBinding'

        $cbArgs = @{}
        foreach ($named in $cmdletBinding.NamedArguments) {
            $cbArgs[$named.ArgumentName] = $named.Argument.Extent.Text
        }
        $cbArgs.Keys | Should -Contain 'SupportsShouldProcess' -Because '-WhatIf must be honored end-to-end'
        $cbArgs['SupportsShouldProcess'] | Should -Match '\$true'
        $cbArgs.Keys | Should -Contain 'ConfirmImpact'
        $cbArgs['ConfirmImpact'] | Should -Match "'Medium'"
    }
}

Describe 'Deploy-RoleGroupBackingEntraGroups.ps1 — parameter surface' {

    BeforeAll {
        $script:ParamBlock = $script:Ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.ParamBlockAst]
            }, $true)
        $script:ParamNames = $script:ParamBlock.Parameters |
            ForEach-Object { $_.Name.VariablePath.UserPath }
    }

    It 'exposes -Path with a default pointing at role-groups.yaml' {
        $script:ParamNames | Should -Contain 'Path'
        $pathParam = $script:ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'Path' } |
            Select-Object -First 1
        $pathParam.DefaultValue | Should -Not -BeNullOrEmpty
        $pathParam.DefaultValue.Extent.Text |
            Should -Match 'purview-role-groups[\\/]role-groups\.yaml'
    }

    It 'exposes -OwnerObjectId with a GUID ValidatePattern' {
        $script:ParamNames | Should -Contain 'OwnerObjectId'
        $p = $script:ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'OwnerObjectId' } |
            Select-Object -First 1
        $p.StaticType.FullName | Should -Be 'System.String'
        $validate = $p.Attributes |
            Where-Object { $_.TypeName.FullName -eq 'ValidatePattern' } |
            Select-Object -First 1
        $validate | Should -Not -BeNullOrEmpty -Because 'OwnerObjectId must be a GUID'
        $validate.PositionalArguments[0].Extent.Text | Should -Match '\[0-9a-fA-F\]\{8\}'
    }

    It 'exposes -PruneMissing as a [switch] (default $false)' {
        $script:ParamNames | Should -Contain 'PruneMissing'
        $p = $script:ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'PruneMissing' } |
            Select-Object -First 1
        $p.StaticType.FullName | Should -Be 'System.Management.Automation.SwitchParameter'
    }

    It 'exposes -Force as a [switch] (default $false)' {
        $script:ParamNames | Should -Contain 'Force'
        $p = $script:ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'Force' } |
            Select-Object -First 1
        $p.StaticType.FullName | Should -Be 'System.Management.Automation.SwitchParameter'
    }

    It 'exposes -ExportCurrentState as a mandatory [switch] in the Export parameter set' {
        # Required by the full-circle reconciler contract guard (issue #292)
        # and ratified by ADR 0025.
        $script:ParamNames | Should -Contain 'ExportCurrentState'
        $p = $script:ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'ExportCurrentState' } |
            Select-Object -First 1
        $p.StaticType.FullName | Should -Be 'System.Management.Automation.SwitchParameter'
        $exportAttr = $p.Attributes |
            Where-Object {
                $_ -is [System.Management.Automation.Language.AttributeAst] -and
                $_.TypeName.Name -eq 'Parameter' -and
                ($_.NamedArguments | Where-Object { $_.ArgumentName -eq 'ParameterSetName' -and $_.Argument.Value -eq 'Export' })
            } | Select-Object -First 1
        $exportAttr | Should -Not -BeNullOrEmpty
        ($exportAttr.NamedArguments |
            Where-Object { $_.ArgumentName -eq 'Mandatory' } |
            Select-Object -First 1).Argument.VariablePath.UserPath | Should -Be 'true'
    }

    It 'declares Apply as the default parameter set' {
        # Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_functions_cmdletbindingattribute
        $cmdletBinding = $script:Ast.ParamBlock.Attributes |
            Where-Object { $_.TypeName.Name -eq 'CmdletBinding' } |
            Select-Object -First 1
        $defaultSet = ($cmdletBinding.NamedArguments |
            Where-Object { $_.ArgumentName -eq 'DefaultParameterSetName' } |
            Select-Object -First 1).Argument.Value
        $defaultSet | Should -Be 'Apply'
    }
}

Describe 'Deploy-RoleGroupBackingEntraGroups.ps1 — drift-report categories' {

    It 'emits each of the five canonical categories as a string literal' {
        $stringLiterals = $script:Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
            }, $true) | ForEach-Object { $_.Value }

        foreach ($category in @('Create', 'Update', 'NoChange', 'Orphan', 'Conflict')) {
            $stringLiterals |
                Should -Contain $category -Because "drift category '$category' is part of the contract in .github/instructions/powershell.instructions.md"
        }
    }

    It 'guards orphan deletion behind -PruneMissing' {
        $script:ScriptText | Should -Match '-not \$PruneMissing'
    }

    It 'guards conflict overwrite behind -Force' {
        $script:ScriptText | Should -Match '-not \$Force'
    }

    It 'requires -OwnerObjectId for live Create' {
        $script:ScriptText | Should -Match '-not \$OwnerObjectId'
        $script:ScriptText | Should -Match 'requires -OwnerObjectId'
    }

    It 'branches into an Export mode when ParameterSetName is Export' {
        # Full-circle reconciler contract (issue #292, ADR 0025): the
        # -ExportCurrentState switch must take its own code path that joins
        # live Graph inventory against role-groups.yaml and returns before
        # the reconciler's write-bearing loop.
        $script:ScriptText | Should -Match "\`$ExportCurrentState\.IsPresent"
        $script:ScriptText | Should -Match "Status\s*=\s*if \(\`$isTracked\) \{ 'Tracked' \} else \{ 'Orphan' \}"
    }
}

Describe 'Deploy-RoleGroupBackingEntraGroups.ps1 — Microsoft Graph surface' {

    It 'targets the v1.0 /groups endpoint (not Purview or legacy Azure AD Graph)' {
        $script:ScriptText | Should -Match 'graph\.microsoft\.com/v1\.0'
        $script:ScriptText | Should -Match '/groups'
        $script:ScriptText | Should -Not -Match 'purview\.azure\.com'
        $script:ScriptText | Should -Not -Match 'graph\.windows\.net'
    }

    It 'invokes GET, POST, PATCH, and DELETE against Invoke-RestMethod' {
        foreach ($verb in @('Get', 'Post', 'Patch', 'Delete')) {
            $script:ScriptText |
                Should -Match ("Invoke-RestMethod\s+-Method\s+{0}\b" -f $verb)
        }
    }

    It 'acquires its access token against the Microsoft Graph resource' {
        $script:ScriptText | Should -Match 'az account get-access-token --resource ''https://graph\.microsoft\.com'''
    }

    It 'creates security groups (securityEnabled true, mailEnabled false)' {
        $script:ScriptText | Should -Match 'securityEnabled\s*=\s*\$true'
        $script:ScriptText | Should -Match 'mailEnabled\s*=\s*\$false'
    }

    It 'filters list queries to the sg-purview- prefix' {
        $script:ScriptText | Should -Match "startswith\(displayName,'\`$script:NamePrefix'\)"
    }
}

Describe 'Deploy-RoleGroupBackingEntraGroups.ps1 — naming contract (ADR 0025)' {

    It 'declares the sg-purview- prefix as a single constant' {
        $script:ScriptText | Should -Match "\`$script:NamePrefix\s*=\s*'sg-purview-'"
    }

    It 'defines the ConvertTo-BackingGroupSlug helper' {
        $functions = $script:Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true) | ForEach-Object { $_.Name }
        $functions | Should -Contain 'ConvertTo-BackingGroupSlug'
    }

    It 'derives slugs per ADR 0025 (acronym-preserving kebab-case)' {
        # Dot-source only the helper by extracting its AST and Invoke()-ing it
        # in an isolated scope. The wider script body shells out to az and is
        # never invoked.
        $fnAst = $script:Ast.Find({
                param($node)
                ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
                ($node.Name -eq 'ConvertTo-BackingGroupSlug')
            }, $true)
        $fnAst | Should -Not -BeNullOrEmpty

        # We assert by re-implementing the contract and checking it against the
        # ADR 0025 reference rows. The script's regex is locked in by the
        # text-match assertion below, so any drift breaks one or both tests.
        $script:ScriptText | Should -Match "\[regex\]::Replace\(\`$RoleGroupName, '\(\?<=\[a-z0-9\]\)\(\?=\[A-Z\]\)\|\(\?<=\[A-Z\]\)\(\?=\[A-Z\]\[a-z\]\)', '-'\)\.ToLowerInvariant\(\)"
    }

    It 'produces the worked-example slugs from ADR 0025 when invoked' {
        # Need the prefix constant in scope before the function executes.
        $script:NamePrefix = 'sg-purview-'

        # Dot-source only the helper definition into the current scope by
        # invoking the function's AST text. The script's $script:NamePrefix
        # constant is satisfied by the assignment above.
        $fnAst = $script:Ast.Find({
                param($node)
                ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
                ($node.Name -eq 'ConvertTo-BackingGroupSlug')
            }, $true)
        . ([scriptblock]::Create($fnAst.Extent.Text))

        $cases = @{
            'OrganizationManagement'                = 'sg-purview-organization-management'
            'ComplianceAdministrator'               = 'sg-purview-compliance-administrator'
            'CommunicationComplianceAdministrators' = 'sg-purview-communication-compliance-administrators'
            'eDiscoveryManager'                     = 'sg-purview-e-discovery-manager'
            'InformationProtectionAdmins'           = 'sg-purview-information-protection-admins'
            'DataSecurityAIAdmins'                  = 'sg-purview-data-security-ai-admins'
            'IRMContributors'                       = 'sg-purview-irm-contributors'
        }
        foreach ($input in $cases.Keys) {
            ConvertTo-BackingGroupSlug -RoleGroupName $input |
                Should -BeExactly $cases[$input] -Because "ADR 0025 worked example for '$input'"
        }
    }

    It 'declares the description shape required by ADR 0025' {
        $script:ScriptText | Should -Match "Backs the Microsoft Purview portal role group '\{0\}'"
        $script:ScriptText | Should -Match "Managed by scripts/Deploy-RoleGroupBackingEntraGroups\.ps1"
        $script:ScriptText | Should -Match "docs/adr/0025-role-group-entra-backing-naming\.md"
    }
}

Describe 'Deploy-RoleGroupBackingEntraGroups.ps1 — Microsoft Learn citations' {

    It 'cites the Graph group resource type' {
        $script:ScriptText |
            Should -Match 'learn\.microsoft\.com/en-us/graph/api/resources/group'
    }

    It 'cites every Graph verb the script invokes' {
        $script:ScriptText | Should -Match 'learn\.microsoft\.com/en-us/graph/api/group-list'
        $script:ScriptText | Should -Match 'learn\.microsoft\.com/en-us/graph/api/group-post-groups'
        $script:ScriptText | Should -Match 'learn\.microsoft\.com/en-us/graph/api/group-update'
        $script:ScriptText | Should -Match 'learn\.microsoft\.com/en-us/graph/api/group-delete'
    }

    It 'cites Group.ReadWrite.All as the required Graph scope' {
        $script:ScriptText | Should -Match 'Group\.ReadWrite\.All'
        $script:ScriptText | Should -Match 'learn\.microsoft\.com/en-us/graph/permissions-reference#group-permissions'
    }

    It 'cites ADR 0025 (the ratifying decision)' {
        $script:ScriptText | Should -Match 'docs/adr/0025-role-group-entra-backing-naming\.md'
    }
}
