# Pester tests for Install-ClientHealth.ps1 setup wizard
# Tests validate script structure, config generation, and function contracts
# without requiring MECM, SQL Server, or network infrastructure.

BeforeAll {
    $ScriptPath = Join-Path $PSScriptRoot '..\Deploy\Install-ClientHealth.ps1'
    $SourceRoot = Join-Path $PSScriptRoot '..'

    # Parse the script AST for static analysis
    $Tokens = $null
    $Errors = $null
    $AST = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$Tokens, [ref]$Errors)

    # Dot-source to load functions — the entry point is guarded and won't execute
    . $ScriptPath
}

Describe 'Script Integrity' {
    It 'Parses without errors' {
        $Errors.Count | Should -Be 0
    }

    It 'Has CmdletBinding attribute' {
        $AST.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' } |
            Should -Not -BeNullOrEmpty
    }

    It 'Defines all expected parameters' {
        $paramNames = $AST.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
        $expected = @('SiteCode','SiteServer','Domain','ManagementPoint','SqlServer',
                      'ClientSharePath','LogSharePath','TargetCollection','ClientVersion',
                      'InstallWebservice','WebserviceServer','WebservicePort','SourceRoot','OutputPath')
        foreach ($p in $expected) {
            $paramNames | Should -Contain $p -Because "Parameter '$p' should be defined"
        }
    }
}

Describe 'Read-ValidatedHost' {
    It 'Is defined as a function' {
        Get-Command Read-ValidatedHost -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'Has Prompt, Default, Validate, and ErrorMessage parameters' {
        $cmd = Get-Command Read-ValidatedHost
        $cmd.Parameters.Keys | Should -Contain 'Prompt'
        $cmd.Parameters.Keys | Should -Contain 'Default'
        $cmd.Parameters.Keys | Should -Contain 'Validate'
        $cmd.Parameters.Keys | Should -Contain 'ErrorMessage'
    }
}

Describe 'New-ClientHealthConfig' {
    BeforeAll {
        $tempDir = Join-Path $TestDrive 'config-test'
        New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
        $outFile = Join-Path $tempDir 'config.json'

        New-ClientHealthConfig `
            -SiteCode 'TST' `
            -Domain 'test.contoso.com' `
            -ManagementPoint 'mp01.test.contoso.com' `
            -SqlServer 'sql01.test.contoso.com' `
            -LogSharePath '\\filesvr\ClientHealthLogs$' `
            -ClientVersion '5.00.9128.1007' `
            -OutputFile $outFile

        $config = Get-Content $outFile -Raw | ConvertFrom-Json
    }

    It 'Generates valid JSON' {
        { Get-Content $outFile -Raw | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'Sets the correct site code' {
        $config.Client.SiteCode | Should -BeExactly 'TST'
    }

    It 'Sets the correct domain' {
        $config.Client.Domain | Should -BeExactly 'test.contoso.com'
    }

    It 'Sets the correct client version' {
        $config.Client.Version | Should -BeExactly '5.00.9128.1007'
    }

    It 'Sets the management point in ClientInstallProperties' {
        $mpProp = $config.ClientInstallProperties | Where-Object { $_ -match '^SMSMP=' }
        $mpProp | Should -BeExactly 'SMSMP=mp01.test.contoso.com'
    }

    It 'Does not include /Source in ClientInstallProperties' {
        $sourceProp = $config.ClientInstallProperties | Where-Object { $_ -match '/Source:' }
        $sourceProp | Should -BeNullOrEmpty
    }

    It 'Sets the SQL server in Logging' {
        $config.Logging.SQL.Server | Should -BeExactly 'sql01.test.contoso.com'
    }

    It 'Enables SQL logging' {
        $config.Logging.SQL.Enabled | Should -BeTrue
    }

    It 'Sets the log share path' {
        $config.Logging.Share | Should -BeExactly '\\filesvr\ClientHealthLogs$'
    }

    It 'Sets LocalFiles to ProgramData path' {
        $config.LocalFiles | Should -BeExactly 'C:\ProgramData\ConfigMgrClientHealth'
    }

    It 'Has AutoUpgrade enabled' {
        $config.Client.AutoUpgrade | Should -BeTrue
    }

    It 'Has Client.Share empty (ccmsetup comes from MP)' {
        $config.Client.Share | Should -BeExactly ''
    }

    It 'Has 7 services defined' {
        $config.Services.Count | Should -Be 7
    }

    It 'All service names are safe for WMI filters' {
        foreach ($svc in $config.Services) {
            $svc.Name | Should -Match '^[a-zA-Z0-9_\-\.]+$'
        }
    }

    It 'Has ccmexec in services list' {
        $config.Services.Name | Should -Contain 'ccmexec'
    }

    It 'Has all expected top-level keys' {
        $expected = @('LocalFiles','Client','ClientInstallProperties','Logging','Options','Services','Remediation','Sites')
        foreach ($key in $expected) {
            $config.PSObject.Properties.Name | Should -Contain $key
        }
    }

    It 'Has Sites.Default section' {
        $config.Sites.PSObject.Properties.Name | Should -Contain 'Default'
    }

    It 'Has Options.HardwareInventory with Days' {
        $config.Options.HardwareInventory.Days | Should -BeGreaterThan 0
    }

    It 'Has cache size set to 16GB' {
        $config.Client.Cache.Size | Should -Be 16384
    }
}

Describe 'Test-SqlConnection' {
    It 'Is defined as a function' {
        Get-Command Test-SqlConnection -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'Returns $false for an unreachable server' {
        Test-SqlConnection -Server 'nonexistent.invalid.local' | Should -BeFalse
    }
}

Describe 'New-FileShare' {
    It 'Is defined as a function' {
        Get-Command New-FileShare -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'Rejects invalid UNC paths' {
        { New-FileShare -UncPath 'C:\NotAShare' } | Should -Throw '*Invalid UNC path*'
    }

    It 'Has UncPath as mandatory parameter' {
        $cmd = Get-Command New-FileShare
        $cmd.Parameters['UncPath'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory } |
            Should -Not -BeNullOrEmpty
    }
}

Describe 'Copy-SourceFiles' {
    BeforeAll {
        $tempSource = Join-Path $TestDrive 'source'
        $tempTarget = Join-Path $TestDrive 'target'
        $tempDeploy = Join-Path $tempSource 'Deploy'
        New-Item -Path $tempSource -ItemType Directory -Force | Out-Null
        New-Item -Path $tempDeploy -ItemType Directory -Force | Out-Null

        # Create minimal source files
        Set-Content (Join-Path $tempSource 'ConfigMgrClientHealth.ps1') -Value '# main script'
        Set-Content (Join-Path $tempDeploy 'Deploy-ClientHealthPackage.ps1') -Value '# deploy'
        $configFile = Join-Path $TestDrive 'config.json'
        Set-Content $configFile -Value '{"test": true}'
    }

    It 'Copies all required files to the target directory' {
        Copy-SourceFiles -SourceRoot $tempSource -TargetPath $tempTarget -ConfigFile $configFile

        Test-Path (Join-Path $tempTarget 'ConfigMgrClientHealth.ps1') | Should -BeTrue
        Test-Path (Join-Path $tempTarget 'config.json') | Should -BeTrue
        Test-Path (Join-Path $tempTarget 'Deploy-ClientHealthPackage.ps1') | Should -BeTrue
    }

    It 'Creates the target directory if it does not exist' {
        $newTarget = Join-Path $TestDrive 'newtarget'
        Copy-SourceFiles -SourceRoot $tempSource -TargetPath $newTarget -ConfigFile $configFile
        Test-Path $newTarget | Should -BeTrue
    }

    It 'Throws when main script is missing' {
        $emptySource = Join-Path $TestDrive 'emptysource'
        New-Item -Path $emptySource -ItemType Directory -Force | Out-Null
        { Copy-SourceFiles -SourceRoot $emptySource -TargetPath $tempTarget -ConfigFile $configFile } |
            Should -Throw '*not found*'
    }
}

Describe 'New-MECMObjects' {
    It 'Is defined as a function' {
        Get-Command New-MECMObjects -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'Has all required parameters' {
        $cmd = Get-Command New-MECMObjects
        $required = @('SiteCode','SiteServer','SourcePath','TargetCollection','DetectionScript','RemediationScript')
        foreach ($p in $required) {
            $cmd.Parameters[$p].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory } |
                Should -Not -BeNullOrEmpty -Because "Parameter '$p' should be mandatory"
        }
    }
}

Describe 'Install-ClientHealthWebservice' {
    It 'Is defined as a function' {
        Get-Command Install-ClientHealthWebservice -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'Has SourceRoot, TargetServer, SqlServer, and Port parameters' {
        $cmd = Get-Command Install-ClientHealthWebservice
        $cmd.Parameters.Keys | Should -Contain 'SourceRoot'
        $cmd.Parameters.Keys | Should -Contain 'TargetServer'
        $cmd.Parameters.Keys | Should -Contain 'SqlServer'
        $cmd.Parameters.Keys | Should -Contain 'Port'
    }
}

Describe 'New-ClientHealthDatabase' {
    It 'Is defined as a function' {
        Get-Command New-ClientHealthDatabase -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'Has SqlServer and SqlScriptPath as mandatory parameters' {
        $cmd = Get-Command New-ClientHealthDatabase
        foreach ($p in @('SqlServer','SqlScriptPath')) {
            $cmd.Parameters[$p].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory } |
                Should -Not -BeNullOrEmpty -Because "Parameter '$p' should be mandatory"
        }
    }
}

Describe 'Security' {
    BeforeAll {
        $scriptContent = Get-Content $ScriptPath -Raw
    }

    It 'Does not use Invoke-Expression' {
        $iexCalls = $AST.FindAll({
            $args[0] -is [System.Management.Automation.Language.CommandAst] -and
            $args[0].GetCommandName() -eq 'Invoke-Expression'
        }, $true)
        $iexCalls.Count | Should -Be 0
    }

    It 'Does not contain hardcoded passwords' {
        $scriptContent | Should -Not -Match 'password\s*=\s*[''"][^''"]+[''"]'
    }

    It 'SQL connection uses Trusted_Connection (no embedded credentials)' {
        $scriptContent | Should -Match 'Trusted_Connection=True'
        $scriptContent | Should -Not -Match 'Password=[^;]+;'
    }

    It 'Does not use ConvertTo-SecureString with plaintext' {
        $scriptContent | Should -Not -Match 'ConvertTo-SecureString\s+[''"][^''"]+[''"]'
    }
}

Describe 'Static Analysis: No em-dashes in executable code' {
    BeforeAll {
        $scriptContent = Get-Content $ScriptPath -Raw
        # Remove comment lines for this check
        $codeOnly = ($scriptContent -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    }

    It 'Contains no em-dash characters in executable code' {
        # U+2014 em-dash breaks PowerShell 5.1 string expressions
        $codeOnly | Should -Not -Match ([char]0x2014)
    }
}

Describe 'Generated config compatibility with main script' {
    BeforeAll {
        $tempDir = Join-Path $TestDrive 'compat-test'
        New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
        $outFile = Join-Path $tempDir 'config.json'

        New-ClientHealthConfig `
            -SiteCode 'TST' `
            -Domain 'test.contoso.com' `
            -ManagementPoint 'mp01.test.contoso.com' `
            -SqlServer 'sql01.test.contoso.com' `
            -LogSharePath '\\filesvr\Logs$' `
            -ClientVersion '5.00.9128.1007' `
            -OutputFile $outFile

        $config = Get-Content $outFile -Raw | ConvertFrom-Json
    }

    It 'SiteCode matches 3-character pattern expected by main script' {
        $config.Client.SiteCode | Should -Match '^[A-Za-z0-9]{3}$'
    }

    It 'ClientInstallProperties is an array' {
        @($config.ClientInstallProperties).Count | Should -BeGreaterThan 0
    }

    It 'Has SMSSITECODE in ClientInstallProperties' {
        $config.ClientInstallProperties | Where-Object { $_ -match '^SMSSITECODE=' } |
            Should -Not -BeNullOrEmpty
    }

    It 'Has DNSSUFFIX in ClientInstallProperties' {
        $config.ClientInstallProperties | Where-Object { $_ -match '^DNSSUFFIX=' } |
            Should -Not -BeNullOrEmpty
    }

    It 'Logging.TimeFormat is a valid value' {
        $config.Logging.TimeFormat | Should -BeIn @('ClientLocal', 'UTC')
    }

    It 'All service states are valid' {
        foreach ($svc in $config.Services) {
            $svc.State | Should -BeIn @('Running', 'Stopped')
        }
    }

    It 'Has Options.RefreshComplianceState with Days' {
        $config.Options.RefreshComplianceState.Days | Should -BeGreaterThan 0
    }

    It 'Has Remediation.ClientWUAHandler with Days' {
        $config.Remediation.ClientWUAHandler.Days | Should -BeGreaterThan 0
    }
}
