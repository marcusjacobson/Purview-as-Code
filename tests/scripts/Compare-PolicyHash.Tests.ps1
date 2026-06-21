#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for the order- and comment-insensitive
    conflict-guard fix (`-CompareWithTenant`) in
    `scripts/Deploy-LabelPolicies.ps1`.

.DESCRIPTION
    Locks in the issue #235 acceptance criteria:

      1. Two policies with the same `labels:` elements in different
         order hash to byte-identical canonical strings, so the
         conflict guard treats them as equal.
      2. Same treatment applied to `exchangeLocation:` (also an
         unordered set per Microsoft Learn).
      3. Genuinely different label sets still produce a `labels` diff.
      4. Mode and advancedSettings diffs continue to surface.
      5. Comments above unordered list fields in a desired YAML have
         no effect on the desired hash, because `ConvertFrom-Yaml`
         drops comments at parse time.

    Pattern: AST-extract the three function definitions
    (`ConvertTo-PolicyHash`, `ConvertTo-TenantPolicyHash`,
    `Compare-PolicyHash`) and evaluate them into the test scope. We
    deliberately do NOT dot-source the script -- that would execute
    its top-level code and attempt to load ExchangeOnlineManagement /
    connect to a tenant.

    Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-labelpolicy
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-LabelPolicies.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Deploy-LabelPolicies.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)

    foreach ($fname in @('ConvertTo-PolicyHash', 'ConvertTo-TenantPolicyHash', 'Compare-PolicyHash')) {
        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fname
            }, $true)
        if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }

    # Stub script-scoped dependencies that Compare-PolicyHash reads.
    $script:TrackedScalarFields       = @('mode')
    $script:AdvancedSettingsAllowlist = @('RequireDowngradeJustification', 'MandatoryLabelling', 'HideBarByDefault')

    # ConvertTo-TenantPolicyHash calls ConvertTo-PolicyInputMode for
    # mode normalization. The tests pin Mode directly so a pass-through
    # stub is sufficient.
    function ConvertTo-PolicyInputMode {
        param([string]$Mode)
        return $Mode
    }
}

Describe 'Compare-PolicyHash order-insensitivity (issue #235)' {

    It 'returns no diffs when labels: differs only in order' {
        $a = @{
            name             = 'p1'; mode = 'Enable'
            exchangeLocation = @('All')
            labels           = @('Public', 'General', 'Confidential') | Sort-Object -Unique
            advancedSettings = @{}
        }
        $b = @{
            name             = 'p1'; mode = 'Enable'
            exchangeLocation = @('All')
            labels           = @('Confidential', 'Public', 'General') | Sort-Object -Unique
            advancedSettings = @{}
        }
        Compare-PolicyHash -Desired $a -Tenant $b | Should -BeNullOrEmpty
    }

    It 'returns no diffs when exchangeLocation: differs only in order' {
        $a = @{
            name             = 'p1'; mode = 'Enable'
            exchangeLocation = @('user1@contoso.com', 'user2@contoso.com') | Sort-Object -Unique
            labels           = @('Public')
            advancedSettings = @{}
        }
        $b = @{
            name             = 'p1'; mode = 'Enable'
            exchangeLocation = @('user2@contoso.com', 'user1@contoso.com') | Sort-Object -Unique
            labels           = @('Public')
            advancedSettings = @{}
        }
        Compare-PolicyHash -Desired $a -Tenant $b | Should -BeNullOrEmpty
    }

    It 'returns labels when the desired label set is missing an element' {
        $a = @{
            name             = 'p1'; mode = 'Enable'
            exchangeLocation = @('All')
            labels           = @('Public', 'General') | Sort-Object -Unique
            advancedSettings = @{}
        }
        $b = @{
            name             = 'p1'; mode = 'Enable'
            exchangeLocation = @('All')
            labels           = @('Public', 'General', 'Confidential') | Sort-Object -Unique
            advancedSettings = @{}
        }
        $diffs = Compare-PolicyHash -Desired $a -Tenant $b
        $diffs | Should -Contain 'labels'
    }

    It 'returns mode when the desired mode differs' {
        $a = @{
            name             = 'p1'; mode = 'Enable'
            exchangeLocation = @('All')
            labels           = @('Public')
            advancedSettings = @{}
        }
        $b = @{
            name             = 'p1'; mode = 'Disable'
            exchangeLocation = @('All')
            labels           = @('Public')
            advancedSettings = @{}
        }
        $diffs = Compare-PolicyHash -Desired $a -Tenant $b
        $diffs | Should -Contain 'mode'
    }

    It 'returns advancedSettings.<key> when an allowlisted value differs' {
        $a = @{
            name             = 'p1'; mode = 'Enable'
            exchangeLocation = @('All')
            labels           = @('Public')
            advancedSettings = @{ requiredowngradejustification = 'true' }
        }
        $b = @{
            name             = 'p1'; mode = 'Enable'
            exchangeLocation = @('All')
            labels           = @('Public')
            advancedSettings = @{ requiredowngradejustification = 'false' }
        }
        $diffs = Compare-PolicyHash -Desired $a -Tenant $b
        ($diffs -join ',') | Should -Match 'advancedSettings\.RequireDowngradeJustification'
    }
}

Describe 'ConvertTo-PolicyHash sorts unordered set-shaped fields (issue #235)' {

    It 'sorts labels: into the same canonical order regardless of YAML order' {
        $entryAuthorOrder = @{
            name             = 'p1'
            mode             = 'Enable'
            exchangeLocation = @('All')
            labels           = @('Public', 'General', 'Confidential')
        }
        $entryAlphaOrder = @{
            name             = 'p1'
            mode             = 'Enable'
            exchangeLocation = @('All')
            labels           = @('Confidential', 'General', 'Public')
        }
        $hAuthor = ConvertTo-PolicyHash -Entry $entryAuthorOrder
        $hAlpha  = ConvertTo-PolicyHash -Entry $entryAlphaOrder
        ($hAuthor.labels -join ',') | Should -Be ($hAlpha.labels -join ',')
    }

    It 'sorts exchangeLocation: into the same canonical order regardless of YAML order' {
        $entryA = @{
            name             = 'p1'
            mode             = 'Enable'
            exchangeLocation = @('user1@contoso.com', 'user2@contoso.com')
            labels           = @('Public')
        }
        $entryB = @{
            name             = 'p1'
            mode             = 'Enable'
            exchangeLocation = @('user2@contoso.com', 'user1@contoso.com')
            labels           = @('Public')
        }
        $hA = ConvertTo-PolicyHash -Entry $entryA
        $hB = ConvertTo-PolicyHash -Entry $entryB
        ($hA.exchangeLocation -join ',') | Should -Be ($hB.exchangeLocation -join ',')
    }
}

Describe 'Full hash round-trip: desired (any order) vs tenant (alphabetized)' {

    It 'desired YAML in author order compares equal to tenant returning alphabetized labels' {
        # Simulate the exact scenario from the workflow run that
        # surfaced this bug: YAML has labels in author order, tenant
        # Get-LabelPolicy.Labels returns them alphabetized.
        $desiredEntry = @{
            name             = 'Lab-Default-Files-Emails'
            mode             = 'Enable'
            exchangeLocation = @('All')
            labels           = @('Public', 'General', 'Confidential', 'Highly Confidential')
        }
        $tenantPolicy = [pscustomobject]@{
            Name             = 'Lab-Default-Files-Emails'
            Guid             = '00000000-0000-0000-0000-0000000000ff'
            Mode             = 'Enable'
            Status           = 'Published'
            ExchangeLocation = @([pscustomobject]@{ DisplayName = 'All' })
            Labels           = @('Confidential', 'General', 'Highly Confidential', 'Public')
            Settings         = @()
        }
        $desiredHash = ConvertTo-PolicyHash -Entry $desiredEntry
        $tenantHash  = ConvertTo-TenantPolicyHash -Policy $tenantPolicy -TenantLabels @()
        Compare-PolicyHash -Desired $desiredHash -Tenant $tenantHash | Should -BeNullOrEmpty
    }
}
