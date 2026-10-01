<#
.SYNOPSIS
    Interactive setup wizard for ConfigMgr Client Health.

.DESCRIPTION
    Guided walkthrough that collects environment-specific settings, generates a
    ready-to-deploy source directory, creates the ClientHealth SQL database, and
    provisions all MECM objects (Package, Program, Configuration Item,
    Configuration Baseline, and optionally the API webservice).

    Run this once on an admin workstation that has the ConfigurationManager
    PowerShell module available (MECM admin console installed).

.EXAMPLE
    .\Install-ClientHealth.ps1

.EXAMPLE
    # Non-interactive for automation / testing:
    .\Install-ClientHealth.ps1 -SiteCode 'MCM' -SiteServer 'sccm01.contoso.com' `
        -Domain 'contoso.com' -ManagementPoints 'sccm01.contoso.com','sccm02.contoso.com' `
        -SqlServer 'sccmdbs.contoso.com' -ClientSharePath '\\fileshare\ClientHealth$' `
        -LogSharePath '\\fileshare\ClientHealthLogs$' -TargetCollection 'All Systems' `
        -ClientVersion '5.00.9128.1007'

.NOTES
    Requires: ConfigurationManager PowerShell module, SqlServer module (for DB creation),
    admin rights on target file server (for share creation).
#>

[CmdletBinding()]
param(
    [string]$SiteCode,
    [string]$SiteServer,
    [string]$Domain,
    [string[]]$ManagementPoints,
    [bool]$MPHttps = $false,
    [string]$SqlServer,
    [string]$SqlAccessPrincipal,
    [string]$ClientSharePath,
    [string]$LogSharePath,
    [string]$TargetCollection = 'All Systems',
    [string]$ClientVersion,
    [switch]$InstallWebservice,
    [string]$WebserviceServer,
    [int]$WebservicePort = 5000,
    [string]$SourceRoot,
    [string]$OutputPath
)

#region ── Helper Functions ──────────────────────────────────────────────────

function Write-Banner {
    param([string]$Text)
    $line = '=' * 60
    Write-Host ''
    Write-Host $line -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
    Write-Host ''
}

function Read-ValidatedHost {
    <#
    .SYNOPSIS
        Prompts the user and validates the response. Loops until valid.
    #>
    param(
        [string]$Prompt,
        [string]$Default,
        [scriptblock]$Validate,
        [string]$ErrorMessage = 'Invalid input. Please try again.'
    )
    while ($true) {
        $display = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
        $answer = Read-Host $display
        if ([string]::IsNullOrWhiteSpace($answer) -and $Default) { $answer = $Default }
        if ([string]::IsNullOrWhiteSpace($answer)) {
            Write-Host "  A value is required." -ForegroundColor Yellow
            continue
        }
        if ($Validate) {
            $result = & $Validate $answer
            if ($result -eq $true) { return $answer }
            Write-Host "  $ErrorMessage" -ForegroundColor Yellow
        }
        else { return $answer }
    }
}

function Test-ServerReachable {
    param([string]$Server)
    try { $null = Test-Connection -ComputerName $Server -Count 1 -Quiet -ErrorAction Stop; return $true }
    catch { return $false }
}

function Test-SqlConnection {
    <#
    .SYNOPSIS
        Validates SQL Server connectivity using a lightweight .NET connection test.
    #>
    param([string]$Server)
    try {
        $conn = New-Object System.Data.SqlClient.SqlConnection
        $conn.ConnectionString = "Server=$Server;Database=master;Trusted_Connection=True;Connect Timeout=5;"
        $conn.Open()
        $conn.Close()
        return $true
    }
    catch { return $false }
}

function Test-PortNumber {
    param([string]$Value)

    $port = 0
    return [int]::TryParse($Value, [ref]$port) -and $port -gt 0 -and $port -le 65535
}

function Test-ManagementPointName {
    param(
        [string]$Value,
        [switch]$RequireFqdn
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $hostName = $Value.Trim()
    if ($hostName -notmatch '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$') { return $false }
    if ($hostName -match '\.\.') { return $false }
    if ($RequireFqdn -and $hostName -notmatch '\.') { return $false }
    return $true
}

function Test-IsLocalComputer {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $candidate = $Name.Trim().TrimEnd('.')
    $localNames = @($env:COMPUTERNAME, 'localhost', '.', '127.0.0.1', '::1')
    try { $localNames += [System.Net.Dns]::GetHostEntry('localhost').HostName } catch { }
    try { $localNames += [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName } catch { }
    if ($env:USERDNSDOMAIN) { $localNames += "$env:COMPUTERNAME.$env:USERDNSDOMAIN" }
    return ($localNames | Where-Object { $_ -and ($_ -eq $candidate) }).Count -gt 0
}

function Get-DefaultLogWriterPrincipal {
    if ($env:USERDOMAIN -and $env:USERDOMAIN -ne $env:COMPUTERNAME) {
        return "$env:USERDOMAIN\Domain Computers"
    }

    return 'NT AUTHORITY\Authenticated Users'
}

function Get-DefaultSqlAccessPrincipal {
    if ($env:USERDOMAIN -and $env:USERDOMAIN -ne $env:COMPUTERNAME) {
        return "$env:USERDOMAIN\Domain Computers"
    }

    return ''
}

function New-ClientHealthConfig {
    <#
    .SYNOPSIS
        Generates a config.json populated with the collected environment values.
    #>
    param(
        [Parameter(Mandatory)][string]$SiteCode,
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string[]]$ManagementPoints,
        [Parameter(Mandatory)][string]$SqlServer,
        [Parameter(Mandatory)][string]$LogSharePath,
        [Parameter(Mandatory)][string]$ClientVersion,
        [bool]$MPHttps = $false,
        [Parameter(Mandatory)][string]$OutputFile
    )

    $ManagementPoints = @(
        $ManagementPoints | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($ManagementPoints.Count -eq 0) {
        throw 'At least one Management Point is required.'
    }
    foreach ($mp in $ManagementPoints) {
        if (-not (Test-ManagementPointName -Value $mp -RequireFqdn)) {
            throw "Invalid Management Point '$mp'. Use a fully qualified domain name."
        }
    }

    $primaryMp = $ManagementPoints[0]

    $config = [ordered]@{
        LocalFiles             = 'C:\ProgramData\ConfigMgrClientHealth'
        Client                 = [ordered]@{
            Version          = $ClientVersion
            SiteCode         = $SiteCode
            Domain           = $Domain
            AutoUpgrade      = $true
            ManagementPoints = @($ManagementPoints)
            MPHttps          = $MPHttps
            Cache            = [ordered]@{ Size = 16384; DeleteOrphanedData = $true; Enable = $true }
            Log              = [ordered]@{ MaxSize = 4096; MaxHistory = 2; Enable = $true }
        }
        ClientInstallProperties = @(
            "SMSSITECODE=$SiteCode",
            "FSP=$primaryMp",
            "DNSSUFFIX=$Domain"
        )
        Logging                = [ordered]@{
            Share        = $LogSharePath
            Level        = 'Full'
            MaxHistory   = 8
            LocalLogFile = $true
            FileEnabled  = $true
            TimeFormat   = 'ClientLocal'
            SQL          = [ordered]@{ Server = $SqlServer; Enabled = $true }
        }
        Options                = [ordered]@{
            CcmSQLCELog          = $false
            BITSCheck             = [ordered]@{ Enable = $true; Fix = $true; Days = 7 }
            ClientSettingsCheck   = [ordered]@{ Enable = $true; Fix = $true }
            DNSCheck              = [ordered]@{ Enable = $true; Fix = $true }
            Drivers               = $true
            PatchLevel            = $true
            Updates               = [ordered]@{ Share = ''; Enable = $false; Fix = $true }
            PendingReboot         = [ordered]@{ Enable = $true; StartRebootApplication = $false }
            RebootApplication     = [ordered]@{ Enable = $false; Application = '' }
            MaxRebootDays         = 7
            OSDiskFreeSpace       = 10
            HardwareInventory     = [ordered]@{ Enable = $true; Fix = $true; Days = 10 }
            SoftwareMetering      = [ordered]@{ Enable = $true; Fix = $true }
            WMI                   = [ordered]@{ Enable = $true; Fix = $true }
            RefreshComplianceState = [ordered]@{ Enable = $true; Days = 30 }
            CcmEvalTask           = [ordered]@{ Enable = $true; Fix = $true }
            ClientActivity        = [ordered]@{ Enable = $true; Fix = $true; Days = 7 }
            WindowsUpdateSource   = [ordered]@{ Enable = $true; Fix = $true }
            WindowsUpdateScan     = [ordered]@{ Enable = $true; Fix = $false; ResetDays = 30 }
            TlsConfiguration      = [ordered]@{ Enable = $true; Fix = $false }
            CoManagement          = [ordered]@{ Enable = $true }
            SecureChannel         = [ordered]@{ Enable = $true }
            ScriptPolicy          = [ordered]@{ Enable = $true }
            SiteCommunication     = [ordered]@{ Enable = $true }
            PkiCertificate        = [ordered]@{ Enable = $false; Days = 30 }
            ClientIdentity        = [ordered]@{ Enable = $true }
            DeliveryOptimization  = [ordered]@{ Enable = $true }
            InstallerCache        = [ordered]@{ Enable = $true; Fix = $true }
            VCRuntime             = [ordered]@{ Enable = $true; Fix = $true }
        }
        Services               = @(
            [ordered]@{ Name = 'BITS';         StartupType = 'Manual|Automatic|Automatic (Delayed Start)'; State = ''; Uptime = '' }
            [ordered]@{ Name = 'winmgmt';      StartupType = 'Automatic';                 State = 'Running'; Uptime = '' }
            [ordered]@{ Name = 'wuauserv';     StartupType = 'Manual|Automatic|Automatic (Delayed Start)'; State = ''; Uptime = '' }
            [ordered]@{ Name = 'lanmanserver'; StartupType = 'Automatic';                 State = 'Running'; Uptime = '' }
            [ordered]@{ Name = 'RpcSs';        StartupType = 'Automatic';                 State = 'Running'; Uptime = '' }
            [ordered]@{ Name = 'W32Time';      StartupType = 'Automatic';                 State = 'Running'; Uptime = '' }
            [ordered]@{ Name = 'ccmexec';      StartupType = 'Automatic (Delayed Start)'; State = 'Running'; Uptime = '' }
        )
        Remediation            = [ordered]@{
            AdminShare             = $true
            ClientProvisioningMode = $true
            ClientStateMessages    = $true
            ClientWUAHandler       = [ordered]@{ Fix = $true; Days = 7 }
            ClientCertificate      = $true
        }
        Sites                  = [ordered]@{ Default = [ordered]@{} }
    }

    $json = $config | ConvertTo-Json -Depth 5
    Set-Content -Path $OutputFile -Value $json -Encoding UTF8 -Force
    return $OutputFile
}

function Get-SqlScriptBatch {
    <#
    .SYNOPSIS
        Splits a SQL script on GO and returns each batch with the database it must run in.
    .NOTES
        Every Invoke-Sqlcmd call opens a new session, so a USE statement does not carry over to
        the next batch. The USE target is tracked here and passed as -Database instead.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $database = 'master'
    $content = Get-Content -Path $Path -Raw
    foreach ($batch in ($content -split '(?m)^\s*GO\s*$')) {
        $useMatches = [regex]::Matches($batch, '(?im)^\s*USE\s+\[?(?<db>[A-Za-z0-9_]+)\]?\s*;?\s*$')
        if ($useMatches.Count -gt 0) { $database = $useMatches[$useMatches.Count - 1].Groups['db'].Value }
        $query = [regex]::Replace($batch, '(?im)^\s*USE\s+\[?[A-Za-z0-9_]+\]?\s*;?\s*$', '')

        $code = [regex]::Replace($query, '(?m)--.*$', '').Trim()
        if ($code -eq '') { continue }

        [pscustomobject]@{ Database = $database; Query = $query }
    }
}

function New-ClientHealthDatabase {
    <#
    .SYNOPSIS
        Executes CreateDatabase.sql against the target SQL Server.
    #>
    param(
        [Parameter(Mandatory)][string]$SqlServer,
        [Parameter(Mandatory)][string]$SqlScriptPath,
        [string]$AccessPrincipal = (Get-DefaultSqlAccessPrincipal)
    )

    if (-not (Get-Module -ListAvailable -Name SqlServer) -and
        -not (Get-Module -ListAvailable -Name SQLPS)) {
        throw "Neither SqlServer nor SQLPS module is available. Install the SqlServer module: Install-Module SqlServer"
    }

    $moduleName = if (Get-Module -ListAvailable -Name SqlServer) { 'SqlServer' } else { 'SQLPS' }
    Import-Module $moduleName -ErrorAction Stop

    $sqlArgs = @{ ServerInstance = $SqlServer; ErrorAction = 'Stop' }
    # SqlServer module 22+ encrypts by default and rejects a self-signed server certificate.
    if ((Get-Command Invoke-Sqlcmd).Parameters.ContainsKey('TrustServerCertificate')) { $sqlArgs.TrustServerCertificate = $true }

    foreach ($batch in (Get-SqlScriptBatch -Path $SqlScriptPath)) {
        Invoke-Sqlcmd @sqlArgs -Database $batch.Database -Query $batch.Query
    }

    if ([string]::IsNullOrWhiteSpace($AccessPrincipal)) {
        throw "SQL access principal is required. Use a domain group such as 'CONTOSO\Domain Computers'."
    }

    # Grant client computer access
    $principalName = $AccessPrincipal.Replace("'", "''")
    $principalIdentifier = $AccessPrincipal.Replace(']', ']]')
    $grantSql = @"
USE ClientHealth;
IF NOT EXISTS (SELECT * FROM sys.server_principals WHERE name = N'$principalName')
    CREATE LOGIN [$principalIdentifier] FROM WINDOWS;
IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = N'$principalName')
    CREATE USER [$principalIdentifier] FOR LOGIN [$principalIdentifier];
IF IS_ROLEMEMBER('db_datareader', N'$principalName') = 0
    ALTER ROLE db_datareader ADD MEMBER [$principalIdentifier];
IF IS_ROLEMEMBER('db_datawriter', N'$principalName') = 0
    ALTER ROLE db_datawriter ADD MEMBER [$principalIdentifier];
"@
    Invoke-Sqlcmd @sqlArgs -Database 'master' -Query $grantSql
}

function New-FileShare {
    <#
    .SYNOPSIS
        Creates a local directory and SMB share if they don't exist.
        Only works on the local machine. For remote shares, validates the path exists.
    #>
    param(
        [Parameter(Mandatory)][string]$UncPath,
        [string]$Description = 'ConfigMgr Client Health',
        [string[]]$ReadAccess = @('Everyone'),
        [string[]]$ChangeAccess = @()
    )

    # Parse \\server\share from UNC
    if ($UncPath -notmatch '^\\\\([^\\]+)\\([^\\]+)') {
        throw "Invalid UNC path: $UncPath"
    }
    $server = $Matches[1]
    $shareName = $Matches[2]

    # If it already exists, we're done
    if (Test-Path $UncPath) {
        Write-Host "  Share already accessible: $UncPath" -ForegroundColor Green
        return
    }

    if (-not (Test-IsLocalComputer -Name $server)) {
        throw "Share $UncPath does not exist and cannot be created remotely. Create the share on $server first, then re-run."
    }

    # Create local directory under C:\Shares\<shareName>
    $localDir = "C:\Shares\$shareName"
    if (-not (Test-Path $localDir)) {
        New-Item -Path $localDir -ItemType Directory -Force | Out-Null
        Write-Host "  Created directory: $localDir" -ForegroundColor Green
    }

    if ($ChangeAccess.Count -gt 0) {
        $acl = Get-Acl -Path $localDir
        foreach ($principal in $ChangeAccess) {
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $principal,
                'Modify',
                'ContainerInherit,ObjectInherit',
                'None',
                'Allow'
            )
            $acl.SetAccessRule($rule)
        }
        Set-Acl -Path $localDir -AclObject $acl
    }

    # Create SMB share
    $existingShare = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
    if (-not $existingShare) {
        $shareParams = @{
            Name        = $shareName
            Path        = $localDir
            Description = $Description
            FullAccess  = 'Administrators'
        }
        if ($ChangeAccess.Count -gt 0) { $shareParams.ChangeAccess = $ChangeAccess }
        elseif ($ReadAccess.Count -gt 0) { $shareParams.ReadAccess = $ReadAccess }

        New-SmbShare @shareParams | Out-Null
        Write-Host "  Created share: \\$env:COMPUTERNAME\$shareName" -ForegroundColor Green
    }
}

function Copy-SourceFiles {
    <#
    .SYNOPSIS
        Copies the health check script, generated config, and deploy scripts to
        the client share so the CM Package can distribute them.
    #>
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$ConfigFile
    )

    if (-not (Test-Path $TargetPath)) {
        New-Item -Path $TargetPath -ItemType Directory -Force | Out-Null
    }

    # Core files
    $mainScript = Join-Path $SourceRoot 'ConfigMgrClientHealth.ps1'
    $deployScript = Join-Path $SourceRoot 'Deploy\Deploy-ClientHealthPackage.ps1'

    if (-not (Test-Path $mainScript)) { throw "Main script not found: $mainScript" }

    Copy-Item -Path $mainScript -Destination $TargetPath -Force
    Copy-Item -Path $ConfigFile -Destination (Join-Path $TargetPath 'config.json') -Force
    if (Test-Path $deployScript) {
        Copy-Item -Path $deployScript -Destination $TargetPath -Force
    }

    Write-Host "  Source files copied to: $TargetPath" -ForegroundColor Green
}

function New-MECMObjects {
    <#
    .SYNOPSIS
        Creates the MECM Package, Program, CI, Baseline, and deployments.
    #>
    param(
        [Parameter(Mandatory)][string]$SiteCode,
        [Parameter(Mandatory)][string]$SiteServer,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$TargetCollection,
        [Parameter(Mandatory)][string]$DetectionScript,
        [Parameter(Mandatory)][string]$RemediationScript
    )

    # Import CM module
    $cmModule = Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH -Parent) 'ConfigurationManager.psd1'
    if (-not (Test-Path $cmModule)) {
        throw "ConfigurationManager module not found. Is the MECM admin console installed?"
    }
    Import-Module $cmModule -ErrorAction Stop

    # Switch to CM drive
    $cmDrive = "${SiteCode}:"
    if (-not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer | Out-Null
    }
    $originalLocation = Get-Location
    Set-Location $cmDrive

    try {
        # ── Package + Program ──
        Write-Host '  Creating CM Package...' -ForegroundColor Gray
        $pkg = Get-CMPackage -Name 'ConfigMgr Client Health' -Fast -ErrorAction SilentlyContinue
        if (-not $pkg) {
            $pkg = New-CMPackage -Name 'ConfigMgr Client Health' `
                -Description 'Stages ConfigMgr Client Health script and config to endpoints' `
                -Path $SourcePath
            Write-Host "  Package created: $($pkg.PackageID)" -ForegroundColor Green
        }
        else {
            Write-Host "  Package already exists: $($pkg.PackageID)" -ForegroundColor Yellow
            # Without this, re-running the wizard copies new files to the source share but DPs keep the old content.
            Update-CMDistributionPoint -PackageId $pkg.PackageID -ErrorAction Stop
            Write-Host '  Distribution points updated with current package source' -ForegroundColor Green
        }

        $program = Get-CMProgram -PackageId $pkg.PackageID -ProgramName 'Deploy' -ErrorAction SilentlyContinue
        if (-not $program) {
            New-CMProgram -PackageId $pkg.PackageID `
                -StandardProgramName 'Deploy' `
                -CommandLine 'powershell.exe -ExecutionPolicy Bypass -File Deploy-ClientHealthPackage.ps1' `
                -RunType Hidden `
                -ProgramRunType WhetherOrNotUserIsLoggedOn `
                -RunMode RunWithAdministrativeRights | Out-Null
            Write-Host '  Program "Deploy" created' -ForegroundColor Green
        }

        # Distribute to all DPs
        Write-Host '  Distributing content to all DP groups...' -ForegroundColor Gray
        $dpGroups = @(Get-CMDistributionPointGroup)
        if ($dpGroups.Count -eq 0) {
            Write-Warning '  No distribution point groups exist. Distribute the package manually.'
        }
        foreach ($dpg in $dpGroups) {
            try {
                Start-CMContentDistribution -PackageId $pkg.PackageID -DistributionPointGroupName $dpg.Name -ErrorAction Stop
                Write-Host "  Content distributed to DP group: $($dpg.Name)" -ForegroundColor Green
            }
            catch {
                # Expected on re-run: content is already targeted to this group.
                Write-Host "  DP group '$($dpg.Name)': $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        # ── Configuration Item ──
        Write-Host '  Creating Configuration Item...' -ForegroundColor Gray
        $ciName = 'ConfigMgr Client Health - Compliance'
        $ci = Get-CMConfigurationItem -Name $ciName -Fast -ErrorAction SilentlyContinue
        if (-not $ci) {
            $ci = New-CMConfigurationItem -Name $ciName `
                -Description 'Detects whether ConfigMgr Client Health has run within the last 7 days and remediates if not.' `
                -CreationType WindowsOS -ErrorAction Stop

            # Add discovery + remediation scripts with inline compliance rule.
            # A CI without its setting is never non-compliant, and a re-run would skip it as existing.
            try {
                Add-CMComplianceSettingScript -InputObject $ci `
                    -Name 'ClientHealth LastRun Check' `
                    -DataType Boolean `
                    -DiscoveryScriptLanguage PowerShell `
                    -DiscoveryScriptText $DetectionScript `
                    -RemediationScriptLanguage PowerShell `
                    -RemediationScriptText $RemediationScript `
                    -Is64Bit `
                    -ValueRule `
                    -RuleName 'ClientHealth ran within 7 days' `
                    -ExpectedValue 'True' `
                    -ExpressionOperator IsEquals `
                    -ReportNoncompliance `
                    -Remediate `
                    -ErrorAction Stop | Out-Null
            }
            catch {
                Remove-CMConfigurationItem -Id $ci.CI_ID -Force -ErrorAction SilentlyContinue
                throw "Could not add the compliance script to '$ciName'; the CI was removed. $($_.Exception.Message)"
            }

            Write-Host "  CI created: $ciName" -ForegroundColor Green
        }
        else {
            Set-CMComplianceSettingScript -InputObject $ci -SettingName 'ClientHealth LastRun Check' `
                -DiscoveryScriptLanguage PowerShell -DiscoveryScriptText $DetectionScript `
                -RemediationScriptLanguage PowerShell -RemediationScriptText $RemediationScript `
                -Is64Bit $true -ErrorAction Stop | Out-Null
            Write-Host "  CI already exists: $ciName (detection and remediation scripts updated)" -ForegroundColor Yellow
        }

        # ── Configuration Baseline ──
        Write-Host '  Creating Configuration Baseline...' -ForegroundColor Gray
        $cbName = 'ConfigMgr Client Health'
        $cb = Get-CMBaseline -Name $cbName -ErrorAction SilentlyContinue
        if (-not $cb) {
            $cb = New-CMBaseline -Name $cbName `
                -Description 'Ensures ConfigMgr Client Health runs on a regular schedule via CI remediation.'

            Set-CMBaseline -Name $cbName -AddOSConfigurationItem $ci.CI_ID

            Write-Host "  Baseline created: $cbName" -ForegroundColor Green
        }
        else {
            Write-Host "  Baseline already exists: $cbName" -ForegroundColor Yellow
        }

        # ── Deploy Baseline ──
        Write-Host "  Deploying baseline to '$TargetCollection'..." -ForegroundColor Gray
        # SMS_BaselineAssignment has TargetCollectionID but no CollectionName property; filtering the
        # returned objects on CollectionName matches nothing and creates a duplicate deployment.
        $existingDeployment = Get-CMBaselineDeployment -Name $cbName -CollectionName $TargetCollection -Fast -ErrorAction SilentlyContinue
        if (-not $existingDeployment) {
            New-CMBaselineDeployment -Name $cbName `
                -CollectionName $TargetCollection `
                -EnableEnforcement $true `
                -GenerateAlert $false `
                -MonitoredByScom $false `
                -ParameterValue 1 `
                -PostponeDateTime (Get-Date).AddHours(1) `
                -Schedule (New-CMSchedule -RecurInterval Days -RecurCount 1) | Out-Null
            Write-Host "  Baseline deployed to: $TargetCollection" -ForegroundColor Green
        }
        else {
            Write-Host "  Baseline deployment already exists for: $TargetCollection" -ForegroundColor Yellow
        }

        # ── Deploy Package ──
        Write-Host "  Deploying package to '$TargetCollection'..." -ForegroundColor Gray
        $existingPackageDeployment = Get-CMPackageDeployment -PackageId $pkg.PackageID -CollectionName $TargetCollection -ErrorAction SilentlyContinue
        if ($existingPackageDeployment) {
            # A deployment that reruns only after a failure leaves clients on the old staged files.
            # The program only copies files, so it may run outside maintenance windows.
            Set-CMPackageDeployment -PackageId $pkg.PackageID -StandardProgramName 'Deploy' `
                -CollectionName $TargetCollection -RerunBehavior AlwaysRerunProgram -SoftwareInstallation $true -ErrorAction Stop
            Write-Host "  Package deployment already exists for: $TargetCollection (rerun always, runs outside maintenance windows)" -ForegroundColor Yellow
        }
        else {
            # The weekly recurrence must restage changed config. The program only copies files,
            # so it may run outside maintenance windows.
            New-CMPackageDeployment -PackageId $pkg.PackageID `
                -ProgramName 'Deploy' `
                -CollectionName $TargetCollection `
                -StandardProgram `
                -DeployPurpose Required `
                -FastNetworkOption DownloadContentFromDistributionPointAndRunLocally `
                -SlowNetworkOption DownloadContentFromDistributionPointAndLocally `
                -RerunBehavior AlwaysRerunProgram `
                -SoftwareInstallation $true `
                -Schedule (New-CMSchedule -RecurInterval Days -RecurCount 7) `
                -ErrorAction Stop | Out-Null
            Write-Host "  Package deployment created" -ForegroundColor Green
        }
    }
    finally {
        Set-Location $originalLocation
    }
}

function Install-ClientHealthWebservice {
    <#
    .SYNOPSIS
        Publishes the API webservice and installs it as a Windows Service.
    #>
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$TargetServer,
        [Parameter(Mandatory)][string]$SqlServer,
        [int]$Port = 5000
    )

    $projectPath = Join-Path $SourceRoot 'Webservice\ClientHealthApi\ClientHealthApi.csproj'
    if (-not (Test-Path $projectPath)) {
        throw "Webservice project not found: $projectPath"
    }

    $publishDir = Join-Path $SourceRoot 'Webservice\ClientHealthApi\publish'

    # Build self-contained publish
    Write-Host '  Publishing webservice...' -ForegroundColor Gray
    & dotnet publish $projectPath -c Release -o $publishDir --self-contained -r win-x64 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE" }
    Write-Host '  Published to: publish/' -ForegroundColor Green

    # Update appsettings.json with real connection string
    $appSettings = Join-Path $publishDir 'appsettings.json'
    $settings = Get-Content $appSettings -Raw | ConvertFrom-Json
    # Microsoft.Data.SqlClient encrypts by default. Validate the SQL certificate when this machine trusts it;
    # fall back to TrustServerCertificate only for a self-signed SQL certificate.
    $validatedConnection = "Server=$SqlServer;Database=ClientHealth;Trusted_Connection=True;Encrypt=True;TrustServerCertificate=False;"
    $probe = New-Object System.Data.SqlClient.SqlConnection("Server=$SqlServer;Database=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=False;Connect Timeout=10;")
    try {
        $probe.Open()
        $settings.ConnectionStrings.ClientHealth = $validatedConnection
        Write-Host '  SQL certificate validated; the API connection checks it' -ForegroundColor Green
    }
    catch {
        $settings.ConnectionStrings.ClientHealth = "Server=$SqlServer;Database=ClientHealth;Trusted_Connection=True;Encrypt=True;TrustServerCertificate=True;"
        Write-Warning "  SQL certificate on $SqlServer is not trusted by this machine. The API encrypts but does not validate the certificate. Install a trusted certificate on SQL Server and set TrustServerCertificate=False in appsettings.json."
    }
    finally { $probe.Dispose() }
    $settings | ConvertTo-Json -Depth 5 | Set-Content $appSettings -Encoding UTF8 -Force

    $installPath = "C:\Program Files\ClientHealthApi"
    $svcName = 'ClientHealthApi'
    $binaryPath = "`"$(Join-Path $installPath 'ClientHealthApi.exe')`" --urls=http://*:$Port"

    if (Test-IsLocalComputer -Name $TargetServer) {
        # Local install
        if (-not (Test-Path $installPath)) {
            New-Item -Path $installPath -ItemType Directory -Force | Out-Null
        }
        $existing = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($existing -and $existing.Status -ne 'Stopped') { Stop-Service -Name $svcName -Force -ErrorAction Stop }
        Copy-Item -Path "$publishDir\*" -Destination $installPath -Recurse -Force

        # New-Service passes the path unchanged; sc.exe binPath= with embedded quotes is mangled by Windows PowerShell 5.1.
        if (-not $existing) {
            New-Service -Name $svcName -BinaryPathName $binaryPath -DisplayName 'ConfigMgr Client Health API' `
                -Description 'ConfigMgr Client Health REST API' -StartupType Automatic -ErrorAction Stop | Out-Null
            & sc.exe config $svcName start= delayed-auto | Out-Null
            Write-Host "  Service '$svcName' installed" -ForegroundColor Green
        }
        else {
            # Win32_Service.Change takes the path unchanged; a re-run with another port must update --urls.
            $serviceInstance = Get-CimInstance -ClassName Win32_Service -Filter "Name='$svcName'"
            $change = Invoke-CimMethod -InputObject $serviceInstance -MethodName Change -Arguments @{ PathName = $binaryPath }
            if ($change.ReturnValue -ne 0) { throw "Could not update the service path (Win32_Service.Change returned $($change.ReturnValue))." }
            Write-Host "  Service '$svcName' already exists; binaries and path updated" -ForegroundColor Yellow
        }

        $ruleName = "ConfigMgr Client Health API (TCP $Port)"
        Get-NetFirewallRule -DisplayName 'ConfigMgr Client Health API (TCP *)' -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -ne $ruleName } |
            ForEach-Object {
                Remove-NetFirewallRule -Name $_.Name -ErrorAction Stop
                Write-Host "  Firewall rule removed: $($_.DisplayName)" -ForegroundColor Yellow
            }
        if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Domain -ErrorAction Stop | Out-Null
            Write-Host "  Firewall rule created: $ruleName" -ForegroundColor Green
        }

        Start-Service -Name $svcName -ErrorAction Stop
        Write-Host "  Service '$svcName' running on port $Port" -ForegroundColor Green
    }
    else {
        Write-Host "  Published files are in: $publishDir" -ForegroundColor Green
        Write-Host "  Copy them to '$installPath' on $TargetServer, then run there:" -ForegroundColor Yellow
        Write-Host "    New-Service -Name $svcName -BinaryPathName '$binaryPath' -StartupType Automatic" -ForegroundColor Yellow
        Write-Host "    New-NetFirewallRule -DisplayName 'ConfigMgr Client Health API (TCP $Port)' -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Domain" -ForegroundColor Yellow
        Write-Host "    Start-Service $svcName" -ForegroundColor Yellow
    }
}

#endregion

#region ── Main Wizard Flow ──────────────────────────────────────────────────

function Start-ClientHealthWizard {
    <#
    .SYNOPSIS
        Orchestrates the full interactive setup. Called when no parameters are
        provided, or can be called directly for testing with splatted params.
    #>
    param(
        [string]$SiteCode,
        [string]$SiteServer,
        [string]$Domain,
        [string[]]$ManagementPoints,
        [bool]$MPHttps = $false,
        [string]$SqlServer,
        [string]$SqlAccessPrincipal,
        [string]$ClientSharePath,
        [string]$LogSharePath,
        [string]$TargetCollection = 'All Systems',
        [string]$ClientVersion,
        [switch]$InstallWebservice,
        [string]$WebserviceServer,
        [int]$WebservicePort = 5000,
        [string]$SourceRoot,
        [string]$OutputPath
    )

    $interactive = [string]::IsNullOrWhiteSpace($SiteCode)
    if (-not $SourceRoot) {
        $SourceRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        # If running from Deploy/, go up one level
        if (Test-Path (Join-Path $PSScriptRoot '..\ConfigMgrClientHealth.ps1')) {
            $SourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        }
    }

    if ($interactive) {
        Write-Banner 'ConfigMgr Client Health - Setup Wizard'
        Write-Host '  This wizard will configure your environment for Client Health.' -ForegroundColor Gray
        Write-Host '  Each value is validated before proceeding.' -ForegroundColor Gray
        Write-Host ''

        # ── Phase 1: Gather info ──
        Write-Banner 'Phase 1: Environment Settings'

        $SiteCode = Read-ValidatedHost -Prompt 'MECM Site Code (3 chars)' `
            -Validate { param($v) $v -match '^[A-Za-z0-9]{3}$' } `
            -ErrorMessage 'Site code must be exactly 3 alphanumeric characters.'

        $SiteServer = Read-ValidatedHost -Prompt 'SMS Provider / Site Server FQDN' `
            -Validate { param($v) $v -match '\.' } `
            -ErrorMessage 'Please provide a fully qualified domain name.'

        $Domain = Read-ValidatedHost -Prompt 'Domain' `
            -Default ($SiteServer -replace '^[^.]+\.','') `
            -Validate { param($v) $v -match '\.' } `
            -ErrorMessage 'Domain should contain at least one dot (e.g. contoso.com).'

        $mpInput = Read-ValidatedHost -Prompt 'Management Point FQDN(s) - comma-separated for multi-MP' `
            -Default $SiteServer `
            -Validate { param($v) $items = @($v -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }); $items.Count -gt 0 -and (($items | Where-Object { -not (Test-ManagementPointName -Value $_ -RequireFqdn) }).Count -eq 0) } `
            -ErrorMessage 'Each MP must be a fully qualified domain name.'
        $ManagementPoints = @($mpInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

        $httpsAnswer = Read-ValidatedHost -Prompt 'Download ccmsetup.exe over HTTPS? (y/n)' `
            -Default 'n' `
            -Validate { param($v) $v -match '^[yn]$' } `
            -ErrorMessage 'Enter y or n.'
        $MPHttps = ($httpsAnswer -eq 'y')

        $SqlServer = Read-ValidatedHost -Prompt 'SQL Server for ClientHealth database' `
            -Default $SiteServer `
            -Validate { param($v) Test-SqlConnection $v } `
            -ErrorMessage 'Cannot connect to SQL Server. Verify the server name and that your account has access.'

        $SqlAccessPrincipal = Read-ValidatedHost -Prompt 'SQL principal for client database writes' `
            -Default (Get-DefaultSqlAccessPrincipal) `
            -Validate { param($v) $v -match '^[^\\]+\\[^\\]+$' } `
            -ErrorMessage 'Use DOMAIN\Group format, for example CONTOSO\Domain Computers.'

        $ClientSharePath = Read-ValidatedHost -Prompt 'Client share UNC path (e.g. \\server\ClientHealth$)' `
            -Validate { param($v) $v -match '^\\\\[^\\]+\\[^\\]+' } `
            -ErrorMessage 'Must be a valid UNC path (\\server\share).'

        $LogSharePath = Read-ValidatedHost -Prompt 'Log share UNC path (e.g. \\server\ClientHealthLogs$)' `
            -Validate { param($v) $v -match '^\\\\[^\\]+\\[^\\]+' } `
            -ErrorMessage 'Must be a valid UNC path (\\server\share).'

        $TargetCollection = Read-ValidatedHost -Prompt 'Target collection for baseline deployment' `
            -Default 'All Systems'

        $ClientVersion = Read-ValidatedHost -Prompt 'Minimum CM client version (e.g. 5.00.9128.1007)' `
            -Validate { param($v) $v -match '^\d+\.\d+\.\d+\.\d+$' } `
            -ErrorMessage 'Version must be in format X.XX.XXXX.XXXX.'

        # Webservice prompt
        $wsAnswer = Read-ValidatedHost -Prompt 'Install API webservice? (y/n)' `
            -Default 'n' `
            -Validate { param($v) $v -match '^[yn]$' } `
            -ErrorMessage 'Enter y or n.'
        $InstallWebservice = ($wsAnswer -eq 'y')

        if ($InstallWebservice) {
            $WebserviceServer = Read-ValidatedHost -Prompt 'Webservice target server' `
                -Default $SiteServer
            $portStr = Read-ValidatedHost -Prompt 'Webservice port' `
                -Default '5000' `
                -Validate { param($v) Test-PortNumber $v } `
                -ErrorMessage 'Must be a valid port number (1-65535).'
            $WebservicePort = [int]$portStr
        }

        # ── Confirm ──
        Write-Banner 'Review Settings'
        Write-Host "  Site Code:          $SiteCode"
        Write-Host "  Site Server:        $SiteServer"
        Write-Host "  Domain:             $Domain"
        Write-Host "  Management Points:  $([string]::Join(', ', $ManagementPoints))"
        Write-Host "  MP Scheme:          $(if ($MPHttps) { 'HTTPS' } else { 'HTTP' })"
        Write-Host "  SQL Server:         $SqlServer"
        Write-Host "  SQL Access:         $SqlAccessPrincipal"
        Write-Host "  Client Share:       $ClientSharePath"
        Write-Host "  Log Share:          $LogSharePath"
        Write-Host "  Target Collection:  $TargetCollection"
        Write-Host "  Client Version:     $ClientVersion"
        Write-Host "  Webservice:         $(if ($InstallWebservice) { "$WebserviceServer`:$WebservicePort" } else { 'No' })"
        Write-Host ''

        $confirm = Read-ValidatedHost -Prompt 'Proceed with installation? (y/n)' `
            -Validate { param($v) $v -match '^[yn]$' } `
            -ErrorMessage 'Enter y or n.'
        if ($confirm -ne 'y') {
            Write-Host 'Installation cancelled.' -ForegroundColor Yellow
            return
        }
    }

    if (-not $interactive) {
        # The interactive prompts validate each value; parameters bypass the prompts. A bad site code or
        # domain in config.json makes Test-ConfigValues throw on every client.
        $problems = @()
        if ($SiteCode -notmatch '\A[A-Za-z0-9]{3}\z') { $problems += "SiteCode '$SiteCode' must be exactly 3 alphanumeric characters." }
        if ($Domain -notmatch '\A[A-Za-z0-9.-]+\z' -or $Domain -notmatch '\.') { $problems += "Domain '$Domain' must be a DNS domain name." }
        if ($ClientVersion -notmatch '\A\d+\.\d+\.\d+\.\d+\z') { $problems += "ClientVersion '$ClientVersion' must be in format X.XX.XXXX.XXXX." }
        if ([string]::IsNullOrWhiteSpace($SqlServer)) { $problems += 'SqlServer is required.' }
        if ($LogSharePath -notmatch '\A\\\\[^\\]+\\[^\\]+') { $problems += "LogSharePath '$LogSharePath' must be a UNC path." }
        if ($ClientSharePath -notmatch '\A\\\\[^\\]+\\[^\\]+') { $problems += "ClientSharePath '$ClientSharePath' must be a UNC path." }
        if ($problems.Count -gt 0) { throw ("Invalid parameters:`n  " + ($problems -join "`n  ")) }
    }

    # ── Phase 2: Generate config.json ──
    Write-Banner 'Phase 2: Generating config.json'
    if (-not $OutputPath) { $OutputPath = Join-Path $SourceRoot 'Deploy\Output' }
    if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }

    $configFile = Join-Path $OutputPath 'config.json'
    New-ClientHealthConfig -SiteCode $SiteCode -Domain $Domain `
        -ManagementPoints $ManagementPoints -SqlServer $SqlServer `
        -LogSharePath $LogSharePath -ClientVersion $ClientVersion `
        -MPHttps:$MPHttps -OutputFile $configFile
    Write-Host "  Config generated: $configFile" -ForegroundColor Green

    # ── Phase 3: Create database ──
    Write-Banner 'Phase 3: Creating ClientHealth Database'
    if (-not $SqlAccessPrincipal) { $SqlAccessPrincipal = Get-DefaultSqlAccessPrincipal }
    $sqlScript = Join-Path $SourceRoot 'CreateDatabase.sql'
    if (Test-Path $sqlScript) {
        try {
            New-ClientHealthDatabase -SqlServer $SqlServer -SqlScriptPath $sqlScript -AccessPrincipal $SqlAccessPrincipal
            Write-Host '  Database created/updated successfully' -ForegroundColor Green
        }
        catch {
            Write-Warning "  Database creation failed: $_"
            Write-Warning '  You may need to run CreateDatabase.sql manually.'
        }
    }
    else {
        Write-Warning "  CreateDatabase.sql not found at $sqlScript - skipping."
    }

    # ── Phase 4: Create shares and copy files ──
    Write-Banner 'Phase 4: File Shares and Source Files'
    try { New-FileShare -UncPath $ClientSharePath -Description 'ConfigMgr Client Health - Client Files' }
    catch { Write-Warning "  Client share: $_" }

    try { New-FileShare -UncPath $LogSharePath -Description 'ConfigMgr Client Health - Logs' -ChangeAccess (Get-DefaultLogWriterPrincipal) }
    catch { Write-Warning "  Log share: $_" }

    Copy-SourceFiles -SourceRoot $SourceRoot -TargetPath $ClientSharePath -ConfigFile $configFile

    # ── Phase 5: Create MECM objects ──
    Write-Banner 'Phase 5: MECM Integration'
    $detectionScript = Get-Content (Join-Path $SourceRoot 'Deploy\CI-Detection.ps1') -Raw
    $remediationScript = Get-Content (Join-Path $SourceRoot 'Deploy\CI-Remediation.ps1') -Raw

    try {
        New-MECMObjects -SiteCode $SiteCode -SiteServer $SiteServer `
            -SourcePath $ClientSharePath -TargetCollection $TargetCollection `
            -DetectionScript $detectionScript -RemediationScript $remediationScript
    }
    catch {
        Write-Warning "  MECM object creation failed: $_"
        Write-Warning '  Ensure the MECM admin console is installed and you have Full Administrator rights.'
    }

    # ── Phase 6: Webservice (optional) ──
    if ($InstallWebservice) {
        Write-Banner 'Phase 6: API Webservice'
        try {
            Install-ClientHealthWebservice -SourceRoot $SourceRoot `
                -TargetServer $WebserviceServer -SqlServer $SqlServer -Port $WebservicePort
        }
        catch {
            Write-Warning "  Webservice installation failed: $_"
            Write-Warning '  Ensure .NET SDK is installed for publishing.'
        }
    }

    # ── Summary ──
    Write-Banner 'Installation Complete'
    Write-Host '  Created:' -ForegroundColor Green
    Write-Host "    - config.json:    $configFile"
    Write-Host "    - Client share:   $ClientSharePath"
    Write-Host "    - Log share:      $LogSharePath"
    Write-Host "    - SQL database:   ClientHealth on $SqlServer"
    Write-Host "    - SQL access:     $SqlAccessPrincipal"
    Write-Host "    - CM Package:     ConfigMgr Client Health"
    Write-Host "    - CI:             ConfigMgr Client Health - Compliance"
    Write-Host "    - Baseline:       ConfigMgr Client Health"
    Write-Host "    - Deployed to:    $TargetCollection"
    if ($InstallWebservice) {
        Write-Host "    - Webservice:     http://${WebserviceServer}:${WebservicePort}/"
    }
    Write-Host ''
    Write-Host '  Next steps:' -ForegroundColor Cyan
    Write-Host '    1. Verify content distribution completed in the MECM console'
    Write-Host '    2. Monitor baseline compliance in Monitoring > Deployments'
    Write-Host '    3. Check client logs at: %ProgramData%\ConfigMgrClientHealth\'
    if ($LogSharePath) {
        Write-Host "    4. Review centralized logs at: $LogSharePath"
    }
}

#endregion

# ── Entry point ─────────────────────────────────────────────────────────────
# Guard: skip execution when dot-sourced for testing
if ($MyInvocation.InvocationName -ne '.') {
    $wizardParams = @{}
    foreach ($key in @('SiteCode','SiteServer','Domain','ManagementPoints','MPHttps','SqlServer','SqlAccessPrincipal',
                       'ClientSharePath','LogSharePath','TargetCollection','ClientVersion',
                       'InstallWebservice','WebserviceServer','WebservicePort','SourceRoot','OutputPath')) {
        $val = Get-Variable -Name $key -ValueOnly -ErrorAction SilentlyContinue
        if ($val) { $wizardParams[$key] = $val }
    }

    Start-ClientHealthWizard @wizardParams
}
