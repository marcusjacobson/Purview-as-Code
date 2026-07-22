#Requires -Version 7.4
<#
.SYNOPSIS
    Reconcile Microsoft Purview Communication Compliance policies
    against `data-plane/communication-compliance/policies.yaml`
    (desired state). Standing posture is read-only / drift-detection
    only per ADR 0019 (re-verified 2026-06-07); see
    docs/adr/0019-cc-graph-pivot.md.

.DESCRIPTION
    Wave 2e declarative reconciler for Communication Compliance
    (supervisory review) policies (issue #72). The YAML is the
    central source of truth: add / update / remove flows through
    this script, which converges the live tenant to match. Sibling
    of `scripts/Deploy-IRMPolicies.ps1` (Wave 2d) -- same auth path,
    same drift vocabulary.

    Status: scaffold + read-only enumeration + Phase 1 apply
    hardening (issue #271). All cmdlet parameter shapes used by the
    apply switch (`*-SupervisoryReviewPolicyV2` and the rule sibling
    cmdlets `New-/Set-/Get-SupervisoryReviewRule`) were verified
    against Microsoft Learn on 2026-05-16; URLs are cited inline at
    every call site. The desired state still ships empty
    (`policies: []`), so live tenant exercise of the Create / Update /
    Remove branches and the rule sub-reconciler is deferred to a
    Phase 2 follow-up that lands the first declarative policy.

    Important: there is no `Remove-SupervisoryReviewRule` cmdlet on
    the V2 surface. Verified two ways on 2026-05-16: Microsoft Learn
    returns 404 for that page, and `Get-Command
    Remove-SupervisoryReviewRule` against a live `Connect-IPPSSession`
    on `ExchangeOnlineManagement` 3.9.0 returned no result. The rule
    sub-reconciler therefore implements Create + Update only; orphan
    rules are reported but cannot be deleted in place. Removing a
    rule requires removing its parent policy.
    Full live cmdlet inventory, reproduction recipe, and removal
    workaround:
      docs/runbooks/communication-compliance-cmdlet-surface.md

    Drift contract (per
    `.github/instructions/powershell.instructions.md` "Drift report
    format"):

      1. GET every policy via `Get-SupervisoryReviewPolicyV2`.
      2. Match desired vs. tenant by `Name`.
      3. Diff each desired policy against the tenant copy.
      4. Emit a categorized report:
            Create   -- in YAML; not in tenant.
            Update   -- in both; tracked fields differ.
            NoChange -- in both; tracked fields identical.
            Orphan   -- in tenant; not in YAML. Written only with
                        -PruneMissing.
      5. Act only on categories the caller has authorized
         (-WhatIf / -PruneMissing).

    References (Microsoft Learn -- verified 2026-05-16):
      Communication Compliance overview:
        https://learn.microsoft.com/en-us/purview/communication-compliance
      Get-SupervisoryReviewPolicyV2:
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-supervisoryreviewpolicyv2
      New-SupervisoryReviewPolicyV2:
        https://learn.microsoft.com/en-us/powershell/module/exchange/new-supervisoryreviewpolicyv2
      Set-SupervisoryReviewPolicyV2:
        https://learn.microsoft.com/en-us/powershell/module/exchange/set-supervisoryreviewpolicyv2
      Remove-SupervisoryReviewPolicyV2:
        https://learn.microsoft.com/en-us/powershell/module/exchange/remove-supervisoryreviewpolicyv2
      Get-SupervisoryReviewRule:
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-supervisoryreviewrule
      New-SupervisoryReviewRule:
        https://learn.microsoft.com/en-us/powershell/module/exchange/new-supervisoryreviewrule
      Set-SupervisoryReviewRule:
        https://learn.microsoft.com/en-us/powershell/module/exchange/set-supervisoryreviewrule
      Remove-SupervisoryReviewRule: DOES NOT EXIST on the V2 surface
        (Learn returns 404 and live `Get-Command` on
        ExchangeOnlineManagement 3.9.0 returns no result, both
        verified 2026-05-16). Rules are removed only by deleting
        their parent policy. See:
          docs/runbooks/communication-compliance-cmdlet-surface.md
      Connect-IPPSSession (S&C PowerShell):
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
      Connect to S&C PowerShell:
        https://learn.microsoft.com/en-us/powershell/exchange/connect-to-scc-powershell
      App-only auth for EXO / S&C PowerShell:
        https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2
      Everything about ShouldProcess:
        https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
      ADR 0010 (automation identity subject model):
        docs/adr/0010-automation-identity-subject-model.md
      ADR 0011 Decision #3 supersession (Key Vault-signed JWT auth):
        docs/adr/0011-certificate-lifecycle.md
      ADR 0012 (-ParametersFile contract):
        docs/adr/0012-environment-parameters-file.md

.PARAMETER Path
    Path to the desired-state YAML. Defaults to the in-repo location
    `data-plane/communication-compliance/policies.yaml`.

.PARAMETER PruneMissing
    Allow removal of tenant policies that are not declared in the YAML.
    Default $false.

.PARAMETER AllowMajorityPrune
    Override for the issue #13 prune sanity-ratio guard. Without it, a
    `-PruneMissing` plan that would delete more than `-MaxPruneRatio` of
    the live Communication Compliance policies is refused before any
    tenant write. Supply it when a large prune is genuinely intended (a
    deliberate consolidation); the ratio is then reported as a warning and
    the run proceeds. Has no effect on the empty-desired-set guard, which
    cannot be overridden.

.PARAMETER MaxPruneRatio
    Largest share of the live Communication Compliance policies
    `-PruneMissing` may delete without `-AllowMajorityPrune`, as a fraction
    in (0, 1]. Default 0.5.
    Reference: scripts/modules/PruneGuard.psm1 (issue #13, guard 2).

.PARAMETER Force
    Suppress the safety guard on the operation you asked for (ADR 0052 section 6).
    Default: $false. Must be explicit per the drift-report contract.

    Here that guard is the ADR 0052 destructive-confirmation prompt in front
    of the `-PruneMissing` delete branch. `-Force` does NOT mean "overwrite
    policies whose author is not the current principal": the IPPS /
    Security & Compliance cmdlet surface returns no authorship field, so
    there is genuinely nothing to diff and this script emits no `Conflict`
    row. ADR 0053 gives the authorship override its own switch
    (`-OverwriteForeignAuthor`) and scopes it to the six Atlas / Data Map
    REST reconcilers that can actually diff an authorship field. This script
    is not one of them and does not get that switch.
    Reference: docs/adr/0053-overwrite-foreign-author-switch.md.

.PARAMETER ParametersFile
    Path to the environment parameters YAML (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved relative to the repo root.
    When the parameter is omitted, the PURVIEW_PARAMETERS_FILE environment
    variable (ADR 0057) takes precedence over the lab default.

.PARAMETER VaultName
    Key Vault that holds the automation certificate. When omitted,
    resolved from `resources.keyVault.name` in the parameters file.

.PARAMETER CertificateName
    Key Vault certificate (and key) object name. When omitted, resolved
    from `automation.apps.dataPlane.certificateName`.

.PARAMETER DataPlaneAppDisplayName
    Entra display name of the data-plane app (ADR 0010). When omitted,
    resolved from `automation.apps.dataPlane.displayName`.

.PARAMETER TenantDomain
    Tenant primary domain passed to `Connect-IPPSSession -Organization`.
    When omitted, resolved from `automation.tenantDomain`.

.PARAMETER SkipSchemaValidation
    Bypass schema validation of the desired-state YAML. Do not use in CI.

.EXAMPLE
    ./scripts/Deploy-CommunicationCompliance.ps1 -WhatIf

    Connect read-only and emit the plan table for what an apply would
    do; make no remote writes. With the scaffold's default
    `policies: []`, this lists every tenant policy as Orphan and
    exits.

.EXAMPLE
    ./scripts/Deploy-CommunicationCompliance.ps1

    Reconcile the tenant against the YAML. With `policies: []`, this
    is a no-op (no Create / Update / Remove rows produced unless
    `-PruneMissing` is specified).

.NOTES
    Caller role requirements (the local principal running this script):
      * Active `az login` session (CLI is the JWT signing transport).
      * `Key Vault Crypto User` on the target vault (keys/sign).
      * `Key Vault Certificate User` on the target vault (certs/get).

    Data-plane Entra app prerequisites (one-time per tenant):
      * App-role `Office 365 Exchange Online > Exchange.ManageAsApp`
        granted with admin consent.
      * Entra directory role `Compliance Administrator` (or higher)
        assigned at directoryScopeId='/'. Reference:
        https://learn.microsoft.com/en-us/purview/communication-compliance-configure

    Output: a list of PSCustomObjects with columns Category / Name /
    Reason. Suitable for capture to `$GITHUB_STEP_SUMMARY` or a file.
    No credential material is printed.

    Schema validation:
      * The desired-state YAML is validated against
        `data-plane/communication-compliance/policies.schema.json`
        (JSON Schema Draft-07) at script start.
        Reference:
        https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
#>
# ConfirmImpact = 'High' is load-bearing, not decorative. PowerShell only
# raises a ShouldProcess confirmation when ConfirmImpact >= $ConfirmPreference,
# and $ConfirmPreference defaults to 'High'. This script shipped 'Medium'
# until ADR 0052, so every $PSCmdlet.ShouldProcess(...) call below returned
# $true without ever prompting. Do not lower it back to 'Medium'.
# Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\communication-compliance\policies.yaml'),

    [switch]$PruneMissing,

    # Issue #13, guard 2: the prune sanity-ratio override and threshold.
    [switch]$AllowMajorityPrune,

    [ValidateRange(0.0000001, 1.0)]
    [double]$MaxPruneRatio = 0.5,

    # ADR 0052: -Force suppresses the destructive-confirmation prompt. This
    # script shipped without the switch, so the gate below had no operator
    # override at all until it was added here.
    [switch]$Force,

    [ValidateNotNullOrEmpty()]
    [string]$ParametersFile,

    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]$')]
    [string]$VaultName,

    [ValidatePattern('^[a-zA-Z0-9\-]{1,127}$')]
    [string]$CertificateName,

    [ValidatePattern('^[A-Za-z][A-Za-z0-9\-]{1,62}[A-Za-z0-9]$')]
    [string]$DataPlaneAppDisplayName,

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.\-]{0,253}[A-Za-z0-9]$')]
    [string]$TenantDomain,

    [switch]$SkipSchemaValidation
)

$ErrorActionPreference = 'Stop'

#region Helpers

function Expand-EnvPlaceholder {
    # Expand ${env:NAME} placeholders against the current process
    # environment. Used to keep tenant fingerprints (real UPNs, SMTP
    # addresses, object IDs) out of the committed YAML while still
    # letting the reconciler resolve them at runtime. Throws on
    # unresolved placeholders so missing CI secrets fail fast rather
    # than silently substituting empty strings.
    # Reference: https://learn.microsoft.com/en-us/dotnet/api/system.environment.getenvironmentvariable
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrEmpty($Value)) { return $Value }

    return [regex]::Replace($Value, '\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}', {
        param($match)
        $name = $match.Groups[1].Value
        $resolved = [Environment]::GetEnvironmentVariable($name)
        if ([string]::IsNullOrEmpty($resolved)) {
            throw ("Environment variable '{0}' is not set; cannot expand placeholder '`${{env:{0}}}`' in desired-state YAML." -f $name)
        }
        return $resolved
    })
}

function ConvertTo-DesiredCommunicationCompliancePolicyHash {
    # Normalize a desired-state YAML entry into a comparable hashtable.
    # String fields are passed through Expand-EnvPlaceholder so
    # ${env:NAME} tokens resolve before plan comparison.
    param([Parameter(Mandatory = $true)][hashtable]$Entry)

    $reviewers = @()
    if ($Entry.ContainsKey('reviewers') -and $Entry.reviewers) {
        $reviewers = @($Entry.reviewers | ForEach-Object { Expand-EnvPlaceholder ([string]$_) } | Sort-Object -Unique)
    }

    $rules = @()
    if ($Entry.ContainsKey('rules') -and $Entry.rules) {
        $rules = @($Entry.rules | ForEach-Object {
            ConvertTo-DesiredCommunicationComplianceRuleHash -Entry ([hashtable]$_)
        })
    }

    $description = $null
    if ($Entry.ContainsKey('description') -and $null -ne $Entry.description) {
        $description = Expand-EnvPlaceholder ([string]$Entry.description)
    }

    return @{
        name        = [string]$Entry.name
        description = $description
        reviewers   = $reviewers
        enabled     = if ($Entry.ContainsKey('enabled')) { [bool]$Entry.enabled } else { $null }
        rules       = $rules
    }
}

function ConvertTo-DesiredCommunicationComplianceRuleHash {
    # Normalize a desired-state rule entry into a comparable hashtable.
    # String fields are passed through Expand-EnvPlaceholder so
    # ${env:NAME} tokens resolve before plan comparison.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-supervisoryreviewrule
    param([Parameter(Mandatory = $true)][hashtable]$Entry)

    $sources = @()
    if ($Entry.ContainsKey('contentSources') -and $Entry.contentSources) {
        $sources = @($Entry.contentSources | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    }

    $condition = $null
    if ($Entry.ContainsKey('condition') -and $null -ne $Entry.condition) {
        $condition = Expand-EnvPlaceholder ([string]$Entry.condition)
    }

    return @{
        name           = [string]$Entry.name
        condition      = $condition
        samplingRate   = if ($Entry.ContainsKey('samplingRate')) { [int]$Entry.samplingRate }   else { $null }
        contentSources = $sources
        ocr            = if ($Entry.ContainsKey('ocr'))          { [bool]$Entry.ocr }            else { $null }
    }
}

function ConvertTo-TenantCommunicationComplianceRuleHash {
    # Normalize a Get-SupervisoryReviewRule result into the same
    # comparable shape as the desired-rule hash. Property names below
    # mirror the documented surface and will be tightened against the
    # live tenant in Phase 2 (apply exercise).
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-supervisoryreviewrule
    param([Parameter(Mandatory = $true)]$Rule)

    $sources = @()
    if ($Rule.PSObject.Properties.Match('ContentSources').Count -and $Rule.ContentSources) {
        $sources = @($Rule.ContentSources | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    }

    return @{
        name           = [string]$Rule.Name
        condition      = if ($Rule.PSObject.Properties.Match('Condition').Count -and $Rule.Condition) {
                              [string]$Rule.Condition
                          } else { $null }
        samplingRate   = if ($Rule.PSObject.Properties.Match('SamplingRate').Count -and $null -ne $Rule.SamplingRate) {
                              [int]$Rule.SamplingRate
                          } else { $null }
        contentSources = $sources
        ocr            = if ($Rule.PSObject.Properties.Match('Ocr').Count -and $null -ne $Rule.Ocr) {
                              [bool]$Rule.Ocr
                          } else { $null }
    }
}

function Compare-CommunicationComplianceRule {
    # Return field names that differ between a desired rule and the
    # tenant rule. Same "missing optional means don't manage" semantics
    # as Compare-CommunicationCompliancePolicy.
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][hashtable]$Tenant
    )

    $diffs = New-Object 'System.Collections.Generic.List[string]'

    if (-not [string]::IsNullOrEmpty($Desired.condition)) {
        if ([string]$Desired.condition -ne [string]$Tenant.condition) {
            $diffs.Add('condition') | Out-Null
        }
    }

    if ($null -ne $Desired.samplingRate) {
        if ([int]$Desired.samplingRate -ne [int]$Tenant.samplingRate) {
            $diffs.Add('samplingRate') | Out-Null
        }
    }

    if ($Desired.contentSources -and $Desired.contentSources.Count -gt 0) {
        $desiredJoined = ($Desired.contentSources | Sort-Object -Unique) -join '|'
        $tenantJoined  = ($Tenant.contentSources  | Sort-Object -Unique) -join '|'
        if ($desiredJoined -ne $tenantJoined) {
            $diffs.Add('contentSources') | Out-Null
        }
    }

    if ($null -ne $Desired.ocr) {
        if ([bool]$Desired.ocr -ne [bool]$Tenant.ocr) {
            $diffs.Add('ocr') | Out-Null
        }
    }

    return $diffs
}

function Invoke-CommunicationComplianceRuleReconcile {
    # Reconcile supervisory-review rules under a single parent policy.
    # Implements Create + Update branches only; there is no
    # Remove-SupervisoryReviewRule cmdlet on the V2 surface (verified
    # 2026-05-16 against Microsoft Learn and against a live IPPS
    # session on ExchangeOnlineManagement 3.9.0 -- see
    # docs/runbooks/communication-compliance-cmdlet-surface.md).
    # Orphan rules are reported but not deleted; pruning a rule
    # requires removing its parent policy.
    #
    # Inherits $WhatIfPreference / $ConfirmPreference from the calling
    # script via PowerShell preference inheritance, so $PSCmdlet.
    # ShouldProcess respects script-level -WhatIf / -Confirm.
    #
    # Reference: https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$PolicyName,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$DesiredRules,
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[object]]$Report,
        # ParentAction lets the caller signal that the parent policy is
        # being created in this same run. In -WhatIf mode the parent does
        # not yet exist, so calling Get-SupervisoryReviewRule -Policy <name>
        # throws "policy does not exist" and the rule loop has to skip the
        # enumeration and treat every desired rule as a fresh RuleCreate.
        # Allowed values mirror the parent plan categories that flow into
        # rule reconciliation.
        [Parameter(Mandatory = $false)]
        [ValidateSet('Create','Update','NoChange')]
        [string]$ParentAction = 'NoChange'
    )

    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-supervisoryreviewrule
    if ($ParentAction -eq 'Create' -and $WhatIfPreference) {
        # Parent policy will not exist in the tenant yet under -WhatIf;
        # don't probe Get-SupervisoryReviewRule. Every desired rule is
        # a fresh RuleCreate by construction.
        $tenantRules = @()
    } else {
        try {
            $tenantRules = @(Get-SupervisoryReviewRule -Policy $PolicyName -ErrorAction Stop)
        } catch {
            $Report.Add([pscustomobject]@{
                Category = 'RuleFailed'
                Name     = ('{0}/*' -f $PolicyName)
                Reason   = ('Get-SupervisoryReviewRule failed: {0}' -f $_.Exception.Message)
            })
            return
        }
    }

    $tenantByName = @{}
    foreach ($r in $tenantRules) {
        $tenantByName[[string]$r.Name] = ConvertTo-TenantCommunicationComplianceRuleHash -Rule $r
    }
    $desiredNames = @($DesiredRules | ForEach-Object { $_.name })

    foreach ($desired in $DesiredRules) {
        $ruleTarget = "Communication Compliance rule '{0}/{1}'" -f $PolicyName, $desired.name
        $fqName     = '{0}/{1}' -f $PolicyName, $desired.name

        if ($tenantByName.ContainsKey($desired.name)) {
            $diffs = Compare-CommunicationComplianceRule -Desired $desired -Tenant $tenantByName[$desired.name]
            if ($diffs.Count -eq 0) {
                $Report.Add([pscustomobject]@{ Category = 'RuleNoChange'; Name = $fqName; Reason = 'In sync with tenant.' })
                continue
            }
            if ($PSCmdlet.ShouldProcess($ruleTarget, 'Set-SupervisoryReviewRule')) {
                try {
                    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-supervisoryreviewrule
                    $splat = @{ Identity = $desired.name }
                    if (-not [string]::IsNullOrEmpty($desired.condition))                  { $splat.Condition      = $desired.condition }
                    if ($null -ne $desired.samplingRate)                                   { $splat.SamplingRate   = [int]$desired.samplingRate }
                    if ($desired.contentSources -and $desired.contentSources.Count -gt 0)  { $splat.ContentSources = $desired.contentSources }
                    if ($null -ne $desired.ocr)                                            { $splat.Ocr            = [bool]$desired.ocr }
                    Set-SupervisoryReviewRule @splat -ErrorAction Stop | Out-Null
                    $Report.Add([pscustomobject]@{ Category = 'RuleUpdated'; Name = $fqName; Reason = ('Drift in: {0}' -f ($diffs -join ', ')) })
                } catch {
                    $Report.Add([pscustomobject]@{ Category = 'RuleFailed'; Name = $fqName; Reason = ('Update failed: {0}' -f $_.Exception.Message) })
                }
            } else {
                $Report.Add([pscustomobject]@{ Category = 'RuleUpdate'; Name = $fqName; Reason = ('Would update. Drift in: {0}' -f ($diffs -join ', ')) })
            }
        } else {
            if ($PSCmdlet.ShouldProcess($ruleTarget, 'New-SupervisoryReviewRule')) {
                try {
                    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-supervisoryreviewrule
                    $splat = @{ Name = $desired.name; Policy = $PolicyName }
                    if (-not [string]::IsNullOrEmpty($desired.condition))                  { $splat.Condition      = $desired.condition }
                    if ($null -ne $desired.samplingRate)                                   { $splat.SamplingRate   = [int]$desired.samplingRate }
                    if ($desired.contentSources -and $desired.contentSources.Count -gt 0)  { $splat.ContentSources = $desired.contentSources }
                    if ($null -ne $desired.ocr)                                            { $splat.Ocr            = [bool]$desired.ocr }
                    New-SupervisoryReviewRule @splat -ErrorAction Stop | Out-Null
                    $Report.Add([pscustomobject]@{ Category = 'RuleCreated'; Name = $fqName; Reason = 'Declared in YAML; absent from tenant.' })
                } catch {
                    $Report.Add([pscustomobject]@{ Category = 'RuleFailed'; Name = $fqName; Reason = ('Create failed: {0}' -f $_.Exception.Message) })
                }
            } else {
                $Report.Add([pscustomobject]@{ Category = 'RuleCreate'; Name = $fqName; Reason = 'Declared in YAML; absent from tenant.' })
            }
        }
    }

    # Orphan rules (in tenant but not in YAML). No Remove cmdlet exists
    # on the V2 rule surface, so these are reported only.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-supervisoryreviewrule
    foreach ($t in $tenantRules) {
        $tn = [string]$t.Name
        if ($desiredNames -notcontains $tn) {
            $Report.Add([pscustomobject]@{
                Category = 'RuleOrphan'
                Name     = ('{0}/{1}' -f $PolicyName, $tn)
                Reason   = 'Tenant-only rule; skipped (no Remove-SupervisoryReviewRule cmdlet exists; remove parent policy to prune).'
            })
        }
    }
}

function ConvertTo-TenantCommunicationCompliancePolicyHash {
    # Normalize a Get-SupervisoryReviewPolicyV2 result into the same
    # comparable shape as
    # ConvertTo-DesiredCommunicationCompliancePolicyHash.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-supervisoryreviewpolicyv2
    param([Parameter(Mandatory = $true)]$Policy)

    # Property names below mirror the ones surfaced by
    # Get-SupervisoryReviewPolicyV2 on a current Security & Compliance
    # PowerShell session. The apply-hardening follow-up issue will
    # verify each property against the live tenant and tighten the
    # mapping as needed.
    $tenantReviewers = @()
    if ($Policy.PSObject.Properties.Match('Reviewers').Count -and $Policy.Reviewers) {
        $tenantReviewers = @($Policy.Reviewers | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    }

    return @{
        name        = [string]$Policy.Name
        description = if ($Policy.PSObject.Properties.Match('Comment').Count -and $Policy.Comment) {
                          [string]$Policy.Comment
                      } elseif ($Policy.PSObject.Properties.Match('Description').Count -and $Policy.Description) {
                          [string]$Policy.Description
                      } else { $null }
        reviewers   = $tenantReviewers
        enabled     = if ($Policy.PSObject.Properties.Match('Enabled').Count -and $null -ne $Policy.Enabled) {
                          [bool]$Policy.Enabled
                      } else { $null }
    }
}

function Compare-CommunicationCompliancePolicy {
    # Return a list of field names that differ between desired and
    # tenant. Compares only fields the YAML actually declares -- a
    # missing optional in YAML is treated as "don't manage", not a diff.
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][hashtable]$Tenant
    )

    $diffs = New-Object 'System.Collections.Generic.List[string]'

    if (-not [string]::IsNullOrEmpty($Desired.description)) {
        if ([string]$Desired.description -ne [string]$Tenant.description) {
            $diffs.Add('description') | Out-Null
        }
    }

    if ($Desired.reviewers -and $Desired.reviewers.Count -gt 0) {
        $desiredJoined = ($Desired.reviewers | Sort-Object -Unique) -join '|'
        $tenantJoined  = ($Tenant.reviewers  | Sort-Object -Unique) -join '|'
        if ($desiredJoined -ne $tenantJoined) {
            $diffs.Add('reviewers') | Out-Null
        }
    }

    if ($null -ne $Desired.enabled) {
        if ([bool]$Desired.enabled -ne [bool]$Tenant.enabled) {
            $diffs.Add('enabled') | Out-Null
        }
    }

    return $diffs
}

#endregion

#region Module dependencies

# Reference: https://www.powershellgallery.com/packages/powershell-yaml
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Information 'Installing powershell-yaml module to CurrentUser scope.' -InformationAction Continue
    Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
}
Import-Module 'powershell-yaml' -ErrorAction Stop

# Connect-IPPSSession -AccessToken requires ExchangeOnlineManagement
# v3.8.0-Preview1+ (install with -AllowPrerelease until GA).
# Reference: https://learn.microsoft.com/en-us/powershell/exchange/exchange-online-powershell-v2
$module = 'ExchangeOnlineManagement'
if (-not (Get-Module -ListAvailable -Name $module)) {
    Write-Information ("Installing {0} module to CurrentUser scope." -f $module) -InformationAction Continue
    Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -AllowPrerelease
}
Import-Module $module -ErrorAction Stop

# In-repo ADR 0052 destructive-operation confirmation gate. Wraps
# $PSCmdlet.ShouldContinue() -- which prompts unconditionally, independent
# of $ConfirmPreference -- so the -PruneMissing delete branch cannot be
# entered unattended from a local terminal.
# Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
Import-Module (Join-Path $PSScriptRoot 'modules/ConfirmGate.psm1') `
    -Force -Scope Local -ErrorAction Stop

# In-repo -PruneMissing safety guard (issue #13): the empty-desired-set
# refusal, which prevents a prune against a zero-entry desired state from
# classifying every live tenant object as an orphan. Shared with the other
# Deploy-*.ps1 reconcilers that implement -PruneMissing.
Import-Module (Join-Path $PSScriptRoot 'modules/PruneGuard.psm1') `
    -Force -Scope Local -ErrorAction Stop

#endregion

#region Parameters file resolution

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot   = Split-Path -Parent $scriptRoot

# When -ParametersFile is omitted, the PURVIEW_PARAMETERS_FILE environment
# variable (set per-environment by the CI workflows) selects the parameters
# file. See docs/adr/0057-multi-environment-and-branch-model.md.
if (-not $ParametersFile) {
    $ParametersFile = if ($env:PURVIEW_PARAMETERS_FILE) {
        $env:PURVIEW_PARAMETERS_FILE
    } else {
        Join-Path $repoRoot 'infra/parameters/lab.yaml'
    }
}
if (-not (Test-Path -LiteralPath $ParametersFile)) {
    Write-Error ("Parameters file not found: '{0}'. See docs/adr/0012-environment-parameters-file.md." -f $ParametersFile)
    return
}
$ParametersFile = (Resolve-Path -LiteralPath $ParametersFile).Path

$parameters = Get-Content -LiteralPath $ParametersFile -Raw | ConvertFrom-Yaml
if (-not $parameters) {
    Write-Error ("Parameters file '{0}' parsed as empty or null." -f $ParametersFile)
    return
}

foreach ($key in @('resources', 'automation')) {
    if (-not $parameters.ContainsKey($key)) {
        Write-Error ("Parameters file '{0}' is missing required top-level key '{1}'. Reference: docs/adr/0012-environment-parameters-file.md." -f $ParametersFile, $key)
        return
    }
}
if (-not $parameters.resources.ContainsKey('keyVault') -or
    -not $parameters.resources.keyVault.ContainsKey('name')) {
    Write-Error ("Parameters file '{0}' is missing required key 'resources.keyVault.name'." -f $ParametersFile)
    return
}
if (-not $parameters.automation.ContainsKey('tenantDomain')) {
    Write-Error ("Parameters file '{0}' is missing required key 'automation.tenantDomain'." -f $ParametersFile)
    return
}
if (-not $parameters.automation.ContainsKey('apps') -or
    -not $parameters.automation.apps.ContainsKey('dataPlane')) {
    Write-Error ("Parameters file '{0}' is missing required key 'automation.apps.dataPlane'. Reference: docs/adr/0010-automation-identity-subject-model.md." -f $ParametersFile)
    return
}
foreach ($key in @('displayName', 'certificateName')) {
    if (-not $parameters.automation.apps.dataPlane.ContainsKey($key)) {
        Write-Error ("Parameters file '{0}' is missing required key 'automation.apps.dataPlane.{1}'." -f $ParametersFile, $key)
        return
    }
}

if (-not $VaultName)               { $VaultName               = [string]$parameters.resources.keyVault.name }
if (-not $CertificateName)         { $CertificateName         = [string]$parameters.automation.apps.dataPlane.certificateName }
if (-not $DataPlaneAppDisplayName) { $DataPlaneAppDisplayName = [string]$parameters.automation.apps.dataPlane.displayName }
if (-not $TenantDomain)            { $TenantDomain            = [string]$parameters.automation.tenantDomain }

Write-Information ("Parameters file : {0}" -f $ParametersFile) -InformationAction Continue
Write-Information ("Environment     : {0}" -f $parameters.environment) -InformationAction Continue
Write-Information ("Vault           : {0}" -f $VaultName) -InformationAction Continue
Write-Information ("Certificate     : {0}" -f $CertificateName) -InformationAction Continue
Write-Information ("Data-plane app  : {0}" -f $DataPlaneAppDisplayName) -InformationAction Continue
Write-Information ("Tenant domain   : {0}" -f $TenantDomain) -InformationAction Continue
Write-Information ("YAML path       : {0}" -f $Path) -InformationAction Continue

#endregion

#region Desired-state load

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Error ("Desired-state YAML not found at '{0}'." -f $Path)
    return
}
$Path = (Resolve-Path -LiteralPath $Path).Path
$desiredRoot = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml

# Schema validation (JSON Schema Draft-07).
# Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
if (-not $SkipSchemaValidation.IsPresent) {
    $schemaPath = Join-Path $scriptRoot '..\data-plane\communication-compliance\policies.schema.json'
    if (-not (Test-Path -LiteralPath $schemaPath)) {
        Write-Error ("Schema file not found at '{0}'." -f $schemaPath)
        return
    }
    $schemaText = Get-Content -LiteralPath $schemaPath -Raw
    $docJson = $desiredRoot | ConvertTo-Json -Depth 10
    try {
        $null = $docJson | Test-Json -Schema $schemaText -ErrorAction Stop
    }
    catch {
        Write-Error ("Desired-state YAML failed schema validation: {0}" -f $_.Exception.Message)
        return
    }
    Write-Information ("Schema OK       : {0}" -f $schemaPath) -InformationAction Continue
}

$desiredEntries = @()
if ($desiredRoot -and $desiredRoot.ContainsKey('policies') -and $desiredRoot.policies) {
    $desiredEntries = @($desiredRoot.policies | ForEach-Object { ConvertTo-DesiredCommunicationCompliancePolicyHash -Entry ([hashtable]$_) })
}
Write-Information ("Desired policies: {0}" -f $desiredEntries.Count) -InformationAction Continue

# Issue #13, guard 1: empty-desired-set hard refusal for -PruneMissing.
#
# With zero desired entries every live tenant communication compliance policy
# falls out of the orphan match below, so the run would classify the entire set
# as orphans and delete it. The rationale, the likely causes, and the
# 2026-07-19 production hit are documented in scripts/modules/PruneGuard.psm1.
#
# This script has no Export mode, so the prune switch alone selects the
# destructive branch. Placed in the desired-state load region so it fires
# before the tenant is contacted at all -- before `az account show`, before
# Connect-IPPSSession, and before any write phase.
if ($PruneMissing.IsPresent) {
    Assert-PruneDesiredSetNotEmpty `
        -DesiredCount   $desiredEntries.Count `
        -ObjectTypeNoun 'communication compliance policy' `
        -SourcePath     $Path `
        -CollectionKey  'policies'
}

#endregion

#region Azure context (read-only preamble)

# Reference: https://learn.microsoft.com/en-us/cli/azure/account#az-account-show
$accountJson = az account show -o json --only-show-errors 2>$null
if (-not $accountJson) {
    Write-Error 'No active Azure CLI session. Run `az login` before invoking this script.'
    return
}
$account  = ($accountJson -join "`n") | ConvertFrom-Json
$tenantId = [string]$account.tenantId
if (-not $tenantId) {
    Write-Error 'az account show did not return a tenantId. Re-run `az login` and retry.'
    return
}
Write-Information ("Subscription    : {0}" -f $account.name) -InformationAction Continue

#endregion

#region Resolve data-plane app + acquire access token

# Reference: https://learn.microsoft.com/en-us/cli/azure/ad/app#az-ad-app-list
$appListJson = az ad app list --display-name $DataPlaneAppDisplayName -o json --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Error ("az ad app list failed with exit code {0}." -f $LASTEXITCODE)
    return
}
$appList = @()
if ($appListJson) {
    $appList = @(($appListJson -join "`n") | ConvertFrom-Json | Where-Object { $_.displayName -eq $DataPlaneAppDisplayName })
}
if ($appList.Count -eq 0) {
    Write-Error ("Entra application '{0}' not found." -f $DataPlaneAppDisplayName)
    return
}
if ($appList.Count -gt 1) {
    Write-Error ("Found {0} Entra applications with display name '{1}'. ADR 0010 mandates one app per display name." -f $appList.Count, $DataPlaneAppDisplayName)
    return
}
$appId = [string]$appList[0].appId
# NOTE: $appId deliberately not echoed at INFO -- real tenant identifier.

# Reference: docs/adr/0011-certificate-lifecycle.md (Decision #3 supersession)
$tokenScript = Join-Path $scriptRoot 'Get-PurviewIPPSAccessToken.ps1'
if (-not (Test-Path -LiteralPath $tokenScript)) {
    Write-Error ("Helper not found: '{0}'." -f $tokenScript)
    return
}
$tok = & $tokenScript `
    -VaultName       $VaultName `
    -CertificateName $CertificateName `
    -AppId           $appId `
    -TenantId        $tenantId
if (-not $tok -or -not $tok.AccessToken) {
    Write-Error 'Get-PurviewIPPSAccessToken.ps1 did not return an access token.'
    return
}
Write-Information ("Token acquired  : scope {0}, expires {1:yyyy-MM-ddTHH:mm:ssZ}" -f $tok.Scope, $tok.ExpiresOn) -InformationAction Continue

#endregion

#region Connect, enumerate, apply

$report = New-Object 'System.Collections.Generic.List[object]'

try {
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
    Connect-IPPSSession `
        -AccessToken  $tok.AccessToken `
        -Organization $TenantDomain `
        -ShowBanner:$false `
        -ErrorAction  Stop | Out-Null
    Write-Information ("Connected to Security & Compliance PowerShell as app '{0}'." -f $DataPlaneAppDisplayName) -InformationAction Continue

    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-supervisoryreviewpolicyv2
    $tenantPolicies = @(Get-SupervisoryReviewPolicyV2 -ErrorAction Stop)
    Write-Information ("Tenant policies : {0}" -f $tenantPolicies.Count) -InformationAction Continue

    # Index tenant policies by Name for O(1) lookup.
    $tenantByName = @{}
    foreach ($t in $tenantPolicies) {
        $tenantByName[[string]$t.Name] = ConvertTo-TenantCommunicationCompliancePolicyHash -Policy $t
    }
    $desiredNames = @($desiredEntries | ForEach-Object { $_.name })

    # Categorize: Create / Update / NoChange (desired-side) +
    # Orphan (tenant-only).
    $plan = New-Object 'System.Collections.Generic.List[object]'
    foreach ($d in $desiredEntries) {
        if ($tenantByName.ContainsKey($d.name)) {
            $diffs = Compare-CommunicationCompliancePolicy -Desired $d -Tenant $tenantByName[$d.name]
            if ($diffs.Count -eq 0) {
                $plan.Add([pscustomobject]@{ Action = 'NoChange'; Name = $d.name; Desired = $d; Reason = 'In sync with tenant.' })
            } else {
                $plan.Add([pscustomobject]@{ Action = 'Update'; Name = $d.name; Desired = $d; Reason = ('Drift in: {0}' -f ($diffs -join ', ')) })
            }
        } else {
            $plan.Add([pscustomobject]@{ Action = 'Create'; Name = $d.name; Desired = $d; Reason = 'Declared in YAML; absent from tenant.' })
        }
    }
    foreach ($t in $tenantPolicies) {
        $tn = [string]$t.Name
        if ($desiredNames -notcontains $tn) {
            $reason = if ($PruneMissing.IsPresent) { 'Tenant-only; will be removed (-PruneMissing).' } else { 'Tenant-only; skipped (no -PruneMissing).' }
            $plan.Add([pscustomobject]@{ Action = 'Orphan'; Name = $tn; Desired = $null; Reason = $reason })
        }
    }

    # ---- Issue #13, guard 2: prune sanity ratio ----
    # Guard 1 (desired-state load region) catches only the total wipe. This
    # catches the near-total one: a policies.yaml that lost most of its
    # entries to a bad merge, or a -Path pointing at a smaller environment's
    # file, both of which leave a non-zero desired count and so clear guard 1.
    #
    # Keyed on the Orphan set this run would delete against the live policy
    # count. This script is Class B (no -DirectionPolicy), so there is no
    # audit mode to gate against -- the guard is gated on -PruneMissing only.
    # It sits inside the enclosing try/finally and before the ADR 0052 gate,
    # so a refusal still runs the finally that disconnects the S&C session.
    # Reference: scripts/modules/PruneGuard.psm1
    if ($PruneMissing.IsPresent) {
        Assert-PruneRatioWithinThreshold `
            -PruneCount     @($plan | Where-Object { $_.Action -eq 'Orphan' }).Count `
            -LiveCount      @($tenantPolicies).Count `
            -ObjectTypeNoun 'communication compliance policy' `
            -MaxPruneRatio  $MaxPruneRatio `
            -Allow:$AllowMajorityPrune
    }

    # ---- ADR 0052: destructive-operation confirmation gate ----
    # The last point before the write loop at which nothing has been
    # written. This script is Class B: it declares no -DirectionPolicy, so
    # it has no repo-wins overwrite branch and exactly ONE destructive
    # branch -- the -PruneMissing delete. That branch is gated here, once
    # per run, via $PSCmdlet.ShouldContinue() -- NOT ShouldProcess().
    # ShouldContinue prompts unconditionally; ShouldProcess only prompts
    # when ConfirmImpact >= $ConfirmPreference, which is precisely the
    # comparison that silently defeated this gate before issue #85.
    #
    # The gate is keyed on the PLAN -- the Orphan rows the delete branch of
    # the write loop below actually iterates -- and never on a policy.
    # $orphans is derived from $plan here and read a few lines later, so it
    # cannot diverge from the deletes it speaks for.
    #
    # This `throw` sits inside the enclosing try/finally. There is no
    # `catch`, so a decline propagates out of the script (after the
    # `finally` disconnects the S&C session) rather than being swallowed
    # and falling through into the write loop.
    #
    # Deleting a Communication Compliance policy CASCADES to its rules:
    # there is no Remove-SupervisoryReviewRule cmdlet on the V2 surface, so
    # removing the parent policy is the only way a rule is ever destroyed.
    # The operator is told so.
    #
    # Suppressed by -Force, by an explicit -Confirm:$false (the CI path),
    # and skipped under -WhatIf so a dry run still previews the deletes
    # without blocking on input.
    # Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
    $yesToAll = $false
    $noToAll = $false
    $confirmBound = $PSCmdlet.MyInvocation.BoundParameters.ContainsKey('Confirm')
    $confirmValue = if ($confirmBound) { [bool]$PSCmdlet.MyInvocation.BoundParameters['Confirm'] } else { $false }
    $gateArgs = @{
        Cmdlet       = $PSCmdlet
        Caption      = 'Destructive operation (ADR 0052)'
        YesToAll     = ([ref]$yesToAll)
        NoToAll      = ([ref]$noToAll)
        Force        = $Force.IsPresent
        IsWhatIf     = [bool]$WhatIfPreference
        ConfirmBound = $confirmBound
        ConfirmValue = $confirmValue
    }

    $orphans = @($plan | Where-Object { $_.Action -eq 'Orphan' })
    if ($PruneMissing.IsPresent -and $orphans.Count -gt 0) {
        $orphanNames = @($orphans | ForEach-Object { [string]$_.Name })
        $pruneQuery = "-PruneMissing will DELETE {0} orphan Communication Compliance policy/policies from the tenant: {1}. Their rules are deleted with them (the V2 surface has no Remove-SupervisoryReviewRule cmdlet). This cannot be undone. Continue?" -f `
            $orphanNames.Count, (($orphanNames | Sort-Object) -join ', ')
        if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $pruneQuery)) {
            throw 'Aborted by operator at the -PruneMissing delete confirmation gate (ADR 0052). No tenant writes were made.'
        }
    }

    # Execute each plan row under ShouldProcess. -WhatIf / -Confirm
    # flow naturally via $PSCmdlet.ShouldProcess.
    # Reference: https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
    #
    # Parameter surface for the four `*-SupervisoryReviewPolicyV2`
    # cmdlets and the three documented `*-SupervisoryReviewRule`
    # cmdlets was verified against Microsoft Learn on 2026-05-16 (see
    # the References block in the script header). With the default
    # `policies: []` desired state, only the Orphan branch produces
    # rows; the Create / Update / Remove branches and the rule
    # sub-reconciler are exercised in Phase 2 once the first
    # declarative policy lands. Tracked by issue #271.
    # Issue #13: orphan prune failures are reported via Write-PruneFailure
    # (Write-Warning plus an '::error::' annotation, not Write-Error, which
    # shell: pwsh's $ErrorActionPreference='stop' would promote to terminating
    # and abandon the remaining orphans) and collected here; a single aggregate
    # throw after the loop names every failure so a failed prune exits non-zero.
    $pruneFailures = New-Object 'System.Collections.Generic.List[string]'

    foreach ($row in $plan) {
        $target = "Communication Compliance policy '{0}'" -f $row.Name
        switch ($row.Action) {
            'Create' {
                $opDesc = 'New-SupervisoryReviewPolicyV2'
                if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                    try {
                        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-supervisoryreviewpolicyv2
                        $splat = @{ Name = $row.Desired.name; Reviewers = $row.Desired.reviewers }
                        if (-not [string]::IsNullOrEmpty($row.Desired.description)) { $splat.Comment = $row.Desired.description }
                        if ($null -ne $row.Desired.enabled) { $splat.Enabled = [bool]$row.Desired.enabled }
                        New-SupervisoryReviewPolicyV2 @splat -ErrorAction Stop | Out-Null
                        $report.Add([pscustomobject]@{ Category = 'Created'; Name = $row.Name; Reason = $row.Reason })
                    } catch {
                        $report.Add([pscustomobject]@{ Category = 'Failed'; Name = $row.Name; Reason = ('Create failed: {0}' -f $_.Exception.Message) })
                    }
                } else {
                    $report.Add([pscustomobject]@{ Category = 'Create'; Name = $row.Name; Reason = ('Would create. {0}' -f $row.Reason) })
                }
            }
            'Update' {
                $opDesc = 'Set-SupervisoryReviewPolicyV2'
                if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                    try {
                        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-supervisoryreviewpolicyv2
                        $splat = @{ Identity = $row.Desired.name }
                        if (-not [string]::IsNullOrEmpty($row.Desired.description)) { $splat.Comment = $row.Desired.description }
                        if ($row.Desired.reviewers -and $row.Desired.reviewers.Count -gt 0) { $splat.Reviewers = $row.Desired.reviewers }
                        if ($null -ne $row.Desired.enabled) { $splat.Enabled = [bool]$row.Desired.enabled }
                        Set-SupervisoryReviewPolicyV2 @splat -ErrorAction Stop | Out-Null
                        $report.Add([pscustomobject]@{ Category = 'Updated'; Name = $row.Name; Reason = $row.Reason })
                    } catch {
                        $report.Add([pscustomobject]@{ Category = 'Failed'; Name = $row.Name; Reason = ('Update failed: {0}' -f $_.Exception.Message) })
                    }
                } else {
                    $report.Add([pscustomobject]@{ Category = 'Update'; Name = $row.Name; Reason = ('Would update. {0}' -f $row.Reason) })
                }
            }
            'NoChange' {
                $report.Add([pscustomobject]@{ Category = 'NoChange'; Name = $row.Name; Reason = $row.Reason })
            }
            'Orphan' {
                if ($PruneMissing.IsPresent) {
                    if ($PSCmdlet.ShouldProcess($target, 'Remove-SupervisoryReviewPolicyV2')) {
                        try {
                            # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/remove-supervisoryreviewpolicyv2
                            Remove-SupervisoryReviewPolicyV2 -Identity $row.Name -Confirm:$false -ErrorAction Stop | Out-Null
                            $report.Add([pscustomobject]@{ Category = 'Removed'; Name = $row.Name; Reason = $row.Reason })
                        } catch {
                            $report.Add([pscustomobject]@{ Category = 'Failed'; Name = $row.Name; Reason = ('Remove failed: {0}' -f $_.Exception.Message) })
                            Write-PruneFailure ("Remove Communication Compliance policy '{0}' failed: {1}" -f $row.Name, $_.Exception.Message)
                            $pruneFailures.Add([string]$row.Name)
                        }
                    } else {
                        $report.Add([pscustomobject]@{ Category = 'Orphan'; Name = $row.Name; Reason = ('Would remove. {0}' -f $row.Reason) })
                    }
                } else {
                    $report.Add([pscustomobject]@{ Category = 'Orphan'; Name = $row.Name; Reason = $row.Reason })
                }
            }
        }

        # Rule sub-reconciliation. Only meaningful for Create / Update /
        # NoChange rows on policies the script can address by name --
        # Orphan rows would be deleting the parent policy (rules cascade)
        # or skipping (no -PruneMissing), so neither needs rule work.
        if ($row.Action -in @('Create','Update','NoChange') -and
            $row.Desired -and
            $row.Desired.rules -and
            $row.Desired.rules.Count -gt 0) {
            Invoke-CommunicationComplianceRuleReconcile `
                -PolicyName    $row.Name `
                -DesiredRules  @($row.Desired.rules) `
                -Report        $report `
                -ParentAction  $row.Action
        }
    }

    # Issue #13: a failed prune now exits non-zero (behaviour change). The
    # throw sits inside the try so the finally still disconnects the S&C
    # session; it fires after every orphan has been attempted, naming them all.
    if ($pruneFailures.Count -gt 0) {
        throw ("Reconciliation aborted: {0} orphan Communication Compliance policy/policies could not be removed: {1}. See errors above." -f $pruneFailures.Count, ($pruneFailures -join ', '))
    }
}
finally {
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/disconnect-exchangeonline
    try {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    } catch {
        Write-Verbose ('Disconnect-ExchangeOnline failed (non-fatal): {0}' -f $_.Exception.Message)
    }
}

#endregion

# Emit the categorized plan. Suitable for | Format-Table or capture to
# $GITHUB_STEP_SUMMARY. Categories: Created / Updated / Removed for
# completed writes; Create / Update / Orphan for -WhatIf rows; NoChange
# for in-sync; Failed for caught exceptions.
$report
