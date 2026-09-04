#Requires -Version 7.4
<#
.SYNOPSIS
    Reconcile the Microsoft Purview collection hierarchy against
    `data-plane/collections/collections.yaml` (desired state).

.DESCRIPTION
    Wave 4a-i-a full-circle reconciler for Purview collections
    (issue #73). The YAML is the central source of truth: add /
    update / remove flows through this script, which converges the
    live Purview account to match.

    Sibling of `scripts/Deploy-Labels.ps1` and
    `scripts/Deploy-IRMPolicies.ps1` -- same drift vocabulary
    (Create / Update / NoChange / Orphan / Removed), same
    `[CmdletBinding(SupportsShouldProcess)]` contract, same
    `-ParametersFile` source-of-truth (ADR 0012). Unlike the
    Security & Compliance reconcilers, collections is a pure
    Purview *data-plane REST* surface, so auth flows through
    `scripts/Connect-Purview.ps1` (Azure CLI token cache) instead
    of an IPPS session.

    Drift contract (per
    `.github/instructions/powershell.instructions.md` "Drift report
    format"):

      1. GET every collection via the account data-plane list endpoint.
      2. Match desired vs. tenant case-insensitively by `name`.
      3. Diff each desired collection against the tenant copy on the
         tracked fields (`friendlyName`, `description`, `parent`).
      4. Emit a categorized report:
            Create   -- in YAML; not in tenant.
            Update   -- in both; tracked fields differ.
            NoChange -- in both; tracked fields identical.
            Orphan   -- in tenant; not in YAML. Written only with
                        `-PruneMissing` (then promoted to Removed).
            Protected-- in tenant; not in YAML; name matched the
                        optional top-level `protected:` allow-list
                        (issue #312). Reported but never deleted,
                        even with `-PruneMissing`. Used for system-
                        managed collections that return HTTP 400 /
                        Purview `code 1006`.
            Removed  -- a prior Orphan that was just deleted.
      5. Act only on categories the caller has authorized
         (`-WhatIf` / `-PruneMissing`).

    Tree-aware ordering:
      * Creates traverse parents-before-children (top-down).
      * Removes traverse children-before-parents (bottom-up). The
        Purview REST surface refuses to delete a parent that still
        owns children, same shape as Microsoft Information Protection
        retention labels.

    Rename semantics:
      * The collection `name` field is the URL segment and is
        immutable on the REST surface (only a getter on the resource
        definition). Changing `name` in YAML produces a Create row
        for the new name plus an Orphan row for the old name; an
        in-place rename is not supported. `friendlyName` and
        `description` ARE mutable via PUT.

    Root-collection guard:
      * The root collection shares the Purview account name and is
        managed by Azure. The script never PUTs or DELETEs the root
        and silently filters it out of the orphan/prune set.

    References (Microsoft Learn):
      Collections - List Collections:
        https://learn.microsoft.com/en-us/rest/api/purview/accountdataplane/collections/list-collections
      Collections - Create Or Update Collection:
        https://learn.microsoft.com/en-us/rest/api/purview/accountdataplane/collections/create-or-update-collection
      Collections - Delete Collection:
        https://learn.microsoft.com/en-us/rest/api/purview/accountdataplane/collections/delete-collection
      Manage collections in Microsoft Purview:
        https://learn.microsoft.com/en-us/purview/how-to-create-and-manage-collections
      Quickstart: create a collection (collection-name rule, issue #310):
        https://learn.microsoft.com/en-us/purview/quickstart-create-collection
      Everything about ShouldProcess:
        https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
      ADR 0010 (automation identity subject model):
        docs/adr/0010-automation-identity-subject-model.md
      ADR 0012 (-ParametersFile contract):
        docs/adr/0012-environment-parameters-file.md

.PARAMETER Path
    Path to the desired-state YAML. Defaults to the in-repo location
    `data-plane/collections/collections.yaml`.

.PARAMETER PruneMissing
    Allow removal of tenant collections that are not declared in the
    YAML. Default $false. Removes traverse bottom-up so child
    collections are deleted before their parents. NEVER passes a name
    listed in `-SkipNames`.

    Guard 1 (`Assert-PruneDesiredSetNotEmpty`, `scripts/modules/PruneGuard.psm1`)
    stands in front of this switch: a prune against an empty
    `collections:` set would classify every live child collection as an
    orphan, so it is refused before the tenant is contacted. The issue #13
    sanity-ratio guard (guard 2) is deliberately NOT wired for collections:
    a subtree teardown legitimately removes a majority of the live
    collections, so the ratio guard does not fit (owner decision). A
    `-PruneMissing` run that hits delete failures now reports every one and
    fails the run non-zero via an aggregate error, rather than exiting 0.

.PARAMETER DirectionPolicy
    Source-of-truth direction for shared-property drift between the
    desired YAML and the live tenant. One of:
      * `audit`       -- read-only verification. Build the plan,
                         emit the categorized report, and exit. No
                         PUT / DELETE writes against the REST surface
                         fire under any circumstance. Equivalent to a
                         forced -WhatIf at the script boundary.
      * `portal-wins` -- (default) skip any collection whose tracked
                         fields differ; emit a Skip plan row per
                         skipped collection and a `[ADR0029-SKIP] <name>`
                         line per skip so an upstream workflow can
                         capture the list for an auto-PR. Create /
                         NoChange / Orphan handling are unchanged.
      * `repo-wins`   -- apply the full plan including shared-property
                         drift. Emit one Write-Warning per overwritten
                         collection naming the drifted field(s). The
                         overwrite is gated at the SCRIPT layer by the
                         ADR 0052 typed-confirmation prompt: it names
                         the collections it is about to overwrite,
                         asks EVERY caller -- local operators included
                         -- and aborts with no tenant writes if
                         declined. Suppress with -Force, or
                         -Confirm:$false as CI does. The workflow's
                         'overwrite portal' input is an ADDITIONAL
                         gate per ADR 0029, not the only one: a clone
                         of this template that has not run kickoff has
                         no CI at all, so the script-layer gate is its
                         only defence.
    Default `portal-wins`. Reference:
    `docs/adr/0029-source-of-truth-direction-policy.md`.

.PARAMETER SkipNames
    Internal contract used by the workflow's `portal-wins` skip-drift
    logic to pass a pre-computed skip list to the script. A name
    matched here is treated as a Skip plan row instead of an Update /
    Orphan row (reason: "explicitly skipped by caller"). NoChange and
    Create rows are unaffected. `-PruneMissing` still respects
    `-SkipNames` -- a skipped name is never deleted. Names not present
    in the YAML or the tenant are silently ignored (defends against a
    stale skip list from the workflow). The match is case-insensitive
    against the bare `name`. Ignored in `-DirectionPolicy audit` mode.
    Default `@()`. Reference:
    `docs/adr/0029-source-of-truth-direction-policy.md`.

.PARAMETER Force
    With `-ExportCurrentState`: allow overwriting a YAML target file
    that already contains a non-trivial `collections:` block. Has no
    effect on the Apply path.

.PARAMETER ExportCurrentState
    Read every collection from the live Purview account and serialize
    it back to `-Path`. Used to refresh the in-repo YAML after
    out-of-band tenant changes. Mutually exclusive with
    `-PruneMissing`.

.PARAMETER ParametersFile
    Path to the environment parameters YAML (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved relative to the repo root.
    When the parameter is omitted, the PURVIEW_PARAMETERS_FILE environment
    variable (ADR 0057) takes precedence over the lab default.

.PARAMETER PurviewAccountName
    Purview account to target. When omitted, resolved from
    `purviewAccountName` in the parameters file.

.EXAMPLE
    ./scripts/Deploy-Collections.ps1 -WhatIf

    Connect read-only and emit the plan table for what an apply
    would do; make no remote writes.

.EXAMPLE
    ./scripts/Deploy-Collections.ps1

    Reconcile the Purview account against the YAML. Without
    `-PruneMissing`, Orphan rows are reported but not removed.

.EXAMPLE
    ./scripts/Deploy-Collections.ps1 -PruneMissing

    Same as the bare apply, plus deletion of any tenant collection
    that is not declared in the YAML (root collection is exempt).

.EXAMPLE
    ./scripts/Deploy-Collections.ps1 -ExportCurrentState

    Round-trip the live tenant state back into the YAML. Re-running
    `-WhatIf` against the exported YAML must produce only `NoChange`
    rows (round-trip idempotency contract).

.NOTES
    Caller role requirements (the local principal running this
    script):
      * Active `az login` session against the lab tenant.
      * Microsoft Purview role `Collection Admin` at the root
        collection of the target account (required to PUT or DELETE
        any descendant collection).

    Output: a stream of `[pscustomobject]` records with the fields
    `Category`, `Kind`, `Name`, `Reason`. Suitable for capture to
    `$GITHUB_STEP_SUMMARY` or a file. No access tokens, request
    bodies, or response headers are emitted.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\collections\collections.yaml'),

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$PruneMissing,

    [Parameter(ParameterSetName = 'Apply')]
    [ValidateSet('audit', 'portal-wins', 'repo-wins')]
    [string]$DirectionPolicy = 'portal-wins',

    [Parameter(ParameterSetName = 'Apply')]
    [string[]]$SkipNames = @(),

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [switch]$Force,

    [Parameter(ParameterSetName = 'Export', Mandatory = $true)]
    [switch]$ExportCurrentState,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateNotNullOrEmpty()]
    [string]$ParametersFile,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [Alias('AccountName')]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{1,62}[A-Za-z0-9]$')]
    [string]$PurviewAccountName
)

$ErrorActionPreference = 'Stop'

# Purview Account Data Plane API version. Only published version on
# Microsoft Learn as of 2026-05. Pinned per the repo's API-version
# discipline (see .github/instructions/powershell.instructions.md).
$script:CollectionsApiVersion = '2019-11-01-preview'

#region Helpers

function ConvertTo-DesiredCollectionList {
    <#
        Flatten the YAML collection tree to a list of comparable
        hashtables. Each entry carries { name; friendlyName;
        description; parent }. The YAML supports two parent shapes:

          1. Top-level entries with an explicit `parent:` field.
          2. Children nested under a parent's `children:` array; the
             containing entry's `name` becomes their parent.

        The root collection itself is NOT emitted -- the script
        never reconciles it (managed by Azure).
    #>
    param(
        [Parameter(Mandatory = $true)]$Tree,
        [Parameter(Mandatory = $true)][string]$RootName
    )

    $result = New-Object 'System.Collections.Generic.List[hashtable]'

    function Add-Entry {
        param($Node, [string]$Parent)
        if (-not $Node.ContainsKey('name')) {
            throw "Collection entry under parent '$Parent' is missing the required 'name' field."
        }
        $entry = @{
            name         = [string]$Node.name
            friendlyName = if ($Node.ContainsKey('friendlyName')) { [string]$Node.friendlyName } else { $null }
            description  = if ($Node.ContainsKey('description'))  { [string]$Node.description  } else { $null }
            parent       = $Parent
        }
        $result.Add($entry) | Out-Null
        if ($Node.ContainsKey('children') -and $Node.children) {
            foreach ($child in $Node.children) {
                Add-Entry -Node ([hashtable]$child) -Parent $entry.name
            }
        }
    }

    if (-not $Tree) { return @() }
    if (-not $Tree.ContainsKey('collections') -or -not $Tree.collections) { return @() }
    foreach ($top in $Tree.collections) {
        $node = [hashtable]$top
        $parent = if ($node.ContainsKey('parent') -and $node.parent) { [string]$node.parent } else { $RootName }
        Add-Entry -Node $node -Parent $parent
    }
    return $result.ToArray()
}

function Test-CollectionNameRule {
    <#
        Validate a single collection name against the Microsoft
        Purview rule documented in the Quickstart (issue #310):

          ^[a-z][a-z0-9-]{2,35}$

        That is: 3-36 characters, must start with a lowercase
        letter, and may contain only lowercase letters, digits,
        and hyphens. Names that violate the rule produce a
        Purview REST 400 at Create time -- catching them in a
        pre-flight pass turns a silent failed-row into an
        actionable per-row reason before any write hits the wire.

        Returns [pscustomobject]@{ Valid; Reason } where Reason is
        one of: OK, TooShort, TooLong, LeadingNonLetter, Uppercase,
        IllegalChar. The order of checks is deterministic so the
        Pester per-failure-mode cases (issue #310) lock in exactly
        one reason per input.

        Reference: https://learn.microsoft.com/en-us/purview/quickstart-create-collection
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name
    )

    if ($Name.Length -lt 3) {
        return [pscustomobject]@{ Valid = $false; Reason = 'TooShort' }
    }
    if ($Name.Length -gt 36) {
        return [pscustomobject]@{ Valid = $false; Reason = 'TooLong' }
    }
    if ($Name[0] -notmatch '[a-z]') {
        return [pscustomobject]@{ Valid = $false; Reason = 'LeadingNonLetter' }
    }
    if ($Name -cmatch '[A-Z]') {
        return [pscustomobject]@{ Valid = $false; Reason = 'Uppercase' }
    }
    if ($Name -notmatch '^[a-z0-9-]+$') {
        return [pscustomobject]@{ Valid = $false; Reason = 'IllegalChar' }
    }
    return [pscustomobject]@{ Valid = $true; Reason = 'OK' }
}

function Get-CollectionNameViolation {
    <#
        Run Test-CollectionNameRule across every desired entry and
        return only the failures as [pscustomobject]@{ Name; Reason }
        rows. A clean YAML returns @(). Caller is expected to
        Write-Error with the rows and abort before any REST write.

        Names supplied via -KnownNames are skipped entirely. These
        are the case-insensitive set of collection names that
        already exist in the tenant -- by definition the REST
        surface accepts them (the portal's collection-create flow
        auto-generates short URL segments like '85cv3o' that fail
        the human-input rule documented in the Quickstart, yet are
        valid identifiers on the wire). Pre-flighting an existing
        name adds zero safety and blocks the round-trip contract
        for Export -> Apply. The rule still guards every newly
        authored YAML entry.

        Reference: https://learn.microsoft.com/en-us/purview/quickstart-create-collection
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable[]]$Entries,
        [Parameter()][AllowEmptyCollection()][string[]]$KnownNames = @()
    )

    $known = @{}
    foreach ($k in $KnownNames) {
        if ($k) { $known[([string]$k).ToLowerInvariant()] = $true }
    }

    $violations = New-Object 'System.Collections.Generic.List[pscustomobject]'
    foreach ($entry in $Entries) {
        $name = [string]$entry.name
        if ($known.ContainsKey($name.ToLowerInvariant())) { continue }
        $result = Test-CollectionNameRule -Name $name
        if (-not $result.Valid) {
            $violations.Add([pscustomobject]@{ Name = $name; Reason = $result.Reason }) | Out-Null
        }
    }
    return $violations.ToArray()
}

function ConvertTo-TenantCollectionHash {
    <#
        Normalize a List Collections response item into the same
        comparable shape as ConvertTo-DesiredCollectionList. The
        Purview REST surface returns `parentCollection.referenceName`;
        a missing `parentCollection` (or one whose name equals the
        account name) identifies the root. When -RootName is
        supplied, both cases are normalized to that value so the
        tenant side matches the desired YAML convention of
        `parent: <account>` for top-level collections.
    #>
    param(
        [Parameter(Mandatory = $true)]$Collection,
        [Parameter()][string]$RootName
    )

    $parent = $null
    if ($Collection.PSObject.Properties.Name -contains 'parentCollection' -and $Collection.parentCollection) {
        if ($Collection.parentCollection.PSObject.Properties.Name -contains 'referenceName') {
            $parent = [string]$Collection.parentCollection.referenceName
        }
    }
    if ($RootName) {
        if ([string]::IsNullOrEmpty($parent) -or $parent -ieq $RootName) {
            $parent = $RootName
        }
    }
    return @{
        name         = [string]$Collection.name
        friendlyName = if ($Collection.PSObject.Properties.Name -contains 'friendlyName') { [string]$Collection.friendlyName } else { $null }
        description  = if ($Collection.PSObject.Properties.Name -contains 'description')  { [string]$Collection.description  } else { $null }
        parent       = $parent
    }
}

function Compare-CollectionHash {
    <#
        Return a list of tracked fields that differ between desired
        and tenant. Tracked fields: friendlyName, description, parent.
        A null/empty desired value is treated as "don't manage" --
        matches the per-domain pattern in Compare-IRMPolicy.
        `name` is intentionally NOT compared because the REST
        surface treats it as immutable; renames flow through the
        Orphan/Create plan instead.
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][hashtable]$Tenant
    )

    $diffs = New-Object 'System.Collections.Generic.List[string]'

    if (-not [string]::IsNullOrEmpty($Desired.friendlyName)) {
        if ([string]$Desired.friendlyName -ne [string]$Tenant.friendlyName) {
            $diffs.Add('friendlyName') | Out-Null
        }
    }
    if (-not [string]::IsNullOrEmpty($Desired.description)) {
        if ([string]$Desired.description -ne [string]$Tenant.description) {
            $diffs.Add('description') | Out-Null
        }
    }
    if (-not [string]::IsNullOrEmpty($Desired.parent)) {
        # Case-insensitive: Purview normalizes the root reference name
        # to the account-name casing, which may differ from the YAML.
        if ([string]$Desired.parent -ine [string]$Tenant.parent) {
            $diffs.Add('parent') | Out-Null
        }
    }

    return $diffs
}

function Format-PurviewRestError {
    <#
        Convert a REST ErrorRecord from Invoke-RestMethod into a
        concise, human-readable Failed-row reason that exposes the
        HTTP status code, the Purview service error code, and the
        first ~120 chars of the service error message.

        Pre-#308 Failed rows showed `$_.Exception.Message`, which on
        PowerShell 7 is the generic "Response status code does not
        indicate success: ..." string and discards the response body.
        The real diagnostic value -- HTTP status and the Purview
        `error.code` (e.g. 12005 = referenced, 1006 = system-managed)
        -- sits on `$ErrorRecord.ErrorDetails.Message` (PS7) or on
        the Response stream (PS5.1).

        Reference (PowerShell 7 surface):
          https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/invoke-restmethod
        Reference (Purview REST error shape):
          https://learn.microsoft.com/en-us/rest/api/purview/accountdataplane/collections/create-or-update-collection#errorresponsemodel
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [int]$MaxMessageLength = 120
    )

    # HTTP status -- best-effort. PS7 surfaces an HttpResponseException
    # with a HttpResponseMessage on .Response; PS5.1 surfaces a
    # WebException with an HttpWebResponse on .Response. Both expose
    # a StatusCode property castable to int.
    $status = $null
    if ($ErrorRecord.Exception -and $ErrorRecord.Exception.PSObject.Properties['Response'] -and $ErrorRecord.Exception.Response) {
        try { $status = [int]$ErrorRecord.Exception.Response.StatusCode } catch { $status = $null }
    }

    # Response body. PS7: $ErrorRecord.ErrorDetails.Message.
    # PS5.1 fallback: read the response stream directly.
    $body = $null
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $body = $ErrorRecord.ErrorDetails.Message
    } elseif ($ErrorRecord.Exception -and $ErrorRecord.Exception.PSObject.Properties['Response'] -and $ErrorRecord.Exception.Response) {
        try {
            $stream = $ErrorRecord.Exception.Response.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $body = $reader.ReadToEnd()
                $reader.Dispose()
            }
        } catch {
            $body = $null
        }
    }

    $code = $null
    $message = $null
    if ($body) {
        try {
            $parsed = $body | ConvertFrom-Json -ErrorAction Stop
            if ($parsed.PSObject.Properties['error'] -and $parsed.error) {
                if ($parsed.error.PSObject.Properties['code'])    { $code    = [string]$parsed.error.code }
                if ($parsed.error.PSObject.Properties['message']) { $message = [string]$parsed.error.message }
            } elseif ($parsed.PSObject.Properties['code'] -or $parsed.PSObject.Properties['message']) {
                if ($parsed.PSObject.Properties['code'])    { $code    = [string]$parsed.code }
                if ($parsed.PSObject.Properties['message']) { $message = [string]$parsed.message }
            }
        } catch {
            Write-Verbose ("Format-PurviewRestError: response body was not JSON ({0}); falling back to exception message." -f $_.Exception.Message)
        }
    }

    if ($message -and $message.Length -gt $MaxMessageLength) {
        $message = $message.Substring(0, $MaxMessageLength) + '...'
    }

    $segments = New-Object 'System.Collections.Generic.List[string]'
    if ($status) { $segments.Add("HTTP $status") | Out-Null }
    if ($code)   { $segments.Add("code $code")   | Out-Null }
    $prefix = if ($segments.Count -gt 0) { $segments -join ' ' } else { $null }

    if ($prefix -and $message) { return "${prefix}: $message" }
    if ($prefix)               { return $prefix }
    if ($message)              { return $message }

    # Last resort -- preserve the raw exception text so callers never
    # lose context (mirrors the pre-#308 Failed-row contents).
    return $ErrorRecord.Exception.Message
}

function Get-OrphanAction {
    <#
        Decide whether a tenant-only collection (one absent from the
        desired-state YAML) should be planned as an `Orphan` (eligible
        for `-PruneMissing` deletion) or as `Protected` (system-managed
        / undeletable; never sent to DELETE).

        Issue #312 surfaced the operational pain: collections that
        return HTTP 400 / Purview error `code 1006`
        ("<friendly> can't be deleted with this API.") got planned as
        Orphan, attempted on every `-PruneMissing` run, and reliably
        produced a `Failed` row -- noise that masks real drift. The
        protected allow-list (top-level `protected:` key in
        collections.yaml) lets the owner declare those names once and
        have the script skip the DELETE call entirely.

        Matching is case-insensitive against the `name` (URL segment)
        field, since that is the identifier the REST surface uses.

        Reference: https://learn.microsoft.com/en-us/rest/api/purview/accountdataplane/collections/delete-collection
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter()][AllowNull()][AllowEmptyCollection()][string[]]$ProtectedNames
    )

    if ($ProtectedNames -and $ProtectedNames.Count -gt 0) {
        $needle = $Name.ToLowerInvariant()
        foreach ($p in $ProtectedNames) {
            if ($null -ne $p -and $p.ToLowerInvariant() -eq $needle) {
                return 'Protected'
            }
        }
    }
    return 'Orphan'
}

function Get-TenantCollection {
    <#
        Read every collection from the Purview account, following
        the documented $skipToken pagination. Returns a list of the
        raw response objects (callers normalize with
        ConvertTo-TenantCollectionHash).
        Reference: https://learn.microsoft.com/en-us/rest/api/purview/accountdataplane/collections/list-collections
    #>
    param(
        [Parameter(Mandatory = $true)][string]$BaseUri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][string]$ApiVersion
    )

    $items   = New-Object 'System.Collections.Generic.List[object]'
    $uri     = "$BaseUri/collections?api-version=$ApiVersion"

    while ($uri) {
        $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers $Headers -ErrorAction Stop
        if ($resp.value) {
            foreach ($v in $resp.value) { $items.Add($v) | Out-Null }
        }
        # Pagination: the LIST response defines `nextLink` (absolute
        # URL) when more pages exist; a `$skipToken` query parameter
        # is also supported on the GET. We honour the server's
        # nextLink when present, otherwise stop.
        if ($resp.PSObject.Properties.Name -contains 'nextLink' -and $resp.nextLink) {
            $uri = [string]$resp.nextLink
        } else {
            $uri = $null
        }
    }
    return $items.ToArray()
}

function ConvertTo-CollectionExportDoc {
    <#
        Build the ordered desired-state document from a normalized
        list of tenant collection hashes (each shaped like the output
        of ConvertTo-TenantCollectionHash: @{ name; friendlyName;
        description; parent }).

        Exposed as a separate function so the export logic is unit-
        testable without touching the REST surface or the powershell-
        yaml module. Locks in the issue #309 contract:

          1. Every tenant collection appears in the returned doc
             exactly once. Entries whose parent is not the walked
             root (e.g. parented to the system root, or a sibling
             that the walk did not reach) are still emitted -- at
             the top level, with their actual parent preserved so
             a round-trip apply reports NoChange.
          2. The returned WrittenCount equals the number of entries
             actually emitted (root excluded), so the export banner
             reports the count of written entries instead of the
             count of tenant collections read.

        Returns a PSCustomObject with:
          Document     : [ordered] hashtable suitable for ConvertTo-Yaml
          WrittenCount : [int] number of entries emitted

        Reference: https://learn.microsoft.com/en-us/rest/api/purview/accountdataplane/collections/list-collections
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RootName,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable[]]$TenantHashes
    )

    # Index by name and by parent (case-insensitive).
    $byName     = @{}
    $childrenOf = @{}
    foreach ($h in $TenantHashes) {
        if (-not $h -or [string]::IsNullOrEmpty([string]$h.name)) { continue }
        $byName[$h.name.ToLowerInvariant()] = $h
        $pkey = if ($h.parent) { $h.parent.ToLowerInvariant() } else { '' }
        if (-not $childrenOf.ContainsKey($pkey)) {
            $childrenOf[$pkey] = New-Object 'System.Collections.Generic.List[hashtable]'
        }
        $childrenOf[$pkey].Add($h) | Out-Null
    }

    $emitted = @{}

    # Closure: builds a node (and recursively its emitted descendants),
    # marking $emitted as it goes. $ParentOverride is used for unwalked
    # top-level entries whose actual parent is not the walked root.
    $buildNode = {
        param([hashtable]$Entry, [bool]$Top, [string]$ParentOverride)
        $node = [ordered]@{}
        $node.name = $Entry.name
        if (-not [string]::IsNullOrEmpty($Entry.friendlyName)) { $node.friendlyName = $Entry.friendlyName }
        if (-not [string]::IsNullOrEmpty($Entry.description))  { $node.description  = $Entry.description }
        if ($Top) {
            $node.parent = if (-not [string]::IsNullOrEmpty($ParentOverride)) { $ParentOverride } else { $RootName }
        }
        $emitted[$Entry.name.ToLowerInvariant()] = $true
        $pkey = $Entry.name.ToLowerInvariant()
        if ($childrenOf.ContainsKey($pkey) -and $childrenOf[$pkey].Count -gt 0) {
            $kids = New-Object 'System.Collections.Generic.List[object]'
            # Stable order: alphabetical by name for deterministic round-trip.
            $sorted = $childrenOf[$pkey] | Sort-Object -Property { $_.name.ToLowerInvariant() }
            foreach ($k in $sorted) {
                $kids.Add((& $buildNode -Entry $k -Top $false -ParentOverride '')) | Out-Null
            }
            $node.children = $kids.ToArray()
        }
        return $node
    }

    $topLevel  = New-Object 'System.Collections.Generic.List[object]'
    $rootLower = $RootName.ToLowerInvariant()

    # Top-level entries: parent == root (case-insensitive) AND name != root.
    $topSorted = $byName.Values | Where-Object {
        $_.name.ToLowerInvariant() -ne $rootLower -and
        ($_.parent -and $_.parent.ToLowerInvariant() -eq $rootLower)
    } | Sort-Object -Property { $_.name.ToLowerInvariant() }
    foreach ($t in $topSorted) {
        $topLevel.Add((& $buildNode -Entry $t -Top $true -ParentOverride '')) | Out-Null
    }

    # Unwalked entries: tenant collections not yet emitted (and not
    # the root). Issue #309: ensure every tenant collection appears
    # in the exported YAML, even when its parent is the system root
    # or otherwise not the walked root collection. Preserve the
    # actual parent so the round-trip reports NoChange.
    $unwalked = $byName.Values | Where-Object {
        $_.name.ToLowerInvariant() -ne $rootLower -and
        -not $emitted.ContainsKey($_.name.ToLowerInvariant())
    } | Sort-Object -Property { $_.name.ToLowerInvariant() }
    foreach ($u in $unwalked) {
        # Re-check $emitted: an earlier unwalked entry's recursive
        # descent may have already emitted this one as its child.
        if ($emitted.ContainsKey($u.name.ToLowerInvariant())) { continue }
        $parentRef = if ($u.parent) { $u.parent } else { $RootName }
        $topLevel.Add((& $buildNode -Entry $u -Top $true -ParentOverride $parentRef)) | Out-Null
    }

    $doc = [ordered]@{
        rootCollection = $RootName
        collections    = $topLevel.ToArray()
    }

    return [pscustomobject]@{
        Document     = $doc
        WrittenCount = $emitted.Count
    }
}

function Invoke-CollectionExport {
    <#
        Build the desired-state YAML body from the live tenant tree.
        Preserves any leading comment / blank-line header from the
        existing file (so the Microsoft Learn reference comment in
        collections.yaml survives a round-trip). Delegates the
        doc-building to ConvertTo-CollectionExportDoc (issue #309)
        so the orphan / unwalked-entry contract is unit-testable.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RootName,
        [Parameter(Mandatory = $true)][object[]]$TenantCollections,
        [Parameter(Mandatory = $true)][bool]$ForceOverwrite
    )

    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Content -LiteralPath $Path -Raw
        $hasBody  = $false
        if ($existing) {
            try {
                $existingDoc = $existing | ConvertFrom-Yaml -ErrorAction Stop
                if ($existingDoc -and $existingDoc.ContainsKey('collections') -and $existingDoc.collections -and $existingDoc.collections.Count -gt 0) {
                    $hasBody = $true
                }
            } catch {
                # If it doesn't parse, treat as no-body so the export can repair it.
                $hasBody = $false
            }
        }
        if ($hasBody -and -not $ForceOverwrite) {
            Write-Error ("Target YAML '{0}' already declares collections. Re-run with -Force to overwrite." -f $Path)
            return
        }
    }

    # Preserve leading comment / blank-line header (everything up to
    # the first non-comment, non-blank line).
    $headerLines = @()
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in (Get-Content -LiteralPath $Path)) {
            if ($line -match '^\s*$' -or $line -match '^\s*#') { $headerLines += $line } else { break }
        }
    }

    # Normalize tenant list, then delegate doc building.
    $tenantHashes = @($TenantCollections | ForEach-Object { ConvertTo-TenantCollectionHash -Collection $_ -RootName $RootName })
    $built = ConvertTo-CollectionExportDoc -RootName $RootName -TenantHashes $tenantHashes

    $body = ConvertTo-Yaml $built.Document
    $nl   = [Environment]::NewLine
    $output = if ($headerLines.Count) { ($headerLines -join $nl) + $nl + $body } else { $body }
    Set-Content -LiteralPath $Path -Value $output -Encoding utf8
    # Issue #309: banner reports the count of entries actually
    # written, not the count of tenant collections read.
    Write-Information ("Exported {0} collection(s) to '{1}'." -f $built.WrittenCount, $Path) -InformationAction Continue
}

#endregion

#region Module dependencies

# Reference: https://www.powershellgallery.com/packages/powershell-yaml
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Information 'Installing powershell-yaml module to CurrentUser scope.' -InformationAction Continue
    Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
}
Import-Module 'powershell-yaml' -ErrorAction Stop

# Reference: docs/adr/0029-source-of-truth-direction-policy.md
Import-Module (Join-Path $PSScriptRoot 'modules/DirectionPolicy.psm1') `
    -Force -Scope Local -ErrorAction Stop

# In-repo ADR 0052 destructive-operation confirmation gate. Wraps
# $PSCmdlet.ShouldContinue() -- which prompts unconditionally, independent
# of $ConfirmPreference -- so neither destructive branch (repo-wins
# overwrite, -PruneMissing delete) can be entered unattended from a local
# terminal.
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
if (-not $parameters.ContainsKey('purviewAccountName')) {
    Write-Error ("Parameters file '{0}' is missing required key 'purviewAccountName'. Reference: docs/adr/0012-environment-parameters-file.md." -f $ParametersFile)
    return
}

if (-not $PurviewAccountName) { $PurviewAccountName = [string]$parameters.purviewAccountName }

$mode = if ($ExportCurrentState.IsPresent) { 'Export' } else { 'Apply' }
Write-Information ("Parameters file : {0}" -f $ParametersFile) -InformationAction Continue
Write-Information ("Environment     : {0}" -f $parameters.environment) -InformationAction Continue
Write-Information ("Purview account : {0}" -f $PurviewAccountName) -InformationAction Continue
Write-Information ("YAML path       : {0}" -f $Path) -InformationAction Continue
Write-Information ("Mode            : {0}" -f $mode) -InformationAction Continue
if ($mode -eq 'Apply') {
    Write-Information ("DirectionPolicy : {0}" -f $DirectionPolicy) -InformationAction Continue
    Write-Information ("SkipNames count : {0}" -f $SkipNames.Count) -InformationAction Continue
}

#endregion

#region Desired-state load (Apply mode only -- Export overwrites the file)

$desiredEntries = @()
if ($mode -eq 'Apply') {
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Error ("Desired-state YAML not found at '{0}'." -f $Path)
        return
    }
    $Path = (Resolve-Path -LiteralPath $Path).Path
    $desiredRoot = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml
    if (-not $desiredRoot) {
        Write-Error ("Desired-state YAML '{0}' parsed as empty." -f $Path)
        return
    }

    # The YAML's rootCollection is informational here; the script
    # always trusts -PurviewAccountName / parameters file for the
    # actual account binding. If the YAML disagrees, surface the
    # mismatch loudly: a contributor probably copy-pasted the wrong
    # file.
    if ($desiredRoot.ContainsKey('rootCollection') -and $desiredRoot.rootCollection) {
        if ([string]$desiredRoot.rootCollection -ine $PurviewAccountName) {
            Write-Error ("YAML rootCollection '{0}' does not match the target Purview account '{1}'. Update the YAML or pass -PurviewAccountName explicitly." -f $desiredRoot.rootCollection, $PurviewAccountName)
            return
        }
    }

    # Optional protected-name allow-list (issue #312). Lowercased here
    # so the orphan-categorization helper can do a single-pass case-
    # insensitive compare. Absent / null / empty all collapse to @().
    $protectedNames = @()
    if ($desiredRoot.ContainsKey('protected') -and $desiredRoot.protected) {
        $protectedNames = @($desiredRoot.protected | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() })
    }

    $desiredEntries = @(ConvertTo-DesiredCollectionList -Tree $desiredRoot -RootName $PurviewAccountName)

    Write-Information ("Desired         : {0} collection(s)" -f $desiredEntries.Count) -InformationAction Continue
    if ($protectedNames.Count -gt 0) {
        Write-Information ("Protected       : {0} name(s) ({1})" -f $protectedNames.Count, ($protectedNames -join ', ')) -InformationAction Continue
    }

    # Issue #13, guard 1: empty-desired-set hard refusal for -PruneMissing.
    #
    # ConvertTo-DesiredCollectionList never emits the root collection, so a
    # count of zero really does mean "no managed collections declared". With
    # zero desired entries every live child collection falls out of the orphan
    # match below and the run would delete the whole hierarchy. The rationale,
    # the likely causes, and the 2026-07-19 production hit are documented in
    # scripts/modules/PruneGuard.psm1.
    #
    # Placed in the desired-state load region so it fires before the tenant is
    # contacted at all -- before `az account show` and before any write phase.
    if ($PruneMissing.IsPresent) {
        Assert-PruneDesiredSetNotEmpty `
            -DesiredCount   $desiredEntries.Count `
            -ObjectTypeNoun 'collection' `
            -SourcePath     $Path `
            -CollectionKey  'collections'
    }

    # Pre-flight collection-name validation moved to after the
    # tenant GET so the rule can be skipped for names already
    # present in the tenant (see Get-CollectionNameViolation
    # -KnownNames). The rule still guards every newly authored
    # YAML entry.
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

#region Connect to the Purview data plane

# Reference: scripts/Connect-Purview.ps1 (shared helper -- acquires
# the Purview data-plane token via the Azure CLI cache and returns
# the canonical Atlas / accountdataplane endpoint).
$connectScript = Join-Path $scriptRoot 'Connect-Purview.ps1'
if (-not (Test-Path -LiteralPath $connectScript)) {
    Write-Error ("Helper not found: '{0}'." -f $connectScript)
    return
}
$ctx = & $connectScript -AccountName $PurviewAccountName
if (-not $ctx -or -not $ctx.DataHeaders -or -not $ctx.Endpoint) {
    Write-Error 'Connect-Purview.ps1 did not return data-plane headers.'
    return
}
# The accountdataplane operation group is rooted at /account/.
# Reference: https://learn.microsoft.com/en-us/rest/api/purview/accountdataplane/collections/list-collections
$baseUri = "$($ctx.Endpoint)/account"
Write-Information ("Endpoint        : {0}" -f $baseUri) -InformationAction Continue

#endregion

#region Read tenant state

try {
    $tenantRaw = @(Get-TenantCollection -BaseUri $baseUri -Headers $ctx.DataHeaders -ApiVersion $script:CollectionsApiVersion)
} catch {
    Write-Error ("Failed to list tenant collections: {0}" -f (Format-PurviewRestError -ErrorRecord $_))
    return
}
Write-Information ("Tenant          : {0} collection(s)" -f $tenantRaw.Count) -InformationAction Continue

# Build a case-insensitive index. Identify the root collection by
# matching the Purview account name (case-insensitive); track its
# canonical name (whatever Purview returned) so we can reference it
# from PUT bodies and Export output.
$tenantByName = @{}
$rootCanonical = $null
foreach ($t in $tenantRaw) {
    $h = ConvertTo-TenantCollectionHash -Collection $t -RootName $PurviewAccountName
    $tenantByName[$h.name.ToLowerInvariant()] = $h
    if ($h.name.ToLowerInvariant() -eq $PurviewAccountName.ToLowerInvariant()) {
        $rootCanonical = $h.name
    }
}
if (-not $rootCanonical) {
    # The tenant did not return an entry matching the account name.
    # Fall back to the parameter value; PUTs against the root parent
    # will still resolve because Purview accepts the literal account
    # name as a reference.
    $rootCanonical = $PurviewAccountName
}
Write-Information ("Root collection : {0}" -f $rootCanonical) -InformationAction Continue

#endregion

#region Pre-flight collection-name validation (Apply mode)

# Validate names for entries that do NOT already exist in the tenant.
# Names already present in the tenant are accepted by the REST surface
# by definition (the portal's create flow auto-generates short URL
# segments like '85cv3o' that fail the human-input rule yet round-trip
# cleanly via Export -> Apply). Issue #310 still guards every newly
# authored YAML entry. Reference:
# https://learn.microsoft.com/en-us/purview/quickstart-create-collection
if ($mode -eq 'Apply') {
    $violations = @(Get-CollectionNameViolation -Entries $desiredEntries -KnownNames @($tenantByName.Keys))
    if ($violations.Count -gt 0) {
        $lines = $violations | ForEach-Object { "  - {0}: {1}" -f $_.Name, $_.Reason }
        Write-Error (
            "Invalid collection name(s) for new YAML entries (rule: ^[a-z][a-z0-9-]{2,35}$ -- see https://learn.microsoft.com/en-us/purview/quickstart-create-collection):`n" +
            ($lines -join "`n")
        )
        return
    }
}

#endregion

#region Export short-circuit

if ($mode -eq 'Export') {
    $exportTarget = if (Test-Path -LiteralPath $Path) {
        (Resolve-Path -LiteralPath $Path).Path
    } else {
        # Resolve the parent so Set-Content can write the new file.
        $parent = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $parent)) {
            Write-Error ("Parent directory does not exist: '{0}'." -f $parent)
            return
        }
        Join-Path ((Resolve-Path -LiteralPath $parent).Path) (Split-Path -Leaf $Path)
    }
    if ($PSCmdlet.ShouldProcess($exportTarget, 'Write exported collection hierarchy')) {
        Invoke-CollectionExport `
            -Path $exportTarget `
            -RootName $rootCanonical `
            -TenantCollections $tenantRaw `
            -ForceOverwrite $Force.IsPresent
    } else {
        Write-Information '-WhatIf specified with -ExportCurrentState. Planned behaviour (no file written):' -InformationAction Continue
        Write-Information ("  Would write {0} collection(s) to '{1}'." -f $tenantRaw.Count, $exportTarget) -InformationAction Continue
    }
    return
}

#endregion

#region Build plan

$rootKey = $PurviewAccountName.ToLowerInvariant()
$desiredByName = @{}
foreach ($d in $desiredEntries) {
    $key = $d.name.ToLowerInvariant()
    if ($desiredByName.ContainsKey($key)) {
        Write-Error ("Duplicate collection name '{0}' in YAML. Names must be unique within the account." -f $d.name)
        return
    }
    $desiredByName[$key] = $d
}

# Topological ordering of desired entries: parents before children.
# Required for the Create path because PUTting a child whose parent
# does not yet exist returns 4xx from Purview.
function Resolve-DesiredOrder {
    param([hashtable]$Index, [string]$RootKey)
    $emitted = New-Object 'System.Collections.Generic.HashSet[string]'
    $emitted.Add($RootKey) | Out-Null
    $ordered = New-Object 'System.Collections.Generic.List[hashtable]'
    $remaining = New-Object 'System.Collections.Generic.List[hashtable]'
    foreach ($v in $Index.Values) { $remaining.Add($v) | Out-Null }
    while ($remaining.Count -gt 0) {
        $progress = $false
        for ($i = $remaining.Count - 1; $i -ge 0; $i--) {
            $entry = $remaining[$i]
            $pkey = if ($entry.parent) { $entry.parent.ToLowerInvariant() } else { $RootKey }
            if ($emitted.Contains($pkey)) {
                $ordered.Add($entry) | Out-Null
                $emitted.Add($entry.name.ToLowerInvariant()) | Out-Null
                $remaining.RemoveAt($i)
                $progress = $true
            }
        }
        if (-not $progress) {
            $orphans = $remaining | ForEach-Object { "'$($_.name)' -> '$($_.parent)'" }
            throw ("Cycle or missing parent in YAML collection tree. Unresolved: {0}." -f ($orphans -join ', '))
        }
    }
    return $ordered.ToArray()
}

$desiredOrdered = Resolve-DesiredOrder -Index $desiredByName -RootKey $rootKey

$plan = New-Object 'System.Collections.Generic.List[object]'
foreach ($d in $desiredOrdered) {
    $key = $d.name.ToLowerInvariant()
    if ($tenantByName.ContainsKey($key)) {
        $diffs = Compare-CollectionHash -Desired $d -Tenant $tenantByName[$key]
        if ($diffs.Count -eq 0) {
            $plan.Add([pscustomobject]@{ Action = 'NoChange'; Name = $d.name; Desired = $d; Reason = 'In sync with tenant.' }) | Out-Null
        } else {
            $plan.Add([pscustomobject]@{ Action = 'Update'; Name = $d.name; Desired = $d; Reason = ('Drift in: {0}' -f ($diffs -join ', ')) }) | Out-Null
        }
    } else {
        $plan.Add([pscustomobject]@{ Action = 'Create'; Name = $d.name; Desired = $d; Reason = 'Declared in YAML; absent from tenant.' }) | Out-Null
    }
}

# Orphans: tenant collections not in YAML and not the root. Order
# bottom-up so children delete before parents (Purview rejects
# deletion of a parent that still has children, same as MIP labels
# per the user-memory note on Deploy-Labels.ps1 -PruneMissing).
$tenantTopo = @{}
foreach ($t in $tenantByName.Values) {
    $depth = 0
    $cursor = $t
    while ($cursor -and $cursor.parent -and $cursor.parent.ToLowerInvariant() -ne $rootKey) {
        $depth++
        $pkey = $cursor.parent.ToLowerInvariant()
        if (-not $tenantByName.ContainsKey($pkey)) { break }
        $cursor = $tenantByName[$pkey]
        if ($depth -gt 32) { break }   # safety stop
    }
    $tenantTopo[$t.name.ToLowerInvariant()] = $depth
}
$orphans = @($tenantByName.Values | Where-Object {
    $_.name.ToLowerInvariant() -ne $rootKey -and
    -not $desiredByName.ContainsKey($_.name.ToLowerInvariant())
} | Sort-Object -Property { -1 * $tenantTopo[$_.name.ToLowerInvariant()] })

foreach ($o in $orphans) {
    $action = Get-OrphanAction -Name $o.name -ProtectedNames $protectedNames
    $reason = if ($action -eq 'Protected') {
        "Tenant-only; skipped (name in 'protected:' allow-list)."
    } elseif ($PruneMissing.IsPresent) {
        'Tenant-only; will be removed (-PruneMissing).'
    } else {
        'Tenant-only; skipped (no -PruneMissing).'
    }
    $plan.Add([pscustomobject]@{ Action = $action; Name = $o.name; Desired = $null; Reason = $reason }) | Out-Null
}

#endregion

#region ADR 0029 direction-policy pass

# Audit short-circuit: `-DirectionPolicy audit` flips $WhatIfPreference
# for the rest of this script so every $PSCmdlet.ShouldProcess(...)
# call in the apply loop returns false and falls into its existing
# "Would ..." else branch. No PUT / DELETE writes against the REST
# surface under any circumstance, while the categorized plan-with-
# would-rows is preserved end-to-end.
# Reference: docs/adr/0029-source-of-truth-direction-policy.md
if ($DirectionPolicy -eq 'audit') {
    Write-Information '[ADR0029-AUDIT] DirectionPolicy=audit - no writes will fire. Plan below is read-only.' -InformationAction Continue
    $WhatIfPreference = $true
}

# Direction-policy pass on the plan. -SkipNames mutates every row
# category (Create / Update / NoChange / Orphan / Protected) so the
# workflow can suppress noise on operator-managed names regardless
# of category. portal-wins drift arbitration applies to Update rows
# only. Audit mode short-circuited above does not enter this pass.
# Reference: docs/adr/0029-source-of-truth-direction-policy.md
$script:Adr0029Skips = New-Object 'System.Collections.Generic.List[object]'

# ADR 0052: every collection whose tenant fields this run WILL overwrite.
# Constructed OUTSIDE the policy test below so the gate can read .Count on
# it unconditionally -- under `audit` the pass never runs, the list stays
# empty, and the gate correctly stays silent.
$repoWinsOverwrites = New-Object 'System.Collections.Generic.List[string]'

if ($DirectionPolicy -ne 'audit') {
    foreach ($row in $plan) {
        if ($row.Action -notin @('Create','Update','NoChange','Orphan','Protected')) { continue }
        $hasDrift = ($row.Action -eq 'Update')
        $decision = Resolve-DirectionPolicyAction `
            -Policy      $DirectionPolicy `
            -SkipList    $SkipNames `
            -DisplayName ([string]$row.Name) `
            -HasDrift    $hasDrift
        if ($decision.Action -eq 'Skip') {
            $row.Action = 'Skip'
            $row.Reason = $decision.Reason
            $script:Adr0029Skips.Add([pscustomobject]@{
                Kind        = 'Collection'
                DisplayName = [string]$row.Name
                Reason      = $decision.Reason
            })
            continue
        }
        if ($row.Action -eq 'Update') {
            $fieldsText = ($row.Reason -replace '^Drift in: ', '')
            if ($DirectionPolicy -eq 'repo-wins') {
                Write-Warning ("repo-wins overwriting tenant on Purview collection '{0}' fields: {1}" -f $row.Name, $fieldsText)
            }
            # Every Update row that survived Resolve-DirectionPolicyAction's Skip
            # decision WILL be PUT, whatever policy let it through. Collect it
            # here, OUTSIDE the repo-wins test above: the ADR 0052 gate is keyed
            # on this list -- the plan -- and never on $DirectionPolicy. Populating
            # it only under repo-wins would leave the list empty under portal-wins,
            # the plan-keyed gate would see zero, and the overwrite would proceed
            # unconfirmed. See ConfirmGate.psm1 "KEY THE GATE ON THE PLAN, NOT ON
            # THE POLICY".
            $repoWinsOverwrites.Add([string]$row.Name) | Out-Null
        }
    }

    # Machine-readable marker per skipped object for the workflow's
    # auto-PR step. One line per skipped object; format must match
    # `^\[ADR0029-SKIP\] (.+)$` per the github-actions instructions.
    foreach ($s in $script:Adr0029Skips) {
        Write-Information ("[ADR0029-SKIP] {0}" -f $s.DisplayName) -InformationAction Continue
    }
}

#endregion

#region ADR 0052 destructive-operation confirmation gate

# The last point before the write loop at which nothing has been PUT or
# DELETEd. Both destructive branches are gated here, once per run, via
# $PSCmdlet.ShouldContinue() -- NOT ShouldProcess(). ShouldContinue prompts
# unconditionally; ShouldProcess only prompts when ConfirmImpact >=
# $ConfirmPreference, which is precisely the comparison that silently
# defeated this gate before issue #85.
#
# Both gates are keyed on the PLAN -- the objects this run will actually
# overwrite or delete -- and never on $DirectionPolicy.
#
# The $yesToAll / $noToAll pair is shared by both gates, so a run that trips
# the overwrite gate AND the prune gate prompts once, not twice, and never
# once per object.
#
# Suppressed by -Force, by an explicit -Confirm:$false (the CI path -- every
# workflow apply step binds it), and skipped under -WhatIf so a dry run still
# previews the deletes without blocking on input. `-DirectionPolicy audit`
# sets $WhatIfPreference above, so an audit run cannot prompt either.
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

if ($repoWinsOverwrites.Count -gt 0) {
    $overwriteNames = @($repoWinsOverwrites | Sort-Object -Unique)
    $overwriteQuery = "This run will OVERWRITE tenant fields on {0} Purview collection(s) with the values from YAML: {1}. Portal edits to those fields are lost. Continue?" -f `
        $overwriteNames.Count, ($overwriteNames -join ', ')
    if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $overwriteQuery)) {
        throw 'Aborted by operator at the repo-wins overwrite confirmation gate (ADR 0052). No tenant writes were made.'
    }
}

# Derived from the FINAL plan one line above the gate and read one line
# later, so it cannot diverge from the deletes it speaks for. Protected rows
# (issue #312) are a distinct Action and are never deleted, so they are
# correctly absent.
$pruneTargets = @($plan | Where-Object { $_.Action -eq 'Orphan' })
if ($PruneMissing.IsPresent -and $pruneTargets.Count -gt 0) {
    $pruneNames = @($pruneTargets | ForEach-Object { [string]$_.Name } | Sort-Object -Unique)
    $pruneQuery = "-PruneMissing will DELETE {0} orphan Purview collection(s) from the account: {1}. This cannot be undone. Continue?" -f `
        $pruneNames.Count, ($pruneNames -join ', ')
    if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $pruneQuery)) {
        throw 'Aborted by operator at the -PruneMissing delete confirmation gate (ADR 0052). No tenant writes were made.'
    }
}

#endregion

#region Execute plan with ShouldProcess

$report = New-Object 'System.Collections.Generic.List[object]'

# Issue #13: in-loop prune failures keep their 'Failed' report row AND are
# reported via Write-PruneFailure (scripts/modules/PruneGuard.psm1), which uses
# Write-Warning plus an '::error::' workflow command rather than Write-Error.
# Previously the Orphan catch added the 'Failed' row and moved on, so a failed
# prune exited 0. Each object in the collection is recorded here and, after the
# apply loop attempts every row, a single aggregate throw names them all so a
# failed prune exits non-zero. No audit / -WhatIf gate is needed on this
# reporter: under -DirectionPolicy audit the script flips $WhatIfPreference, so
# every DELETE ShouldProcess returns false and the delete catch never runs, and
# under -WhatIf the same holds. The issue #13 ratio guard (guard 2) is
# deliberately NOT wired: a subtree teardown legitimately prunes a majority
# (owner decision), so only guard 1 and this reporter protect the prune path.
$pruneFailures = New-Object 'System.Collections.Generic.List[string]'

foreach ($row in $plan) {
    $target = "Purview collection '{0}'" -f $row.Name
    switch ($row.Action) {
        'NoChange' {
            $report.Add([pscustomobject]@{ Category = 'NoChange'; Kind = 'Collection'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
            continue
        }
        'Skip' {
            # ADR 0029 portal-wins drift skip or -SkipNames pre-pass.
            # Reported but never written; -PruneMissing is bypassed.
            $report.Add([pscustomobject]@{ Category = 'Skip'; Kind = 'Collection'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
            continue
        }
        'Create' {
            $opDesc = 'PUT collection (Create)'
            if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                try {
                    $body = @{
                        friendlyName     = $row.Desired.friendlyName
                        description      = $row.Desired.description
                        parentCollection = @{ referenceName = $row.Desired.parent }
                    } | ConvertTo-Json -Depth 5 -Compress
                    $uri = "$baseUri/collections/$([uri]::EscapeDataString($row.Desired.name))?api-version=$script:CollectionsApiVersion"
                    $null = Invoke-RestMethod -Method PUT -Uri $uri -Headers $ctx.DataHeaders -Body $body -ErrorAction Stop
                    $report.Add([pscustomobject]@{ Category = 'Create'; Kind = 'Collection'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
                } catch {
                    $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = 'Collection'; Name = $row.Name; Reason = ("Create failed: {0}" -f (Format-PurviewRestError -ErrorRecord $_)) }) | Out-Null
                }
            } else {
                $report.Add([pscustomobject]@{ Category = 'Create'; Kind = 'Collection'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
            }
            continue
        }
        'Update' {
            $opDesc = 'PUT collection (Update)'
            if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                try {
                    $body = @{
                        friendlyName     = $row.Desired.friendlyName
                        description      = $row.Desired.description
                        parentCollection = @{ referenceName = $row.Desired.parent }
                    } | ConvertTo-Json -Depth 5 -Compress
                    $uri = "$baseUri/collections/$([uri]::EscapeDataString($row.Desired.name))?api-version=$script:CollectionsApiVersion"
                    $null = Invoke-RestMethod -Method PUT -Uri $uri -Headers $ctx.DataHeaders -Body $body -ErrorAction Stop
                    $report.Add([pscustomobject]@{ Category = 'Update'; Kind = 'Collection'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
                } catch {
                    $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = 'Collection'; Name = $row.Name; Reason = ("Update failed: {0}" -f (Format-PurviewRestError -ErrorRecord $_)) }) | Out-Null
                }
            } else {
                $report.Add([pscustomobject]@{ Category = 'Update'; Kind = 'Collection'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
            }
            continue
        }
        'Orphan' {
            if (-not $PruneMissing.IsPresent) {
                $report.Add([pscustomobject]@{ Category = 'Orphan'; Kind = 'Collection'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
                continue
            }
            $opDesc = 'DELETE collection'
            if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                try {
                    $uri = "$baseUri/collections/$([uri]::EscapeDataString($row.Name))?api-version=$script:CollectionsApiVersion"
                    $null = Invoke-RestMethod -Method DELETE -Uri $uri -Headers $ctx.DataHeaders -ErrorAction Stop
                    $report.Add([pscustomobject]@{ Category = 'Removed'; Kind = 'Collection'; Name = $row.Name; Reason = 'Deleted (-PruneMissing).' }) | Out-Null
                } catch {
                    $failureText = Format-PurviewRestError -ErrorRecord $_
                    $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = 'Collection'; Name = $row.Name; Reason = ("Delete failed: {0}" -f $failureText) }) | Out-Null
                    Write-PruneFailure ("DELETE collection '{0}' failed: {1}" -f $row.Name, $failureText)
                    $pruneFailures.Add(("collection '{0}'" -f $row.Name)) | Out-Null
                    continue
                }
            } else {
                $report.Add([pscustomobject]@{ Category = 'Removed'; Kind = 'Collection'; Name = $row.Name; Reason = 'Would be deleted (-PruneMissing).' }) | Out-Null
            }
            continue
        }
        'Protected' {
            # Issue #312: tenant-only collection that matches the
            # `protected:` allow-list. Always reported, never deleted,
            # ignored entirely by -PruneMissing. Distinct from Orphan
            # so operators can see at-a-glance which collections were
            # spared and why.
            $report.Add([pscustomobject]@{ Category = 'Protected'; Kind = 'Collection'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
            continue
        }
    }
}

if ($pruneFailures.Count -gt 0) {
    throw ("Reconciliation aborted: {0} orphan collection(s) could not be deleted: {1}. See errors above." -f $pruneFailures.Count, ($pruneFailures -join ', '))
}

#endregion

#region Emit report

# Per-object rows first (pipeline output), then a summary banner.
# Reference: .github/instructions/powershell.instructions.md "Drift report format".
$report

$counts = @{}
foreach ($r in $report) {
    if (-not $counts.ContainsKey($r.Category)) { $counts[$r.Category] = 0 }
    $counts[$r.Category]++
}
$bannerParts = @()
foreach ($k in @('Create','Update','NoChange','Orphan','Protected','Skip','Removed','Failed')) {
    if ($counts.ContainsKey($k)) { $bannerParts += ("{0} {1}" -f $counts[$k], $k) }
}
if ($bannerParts.Count -gt 0) {
    Write-Information ("Plan: {0}" -f ($bannerParts -join ', ')) -InformationAction Continue
} else {
    Write-Information 'Plan: 0 changes.' -InformationAction Continue
}

#endregion
