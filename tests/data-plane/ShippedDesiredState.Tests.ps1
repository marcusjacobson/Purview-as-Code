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

    ADR 0056 GENERALISES THE RULE FROM TWO FILES TO ALL OF THEM.
    ADR 0055 shipped this file checking exactly two root lists — `roleGroups` and
    `directoryRoles` — out of thirty-one data-plane files. The other twenty-nine
    included `information-protection/auto-label-policies.yaml`, which shipped
    `Lab-AutoLabel-SSN` at `mode: Enable` / `exchangeLocation: [All]`: a live,
    enforcing, tenant-wide policy that stamps an encrypted label on any mail
    containing a U.S. Social Security Number. In a PUBLIC template. Two files out
    of thirty-one is not a control; it is a spot check that happened to look at
    the wrong spot.

    THE RULE IS NOW UNIFORM AND MECHANICAL:

        Every root LIST under data-plane/** ships EMPTY.

    A uniform rule cannot be eroded by judgment. A per-file "is this one safe
    enough to ship?" call is EXACTLY how the SSN policy shipped — its sibling in
    the same file was at `TestWithoutNotifications`, so simulation mode was known,
    considered, and not used.

    TEMPLATE AWARENESS (ADR 0045 / ADR 0046 / ADR 0055 / ADR 0056). This
    repository is a tenant-neutral TEMPLATE, and these assertions encode the
    TEMPLATE's shipped default. A tailored spin-off populates its desired state
    after the kickoff wizard, and the 'template ships empty' Context WILL fail in
    that spin-off. That is intended, and it is the mechanism: adopting a
    deployable governance surface should require a deliberate, reviewed edit to
    the test that guards it — not a silent YAML change nobody reads. The
    'every copy, forever' Contexts must keep passing in that spin-off regardless.

    BRANCH AWARENESS (ADR 0057). The empty-desired-state contract is a property
    of the TEMPLATE branch: main (and the operator repo's main, which mirrors
    upstream). An operator spin-off carries populated desired state on its
    dev / lab branches by design, so on those branches the EMPTINESS assertions
    (and only those) skip with a message. Every 'every copy, forever' assertion
    — parse integrity, carve-out pins, no-raw-principal-GUID, examples/** is
    inert — stays enforced on every branch of every copy.

    References:
      ADR 0057 — multi-environment and branch model (why emptiness is main-only)
      ADR 0056 — the template ships empty desired state (why this file is uniform)
      ADR 0055 — identifier-shaped residual scan (why this file exists)
      ADR 0035 — records seed content is immovable (the seed-skip carve-out)
      ADR 0023 — principals are named by displayName, never a raw object ID
      ADR 0017 — label auto-application shape (the fixture carve-out)
      ADR 0052 / ADR 0053 — the destructive-operation contract these lists feed
      https://pester.dev/docs/quick-start
#>

BeforeDiscovery {
    # ADR 0057: resolve the branch this run validates. In CI the GitHub-provided
    # variables are authoritative (GITHUB_BASE_REF on pull_request events,
    # GITHUB_REF_NAME on push); locally, fall back to the checked-out branch.
    # Reference: https://docs.github.com/en/actions/reference/workflows-and-actions/variables#default-environment-variables
    $script:TargetBranch = $null
    if ($env:GITHUB_BASE_REF) { $script:TargetBranch = $env:GITHUB_BASE_REF }
    elseif ($env:GITHUB_REF_NAME) { $script:TargetBranch = $env:GITHUB_REF_NAME }
    else {
        try {
            $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
            $script:TargetBranch = [string](& git -C $repoRoot rev-parse --abbrev-ref HEAD 2>$null)
        }
        catch { $script:TargetBranch = $null }
    }
    if (-not $script:TargetBranch) { $script:TargetBranch = 'main' }

    # Skip ONLY on the two operator branches. Any other branch — main, a template
    # feature branch, a detached HEAD — enforces, so the guard cannot be dodged
    # by working on a topic branch of the template.
    $script:SkipEmptyStateEnforcement = $script:TargetBranch.Trim() -in @('dev', 'lab')
    if ($script:SkipEmptyStateEnforcement) {
        $msg = ("ShippedDesiredState: target branch '{0}' is an operator branch — the ADR 0056 " +
            'empty-desired-state assertions are SKIPPED here and enforced on main only (ADR 0057). ' +
            'All every-copy-forever assertions still run.') -f $script:TargetBranch.Trim()
        Write-Information $msg -InformationAction Continue
    }
}

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

    # -------------------------------------------------------------------------
    # THE CARVE-OUTS. Three files, each named, each with its reason WRITTEN DOWN.
    #
    # A carve-out whose reason is recorded is a rule. A carve-out without one is
    # the erosion this ADR exists to prevent — and the erosion is not
    # hypothetical: `intentionalSamples` once carried four data-plane exclusions
    # commented "sample source names" / "sample scan targets", and all four were
    # false. The comment described why the line was ADDED and not what it DID.
    #
    # So: the reason is a first-class field here, the list is PINNED by its own
    # `It` below, and the pin cannot be relaxed without editing this test — which
    # is a visible review signal, not a silent YAML change.
    # -------------------------------------------------------------------------
    $script:Carveouts = @(
        [pscustomobject]@{
            Path   = 'data-plane/classifications/sit-catalog.yaml'
            Reason = @(
                'REFERENCE DATA, NOT DESIRED STATE — and emptying it would BREAK label deploys.'
                'Every entry is either `publisher: Microsoft Corporation` (a built-in SIT,'
                'identical in every tenant, tenant-INDEPENDENT and disclosing nothing) or a'
                'repo-managed custom SIT this repo''s own Deploy-SITRulePackages.ps1 reconciler'
                'deployed from sit-rule-packages.yaml (ADR 0061) — never a raw, unfiltered tenant'
                'discovery. Nothing else RECONCILES this file: there is no Deploy-SITs.ps1, and no'
                'script calls New-/Set-/Remove-DlpSensitiveInformationType except'
                'Sync-SITCatalog.ps1, which is the EXPORTER that generates this file from the SIT'
                'API. Every other consumer only READS it — Deploy-Labels.ps1:1244-1264,'
                'Deploy-AutoLabelPolicies.ps1:1432/1891, Invoke-SITConfidenceAnalysis.ps1:494.'
                'DECISIVE: Deploy-Labels.ps1:1262 ERRORS and RETURNS when a label references an'
                'autoApplicationOf sitId that is not in this catalog. An empty catalog therefore'
                'converts a working reference into a deploy-breaking one — every label carrying'
                'autoApplicationOf fails to reconcile. This carve-out makes the repo SAFER, which'
                'is the only kind of carve-out this rule admits.'
            ) -join ' '
        }
        [pscustomobject]@{
            Path   = 'data-plane/records/seed-skip-names.yaml'
            Reason = @(
                'A SAFETY INPUT, NOT DESIRED STATE — emptying it would make the repo LESS safe.'
                '`seedSkipNames` is a SKIP list: 31 names the File Plan reconciler must NOT touch'
                '(ADR 0035 Decision 3). Deploy-FilePlan.ps1 UNIONS them into the effective skip'
                'set on every run. The polarity is inverted relative to every other list in this'
                'tree: a populated entry here REMOVES an object from the plan; an empty list ADDS'
                '31 objects back into a -PruneMissing run. Those 31 are Microsoft-provisioned File'
                'Plan Manager seed content, UNDELETABLE on the documented IPPS surface (every'
                'Remove-FilePlanProperty* against them fails with ErrorRuleNotFoundException), so'
                'emptying this produces 31 Failed plan rows on every prune — noise that trains'
                'operators to ignore prune output, which is exactly how a real deletion gets waved'
                'through. The names are Microsoft seed content ("Accounts payable", "Sarbanes-Oxley'
                'Act of 2002", ...), identical in every tenant, and disclose nothing.'
            ) -join ' '
        }
        [pscustomobject]@{
            Path   = 'data-plane/information-protection/labels.autoApplicationOf.fixture.yaml'
            Reason = @(
                'A TEST FIXTURE, NOT DESIRED STATE. Named for what it is (`.fixture.yaml`) and'
                'documented as such by ADR 0017. NO reconciler reads it: Deploy-Labels.ps1 defaults'
                'its -Path to labels.yaml on both the Apply and the ExportCurrentState path, and no'
                'workflow passes this file to anything. It exists for ad-hoc `Test-Json` validation'
                'of labels.schema.json. Its two entries are synthetic and its two sitId values are'
                'Microsoft built-in SIT IDs. Verified by the `no reconciler reads it` It below,'
                'which greps scripts/ and .github/workflows/ rather than taking this on trust.'
            ) -join ' '
        }
    )

    $script:CarveoutPaths = @($script:Carveouts.Path)

    # Every non-schema YAML shipped under data-plane/.
    $script:ShippedYamlFiles = @(
        Get-ChildItem -Path (Join-Path $script:RepoRoot 'data-plane') -Recurse -File -Filter '*.yaml' |
            Where-Object { $_.Name -notlike '*.schema.*' } |
            Sort-Object FullName
    )

    function Get-RelativeDataPlanePath {
        param([System.IO.FileInfo]$File)
        return $File.FullName.Substring($script:RepoRoot.Length + 1).Replace('\', '/')
    }
    $script:GetRelativeDataPlanePath = ${function:Get-RelativeDataPlanePath}
}

Describe 'Shipped desired state — EVERY root list under data-plane/** ships EMPTY (ADR 0056)' {

    BeforeAll {
        ${function:Get-ShippedYaml}            = $script:GetShippedYaml
        ${function:Get-RelativeDataPlanePath}  = $script:GetRelativeDataPlanePath

        # Parse every shipped YAML once and record, per file, every ROOT key whose
        # value is a LIST (an IEnumerable that is not a string and not a map) and
        # how many entries it holds.
        $script:RootLists = [System.Collections.Generic.List[object]]::new()
        $script:ParseFailures = [System.Collections.Generic.List[string]]::new()
        $script:FilesParsed = 0

        foreach ($file in $script:ShippedYamlFiles) {
            $relative = Get-RelativeDataPlanePath -File $file
            $doc = $null
            try { $doc = (Get-Content -LiteralPath $file.FullName -Raw) | ConvertFrom-Yaml }
            catch {
                # A shipped YAML that does not parse is a defect in its own right and
                # must NOT be silently skipped — that is how a guard test goes green
                # by reading nothing. Recorded and asserted on below.
                $script:ParseFailures.Add("$relative :: $($_.Exception.Message)")
                continue
            }
            $script:FilesParsed++
            if ($null -eq $doc -or $doc -isnot [System.Collections.IDictionary]) { continue }

            foreach ($key in $doc.Keys) {
                $value = $doc[$key]
                $isList = ($value -is [System.Collections.IEnumerable]) -and
                          ($value -isnot [string]) -and
                          ($value -isnot [System.Collections.IDictionary])
                if (-not $isList) { continue }
                $script:RootLists.Add([pscustomobject]@{
                        File  = $relative
                        Key   = [string]$key
                        Count = @($value).Count
                    })
            }
        }
    }

    # ---- Non-vacuity. A guard test that silently loads nothing is worse than no
    # ---- guard test, because it is trusted. Assert the inputs BEFORE the rule.

    It 'parses every shipped data-plane YAML (no file is silently skipped)' {
        $script:ParseFailures | Should -BeNullOrEmpty -Because (
            'a shipped data-plane YAML that does not parse cannot be checked, and an ' +
            'unchecked file is exactly where the last two disclosures lived. Failures: ' +
            ($script:ParseFailures -join '; '))
        $script:FilesParsed | Should -Be $script:ShippedYamlFiles.Count
    }

    It 'finds the shipped data-plane YAMLs and at least 25 root lists (the rule is not vacuously satisfied)' {
        # 31 non-schema YAMLs today. If a refactor moves the tree, this fails loudly
        # rather than passing over an empty file set.
        $script:ShippedYamlFiles.Count | Should -BeGreaterThan 25
        $script:RootLists.Count        | Should -BeGreaterThan 25
    }

    # ---- THE RULE. Enforced on main only (ADR 0057): an operator spin-off
    # ---- populates desired state on its dev / lab branches by design.

    It 'ships EVERY root list empty, except the three named carve-outs' -Skip:$script:SkipEmptyStateEnforcement {
        $violations = [System.Collections.Generic.List[string]]::new()

        foreach ($rl in $script:RootLists) {
            if ($script:CarveoutPaths -contains $rl.File) { continue }
            if ($rl.Count -ne 0) {
                $violations.Add("$($rl.File) :: $($rl.Key) has $($rl.Count) entry(ies)")
            }
        }

        $violations.Count | Should -Be 0 -Because (
            "ADR 0056: the template ships NOTHING deployable. A populated root list is " +
            "DEPLOYABLE DESIRED STATE — a consumer who clicks 'Use this template' and " +
            "dispatches the deploy workflow gets every entry created in THEIR tenant. Only " +
            "an EMPTY ROOT LIST is a true no-op; `members: []` on a LISTED object means " +
            "'revoke everything'. If you are adopting this solution in a spin-off, populate " +
            "the list AND edit this test deliberately. If you are the template, empty it and " +
            "put the worked example under examples/**. Violations: " + ($violations -join '; '))
    }

    # ---- THE CARVE-OUTS. Pinned, reasoned, and each one verified — not asserted.

    It 'PINS the carve-out list to exactly the three known files, BY NAME' {
        # This pin is the whole defence. `intentionalSamples` once carried four
        # data-plane exclusions asserting those files were "samples". All four were
        # false, and the SSN policy shipped behind them. A carve-out list that can
        # grow silently is not a carve-out list, it is an escape hatch.
        #
        # Adding a fourth carve-out requires editing THIS line, in a reviewed PR,
        # with a Reason string that survives the reader's eye.
        $script:CarveoutPaths | Should -HaveCount 3
        $script:CarveoutPaths | Should -Contain 'data-plane/classifications/sit-catalog.yaml'
        $script:CarveoutPaths | Should -Contain 'data-plane/records/seed-skip-names.yaml'
        $script:CarveoutPaths | Should -Contain 'data-plane/information-protection/labels.autoApplicationOf.fixture.yaml'
    }

    It 'gives every carve-out a written reason (a carve-out without one is the erosion)' {
        foreach ($c in $script:Carveouts) {
            $c.Reason | Should -Not -BeNullOrEmpty -Because "$($c.Path) must say WHY it is exempt"
            # Long enough to be an argument, not a shrug. 'sample data' is 11 characters.
            $c.Reason.Length | Should -BeGreaterThan 200 -Because (
                "$($c.Path)'s exemption must be a reason a reviewer can disagree with, not a label")
        }
    }

    It 'carve-out 1: sit-catalog.yaml stays POPULATED and is Microsoft reference data' {
        # Emptying it would break Deploy-Labels.ps1:1262, which errors when a label's
        # autoApplicationOf sitId is absent from the catalog. This assertion is the
        # inverse of the rule: the file MUST NOT be empty.
        $doc = Get-ShippedYaml -RelativePath 'data-plane/classifications/sit-catalog.yaml'
        $doc | Should -Not -BeNullOrEmpty
        $sits = @($doc.sits)
        $sits.Count | Should -BeGreaterThan 300 -Because 'the SIT catalog is load-bearing for label auto-application validation'

        # Tenant-independence is the licence for shipping it -- EXCEPT for SITs this repo's
        # own reconciler deployed (ADR 0061): Deploy-SITRulePackages.ps1 manages custom SITs
        # declared in sit-rule-packages.yaml, and they enter this catalog only via a later,
        # deliberate `Sync-SITCatalog.ps1 -ExportCurrentState` (never a raw, unfiltered
        # overwrite -- a full re-export also surfaces un-managed tenant-local discoveries,
        # e.g. document-fingerprint / EDM SITs whose `publisher` is the tenant's own
        # `*.onmicrosoft.com` domain, real tenant data that must never land in this PUBLIC
        # file, #48 Phase 3). So a non-Microsoft entry is allowed ONLY if its id is declared
        # in the manifest; anything else is either an un-managed discovery or a genuine leak.
        $manifestDoc = Get-ShippedYaml -RelativePath 'data-plane/classifications/sit-rule-packages.yaml'
        $repoManagedIds = @(
            @($manifestDoc.rulePackages) | ForEach-Object { @($_.sits) | ForEach-Object { [string]$_.id } }
        ) | Where-Object { $_ }
        $nonMicrosoft = @($sits | Where-Object { [string]$_.publisher -ne 'Microsoft Corporation' })
        $unclaimed = @($nonMicrosoft | Where-Object { $repoManagedIds -notcontains [string]$_.id })
        $unclaimed.Count | Should -Be 0 -Because (
            'every non-Microsoft entry must be a SIT this repo''s own Deploy-SITRulePackages.ps1 ' +
            'reconciler deployed (its id must be declared in sit-rule-packages.yaml, ADR 0061). ' +
            'An un-managed tenant-local discovery or any other real tenant data in this catalog ' +
            'would disclose the tenant. Offenders: ' + (($unclaimed | Select-Object -First 5).name -join ', '))
    }

    It 'carve-out 1: no UNSANCTIONED script CREATES, UPDATES, or PRUNES a SIT' {
        # The carve-out rests on "nothing reconciles the CATALOG". Verify it against the
        # source rather than taking the ADR's word for it — the ADR could go stale, this
        # assertion cannot. The regex is unanchored, so it also matches the
        # *-DlpSensitiveInformationTypeRulePackage cmdlet family as a substring.
        $scriptDir = Join-Path $script:RepoRoot 'scripts'
        $writers = @(
            Get-ChildItem -Path $scriptDir -Filter '*.ps1' -File |
                Where-Object {
                    (Get-Content -LiteralPath $_.FullName -Raw) -match
                    '(New|Set|Remove)-DlpSensitiveInformationType'
                } |
                Select-Object -ExpandProperty Name
        )
        # Two scripts are SANCTIONED writers, and NEITHER makes sit-catalog.yaml desired state:
        #   * Sync-SITCatalog.ps1        — the EXPORTER (reads the SIT API, regenerates the catalog).
        #   * Deploy-SITRulePackages.ps1 — the custom-SIT rule-package reconciler (ADR 0061). It
        #     manages a SEPARATE desired-state surface (sit-rule-packages.yaml + rule-packages/*.xml)
        #     via the *RulePackage cmdlets; it does NOT read or write sit-catalog.yaml (asserted
        #     separately below). Custom SITs enter the catalog only via a later export.
        # Anything ELSE here means a new writer exists that this carve-out has not vetted.
        $sanctioned = @('Sync-SITCatalog.ps1', 'Deploy-SITRulePackages.ps1')
        $unexpected = @($writers | Where-Object { $_ -notin $sanctioned })
        $unexpected.Count | Should -Be 0 -Because (
            'the sit-catalog carve-out rests on the catalog being READ-ONLY reference data. ' +
            'A NEW (unsanctioned) script that writes SITs must be vetted against that premise. ' +
            'Offenders: ' + ($unexpected -join ', '))
    }

    It 'carve-out 1: the rule-package reconciler''s desired-state file is the manifest, not the catalog' {
        # The above widens the sanctioned writer set to include Deploy-SITRulePackages.ps1.
        # That is only safe because the rule-package reconciler owns a DIFFERENT file. Pin
        # that here via its -Path default: its desired state is sit-rule-packages.yaml, and
        # it does NOT default to sit-catalog.yaml. If that ever changes, the catalog has
        # become desired state and the carve-out is void (ADR 0061 decision 7). (Prose that
        # merely NAMES sit-catalog.yaml to explain the boundary is fine — hence the check is
        # on the parameter default, not a blanket string search.)
        $reconciler = Join-Path $script:RepoRoot 'scripts' 'Deploy-SITRulePackages.ps1'
        Test-Path -LiteralPath $reconciler | Should -BeTrue
        $src = Get-Content -LiteralPath $reconciler -Raw
        $src | Should -Match '\$Path\s*=\s*\(Join-Path[^\r\n]*sit-rule-packages\.yaml'
        $src | Should -Not -Match '\$Path\s*=\s*\(Join-Path[^\r\n]*sit-catalog\.yaml'
    }

    It 'carve-out 2: seed-skip-names.yaml stays POPULATED — it is a skip list, and emptying it is LESS safe' {
        $doc = Get-ShippedYaml -RelativePath 'data-plane/records/seed-skip-names.yaml'
        $doc | Should -Not -BeNullOrEmpty
        # ADR 0035 Decision 3 mandates a 31-name baseline, verbatim. Operators may EXTEND
        # it at the command line; they may not SHRINK it there. Shrinking means editing
        # the file in a reviewed PR — which now also means editing this number.
        @($doc.seedSkipNames).Count | Should -Be 31 -Because (
            'ADR 0035 Decision 3 pins the seed-skip baseline at 31 names. This list is a ' +
            'SAFETY input with inverted polarity: emptying it does not make the reconciler ' +
            'do nothing, it makes -PruneMissing plan against 31 undeletable Microsoft seed ' +
            'objects and produce 31 Failed rows on every run.')
    }

    It 'carve-out 3: no reconciler and no workflow reads the autoApplicationOf fixture' {
        # The fixture carve-out rests on "no reconciler reads it as desired state".
        # Verify it: grep scripts/ and .github/workflows/ for the filename.
        $needle = 'labels.autoApplicationOf.fixture'
        $readers = @(
            @(Get-ChildItem -Path (Join-Path $script:RepoRoot 'scripts') -Filter '*.ps1' -File -Recurse) +
            @(Get-ChildItem -Path (Join-Path $script:RepoRoot '.github/workflows') -Filter '*.yml' -File) |
                Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -like "*$needle*" } |
                Select-Object -ExpandProperty Name
        )
        $readers.Count | Should -Be 0 -Because (
            'the fixture carve-out (ADR 0017) rests on nothing consuming it as desired state. ' +
            'If a script or workflow now reads it, it IS desired state and must ship empty. ' +
            'Readers: ' + ($readers -join ', '))
    }
}

Describe 'Shipped desired state — the CONFIG-MAPPING ruling (ADR 0056 Decision 4)' {

    # THE RULING, STATED: config mappings are OUT of the empty-root-list rule, and IN
    # a rule of their own.
    #
    # `dspm/dspm-config.yaml` and `dspm-ai/dspm-ai-config.yaml` have root keys that are
    # MAPPINGS (`scope`, `export`, `posture`), not lists. "Every root list is empty" is
    # therefore VACUOUSLY TRUE for them — and a rule that is vacuously satisfied is the
    # exact bug class this repo keeps hitting. So the ruling is made explicit and checked,
    # rather than left to be true by accident:
    #
    #   1. THEY ARE NOT DESIRED STATE. There is no Deploy-DSPM*.ps1. Their only consumers
    #      are READ-ONLY verifiers (Test-DSPMPosture.ps1, Test-DSPMforAIPosture.ps1) and a
    #      READ-ONLY exporter (Export-ContentExplorerData.ps1). ADR 0022 records that
    #      Microsoft Learn documents no programmatic authoring API for DSPM for AI at all.
    #      Zero tenant writes, so there is nothing for a consumer's first dispatch to
    #      create in their tenant. That is the whole hazard, and these files do not carry
    #      it.
    #
    #   2. THEY CARRY NO TENANT-SPECIFIC VALUES. Their contents are repo-relative file
    #      paths, Microsoft-published workload and role-group names, and numeric knobs.
    #
    # Both properties are asserted below, so the ruling is a check and not a claim. If
    # someone later adds a root LIST to one of these files, the uniform rule in the
    # Describe above catches it automatically — they are not exempted from it, they simply
    # have nothing for it to bite on today.

    BeforeAll { ${function:Get-ShippedYaml} = $script:GetShippedYaml }

    It 'dspm-config.yaml and dspm-ai-config.yaml carry NO root list at all (the rule bites on nothing here — by structure, not by exemption)' {
        foreach ($rel in @('data-plane/dspm/dspm-config.yaml', 'data-plane/dspm-ai/dspm-ai-config.yaml')) {
            $doc = Get-ShippedYaml -RelativePath $rel
            $doc | Should -Not -BeNullOrEmpty -Because "$rel must exist and parse"
            foreach ($key in $doc.Keys) {
                $value = $doc[$key]
                $isList = ($value -is [System.Collections.IEnumerable]) -and
                          ($value -isnot [string]) -and
                          ($value -isnot [System.Collections.IDictionary])
                $isList | Should -BeFalse -Because (
                    "$rel root key '$key' is a LIST. ADR 0056 Decision 4 rules these files IN " +
                    'as config mappings on the premise that they carry no root list. A root list ' +
                    'here is desired state wearing a config hat: either empty it (the uniform ' +
                    'rule) or re-litigate the ruling.')
            }
        }
    }

    It 'no Deploy-* reconciler reads the DSPM config files (they are read-only posture inputs, not desired state)' {
        $deployScripts = @(Get-ChildItem -Path (Join-Path $script:RepoRoot 'scripts') -Filter 'Deploy-*.ps1' -File)
        $offenders = @(
            $deployScripts |
                Where-Object {
                    $raw = Get-Content -LiteralPath $_.FullName -Raw
                    $raw -like '*dspm-config*' -or $raw -like '*dspm-ai-config*'
                } |
                Select-Object -ExpandProperty Name
        )
        $offenders.Count | Should -Be 0 -Because (
            'the config-mapping ruling rests on there being NO reconciler behind these files. ' +
            'A Deploy-* script that reads one makes it desired state. Offenders: ' +
            ($offenders -join ', '))
    }

    It 'the DSPM config sources point only at repo-relative data-plane paths (no tenant values)' {
        foreach ($rel in @('data-plane/dspm/dspm-config.yaml', 'data-plane/dspm-ai/dspm-ai-config.yaml')) {
            $doc = Get-ShippedYaml -RelativePath $rel
            foreach ($selector in @('labels', 'sits')) {
                if (-not $doc.scope.ContainsKey($selector)) { continue }
                foreach ($src in @($doc.scope[$selector].sources)) {
                    [string]$src | Should -Match '^data-plane/' -Because (
                        "$rel scope.$selector.sources must reference repo-relative desired-state " +
                        'files, never a tenant identifier or an absolute path')
                    Test-Path -LiteralPath (Join-Path $script:RepoRoot $src) | Should -BeTrue -Because (
                        "$rel references '$src', which must exist")
                }
            }
        }
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
    #
    # ADR 0056 widens the scan to examples/** as well. Relocating content to an
    # examples tree RELOCATES a disclosure; it does not remove one. The examples are
    # scrubbed, and this is one of the two mechanisms that keeps them that way (the
    # other is scripts/Test-IdentifierResidue.ps1, which has no path exclusions at
    # all and therefore reads examples/** like everything else).

    BeforeAll {
        ${function:Get-ShippedYaml} = $script:GetShippedYaml

        # Walk every shipped YAML and collect the scalar value of every key whose name
        # denotes a principal, plus every item of a principal list.
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

        # data-plane/** AND examples/** — see the note above.
        $script:ScannedYamlFiles = @(
            @(Get-ChildItem -Path (Join-Path $script:RepoRoot 'data-plane') -Recurse -File -Filter '*.yaml') +
            @(Get-ChildItem -Path (Join-Path $script:RepoRoot 'examples')   -Recurse -File -Filter '*.yaml' -ErrorAction SilentlyContinue) |
                Where-Object { $_.Name -notlike '*.schema.*' }
        )
    }

    It 'finds and parses the shipped YAMLs under data-plane/ AND examples/ (the test is not vacuously green)' {
        $script:ScannedYamlFiles.Count | Should -BeGreaterThan 5
        # examples/ must actually be reached — a typo'd path here would silently
        # un-scan the tree the content moved INTO, which is the failure mode of the
        # whole ADR performed on its own guard test.
        @($script:ScannedYamlFiles | Where-Object { $_.FullName -like '*examples*' }).Count |
            Should -BeGreaterThan 5 -Because 'examples/** must be in scope: relocating content relocates the disclosure'
    }

    It 'carries no raw GUID under any principal key in any shipped data-plane or examples YAML' {
        $violations = [System.Collections.Generic.List[string]]::new()

        foreach ($file in $script:ScannedYamlFiles) {
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

Describe 'Shipped desired state — examples/** is documentation, not a deploy path (ADR 0056)' {

    # The examples tree only works as a safety mechanism if NOTHING reads it. If a
    # workflow or a reconciler ever points at examples/, the directory boundary
    # evaporates and the content is back in a deploy path — with the added hazard
    # that everyone now believes it is inert.

    It 'no script and no workflow reads anything under examples/' {
        $offenders = [System.Collections.Generic.List[string]]::new()

        $candidates = @(
            @(Get-ChildItem -Path (Join-Path $script:RepoRoot 'scripts') -Filter '*.ps1' -File -Recurse) +
            @(Get-ChildItem -Path (Join-Path $script:RepoRoot '.github/workflows') -Filter '*.yml' -File)
        )
        foreach ($f in $candidates) {
            $raw = Get-Content -LiteralPath $f.FullName -Raw
            # `examples/` as a PATH reference. Prose mentions ("see examples/README.md")
            # are what the -notmatch guards below allow; a -Path / default-parameter
            # binding is what must never appear.
            foreach ($line in ($raw -split "`r?`n")) {
                if ($line -match 'examples[/\\]data-plane') {
                    if ($line -match '^\s*#') { continue }        # PowerShell comment
                    if ($line -match '^\s*//') { continue }
                    if ($line -match '^\s*#\s') { continue }
                    $offenders.Add("$($f.Name) :: $($line.Trim())")
                }
            }
        }

        $offenders.Count | Should -Be 0 -Because (
            'examples/** is a documentation tree. The moment a script or workflow reads it, ' +
            'it becomes a deploy path again and the ADR 0056 directory boundary is gone — ' +
            'while everyone keeps believing it is inert, which is worse than before. ' +
            'Offenders: ' + ($offenders -join '; '))
    }

    It 'every emptied data-plane file has a worked example to point at' {
        # Not a safety property — a usability one. The rule "the template ships nothing
        # deployable" is only tolerable if the knowledge is not deleted with the data.
        $expected = @(
            'examples/data-plane/collections/collections.yaml'
            'examples/data-plane/data-sources/data-sources.yaml'
            'examples/data-plane/scans/scans.yaml'
            'examples/data-plane/dlp/policies.yaml'
            'examples/data-plane/information-protection/labels.yaml'
            'examples/data-plane/information-protection/label-policies.yaml'
            'examples/data-plane/information-protection/auto-label-policies.yaml'
            'examples/data-plane/irm/policies.yaml'
            'examples/data-plane/glossary/glossary.yaml'
            'examples/data-plane/classifications/classifications.yaml'
            'examples/data-plane/adaptive-scopes/scopes.yaml'
        )
        foreach ($rel in $expected) {
            Test-Path -LiteralPath (Join-Path $script:RepoRoot $rel) |
                Should -BeTrue -Because "ADR 0056 moves the worked content here, it does not delete it: $rel"
        }
    }

    It 'the enforcing SSN auto-label policy is not DEFINED anywhere — not in data-plane, not in examples' {
        # The single most important assertion in this file. `Lab-AutoLabel-SSN` was a
        # live, enforcing, tenant-wide policy in a public template. It is DELETED — not
        # emptied, not commented out, not relocated to examples/. It does not come back
        # as an example and it does not come back as a fixture.
        #
        # This hunts a DEFINITION — an uncommented YAML `name:` key binding that value —
        # not a mention. Naming the defect in prose is REQUIRED, not forbidden: ADR 0056,
        # the CHANGELOG, the header comments on the emptied file, and this test all say
        # `Lab-AutoLabel-SSN` out loud, and must keep being able to. A rule that forbade
        # the name would forbid the record of why the rule exists.
        $hits = [System.Collections.Generic.List[string]]::new()
        foreach ($root in @('data-plane', 'examples')) {
            $dir = Join-Path $script:RepoRoot $root
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            foreach ($f in (Get-ChildItem -Path $dir -Recurse -File -Include '*.yaml', '*.yml')) {
                $rel = $f.FullName.Substring($script:RepoRoot.Length + 1).Replace('\', '/')
                $lineNo = 0
                foreach ($line in (Get-Content -LiteralPath $f.FullName)) {
                    $lineNo++
                    if ($line -match '^\s*#') { continue }                       # a comment is prose
                    if ($line -match '^\s*-?\s*name\s*:\s*["'']?Lab-AutoLabel-SSN') {
                        $hits.Add("${rel}:${lineNo}")
                    }
                }
            }
        }
        $hits.Count | Should -Be 0 -Because (
            'Lab-AutoLabel-SSN (mode: Enable, exchangeLocation: [All]) is DELETED, not ' +
            'preserved. A public template must not carry a definition of an enforcing, ' +
            'tenant-wide SSN auto-labeling policy — in a deploy path or in an examples ' +
            'tree. Defined at: ' + ($hits -join ', '))
    }

    It 'no auto-label policy anywhere in data-plane/ or examples/ ships at mode: Enable' -Skip:$script:SkipEmptyStateEnforcement {
        # The generalisation of the assertion above. Blocking one policy by NAME is a
        # blocklist, and a blocklist only catches the instance you already found. The
        # hazard is the SHAPE: an enforcing auto-label policy shipped in a public
        # template. Block the shape.
        #
        # Main-only (ADR 0057): on an operator's dev / lab branch an enforcing
        # policy is a legitimate END state — reached through the ADR 0016
        # promotion ladder, one destructive-labelled PR per step, in the
        # operator's own reviewed repo. What must never carry one is the
        # template (and the operator main that mirrors it).
        $hits = [System.Collections.Generic.List[string]]::new()
        foreach ($rel in @(
                'data-plane/information-protection/auto-label-policies.yaml'
                'examples/data-plane/information-protection/auto-label-policies.yaml'
            )) {
            $full = Join-Path $script:RepoRoot $rel
            if (-not (Test-Path -LiteralPath $full)) { continue }
            $lineNo = 0
            foreach ($line in (Get-Content -LiteralPath $full)) {
                $lineNo++
                if ($line -match '^\s*#') { continue }
                if ($line -match '^\s*mode\s*:\s*Enable\s*$') { $hits.Add("${rel}:${lineNo}") }
            }
        }
        $hits.Count | Should -Be 0 -Because (
            'simulation first (ADR 0016, project-plan guiding principle 3): an auto-label ' +
            'policy lands at TestWithoutNotifications and is promoted deliberately, one ' +
            'destructive-labelled PR per step. `mode: Enable` at: ' + ($hits -join ', '))
    }
}
