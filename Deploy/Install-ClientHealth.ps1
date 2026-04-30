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
            BITSCheck             = [ordered]@{ Enable = $true; Fix = $true }
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
        }
        Services               = @(
            [ordered]@{ Name = 'BITS';         StartupType = 'Automatic (Delayed Start)'; State = 'Running'; Uptime = '' }
            [ordered]@{ Name = 'winmgmt';      StartupType = 'Automatic';                 State = 'Running'; Uptime = '' }
            [ordered]@{ Name = 'wuauserv';     StartupType = 'Automatic (Delayed Start)'; State = 'Running'; Uptime = '' }
            [ordered]@{ Name = 'lanmanserver'; StartupType = 'Automatic';                 State = 'Running'; Uptime = '' }
            [ordered]@{ Name = 'RpcSs';        StartupType = 'Automatic';                 State = 'Running'; Uptime = '' }
            [ordered]@{ Name = 'W32Time';      StartupType = 'Automatic';                 State = 'Running'; Uptime = '' }
            [ordered]@{ Name = 'ccmexec';      StartupType = 'Automatic (Delayed Start)'; State = 'Running'; Uptime = '' }
        )
        Remediation            = [ordered]@{
            AdminShare             = $true
            ClientProvisioningMode = $true
            ClientStateMessages    = $true
            ClientWUAHandler       = [ordered]@{ Fix = $true; Days = 30 }
            ClientCertificate      = $true
        }
        Sites                  = [ordered]@{ Default = [ordered]@{} }
    }

    $json = $config | ConvertTo-Json -Depth 5
    Set-Content -Path $OutputFile -Value $json -Encoding UTF8 -Force
    return $OutputFile
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

    $sqlContent = Get-Content -Path $SqlScriptPath -Raw
    # Split on GO statements for batch execution
    $batches = $sqlContent -split '(?m)^\s*GO\s*$' | Where-Object { $_.Trim() -ne '' }

    foreach ($batch in $batches) {
        Invoke-Sqlcmd -ServerInstance $SqlServer -Query $batch -ErrorAction Stop
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
    Invoke-Sqlcmd -ServerInstance $SqlServer -Query $grantSql -ErrorAction Stop
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

    $isLocal = ($server -eq $env:COMPUTERNAME) -or ($server -eq 'localhost') -or ($server -eq '.')
    if (-not $isLocal) {
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
        $dpGroups = Get-CMDistributionPointGroup
        foreach ($dpg in $dpGroups) {
            Start-CMContentDistribution -PackageId $pkg.PackageID `
                -DistributionPointGroupName $dpg.Name -ErrorAction SilentlyContinue
        }
        Write-Host "  Content distributed to $($dpGroups.Count) DP group(s)" -ForegroundColor Green

        # ── Configuration Item ──
        Write-Host '  Creating Configuration Item...' -ForegroundColor Gray
        $ciName = 'ConfigMgr Client Health - Compliance'
        $ci = Get-CMConfigurationItem -Name $ciName -Fast -ErrorAction SilentlyContinue
        if (-not $ci) {
            $ci = New-CMConfigurationItem -Name $ciName `
                -Description 'Detects whether ConfigMgr Client Health has run within the last 7 days and remediates if not.' `
                -CreationType WindowsOS

            # Add discovery + remediation scripts with inline compliance rule
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
                -Remediate

            Write-Host "  CI created: $ciName" -ForegroundColor Green
        }
        else {
            Write-Host "  CI already exists: $ciName" -ForegroundColor Yellow
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
        $existingDeployment = Get-CMBaselineDeployment -Name $cbName -ErrorAction SilentlyContinue |
            Where-Object { $_.CollectionName -eq $TargetCollection }
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
        New-CMPackageDeployment -PackageId $pkg.PackageID `
            -ProgramName 'Deploy' `
            -CollectionName $TargetCollection `
            -StandardProgram `
            -DeployPurpose Required `
            -FastNetworkOption DownloadContentFromDistributionPointAndRunLocally `
            -SlowNetworkOption DownloadContentFromDistributionPointAndLocally `
            -RerunBehavior RerunIfFailedPreviousAttempt `
            -Schedule (New-CMSchedule -RecurInterval Days -RecurCount 7) `
            -ErrorAction SilentlyContinue | Out-Null
        Write-Host "  Package deployment created" -ForegroundColor Green
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
    $settings.ConnectionStrings.ClientHealth = "Server=$SqlServer;Database=ClientHealth;Trusted_Connection=True;TrustServerCertificate=True;"
    $settings | ConvertTo-Json -Depth 5 | Set-Content $appSettings -Encoding UTF8 -Force

    $isLocal = ($TargetServer -eq $env:COMPUTERNAME) -or ($TargetServer -eq 'localhost')
    $installPath = "C:\Program Files\ClientHealthApi"

    if ($isLocal) {
        # Local install
        if (-not (Test-Path $installPath)) {
            New-Item -Path $installPath -ItemType Directory -Force | Out-Null
        }
        Copy-Item -Path "$publishDir\*" -Destination $installPath -Recurse -Force

        # Install as Windows Service
        $svcName = 'ClientHealthApi'
        $existing = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if (-not $existing) {
            $exePath = Join-Path $installPath 'ClientHealthApi.exe'
            & sc.exe create $svcName binPath= "`"$exePath`" --urls=http://*:$Port" start= delayed-auto 2>&1 | Out-Null
            & sc.exe description $svcName "ConfigMgr Client Health REST API" 2>&1 | Out-Null
            Start-Service -Name $svcName
            Write-Host "  Service '$svcName' installed and started on port $Port" -ForegroundColor Green
        }
        else {
            Write-Host "  Service '$svcName' already exists" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "  Published files are in: $publishDir" -ForegroundColor Green
        Write-Host "  Copy them to $TargetServer and run:" -ForegroundColor Yellow
        Write-Host "    sc.exe create ClientHealthApi binPath= `"C:\Program Files\ClientHealthApi\ClientHealthApi.exe --urls=http://*:$Port`" start= delayed-auto" -ForegroundColor Yellow
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

    try { New-FileShare -UncPath $LogSharePath -Description 'ConfigMgr Client Health - Logs' -ChangeAccess 'Everyone' }
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
