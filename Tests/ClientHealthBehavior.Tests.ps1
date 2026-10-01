# Behavioral tests: each function is extracted from ConfigMgrClientHealth.ps1 by AST and executed
# in isolation with stubs, so no ConfigMgr client, SQL Server, or network is required.

BeforeDiscovery {
    $IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

BeforeAll {
    $script:ScriptFile = Join-Path $PSScriptRoot '..\ConfigMgrClientHealth.ps1'
    $tokens = $null; $errors = $null
    $script:ScriptAst = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptFile, [ref]$tokens, [ref]$errors)
    $script:AllFunctions = $script:ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)

    function Get-FunctionSource {
        param([string[]]$Name)
        foreach ($fn in $Name) {
            $node = $script:AllFunctions | Where-Object { $_.Name -eq $fn } | Select-Object -First 1
            if (-not $node) { throw "Function $fn not found in script" }
            $node.Extent.Text
        }
    }
}

Describe 'Config getter call sites' {
    It 'Never passes comparison operators as arguments to a Get-XMLConfig command' {
        # "if (Get-XMLConfigX -like 'True')" binds -like as an ignored argument, and the string "False" is truthy.
        $bad = $script:ScriptAst.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -like 'Get-XMLConfig*' -and
            @($n.CommandElements | Where-Object {
                $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
                $_.ParameterName -match '^(i|c)?(like|notlike|eq|ne|ge|gt|le|lt|match|notmatch)$'
            }).Count -gt 0
        }, $true)
        @($bad | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Extent.Text)" }) | Should -BeNullOrEmpty
    }

    It 'Every function that reads the XML config also handles JSON config' {
        $xmlOnly = $script:AllFunctions | Where-Object {
            $_.Body.Extent.Text -match '\$Xml\.Configuration' -and
            $_.Body.Extent.Text -notmatch '\$script:JsonConfig' -and
            $_.Name -notin @('Test-XML')
        }
        @($xmlOnly | ForEach-Object { $_.Name }) | Should -BeNullOrEmpty
    }

    It 'Does not call ExpandString on config values' {
        (Get-Content $script:ScriptFile -Raw) | Should -Not -Match 'InvokeCommand\.ExpandString'
    }
}

Describe 'ConvertTo-ConfigBoolean' {
    BeforeAll { . ([scriptblock]::Create((Get-FunctionSource 'ConvertTo-ConfigBoolean'))) }

    It 'Returns <Expected> for <Value>' -ForEach @(
        @{ Value = 'True'; Expected = $true }
        @{ Value = 'false'; Expected = $false }
        @{ Value = 'FALSE'; Expected = $false }
        @{ Value = $true; Expected = $true }
        @{ Value = $false; Expected = $false }
        @{ Value = '1'; Expected = $true }
        @{ Value = '0'; Expected = $false }
        @{ Value = 'yes'; Expected = $true }
        @{ Value = 'enable'; Expected = $true }
    ) {
        ConvertTo-ConfigBoolean $Value | Should -Be $Expected
    }

    It 'Returns the default for empty or unparseable values' {
        ConvertTo-ConfigBoolean $null | Should -BeFalse
        ConvertTo-ConfigBoolean '' -Default $true | Should -BeTrue
        ConvertTo-ConfigBoolean 'banana' 3>$null | Should -BeFalse
    }
}

Describe 'ConvertTo-ConfigInt' {
    BeforeAll { . ([scriptblock]::Create((Get-FunctionSource 'ConvertTo-ConfigInt'))) }

    It 'Parses integers' {
        ConvertTo-ConfigInt -Value '14' -Default 7 | Should -Be 14
        ConvertTo-ConfigInt -Value 3 -Default 7 | Should -Be 3
    }

    It 'Uses the default for missing, empty, or non-numeric values' {
        ConvertTo-ConfigInt -Value $null -Default 7 | Should -Be 7
        ConvertTo-ConfigInt -Value '' -Default 7 | Should -Be 7
        ConvertTo-ConfigInt -Value 'False' -Default 7 | Should -Be 7
    }

    It 'Uses the default below the minimum' {
        ConvertTo-ConfigInt -Value '0' -Default 8 -Minimum 1 | Should -Be 8
    }
}

Describe 'Expand-ConfigPath' {
    BeforeAll { . ([scriptblock]::Create((Get-FunctionSource 'Expand-ConfigPath'))) }

    It 'Expands %VAR% and $env:VAR' {
        Expand-ConfigPath '%SystemRoot%\Temp' | Should -Be "$env:SystemRoot\Temp"
        Expand-ConfigPath '$env:SystemRoot\Temp' | Should -Be "$env:SystemRoot\Temp"
    }

    It 'Does not execute subexpressions' {
        $global:ExpandConfigPathSentinel = $null
        $value = '$(Set-Variable -Name ExpandConfigPathSentinel -Value 1 -Scope Global)C:\x'
        Expand-ConfigPath $value | Should -Be $value
        $global:ExpandConfigPathSentinel | Should -BeNullOrEmpty
    }

    It 'Keeps a literal dollar sign in a share name' {
        Expand-ConfigPath '\\srv\Logs$Archive' | Should -Be '\\srv\Logs$Archive'
    }
}

Describe 'SQL parameter conversion' {
    BeforeAll { . ([scriptblock]::Create((Get-FunctionSource 'ConvertTo-SqlValue', 'New-SqlParam'))) }

    It 'Keeps zero as zero, not NULL' {
        ConvertTo-SqlValue -Type Int -Value 0 | Should -Be 0
        ConvertTo-SqlValue -Type Float -Value 0 | Should -Be 0
    }

    It 'Maps empty and null values to DBNull' {
        ConvertTo-SqlValue -Type VarChar -Value '' | Should -BeOfType [System.DBNull]
        ConvertTo-SqlValue -Type Int -Value $null | Should -BeOfType [System.DBNull]
    }

    It 'Maps a date outside the smalldatetime range to DBNull' {
        ConvertTo-SqlValue -Type SmallDateTime -Value '0001-01-01 00:00:00' | Should -BeOfType [System.DBNull]
    }

    It 'Parses the log date format independent of culture' {
        $previous = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]'de-DE'
            $value = ConvertTo-SqlValue -Type SmallDateTime -Value '2026-09-13 14:05:00'
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $previous }
        $value | Should -BeOfType [datetime]
        $value.Month | Should -Be 9
        $value.Day | Should -Be 13
    }

    It 'Maps a non-numeric value for an int column to DBNull' {
        ConvertTo-SqlValue -Type Int -Value 'False' | Should -BeOfType [System.DBNull]
    }

    It 'Creates typed, size-limited parameters' {
        $p = New-SqlParam '@Sitecode' VarChar 3 'ABC'
        $p.SqlDbType | Should -Be ([System.Data.SqlDbType]::VarChar)
        $p.Size | Should -Be 3
        $p.Value | Should -Be 'ABC'
    }
}

Describe 'Client version comparison' {
    BeforeAll { . ([scriptblock]::Create((Get-FunctionSource 'ConvertTo-ClientVersion', 'Test-ClientVersionAtLeast'))) }

    It 'Compares numerically across digit-count changes' {
        Test-ClientVersionAtLeast -Installed '5.00.10000.1000' -Minimum '5.00.9135.1000' | Should -BeTrue
        Test-ClientVersionAtLeast -Installed '5.00.9135.1000' -Minimum '5.00.10000.1000' | Should -BeFalse
    }

    It 'Fails the check when the installed version is unreadable' {
        Test-ClientVersionAtLeast -Installed $null -Minimum '5.00.9135.1000' | Should -BeFalse
    }

    It 'Passes the check when no minimum is configured' {
        Test-ClientVersionAtLeast -Installed '5.00.9135.1000' -Minimum '' | Should -BeTrue
    }
}

Describe 'Management point validation' {
    BeforeAll { . ([scriptblock]::Create((Get-FunctionSource 'Test-ManagementPointName'))) }

    It 'Accepts hostnames and FQDNs' {
        Test-ManagementPointName 'mp01' | Should -BeTrue
        Test-ManagementPointName 'mp01.corp.contoso.com' | Should -BeTrue
    }

    It 'Rejects URLs, whitespace, and a trailing newline' {
        Test-ManagementPointName 'http://mp01' | Should -BeFalse
        Test-ManagementPointName 'mp 01' | Should -BeFalse
        Test-ManagementPointName "mp01`n" | Should -BeFalse
    }
}

Describe 'Trusted directory check' {
    BeforeAll { . ([scriptblock]::Create((Get-FunctionSource 'Test-TrustedDirectory'))) }

    It 'Rejects a missing directory' {
        Test-TrustedDirectory -Path (Join-Path $TestDrive 'missing') | Should -BeFalse
    }

    It 'Rejects a directory with inherited, user-writable permissions' {
        $dir = Join-Path $TestDrive 'userowned'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Test-TrustedDirectory -Path $dir | Should -BeFalse
    }
}

Describe 'Staging folder protection' {
    It 'Deploy-ClientHealthPackage.ps1 carries identical copies of the secure-folder helpers' {
        $packageFile = Join-Path $PSScriptRoot '..\Deploy\Deploy-ClientHealthPackage.ps1'
        $packageAst = [System.Management.Automation.Language.Parser]::ParseFile($packageFile, [ref]$null, [ref]$null)
        $packageFunctions = $packageAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        foreach ($name in 'Test-TrustedDirectory', 'Remove-PathNoFollow', 'Initialize-SecureDirectory') {
            $normalize = { param($text) (($text -split "`r?`n") | ForEach-Object { $_.Trim() }) -join "`n" }
            $inScript = & $normalize ((Get-FunctionSource $name) | Out-String).Trim()
            $inPackage = & $normalize (($packageFunctions | Where-Object Name -eq $name | Select-Object -First 1).Extent.Text)
            $inPackage | Should -Be $inScript -Because "$name must match in both files"
        }
    }

    It 'Remove-PathNoFollow deletes a junction without deleting its target' {
        . ([scriptblock]::Create((Get-FunctionSource 'Remove-PathNoFollow')))
        $target = Join-Path $TestDrive 'target'
        $victim = Join-Path $target 'keep.txt'
        New-Item -ItemType Directory -Path $target | Out-Null
        Set-Content -Path $victim -Value 'keep'
        $folder = Join-Path $TestDrive 'planted'
        New-Item -ItemType Directory -Path $folder | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $folder 'link') -Target $target | Out-Null
        Set-Content -Path (Join-Path $folder 'file.txt') -Value 'x'

        Remove-PathNoFollow -Path $folder

        Test-Path $folder | Should -BeFalse
        Test-Path $victim | Should -BeTrue
    }

    # Setting another account as owner needs administrator rights.
    It 'Initialize-SecureDirectory removes an item another account owns from a trusted folder' -Skip:(-not $IsElevated) {
        . ([scriptblock]::Create((Get-FunctionSource 'Test-TrustedDirectory', 'Remove-PathNoFollow', 'Initialize-SecureDirectory')))
        $folder = Join-Path $TestDrive 'trusted'
        Initialize-SecureDirectory -Path $folder | Should -BeTrue
        $planted = Join-Path $folder 'ConfigMgrClientHealth.ps1'
        $kept = Join-Path $folder 'config.json'
        Set-Content -Path $planted -Value 'planted'
        Set-Content -Path $kept -Value '{}'
        & icacls.exe $planted /setowner '*S-1-5-32-545' | Out-Null
        (Get-Acl -LiteralPath $planted).GetOwner([System.Security.Principal.SecurityIdentifier]).Value | Should -Be 'S-1-5-32-545'

        Initialize-SecureDirectory -Path $folder 3>$null | Should -BeTrue

        Test-Path $planted | Should -BeFalse
        Test-Path $kept | Should -BeTrue
    }

    # Elevated, the test folder is owned by Administrators and is legitimately trusted.
    It 'CI-Remediation refuses a staging folder owned by a standard user' -Skip:$IsElevated {
        $programData = Join-Path $TestDrive 'pd'
        $staging = Join-Path $programData 'ConfigMgrClientHealth'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        $marker = Join-Path $TestDrive 'executed.txt'
        Set-Content -Path (Join-Path $staging 'ConfigMgrClientHealth.ps1') -Value "Set-Content -Path '$marker' -Value 'ran'"
        Set-Content -Path (Join-Path $staging 'config.json') -Value '{}'

        $remediation = Join-Path $PSScriptRoot '..\Deploy\CI-Remediation.ps1'
        $savedProgramData = $env:ProgramData
        try {
            $env:ProgramData = $programData
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $remediation 2>$null | Out-Null
            $exitCode = $LASTEXITCODE
        }
        finally { $env:ProgramData = $savedProgramData }

        $exitCode | Should -Be 1
        Test-Path $marker | Should -BeFalse
    }
}

Describe 'Break scripts' {
    It '<File> uses the compliance refresh registry value that the script reads' -ForEach @(
        @{ File = 'Break-ComplianceState.ps1' }
        @{ File = 'Get-HealthState.ps1' }
    ) {
        $valueName = [regex]::Match((Get-Content $script:ScriptFile -Raw), '\$RegValueName\s*=\s*"([^"]+)"').Groups[1].Value
        $valueName | Should -Not -BeNullOrEmpty
        Get-Content (Join-Path $PSScriptRoot "BreakScripts\$File") -Raw | Should -Match ([regex]::Escape("-Name '$valueName'"))
    }
}

Describe 'Get-OperatingSystem' {
    BeforeAll { . ([scriptblock]::Create((Get-FunctionSource 'Get-OperatingSystem'))) }

    It 'Maps <Caption> to <Expected>' -ForEach @(
        @{ Caption = 'Microsoft Windows 11 Pro'; Expected = 'Windows 11 64-Bit' }
        @{ Caption = 'Microsoft Windows 10 Enterprise'; Expected = 'Windows 10 64-Bit' }
        @{ Caption = 'Microsoft Windows Server 2022 Datacenter'; Expected = 'Windows Server 2022 64-Bit' }
        @{ Caption = 'Microsoft Windows Server 2025 Standard'; Expected = 'Windows Server 2025 64-Bit' }
    ) {
        Mock Get-CimInstance { [pscustomobject]@{ Caption = $Caption; OSArchitecture = '64-bit' } }
        Get-OperatingSystem | Should -Be $Expected
    }

    It 'Returns a non-empty name for an unknown caption' {
        Mock Get-CimInstance { [pscustomobject]@{ Caption = 'Microsoft Windows 12 Pro'; OSArchitecture = '64-bit' } }
        Get-OperatingSystem | Should -Be 'Windows 12 Pro 64-Bit'
    }
}

Describe 'Resolve-Client failure handling' {
    BeforeAll {
        . ([scriptblock]::Create((Get-FunctionSource 'Test-ManagementPointName', 'Test-MicrosoftSignedFile', 'Test-CcmSetupSignature', 'Get-CMLogEntry', 'Resolve-Client')))
        function Get-XMLConfigClientShare { '' }
        function Get-XMLConfigMPHttps { $false }
        function Enable-Tls12 { }
        function Initialize-SecureDirectory { param($Path) $true }
        function New-ClientInstalledReason { param($Log, $Message) $Log.ClientInstalledReason = $Message }
        function Test-CCMSetup1 { }
        function Add-Finding { param($Log, $Text) }
    }

    BeforeEach {
        $script:OriginalProgramData = $env:ProgramData
        $env:ProgramData = $TestDrive
        Mock Get-Process { $null } -ParameterFilter { $Name -eq 'ccmsetup' }
        Mock Start-Process { }
    }

    AfterEach { $env:ProgramData = $script:OriginalProgramData }

    It 'Returns false instead of exiting when no management point is configured' {
        function Get-XMLConfigManagementPoints { @() }
        $log = [pscustomobject]@{ ClientInstalledReason = $null }
        Resolve-Client -ClientInstallProperties 'SMSSITECODE=ABC' -Log $log -ErrorAction SilentlyContinue | Should -BeFalse
        $log.ClientInstalledReason | Should -Match 'no management point'
        Should -Invoke Start-Process -Times 0
    }

    It 'Refuses an unsigned download and does not start it' {
        function Get-XMLConfigManagementPoints { @('mp01.contoso.com') }
        Mock Invoke-WebRequest { Set-Content -Path $OutFile -Value 'not a binary' }
        $log = [pscustomobject]@{ ClientInstalledReason = $null }
        Resolve-Client -ClientInstallProperties 'SMSSITECODE=ABC' -Log $log -ErrorAction SilentlyContinue 3>$null | Should -BeFalse
        Should -Invoke Start-Process -Times 0
        Test-Path (Join-Path $TestDrive 'ConfigMgrClientHealth\ccmsetup\ccmsetup.exe') | Should -BeFalse
    }

    It 'Returns false when ccmsetup is already running' {
        Mock Get-Process { [pscustomobject]@{ Name = 'ccmsetup' } } -ParameterFilter { $Name -eq 'ccmsetup' }
        function Get-XMLConfigManagementPoints { @('mp01.contoso.com') }
        Resolve-Client -ClientInstallProperties 'SMSSITECODE=ABC' 3>$null | Should -BeFalse
        Should -Invoke Start-Process -Times 0
    }
}

Describe 'CI remediation and staging' {
    It 'CI-Remediation starts the health run in a scheduled task instead of running it inline' {
        # The client stops a compliance script after ScriptExecutionTimeout (60 s by default).
        $remediation = Join-Path $PSScriptRoot '..\Deploy\CI-Remediation.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($remediation, [ref]$null, [ref]$null)
        $commands = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        $commands | Should -Contain 'Register-ScheduledTask'
        $commands | Should -Contain 'Start-ScheduledTask'
        $inline = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq 'Ampersand' }, $true)
        @($inline).Count | Should -Be 0
    }

    It 'Deploy-ClientHealthPackage stages nothing when config.json is missing' {
        $source = Join-Path $TestDrive 'pkgsrc'
        New-Item -ItemType Directory -Path $source | Out-Null
        Copy-Item (Join-Path $PSScriptRoot '..\Deploy\Deploy-ClientHealthPackage.ps1') $source
        Set-Content -Path (Join-Path $source 'ConfigMgrClientHealth.ps1') -Value '# new script'
        $programData = Join-Path $TestDrive 'pd2'
        New-Item -ItemType Directory -Path $programData | Out-Null

        $savedProgramData = $env:ProgramData
        try {
            $env:ProgramData = $programData
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $source 'Deploy-ClientHealthPackage.ps1') 2>$null | Out-Null
            $exitCode = $LASTEXITCODE
        }
        finally { $env:ProgramData = $savedProgramData }

        $exitCode | Should -Be 1
        Test-Path (Join-Path $programData 'ConfigMgrClientHealth') | Should -BeFalse
    }
}

Describe 'Local database check' {
    It 'Test-CcmSQLCELog never stops the client, deletes files, or requests a reinstall' {
        # Current clients write CcmSQLCE.log during normal operation; acting on it uninstalls healthy clients.
        $body = (Get-FunctionSource 'Test-CcmSQLCELog') | Out-String
        $body | Should -Not -Match 'Remove-Item|Stop-Service|\.Stop\(\)'
        . ([scriptblock]::Create($body))
        function Get-CCMLogDirectory { $TestDrive }
        Set-Content -Path (Join-Path $TestDrive 'CcmSQLCE.log') -Value 'x'
        (Get-Item (Join-Path $TestDrive 'CcmSQLCE.log')).CreationTime = (Get-Date).AddDays(-30)
        Test-CcmSQLCELog 3>$null | Should -BeFalse
    }
}

Describe 'Test-Service with a missing service' {
    BeforeAll {
        . ([scriptblock]::Create((Get-FunctionSource 'Test-Service')))
        function Get-OperatingSystem { 'Windows 11 64-Bit' }
    }

    It 'Reports the missing service instead of OK' {
        $log = [pscustomobject]@{ Services = 'OK' }
        Test-Service -Name 'NoSuchService-CHTest' -StartupType 'Automatic' -State 'Running' -Log $log 3>$null 2>$null | Out-Null
        $log.Services | Should -Be 'Missing: NoSuchService-CHTest'
    }
}

Describe 'SQL upsert' {
    It 'Keeps the stored ClientInstalled value when a run sends none' {
        $body = (Get-FunctionSource 'Update-SQL') | Out-String
        $body | Should -Match 'ClientInstalled = COALESCE\(@ClientInstalled, ClientInstalled\)'
    }
}

Describe 'Get-SiteConfig' {
    BeforeAll {
        . ([scriptblock]::Create((Get-FunctionSource 'Get-SiteConfig')))
        function Get-ClientSiteName { 'Branch1' }
    }
    BeforeEach { $script:ResolvedADSite = $null }

    It 'Falls back to Default when the site value is empty' {
        $script:JsonConfig = [pscustomobject]@{ Sites = [pscustomobject]@{
            Branch1 = [pscustomobject]@{ SQLServer = ''; ManagementPoints = @() }
            Default = [pscustomobject]@{ SQLServer = 'sql01'; ManagementPoints = @('mp01.contoso.com') } } }
        Get-SiteConfig -PropertyName 'SQLServer' | Should -Be 'sql01'
        Get-SiteConfig -PropertyName 'ManagementPoints' | Should -Be 'mp01.contoso.com'
    }

    It 'Uses the site value when it is set, including boolean false' {
        $script:JsonConfig = [pscustomobject]@{ Sites = [pscustomobject]@{
            Branch1 = [pscustomobject]@{ SQLServer = 'sql-branch'; MPHttps = $false }
            Default = [pscustomobject]@{ SQLServer = 'sql01'; MPHttps = $true } } }
        Get-SiteConfig -PropertyName 'SQLServer' | Should -Be 'sql-branch'
        Get-SiteConfig -PropertyName 'MPHttps' | Should -BeFalse
    }
}

Describe 'Reboot application command parsing' {
    BeforeAll { . ([scriptblock]::Create((Get-FunctionSource 'Get-RebootApplicationCommand'))) }

    It 'Splits <Line>' -ForEach @(
        @{ Line = '"C:\Program Files\Reboot\app.exe" /a /b'; Execute = 'C:\Program Files\Reboot\app.exe'; Argument = '/a /b' }
        @{ Line = 'C:\Program Files\Reboot\app.exe /a'; Execute = 'C:\Program Files\Reboot\app.exe'; Argument = '/a' }
        @{ Line = 'C:\Tools\app.exe'; Execute = 'C:\Tools\app.exe'; Argument = '' }
        @{ Line = 'shutdown /r /t 600'; Execute = 'shutdown'; Argument = '/r /t 600' }
    ) {
        $command = Get-RebootApplicationCommand -CommandLine $Line
        $command.Execute | Should -Be $Execute
        $command.Argument | Should -Be $Argument
    }

    It 'Returns nothing for an empty setting' {
        Get-RebootApplicationCommand -CommandLine '' | Should -BeNullOrEmpty
    }
}

Describe 'Out-LogFile without a log share' {
    It 'Writes nothing when no share is configured' {
        . ([scriptblock]::Create((Get-FunctionSource 'Out-LogFile')))
        function Get-XMLConfigLoggingShare { '' }
        function Get-LogFileName { throw 'must not be called' }
        { Out-LogFile -Text 'x' -Severity 3 } | Should -Not -Throw
    }
}

Describe 'Exit code' {
    It 'Ends with exit 1 when an install or result upload failed' {
        $text = Get-Content $script:ScriptFile -Raw
        $text | Should -Match 'if \(\$script:FailureCount -gt 0\) \{ exit 1 \}'
        ([regex]::Matches($text, '\$script:FailureCount\+\+')).Count | Should -BeGreaterOrEqual 6
    }
}

Describe 'Get-ConfigOption' {
    BeforeAll { . ([scriptblock]::Create((Get-FunctionSource 'ConvertTo-ConfigBoolean', 'ConvertTo-ConfigInt', 'Get-ConfigOption'))) }
    BeforeEach { $script:JsonConfig = $null; $config = $null; $Xml = $null }

    It 'Reads JSON values and converts them to the type of the default' {
        $script:JsonConfig = [pscustomobject]@{ Options = [pscustomobject]@{ ClientActivity = [pscustomobject]@{ Enable = $false; Days = '14' } } }
        Get-ConfigOption -Name 'ClientActivity' -Property 'Enable' -Default $true | Should -BeFalse
        Get-ConfigOption -Name 'ClientActivity' -Property 'Days' -Default 7 | Should -Be 14
    }

    It 'Returns the default when the option or property is missing' {
        $script:JsonConfig = [pscustomobject]@{ Options = [pscustomobject]@{} }
        Get-ConfigOption -Name 'CcmEvalTask' -Property 'Fix' -Default $true | Should -BeTrue
        $script:JsonConfig = [pscustomobject]@{ }
        Get-ConfigOption -Name 'CcmEvalTask' -Default $true | Should -BeTrue
    }

    It 'Reads XML Option attributes' {
        $config = 'x.xml'
        $Xml = [xml]'<Configuration><Option Name="WindowsUpdateScan" Enable="False" Fix="True" ResetDays="10" /></Configuration>'
        Get-ConfigOption -Name 'WindowsUpdateScan' -Default $true | Should -BeFalse
        Get-ConfigOption -Name 'WindowsUpdateScan' -Property 'ResetDays' -Default 30 | Should -Be 10
        Get-ConfigOption -Name 'Missing' -Property 'Fix' -Default $false | Should -BeFalse
    }
}

Describe 'Set-MonitorOnlyConfig' {
    BeforeAll { . ([scriptblock]::Create((Get-FunctionSource 'Set-MonitorOnlyConfig'))) }

    It 'Turns off every fix in a JSON config' {
        $script:JsonConfig = '{"Client":{"AutoUpgrade":true,"Cache":{"Enable":true,"DeleteOrphanedData":true},"Log":{"Enable":true}},
            "Options":{"BITSCheck":{"Enable":true,"Fix":true},"Drivers":true},
            "Remediation":{"AdminShare":true,"ClientWUAHandler":{"Fix":true,"Days":30}}}' | ConvertFrom-Json
        Set-MonitorOnlyConfig
        $script:JsonConfig.Client.AutoUpgrade | Should -BeFalse
        $script:JsonConfig.Client.Cache.DeleteOrphanedData | Should -BeFalse
        $script:JsonConfig.Options.BITSCheck.Fix | Should -BeFalse
        $script:JsonConfig.Options.BITSCheck.Enable | Should -BeTrue
        # Remediation checks keep running and report through $script:MonitorOnly.
        $script:JsonConfig.Remediation.AdminShare | Should -BeTrue
        $script:JsonConfig.Client.Cache.Enable | Should -BeTrue
    }
}

Describe 'Get-CMLogEntry' {
    BeforeAll { . ([scriptblock]::Create((Get-FunctionSource 'Get-CMLogEntry'))) }

    It 'Returns messages at or after the start time, oldest first' {
        $log = Join-Path $TestDrive 'test.log'
        @(
            '<![LOG[old message]LOG]!><time="08:00:00.000+000" date="09-29-2026" component="X" context="" type="1" thread="1" file="">'
            '<![LOG[new message 0x87D00692]LOG]!><time="10:00:00.000+000" date="09-30-2026" component="X" context="" type="1" thread="1" file="">'
            '<![LOG[newest]LOG]!><time="11:30:00.000+000" date="09-30-2026" component="X" context="" type="1" thread="1" file="">'
        ) | Set-Content -Path $log
        $entries = @(Get-CMLogEntry -LogFile $log -StartTime ([datetime]'2026-09-30 00:00:00'))
        $entries.Count | Should -Be 2
        $entries[0].Message | Should -Be 'new message 0x87D00692'
        $entries[1].Message | Should -Be 'newest'
    }
}

Describe 'Test-WindowsUpdateScan' {
    BeforeAll {
        . ([scriptblock]::Create((Get-FunctionSource 'Get-CMLogEntry', 'Test-WindowsUpdateScan')))
        function Get-CCMLogDirectory { $TestDrive }
        function Add-Finding { param($Log, $Text) $Log.Findings += @($Text) }
        function Test-FixAllowed { param($Name, $Default) $false }
    }

    It 'Classifies scan errors and reports a domain WSUS override' {
        @(
            '<![LOG[Group policy settings were overwritten by a higher authority (Domain Controller) to: Server http://wsus:8530]LOG]!><time="10:00:00.000+000" date="09-30-2026" component="WUAHandler" context="" type="1" thread="1" file="">'
            '<![LOG[OnSearchComplete - Failed to end search job. Error = 0x80244021.]LOG]!><time="10:01:00.000+000" date="09-30-2026" component="WUAHandler" context="" type="3" thread="1" file="">'
            '<![LOG[Scan failed with error = 0x80070002.]LOG]!><time="10:02:00.000+000" date="09-30-2026" component="WUAHandler" context="" type="3" thread="1" file="">'
            '<![LOG[Unable to read existing resultant WUA policy. Error = 0x80070005.]LOG]!><time="10:03:00.000+000" date="09-30-2026" component="WUAHandler" context="" type="3" thread="1" file="">'
        ) | Set-Content -Path (Join-Path $TestDrive 'WUAHandler.log')
        $log = [pscustomobject]@{ Findings = @() }
        Test-WindowsUpdateScan -Log $log -StartTime ([datetime]'2026-09-30')
        $log.Findings | Should -Contain 'Domain Group Policy overrides the WSUS server'
        ($log.Findings -join ';') | Should -Match 'proxy\): 0X80244021'
        ($log.Findings -join ';') | Should -Match 'corrupt Windows Update components\): 0X80070002'
        ($log.Findings -join ';') | Should -Not -Match '0X80070005'
    }
}

Describe 'Test-ClientActivity' {
    BeforeAll {
        . ([scriptblock]::Create((Get-FunctionSource 'Test-ClientActivity')))
        function Get-ConfigOption { param($Name, $Property, $Default) $Default }
        function Get-CCMLogDirectory { $TestDrive }
        function Add-Finding { param($Log, $Text) $Log.Findings += @($Text) }
        function Test-FixAllowed { param($Name, $Default) $true }
        function Invoke-CCMTrigger { param($ScheduleID) }
        Set-Content -Path (Join-Path $TestDrive 'PolicyAgent.log') -Value 'x'
    }

    It 'Reports a missing heartbeat record apart from stale activity' {
        function Get-CimInstance { }
        $log = [pscustomobject]@{ Findings = @() }
        Test-ClientActivity -Log $log
        $log.Findings | Should -Be @('No heartbeat record')
    }
    It 'Reports a stale heartbeat' {
        function Get-CimInstance { [pscustomobject]@{ InventoryActionID = '{00000000-0000-0000-0000-000000000003}'; LastReportDate = (Get-Date).AddDays(-30) } }
        $log = [pscustomobject]@{ Findings = @() }
        Test-ClientActivity -Log $log
        $log.Findings | Should -Be @('No heartbeat activity for 7 days')
    }
}

Describe 'Test-RegistryPolHeader' {
    BeforeAll { . ([scriptblock]::Create((Get-FunctionSource 'Test-RegistryPolHeader'))) }

    It 'Accepts a missing file' {
        Test-RegistryPolHeader -Path (Join-Path $TestDrive 'none.pol') | Should -BeTrue
    }
    It 'Accepts a header-only file' {
        $path = Join-Path $TestDrive 'valid.pol'
        [System.IO.File]::WriteAllBytes($path, [byte[]](0x50,0x52,0x65,0x67,0x01,0x00,0x00,0x00))
        Test-RegistryPolHeader -Path $path | Should -BeTrue
    }
    It 'Rejects an empty file' {
        $path = Join-Path $TestDrive 'empty.pol'
        [System.IO.File]::WriteAllBytes($path, [byte[]]@())
        Test-RegistryPolHeader -Path $path | Should -BeFalse
    }
    It 'Rejects a file without the PReg signature' {
        $path = Join-Path $TestDrive 'bad.pol'
        [System.IO.File]::WriteAllBytes($path, [byte[]](0x00,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x5B,0x00))
        Test-RegistryPolHeader -Path $path | Should -BeFalse
    }
}

Describe 'Test-RegistryPol' {
    BeforeAll {
        . ([scriptblock]::Create((Get-FunctionSource 'Test-RegistryPol', 'ConvertTo-ConfigInt')))
        function Get-CCMLogDirectory { $TestDrive }
        function Get-CMLogEntry { param($LogFile, $StartTime) }
        function Get-WinEvent { }
        function Add-Finding { param($Log, $Text) $Log.Findings += @($Text) }
        function Get-RegistryValue { param($Path, $Name) }
        function Set-RegistryValue { param($Path, $Name, $Value) }
        function Restart-Service { }
        function Invoke-CCMTrigger { param($ScheduleID) }
        function gpupdate.exe { }
    }

    It 'Reports a corrupt registry.pol in monitor mode without a change' {
        function Test-RegistryPolHeader { param($Path) $false }
        $script:MonitorOnly = $true
        $log = [pscustomobject]@{ Findings = @(); WUAHandler = $null }
        Test-RegistryPol -Log $log -Days 7 | Out-Null
        $log.WUAHandler | Should -Be 'Broken (Corrupt registry.pol)'
        $log.Findings | Should -Contain 'registry.pol has no valid header'
        $script:MonitorOnly = $false
    }
    It 'Repairs a corrupt registry.pol' {
        function Test-RegistryPolHeader { param($Path) $false }
        function Move-Item { }
        $log = [pscustomobject]@{ Findings = @(); WUAHandler = $null }
        Test-RegistryPol -Log $log -Days 7 | Out-Null
        $log.WUAHandler | Should -Be 'Repaired (Corrupt registry.pol)'
    }
    It 'Leaves a valid registry.pol alone' {
        function Test-RegistryPolHeader { param($Path) $true }
        $log = [pscustomobject]@{ Findings = @(); WUAHandler = $null }
        Test-RegistryPol -Log $log -Days 7 | Out-Null
        $log.WUAHandler | Should -Be 'OK'
    }
}

Describe 'Test-InstallerCache' {
    BeforeAll {
        . ([scriptblock]::Create((Get-FunctionSource 'Test-InstallerCache')))
        function Add-Finding { param($Log, $Text) $Log.Findings += @($Text) }
        function Test-FixAllowed { param($Name, $Default) $false }
    }

    It 'Reports products whose cached package is missing' {
        function Get-InstalledMsiProduct { param($NamePattern)
            [pscustomobject]@{ Name = 'Microsoft Policy Platform'; Version = '68.1.9099.1053'; LocalPackage = 'C:\Windows\Installer\x.msi'; CacheExists = $false }
            [pscustomobject]@{ Name = 'Configuration Manager Client'; Version = '5.00.9146.1000'; LocalPackage = 'C:\Windows\Installer\y.msi'; CacheExists = $true }
        }
        $log = [pscustomobject]@{ Findings = @() }
        Test-InstallerCache -Log $log
        $log.Findings | Should -Be @('Cached installer missing: Microsoft Policy Platform 68.1.9099.1053')
    }
    It 'Tags the client for a forced reinstall when the client MSI cache is missing' {
        function Test-FixAllowed { param($Name, $Default) $true }
        function New-ClientInstalledReason { param($Log, $Message) $Log.Reason = $Message }
        function Get-InstalledMsiProduct { param($NamePattern)
            [pscustomobject]@{ Name = 'Configuration Manager Client'; Version = '5.00.9146.1000'; LocalPackage = 'C:\Windows\Installer\y.msi'; CacheExists = $false }
        }
        $script:ClientCacheReinstall = $false
        $log = [pscustomobject]@{ Findings = @(); Reason = $null }
        Test-InstallerCache -Log $log
        $script:ClientCacheReinstall | Should -BeTrue
        $log.Reason | Should -Be 'Client installer cache missing.'
        $log.Findings | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-Client command line' {
    BeforeAll {
        . ([scriptblock]::Create((Get-FunctionSource 'Test-ManagementPointName', 'Get-CMLogEntry', 'Resolve-Client')))
        function Get-XMLConfigClientShare { '' }
        function Enable-Tls12 { }
        function Initialize-SecureDirectory { param($Path) $true }
        function New-ClientInstalledReason { param($Log, $Message) }
        function Add-Finding { param($Log, $Text) }
        function Test-CCMSetup1 { }
        function Test-CcmSetupSignature { param($Path) $true }
        function Wait-CcmSetup { param($Activity) $true }
    }

    BeforeEach {
        $script:OriginalProgramData = $env:ProgramData
        $env:ProgramData = $TestDrive
        $script:MonitorOnly = $false
        Mock Get-Process { $null } -ParameterFilter { $Name -eq 'ccmsetup' }
        Mock Invoke-WebRequest { Set-Content -Path $OutFile -Value 'binary' }
        Mock Start-Process { $script:CapturedArguments = $ArgumentList }
        Mock Get-Random { $InputObject }
    }

    AfterEach { $env:ProgramData = $script:OriginalProgramData }

    It 'Puts switches first, lists every MP, and adds /forceinstall for a forced reinstall' {
        function Get-XMLConfigManagementPoints { @('mp01.contoso.com', 'mp02.contoso.com') }
        function Get-XMLConfigMPHttps { $false }
        $Uninstall = $true
        Resolve-Client -ClientInstallProperties 'SMSSITECODE=ABC /skipprereq:x.exe SMSMP=old.contoso.com /mp:old.contoso.com' | Should -BeTrue
        $captured = [string[]]@($script:CapturedArguments)
        $captured[0] | Should -Be '/mp:mp01.contoso.com;mp02.contoso.com'
        $captured | Should -Contain '/skipprereq:x.exe'
        $captured | Should -Contain '/forceinstall'
        $captured | Should -Contain 'SMSMP=mp01.contoso.com'
        $captured | Should -Contain 'SMSMPLIST=mp01.contoso.com;mp02.contoso.com'
        $captured | Should -Not -Contain 'SMSMP=old.contoso.com'
        $switchIndexes = @(0..($captured.Count - 1) | Where-Object { $captured[$_].StartsWith('/') })
        $propertyIndexes = @(0..($captured.Count - 1) | Where-Object { -not $captured[$_].StartsWith('/') })
        ($switchIndexes | Measure-Object -Maximum).Maximum | Should -BeLessThan ($propertyIndexes | Measure-Object -Minimum).Minimum
    }

    It 'Prefixes SMSMP with https:// when the MP uses HTTPS' {
        function Get-XMLConfigManagementPoints { @('mp01.contoso.com') }
        function Get-XMLConfigMPHttps { $true }
        $Uninstall = $false
        Resolve-Client -ClientInstallProperties 'SMSSITECODE=ABC' | Should -BeTrue
        @($script:CapturedArguments) | Should -Contain 'SMSMP=https://mp01.contoso.com'
        @($script:CapturedArguments) | Should -Not -Contain '/forceinstall'
    }

    It 'Does nothing on a device excluded from remediation' {
        function Get-XMLConfigManagementPoints { @('mp01.contoso.com') }
        $script:MonitorOnly = $true
        Resolve-Client -ClientInstallProperties 'SMSSITECODE=ABC' | Should -BeFalse
        Should -Invoke Start-Process -Times 0
    }
}
