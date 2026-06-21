<#
.SYNOPSIS
    Verifies the Set-Label cmdlet parameter shape for client-side auto-application
    conditions against the contoso-lab Microsoft Purview tenant.

.DESCRIPTION
    One-off verification helper to unblock acceptance criterion #1 on issue #212
    (Deploy-Labels.ps1 autoApplicationOf translation). Microsoft Learn does not
    document the exact Set-Label parameter that accepts client-side Recommend /
    Automatic conditions as of 2026-05-13, so the cmdlet help in the live tenant
    is the only reliable source.

    The script:
      1. Connects to the Security & Compliance PowerShell endpoint.
      2. Dumps the full Set-Label parameter surface and filters to likely
         condition-bearing parameter names.
      3. Lists existing tenant labels and prints the Format-List * shape of any
         label that already carries Conditions / Settings / AdvancedSettings.
      4. Creates a throwaway test sublabel and attempts each candidate parameter
         shape in turn (AdvancedSettings, LocaleSettings, Conditions) until one
         round-trips successfully.
      5. Captures the Get-Label output for the test sublabel so
         ConvertTo-TenantLabelHash knows what to re-shape during reconciliation.
      6. Removes the test sublabel and disconnects.

    Outputs are written to .\verify-set-label-output\ (gitignored). Paste them
    into issue #212 after redacting tenant / object GUIDs to the zero GUID per
    the identifier rule in .github/copilot-instructions.md.

    References:
      Connect to S&C PowerShell:
        https://learn.microsoft.com/en-us/powershell/exchange/connect-to-scc-powershell
      Set-Label cmdlet (Learn-silent on auto-apply parameter):
        https://learn.microsoft.com/en-us/powershell/module/exchange/set-label
      Get-Label cmdlet:
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-label

.PARAMETER UserPrincipalName
    Lab-owner UPN with Compliance Administrator or Compliance Data Administrator
    role assigned in Microsoft Entra. Example: user@contoso.onmicrosoft.com.

.PARAMETER ParentLabelIdentity
    Optional. Identity (GUID or DisplayName) of an existing top-level label under
    which the test sublabel will be created. Defaults to the first top-level
    label returned by Get-Label.

.PARAMETER TestSitGuid
    Sensitive Information Type GUID to reference in the test condition. Defaults
    to the Microsoft built-in Credit Card Number SIT
    (50842eb7-edc8-4019-85dd-5a5c1f2bb085).

.PARAMETER OutputDirectory
    Directory for captured artefacts. Defaults to .\verify-set-label-output.

.PARAMETER SkipCleanup
    Switch. If set, leaves the test sublabel in place for further inspection.
    Default is to remove it.

.EXAMPLE
    .\scripts\Verify-SetLabelAutoApply.ps1 -UserPrincipalName admin@contoso.onmicrosoft.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$UserPrincipalName,

    [Parameter(Mandatory = $false)]
    [string]$ParentLabelIdentity,

    [Parameter(Mandatory = $false)]
    [string]$TestSitGuid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085',

    [Parameter(Mandatory = $false)]
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\verify-set-label-output'),

    [Parameter(Mandatory = $false)]
    [switch]$SkipCleanup
)

$ErrorActionPreference = 'Stop'

# Resolve and prepare output directory
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
if (-not (Test-Path $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}
Write-Information "Output directory: $OutputDirectory"

# --- Step 1: Module + connection ----------------------------------------------
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Write-Information 'Installing ExchangeOnlineManagement module (CurrentUser scope)...'
    Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber
}
Import-Module ExchangeOnlineManagement -ErrorAction Stop

Write-Information "Connecting to Security & Compliance PowerShell as $UserPrincipalName..."
# Reference: https://learn.microsoft.com/en-us/powershell/exchange/connect-to-scc-powershell
Connect-IPPSSession -UserPrincipalName $UserPrincipalName -ShowBanner:$false

try {
    # --- Step 2: Parameter surface ------------------------------------------------
    $paramFile = Join-Path $OutputDirectory '01-set-label-parameters.txt'
    Write-Information "`nCapturing Set-Label parameter surface -> $paramFile"
    Get-Help Set-Label -Full | Out-File -FilePath $paramFile -Encoding utf8

    $candidates = (Get-Command Set-Label).Parameters.Keys |
        Where-Object { $_ -match 'Auto|Apply|Condition|Sensitive|Advanced|LocaleSettings' } |
        Sort-Object
    Write-Information "`nCandidate condition-bearing parameters on Set-Label:"
    $candidates | ForEach-Object { Write-Information "  - $_" }
    $candidates | Out-File -FilePath (Join-Path $OutputDirectory '02-candidate-parameters.txt') -Encoding utf8

    # --- Step 3: Inspect existing labels with conditions --------------------------
    Write-Information "`nScanning existing labels for non-empty Conditions / Settings / AdvancedSettings..."
    $allLabels = Get-Label
    $existingShapeFile = Join-Path $OutputDirectory '03-existing-labels-with-conditions.txt'
    "Total labels in tenant: $($allLabels.Count)" | Out-File -FilePath $existingShapeFile -Encoding utf8
    $withConditions = $allLabels | Where-Object {
        ($_.Conditions -and $_.Conditions.Count -gt 0) -or
        ($_.Settings -and $_.Settings.Count -gt 0) -or
        ($_.AdvancedSettings -and $_.AdvancedSettings.Count -gt 0)
    }
    if ($withConditions) {
        Write-Information "Found $($withConditions.Count) label(s) with conditions/settings. Capturing shape."
        foreach ($lbl in $withConditions) {
            "`n=== Label: $($lbl.DisplayName) (Guid: $($lbl.Guid)) ===" | Out-File -FilePath $existingShapeFile -Encoding utf8 -Append
            Get-Label -Identity $lbl.Identity | Format-List * | Out-File -FilePath $existingShapeFile -Encoding utf8 -Append
        }
    }
    else {
        Write-Information 'No tenant labels currently carry conditions/settings - shape must be inferred from the test sublabel.'
        'No tenant labels currently carry conditions/settings.' | Out-File -FilePath $existingShapeFile -Encoding utf8 -Append
    }

    # --- Step 4: Create test label -----------------------------------------------
    # Modern label scheme requires sub-labels to live under a label *group*. If
    # -ParentLabelIdentity is supplied we honour it; otherwise we create a
    # throwaway TOP-LEVEL label so the auto-apply parameter shape can be probed
    # without depending on a group existing.
    $testName = "TEST-AutoApply-$(Get-Date -Format 'yyyyMMddHHmmss')"
    if ($ParentLabelIdentity) {
        Write-Information "`nCreating test sublabel: $testName (parent: $ParentLabelIdentity)"
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-label
        New-Label -DisplayName $testName `
                  -Name $testName `
                  -Tooltip 'Throwaway sublabel for autoApplicationOf verification - safe to delete' `
                  -ParentId $ParentLabelIdentity | Out-Null
    }
    else {
        Write-Information "`nCreating throwaway top-level test label: $testName"
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-label
        New-Label -DisplayName $testName `
                  -Name $testName `
                  -Tooltip 'Throwaway label for autoApplicationOf verification - safe to delete' | Out-Null
    }

    # --- Step 5: Try each candidate parameter shape ------------------------------
    $variants = @(
        @{
            Name = 'AdvancedSettings (DefaultSensitiveTypes JSON string)'
            Splat = @{
                Identity         = $testName
                AdvancedSettings = @{
                    DefaultSensitiveTypes = "[{`"sitId`":`"$TestSitGuid`",`"minCount`":1,`"minConfidence`":75}]"
                }
            }
        },
        @{
            Name = 'LocaleSettings JSON blob'
            Splat = @{
                Identity       = $testName
                LocaleSettings = '[{"LocaleKey":"Conditions","Settings":[{"Key":"Recommend","Value":"{\"sitId\":\"' + $TestSitGuid + '\",\"minCount\":1,\"minConfidence\":75}"}]}]'
            }
        },
        @{
            Name = 'AdvancedSettings (autolabel hashtable)'
            Splat = @{
                Identity         = $testName
                AdvancedSettings = @{
                    autoApplyLabelClassifications = "[{`"sitId`":`"$TestSitGuid`",`"minCount`":1,`"minConfidence`":75}]"
                }
            }
        },
        @{
            Name = 'Conditions parameter (direct JSON)'
            Splat = @{
                Identity   = $testName
                Conditions = "{`"And`":[{`"Settings`":[{`"Key`":`"ContentContainsSensitiveInformation`",`"Value`":`"[{\`"groups\`":[{\`"sensitivetypes\`":[{\`"id\`":\`"$TestSitGuid\`",\`"mincount\`":1,\`"confidencelevel\`":\`"75\`"}]}]}]`"}]}]}"
            }
        }
    )

    $successVariant = $null
    foreach ($v in $variants) {
        Write-Information "`nAttempting variant: $($v.Name)"
        try {
            $splat = $v.Splat
            Set-Label @splat -ErrorAction Stop
            Write-Information "  SUCCESS."
            $successVariant = $v
            break
        }
        catch {
            Write-Information "  FAILED: $($_.Exception.Message)"
        }
    }

    if (-not $successVariant) {
        Write-Warning 'No candidate variant succeeded. Inspect 01-set-label-parameters.txt for the full parameter set and try a manual Set-Label call.'
    }
    else {
        $variantFile = Join-Path $OutputDirectory '04-successful-variant.txt'
        "Successful variant: $($successVariant.Name)" | Out-File -FilePath $variantFile -Encoding utf8
        $successVariant.Splat | ConvertTo-Json -Depth 10 | Out-File -FilePath $variantFile -Encoding utf8 -Append
    }

    # --- Step 6: Capture round-trip shape ----------------------------------------
    $shapeFile = Join-Path $OutputDirectory '05-test-sublabel-shape.txt'
    Write-Information "`nCapturing Get-Label round-trip shape -> $shapeFile"
    Get-Label -Identity $testName | Format-List * | Out-File -FilePath $shapeFile -Encoding utf8

    Write-Information "`nVerification complete. Artefacts in: $OutputDirectory"
    Write-Information 'Paste these (redacted) into issue #212:'
    Get-ChildItem $OutputDirectory | ForEach-Object { Write-Information "  - $($_.Name)" }
}
finally {
    # --- Step 7: Cleanup ---------------------------------------------------------
    if (-not $SkipCleanup -and $testName) {
        try {
            Write-Information "`nRemoving test sublabel: $testName"
            Remove-Label -Identity $testName -Confirm:$false -ErrorAction Stop
        }
        catch {
            Write-Warning "Cleanup failed for $testName. Remove manually: Remove-Label -Identity '$testName' -Confirm:`$false"
            Write-Warning $_.Exception.Message
        }
    }
    elseif ($SkipCleanup) {
        Write-Information "`n-SkipCleanup set. Test sublabel '$testName' left in place."
    }

    Write-Information 'Disconnecting from Security & Compliance PowerShell...'
    Disconnect-ExchangeOnline -Confirm:$false
}
