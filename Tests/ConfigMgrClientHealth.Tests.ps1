# Pester tests for ConfigMgr Client Health community fork
# These tests validate security fixes, code quality, and structural integrity
# without requiring a ConfigMgr environment or SQL Server.

BeforeAll {
    $ScriptPath = Join-Path $PSScriptRoot '..\ConfigMgrClientHealth.ps1'
    $ConfigPath = Join-Path $PSScriptRoot '..\config.xml'
    $SqlSchemaPath = Join-Path $PSScriptRoot '..\CreateDatabase.sql'

    # Parse the script AST for static analysis
    $Tokens = $null
    $Errors = $null
    $AST = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$Tokens, [ref]$Errors)
}

Describe 'Script Integrity' {
    It 'Parses without errors' {
        $Errors.Count | Should -Be 0
    }

    It 'Contains a Begin block' {
        $AST.BeginBlock | Should -Not -BeNullOrEmpty
    }

    It 'Contains a Process block' {
        $AST.ProcessBlock | Should -Not -BeNullOrEmpty
    }

    It 'Contains an End block' {
        $AST.EndBlock | Should -Not -BeNullOrEmpty
    }
}

Describe 'Security: No Invoke-Expression' {
    It 'Does not use Invoke-Expression anywhere' {
        $iexCalls = $AST.FindAll({
            $args[0] -is [System.Management.Automation.Language.CommandAst] -and
            $args[0].GetCommandName() -eq 'Invoke-Expression'
        }, $true)
        $iexCalls.Count | Should -Be 0
    }
}

Describe 'Security: Parameterized SQL' {
    BeforeAll {
        $scriptContent = Get-Content $ScriptPath -Raw
    }

    It 'Update-SQL function exists' {
        $scriptContent | Should -Match 'Function Update-SQL'
    }

    It 'Update-SQL uses @paramName placeholders instead of string concatenation' {
        # The old vulnerable pattern: "'"+$log.Hostname+"'"
        $scriptContent | Should -Not -Match "\`"'\`"\+\\\$log\."
    }

    It 'Update-SQL builds SqlParameter array' {
        $scriptContent | Should -Match 'New-SqlParam\s+.@Hostname'
    }

    It 'Invoke-Sqlcmd2 accepts SqlParameters parameter' {
        $scriptContent | Should -Match '\[System\.Data\.SqlClient\.SqlParameter\[\]\]\$SqlParameters'
    }

    It 'Invoke-Sqlcmd2 adds parameters to command' {
        $scriptContent | Should -Match '\$cmd\.Parameters\.Add'
    }

    It 'Uses Invoke-WithRetry for SQL operations' {
        $scriptContent | Should -Match "Invoke-WithRetry\s+-OperationName\s+'SQL Update'"
    }
}

Describe 'Security: Config Validation' {
    BeforeAll {
        $scriptContent = Get-Content $ScriptPath -Raw
    }

    It 'Test-ConfigValues function exists' {
        $scriptContent | Should -Match 'Function Test-ConfigValues'
    }

    It 'Validates service names against regex' {
        $scriptContent | Should -Match "notmatch\s+'.*\[a-zA-Z0-9"
    }

    It 'Validates site code format' {
        $scriptContent | Should -Match "notmatch\s+'.*\[A-Za-z0-9\].*3"
    }

    It 'Test-ConfigValues is called after config load' {
        $scriptContent | Should -Match 'Test-ConfigValues\s+-Xml\s+\$Xml'
    }
}

Describe 'Security: No hardcoded credentials' {
    BeforeAll {
        $scriptContent = Get-Content $ScriptPath -Raw
    }

    It 'Does not contain plaintext passwords' {
        $scriptContent | Should -Not -Match 'password\s*=\s*[''"][^''"]+[''"]'
    }

    It 'Does not contain API keys' {
        $scriptContent | Should -Not -Match 'apikey\s*=\s*[''"][^''"]+[''"]'
    }
}

Describe 'WMI to CIM Migration' {
    BeforeAll {
        $scriptContent = Get-Content $ScriptPath -Raw
    }

    It 'Contains no Get-WmiObject calls' {
        $wmiCalls = $AST.FindAll({
            $args[0] -is [System.Management.Automation.Language.CommandAst] -and
            $args[0].GetCommandName() -eq 'Get-WmiObject'
        }, $true)
        $wmiCalls.Count | Should -Be 0
    }

    It 'Contains no Invoke-WmiMethod calls' {
        $wmiCalls = $AST.FindAll({
            $args[0] -is [System.Management.Automation.Language.CommandAst] -and
            $args[0].GetCommandName() -eq 'Invoke-WmiMethod'
        }, $true)
        $wmiCalls.Count | Should -Be 0
    }

    It 'Contains no Remove-WmiObject calls' {
        $wmiCalls = $AST.FindAll({
            $args[0] -is [System.Management.Automation.Language.CommandAst] -and
            $args[0].GetCommandName() -eq 'Remove-WmiObject'
        }, $true)
        $wmiCalls.Count | Should -Be 0
    }

    It 'Contains no [wmiclass] type accelerators in executable code' {
        $typeExprs = $AST.FindAll({
            $args[0] -is [System.Management.Automation.Language.TypeExpressionAst] -and
            $args[0].TypeName.Name -eq 'wmiclass'
        }, $true)
        $typeExprs.Count | Should -Be 0
    }

    It 'Contains no $PowerShellVersion variable in executable code' {
        $varRefs = $AST.FindAll({
            $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $args[0].VariablePath.UserPath -eq 'PowerShellVersion'
        }, $true)
        $varRefs.Count | Should -Be 0
    }

    It 'Uses Get-CimInstance for WMI queries' {
        $cimCalls = $AST.FindAll({
            $args[0] -is [System.Management.Automation.Language.CommandAst] -and
            $args[0].GetCommandName() -eq 'Get-CimInstance'
        }, $true)
        $cimCalls.Count | Should -BeGreaterThan 10
    }

    It 'Uses Invoke-CimMethod for WMI method calls' {
        $cimCalls = $AST.FindAll({
            $args[0] -is [System.Management.Automation.Language.CommandAst] -and
            $args[0].GetCommandName() -eq 'Invoke-CimMethod'
        }, $true)
        $cimCalls.Count | Should -BeGreaterThan 3
    }

    It 'Does not use ConvertToDateTime (CIM returns native DateTime)' {
        $scriptContent | Should -Not -Match '\.ConvertToDateTime\('
    }

    It 'Has consolidated Invoke-CCMTrigger function' {
        $scriptContent | Should -Match 'Function Invoke-CCMTrigger'
    }

    It 'Invoke-CCMTrigger accepts ScheduleID parameter' {
        $scriptContent | Should -Match 'Invoke-CCMTrigger.*-ScheduleID'
    }
}

Describe 'Error Handling' {
    BeforeAll {
        $scriptContent = Get-Content $ScriptPath -Raw
    }

    It 'Contains no empty catch blocks in executable code' {
        $catchClauses = $AST.FindAll({
            $args[0] -is [System.Management.Automation.Language.CatchClauseAst]
        }, $true)
        $emptyCatches = $catchClauses | Where-Object { $_.Body.Statements.Count -eq 0 }
        $emptyCatches.Count | Should -Be 0
    }

    It 'Invoke-WithRetry function exists' {
        $scriptContent | Should -Match 'Function Invoke-WithRetry'
    }

    It 'Invoke-WithRetry has MaxRetries parameter' {
        $scriptContent | Should -Match '\$MaxRetries\s*=\s*3'
    }
}

Describe 'Client Install Safety' {
    BeforeAll {
        $scriptContent = Get-Content $ScriptPath -Raw
    }

    It 'Uses Start-Process for ccmsetup.exe instead of Invoke-Expression' {
        $scriptContent | Should -Match "Start-Process\s+-FilePath.*ccmsetup\.exe"
    }

    It 'Uses -ArgumentList array for ccmsetup parameters' {
        $scriptContent | Should -Match '-ArgumentList\s+\$argArray'
    }

    It 'Does not use backtick-semicolon escaping for install properties' {
        $scriptContent | Should -Not -Match "Replace\(';',\s*'``;"
    }
}

Describe 'Config File: config.xml' {
    BeforeAll {
        [xml]$Config = Get-Content $ConfigPath
    }

    It 'config.xml exists and is valid XML' {
        { [xml](Get-Content $ConfigPath) } | Should -Not -Throw
    }

    It 'Has Configuration root element' {
        $Config.Configuration | Should -Not -BeNullOrEmpty
    }

    It 'Has Client elements' {
        $Config.Configuration.Client | Should -Not -BeNullOrEmpty
    }

    It 'Has Service elements' {
        $Config.Configuration.Service | Should -Not -BeNullOrEmpty
    }

    It 'Has Option elements' {
        $Config.Configuration.Option | Should -Not -BeNullOrEmpty
    }

    It 'Has Remediation elements' {
        $Config.Configuration.Remediation | Should -Not -BeNullOrEmpty
    }

    It 'Has Log elements' {
        $Config.Configuration.Log | Should -Not -BeNullOrEmpty
    }

    It 'Service names are safe for WMI filters' {
        foreach ($svc in $Config.Configuration.Service) {
            $svc.Name | Should -Match '^[a-zA-Z0-9_\-\.]+$'
        }
    }
}

Describe 'SQL Schema: CreateDatabase.sql' {
    BeforeAll {
        $SqlContent = Get-Content $SqlSchemaPath -Raw
    }

    It 'CreateDatabase.sql exists' {
        Test-Path $SqlSchemaPath | Should -BeTrue
    }

    It 'Creates ClientHealth database' {
        $SqlContent | Should -Match 'CREATE DATABASE.*ClientHealth'
    }

    It 'Creates Clients table' {
        $SqlContent | Should -Match 'CREATE TABLE.*Clients'
    }

    It 'Has Hostname as primary key' {
        $SqlContent | Should -Match 'Hostname.*PRIMARY KEY'
    }

    It 'Schema columns match Update-SQL parameters' {
        $scriptContent = Get-Content $ScriptPath -Raw
        # Extract parameter names from New-SqlParam calls
        $paramNames = [regex]::Matches($scriptContent, "New-SqlParam\s+'@(\w+)'") | ForEach-Object { $_.Groups[1].Value }
        # Every param should have a column in the schema (except Timestamp which maps to datetime)
        foreach ($param in $paramNames) {
            if ($param -eq 'Timestamp') { continue }  # datetime column, different name format
            $SqlContent | Should -Match $param -Because "Column $param should exist in schema"
        }
    }
}

Describe 'Script Structure' {
    BeforeAll {
        $scriptContent = Get-Content $ScriptPath -Raw
    }

    It 'Has version string' {
        $scriptContent | Should -Match "\`$Version\s*=\s*'[0-9]+\.[0-9]+\.[0-9]+'"
    }

    It 'Sets last run timestamp in registry' {
        $scriptContent | Should -Match 'LastRunRegistryValueName'
    }

    It 'Supports -Config parameter' {
        $scriptContent | Should -Match '\[string\]\$Config'
    }

    It 'Supports -Webservice parameter' {
        $scriptContent | Should -Match '\[string\]\$Webservice'
    }

    It 'Has SupportsShouldProcess for safety' {
        $scriptContent | Should -Match 'SupportsShouldProcess'
    }
}

Describe 'JSON Config: config.json' {
    BeforeAll {
        $JsonConfigPath = Join-Path $PSScriptRoot '..\config.json'
        $JsonConfig = Get-Content $JsonConfigPath -Raw | ConvertFrom-Json
    }

    It 'config.json exists and is valid JSON' {
        { Get-Content $JsonConfigPath -Raw | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'Has Client section with Version' {
        $JsonConfig.Client.Version | Should -Not -BeNullOrEmpty
    }

    It 'Has Client.SiteCode' {
        $JsonConfig.Client.SiteCode | Should -Match '^[A-Za-z0-9]{3}$'
    }

    It 'Has Client.Cache with Size and Enable' {
        $JsonConfig.Client.Cache.Size | Should -BeGreaterThan 0
        $JsonConfig.Client.Cache.PSObject.Properties['Enable'] | Should -Not -BeNullOrEmpty
    }

    It 'Has ClientInstallProperties as array' {
        @($JsonConfig.ClientInstallProperties).Count | Should -BeGreaterThan 0
    }

    It 'Has Logging section with SQL' {
        $JsonConfig.Logging.SQL | Should -Not -BeNullOrEmpty
        $JsonConfig.Logging.SQL.PSObject.Properties['Server'] | Should -Not -BeNullOrEmpty
        $JsonConfig.Logging.SQL.PSObject.Properties['Enabled'] | Should -Not -BeNullOrEmpty
    }

    It 'Has Logging.TimeFormat' {
        $JsonConfig.Logging.TimeFormat | Should -BeIn @('ClientLocal', 'UTC')
    }

    It 'Has Options section' {
        $JsonConfig.Options | Should -Not -BeNullOrEmpty
    }

    It 'Has Options.HardwareInventory with Days' {
        $JsonConfig.Options.HardwareInventory.Days | Should -BeGreaterThan 0
    }

    It 'Has Services array with valid entries' {
        $JsonConfig.Services | Should -Not -BeNullOrEmpty
        $JsonConfig.Services.Count | Should -BeGreaterThan 0
        foreach ($svc in $JsonConfig.Services) {
            $svc.Name | Should -Match '^[a-zA-Z0-9_\-\.]+$'
            $svc.State | Should -BeIn @('Running', 'Stopped')
        }
    }

    It 'Has Remediation section' {
        $JsonConfig.Remediation | Should -Not -BeNullOrEmpty
    }

    It 'Has Sites section with Default' {
        $JsonConfig.Sites | Should -Not -BeNullOrEmpty
        $JsonConfig.Sites.PSObject.Properties['Default'] | Should -Not -BeNullOrEmpty
    }
}

Describe 'JSON Config: Backward Compatibility' {
    BeforeAll {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\ConfigMgrClientHealth.ps1') -Raw
    }

    It 'Accepts both .xml and .json file extensions' {
        $scriptContent | Should -Match "ValidatePattern\('.*xml.*json"
    }

    It 'Branches on file extension for config loading' {
        $scriptContent | Should -Match "Config -match '\\\.json"
    }

    It 'Preserves XML fallback in Get-XMLConfig functions' {
        # Each function should still have the XML path
        $scriptContent | Should -Match 'Xml\.Configuration\.'
    }

    It 'Initializes JsonConfig to null' {
        $scriptContent | Should -Match '\$script:JsonConfig\s*=\s*\$null'
    }
}

Describe 'Site-Aware Config' {
    BeforeAll {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\ConfigMgrClientHealth.ps1') -Raw
    }

    It 'Get-SiteConfig function exists' {
        $scriptContent | Should -Match 'Function Get-SiteConfig'
    }

    It 'Get-SiteConfig checks AD site name' {
        $scriptContent | Should -Match 'Get-ClientSiteName'
    }

    It 'Get-SiteConfig falls back to Default' {
        $scriptContent | Should -Match "PSObject\.Properties\['Default'\]"
    }

    It 'SQL server accessor uses site override' {
        $scriptContent | Should -Match "Get-SiteConfig\s+-PropertyName\s+'SQLServer'"
    }

    It 'Client share accessor uses site override' {
        $scriptContent | Should -Match "Get-SiteConfig\s+-PropertyName\s+'ClientShare'"
    }

    It 'Log share accessor uses site override' {
        $scriptContent | Should -Match "Get-SiteConfig\s+-PropertyName\s+'LogShare'"
    }
}

Describe 'Config Caching' {
    BeforeAll {
        $scriptContent = Get-Content (Join-Path $PSScriptRoot '..\ConfigMgrClientHealth.ps1') -Raw
    }

    It 'Defines cache path in ProgramData' {
        $scriptContent | Should -Match 'ConfigMgrClientHealth'
        $scriptContent | Should -Match 'config\.json\.cache'
    }

    It 'Caches config after successful JSON load' {
        $scriptContent | Should -Match 'Set-Content\s+-Path\s+\$ConfigCachePath'
    }

    It 'Falls back to cache when config file unreachable' {
        $scriptContent | Should -Match 'Using cached config from'
    }

    It 'Warns when using cached config' {
        $scriptContent | Should -Match 'Write-Warning.*cached config'
    }
}
