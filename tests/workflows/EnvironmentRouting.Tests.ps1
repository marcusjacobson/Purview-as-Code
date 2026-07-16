#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    ENVIRONMENT ROUTING IS A CONTRACT, SO A TEST PINS IT.

    ADR 0057 gives every tenant-touching workflow one routing contract:

      * an `environment` workflow_dispatch input (choice `lab` | `dev`,
        default `lab`), so an operator can aim any run at either GitHub
        Environment;
      * a job-level `environment:` declaration derived from that input, so the
        OIDC federated-credential subject
        (`repo:<org>/<repo>:environment:<environment>`, ADR 0010) matches at
        token-exchange time. Push/schedule runs map branch `dev` -> `dev` and
        every other branch -> `lab` via the canonical expression; dispatch-only
        workflows (no push trigger, so `inputs` is always populated) may use
        the short form; kv-temp-unlock pairs to the dedicated unlock
        environments instead (`lab` -> `kv-unlock`, `dev` -> `kv-unlock-dev`)
        on BOTH of its jobs, because deployment protection rules are evaluated
        per job;
      * an environment-derived concurrency group where overlapping runs of the
        same surface could interleave (per-solution deploys/syncs, drift, the
        shared kv-firewall group), with `cancel-in-progress: false` retained;
      * NO functional tenant literal left in any workflow — tenant-specific
        values reach jobs only through the selected Environment's variables
        and secrets.

    The contract is byte-precise on purpose: sixteen workflows carry the same
    expression, and a seventeenth that paraphrases it ("main -> lab" spelled
    differently) would route somewhere else. This suite reads the SHIPPED
    workflow files — the same reasoning as the tests/data-plane/ guard tests:
    when the hazard is in the committed artefact, the test must read the
    committed artefact.

    PARSER GOTCHA, pinned here so nobody rediscovers it: YAML 1.1 parses the
    bare key `on` as the BOOLEAN true, so a parsed workflow's trigger block can
    sit under the key $true rather than the string 'on'. Get-TriggerBlock
    below guards both shapes.

    References:
      ADR 0057 — multi-environment and branch model (the contract under test)
      ADR 0010 — one OIDC federated credential per app, environment-scoped subject
      https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments
      https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#onworkflow_dispatchinputs
      https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#concurrency
      https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect
      https://pester.dev/docs/quick-start
#>

BeforeDiscovery {
    # The sixteen tenant-touching workflows and the routing shape each one is
    # REQUIRED to carry. Adding a seventeenth tenant-touching workflow means
    # adding a row here — that is the point: the routing contract is reviewed,
    # not inferred.
    #
    #   EnvKind:
    #     canonical      — job environment: uses the full branch-mapping expression
    #     dispatch-only  — no push/schedule identity risk: `inputs` always present
    #     unlock-paired  — kv-temp-unlock's dedicated unlock environments
    #   ConcurrencyKind:
    #     canonical-suffix     — group ends with the canonical expression
    #     kv-firewall-dispatch — the shared `kv-firewall-<env>` group (dispatch form)
    #     static               — deliberately serialized ACROSS environments
    #     none                 — no concurrency group
    $script:TenantWorkflows = @(
        @{ Name = 'deploy-infra.yml';                          EnvKind = 'dispatch-only'; ConcurrencyKind = 'none' }
        @{ Name = 'validate-oidc-auth.yml';                    EnvKind = 'dispatch-only'; ConcurrencyKind = 'kv-firewall-dispatch' }
        @{ Name = 'kv-temp-unlock.yml';                        EnvKind = 'unlock-paired'; ConcurrencyKind = 'kv-firewall-dispatch' }
        @{ Name = 'deploy-labels.yml';                         EnvKind = 'canonical';     ConcurrencyKind = 'canonical-suffix' }
        @{ Name = 'deploy-label-policies.yml';                 EnvKind = 'canonical';     ConcurrencyKind = 'canonical-suffix' }
        @{ Name = 'deploy-auto-label-policies.yml';            EnvKind = 'canonical';     ConcurrencyKind = 'canonical-suffix' }
        @{ Name = 'deploy-dlp.yml';                            EnvKind = 'canonical';     ConcurrencyKind = 'canonical-suffix' }
        @{ Name = 'deploy-irm.yml';                            EnvKind = 'canonical';     ConcurrencyKind = 'canonical-suffix' }
        @{ Name = 'sync-labels-from-tenant.yml';               EnvKind = 'canonical';     ConcurrencyKind = 'canonical-suffix' }
        @{ Name = 'sync-label-policies-from-tenant.yml';       EnvKind = 'canonical';     ConcurrencyKind = 'canonical-suffix' }
        @{ Name = 'sync-auto-label-policies-from-tenant.yml';  EnvKind = 'canonical';     ConcurrencyKind = 'canonical-suffix' }
        @{ Name = 'sync-dlp-from-tenant.yml';                  EnvKind = 'canonical';     ConcurrencyKind = 'canonical-suffix' }
        @{ Name = 'sync-irm-from-tenant.yml';                  EnvKind = 'canonical';     ConcurrencyKind = 'canonical-suffix' }
        @{ Name = 'drift-detection.yml';                       EnvKind = 'canonical';     ConcurrencyKind = 'canonical-suffix' }
        @{ Name = 'export-content-explorer.yml';               EnvKind = 'canonical';     ConcurrencyKind = 'none' }
        @{ Name = 'code-currency-watch.yml';                   EnvKind = 'canonical';     ConcurrencyKind = 'static' }
    )
}

BeforeAll {
    $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:WorkflowsDir = Join-Path $script:RepoRoot '.github/workflows'
    Import-Module 'powershell-yaml' -ErrorAction Stop

    # The contract expressions, byte for byte. Keep in lockstep with ADR 0057.
    $script:CanonicalEnvExpr    = '${{ inputs.environment || (github.ref_name == ''dev'' && ''dev'' || ''lab'') }}'
    $script:DispatchOnlyEnvExpr = '${{ inputs.environment || ''lab'' }}'
    $script:UnlockPairExpr      = '${{ inputs.environment == ''dev'' && ''kv-unlock-dev'' || ''kv-unlock'' }}'

    function Get-WorkflowDocument {
        param([string]$Name)
        $path = Join-Path $script:WorkflowsDir $Name
        if (-not (Test-Path -LiteralPath $path)) { throw "Workflow not found: $Name" }
        return (Get-Content -LiteralPath $path -Raw) | ConvertFrom-Yaml
    }

    function Get-TriggerBlock {
        # YAML 1.1 parses the bare key `on` as boolean true, so the trigger
        # block may be keyed by $true instead of the string 'on'.
        param([System.Collections.IDictionary]$Workflow)
        foreach ($key in $Workflow.Keys) {
            if ($key -is [bool] -and $key) { return $Workflow[$key] }
            if ([string]$key -eq 'on')     { return $Workflow[$key] }
        }
        return $null
    }

    function Get-JobEnvironmentValue {
        # Every job-level `environment:` declaration in the workflow, as
        # (JobName, Value) pairs. A declaration may be a scalar expression or
        # a { name, url } mapping; these workflows use the scalar form only.
        param([System.Collections.IDictionary]$Workflow)
        $out = [System.Collections.Generic.List[object]]::new()
        foreach ($jobName in $Workflow.jobs.Keys) {
            $job = $Workflow.jobs[$jobName]
            if ($job -is [System.Collections.IDictionary] -and $job.Contains('environment')) {
                $out.Add([pscustomobject]@{ Job = [string]$jobName; Value = $job['environment'] })
            }
        }
        return $out
    }

    # Parse each contract workflow exactly once.
    $script:Parsed = @{}
    foreach ($name in @(
            'deploy-infra.yml', 'validate-oidc-auth.yml', 'kv-temp-unlock.yml',
            'deploy-labels.yml', 'deploy-label-policies.yml', 'deploy-auto-label-policies.yml',
            'deploy-dlp.yml', 'deploy-irm.yml',
            'sync-labels-from-tenant.yml', 'sync-label-policies-from-tenant.yml',
            'sync-auto-label-policies-from-tenant.yml', 'sync-dlp-from-tenant.yml',
            'sync-irm-from-tenant.yml', 'drift-detection.yml',
            'export-content-explorer.yml', 'code-currency-watch.yml')) {
        $script:Parsed[$name] = Get-WorkflowDocument -Name $name
    }
}

Describe 'Environment routing — the sixteen tenant-touching workflows exist (the contract is not vacuous)' {

    It 'finds every workflow named in the contract table' -ForEach $script:TenantWorkflows {
        Test-Path -LiteralPath (Join-Path $script:WorkflowsDir $Name) |
            Should -BeTrue -Because "ADR 0057 names $Name as a tenant-touching workflow; if it was renamed, update this table in the same PR"
    }
}

Describe 'Environment routing — every tenant-touching workflow carries the environment dispatch input (ADR 0057)' {

    It '<Name> declares workflow_dispatch.inputs.environment as choice [lab, dev] defaulting to lab' -ForEach $script:TenantWorkflows {
        $trigger = Get-TriggerBlock -Workflow $script:Parsed[$Name]
        $trigger | Should -Not -BeNullOrEmpty -Because "$Name must declare triggers"
        $trigger.Contains('workflow_dispatch') | Should -BeTrue -Because "$Name must be manually dispatchable at a chosen environment"

        $dispatch = $trigger['workflow_dispatch']
        $dispatch | Should -Not -BeNullOrEmpty -Because "$Name workflow_dispatch must declare inputs"
        $dispatch.Contains('inputs') | Should -BeTrue
        $dispatch.inputs.Contains('environment') | Should -BeTrue -Because "$Name must expose the environment selector"

        $envInput = $dispatch.inputs['environment']
        [string]$envInput.type    | Should -Be 'choice'
        @($envInput.options)      | Should -Be @('lab', 'dev') -Because 'the template ships exactly the lab and dev routes (ADR 0057)'
        [string]$envInput.default | Should -Be 'lab' -Because 'lab is the backward-compatible default for existing single-environment spin-offs'
    }
}

Describe 'Environment routing — job environment declarations match the OIDC subject contract (ADR 0010 / ADR 0057)' {

    It '<Name> derives every job environment from the canonical branch-mapping expression' -ForEach ($script:TenantWorkflows | Where-Object { $_.EnvKind -eq 'canonical' }) {
        $declared = @(Get-JobEnvironmentValue -Workflow $script:Parsed[$Name])
        $declared.Count | Should -BeGreaterThan 0 -Because "$Name must declare a GitHub Environment or its OIDC subject cannot be environment-scoped"
        foreach ($d in $declared) {
            [string]$d.Value | Should -BeExactly $script:CanonicalEnvExpr -Because (
                "$Name job '$($d.Job)' must use the byte-identical canonical expression: push/schedule " +
                'runs map branch dev -> dev and every other branch -> lab; a paraphrase routes differently')
        }
    }

    It '<Name> (dispatch-only) derives every job environment from the dispatch input with the lab fallback' -ForEach ($script:TenantWorkflows | Where-Object { $_.EnvKind -eq 'dispatch-only' }) {
        $declared = @(Get-JobEnvironmentValue -Workflow $script:Parsed[$Name])
        $declared.Count | Should -BeGreaterThan 0
        foreach ($d in $declared) {
            [string]$d.Value | Should -BeExactly $script:DispatchOnlyEnvExpr -Because (
                "$Name has no push/schedule trigger, so inputs.environment is always present and " +
                'the short dispatch form is the permitted variant (ADR 0057)')
        }
    }

    It 'kv-temp-unlock.yml pairs BOTH jobs to the selected unlock environment (lab -> kv-unlock, dev -> kv-unlock-dev)' {
        $wf = $script:Parsed['kv-temp-unlock.yml']
        @($wf.jobs.Keys).Count | Should -Be 2 -Because 'the approval surface and the Azure-acting surface are deliberately separate jobs'

        $declared = @(Get-JobEnvironmentValue -Workflow $wf)
        $declared.Count | Should -Be 2 -Because (
            'deployment protection rules are evaluated per job, and the kv-unlock OIDC subject is ' +
            'environment-scoped — BOTH jobs must declare the unlock environment or one of the two ' +
            'guarantees (approval gate, token exchange) silently breaks')
        foreach ($d in $declared) {
            [string]$d.Value | Should -BeExactly $script:UnlockPairExpr -Because (
                "kv-temp-unlock job '$($d.Job)' must pair lab -> kv-unlock and dev -> kv-unlock-dev")
        }
    }
}

Describe 'Environment routing — concurrency groups are environment-derived (ADR 0057)' {

    It '<Name> scopes its concurrency group to the selected environment and keeps cancel-in-progress false' -ForEach ($script:TenantWorkflows | Where-Object { $_.ConcurrencyKind -eq 'canonical-suffix' }) {
        $wf = $script:Parsed[$Name]
        $wf.Contains('concurrency') | Should -BeTrue -Because "$Name serializes runs per surface, per environment"
        $group = [string]$wf.concurrency.group
        $group | Should -BeLike "*-$script:CanonicalEnvExpr" -Because (
            "$Name's group must be environment-derived so a lab run and a dev run never queue " +
            'behind (or clobber) each other')
        $wf.concurrency['cancel-in-progress'] | Should -BeFalse -Because (
            'an in-flight apply must reach its cleanup/re-lock steps; cancellation mid-apply is the ' +
            'failure mode these groups exist to prevent')
    }

    It '<Name> shares the per-environment kv-firewall concurrency group' -ForEach ($script:TenantWorkflows | Where-Object { $_.ConcurrencyKind -eq 'kv-firewall-dispatch' }) {
        $wf = $script:Parsed[$Name]
        $wf.Contains('concurrency') | Should -BeTrue
        [string]$wf.concurrency.group | Should -BeExactly "kv-firewall-$script:DispatchOnlyEnvExpr" -Because (
            "$Name toggles an environment's Key Vault firewall: every workflow that touches the same " +
            "environment's vault must share ONE group (two overlapping toggles can clobber each " +
            "other's re-lock), while different environments' vaults are independent and must not queue")
        $wf.concurrency['cancel-in-progress'] | Should -BeFalse -Because (
            'a cancelled unlock must still reach its if: always() re-lock step')
    }
}

Describe 'Environment routing — no functional tenant literal remains in any workflow (ADR 0057)' {

    It 'no workflow hardcodes a contoso Key Vault, tenant domain, or bare lab environment binding' {
        # The residue shapes that would defeat environment routing: a literal
        # vault name, a literal tenant domain, or a job pinned to the lab
        # environment by literal (`environment: lab`) rather than derived by
        # expression. Environment-specific values reach jobs only through the
        # selected GitHub Environment's variables and secrets.
        $pattern = 'KEY_VAULT_NAME:.*contoso|TENANT_DOMAIN:.*contoso|environment: lab$'
        $hits = [System.Collections.Generic.List[string]]::new()

        foreach ($file in (Get-ChildItem -Path $script:WorkflowsDir -Filter '*.yml' -File)) {
            $lineNo = 0
            foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
                $lineNo++
                if ($line -match $pattern) { $hits.Add("$($file.Name):${lineNo}: $($line.Trim())") }
            }
        }

        $hits.Count | Should -Be 0 -Because (
            'a hardcoded tenant literal in a workflow routes every environment at one tenant ' +
            'value, which is exactly the defect ADR 0057 removes. Offenders: ' + ($hits -join '; '))
    }
}
