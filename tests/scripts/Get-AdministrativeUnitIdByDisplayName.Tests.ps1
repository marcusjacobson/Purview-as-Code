#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Unit tests for scripts/Get-AdministrativeUnitIdByDisplayName.ps1 (ADR 0042).

.DESCRIPTION
    Exercises forward (DisplayName -> objectId) and reverse (objectId -> DisplayName)
    lookup branches by stubbing the az external command with a local function inside
    each It block.  No live tenant.  Synthetic GUIDs follow the
    00000000-0000-0000-0000-0000000000NN pattern per sample-data.instructions.md.

    Reference: https://learn.microsoft.com/en-us/graph/api/administrativeunit-list
    Reference: https://learn.microsoft.com/en-us/graph/api/administrativeunit-get
    Reference: https://learn.microsoft.com/en-us/graph/query-parameters#filter-parameter
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' `
        'Get-AdministrativeUnitIdByDisplayName.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Get-AdministrativeUnitIdByDisplayName.ps1 at: $script:ScriptPath"
    }
    # Reset cache before suite runs.
    $global:PurviewIdentifierCache = @{}
}

Describe 'Get-AdministrativeUnitIdByDisplayName -- ByDisplayName forward lookup' {

    It 'returns the object ID when Graph returns exactly one match' {
        $global:PurviewIdentifierCache = @{}
        function az {
            $script:AzArgs = $args -join ' '
            $global:LASTEXITCODE = 0
            return '{"value":[{"id":"00000000-0000-0000-0000-000000000001","displayName":"Finance"}]}'
        }
        $result = & $script:ScriptPath -DisplayName 'Finance' -NoCache
        $result | Should -Be '00000000-0000-0000-0000-000000000001'
    }

    It 'populates the session cache after a successful lookup' {
        $global:PurviewIdentifierCache = @{}
        function az {
            $global:LASTEXITCODE = 0
            return '{"value":[{"id":"00000000-0000-0000-0000-000000000002","displayName":"Marketing"}]}'
        }
        & $script:ScriptPath -DisplayName 'Marketing' -NoCache | Out-Null
        $global:PurviewIdentifierCache.ContainsKey('AdministrativeUnit|Marketing') | Should -BeTrue
        $global:PurviewIdentifierCache['AdministrativeUnit|Marketing'] |
            Should -Be '00000000-0000-0000-0000-000000000002'
    }

    It 'throws when Graph returns zero matches' {
        $global:PurviewIdentifierCache = @{}
        function az {
            $global:LASTEXITCODE = 0
            return '{"value":[]}'
        }
        { & $script:ScriptPath -DisplayName 'NonExistent AU' -NoCache } | Should -Throw
    }

    It 'throws when Graph returns more than one match' {
        $global:PurviewIdentifierCache = @{}
        function az {
            $global:LASTEXITCODE = 0
            return '{"value":[{"id":"00000000-0000-0000-0000-000000000001","displayName":"Finance"},{"id":"00000000-0000-0000-0000-000000000002","displayName":"Finance"}]}'
        }
        { & $script:ScriptPath -DisplayName 'Finance' -NoCache } | Should -Throw
    }

    It 'escapes a single quote in the display name for OData filter (Reference: https://learn.microsoft.com/en-us/graph/query-parameters#filter-parameter)' {
        $global:PurviewIdentifierCache = @{}
        $global:CapturedUri = ''
        function az {
            $global:CapturedUri = $args -join ' '
            $global:LASTEXITCODE = 0
            return '{"value":[{"id":"00000000-0000-0000-0000-000000000003","displayName":"OBrien Dept"}]}'
        }
        # Display name contains a single quote that must be doubled in the OData $filter.
        # The script does: $escaped = $DisplayName.Replace("'", "''")
        # Reference: https://learn.microsoft.com/en-us/graph/query-parameters#filter-parameter
        & $script:ScriptPath -DisplayName "O'Brien Dept" -NoCache | Out-Null
        $global:CapturedUri | Should -Match "O''Brien"
    }
}

Describe 'Get-AdministrativeUnitIdByDisplayName -- ByObjectId reverse lookup' {

    It 'returns the display name when Graph returns a valid object' {
        $global:PurviewIdentifierCache = @{}
        function az {
            $global:LASTEXITCODE = 0
            return '{"id":"00000000-0000-0000-0000-000000000001","displayName":"Finance"}'
        }
        $result = & $script:ScriptPath -ObjectId '00000000-0000-0000-0000-000000000001' -NoCache
        $result | Should -Be 'Finance'
    }

    It 'populates the reverse cache after a successful lookup' {
        $global:PurviewIdentifierCache = @{}
        function az {
            $global:LASTEXITCODE = 0
            return '{"id":"00000000-0000-0000-0000-000000000004","displayName":"Legal"}'
        }
        & $script:ScriptPath -ObjectId '00000000-0000-0000-0000-000000000004' -NoCache | Out-Null
        $global:PurviewIdentifierCache.ContainsKey(
            'AdministrativeUnit|ById|00000000-0000-0000-0000-000000000004') | Should -BeTrue
    }

    It 'throws when the response displayName is empty' {
        $global:PurviewIdentifierCache = @{}
        function az {
            $global:LASTEXITCODE = 0
            return '{"id":"00000000-0000-0000-0000-000000000001","displayName":""}'
        }
        { & $script:ScriptPath -ObjectId '00000000-0000-0000-0000-000000000001' -NoCache } |
            Should -Throw
    }
}
