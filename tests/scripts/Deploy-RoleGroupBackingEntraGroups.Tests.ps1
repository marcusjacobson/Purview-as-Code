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
         ConfirmImpact = 'High' so -WhatIf is honored end-to-end AND the
         ADR 0052 destructive-confirmation gate can actually prompt.
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

    It 'declares [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = ''High'')]' {
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
        # 'High', NOT 'Medium'. This assertion previously pinned 'Medium' --
        # it was pinning the issue #85 DEFECT. PowerShell raises a
        # ShouldProcess confirmation only when ConfirmImpact >=
        # $ConfirmPreference, and $ConfirmPreference defaults to 'High', so at
        # 'Medium' every ShouldProcess call returned $true WITHOUT PROMPTING
        # and the mandated confirmation was dead code. Raised by issue #83
        # (ADR 0052 rollout). Case-sensitive so a lowercase 'high' cannot pass.
        # Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
        $cbArgs['ConfirmImpact'] | Should -CMatch "'High'" `
            -Because 'ConfirmImpact = Medium is the issue #85 defect: it silently disables every confirmation prompt in the script'
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

# ---------------------------------------------------------------------------
# Issue #13, part C batch 3: guard 2 (prune sanity ratio) and the failure
# reporter. This script's apply phase is a mixed Create/Update/Delete switch
# that had NO try/catch: under $ErrorActionPreference = 'Stop', the first
# failed orphan delete terminated the run and the remaining orphans were
# never attempted. The regions below are lifted from the REAL script source
# (not transcribed) and executed against stubs, so the tests cannot keep
# passing after the script regresses.
# ---------------------------------------------------------------------------
Describe 'Prune guard 2 and failure reporter wiring (issue #13, batch 3)' {

    BeforeAll {
        $script:RgSource = Get-Content -LiteralPath $script:ScriptPath -Raw
    }

    It 'imports the shared PruneGuard module' {
        $script:RgSource | Should -Match "Import-Module \(Join-Path \`$PSScriptRoot 'modules[\\/]PruneGuard\.psm1'\)"
    }
    It 'still calls guard 1 (empty-desired-set) -- earlier rollout not regressed' {
        $script:RgSource | Should -Match 'Assert-PruneDesiredSetNotEmpty'
    }
    It 'calls the sanity-ratio guard with the backing-group noun' {
        $script:RgSource | Should -Match 'Assert-PruneRatioWithinThreshold'
        $script:RgSource | Should -Match ([regex]::Escape("-ObjectTypeNoun 'backing Entra security group'"))
    }
    It 'keys guard 2 on the live sg-purview-* group count' {
        $script:RgSource | Should -Match ([regex]::Escape('@($current).Count'))
    }
    It 'surfaces the ratio override and threshold parameters on the Apply parameter set' {
        $script:RgSource | Should -Match '\[switch\]\$AllowMajorityPrune'
        $script:RgSource | Should -Match '\[double\]\$MaxPruneRatio\s*=\s*0\.5'
        $cmd = Get-Command -Name $script:ScriptPath -CommandType ExternalScript
        $cmd.Parameters['AllowMajorityPrune'].ParameterSets.Keys | Should -Not -Contain 'Export'
        $cmd.Parameters['MaxPruneRatio'].ParameterSets.Keys | Should -Not -Contain 'Export'
    }
    It 'places guard 2 before the ADR 0052 confirmation gate' {
        $ratioIdx = $script:RgSource.IndexOf('Assert-PruneRatioWithinThreshold')
        $gateIdx  = $script:RgSource.IndexOf('Assert-DestructiveOperationConfirmed @gateArgs')
        $ratioIdx | Should -BeGreaterThan 0
        $gateIdx  | Should -BeGreaterThan 0
        $ratioIdx | Should -BeLessThan $gateIdx
    }
}

Describe 'Prune sanity-ratio guard executed through the script wiring (issue #13, batch 3)' {

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..' '..' 'scripts' 'modules' 'PruneGuard.psm1') -Force -ErrorAction Stop
        $lines = @(Get-Content -LiteralPath $script:ScriptPath)
        $start = -1; $end = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*if \(\$PruneMissing\.IsPresent') {
                $depth = 0; $e = -1
                for ($j = $i; $j -lt $lines.Count; $j++) {
                    $depth += ([regex]::Matches($lines[$j], '\{')).Count
                    $depth -= ([regex]::Matches($lines[$j], '\}')).Count
                    if ($depth -le 0) { $e = $j; break }
                }
                $cand = ($lines[$i..$e] -join [Environment]::NewLine)
                if ($cand -match 'Assert-PruneRatioWithinThreshold') { $start = $i; $end = $e; break }
            }
        }
        if ($start -lt 0) { throw 'Could not locate the guard-2 region in Deploy-RoleGroupBackingEntraGroups.ps1; update the anchor in this test.' }
        $script:Guard2Region = ($lines[$start..$end] -join [Environment]::NewLine)

        function Invoke-Guard2 {
            param([int]$Prune, [int]$Live, [double]$Max = 0.5, [switch]$Allow)
            $PruneMissing = [switch]$true
            $MaxPruneRatio = $Max
            $AllowMajorityPrune = [switch]$Allow
            $orphans = @(for ($i = 0; $i -lt $Prune; $i++) { [pscustomobject]@{ Category = 'Orphan'; Name = "sg-purview-orphan-$i" } })
            $current = @(for ($i = 0; $i -lt $Live; $i++) { [pscustomobject]@{ displayName = "sg-purview-live-$i"; id = "live-$i" } })
            $null = $PruneMissing, $MaxPruneRatio, $AllowMajorityPrune, $orphans, $current
            & ([scriptblock]::Create($script:Guard2Region)) 3>$null
        }
    }

    It 'passes below the threshold (2 of 10 live)' { { Invoke-Guard2 -Prune 2 -Live 10 } | Should -Not -Throw }
    It 'passes exactly at the threshold (5 of 10 live)' { { Invoke-Guard2 -Prune 5 -Live 10 } | Should -Not -Throw }
    It 'throws above the threshold (6 of 10 live)' { { Invoke-Guard2 -Prune 6 -Live 10 } | Should -Throw }
    It 'permits an over-threshold prune when -AllowMajorityPrune is supplied' { { Invoke-Guard2 -Prune 10 -Live 10 -Allow } | Should -Not -Throw }
    It 'honours a caller-supplied -MaxPruneRatio' { { Invoke-Guard2 -Prune 6 -Live 10 -Max 0.7 } | Should -Not -Throw }
}

Describe 'Prune failure reporting executed through the script wiring (issue #13, batch 3)' {

    BeforeAll {
        $script:RepLines = @(Get-Content -LiteralPath $script:ScriptPath)
        $s = -1
        for ($i = 0; $i -lt $script:RepLines.Count; $i++) {
            if ($script:RepLines[$i] -match '^\s*\$pruneFailures = New-Object') { $s = $i; break }
        }
        if ($s -lt 0) { throw 'Could not locate the $pruneFailures declaration in Deploy-RoleGroupBackingEntraGroups.ps1; update the anchor in this test.' }
        $ifStart = -1
        for ($i = $s; $i -lt $script:RepLines.Count; $i++) {
            if ($script:RepLines[$i] -match '^\s*if \(\$pruneFailures\.Count -gt 0\) \{') { $ifStart = $i; break }
        }
        if ($ifStart -lt 0) { throw 'Could not locate the aggregate-throw block in Deploy-RoleGroupBackingEntraGroups.ps1; update the anchor in this test.' }
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
            param([string[]]$Names = @(), [string[]]$Fail = @())
            $attempted = New-Object 'System.Collections.Generic.List[string]'
            $reported  = New-Object 'System.Collections.Generic.List[string]'
            # Stub shadows the real cmdlet inside the lifted region. Deletes are
            # identified by the trailing URI segment, which the harness sets to
            # the group's display name (ObjectId == displayName in the stub
            # tenant).
            function Invoke-RestMethod {
                param($Method, $Uri, $Headers, $Body)
                $null = $Headers, $Body
                if ($Method -ne 'Delete') { throw "Unexpected non-Delete call in orphan-only run: $Method $Uri" }
                $name = ($Uri -split '/')[-1]
                $attempted.Add($name)
                if ($Fail -contains $name) { throw "TenantBlockerException: $name" }
            }
            function Write-PruneFailure { param([Parameter(Position = 0)][string]$Message) $reported.Add($Message) }
            $PruneMissing = [switch]$true
            $graphBase = 'https://graph.unit.test/v1.0'
            $headers = @{}
            $desired = @()
            $OwnerObjectId = $null
            $report = @($Names | ForEach-Object { [pscustomobject]@{ Category = 'Orphan'; Kind = 'EntraSecurityGroup'; Name = $_; RoleGroupName = $null; ObjectId = $_; Reason = 'test' } })
            $ShouldProcessStub = [pscustomobject]@{}
            $ShouldProcessStub | Add-Member -MemberType ScriptMethod -Name ShouldProcess -Value { param($Target, $Action) $null = $Target, $Action; $true }
            $null = $PruneMissing, $graphBase, $headers, $desired, $OwnerObjectId, $report, $ShouldProcessStub
            $thrown = $null
            try { & ([scriptblock]::Create($script:ReporterRunnable)) 6>$null 3>$null } catch { $thrown = $_.Exception.Message }
            [pscustomobject]@{ Attempted = $attempted.ToArray(); Reported = $reported.ToArray(); Thrown = $thrown }
        }
    }

    It 'attempts every orphan after a failure (no first-failure abort)' {
        $r = Invoke-PruneRegion -Names @('sg-purview-a', 'sg-purview-b', 'sg-purview-c') -Fail @('sg-purview-a')
        $r.Attempted | Should -Be @('sg-purview-a', 'sg-purview-b', 'sg-purview-c')
    }
    It 'reports each failure with the tenant''s own error text' {
        $r = Invoke-PruneRegion -Names @('sg-purview-a', 'sg-purview-b') -Fail @('sg-purview-b')
        $r.Reported.Count | Should -Be 1
        $r.Reported[0] | Should -Match 'TenantBlockerException: sg-purview-b'
    }
    It 'throws one aggregate naming every failure (non-zero exit preserved)' {
        $r = Invoke-PruneRegion -Names @('sg-purview-a', 'sg-purview-b', 'sg-purview-c') -Fail @('sg-purview-a', 'sg-purview-c')
        $r.Thrown | Should -Match 'sg-purview-a, sg-purview-c'
        $r.Thrown | Should -Match '2 orphan backing Entra security group'
    }
    It 'throws nothing when every prune succeeds' {
        $r = Invoke-PruneRegion -Names @('sg-purview-a', 'sg-purview-b')
        $r.Thrown   | Should -BeNullOrEmpty
        $r.Reported | Should -BeNullOrEmpty
    }
    It 'keeps the delete behind a ShouldProcess gate (substitution non-vacuous)' {
        $script:ReporterShouldProcessCount | Should -BeGreaterThan 0
    }
    It 'carries try/catch, the reporter, and the aggregate throw in the lifted region (mutation check vs pre-batch first-failure abort)' {
        # Non-vacuous: the lift anchors on the $pruneFailures declaration,
        # which the pre-change file lacked entirely (no try/catch around the
        # delete, no collection, no aggregate throw).
        $script:ReporterRegion | Should -Match 'try \{'
        $script:ReporterRegion | Should -Match 'Write-PruneFailure'
        $script:ReporterRegion | Should -Match 'throw'
        $script:ReporterRegion | Should -Not -Match '(?m)^\s*Write-Error'
    }
}

# --------------------------------------------------------------------------
# Issue #65 F1: the ADR 0062 directory-role backing groups share the
# 'sg-purview-' prefix but belong to a different RBAC surface. This reconciler
# must exclude them from its tenant view so a future -PruneMissing never deletes
# them as false orphans.
# --------------------------------------------------------------------------
Describe 'Deploy-RoleGroupBackingEntraGroups.ps1 — directory-role namespace excluded (issue #65 F1)' {

    BeforeAll {
        # Satisfy the $script:DirectoryRolePrefix constant the helper references,
        # then dot-source just the pure predicate (no script execution).
        $script:DirectoryRolePrefix = 'sg-purview-directory-role-'
        $fnAst = $script:Ast.Find({
                param($node)
                ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
                ($node.Name -eq 'Test-IsDirectoryRoleBackingName')
            }, $true)
        if (-not $fnAst) { throw 'Test-IsDirectoryRoleBackingName not found; the F1 fix is missing.' }
        . ([scriptblock]::Create($fnAst.Extent.Text))
    }

    It 'defines the sg-purview-directory-role- exclusion prefix constant' {
        $script:ScriptText | Should -Match "DirectoryRolePrefix = 'sg-purview-directory-role-'"
    }
    It 'classifies a directory-role backing group as directory-role-owned' {
        Test-IsDirectoryRoleBackingName -DisplayName 'sg-purview-directory-role-compliance-administrator' | Should -BeTrue
    }
    It 'classifies a portal role-group backing group as NOT directory-role-owned' {
        Test-IsDirectoryRoleBackingName -DisplayName 'sg-purview-compliance-administrator' | Should -BeFalse
    }
    It 'matches the directory-role prefix case-insensitively' {
        Test-IsDirectoryRoleBackingName -DisplayName 'SG-PURVIEW-DIRECTORY-ROLE-X' | Should -BeTrue
    }
    It 'classifies an unrelated or empty display name as NOT directory-role-owned' {
        Test-IsDirectoryRoleBackingName -DisplayName 'sg-something-else' | Should -BeFalse
        Test-IsDirectoryRoleBackingName -DisplayName '' | Should -BeFalse
    }
    It 'reduces $current by the directory-role predicate before any drift calc (source contract)' {
        $script:ScriptText | Should -Match '\$current = @\(\$current \| Where-Object \{ -not \(Test-IsDirectoryRoleBackingName'
    }
}

# --------------------------------------------------------------------------
# Issue #65 F2/F3: the group create must not set owners@odata.bind (F2 -- a
# delegated-self run duplicates the creator and the create fails), and must
# apply -OwnerObjectId via an idempotent post-create POST /owners/$ref (F3 --
# the create-body bind was silently dropped for a service principal).
# --------------------------------------------------------------------------
Describe 'Deploy-RoleGroupBackingEntraGroups.ps1 — create owner handling (issue #65 F2/F3)' {

    It 'does NOT assign owners@odata.bind in the group create body (F2)' {
        # The removed defect was `$bodyHash['owners@odata.bind'] = ...`; the prose
        # comment still names the property, so anchor on the hashtable-key access.
        $script:ScriptText | Should -Not -Match "owners@odata\.bind'\]"
    }
    It 'ensures -OwnerObjectId via a post-create POST to /owners/$ref (F3)' {
        $script:ScriptText | Should -Match 'ownerRefBody'
        $script:ScriptText | Should -Match 'learn\.microsoft\.com/en-us/graph/api/group-post-owners'
    }
    It 'treats an already-an-owner response as an idempotent no-op, not a failure' {
        $script:ScriptText | Should -Match "already exist"
    }
}
