#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for the ADR 0052 destructive-operation confirmation
    gate: scripts/modules/ConfirmGate.psm1 and its three reference
    consumers.

.DESCRIPTION
    Locks in the fix for issue #85. The defect being regression-tested:

      Every Deploy-*.ps1 declared ConfirmImpact = 'Medium'. PowerShell only
      raises a ShouldProcess confirmation when ConfirmImpact >=
      $ConfirmPreference, and $ConfirmPreference defaults to 'High'. Because
      Medium < High, EVERY $PSCmdlet.ShouldProcess(...) call returned $true
      without ever prompting. The mandated delete-confirmation prompt was
      dead code.

    The fix is a change of METHOD, not merely of constant: the destructive
    branches are gated with ShouldContinue (which performs no
    ConfirmImpact / $ConfirmPreference comparison and therefore prompts
    unconditionally) rather than ShouldProcess. The most important test in
    this file is 'ignores $ConfirmPreference entirely' -- if that ever goes
    red, the defect is back.

    Pattern (matches tests/scripts/Deploy-FilePlan.Tests.ps1):

      1. Behaviour tests against the shared scripts/modules/ConfirmGate.psm1
         module directly, driving it with a stub $Cmdlet that records
         ShouldContinue calls. We do NOT dot-source the consumer scripts --
         that would execute their top-level code and try to
         Connect-IPPSSession against the live tenant.
      2. Source-text regex assertions on the three reference consumers
         (ConfirmImpact level, module import, gate invocation).
      3. Workflow-text assertions that every CI invocation of the two
         reconcilers with a ShouldProcess-gated write binds -Confirm:$false,
         so raising ConfirmImpact to 'High' cannot hang a job.

    Reference: https://pester.dev/docs/quick-start
    Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
    Reference: https://learn.microsoft.com/en-us/dotnet/api/system.management.automation.cmdlet.shouldcontinue
#>

BeforeAll {
    $script:RepoRoot = Join-Path $PSScriptRoot '..' '..'

    $script:ModulePath = Join-Path $script:RepoRoot 'scripts' 'modules' 'ConfirmGate.psm1'
    if (-not (Test-Path -LiteralPath $script:ModulePath)) {
        throw "Could not locate ConfirmGate.psm1 at: $script:ModulePath"
    }
    Import-Module $script:ModulePath -Force -ErrorAction Stop

    # Stub $PSCmdlet. Records every ShouldContinue call and returns a canned
    # answer, so the prompt-emission path is testable under a non-interactive
    # Pester run (a real PSCmdlet cannot raise a prompt there).
    #   -Answer      : what ShouldContinue returns.
    #   -SetYesToAll : simulate the operator choosing "Yes to All".
    #   -SetNoToAll  : simulate the operator choosing "No to All".
    function Get-StubCmdlet {
        param(
            [bool]$Answer = $true,
            [switch]$SetYesToAll,
            [switch]$SetNoToAll
        )
        $stub = [pscustomobject]@{
            Calls       = [System.Collections.Generic.List[object]]::new()
            Answer      = $Answer
            SetYesToAll = [bool]$SetYesToAll
            SetNoToAll  = [bool]$SetNoToAll
        }
        # Signature mirrors the four-argument overload:
        #   bool ShouldContinue(string query, string caption, ref bool yesToAll, ref bool noToAll)
        $stub | Add-Member -MemberType ScriptMethod -Name 'ShouldContinue' -Value {
            param($query, $caption, [ref]$yesToAll, [ref]$noToAll)
            $this.Calls.Add([pscustomobject]@{ Query = $query; Caption = $caption })
            if ($this.SetYesToAll) { $yesToAll.Value = $true }
            if ($this.SetNoToAll) { $noToAll.Value = $true }
            return $this.Answer
        }
        return $stub
    }

    # Default gate arguments: no suppressor set, so the gate prompts.
    function Get-GateArgTable {
        param(
            [Parameter(Mandatory)]$Stub,
            [Parameter(Mandatory)][ref]$YesToAll,
            [Parameter(Mandatory)][ref]$NoToAll
        )
        @{
            Cmdlet   = $Stub
            Caption  = 'Destructive operation (ADR 0052)'
            Query    = '-PruneMissing will DELETE 3 orphan object(s). This cannot be undone. Continue?'
            YesToAll = $YesToAll
            NoToAll  = $NoToAll
        }
    }
}

Describe 'ConfirmGate: ShouldContinue prompt emission (ADR 0052)' {

    It 'prompts via ShouldContinue when no suppressor is set' {
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $true
        $gateArgs = Get-GateArgTable -Stub $stub -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $result = Assert-DestructiveOperationConfirmed @gateArgs
        $result | Should -BeTrue
        $stub.Calls.Count | Should -Be 1
    }

    It 'returns $false when the operator declines' {
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $false
        $gateArgs = Get-GateArgTable -Stub $stub -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $result = Assert-DestructiveOperationConfirmed @gateArgs
        $result | Should -BeFalse
        $stub.Calls.Count | Should -Be 1
    }

    It 'passes the object names and count through to the operator in the query text' {
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $true
        $null = Assert-DestructiveOperationConfirmed -Cmdlet $stub -Caption 'Destructive operation (ADR 0052)' `
            -Query "-PruneMissing will DELETE 2 orphan sensitivity label(s) from the tenant: Alpha, Beta. This cannot be undone. Continue?" `
            -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $stub.Calls[0].Query | Should -Match 'Alpha, Beta'
        $stub.Calls[0].Query | Should -Match 'cannot be undone'
    }

    # THE regression test for issue #85. ShouldContinue must NOT consult
    # $ConfirmPreference. If this goes red, the Medium-vs-High defect is back.
    It 'ignores $ConfirmPreference entirely -- prompts even when $ConfirmPreference = None' {
        $ConfirmPreference = 'None'
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $true
        $gateArgs = Get-GateArgTable -Stub $stub -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $null = Assert-DestructiveOperationConfirmed @gateArgs
        $stub.Calls.Count | Should -Be 1
    }
}

Describe 'ConfirmGate: -Force suppression (ADR 0052)' {

    It '-Force returns $true WITHOUT prompting' {
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $false   # would decline if ever asked
        $gateArgs = Get-GateArgTable -Stub $stub -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $result = Assert-DestructiveOperationConfirmed @gateArgs -Force
        $result | Should -BeTrue
        $stub.Calls.Count | Should -Be 0
    }
}

Describe 'ConfirmGate: -WhatIf short-circuits BEFORE the prompt (ADR 0052)' {

    # -WhatIf must return $true so the caller still WALKS the destructive
    # branch and the per-write ShouldProcess calls inside it render their
    # "What if:" preview. Returning $false here would hide the very deletes
    # -WhatIf exists to preview.
    It '-WhatIf returns $true WITHOUT prompting (dry run never blocks on input)' {
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $false
        $gateArgs = Get-GateArgTable -Stub $stub -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $result = Assert-DestructiveOperationConfirmed @gateArgs -IsWhatIf
        $result | Should -BeTrue
        $stub.Calls.Count | Should -Be 0
    }

    It '-WhatIf takes precedence over -Force (neither prompts; both proceed)' {
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $false
        $gateArgs = Get-GateArgTable -Stub $stub -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $result = Assert-DestructiveOperationConfirmed @gateArgs -IsWhatIf -Force
        $result | Should -BeTrue
        $stub.Calls.Count | Should -Be 0
    }
}

Describe 'ConfirmGate: -Confirm:$false is the unattended CI path (ADR 0052)' {

    It '-Confirm:$false returns $true WITHOUT prompting (CI runs unattended)' {
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $false
        $gateArgs = Get-GateArgTable -Stub $stub -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $result = Assert-DestructiveOperationConfirmed @gateArgs -ConfirmBound $true -ConfirmValue $false
        $result | Should -BeTrue
        $stub.Calls.Count | Should -Be 0
    }

    It 'an explicit -Confirm:$true still prompts' {
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $true
        $gateArgs = Get-GateArgTable -Stub $stub -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $null = Assert-DestructiveOperationConfirmed @gateArgs -ConfirmBound $true -ConfirmValue $true
        $stub.Calls.Count | Should -Be 1
    }

    It 'an UNBOUND -Confirm still prompts (absence of -Confirm is not consent)' {
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $true
        $gateArgs = Get-GateArgTable -Stub $stub -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $null = Assert-DestructiveOperationConfirmed @gateArgs -ConfirmBound $false -ConfirmValue $false
        $stub.Calls.Count | Should -Be 1
    }
}

Describe 'ConfirmGate: one prompt per run, not one per object (ADR 0052)' {

    It 'honours a pre-set yesToAll without prompting again' {
        $yes = $true; $no = $false
        $stub = Get-StubCmdlet -Answer $false
        $gateArgs = Get-GateArgTable -Stub $stub -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $result = Assert-DestructiveOperationConfirmed @gateArgs
        $result | Should -BeTrue
        $stub.Calls.Count | Should -Be 0
    }

    It 'honours a pre-set noToAll without prompting again' {
        $yes = $false; $no = $true
        $stub = Get-StubCmdlet -Answer $true
        $gateArgs = Get-GateArgTable -Stub $stub -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $result = Assert-DestructiveOperationConfirmed @gateArgs
        $result | Should -BeFalse
        $stub.Calls.Count | Should -Be 0
    }

    It 'writes the operator''s "Yes to All" answer back through the [ref] pair' {
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $true -SetYesToAll
        $gateArgs = Get-GateArgTable -Stub $stub -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $null = Assert-DestructiveOperationConfirmed @gateArgs
        $yes | Should -BeTrue
    }

    # The shared-ref contract: a run that trips BOTH the repo-wins overwrite
    # gate AND the -PruneMissing delete gate prompts ONCE.
    It 'a second gate in the same run does not re-prompt after "Yes to All"' {
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $true -SetYesToAll

        $gate1 = Assert-DestructiveOperationConfirmed -Cmdlet $stub -Caption 'c' -Query 'overwrite gate' `
            -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $gate2 = Assert-DestructiveOperationConfirmed -Cmdlet $stub -Caption 'c' -Query 'prune gate' `
            -YesToAll ([ref]$yes) -NoToAll ([ref]$no)

        $gate1 | Should -BeTrue
        $gate2 | Should -BeTrue
        $stub.Calls.Count | Should -Be 1   # ONE prompt across BOTH gates
    }

    It 'a second gate in the same run does not re-prompt after "No to All"' {
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $false -SetNoToAll

        $gate1 = Assert-DestructiveOperationConfirmed -Cmdlet $stub -Caption 'c' -Query 'overwrite gate' `
            -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $gate2 = Assert-DestructiveOperationConfirmed -Cmdlet $stub -Caption 'c' -Query 'prune gate' `
            -YesToAll ([ref]$yes) -NoToAll ([ref]$no)

        $gate1 | Should -BeFalse
        $gate2 | Should -BeFalse
        $stub.Calls.Count | Should -Be 1
    }
}

Describe 'ConfirmGate: contract check on -Cmdlet' {

    It 'throws when -Cmdlet exposes no ShouldContinue method' {
        $yes = $false; $no = $false
        { Assert-DestructiveOperationConfirmed -Cmdlet ([pscustomobject]@{ Nope = $true }) `
                -Caption 'c' -Query 'q' -YesToAll ([ref]$yes) -NoToAll ([ref]$no) } |
            Should -Throw '*must expose a ShouldContinue method*'
    }
}

Describe 'ADR 0052 reference implementations: source-text contract' {

    BeforeDiscovery {
        $script:Reconcilers = @('Deploy-Labels.ps1', 'Deploy-FilePlan.ps1', 'Deploy-DLPPolicies.ps1')
    }

    Context 'on <_>' -ForEach @('Deploy-Labels.ps1', 'Deploy-FilePlan.ps1', 'Deploy-DLPPolicies.ps1') {

        BeforeAll {
            $script:Text = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts' $_) -Raw
        }

        # Whitespace-tolerant: the on-disk spelling has spaces around the '='.
        # A pattern without \s* returns zero matches and a false sense of safety.
        It 'declares ConfirmImpact = ''High''' {
            $script:Text | Should -Match "ConfirmImpact\s*=\s*'High'"
        }

        It 'does NOT declare ConfirmImpact = ''Medium'' (the issue #85 defect)' {
            $script:Text | Should -Not -Match "ConfirmImpact\s*=\s*'Medium'"
        }

        It 'imports the shared ConfirmGate.psm1 module (does not re-inline the gate)' {
            $script:Text | Should -Match 'ConfirmGate\.psm1'
        }

        It 'gates the -PruneMissing delete branch via Assert-DestructiveOperationConfirmed' {
            $script:Text | Should -Match 'PruneMissing will DELETE'
        }

        It 'gates the -DirectionPolicy repo-wins overwrite branch via Assert-DestructiveOperationConfirmed' {
            $script:Text | Should -Match 'repo-wins will OVERWRITE'
        }

        It 'aborts the run when the operator declines (does not partially apply)' {
            $script:Text | Should -Match 'Aborted by operator at the .* confirmation gate \(ADR 0052\)'
        }

        It 'uses ShouldContinue for the destructive gate, not ShouldProcess' {
            $script:Text | Should -Match 'Assert-DestructiveOperationConfirmed'
        }
    }
}

Describe 'ADR 0052: CI cannot hang -- every workflow invocation binds -Confirm:$false' {

    # This is the regression test for the hang that raising ConfirmImpact to
    # 'High' would otherwise have caused. Deploy-Labels.ps1 wraps its
    # -ExportCurrentState YAML write in $PSCmdlet.ShouldProcess(...), and two
    # workflows invoked that export path without -Confirm:$false. At 'High'
    # those steps would have prompted on a hosted runner and hung the job.
    Context 'in <_>' -ForEach @(
        'deploy-labels.yml',
        'sync-labels-from-tenant.yml',
        'deploy-dlp.yml',
        'sync-dlp-from-tenant.yml'
    ) {
        BeforeAll {
            $script:WfText = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github' 'workflows' $_) -Raw
        }

        It 'binds -Confirm:$false on every Deploy-Labels/Deploy-DLPPolicies invocation' {
            # An invocation is a pwsh call continued across lines with trailing
            # backticks, or a one-line splat (`... .ps1 @applyArgs`). Walk the
            # continuation lines rather than trying to express them in one regex.
            $lines = $script:WfText -split "\r?\n"
            $blocks = [System.Collections.Generic.List[string]]::new()
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -notmatch '\./scripts/Deploy-(?:Labels|DLPPolicies)\.ps1') { continue }
                $sb = [System.Text.StringBuilder]::new($lines[$i])
                $j = $i
                while ($j -lt $lines.Count - 1 -and $lines[$j].TrimEnd().EndsWith('`')) {
                    $j++
                    [void]$sb.AppendLine()
                    [void]$sb.Append($lines[$j])
                }
                $blocks.Add($sb.ToString())
            }
            $blocks.Count | Should -BeGreaterThan 0

            foreach ($block in $blocks) {
                # A splatted invocation carries Confirm inside the hashtable
                # built just above it; that is asserted by the next It block.
                if ($block -match '@\w+\s*$') { continue }
                $block | Should -Match '-Confirm:\$false' -Because "invocation '$($block.Trim())' must bind -Confirm:`$false or it hangs at ConfirmImpact='High'"
            }
        }

        It 'binds Confirm = $false in every splatted argument hashtable' {
            $splats = [regex]::Matches($script:WfText, '\$applyArgs\s*=\s*@\{(?<body>[^}]*)\}')
            foreach ($s in $splats) {
                $s.Groups['body'].Value | Should -Match 'Confirm\s*=\s*\$false'
            }
        }
    }
}
