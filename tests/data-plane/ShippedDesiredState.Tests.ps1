#Requires -Version 7.4
<#
    THE GUARD TEST THAT WOULD ACTUALLY HAVE CAUGHT IT.

    Before this file, ZERO tests in this repository loaded a shipped
    `data-plane/**` YAML. Every Pester test under tests/scripts/ builds its own
    in-memory fixture and asserts against that. So the reconcilers were heavily
    tested and the DATA they reconcile was tested not at all — and the hazard was
    in the data.

    This is the specific reason "more reconciler coverage" would NOT have caught
    the ADR 0055 disclosure. `Deploy-PurviewRoleGroups.Tests.ps1` already carries
    ~20 `It` blocks pinning revoke-everything-on-empty-members as a REQUIRED
    contract — and the shipped role-groups.yaml carried ~50 `members: []` rows
    plus real Entra group object IDs anyway. The reconciler was correct. The
    fixtures were correct. The shipped file was the problem, and nothing read it.

    A test that asserts a property of the SHIPPED artefact is the only kind that
    can catch a defect in the SHIPPED artefact.

    TEMPLATE AWARENESS (ADR 0045 / ADR 0046 / ADR 0055). This repository is a
    tenant-neutral TEMPLATE, and these assertions encode the TEMPLATE's shipped
    default. Downstream spin-offs populate their desired state after the kickoff
    wizard. See the per-Context notes below for which assertions are
    template-only and which must hold in every copy, forever.

    References:
      ADR 0055 — identifier-shaped residual scan (why this file exists)
      ADR 0023 — principals are named by displayName, never a raw object ID
      ADR 0052 / ADR 0053 — the destructive-operation contract these lists feed
      https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    Import-Module 'powershell-yaml' -ErrorAction Stop

    $script:GuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

    function Get-ShippedYaml {
        param([string]$RelativePath)
        $full = Join-Path $script:RepoRoot $RelativePath
        if (-not (Test-Path -LiteralPath $full)) { return $null }
        return (Get-Content -LiteralPath $full -Raw) | ConvertFrom-Yaml
    }
    $script:GetShippedYaml = ${function:Get-ShippedYaml}
}

Describe 'Shipped desired state — the privileged root lists ship EMPTY in the template' {

    # TEMPLATE-ONLY assertions.
    #
    # These two lists are the highest-privilege desired state in the repo: one
    # grants tenant-wide Entra directory roles, the other grants Microsoft Purview
    # / Exchange role-group membership. In the TEMPLATE they must be empty, for two
    # independent reasons:
    #
    #   1. PRIVACY. A populated list means committed principal identifiers. Per
    #      ADR 0023 those must be displayNames, but the shipped file is the exact
    #      place raw object IDs landed and sat in a public repo.
    #
    #   2. SAFETY. "Not listed" is the ONLY shape that means "not managed". A role
    #      group LISTED with `members: []` means "this role group must have zero
    #      members" — under `-Apply -PruneMissing` the reconciler revokes every
    #      existing assignment. Both reconcilers hard-code a pre-flight no-op on an
    #      EMPTY ROOT LIST that returns before any tenant read or write. The empty
    #      root list is therefore a load-bearing safety default, not a placeholder.
    #
    # A tailored spin-off that legitimately adopts these solutions WILL populate
    # these lists and this Context will fail. That is intended: adopting a
    # tenant-wide role-grant surface should require a deliberate edit to the test
    # that guards it. The Context below ('every copy, forever') must keep passing
    # in that spin-off regardless.

    BeforeAll { ${function:Get-ShippedYaml} = $script:GetShippedYaml }

    It 'data-plane/purview-role-groups/role-groups.yaml ships `roleGroups: []`' {
        $doc = Get-ShippedYaml -RelativePath 'data-plane/purview-role-groups/role-groups.yaml'
        $doc | Should -Not -BeNullOrEmpty
        $doc.Keys | Should -Contain 'roleGroups'
        @($doc.roleGroups).Count | Should -Be 0 -Because 'the template ships an empty root list: not listed = not managed (ADR 0055)'
    }

    It 'data-plane/entra-directory-roles/role-assignments.yaml ships `directoryRoles: []`' {
        $doc = Get-ShippedYaml -RelativePath 'data-plane/entra-directory-roles/role-assignments.yaml'
        $doc | Should -Not -BeNullOrEmpty
        $doc.Keys | Should -Contain 'directoryRoles'
        @($doc.directoryRoles).Count | Should -Be 0 -Because 'the template ships an empty root list: not listed = not managed (ADR 0055)'
    }
}

Describe 'Shipped desired state — no raw principal identifier, in ANY copy, forever' {

    # MUST HOLD IN EVERY COPY, TEMPLATE OR TAILORED.
    #
    # ADR 0023 Category 3: an Entra principal is carried in YAML by its stable
    # `displayName` and resolved to an object ID at deploy time by
    # scripts/Get-EntraPrincipalIdByDisplayName.ps1. A raw GUID under a principal
    # key is a violation of that decision no matter who ships it, and it is exactly
    # the shape the disclosure took:
    #
    #     members:
    #       - <raw object id>   # sg-purview-...
    #
    # This assertion survives tailoring: a spin-off that adopts role groups still
    # must not commit raw object IDs. Keep it green.

    BeforeAll {
        ${function:Get-ShippedYaml} = $script:GetShippedYaml

        # Walk every shipped data-plane YAML and collect the scalar value of every
        # key whose name denotes a principal, plus every item of a principal list.
        $script:PrincipalKeys = @('members', 'principals', 'owners', 'assignedTo', 'memberOf')

        function Get-PrincipalScalar {
            param([object]$Node, [string]$Path)
            $out = [System.Collections.Generic.List[object]]::new()
            if ($null -eq $Node) { return $out }

            if ($Node -is [System.Collections.IDictionary]) {
                foreach ($key in $Node.Keys) {
                    $child = $Node[$key]
                    $childPath = "$Path.$key"
                    if ($script:PrincipalKeys -contains [string]$key) {
                        foreach ($item in @($child)) {
                            if ($item -is [string]) {
                                $out.Add([pscustomobject]@{ Path = $childPath; Value = $item })
                            }
                            elseif ($item -is [System.Collections.IDictionary]) {
                                # ADR 0023 shape: { kind: Group, displayName: sg-... }
                                foreach ($ik in $item.Keys) {
                                    if ($item[$ik] -is [string]) {
                                        $out.Add([pscustomobject]@{ Path = "$childPath.$ik"; Value = [string]$item[$ik] })
                                    }
                                }
                            }
                        }
                    }
                    else {
                        foreach ($r in (Get-PrincipalScalar -Node $child -Path $childPath)) { $out.Add($r) }
                    }
                }
            }
            elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
                $idx = 0
                foreach ($item in $Node) {
                    foreach ($r in (Get-PrincipalScalar -Node $item -Path "$Path[$idx]")) { $out.Add($r) }
                    $idx++
                }
            }
            return $out
        }

        $script:ShippedYamlFiles = @(
            Get-ChildItem -Path (Join-Path $script:RepoRoot 'data-plane') -Recurse -File -Filter '*.yaml' |
                Where-Object { $_.Name -notlike '*.schema.*' }
        )
    }

    It 'finds and parses the shipped data-plane YAMLs (the test is not vacuously green)' {
        # A guard test that silently loaded nothing would be worse than no test.
        $script:ShippedYamlFiles.Count | Should -BeGreaterThan 5
    }

    It 'carries no raw GUID under any principal key in any shipped data-plane YAML' {
        $violations = [System.Collections.Generic.List[string]]::new()

        foreach ($file in $script:ShippedYamlFiles) {
            $relative = $file.FullName.Substring($script:RepoRoot.Length + 1).Replace('\', '/')
            $doc = $null
            try { $doc = (Get-Content -LiteralPath $file.FullName -Raw) | ConvertFrom-Yaml }
            catch { continue }   # schema-invalid YAML is another test's problem
            if ($null -eq $doc) { continue }

            foreach ($hit in (Get-PrincipalScalar -Node $doc -Path $relative)) {
                if ($hit.Value -match $script:GuidPattern -and
                    $hit.Value -ne '00000000-0000-0000-0000-000000000000') {
                    # Redacted: this message can surface in a public CI log.
                    $violations.Add("$($hit.Path) = $($hit.Value.Substring(0,8))-...")
                }
            }
        }

        $violations.Count | Should -Be 0 -Because (
            'ADR 0023 requires principals be named by displayName, never a raw object ID. ' +
            'Violations: ' + ($violations -join '; '))
    }
}
