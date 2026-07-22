#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Unit tests for scripts/Deploy-SITRulePackages.ps1 -- the custom SIT
    rule-package reconciler (docs/adr/0061-custom-sit-rule-package-shape.md).

.DESCRIPTION
    The script's top-level body calls `az`, the token helper, and IPPS cmdlets,
    so it cannot be dot-sourced. Following the repo's AST-extraction pattern, the
    pure helper functions are pulled in and exercised directly, plus source-level
    regression guards over the main body for the load-bearing contract points:

      * ConvertTo-CanonicalRulePackXml IGNORES the service-stamped `lastModifiedTime`
        (ADR 0061 decision 4) -- the single most important comparator property, since
        the service rewrites those timestamps on every write and a byte-compare would
        report permanent false drift.
      * Test-ReservedRulePack fires for all four Microsoft-managed classes (built-in,
        fingerprint, EDM, SCCManaged) -- the ADR 0061 decision 3 denylist.
      * XML id / version / entity parsing via local-name() XPath (namespace-agnostic).
      * The main body wires guard 1, guard 2, Write-PruneFailure, the ADR 0052 gate,
        and the Version-bump `Blocked` rule.

    Reference: docs/adr/0061-custom-sit-rule-package-shape.md
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-SITRulePackages.ps1'
    if (-not (Test-Path $script:ScriptPath)) { throw "Could not locate Deploy-SITRulePackages.ps1 at: $script:ScriptPath" }
    $script:SourceText = Get-Content -Raw -LiteralPath $script:ScriptPath

    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$tokens, [ref]$errors)
    $allFns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    foreach ($target in @('ConvertFrom-RulePackXmlContent','Get-RulePackIdFromXml','Get-RulePackVersionFromXml','Get-RulePackEntitiesFromXml','ConvertTo-CanonicalRulePackXml','Test-ReservedRulePack','Get-RulePackIdFromIdentityDn','ConvertTo-SafeFileName')) {
        $fn = $allFns | Where-Object { $_.Name -eq $target } | Select-Object -First 1
        if (-not $fn) { throw "Function '$target' not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fn.Extent.Text))
    }

    # Reserved-constant script variables the helpers reference. Mirror the values
    # the script sets in its #region Reserved-pack constants.
    $script:MicrosoftBuiltinRuleCollectionName = 'Microsoft Rule Package'
    $script:SccManagedRulePackId             = '5da58d7a-25f1-4205-93d0-beb10054c503'
    $script:SccManagedRuleCollectionName     = 'Microsoft.SCCManaged.CustomRulePack'
    $script:EdmNamespace                     = 'http://schemas.microsoft.com/office/2018/edm'

    function Get-TestByteArray { param([string]$Xml) return [System.Text.Encoding]::UTF8.GetBytes($Xml) }

    $script:SampleXml = @'
<?xml version="1.0" encoding="utf-8"?>
<RulePackage xmlns="http://schemas.microsoft.com/office/2011/mce">
  <RulePack id="00000000-0000-0000-0000-000000000061">
    <Version major="1" minor="2" build="0" revision="0" />
    <Publisher id="00000000-0000-0000-0000-000000000060" />
    <Details defaultLangCode="en-us"><LocalizedDetails langcode="en-us">
      <PublisherName>Example</PublisherName><Name>Example.Pack</Name><Description>d</Description>
    </LocalizedDetails></Details>
  </RulePack>
  <Rules>
    <Entity id="00000000-0000-0000-0000-000000000062" patternsProximity="300" recommendedConfidence="85" lastModifiedTime="2025-12-31T18:59:49.6299569Z">
      <Pattern confidenceLevel="85"><IdMatch idRef="Regex_x" /></Pattern>
    </Entity>
    <Regex id="Regex_x">EMP-\d{4}</Regex>
    <LocalizedStrings><Resource idRef="00000000-0000-0000-0000-000000000062">
      <Name default="true" langcode="en-us">Example SIT</Name><Description default="true" langcode="en-us">d</Description>
    </Resource></LocalizedStrings>
  </Rules>
</RulePackage>
'@
}

Describe 'ConvertFrom-RulePackXmlContent + XML parsing helpers' {
    It 'parses the RulePack id (lower-cased) via local-name() XPath' {
        $doc = ConvertFrom-RulePackXmlContent -Bytes (Get-TestByteArray $script:SampleXml)
        Get-RulePackIdFromXml -Doc $doc | Should -Be '00000000-0000-0000-0000-000000000061'
    }
    It 'parses the PACK version from RulePack/Version (not a Rules/Version wrapper)' {
        $doc = ConvertFrom-RulePackXmlContent -Bytes (Get-TestByteArray $script:SampleXml)
        [string](Get-RulePackVersionFromXml -Doc $doc) | Should -Be '1.2.0.0'
    }
    It 'extracts entities with their localized names' {
        $doc = ConvertFrom-RulePackXmlContent -Bytes (Get-TestByteArray $script:SampleXml)
        $ents = Get-RulePackEntitiesFromXml -Doc $doc
        $ents.Count | Should -Be 1
        $ents[0].id | Should -Be '00000000-0000-0000-0000-000000000062'
        $ents[0].name | Should -Be 'Example SIT'
    }
    It 'honours the encoding declaration (UTF-16 input round-trips)' {
        $bytes = [System.Text.Encoding]::Unicode.GetBytes(($script:SampleXml -replace 'utf-8', 'utf-16'))
        $doc = ConvertFrom-RulePackXmlContent -Bytes $bytes
        Get-RulePackIdFromXml -Doc $doc | Should -Be '00000000-0000-0000-0000-000000000061'
    }
}

Describe 'ConvertTo-CanonicalRulePackXml -- timestamp-agnostic comparator (ADR 0061 decision 4)' {
    It 'produces IDENTICAL canonical form for two packs differing ONLY in lastModifiedTime' {
        $a = ConvertFrom-RulePackXmlContent -Bytes (Get-TestByteArray $script:SampleXml)
        $b = ConvertFrom-RulePackXmlContent -Bytes (Get-TestByteArray ($script:SampleXml -replace '2025-12-31T18:59:49.6299569Z', '2026-07-22T10:00:00.0000000Z'))
        (ConvertTo-CanonicalRulePackXml -Doc $a) | Should -Be (ConvertTo-CanonicalRulePackXml -Doc $b)
    }
    It 'produces DIFFERENT canonical form when the regex actually changes' {
        $a = ConvertFrom-RulePackXmlContent -Bytes (Get-TestByteArray $script:SampleXml)
        $b = ConvertFrom-RulePackXmlContent -Bytes (Get-TestByteArray ($script:SampleXml -replace 'EMP-\\d\{4\}', 'STAFF-\d{6}'))
        (ConvertTo-CanonicalRulePackXml -Doc $a) | Should -Not -Be (ConvertTo-CanonicalRulePackXml -Doc $b)
    }
    It 'is insensitive to attribute ORDER (sorts attributes)' {
        $reordered = $script:SampleXml -replace 'patternsProximity="300" recommendedConfidence="85"', 'recommendedConfidence="85" patternsProximity="300"'
        $a = ConvertFrom-RulePackXmlContent -Bytes (Get-TestByteArray $script:SampleXml)
        $b = ConvertFrom-RulePackXmlContent -Bytes (Get-TestByteArray $reordered)
        (ConvertTo-CanonicalRulePackXml -Doc $a) | Should -Be (ConvertTo-CanonicalRulePackXml -Doc $b)
    }
    It 'is insensitive to insignificant whitespace' {
        $compact = ($script:SampleXml -replace '>\s+<', '><')
        $a = ConvertFrom-RulePackXmlContent -Bytes (Get-TestByteArray $script:SampleXml)
        $b = ConvertFrom-RulePackXmlContent -Bytes (Get-TestByteArray $compact)
        (ConvertTo-CanonicalRulePackXml -Doc $a) | Should -Be (ConvertTo-CanonicalRulePackXml -Doc $b)
    }
    It 'treats an omitted Entity relaxProximity attribute as equal to an explicit "false" (#48 Phase 3 live finding)' {
        # The service stamps relaxProximity="false" onto every <Entity> at write time when the
        # authored XML omits it -- undocumented on Microsoft Learn, discovered only by the live
        # round-trip. Without this default-fill, an untouched pack's export never reports NoChange.
        $withoutAttr = $script:SampleXml
        $withAttrFalse = $script:SampleXml -replace 'patternsProximity="300" recommendedConfidence="85"', 'patternsProximity="300" recommendedConfidence="85" relaxProximity="false"'
        $a = ConvertFrom-RulePackXmlContent -Bytes (Get-TestByteArray $withoutAttr)
        $b = ConvertFrom-RulePackXmlContent -Bytes (Get-TestByteArray $withAttrFalse)
        (ConvertTo-CanonicalRulePackXml -Doc $a) | Should -Be (ConvertTo-CanonicalRulePackXml -Doc $b)
    }
    It 'still treats an explicit Entity relaxProximity="true" as REAL drift, not default-filled away' {
        $default = $script:SampleXml
        $relaxed = $script:SampleXml -replace 'patternsProximity="300" recommendedConfidence="85"', 'patternsProximity="300" recommendedConfidence="85" relaxProximity="true"'
        $a = ConvertFrom-RulePackXmlContent -Bytes (Get-TestByteArray $default)
        $b = ConvertFrom-RulePackXmlContent -Bytes (Get-TestByteArray $relaxed)
        (ConvertTo-CanonicalRulePackXml -Doc $a) | Should -Not -Be (ConvertTo-CanonicalRulePackXml -Doc $b)
    }
}

Describe 'Test-ReservedRulePack -- the ADR 0061 decision 3 denylist' {
    It 'blocks the Microsoft built-in rule package (by RuleCollectionName)' {
        $r = ''
        Test-ReservedRulePack -RulePackId '11111111-1111-1111-1111-111111111111' -RuleCollectionName 'Microsoft Rule Package' -IsFingerprint $false -IsEdm $false -ReasonRef ([ref]$r) | Should -BeTrue
        $r | Should -Match 'built-in'
    }
    It 'blocks a fingerprint pack (by flag)' {
        $r = ''
        Test-ReservedRulePack -RulePackId '22222222-2222-2222-2222-222222222222' -RuleCollectionName 'Document Fingerprint Rule Package' -IsFingerprint $true -IsEdm $false -ReasonRef ([ref]$r) | Should -BeTrue
        $r | Should -Match 'fingerprint'
    }
    It 'blocks an EDM pack (by flag)' {
        $r = ''
        Test-ReservedRulePack -RulePackId '33333333-3333-3333-3333-333333333333' -RuleCollectionName 'Some EDM' -IsFingerprint $false -IsEdm $true -ReasonRef ([ref]$r) | Should -BeTrue
        $r | Should -Match 'EDM'
    }
    It 'blocks Microsoft.SCCManaged.CustomRulePack by its fixed GUID (case-insensitive)' {
        $r = ''
        Test-ReservedRulePack -RulePackId '5DA58D7A-25F1-4205-93D0-BEB10054C503' -RuleCollectionName 'anything' -IsFingerprint $false -IsEdm $false -ReasonRef ([ref]$r) | Should -BeTrue
        $r | Should -Match 'SCCManaged'
    }
    It 'blocks Microsoft.SCCManaged.CustomRulePack by name' {
        $r = ''
        Test-ReservedRulePack -RulePackId '44444444-4444-4444-4444-444444444444' -RuleCollectionName 'Microsoft.SCCManaged.CustomRulePack' -IsFingerprint $false -IsEdm $false -ReasonRef ([ref]$r) | Should -BeTrue
    }
    It 'does NOT block a genuine repo-authored pack' {
        $r = ''
        Test-ReservedRulePack -RulePackId '00000000-0000-0000-0000-000000000061' -RuleCollectionName 'Contoso.Repo.CustomRulePack' -IsFingerprint $false -IsEdm $false -ReasonRef ([ref]$r) | Should -BeFalse
    }
}

Describe 'Get-RulePackIdFromIdentityDn' {
    It 'parses the GUID from the Identity DN tail (lower-cased)' {
        Get-RulePackIdFromIdentityDn -IdentityDn 'FFO.extest.microsoft.com/.../Configuration/5DA58D7A-25F1-4205-93D0-BEB10054C503' |
            Should -Be '5da58d7a-25f1-4205-93d0-beb10054c503'
    }
    It 'returns $null for an empty Identity rather than throwing (#48 Phase 3 live finding)' {
        # Get-DlpSensitiveInformationTypeRulePackage returns an EMPTY Identity, live, for the
        # built-in "Microsoft Rule Package" specifically -- it has no per-tenant Configuration
        # object. That pack is still correctly classified as reserved via its RuleCollectionName
        # (Test-ReservedRulePack checks that first and never depends on RulePackId), so this must
        # degrade gracefully rather than crash mandatory-parameter binding on every plan run.
        Get-RulePackIdFromIdentityDn -IdentityDn '' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-SafeFileName' {
    It 'strips unsafe characters and lower-cases' {
        ConvertTo-SafeFileName -Name 'Microsoft.SCCManaged.CustomRulePack' | Should -Be 'microsoft.sccmanaged.customrulepack'
    }
    It 'falls back for an all-unsafe name' {
        ConvertTo-SafeFileName -Name '///' | Should -Be 'rule-package'
    }
}

Describe 'Main body -- source-level contract guards' {
    It 'wires guard 1 (Assert-PruneDesiredSetNotEmpty) before tenant contact' {
        $script:SourceText | Should -Match 'Assert-PruneDesiredSetNotEmpty'
    }
    It 'wires guard 2 (Assert-PruneRatioWithinThreshold) keyed on the orphan/managed counts' {
        $script:SourceText | Should -Match 'Assert-PruneRatioWithinThreshold'
    }
    It 'reports prune failures via Write-PruneFailure and throws an aggregate' {
        $script:SourceText | Should -Match 'Write-PruneFailure'
        $script:SourceText | Should -Match 'pruneFailures'
    }
    It 'gates destructive operations via the ADR 0052 ConfirmGate' {
        $script:SourceText | Should -Match 'Assert-DestructiveOperationConfirmed'
    }
    It 'blocks a content change whose Version was not bumped (ADR 0061 decision 5)' {
        $script:SourceText | Should -Match 'not greater than the tenant'
    }
    It 'blocks a manifest rulePackId that mismatches the XML' {
        $script:SourceText | Should -Match "Manifest rulePackId"
    }
    It 'enforces the 10-package tenant limit' {
        $script:SourceText | Should -Match 'MaxRulePackagesPerTenant'
    }
    It 'uses the RulePackage cmdlet family, not the fingerprint-only triple' {
        $script:SourceText | Should -Match 'New-DlpSensitiveInformationTypeRulePackage'
        $script:SourceText | Should -Match 'Set-DlpSensitiveInformationTypeRulePackage'
        $script:SourceText | Should -Match 'Remove-DlpSensitiveInformationTypeRulePackage'
    }
}

Describe 'Worked example -- self-consistent and well-formed (the file Phase 3 copies from)' {
    # Nothing else in the repo PARSES the example XML: yamllint is YAML-only, the
    # identifier scan reads text for GUIDs, and ScriptAnalyzer never touches .xml.
    # A malformed example (e.g. a `--` inside an XML comment, which XML forbids)
    # would ship green and only fail when the reconciler tries to load it. This
    # test loads the example the way the reconciler's own load phase does, so the
    # file Phase 3 starts from is proven parseable and internally consistent.
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        Import-Module 'powershell-yaml' -ErrorAction Stop
        $script:ExDir = Join-Path $script:RepoRoot 'examples' 'data-plane' 'classifications'
        $script:ExManifest = Get-Content -Raw -LiteralPath (Join-Path $script:ExDir 'sit-rule-packages.yaml') | ConvertFrom-Yaml
    }

    It 'the example manifest declares at least one rule package' {
        @($script:ExManifest.rulePackages).Count | Should -BeGreaterThan 0
    }

    It 'every example rule-package XML parses (no malformed XML, e.g. `` -- `` in a comment)' {
        foreach ($entry in $script:ExManifest.rulePackages) {
            $xmlPath = Join-Path $script:ExDir $entry.file
            Test-Path -LiteralPath $xmlPath | Should -BeTrue -Because "manifest entry '$($entry.name)' references '$($entry.file)'"
            $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $xmlPath).Path)
            { ConvertFrom-RulePackXmlContent -Bytes $bytes } | Should -Not -Throw -Because "the example XML must be well-formed"
        }
    }

    It 'manifest rulePackId / version / entity ids MATCH the XML (would Block otherwise)' {
        foreach ($entry in $script:ExManifest.rulePackages) {
            $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath (Join-Path $script:ExDir $entry.file)).Path)
            $doc = ConvertFrom-RulePackXmlContent -Bytes $bytes
            (Get-RulePackIdFromXml -Doc $doc) | Should -Be ([string]$entry.rulePackId).ToLowerInvariant()
            [string](Get-RulePackVersionFromXml -Doc $doc) | Should -Be ([string]$entry.version)
            $xmlEntityIds = @((Get-RulePackEntitiesFromXml -Doc $doc) | ForEach-Object { $_.id }) | Sort-Object
            $manifestSitIds = @($entry.sits | ForEach-Object { ([string]$_.id).ToLowerInvariant() }) | Sort-Object
            ($xmlEntityIds -join ',') | Should -Be ($manifestSitIds -join ',')
        }
    }

    It 'all example GUIDs are in the reserved synthetic namespace (ADR 0061 decision 2, ADR 0055-clean)' {
        # 00000000-0000-0000-0000-<12 hex> -- the shape the identifier scan acquits.
        $synthetic = '^00000000-0000-0000-0000-[0-9a-f]{12}$'
        foreach ($entry in $script:ExManifest.rulePackages) {
            ([string]$entry.rulePackId).ToLowerInvariant() | Should -Match $synthetic
            foreach ($s in $entry.sits) { ([string]$s.id).ToLowerInvariant() | Should -Match $synthetic }
            $doc = ConvertFrom-RulePackXmlContent -Bytes ([System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath (Join-Path $script:ExDir $entry.file)).Path))
            $pub = $doc.SelectSingleNode("//*[local-name()='Publisher']").Attributes['id'].Value
            $pub.ToLowerInvariant() | Should -Match $synthetic -Because 'the Publisher id must be synthetic, never a real tenant GUID'
        }
    }
}
