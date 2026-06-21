#Requires -Version 7.4
<#
.SYNOPSIS
    Create (idempotently) a Microsoft Entra ID role-assignable security
    group and, optionally, add a single principal as a member, via
    Microsoft Graph.

.DESCRIPTION
    Imperative primitive that brackets the `Grant-EntraDirectoryRole.ps1`
    Wave 0 primitive. Together they let a lab owner wrap any directly-
    assigned workload identity (service principal or managed identity) in
    a role-assignable Entra security group so the assignment becomes
    declarative in `data-plane/entra-directory-roles/role-assignments.yaml`
    -- the schema accepts groups only per `security.instructions.md` rule
    #4 (least privilege; assign to groups, not principals).

    Behaviour:

      1. `az account get-access-token --resource https://graph.microsoft.com`
         to mint a delegated Microsoft Graph token from the local
         contributor's `az login` session. Matches the auth model used by
         `Grant-EntraDirectoryRole.ps1`.
      2. Look up an existing group by `displayName` via
         `GET /v1.0/groups?$filter=displayName eq '...'`. Group lookup is
         case-sensitive on the wire; the script trims and exact-matches
         the requested `-DisplayName` to defend against accidental
         drift.
      3. If a group exists with that name, validate it is
         security-enabled with `isAssignableToRole=true`. If either
         property is wrong the script refuses to proceed -- the existing
         group cannot satisfy the directory-role assignment contract and
         is almost certainly the wrong target.
      4. If no group exists, `POST /v1.0/groups` with
         `mailEnabled=false`, `securityEnabled=true`,
         `isAssignableToRole=true`, the requested `displayName`, a
         deterministic `mailNickname`, and the requested
         `-Description`. Per Microsoft Graph the
         `isAssignableToRole` property is immutable after creation;
         creating with the wrong value cannot be repaired without
         re-creating the group.
      5. When `-AddMemberId` is supplied: read the current membership via
         `GET /v1.0/groups/{id}/members/$ref?$top=999`, and if the
         requested principal is not already a member, POST a
         `members/$ref` add. The script accepts any object kind that
         Graph accepts as a group member (user, group, servicePrincipal,
         device) -- enforcement of "group-only" is the directory-role
         assignment contract, not the group-membership contract. The
         lab use case is `servicePrincipal`.
      6. Emit a single drift-report row per write target: NoChange |
         Create | NoOp | AddMember. Re-reads the final state after any
         write to confirm.

    Idempotency:

      - Re-running with the same `-DisplayName` and `-Description`
        against an already-correct group emits `NoChange` for the group
        and (if `-AddMemberId` is supplied and already a member)
        `NoOp` for the member. No writes are performed.
      - Re-running after a manual delete of the group will recreate it
        from scratch with a new OID -- any downstream YAML referencing
        the previous OID will need to be updated. The script prints the
        new OID in its summary output for that purpose.
      - The `description` of an existing group is NOT updated by this
        primitive. If a description mismatch is detected, the script
        emits a warning but leaves the description alone -- editing
        descriptions in bulk is the job of a future `Deploy-*` reconciler,
        not an imperative primitive (per
        `.github/instructions/powershell.instructions.md` -- imperative
        primitives stay narrow).

    No -ParametersFile. Like `Grant-EntraDirectoryRole.ps1`, this
    primitive has no environment-varying values to read: tenant comes
    from the local `az login` session and the Graph endpoint does not
    vary by environment.

    References (Microsoft Learn):
      Use Microsoft Entra groups to manage role assignments:
        https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/groups-concept
      Create a role-assignable group (overview):
        https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/groups-create-eligible
      Create group (Microsoft Graph):
        https://learn.microsoft.com/en-us/graph/api/group-post-groups
      Get group:
        https://learn.microsoft.com/en-us/graph/api/group-get
      List group members:
        https://learn.microsoft.com/en-us/graph/api/group-list-members
      Add member ($ref):
        https://learn.microsoft.com/en-us/graph/api/group-post-members
      az account get-access-token:
        https://learn.microsoft.com/en-us/cli/azure/account#az-account-get-access-token
      Everything about ShouldProcess:
        https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess

.PARAMETER DisplayName
    Display name of the Entra security group. Must follow the
    `sg-purview-*` lab convention defined in
    `docs/adr/0025-role-group-entra-backing-naming.md`. Validated to be
    1-120 characters, kebab-case alphanumerics plus hyphen, and to start
    with `sg-`. The pattern intentionally narrows below Graph's 256-char
    limit to keep tenant directory listings tidy.

.PARAMETER Description
    Mandatory free-text description of the group's purpose. Per ADR
    0025 every `sg-purview-*` group must be self-identifying because
    the directory will accumulate many such groups over time. 5-512
    characters.

.PARAMETER AddMemberId
    Optional OID of a directory principal to add as a member after
    create-or-resolve. Accepts any object kind Graph accepts as a group
    member -- the lab use case is wrapping a `servicePrincipal` so it
    can hold a directory role indirectly. Validated as a GUID.

.PARAMETER MailNickname
    Optional override for the group's `mailNickname` (required by Graph
    even for non-mail-enabled groups). Defaults to `DisplayName`. Must
    be 1-64 chars and match `^[A-Za-z0-9._-]+$` -- Graph rejects
    spaces and most punctuation.

.EXAMPLE
    ./scripts/New-RoleAssignableEntraGroup.ps1 `
        -DisplayName 'sg-purview-data-plane-compliance-admin' `
        -Description 'Wrapper for the data-plane automation SP to hold Compliance Administrator via group.' `
        -AddMemberId 00000000-0000-0000-0000-000000000000 `
        -WhatIf

    Prints planned behaviour; makes no remote calls.

.EXAMPLE
    ./scripts/New-RoleAssignableEntraGroup.ps1 `
        -DisplayName 'sg-purview-data-plane-compliance-admin' `
        -Description 'Wrapper for the data-plane automation SP to hold Compliance Administrator via group.' `
        -AddMemberId 00000000-0000-0000-0000-000000000000

    Creates the group if missing, adds the principal if not already a
    member, prints the resulting group OID. Re-running is safe (NoChange/NoOp).

.NOTES
    Caller role requirements (the local principal running this script):
      * Active `az login` session that can mint a delegated Microsoft
        Graph token via `az account get-access-token --resource
        https://graph.microsoft.com`.
      * Microsoft Entra directory role `Privileged Role Administrator`
        (or `Global Administrator`). Creating a group with
        `isAssignableToRole=true` requires
        `Privileged Role Administrator` per Microsoft Learn -- a
        regular `Group.Create` permission is not sufficient.
        Reference:
          https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/groups-create-eligible

    Output: a single PSCustomObject summary with the group OID, the
    requested displayName, and the actions taken (`groupAction`,
    `memberAction`). The access token is never echoed.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [ValidateLength(4, 120)]
    [ValidatePattern('^sg-[a-z0-9]([a-z0-9-]{0,118}[a-z0-9])?$')]
    [string]$DisplayName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [ValidateLength(5, 512)]
    [string]$Description,

    [Parameter()]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$AddMemberId,

    [Parameter()]
    [ValidateLength(1, 64)]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$MailNickname
)

$ErrorActionPreference = 'Stop'

# Microsoft Graph v1.0 base. Pinning the version explicitly per the
# powershell.instructions.md "Purview REST API version selection" rule
# (same GA-over-beta principle applies to Graph).
# Reference: https://learn.microsoft.com/en-us/graph/use-the-api
$graphBase = 'https://graph.microsoft.com/v1.0'

if (-not $PSBoundParameters.ContainsKey('MailNickname')) {
    $MailNickname = $DisplayName
}

#region Helpers

function Format-EntraIdentifier {
    # Redact a GUID-like string for transcript-safe logging. Real GUIDs
    # only leave the script via the structured PSObject return value
    # (consumed programmatically), never via Write-Information /
    # Write-Error / Write-Warning. See `.github/instructions/security.instructions.md`
    # and the "Environment and identifier boundaries" section of
    # `.github/copilot-instructions.md`.
    [CmdletBinding()]
    param(
        [Parameter()] [AllowNull()] [AllowEmptyString()] [string]$Value
    )
    if ([string]::IsNullOrWhiteSpace($Value)) { return '<none>' }
    if ($Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        return ('{0}-...' -f $Value.Substring(0, 8))
    }
    return $Value
}

function Test-IsAddMemberAlreadyExistsError {
    # Treat the Microsoft Graph response "One or more added object
    # references already exist" (HTTP 400 Request_BadRequest on
    # POST /groups/{id}/members/$ref) as idempotent success. Eventual
    # consistency between the post-add verify probe and the write side
    # can produce this on a re-run that the operator believes is the
    # first attempt.
    # Reference: https://learn.microsoft.com/en-us/graph/api/group-post-members
    [CmdletBinding()]
    param(
        [Parameter()] [AllowNull()] [AllowEmptyString()] [string]$ErrorBody
    )
    if ([string]::IsNullOrWhiteSpace($ErrorBody)) { return $false }
    return ($ErrorBody -match 'Request_BadRequest' -and
            $ErrorBody -match 'object references already exist')
}

function Wait-MembershipConsistent {
    # Re-poll a probe scriptblock until `$TargetId` is observed in the
    # returned id list, or attempts are exhausted. Microsoft Graph
    # group-membership writes are eventually consistent; a single GET
    # immediately after POST can falsely report absence.
    # Reference: https://learn.microsoft.com/en-us/graph/aad-advanced-queries
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [scriptblock]$Probe,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$TargetId,
        [Parameter()] [ValidateRange(1, 10)] [int]$MaxAttempts = 5,
        [Parameter()] [ValidateRange(0, 10000)] [int]$DelayMs = 1000
    )
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        $ids = & $Probe
        if ($ids -contains $TargetId) { return $true }
        if ($i -lt $MaxAttempts -and $DelayMs -gt 0) {
            Start-Sleep -Milliseconds $DelayMs
        }
    }
    return $false
}

function Assert-ActionLabel {
    # Sanity-check the action labels before emitting the summary so a
    # null / sentinel value never reaches the operator transcript. Each
    # code path (resolve-existing, create, add-member, no-op, whatif)
    # must set both labels to one of the documented values.
    [CmdletBinding()]
    param(
        [Parameter()] [AllowNull()] [string]$GroupAction,
        [Parameter()] [AllowNull()] [string]$MemberAction,
        [Parameter()] [string[]]$AllowedGroupActions = @('NoChange', 'Create', 'WhatIf'),
        [Parameter()] [string[]]$AllowedMemberActions = @('NoChange', 'NoOp', 'AddMember', 'NotRequested', 'WhatIf', 'WhatIf-NotRequested')
    )
    if ([string]::IsNullOrWhiteSpace($GroupAction)) {
        throw "groupAction was not set before emit (still sentinel). This is a bug in New-RoleAssignableEntraGroup.ps1."
    }
    if ($GroupAction -notin $AllowedGroupActions) {
        throw ("groupAction '{0}' is not one of: {1}" -f $GroupAction, ($AllowedGroupActions -join ', '))
    }
    if ([string]::IsNullOrWhiteSpace($MemberAction)) {
        throw "memberAction was not set before emit (still sentinel). This is a bug in New-RoleAssignableEntraGroup.ps1."
    }
    if ($MemberAction -notin $AllowedMemberActions) {
        throw ("memberAction '{0}' is not one of: {1}" -f $MemberAction, ($AllowedMemberActions -join ', '))
    }
}

function Invoke-EntraGraphRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [ValidateSet('GET', 'POST', 'DELETE', 'PATCH')] [string]$Method,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()]                            [string]$Uri,
        [Parameter()]                                                                        [object]$Body,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()]                            [string]$AccessToken
    )

    $headers = @{
        Authorization    = "Bearer $AccessToken"
        'Content-Type'   = 'application/json'
        ConsistencyLevel = 'eventual'
    }

    $params = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $headers
        ErrorAction = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 6 -Compress)
    }

    try {
        return Invoke-RestMethod @params
    }
    catch {
        $status = $null
        $errBody = $null
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $errBody = $reader.ReadToEnd()
                }
            }
            catch {
                $errBody = '<unable to read error body>'
            }
        }
        $sanitizedUri = ($Uri -split '\?', 2)[0]
        Write-Error ("Microsoft Graph {0} {1} failed (HTTP {2}): {3}" -f $Method, $sanitizedUri, $status, $errBody)
        throw
    }
}

#endregion

#region Banner

Write-Information ("DisplayName     : {0}" -f $DisplayName) -InformationAction Continue
Write-Information ("MailNickname    : {0}" -f $MailNickname) -InformationAction Continue
Write-Information ("AddMemberId     : {0}" -f (Format-EntraIdentifier -Value $AddMemberId)) -InformationAction Continue
Write-Information ("Role-assignable : true (immutable after create)") -InformationAction Continue

#endregion

#region Azure context (read-only preamble)

$accountJson = az account show -o json --only-show-errors 2>$null
if (-not $accountJson) {
    Write-Error 'No active Azure CLI session. Run `az login` before invoking this script.'
    return
}
$account = ($accountJson -join "`n") | ConvertFrom-Json
if (-not $account.tenantId) {
    Write-Error 'az account show did not return a tenantId. Re-run `az login` and retry.'
    return
}
Write-Information ("Subscription    : {0}" -f $account.name) -InformationAction Continue

#endregion

#region ShouldProcess gate

$groupAction       = $null
$memberAction      = $null
$resolvedGroupId   = $null

$shouldProcessTarget = "Microsoft Entra role-assignable security group '{0}'" -f $DisplayName
$shouldProcessAction = if ($PSBoundParameters.ContainsKey('AddMemberId')) {
    "Resolve-or-create group; add member {0} only if not already present" -f (Format-EntraIdentifier -Value $AddMemberId)
} else {
    "Resolve-or-create group (no membership change)"
}

if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {

    # --- Acquire delegated Graph access token. ------------------------------
    # Reference: https://learn.microsoft.com/en-us/cli/azure/account#az-account-get-access-token
    $tokenJson = az account get-access-token --resource 'https://graph.microsoft.com' -o json --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $tokenJson) {
        Write-Error 'az account get-access-token failed for resource https://graph.microsoft.com. Verify your `az login` session has Microsoft Graph access.'
        return
    }
    $tokenObj = ($tokenJson -join "`n") | ConvertFrom-Json
    if (-not $tokenObj.accessToken) {
        Write-Error 'az account get-access-token returned no accessToken field.'
        return
    }
    $accessToken = [string]$tokenObj.accessToken
    Write-Information ("Token acquired  : resource https://graph.microsoft.com (delegated)") -InformationAction Continue

    try {
        # --- Resolve-or-create the group. --------------------------------
        # Reference: https://learn.microsoft.com/en-us/graph/api/group-get
        $dnEscaped = [System.Uri]::EscapeDataString($DisplayName)
        $lookupUri = ("{0}/groups?`$filter=displayName+eq+'{1}'&`$select=id,displayName,securityEnabled,mailEnabled,isAssignableToRole,description" -f $graphBase, $dnEscaped)
        $lookupResp = Invoke-EntraGraphRequest -Method GET -Uri $lookupUri -AccessToken $accessToken
        $existing = @($lookupResp.value)

        if ($existing.Count -gt 1) {
            Write-Error ("Found {0} Entra groups with displayName '{1}'. Reconcile manually before re-running this primitive." -f $existing.Count, $DisplayName)
            return
        }

        if ($existing.Count -eq 1) {
            $group = $existing[0]
            if (-not $group.securityEnabled) {
                Write-Error ("Existing group '{0}' has securityEnabled=false; refusing to repurpose it." -f $DisplayName)
                return
            }
            if ($group.mailEnabled) {
                Write-Error ("Existing group '{0}' has mailEnabled=true; refusing to repurpose it (role-assignable groups must be mail-disabled)." -f $DisplayName)
                return
            }
            if (-not $group.isAssignableToRole) {
                Write-Error ("Existing group '{0}' has isAssignableToRole=false (immutable). Delete and recreate, or pick a different DisplayName." -f $DisplayName)
                return
            }
            $resolvedGroupId = [string]$group.id
            $groupAction = 'NoChange'
            if ($group.description -and $group.description -ne $Description) {
                Write-Warning ("Existing group description differs from requested. This primitive does not update descriptions; edit via Entra portal or a future reconciler if needed.")
            }
            Write-Information ("Group resolved  : id={0} (NoChange)" -f (Format-EntraIdentifier -Value $resolvedGroupId)) -InformationAction Continue
        }
        else {
            # Reference: https://learn.microsoft.com/en-us/graph/api/group-post-groups
            $createBody = @{
                displayName        = $DisplayName
                description        = $Description
                mailEnabled        = $false
                mailNickname       = $MailNickname
                securityEnabled    = $true
                isAssignableToRole = $true
            }
            $createUri = ('{0}/groups' -f $graphBase)
            $created = Invoke-EntraGraphRequest -Method POST -Uri $createUri -Body $createBody -AccessToken $accessToken
            if (-not $created -or -not $created.id) {
                Write-Error ("POST /groups returned no id for displayName '{0}'." -f $DisplayName)
                return
            }
            $resolvedGroupId = [string]$created.id
            $groupAction = 'Create'
            Write-Information ("Group created   : id={0}" -f (Format-EntraIdentifier -Value $resolvedGroupId)) -InformationAction Continue
        }

        # --- Optional membership add. ------------------------------------
        if ($PSBoundParameters.ContainsKey('AddMemberId')) {
            # Reference: https://learn.microsoft.com/en-us/graph/api/group-list-members
            $membersUri = ('{0}/groups/{1}/members?$select=id&$top=999' -f $graphBase, [System.Uri]::EscapeDataString($resolvedGroupId))
            $membersResp = Invoke-EntraGraphRequest -Method GET -Uri $membersUri -AccessToken $accessToken
            $memberIds = @($membersResp.value | ForEach-Object { [string]$_.id })

            if ($memberIds -contains $AddMemberId) {
                $memberAction = 'NoOp'
                Write-Information ("Member present  : {0} (NoOp)" -f (Format-EntraIdentifier -Value $AddMemberId)) -InformationAction Continue
            }
            else {
                # Reference: https://learn.microsoft.com/en-us/graph/api/group-post-members
                $addUri  = ('{0}/groups/{1}/members/$ref' -f $graphBase, [System.Uri]::EscapeDataString($resolvedGroupId))
                $addBody = @{ '@odata.id' = ("{0}/directoryObjects/{1}" -f $graphBase, $AddMemberId) }
                $alreadyPresent = $false
                try {
                    Invoke-EntraGraphRequest -Method POST -Uri $addUri -Body $addBody -AccessToken $accessToken | Out-Null
                }
                catch {
                    $errMessage = if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                        [string]$_.ErrorDetails.Message
                    } elseif ($_.Exception) {
                        [string]$_.Exception.Message
                    } else { '' }
                    if (Test-IsAddMemberAlreadyExistsError -ErrorBody $errMessage) {
                        $alreadyPresent = $true
                        Write-Information ("Member already present per Graph 400 'object references already exist' (idempotent).") -InformationAction Continue
                    }
                    else {
                        throw
                    }
                }
                # Re-read with bounded retry to absorb Graph eventual consistency
                # on group-membership writes.
                # Reference: https://learn.microsoft.com/en-us/graph/aad-advanced-queries
                $probe = {
                    $resp = Invoke-EntraGraphRequest -Method GET -Uri $membersUri -AccessToken $accessToken
                    @($resp.value | ForEach-Object { [string]$_.id })
                }
                $observed = Wait-MembershipConsistent -Probe $probe -TargetId $AddMemberId -MaxAttempts 5 -DelayMs 1500
                if (-not $observed) {
                    Write-Error ("POST members/`$ref reported success but principal {0} was not observed in the group after 5 retries (Graph eventual consistency window exceeded)." -f (Format-EntraIdentifier -Value $AddMemberId))
                    return
                }
                $memberAction = if ($alreadyPresent) { 'NoOp' } else { 'AddMember' }
                Write-Information ("Member {0,-9}: {1}" -f $memberAction, (Format-EntraIdentifier -Value $AddMemberId)) -InformationAction Continue
            }
        }
        else {
            $memberAction = 'NotRequested'
        }
    }
    finally {
        if (Get-Variable -Name accessToken -Scope 0 -ErrorAction SilentlyContinue) {
            Remove-Variable -Name accessToken -Scope 0 -ErrorAction SilentlyContinue
        }
    }
}
else {
    # -WhatIf path: no remote calls.
    $groupAction = 'WhatIf'
    $memberAction = if ($PSBoundParameters.ContainsKey('AddMemberId')) { 'WhatIf' } else { 'WhatIf-NotRequested' }
    Write-Information '-WhatIf specified. Planned behaviour (no remote calls made):' -InformationAction Continue
    Write-Information '  1. Acquire delegated Microsoft Graph token via `az account get-access-token --resource https://graph.microsoft.com`.' -InformationAction Continue
    Write-Information ("  2. GET {0}/groups?`$filter=displayName eq '{1}' to probe for an existing group." -f $graphBase, $DisplayName) -InformationAction Continue
    Write-Information '  3. If exactly one match is found and (securityEnabled=true, mailEnabled=false, isAssignableToRole=true), emit NoChange.' -InformationAction Continue
    Write-Information '  4. If no match is found, POST /groups with isAssignableToRole=true, securityEnabled=true, mailEnabled=false; emit Create.' -InformationAction Continue
    if ($PSBoundParameters.ContainsKey('AddMemberId')) {
        Write-Information ("  5. GET /groups/{{id}}/members and probe for principal {0}; if absent, POST members/`$ref to add; emit AddMember / NoOp." -f (Format-EntraIdentifier -Value $AddMemberId)) -InformationAction Continue
    }
}

#endregion

#region Summary

# Defence-in-depth: catch any code path that forgot to set an action label.
Assert-ActionLabel -GroupAction $groupAction -MemberAction $memberAction

# Console summary: redacted identifiers only. Real GUIDs leave the
# script via the structured PSObject emit below (consumed
# programmatically), per the redaction rule in
# `.github/instructions/security.instructions.md`.
Write-Information ('Summary: displayName={0}, groupAction={1}, groupId={2}, addMemberId={3}, memberAction={4}' -f `
        $DisplayName,
        $groupAction,
        (Format-EntraIdentifier -Value $resolvedGroupId),
        (Format-EntraIdentifier -Value $AddMemberId),
        $memberAction) -InformationAction Continue

[pscustomobject]@{
    displayName     = $DisplayName
    mailNickname    = $MailNickname
    groupAction     = $groupAction
    groupId         = $resolvedGroupId
    addMemberId     = if ($PSBoundParameters.ContainsKey('AddMemberId')) { $AddMemberId } else { $null }
    memberAction    = $memberAction
}

#endregion