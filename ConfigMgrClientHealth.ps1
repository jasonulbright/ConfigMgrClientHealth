<#
.SYNOPSIS
    ConfigMgr Client Health is a tool that validates and automatically fixes errors on Windows computers managed by Microsoft Configuration Manager.
.EXAMPLE
   .\ConfigMgrClientHealth.ps1 -Config .\config.json
.EXAMPLE
    .\ConfigMgrClientHealth.ps1 -Config .\config.json -Webservice http://sccm01:5000
.PARAMETER Config
    Path to the configuration file (.json or .xml).
.PARAMETER Webservice
    A single parameter specifying the URI to the ConfigMgr Client Health Webservice.
.DESCRIPTION
    ConfigMgr Client Health detects and fixes following errors:
        * ConfigMgr client is not installed.
        * ConfigMgr client is assigned the correct site code.
        * ConfigMgr client is upgraded to current version if not at specified minimum version.
        * ConfigMgr client not able to forward state messages to management point.
        * ConfigMgr client stuck in provisioning mode.
        * ConfigMgr client maximum log file size.
        * ConfigMgr client cache size.
        * Corrupt WMI.
        * Services for ConfigMgr client is not running or disabled.
        * Other services can be specified to start and run and specific state.
        * Hardware inventory is running at correct schedule
        * Group Policy failes to update registry.pol
        * Pending reboot blocking updates from installing
        * ConfigMgr Client Update Handler is working correctly with registry.pol
        * Windows Update Agent not working correctly, causing client not to receive patches.
        * Windows Update Agent missing patches that fixes known bugs.
.NOTES
    You should run this with at least local administrator rights. It is recommended to run this script under the SYSTEM context.

    DO NOT GIVE USERS WRITE ACCESS TO THIS FILE. LOCK IT DOWN !

    Author: Anders Rødland
    Blog: https://www.andersrodland.com
    Twitter: @AndersRodland
.LINK
    Full documentation: https://www.andersrodland.com/configmgr-client-health/
#>

[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="Medium")]
param(
    [Parameter(HelpMessage='Path to JSON or XML configuration file')]
    [ValidatePattern('\.(xml|json)$')]
    [string]$Config,
    [Parameter(HelpMessage='URI to ConfigMgr Client Health Webservice')]
    [string]$Webservice
)

Begin {
    # ConfigMgr Client Health Version
    $Version = '0.8.4'
    $script:JsonConfig = $null
    $script:ConfigRawToCache = $null
    $script:ClientReinstalledThisRun = $false
    $script:FailureCount = 0
    $script:MonitorOnly = $false
    $script:WsusDomainPolicyOverride = $false
    $script:VCRuntimeCacheBroken = @()
    $script:ClientCacheReinstall = $false
    $global:ScriptPath = split-path -parent $MyInvocation.MyCommand.Definition

    #If no config file was passed in, use the default.
    If (!$PSBoundParameters.ContainsKey('Config')) {
        # Prefer config.json if it exists, otherwise fall back to Config.xml
        $jsonDefault = Join-Path ($global:ScriptPath) "config.json"
        $xmlDefault = Join-Path ($global:ScriptPath) "Config.xml"
        if (Test-Path $jsonDefault) {
            $Config = $jsonDefault
        } else {
            $Config = $xmlDefault
        }
        Write-Verbose "No config provided, defaulting to $Config"
    }

    Write-Verbose "Script version: $Version"
    Write-Verbose "PowerShell version: $($PSVersionTable.PSVersion)"

    # Retry helper for transient failures (SQL connections, service starts)
    Function Invoke-WithRetry {
        Param(
            [Parameter(Mandatory=$true)][scriptblock]$ScriptBlock,
            [int]$MaxRetries = 3,
            [int]$DelaySeconds = 5,
            [string]$OperationName = 'Operation'
        )
        for ($i = 1; $i -le $MaxRetries; $i++) {
            try { return (& $ScriptBlock) }
            catch {
                if ($i -eq $MaxRetries) { throw }
                Write-Warning "$OperationName failed (attempt $i/$MaxRetries): $_. Retrying in ${DelaySeconds}s..."
                Start-Sleep -Seconds $DelaySeconds
            }
        }
    }

    # A directory is trusted only when it is a real directory owned by SYSTEM or Administrators,
    # with a protected DACL that grants access to SYSTEM and Administrators only.
    # Standard users can create folders under ProgramData, so an existing folder proves nothing.
    Function Test-TrustedDirectory {
        Param([Parameter(Mandatory=$true)][string]$Path)

        $trustedSids = @('S-1-5-18', 'S-1-5-32-544')
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
        try {
            $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $false }
            $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
            $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
            if ($trustedSids -notcontains $owner) { return $false }
            if (-not $acl.AreAccessRulesProtected) { return $false }
            foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
                if ($rule.AccessControlType -ne 'Allow') { continue }
                if ($trustedSids -notcontains $rule.IdentityReference.Value) { return $false }
            }
            return $true
        }
        catch { return $false }
    }

    # Deletes without following reparse points. Remove-Item -Recurse on Windows PowerShell 5.1
    # can descend into a junction and delete the target's contents.
    Function Remove-PathNoFollow {
        Param([Parameter(Mandatory=$true)][string]$Path)

        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $isReparsePoint = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        if ($item.PSIsContainer) {
            if (-not $isReparsePoint) {
                foreach ($child in [System.IO.Directory]::GetFileSystemEntries($Path)) { Remove-PathNoFollow -Path $child }
            }
            [System.IO.Directory]::Delete($Path, $false)
        }
        else {
            [System.IO.File]::SetAttributes($Path, [System.IO.FileAttributes]::Normal)
            [System.IO.File]::Delete($Path)
        }
    }

    # A folder owned by SYSTEM or Administrators is secured in place: it can hold the staged script
    # that the CI remediation runs, so it must not move. Items inside it that another account owns,
    # and reparse points, are deleted. A folder owned by another account is renamed and recreated.
    Function Initialize-SecureDirectory {
        Param([Parameter(Mandatory=$true)][string]$Path)

        $trustedSids = @('S-1-5-18', 'S-1-5-32-544')
        try {
            if (-not (Test-TrustedDirectory -Path $Path)) {
                if (Test-Path -LiteralPath $Path) {
                    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
                    $owner = (Get-Acl -LiteralPath $Path -ErrorAction Stop).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
                    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or ($trustedSids -notcontains $owner)) {
                        $quarantine = "$Path.untrusted-$([guid]::NewGuid().ToString('N'))"
                        [System.IO.Directory]::Move($Path, $quarantine)
                        Write-Warning "Untrusted folder '$Path' was renamed to '$quarantine'."
                    }
                }
                if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null }

                $acl = New-Object System.Security.AccessControl.DirectorySecurity
                $acl.SetAccessRuleProtection($true, $false)
                foreach ($sid in $trustedSids) {
                    $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
                    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
                    $acl.AddAccessRule($rule)
                }
                Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop

                # An administrator whose default owner policy is "object creator" owns a new folder personally.
                $currentOwner = (Get-Acl -LiteralPath $Path -ErrorAction Stop).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
                if ($trustedSids -notcontains $currentOwner) {
                    $ownerAcl = Get-Acl -LiteralPath $Path -ErrorAction Stop
                    $ownerAcl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
                    Set-Acl -LiteralPath $Path -AclObject $ownerAcl -ErrorAction Stop
                }
            }

            # A trusted folder can still hold an item that another account owns. Copy-Item -Force keeps the
            # owner and ACL of a file it overwrites, so a redeploy alone does not restore trust.
            $pending =New-Object System.Collections.Generic.Queue[string]
            $pending.Enqueue($Path)
            while ($pending.Count -gt 0) {
                foreach ($entry in [System.IO.Directory]::GetFileSystemEntries($pending.Dequeue())) {
                    $child = Get-Item -LiteralPath $entry -Force -ErrorAction Stop
                    $childOwner = (Get-Acl -LiteralPath $entry -ErrorAction Stop).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
                    if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or ($trustedSids -notcontains $childOwner)) {
                        Write-Warning "Removing untrusted item '$entry'."
                        Remove-PathNoFollow -Path $entry
                    }
                    elseif ($child.PSIsContainer) { $pending.Enqueue($entry) }
                }
            }
        }
        catch {
            Write-Warning "Could not secure folder '$Path': $($_.Exception.Message)"
            return $false
        }
        return (Test-TrustedDirectory -Path $Path)
    }

    Function Read-CachedJsonConfig {
        Param([Parameter(Mandatory=$true)][string]$CachePath)

        if (-not (Test-Path -LiteralPath $CachePath -PathType Leaf)) { return $null }
        if (-not (Test-TrustedDirectory -Path (Split-Path $CachePath -Parent))) {
            Write-Warning "Cached config at '$CachePath' is in an untrusted folder and is ignored."
            return $null
        }
        try { return (Get-Content -LiteralPath $CachePath -Raw -ErrorAction Stop | ConvertFrom-Json) }
        catch { return $null }
    }

    Function Save-ConfigCache {
        Param(
            [Parameter(Mandatory=$true)][string]$CachePath,
            [Parameter(Mandatory=$true)][string]$Content
        )

        $cacheDir = Split-Path $CachePath -Parent
        if (-not (Initialize-SecureDirectory -Path $cacheDir)) { return }
        try {
            $tempPath = "$CachePath.tmp"
            Set-Content -LiteralPath $tempPath -Value $Content -Encoding UTF8 -Force -ErrorAction Stop
            Move-Item -LiteralPath $tempPath -Destination $CachePath -Force -ErrorAction Stop
            Write-Verbose "Config cached to $CachePath"
        }
        catch { Write-Verbose "Could not cache config: $_" }
    }

    Function Test-XML {
        <#
        .SYNOPSIS
        Test the validity of an XML file
        #>
        [CmdletBinding()]
        param ([parameter(mandatory=$true)][ValidateNotNullorEmpty()][string]$xmlFilePath)
        # Check the file exists
        if (!(Test-Path -Path $xmlFilePath)) { throw "$xmlFilePath is not valid. Please provide a valid path to the .xml config file" }
        # Check for Load or Parse errors when loading the XML file
        $xml = New-Object System.Xml.XmlDocument
        try {
            $xml.Load((Get-ChildItem -Path $xmlFilePath).FullName)
            return $true
        }
        catch [System.Xml.XmlException] {
            Write-Error "$xmlFilePath : $($_.toString())"
            Write-Error "Configuration file $Config is NOT valid XML. Script will not execute."
            return $false
        }
    }

    # Read configuration from file (JSON or XML)
    $ConfigCachePath = Join-Path $env:ProgramData 'ConfigMgrClientHealth\config.json.cache'

    if ($config) {
        if (Test-Path $Config) {
            if ($Config -match '\.json$') {
                # Load JSON config. The cache is written only after Test-ConfigValues passes.
                Try {
                    $configRaw = Get-Content -Path $Config -Raw -ErrorAction Stop
                    $script:JsonConfig = $configRaw | ConvertFrom-Json -ErrorAction Stop
                    $script:ConfigRawToCache = $configRaw
                    Write-Verbose "JSON configuration loaded from $Config"
                }
                Catch {
                    $ErrorMessage = $_.Exception.Message
                    $script:JsonConfig = Read-CachedJsonConfig -CachePath $ConfigCachePath
                    if ($script:JsonConfig) {
                        Write-Warning "Could not read '$Config' ($ErrorMessage). Using cached config from $ConfigCachePath"
                    }
                    else {
                        $text = "Error, could not read $Config. Check file location and share/ntfs permissions. Is JSON config file damaged?"
                        $text += "`nError message: $ErrorMessage"
                        Write-Error $text
                        Exit 1
                    }
                }
            }
            else {
                # Test if valid XML
                if ((Test-XML -xmlFilePath $Config) -ne $true ) { Exit 1 }

                # Load XML file into variable
                Try { $Xml = [xml](Get-Content -Path $Config) }
                Catch {
                    $ErrorMessage = $_.Exception.Message
                    $text = "Error, could not read $Config. Check file location and share/ntfs permissions. Is XML config file damaged?"
                    $text += "`nError message: $ErrorMessage"
                    Write-Error $text
                    Exit 1
                }
            }
        }
        elseif (($Config -match '\.json$') -and (Test-Path $ConfigCachePath)) {
            # Network config unreachable - fall back to cached copy
            $script:JsonConfig = Read-CachedJsonConfig -CachePath $ConfigCachePath
            if ($script:JsonConfig) {
                Write-Warning "Config file '$Config' not accessible. Using cached config from $ConfigCachePath"
            }
            else {
                Write-Error "Config file '$Config' not accessible and cached config is missing, corrupt, or untrusted."
                Exit 1
            }
        }
        else {
            $text = "Error, could not access $Config. Check file location and share/ntfs permissions. Did you misspell the name?"
            Write-Error $text
            Exit 1
        }
    }


    # Import Modules
    # Import BitsTransfer Module (Does not work on PowerShell Core (6), disable check if module failes to import.)
    $BitsCheckEnabled = $false
    if (Get-Module -ListAvailable -Name BitsTransfer) {
		try {
			Import-Module BitsTransfer -ErrorAction stop
			$BitsCheckEnabled = $true
		}
		catch { $BitsCheckEnabled = $false }
	}

    #region functions
    Function Get-DateTime {
        $format = ([string](Get-XMLConfigLoggingTimeFormat)).ToLower()

        # UTC Time
        if ($format -like "utc") { $obj = ([DateTime]::UtcNow).ToString("yyyy-MM-dd HH:mm:ss") }
        # ClientLocal
        else { $obj = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }

        Write-Output $obj
    }

    # Converts a DateTime object to UTC time.
    Function Get-UTCTime {
        param([Parameter(Mandatory=$true)][DateTime]$DateTime)
        $obj = $DateTime.ToUniversalTime()
        Write-Output $obj
    }

    Function Get-Hostname {
        <#
        if ($PowerShellVersion -ge 6) { $Obj = (Get-CimInstance Win32_ComputerSystem).Name }
        else { $Obj = (Get-WmiObject Win32_ComputerSystem).Name }
        #>
        $obj = $env:COMPUTERNAME
        Write-Output $Obj
    }

    # Update-WebService use ClientHealth Webservice to update database. RESTful API.
    # Windows PowerShell 5.1 on older .NET defaults can omit TLS 1.2.
    Function Enable-Tls12 {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        }
        catch { Write-Verbose "Could not enable TLS 1.2: $_" }
    }

    Function Update-Webservice {
        Param([Parameter(Mandatory=$true)][String]$URI, $Log)

        Test-ValuesBeforeLogUpdate
        # Invoke-RestMethod on Windows PowerShell 5.1 encodes a string body as ISO-8859-1; the API reads UTF-8.
        $Body = [System.Text.Encoding]::UTF8.GetBytes(($Log | ConvertTo-Json))
        $ApiUri = "$($URI.TrimEnd('/'))/api/Clients"
        $ContentType = "application/json; charset=utf-8"
        Enable-Tls12

        # POST with UPSERT - the API handles create-or-update
        try {
            Invoke-WithRetry -OperationName 'Webservice POST' -ScriptBlock {
                Invoke-RestMethod -Method POST -Uri $ApiUri -Body $Body -ContentType $ContentType -UseDefaultCredentials -UseBasicParsing | Out-Null
            }
            Write-Verbose "Webservice updated successfully"
        }
        catch {
            $ExceptionMessage = $_.Exception.Message
            Write-Warning "Error updating webservice at $ApiUri : $ExceptionMessage"
            $script:FailureCount++
            Out-LogFile -Xml $Xml -Text "ERROR Webservice POST: $ExceptionMessage" -Severity 3
            if ($LocalLogging -like 'true') { Out-LogFile -Xml $Xml -Text "ERROR Webservice POST: $ExceptionMessage" -Mode 'Local' -Severity 3 }
        }
    }

    Function Get-LogFileName {
        #$OS = Get-WmiObject -class Win32_OperatingSystem
        #$OSName = Get-OperatingSystem
        $logshare = Get-XMLConfigLoggingShare
        #$obj = "$logshare\$OSName\$env:computername.log"
        $obj = "$logshare\$env:computername.log"
        Write-Output $obj
    }

    Function Get-ServiceUpTime {
        param([Parameter(Mandatory=$true)]$Name)

        Try{$ServiceDisplayName = (Get-Service $Name).DisplayName}
        Catch{
            Write-Warning "The '$($Name)' service could not be found."
            Return
        }

        #First try and get the service start time based on the last start event message in the system log.
        Try{
            [datetime]$ServiceStartTime = (Get-EventLog -LogName System -Source "Service Control Manager" -EntryType Information -Message "*$($ServiceDisplayName)*running*" -Newest 1).TimeGenerated
            Return (New-TimeSpan -Start $ServiceStartTime -End (Get-Date)).Days
        }
        Catch {
            Write-Verbose "Could not get the uptime time for the '$($Name)' service from the event log.  Relying on the process instead."
        }

        #If the event log doesn't contain a start event then use the start time of the service's process.  Since processes can be shared this is less reliable.
        Try{
            $ServiceProcessID = (Get-CimInstance -ClassName Win32_Service -Filter "Name='$($Name)'").ProcessID

            [datetime]$ServiceStartTime = (Get-Process -Id $ServiceProcessID).StartTime
            Return (New-TimeSpan -Start $ServiceStartTime -End (Get-Date)).Days

        }
        Catch{
            Write-Warning "Could not get the uptime time for the '$($Name)' service.  Returning max value."
            Return [int]::MaxValue
        }
    }

    #Loop backwards through a Configuration Manager log file looking for the latest matching message after the start time.
    Function Search-CMLogFile {
        Param(
            [Parameter(Mandatory=$true)]$LogFile,
            [Parameter(Mandatory=$true)][String[]]$SearchStrings,
            [datetime]$StartTime = [datetime]::MinValue
        )

        #Get the log data.
        $LogData = Get-Content $LogFile

        #Loop backwards through the log file.
        :loop for ($i=($LogData.Count - 1);$i -ge 0; $i--) {

            #Parse the log line into its parts.
            try{
                $LogData[$i] -match '\<\!\[LOG\[(?<Message>.*)?\]LOG\]\!\>\<time=\"(?<Time>.+)(?<TZAdjust>[+|-])(?<TZOffset>\d{2,3})\"\s+date=\"(?<Date>.+)?\"\s+component=\"(?<Component>.+)?\"\s+context="(?<Context>.*)?\"\s+type=\"(?<Type>\d)?\"\s+thread=\"(?<TID>\d+)?\"\s+file=\"(?<Reference>.+)?\"\>' | Out-Null
                $LogTime = [datetime]::ParseExact($("$($matches.date) $($matches.time)"),"MM-dd-yyyy HH:mm:ss.fff", $null)
                $LogMessage = $matches.message
            }
            catch{
                Write-Warning "Could not parse the line $($i) in '$($LogFile)': $($LogData[$i])"
				continue
            }

            #If we have gone beyond the start time then stop searching.
            If ($LogTime -lt $StartTime) {
                Write-Verbose "No log lines in $($LogFile) matched $($SearchStrings) before $($StartTime)."
                break loop
            }

            #Loop through each search string looking for a match.
            ForEach($String in $SearchStrings){
                If ($LogMessage -match $String) {
					Write-Output $LogData[$i]
					break loop
				}
            }
        }

        #Looped through log file without finding a match.
        #Return
    }

    Function Test-LocalLogging {
        $clientpath = Get-LocalFilesPath
        $stateDir = Join-Path $env:ProgramData 'ConfigMgrClientHealth'
        if ($clientpath.TrimEnd('\') -eq $stateDir.TrimEnd('\')) { Initialize-SecureDirectory -Path $stateDir | Out-Null }
        elseif ((Test-Path -Path $clientpath) -eq $False) { New-Item -Path $clientpath -ItemType Directory -Force | Out-Null }
    }

    Function Out-LogFile {
        Param([Parameter(Mandatory = $false)][xml]$Xml, $Text, $Mode,
            [Parameter(Mandatory = $false)][ValidateSet(1, 2, 3, 'Information', 'Warning', 'Error')]$Severity = 1)

        switch ($Severity) {
            'Information' {$Severity = 1}
            'Warning' {$Severity = 2}
            'Error' {$Severity = 3}
        }

        if ($Mode -like "Local") {
            Test-LocalLogging
            $clientpath = Get-LocalFilesPath
            $Logfile = "$clientpath\ClientHealth.log"
        }
        else {
            # With no share configured the path would be '\<host>.log', the root of the current drive.
            if ([string]::IsNullOrWhiteSpace((Get-XMLConfigLoggingShare))) { return }
            $Logfile = Get-LogFileName
        }

        if ($mode -like "ClientInstall" ) { 
            $text = "ConfigMgr Client installation failed. Agent not detected 10 minutes after triggering installation." 
            $Severity = 3
        }

        foreach ($item in $text) {
            $item = '<![LOG[' + $item + ']LOG]!>'
            $time = 'time="' + (Get-Date -Format HH:mm:ss.fff) + '+000"' #Should actually be the bias
            $date = 'date="' + (Get-Date -Format MM-dd-yyyy) + '"'
            $component = 'component="ConfigMgrClientHealth"'
            $context = 'context=""'
            $type = 'type="' + $Severity + '"'  #Severity 1=Information, 2=Warning, 3=Error
            $thread = 'thread="' + $PID + '"'
            $file = 'file=""'

            $logblock = ($time, $date, $component, $context, $type, $thread, $file) -join ' '
            $logblock = '<' + $logblock + '>'

            $item + $logblock | Out-File -Encoding utf8 -Append $logFile
        }
        # $obj | Out-File -Encoding utf8 -Append $logFile
    }

    Function Get-OperatingSystem {
        $OS = Get-CimInstance -ClassName Win32_OperatingSystem

        # Handles different OS languages
        $OSArchitecture = ($OS.OSArchitecture -replace ('([^0-9])(\.*)', '')) + '-Bit'
        switch -Wildcard ($OS.Caption) {
            "*Embedded*" {$OSName = "Windows 7 " + $OSArchitecture}
            "*Windows 7*" {$OSName = "Windows 7 " + $OSArchitecture}
            "*Windows 8.1*" {$OSName = "Windows 8.1 " + $OSArchitecture}
            "*Windows 10*" {$OSName = "Windows 10 " + $OSArchitecture}
            "*Windows 11*" {$OSName = "Windows 11 " + $OSArchitecture}
            "*Server 2008*" {
                if ($OS.Caption -like "*R2*") { $OSName = "Windows Server 2008 R2 " + $OSArchitecture }
                else { $OSName = "Windows Server 2008 " + $OSArchitecture }
            }
            "*Server 2012*" {
                if ($OS.Caption -like "*R2*") { $OSName = "Windows Server 2012 R2 " + $OSArchitecture }
                else { $OSName = "Windows Server 2012 " + $OSArchitecture }
            }
            "*Server 2016*" { $OSName = "Windows Server 2016 " + $OSArchitecture }
            "*Server 2019*" { $OSName = "Windows Server 2019 " + $OSArchitecture }
            "*Server 2022*" { $OSName = "Windows Server 2022 " + $OSArchitecture }
            "*Server 2025*" { $OSName = "Windows Server 2025 " + $OSArchitecture }
        }
        if ([string]::IsNullOrWhiteSpace($OSName)) {
            $OSName = (($OS.Caption -replace '^Microsoft\s+', '') -replace '[\\/:*?"<>|]', '').Trim() + ' ' + $OSArchitecture
        }
        Write-Output $OSName
    }


    Function Get-RegistryValue {
        param (
            [parameter(Mandatory=$true)][ValidateNotNullOrEmpty()]$Path,
            [parameter(Mandatory=$true)][ValidateNotNullOrEmpty()]$Name
        )

        Return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    }

    Function Set-RegistryValue {
        param (
            [parameter(Mandatory=$true)][ValidateNotNullOrEmpty()]$Path,
            [parameter(Mandatory=$true)][ValidateNotNullOrEmpty()]$Name,
            [parameter(Mandatory=$true)][ValidateNotNullOrEmpty()]$Value,
            [ValidateSet("String","ExpandString","Binary","DWord","MultiString","Qword")]$ProperyType="String"
        )

        #Make sure the key exists
        If (!(Test-Path $Path)){
            New-Item $Path -Force | Out-Null
        }

        New-ItemProperty -Force -Path $Path -Name $Name -Value $Value -PropertyType $ProperyType | Out-Null
    }

    Function Get-Sitecode {
        try {
            <#
            if ($PowerShellVersion -ge 6) { $obj = (Invoke-CimMethod -Namespace "ROOT\ccm" -ClassName SMS_Client -MethodName GetAssignedSite).sSiteCode }
            else { $obj = $([WmiClass]"ROOT\ccm:SMS_Client").getassignedsite() | Select-Object -Expandproperty sSiteCode }
            #>
            $sms = new-object -comobject 'Microsoft.SMS.Client'
            $obj = $sms.GetAssignedSite()
        }
        catch { $obj = '...' }
        finally { Write-Output $obj }
    }

    Function Get-ClientVersion {
        try {
            $obj = (Get-CimInstance -Namespace root/ccm -ClassName SMS_Client -ErrorAction Stop).ClientVersion
        }
        catch { $obj = $null }
        finally { Write-Output $obj }
    }

    # String comparison orders '5.00.10000.1000' below '5.00.9135.1000'.
    Function ConvertTo-ClientVersion {
        Param([Parameter(Mandatory=$false)]$Value)
        $parsed = $null
        if ([System.Version]::TryParse(([string]$Value).Trim(), [ref]$parsed)) { return $parsed }
        return $null
    }

    # Returns $true when Installed is at least Minimum. An unreadable installed version fails the check;
    # an unreadable or empty minimum passes it.
    Function Test-ClientVersionAtLeast {
        Param($Installed, $Minimum)
        $min = ConvertTo-ClientVersion $Minimum
        if ($null -eq $min) { return $true }
        $inst = ConvertTo-ClientVersion $Installed
        if ($null -eq $inst) { return $false }
        return ($inst -ge $min)
    }

    Function Get-ClientCache {
        try {
            $obj = (New-Object -ComObject UIResource.UIResourceMgr).GetCacheInfo().TotalSize
            #if ($PowerShellVersion -ge 6) { $obj = (Get-CimInstance -Namespace "ROOT\CCM\SoftMgmtAgent" -Class CacheConfig -ErrorAction SilentlyContinue).Size }
            #else { $obj = (Get-WmiObject -Namespace "ROOT\CCM\SoftMgmtAgent" -Class CacheConfig -ErrorAction SilentlyContinue).Size }
        }
        catch { $obj = 0}
        finally {
            if ($null -eq $obj) { $obj = 0 }
            Write-Output $obj
        }
    }

    Function Get-ClientMaxLogSize {
        try { $obj = [Math]::Round(((Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\CCM\Logging\@Global').LogMaxSize) / 1000) }
        catch { $obj = 0 }
        finally { Write-Output $obj }
    }


    Function Get-ClientMaxLogHistory {
        try { $obj = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\CCM\Logging\@Global').LogMaxHistory }
        catch { $obj = 0 }
        finally { Write-Output $obj }
    }


    Function Get-Domain {
        try {
            $obj = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Domain
        }
        catch { $obj = $null }
        finally { Write-Output $obj }
    }

    Function Get-CCMLogDirectory {
        $obj = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\CCM\Logging\@Global').LogDirectory
        if ($null -eq $obj) { $obj = "$env:SystemDrive\windows\ccm\Logs" }
        Write-Output $obj
    }

    Function Get-CCMDirectory {
        $obj = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Client\Configuration\Client Properties' -Name 'Local SMS Path' -ErrorAction SilentlyContinue).'Local SMS Path'
        if ([string]::IsNullOrWhiteSpace($obj)) { $obj = Join-Path $env:windir 'CCM' }
        Write-Output ($obj.TrimEnd('\'))
    }

    <#
    .SYNOPSIS
    Function to test if local database files are missing from the ConfigMgr client.

    .DESCRIPTION
    Function to test if local database files are missing from the ConfigMgr client. Will tag client for reinstall if less than 7. Returns $True if compliant or $False if non-compliant

    .EXAMPLE
    An example

    .NOTES
    Returns $True if compliant or $False if non-compliant. Non.compliant computers require remediation and will be tagged for ConfigMgr client reinstall.
    #>
    Function Test-CcmSDF {
        $ccmdir = Get-CCMDirectory
        $files = @(Get-ChildItem "$ccmdir\*.sdf" -ErrorAction SilentlyContinue)
        if ($files.Count -lt 7) { $obj = $false }
        else { $obj = $true }
        Write-Output $obj
    }

    # Report only. Current clients write CcmSQLCE.log at the default log level during normal operation,
    # so the log alone does not prove database damage; acting on it uninstalls healthy clients.
    Function Test-CcmSQLCELog {
        $logdir = Get-CCMLogDirectory
        $logFile = "$logdir\CcmSQLCE.log"
        $logLevel = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\CCM\Logging\@Global' -ErrorAction SilentlyContinue).logLevel

        if ((Test-Path -Path $logFile) -and ($logLevel -ne 0)) {
            $file = Get-Item -Path $logFile
            $now = Get-Date
            if ((($now - $file.LastWriteTime).Days -lt 7) -and (($now - $file.CreationTime).Days -gt 7)) {
                Write-Warning "CcmSQLCE.log is active outside debug logging. Review it for SQL CE errors. No remediation."
            }
        }
        Write-Output $false
    }

    function Test-CCMCertificateError {
        Param(
            [Parameter(Mandatory=$true)]$Log,
            [datetime]$StartTime = [datetime]::MinValue
        )
        # Since client 2107 the self-signed certificate is bound to a hardware key storage provider and is
        # not exportable, so no key file is deleted. Only lines written since the last run count, which
        # stops one old log line from triggering the same action on every run.
        $entries = @(Get-CMLogEntry -LogFile (Join-Path (Get-CCMLogDirectory) 'ClientIDManagerStartup.log') -StartTime $StartTime)
        $missing = @($entries | Where-Object { $_.Message.Contains('Failed to find the certificate in the store') }).Count -gt 0
        $rejected = @($entries | Where-Object { $_.Message.Contains('Server rejected registration') }).Count -gt 0

        if (-not $missing -and -not $rejected) {
            Write-Output 'ConfigMgr Client Certificate: OK'
            $log.ClientCertificate = 'OK'
            return $false
        }
        if ($rejected) {
            $log.ClientCertificate = 'Registration rejected'
            Add-Finding -Log $Log -Text 'Site rejected the client registration'
        }
        if ($missing) {
            $log.ClientCertificate = 'Certificate missing'
            if ((ConvertTo-ConfigBoolean (Get-XMLConfigRemediationClientCertificate)) -and -not $script:MonitorOnly) {
                Write-Warning 'ConfigMgr Client Certificate: certificate missing. Tagging the client for reinstall.'
                New-ClientInstalledReason -Log $Log -Message 'Client certificate missing.'
                return $true
            }
            Add-Finding -Log $Log -Text 'Client certificate missing from the store'
        }
        return $false
    }

    Function Test-InTaskSequence {
        try { $tsenv = New-Object -COMObject Microsoft.SMS.TSEnvironment }
        catch { $tsenv = $null }

        if ($tsenv) {
            Write-Host "Configuration Manager Task Sequence detected on computer. Exiting script"
            Exit 2
        }
    }


    Function Test-BITS {
        Param([Parameter(Mandatory=$true)]$Log)

        if ($BitsCheckEnabled -ne $true) {
            Write-Host "BITS: PowerShell Module BitsTransfer missing. Skipping check"
            $log.BITS = "PS Module BitsTransfer missing"
            return $false
        }

        # BITS retries TransientError jobs by itself; only Error is a final state that needs an action.
        # The BITS service security descriptor is never changed: Windows ships its own default.
        $days = Get-ConfigOption -Name 'BITSCheck' -Property 'Days' -Default 7
        $limit = (Get-Date).AddDays(-$days)
        $stuck = @(Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.JobState -eq 'Error' -and $_.CreationTime -lt $limit })

        if ($stuck.Count -eq 0) {
            Write-Host "BITS: OK"
            $log.BITS = 'OK'
            return $false
        }
        if ((ConvertTo-ConfigBoolean (Get-XMLConfigBITSCheckFix)) -and -not $script:MonitorOnly) {
            $stuck | Remove-BitsTransfer -ErrorAction SilentlyContinue
            Write-Host "BITS: removed $($stuck.Count) job(s) in Error state for more than $days days"
            $log.BITS = 'Remediated'
            return $true
        }
        Write-Host "BITS: $($stuck.Count) job(s) in Error state for more than $days days. Monitor only"
        $log.BITS = 'Error'
        return $false
    }

	Function Test-ClientSettingsConfiguration {
		Param([Parameter(Mandatory=$true)]$Log)

		$ClientSettingsConfig = @(Get-CimInstance -Namespace "root\ccm\Policy\DefaultMachine\RequestedConfig" -ClassName CCM_ClientAgentConfig -ErrorAction SilentlyContinue | Where-Object {$_.PolicySource -eq "CcmTaskSequence"})

		if ($ClientSettingsConfig.Count -gt 0) {

			$fix = ([string](Get-XMLConfigClientSettingsCheckFix)).ToLower()

			if ($fix -eq "true") {
				$text = "ClientSettings: Error. Remediating"
				$attempt = 0
				DO {
					$attempt++
					Get-CimInstance -Namespace "root\ccm\Policy\DefaultMachine\RequestedConfig" -ClassName CCM_ClientAgentConfig | Where-Object {$_.PolicySource -eq "CcmTaskSequence"} | Select-Object -first 1000 | Remove-CimInstance -ErrorAction SilentlyContinue
					$remaining = Get-CimInstance -Namespace "root\ccm\Policy\DefaultMachine\RequestedConfig" -ClassName CCM_ClientAgentConfig | Where-Object {$_.PolicySource -eq "CcmTaskSequence"} | Select-Object -first 1
				} Until ((-not $remaining) -or ($attempt -ge 10))
				if ($remaining) {
					$text = "ClientSettings: Error. Task sequence client settings remain after $attempt removal attempts"
					$log.ClientSettings = 'Error'
				}
				else { $log.ClientSettings = 'Remediated' }
				$obj = $true
			}
			else {
				$text = "ClientSettings: Error. Monitor only"
				$log.ClientSettings = 'Error'
				$obj = $false
			}
		}

		else {
			$text = "ClientSettings: OK"
			$log.ClientSettings = 'OK'
			$Obj = $false
		}
		Write-Host $text
		#Write-Output $Obj
    }

    Function New-ClientInstalledReason {
        Param(
            [Parameter(Mandatory=$true)]$Message,
            [Parameter(Mandatory=$true)]$Log
            )

        if ($null -eq $log.ClientInstalledReason) { $log.ClientInstalledReason = $Message }
        else { $log.ClientInstalledReason += " $Message" }
    }




    Function Get-OSDiskFreeSpace {

        $driveC = Get-CimInstance -ClassName Win32_LogicalDisk | Where-Object {$_.DeviceID -eq "$env:SystemDrive"} | Select-Object FreeSpace, Size
        $freeSpace = (($driveC.FreeSpace / $driveC.Size) * 100)
        Write-Output ([math]::Round($freeSpace,2))
    }



    Function Get-LastInstalledPatches {
        Param([Parameter(Mandatory=$true)]$Log)
        # Reading date from Windows Update COM object.
        $Session = New-Object -ComObject Microsoft.Update.Session
        $Searcher = $Session.CreateUpdateSearcher()
        $HistoryCount = $Searcher.GetTotalHistoryCount()

        # Windows 10, 11 and Server 2016-2025 record installs by UpdateOrchestrator or the ConfigMgr client.
        $Date = $Searcher.QueryHistory(0, $HistoryCount) | Where-Object {
            ($_.ClientApplicationID -eq 'UpdateOrchestrator' -or $_.ClientApplicationID -eq 'ccmexec') -and ($_.Title -notmatch "Security Intelligence Update|Definition Update")
        } | Select-Object -ExpandProperty Date | Measure-Latest

        # IUpdateHistoryEntry.Date is UTC with Kind Unspecified; Get-SmallDateTime expects local time.
        if ($Date -is [datetime]) { $Date = [DateTime]::SpecifyKind($Date, [DateTimeKind]::Utc).ToLocalTime() }

        $Hotfix = Get-CimInstance -ClassName Win32_QuickFixEngineering | Where-Object { $_.InstalledOn } | Select-Object @{Name="InstalledOn";Expression={[DateTime]::Parse($_.InstalledOn,$([System.Globalization.CultureInfo]::GetCultureInfo("en-US")))}}

        $Hotfix = $Hotfix | Select-Object -ExpandProperty InstalledOn

        $Date2 = $null

        if ($null -ne $hotfix) { $Date2 = Get-Date($hotfix | Measure-Latest) -ErrorAction SilentlyContinue }

        if (($Date -ge $Date2) -and ($null -ne $Date)) { $Log.OSUpdates = Get-SmallDateTime -Date $Date }
        elseif (($Date2 -gt $Date) -and ($null -ne $Date2)) { $Log.OSUpdates = Get-SmallDateTime -Date $Date2 }
    }

    function Measure-Latest {
        BEGIN { $latest = $null }
        PROCESS { if (($null -ne $_) -and (($null -eq $latest) -or ($_ -gt $latest))) { $latest = $_ } }
        END { $latest }
    }

    Function Test-LogFileHistory {
        Param([Parameter(Mandatory=$true)]$Logfile)
        $startString = '<--- ConfigMgr Client Health Check starting --->'
        $content = ''

        # Handle the network share log file
        if (Test-Path $logfile -ErrorAction SilentlyContinue)  { $content = Get-Content $logfile -ErrorAction SilentlyContinue }
		else { return }
        $maxHistory = ConvertTo-ConfigInt -Value (Get-XMLConfigLoggingMaxHistory) -Default 8 -Minimum 1
        $startCount = [regex]::matches($content,$startString).count

        # Delete logfile if more start and stop entries than max history
        if ($startCount -ge $maxHistory) { Remove-Item $logfile -Force }
    }

    Function Test-DNSConfiguration {
        Param([Parameter(Mandatory=$true)]$Log)
        #$dnsdomain = (Get-WmiObject Win32_NetworkAdapterConfiguration -filter "ipenabled = 'true'").DNSDomain
        $fqdn = [System.Net.Dns]::GetHostEntry([string]"localhost").HostName
        $localIPs = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration | Where-Object {$_.IPEnabled -Match "True"} |  Select-Object -ExpandProperty IPAddress
        $dnscheck = [System.Net.DNS]::GetHostByName($fqdn)

        $OSName = Get-OperatingSystem
        if (($OSName -notlike "*Windows 7*") -and ($OSName -notlike "*Server 2008*")) {
            # This method is supported on Windows 8 / Server 2012 and higher. More acurate than using .NET object method
            try {
                $ActiveAdapters = (get-netadapter | Where-Object {$_.Status -like "Up"}).Name
                $dnsServers = Get-DnsClientServerAddress | Where-Object {$ActiveAdapters -contains $_.InterfaceAlias} | Where-Object {$_.AddressFamily -eq 2} | Select-Object -ExpandProperty ServerAddresses
                $dnsAddressList = Resolve-DnsName -Name $fqdn -Server ($dnsServers | Select-Object -First 1) -Type A -DnsOnly | Select-Object -ExpandProperty IPAddress
            }
            catch {
                # Fallback to depreciated method
                $dnsAddressList = $dnscheck.AddressList | Select-Object -ExpandProperty IPAddressToString
                $dnsAddressList = $dnsAddressList -replace("%(.*)", "")
            }
        }

        else {
            # This method cannot guarantee to only resolve against DNS sever. Local cache can be used in some circumstances.
            # For Windows 7 only

            $dnsAddressList = $dnscheck.AddressList | Select-Object -ExpandProperty IPAddressToString
            $dnsAddressList = $dnsAddressList -replace("%(.*)", "")
        }

        $dnsFail = ''
        $logFail = ''

        Write-Verbose 'Verify that local machines FQDN matches DNS'
        if ($dnscheck.HostName -like $fqdn) {
            $obj = $true
            Write-Verbose 'Checking if one local IP matches on IP from DNS'
            Write-Verbose 'Loop through each IP address published in DNS'
            foreach ($dnsIP in $dnsAddressList) {
                #Write-Host "Testing if IP address: $dnsIP published in DNS exist in local IP configuration."
                ##if ($dnsIP -notin $localIPs) { ## Requires PowerShell 3. Works fine :(
                if ($localIPs -notcontains $dnsIP) {
                   $dnsFail += "IP '$dnsIP' in DNS record do not exist locally`n"
                   $logFail += "$dnsIP "
                   $obj = $false
                }
            }
        }
        else {
            $hn = $dnscheck.HostName
            $dnsFail = 'DNS name: ' +$hn + ' local fqdn: ' +$fqdn + ' DNS IPs: ' +$dnsAddressList + ' Local IPs: ' + $localIPs
            $logFail = "Hostname mismatch: $hn"
            $obj = $false
            Write-Host $dnsFail
        }

        $FileLogLevel = ([string](Get-XMLConfigLoggingLevel)).ToLower()

        switch ($obj) {
            $false {
                $fix = ([string](Get-XMLConfigDNSFix)).ToLower()
                # Registration does nothing when policy or every adapter turns dynamic DNS update off.
                $policyRegistration = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name RegistrationEnabled -ErrorAction SilentlyContinue).RegistrationEnabled
                $registeringAdapters = @(Get-DnsClient -ErrorAction SilentlyContinue | Where-Object { $_.RegisterThisConnectionsAddress })
                if (($fix -eq "true") -and (($policyRegistration -eq 0) -or ($registeringAdapters.Count -eq 0))) {
                    $log.DNS = $logFail
                    Add-Finding -Log $Log -Text 'DNS mismatch; dynamic DNS registration is turned off'
                }
                elseif ($fix -eq "true") {
                    $text = 'DNS Check: FAILED. IP address published in DNS do not match IP address on local machine. Trying to resolve by registerting with DNS server'
                    Register-DnsClient | Out-Null
                    Write-Host $text
                    $log.DNS = $logFail
                    if (-NOT($FileLogLevel -like "clientlocal")) {
                        Out-LogFile -Xml $xml -Text $text -Severity 2
                        Out-LogFile -Xml $xml -Text $dnsFail -Severity 2
                    }

                }
                else {
                    $text = 'DNS Check: FAILED. IP address published in DNS do not match IP address on local machine. Monitor mode only, no remediation'
                    $log.DNS = $logFail
                    if (-NOT($FileLogLevel -like "clientlocal")) { Out-LogFile -Xml $xml -Text $text  -Severity 2}
                    Write-Host $text
                }

            }
            $true {
                $text = 'DNS Check: OK'
                Write-Output $text
                $log.DNS = 'OK'
            }
        }
        #Write-Output $obj
    }

    # Function to test that 'HKU:\S-1-5-18\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders\' is set to '%USERPROFILE%\AppData\Roaming'. CCMSETUP will fail if not.
    # Reference: https://www.systemcenterdudes.com/could-not-access-network-location-appdata-ccmsetup-log/
    Function Test-CCMSetup1 {
        New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS -ErrorAction SilentlyContinue | Out-Null
        $correctValue = '%USERPROFILE%\AppData\Roaming'
        $currentValue = (Get-Item 'HKU:\S-1-5-18\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders\').GetValue('AppData', $null, 'DoNotExpandEnvironmentNames')

       # Only fix if the value is wrong
       if ($currentValue -ne $correctValue) { Set-ItemProperty -Path  'HKU:\S-1-5-18\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders\' -Name 'AppData' -Value $correctValue }
    }

    Function Test-Update {
        Param([Parameter(Mandatory=$true)]$Log)

        $UpdateShare = Get-XMLConfigUpdatesShare


        Write-Verbose "Validating required updates is installed on the client. Required updates will be installed if missing on client."
        #$OS = Get-WmiObject -class Win32_OperatingSystem
        $OSName = Get-OperatingSystem


        $build = $null
        if (($OSName -like "*Windows 10*") -or ($OSName -like "*Windows 11*")) {
            $build = Get-CimInstance Win32_OperatingSystem | Select-Object -ExpandProperty BuildNumber
            switch ($build) {
                10240 {$OSName = $OSName + " 1507"}
                10586 {$OSName = $OSName + " 1511"}
                14393 {$OSName = $OSName + " 1607"}
                15063 {$OSName = $OSName + " 1703"}
                16299 {$OSName = $OSName + " 1709"}
                17134 {$OSName = $OSName + " 1803"}
                17763 {$OSName = $OSName + " 1809"}
                18362 {$OSName = $OSName + " 1903"}
                18363 {$OSName = $OSName + " 1909"}
                19041 {$OSName = $OSName + " 2004"}
                19042 {$OSName = $OSName + " 20H2"}
                19043 {$OSName = $OSName + " 21H1"}
                19044 {$OSName = $OSName + " 21H2"}
                19045 {$OSName = $OSName + " 22H2"}
                22000 {$OSName = $OSName + " 21H2"}
                22621 {$OSName = $OSName + " 22H2"}
                22631 {$OSName = $OSName + " 23H2"}
                26100 {$OSName = $OSName + " 24H2"}
                26200 {$OSName = $OSName + " 25H2"}
                default {
                    $displayVersion = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).DisplayVersion
                    if ($displayVersion) { $OSName = $OSName + " $displayVersion" }
                    else { $OSName = $OSName + " Insider Preview" }
                }
            }
        }

        $Updates = (Join-Path $UpdateShare $OSName)
        If ((Test-Path $Updates) -eq $true) {
            $regex = '(?i)^.+-kb[0-9]{6,}-(?:v[0-9]+-)?x[0-9]+\.msu$'
            $hotfixes = @(Get-ChildItem $Updates | Where-Object { $_.Name -match $regex } | Select-Object -ExpandProperty Name)

            $installedUpdates = @((Get-CimInstance -ClassName Win32_QuickFixEngineering).HotFixID)

            $count = $hotfixes.count

            if (($count -eq 0) -or ($null -eq $count)) {
                $text = 'Updates: No mandatory updates to install.'
                Write-Output $text
                $log.Updates = 'OK'
            }
            else {
                $logEntry = $null

				$regex = '\b(?!(KB)+(\d+)\b)\w+'
                foreach ($hotfix in $hotfixes) {
                    $kb = $hotfix -replace $regex -replace "\." -replace "-"
                    if ($installedUpdates -contains $kb) {
                        $text = "Update $hotfix" + ": OK"
                        Write-Output $text
                    }
                    else {
                        if ($null -eq $logEntry) { $logEntry = $kb }
                        else { $logEntry += ", $kb" }

                        if (ConvertTo-ConfigBoolean (Get-XMLConfigUpdatesFix)) {
                            $kbfullpath = Join-Path $updates $hotfix
                            $text = "Update $hotfix" + ": Missing. Installing now..."
                            Write-Warning $text

                            # The package installs as SYSTEM, so it is staged only in the protected state folder;
                            # LocalFiles can point to a folder that standard users can write to.
                            $stateDir = Join-Path $env:ProgramData 'ConfigMgrClientHealth'
                            if (-not (Initialize-SecureDirectory -Path $stateDir)) {
                                Write-Warning "Update ${hotfix}: no protected staging folder. Not installed."
                                continue
                            }
                            $temppath = Join-Path $stateDir 'updates'
                            If ((Test-Path $temppath) -eq $false) { New-Item -Path $temppath -ItemType Directory | Out-Null }

                            # Windows 11 24H2 and Server 2025 cumulative updates can depend on checkpoint updates.
                            # DISM finds them in the folder of the package, so every package of the share folder is staged.
                            Get-ChildItem -Path $Updates -Filter '*.msu' | Where-Object { -not (Test-Path (Join-Path $temppath $_.Name)) } | Copy-Item -Destination $temppath
                            $install = Join-Path $temppath $hotfix
                            try {
                                Add-WindowsPackage -Online -PackagePath $install -NoRestart -ErrorAction Stop | Out-Null
                                Write-Host "Update ${hotfix}: installed."
                            }
                            catch { Add-Finding -Log $Log -Text "Update $hotfix install failed: $($_.Exception.Message)" }

                        }
                        else {
                            $text = "Update $hotfix" + ": Missing. Monitor mode only, no remediation."
                            Write-Warning $text
                        }
                    }

                    if ($null -eq $logEntry) { $log.Updates = 'OK' }
                    else { $log.Updates = $logEntry }
                }
            }
        }
        Else {
            $log.Updates = 'Failed'
            Write-Warning "Updates Failed: Could not locate update folder '$($Updates)'."
        }
    }

    Function Test-ConfigMgrClient {
        Param([Parameter(Mandatory=$true)]$Log)

        # Check if the SCCM Agent is installed or not.
        # If installed, perform tests to decide if reinstall is needed or not.
        if (Get-Service -Name ccmexec -ErrorAction SilentlyContinue) {
            $text = "Configuration Manager Client is installed"
            Write-Host $text

            # Lets not reinstall client unless tests tells us to.
            $Reinstall = $false

            # No documented file count exists; ccmeval checks the client database and reinstalls on failure.
            if ((Test-CcmSDF) -eq $false) { Add-Finding -Log $Log -Text 'Fewer than 7 client database files' }

            # Only test CM client local DB if this check is enabled
            $LocalDB = $false
            if (ConvertTo-ConfigBoolean (Get-XMLConfigCcmSQLCELog)) {
                Write-Host "Testing CcmSQLCELog"
                Test-CcmSQLCELog | Out-Null

            }

            $CCMService = Get-Service -Name ccmexec -ErrorAction SilentlyContinue

            # Reinstall if we are unable to start the CM client
            if (($CCMService.Status -eq "Stopped") -and ($LocalDB -eq $false) -and -not $script:MonitorOnly) {
                try {
                    Write-Host "ConfigMgr Agent not running. Attempting to start it."
                    if ($CCMService.StartType -ne "Automatic") {
                        $text = "Configuring service CcmExec StartupType to: Automatic (Delayed Start)..."
                        Write-Output $text
                        Set-Service -Name CcmExec -StartupType Automatic
                    }
                    Start-Service -Name CcmExec
                }
                catch {
                    $Reinstall = $true
                    New-ClientInstalledReason -Log $Log -Message "Service not running, failed to start."
                }
            }

            # Test that we are able to connect to SMS_Client WMI class. The provider is briefly unavailable
            # after a service start or during a client upgrade. ccmsetup rebuilds the client namespaces, so
            # the namespace is not deleted here.
            if (Get-Process -Name ccmsetup -ErrorAction SilentlyContinue) {
                Write-Warning 'ccmsetup is running. Skipping the SMS_Client WMI check.'
            }
            else {
                $smsClientReachable = $false
                for ($attempt = 1; $attempt -le 6; $attempt++) {
                    try {
                        Get-CimInstance -Namespace root/ccm -ClassName SMS_Client -ErrorAction Stop | Out-Null
                        $smsClientReachable = $true
                        break
                    }
                    catch {
                        if ($attempt -lt 6) { Start-Sleep -Seconds 10 }
                    }
                }

                if (-not $smsClientReachable) {
                    Write-Verbose 'Failed to connect to WMI namespace "root/ccm" class "SMS_Client". Tagging client for reinstall.'
                    $Reinstall = $true
                    $Uninstall = $true
                    New-ClientInstalledReason -Log $Log -Message "Failed to connect to SMS_Client WMI class."
                }
            }

            if ( $reinstall -eq $true) {
                $text = "ConfigMgr Client Health thinks the agent need to be reinstalled.."
                Write-Host $text
                # Lets check that registry settings are OK before we try a new installation.
                Test-CCMSetup1

                if (Resolve-Client -Xml $xml -ClientInstallProperties $clientInstallProperties -FirstInstall $false -Log $Log) {
                    $log.ClientInstalled = Get-SmallDateTime
                    Start-Sleep 600
                }
            }
        }
        else {
            $text = "Configuration Manager client is not installed. Installing..."
            Write-Host $text
            New-ClientInstalledReason -Log $Log -Message "No agent found."
            if (Resolve-Client -Xml $xml -ClientInstallProperties $clientInstallProperties -FirstInstall $true -Log $Log) {
                $log.ClientInstalled = Get-SmallDateTime
            }

            # Test again if agent is installed
            if (Get-Service -Name ccmexec -ErrorAction SilentlyContinue) {}
            else { Out-LogFile "ConfigMgr Client installation failed. Agent not detected 10 minutes after triggering installation."  -Mode "ClientInstall" -Severity 3}
        }
    }

    Function Test-ClientCacheSize {
        Param([Parameter(Mandatory=$true)]$Log)
        $ClientCacheSize = Get-XMLConfigClientCache
        #if ($PowerShellVersion -ge 6) { $Cache = Get-CimInstance -Namespace "ROOT\CCM\SoftMgmtAgent" -Class CacheConfig }
        #else { $Cache = Get-WmiObject -Namespace "ROOT\CCM\SoftMgmtAgent" -Class CacheConfig }

        $CurrentCache = Get-ClientCache

        # With the client setting "Configure client cache size" on, policy sets the size (the smaller of MB and
        # percent); changing it here would be undone by policy and changed again on every run.
        $cachePolicy = Get-CimInstance -Namespace 'root\ccm\Policy\Machine\ActualConfig' -ClassName CCM_SuperPeerClientConfig -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cachePolicy -and $cachePolicy.ConfigureCacheSize -eq $true) {
            Write-Host "ConfigMgr Client Cache Size: $CurrentCache MB, managed by client settings ($($cachePolicy.MaxCacheSizeMB) MB / $($cachePolicy.MaxCacheSizePercent)%)."
            $Log.CacheSize = $CurrentCache
            return $false
        }

        if ($ClientCacheSize -match '%') {
            $type = 'percentage'
            # percentage based cache based on disk space
            $num = $ClientCacheSize -replace '%'
            $num = ($num / 100)
            # TotalDiskSpace in Byte
            $TotalDiskSpace = (Get-CimInstance -ClassName Win32_LogicalDisk | Where-Object {$_.DeviceID -eq "$env:SystemDrive"} | Select-Object -ExpandProperty Size)
            $ClientCacheSize = ([math]::Round(($TotalDiskSpace * $num) / 1048576))
            # The client caps the cache at 99999 MB; compare against the capped value.
            if ($ClientCacheSize -gt 99999) { $ClientCacheSize = 99999 }
        }
        else {
            $type = 'fixed'
            $ClientCacheSize = ConvertTo-ConfigInt -Value $ClientCacheSize -Default 0
            if ($ClientCacheSize -le 0) {
                Write-Warning "ConfigMgr Client Cache Size: no valid size in config. Skipping check."
                $Log.CacheSize = $CurrentCache
                return $false
            }
        }

        if ([int64]$CurrentCache -eq [int64]$ClientCacheSize) {
            $text = "ConfigMgr Client Cache Size: OK"
            Write-Host $text
            $Log.CacheSize = $CurrentCache
            $obj = $false
        }

        else {
            switch ($type) {
                'fixed' {$text = "ConfigMgr Client Cache Size: $CurrentCache. Expected: $ClientCacheSize. Redmediating."}
                'percentage' {
                    $percent = Get-XMLConfigClientCache
                    $text ="ConfigMgr Client Cache Size: $CurrentCache. Expected: $ClientCacheSize ($percent). (99999 maxium). Redmediating."
                }
            }

            Write-Warning $text
            if ($script:MonitorOnly) {
                Add-Finding -Log $Log -Text "Client cache size $CurrentCache MB, expected $ClientCacheSize MB"
                $log.CacheSize = $CurrentCache
                return $false
            }
            $log.CacheSize = $ClientCacheSize
            (New-Object -ComObject UIResource.UIResourceMgr).GetCacheInfo().TotalSize = "$ClientCacheSize"
            $obj = $true
        }
        Write-Output $obj
    }

    Function Test-ClientVersion {
        Param([Parameter(Mandatory=$true)]$Log)
        $ClientVersion = Get-XMLConfigClientVersion
        [String]$ClientAutoUpgrade = Get-XMLConfigClientAutoUpgrade
        $ClientAutoUpgrade = $ClientAutoUpgrade.ToLower()
        $installedVersion = Get-ClientVersion
        $log.ClientVersion = $installedVersion

        if (Test-ClientVersionAtLeast -Installed $installedVersion -Minimum $ClientVersion) {
            $text = 'ConfigMgr Client version is: ' +$installedVersion + ': OK'
            Write-Output $text
            $obj = $false
        }
        elseif ($ClientAutoUpgrade -like 'true') {
            $text = 'ConfigMgr Client version is: ' +$installedVersion +': Tagging client for upgrade to version: '+$ClientVersion
            Write-Warning $text
            $obj = $true
        }
        else {
            $text = 'ConfigMgr Client version is: ' +$installedVersion +': Required version: '+$ClientVersion +' AutoUpgrade: false. Skipping upgrade'
            Write-Output $text
            $obj = $false
        }
        Write-Output $obj
    }

    Function Test-ClientSiteCode {
        Param([Parameter(Mandatory=$true)]$Log)
        $sms = new-object -comobject "Microsoft.SMS.Client"
        $ClientSiteCode = Get-XMLConfigClientSitecode
        #[String]$currentSiteCode = Get-Sitecode
        $currentSiteCode = $sms.GetAssignedSite()
        $currentSiteCode = $currentSiteCode.Trim()
        $Log.Sitecode = $currentSiteCode

        # Do more investigation and testing on WMI Method "SetAssignedSite" to possible avoid reinstall of client for this check.
        if ($ClientSiteCode -like $currentSiteCode) {
            $text = "ConfigMgr Client Site Code: OK"
            Write-Host $text
            #$obj = $false
        }
        else {
            $text = 'ConfigMgr Client Site Code is "' +$currentSiteCode + '". Expected: "' +$ClientSiteCode +'". Changing sitecode.'
            Write-Warning $text
            if ($script:MonitorOnly) { Add-Finding -Log $Log -Text "Site code $currentSiteCode, expected $ClientSiteCode" }
            else { $sms.SetAssignedSite($ClientSiteCode) }
            #$obj = $true
        }
        #Write-Output $obj
    }

    function Test-PendingReboot {
        Param([Parameter(Mandatory=$true)]$Log)
        # Only run pending reboot check if enabled in config
        if (ConvertTo-ConfigBoolean (Get-XMLConfigPendingRebootEnable)) {
            $result = @{
                CBSRebootPending =$false
                WindowsUpdateRebootRequired = $false
                FileRenamePending = $false
                SCCMRebootPending = $false
            }

            # The RebootPending key usually has no subkeys, so only its presence is meaningful.
            if (Test-Path "HKLM:Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") { $result.CBSRebootPending = $true }

            #Check Windows Update
            $key = Get-Item 'HKLM:SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' -ErrorAction SilentlyContinue
            if ($null -ne $key) { $result.WindowsUpdateRebootRequired = $true }

            #Check PendingFileRenameOperations
            $prop = Get-ItemProperty 'HKLM:SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
            if ($null -ne $prop)
            {
                #PendingFileRenameOperations is not *must* to reboot?
                #$result.FileRenamePending = $true
            }

            try
            {
                $status = Invoke-CimMethod -Namespace 'root\ccm\clientsdk' -ClassName 'CCM_ClientUtilities' -MethodName 'DetermineIfRebootPending'
                if(($null -ne $status) -and $status.RebootPending){ $result.SCCMRebootPending = $true}
            }
            catch { Write-Verbose "Non-critical check failed: $_" }

            #Return Reboot required
            if ($result.ContainsValue($true)) {
                $text = 'Pending Reboot: Computer is in pending reboot'
                Write-Warning $text
                $log.PendingReboot = 'Pending Reboot'

                if (ConvertTo-ConfigBoolean (Get-XMLConfigPendingRebootApp)) {
                    Start-RebootApplication
                    $log.RebootApp = Get-SmallDateTime
                }
            }
            else {
                $text = 'Pending Reboot: OK'
                Write-Output $text
                $log.PendingReboot = 'OK'
            }
            #Out-LogFile -Xml $xml -Text $text
        }
    }

    # Functions to detect and fix errors
    Function Test-ProvisioningMode {
        Param([Parameter(Mandatory=$true)]$Log)
        $registryPath = 'HKLM:\SOFTWARE\Microsoft\CCM\CcmExec'
        $settings = Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue

        if ($settings.ProvisioningMode -ne 'true') {
            Write-Output 'ConfigMgr Client Provisioning Mode: OK'
            $log.ProvisioningMode = 'OK'
            return
        }

        # The client leaves provisioning mode by itself after ProvisioningMaxMinutes (48 hours by default).
        # Inside that window a task sequence or an in-place upgrade can still be running.
        $enabledAt = $null
        $raw = [string]$settings.ProvisioningEnabledTime
        $seconds = 0L
        if ([int64]::TryParse($raw, [ref]$seconds)) { $enabledAt = [DateTimeOffset]::FromUnixTimeSeconds($seconds).LocalDateTime }
        $maxMinutes = ConvertTo-ConfigInt -Value $settings.ProvisioningMaxMinutes -Default 2880 -Minimum 1
        if ($enabledAt -and $enabledAt -gt (Get-Date).AddMinutes(-$maxMinutes)) {
            Write-Output "ConfigMgr Client Provisioning Mode: YES since $enabledAt. Within the $maxMinutes-minute window; no change."
            $log.ProvisioningMode = 'Provisioning'
            return
        }

        if ($script:MonitorOnly) {
            Add-Finding -Log $Log -Text 'Client in provisioning mode'
            $log.ProvisioningMode = 'Provisioning'
            return
        }
        # Microsoft documents the WMI method; editing the registry value alone does not leave provisioning mode.
        Write-Warning 'ConfigMgr Client Provisioning Mode: YES. Remediating...'
        try {
            Invoke-CimMethod -Namespace 'root\ccm' -ClassName 'SMS_Client' -MethodName 'SetClientProvisioningMode' -Arguments @{bEnable=$false} -ErrorAction Stop | Out-Null
            $log.ProvisioningMode = 'Repaired'
        }
        catch {
            $log.ProvisioningMode = 'Provisioning'
            Add-Finding -Log $Log -Text "Could not leave provisioning mode: $($_.Exception.Message)"
        }
    }


    Function Test-UpdateStore {
        Param([Parameter(Mandatory=$true)]$Log)
        # "Successfully forwarded State Messages to the MP" only means the message reached CcmMessaging, and the
        # line disappears when the log rolls over. Unsent messages in WMI are the direct signal.
        # Messages wait in the queue for a short time during normal operation; only old ones point to a problem.
        $limit = (Get-Date).AddHours(-1)
        $unsent = @(Get-CimInstance -Namespace 'root\ccm\StateMsg' -ClassName CCM_StateMsg -Filter 'MessageSent = False' -ErrorAction SilentlyContinue | Where-Object { $_.MessageTime -lt $limit })
        if ($unsent.Count -eq 0) {
            Write-Output 'StateMessage: OK'
            $log.StateMessages = 'OK'
            return
        }
        if ($script:MonitorOnly) {
            Add-Finding -Log $Log -Text "$($unsent.Count) state messages unsent for more than 1 hour"
            $log.StateMessages = "Unsent ($($unsent.Count))"
            return
        }
        Write-Warning "StateMessage: $($unsent.Count) unsent. Sending unsent state messages."
        Invoke-CCMTrigger -ScheduleID '{00000000-0000-0000-0000-000000000111}'
        $log.StateMessages = "Repaired ($($unsent.Count) unsent)"
    }

    Function Test-RegistryPolHeader {
        Param([Parameter(Mandatory=$true)][string]$Path)
        # Registry Policy File Format: the file starts with the DWORD REGFILE_SIGNATURE 0x67655250 ("PReg").
        # A missing file is valid; Group Policy creates it when a setting applies.
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $true }
        $stream = $null
        try {
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            if ($stream.Length -lt 8) { return $false }
            $header = New-Object byte[] 4
            if ($stream.Read($header, 0, 4) -ne 4) { return $false }
            return ([System.BitConverter]::ToUInt32($header, 0) -eq 0x67655250)
        }
        catch {
            Write-Verbose "Could not read $($Path): $_"
            return $true
        }
        finally { if ($stream) { $stream.Dispose() } }
    }

    Function Test-RegistryPol {
        Param(
            [datetime]$StartTime=[datetime]::MinValue,
            $Days,
            [Parameter(Mandatory=$true)]$Log)
        $log.WUAHandler = "Checking"
        $MachineRegistryFile = "$($env:WinDir)\System32\GroupPolicy\Machine\registry.pol"
        $corrupt = -not (Test-RegistryPolHeader -Path $MachineRegistryFile)

        # Microsoft's trigger: WUAHandler.log reports "Group policy settings were overwritten by a higher
        # authority" with 0x87d00692. When a domain controller is the source, Group Policy writes the same
        # settings again, so renaming the file cannot help; that case is a finding (Test-WindowsUpdateScan).
        $entries = @(Get-CMLogEntry -LogFile (Join-Path (Get-CCMLogDirectory) 'WUAHandler.log') -StartTime $StartTime)
        $overwritten = @($entries | Where-Object { $_.Message -match 'overwritten by a higher authority' }).Count -gt 0
        $errorCode = @($entries | Where-Object { $_.Message -match '0x87d00692' }).Count -gt 0
        $domainSource = @($entries | Where-Object { $_.Message -match 'higher authority \(Domain Controller\)' }).Count -gt 0

        try {
            $gpoErrors = @(Get-WinEvent -Verbose:$false -FilterHashTable @{LogName='Microsoft-Windows-GroupPolicy/Operational';Level=2;StartTime=$StartTime} -ErrorAction SilentlyContinue | Where-Object {($_.ID -ge 7000 -and $_.ID -le 7007) -or ($_.ID -ge 7017 -and $_.ID -le 7299) -or ($_.ID -eq 1096)}).Count
            if ($gpoErrors -gt 0) { Add-Finding -Log $Log -Text "Group Policy processing errors: $gpoErrors" }
        }
        catch { Write-Verbose "Could not read the Group Policy event log: $_" }

        $overwrittenLocal = $overwritten -and $errorCode -and -not $domainSource
        if (-not $overwrittenLocal -and -not $corrupt) {
            $log.WUAHandler = 'OK'
            Write-Output "GPO Cache: OK"
            return
        }
        if ($corrupt) { $reason = 'Corrupt registry.pol' } else { $reason = 'WUAHandler Log' }

        if ($script:MonitorOnly) {
            $log.WUAHandler = "Broken ($reason)"
            if ($corrupt) { Add-Finding -Log $Log -Text 'registry.pol has no valid header' }
            else { Add-Finding -Log $Log -Text 'registry.pol overwritten by a higher authority (0x87d00692)' }
            return
        }
        # A repeated repair in a short time means something writes the bad setting again.
        $guardDays = ConvertTo-ConfigInt -Value $Days -Default 7 -Minimum 1
        $lastRepair = [datetime]::MinValue
        [void][datetime]::TryParse([string](Get-RegistryValue -Path 'HKLM:\Software\ConfigMgrClientHealth' -Name 'RegistryPolRepair'), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$lastRepair)
        if ($lastRepair -gt (Get-Date).AddDays(-$guardDays)) {
            $log.WUAHandler = 'Broken (repaired recently)'
            Add-Finding -Log $Log -Text "registry.pol broken again within $guardDays days of a repair"
            return
        }

        $log.WUAHandler = "Broken ($reason)"
        Write-Output "GPO Cache: $($log.WUAHandler)"
        try {
            # Renamed, not deleted, so a local policy baseline applied during imaging can be restored.
            if (Test-Path -Path $MachineRegistryFile) { Move-Item -LiteralPath $MachineRegistryFile -Destination "$MachineRegistryFile.$(Get-Date -Format 'yyyyMMddHHmmss').bak" -Force -ErrorAction Stop }
        }
        catch { Write-Warning "GPO Cache: Failed to rename the registry file ($($MachineRegistryFile))." }
        & Write-Output n | gpupdate.exe /force /target:computer | Out-Null
        Set-RegistryValue -Path 'HKLM:\Software\ConfigMgrClientHealth' -Name 'RegistryPolRepair' -Value ((Get-Date).ToString('o'))

        Restart-Service -Name CcmExec -Force -ErrorAction SilentlyContinue
        Invoke-CCMTrigger -ScheduleID '{00000000-0000-0000-0000-000000000113}'
        Invoke-CCMTrigger -ScheduleID '{00000000-0000-0000-0000-000000000108}'

        $log.WUAHandler = "Repaired ($reason)"
        Write-Output "GPO Cache: $($log.WUAHandler)"
    }

    Function Test-ClientLogSize {
        Param([Parameter(Mandatory=$true)]$Log)
        try { [int]$currentLogSize = Get-ClientMaxLogSize }
        catch { [int]$currentLogSize = 0 }
        try { [int]$currentMaxHistory = Get-ClientMaxLogHistory }
        catch { [int]$currentMaxHistory = 0 }
        try { $logLevel = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\CCM\Logging\@Global').logLevel }
        catch { $logLevel = 1 }

        $clientLogSize = Get-XMLConfigClientMaxLogSize
        $clientLogMaxHistory = Get-XMLConfigClientMaxLogHistory

        $text = ''

        if ( ($currentLogSize -eq $clientLogSize) -and ($currentMaxHistory -eq $clientLogMaxHistory) ) {
            $Log.MaxLogSize = $currentLogSize
            $Log.MaxLogHistory = $currentMaxHistory
            $text = "ConfigMgr Client Max Log Size: OK ($currentLogSize)"
            Write-Host $text
            $text = "ConfigMgr Client Max Log History: OK ($currentMaxHistory)"
            Write-Host $text
            $obj = $false
        }
        else {
            if ($currentLogSize -ne $clientLogSize) {
                $text = 'ConfigMgr Client Max Log Size: Configuring to '+ $clientLogSize +' KB'
                $Log.MaxLogSize = $clientLogSize
                Write-Warning $text
            }
            else {
                $text = "ConfigMgr Client Max Log Size: OK ($currentLogSize)"
                Write-Host $text
            }
            if ($currentMaxHistory -ne $clientLogMaxHistory) {
                $text = 'ConfigMgr Client Max Log History: Configuring to ' +$clientLogMaxHistory
                $Log.MaxLogHistory = $clientLogMaxHistory
                Write-Warning $text
            }
            else {
                $text = "ConfigMgr Client Max Log History: OK ($currentMaxHistory)"
                Write-Host $text
            }

            if ($script:MonitorOnly) {
                Add-Finding -Log $Log -Text "Client log size $currentLogSize KB / history $currentMaxHistory, expected $clientLogSize KB / $clientLogMaxHistory"
                return $false
            }
            $newLogSize = [int]$clientLogSize
            $newLogSize = $newLogSize * 1000
            # The client ignores LogMaxSize below 10000 bytes.
            if ($newLogSize -lt 10000) { $newLogSize = 10000 }

            <#
            if ($PowerShellVersion -ge 6) {Invoke-CimMethod -Namespace "root/ccm" -ClassName "sms_client" -MethodName SetGlobalLoggingConfiguration -Arguments @{LogLevel=$loglevel; LogMaxHistory=$clientLogMaxHistory; LogMaxSize=$newLogSize} }
            else {
                $smsClient = [wmiclass]"root/ccm:sms_client"
                $smsClient.SetGlobalLoggingConfiguration($logLevel, $newLogSize, $clientLogMaxHistory)
            }
            #Write-Verbose 'Returning true to trigger restart of ccmexec service'
            #>
            
            # Rewrote after the WMI Method stopped working in previous CM client version
            New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\CCM\Logging\@GLOBAL" -Name LogMaxHistory -PropertyType DWORD -Value $clientLogMaxHistory -Force | Out-Null
            New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\CCM\Logging\@GLOBAL" -Name LogMaxSize -PropertyType DWORD -Value $newLogSize -Force | Out-Null

            #Write-Verbose 'Sleeping for 5 seconds to allow WMI method complete before we collect new results...'
            #Start-Sleep -Seconds 5

            try { $Log.MaxLogSize = Get-ClientMaxLogSize }
            catch { $Log.MaxLogSize = 0 }
            try { $Log.MaxLogHistory = Get-ClientMaxLogHistory }
            catch { $Log.MaxLogHistory = 0 }
            $obj = $true
        }
        Write-Output $obj
    }

    Function Remove-CCMOrphanedCache {
        Write-Host "Clearing ConfigMgr orphaned Cache items."
        try {
            $CCMCache = "$env:SystemDrive\Windows\ccmcache"
            $CCMCache = (New-Object -ComObject "UIResource.UIResourceMgr").GetCacheInfo().Location
            if ($null -eq $CCMCache) { $CCMCache = "$env:SystemDrive\Windows\ccmcache" }
            $ValidCachedFolders = (New-Object -ComObject "UIResource.UIResourceMgr").GetCacheInfo().GetCacheElements() | ForEach-Object {$_.Location}
            $AllCachedFolders = (Get-ChildItem -Path $CCMCache) | Select-Object Fullname -ExpandProperty Fullname

            ForEach ($CachedFolder in $AllCachedFolders) {
                If ($ValidCachedFolders -notcontains $CachedFolder) {
                    #Don't delete new folders that might be syncing data with BITS
                    if ((Get-ItemProperty $CachedFolder).LastWriteTime -le (get-date).AddDays(-14)) {
                        Write-Verbose "Removing orphaned folder: $CachedFolder - LastWriteTime: $((Get-ItemProperty $CachedFolder).LastWriteTime)"
                        Remove-Item -Path $CachedFolder -Force -Recurse
                    }
                }
            }
        }
        catch { Write-Host "Failed Clearing ConfigMgr orphaned Cache items." }
        }

    Function Test-ManagementPointName {
        Param([Parameter(Mandatory=$false)][string]$ManagementPoint)

        if ([string]::IsNullOrWhiteSpace($ManagementPoint)) { return $false }
        if ($ManagementPoint -notmatch '\A[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\z') { return $false }
        if ($ManagementPoint -match '\.\.') { return $false }
        return $true
    }

    # Downloaded installers run as SYSTEM. Anything other than a valid Microsoft signature is refused.
    # OriginalFilename narrows an executable to the expected program; MSI files carry no version resource.
    Function Test-MicrosoftSignedFile {
        Param(
            [Parameter(Mandatory=$true)][string]$Path,
            [string]$OriginalFilename
        )

        $fileName = Split-Path $Path -Leaf
        try {
            $signature = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
            if ($signature.Status -ne 'Valid') {
                Write-Warning "$fileName signature status is '$($signature.Status)': $($signature.StatusMessage)"
                return $false
            }
            if ($signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
                Write-Warning "$fileName is signed by an unexpected publisher: $($signature.SignerCertificate.Subject)"
                return $false
            }
            # Get-AuthenticodeSignature does not check revocation. Only a confirmed revocation is refused:
            # an offline site cannot reach the CRL, and expired-but-timestamped signer certificates are normal.
            $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
            $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::Online
            $chain.ChainPolicy.RevocationFlag = [System.Security.Cryptography.X509Certificates.X509RevocationFlag]::EntireChain
            $chain.ChainPolicy.UrlRetrievalTimeout = [TimeSpan]::FromSeconds(15)
            [void]$chain.Build($signature.SignerCertificate)
            $revoked = @($chain.ChainStatus | Where-Object { $_.Status -band [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags]::Revoked })
            if ($revoked.Count -gt 0) {
                Write-Warning "$fileName signer certificate is revoked: $($signature.SignerCertificate.Subject)"
                return $false
            }
            if ($OriginalFilename) {
                $originalName = (Get-Item -LiteralPath $Path).VersionInfo.OriginalFilename
                if ($originalName -ne $OriginalFilename) {
                    Write-Warning "$fileName is a Microsoft binary but not $OriginalFilename (original file name '$originalName')."
                    return $false
                }
            }
            return $true
        }
        catch {
            Write-Warning "Could not verify the $fileName signature: $($_.Exception.Message)"
            return $false
        }
    }

    Function Test-CcmSetupSignature {
        Param([Parameter(Mandatory=$true)][string]$Path)
        return (Test-MicrosoftSignedFile -Path $Path -OriginalFilename 'ccmsetup.exe')
    }
    # ccmsetup relaunches itself and stays resident while it retries a failed install.
    Function Wait-CcmSetup {
        Param(
            [Parameter(Mandatory=$true)][string]$Activity,
            [int]$TimeoutMinutes = 60
        )

        $timer = [Diagnostics.Stopwatch]::StartNew()
        do {
            Start-Sleep -Seconds 5
            $running = [bool](Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue)
            if ($running) { Write-Verbose "ConfigMgr Client $Activity still running" }
        } while ($running -and ($timer.Elapsed.TotalMinutes -lt $TimeoutMinutes))

        if ($running) {
            Write-Warning "ConfigMgr Client $Activity still running after $TimeoutMinutes minutes. Continuing without waiting."
            return $false
        }
        return $true
    }

    # Returns $true when ccmsetup.exe was started. Messages go to the host stream so callers can use the return value.
    Function Resolve-Client {
        Param(
            [Parameter(Mandatory=$false)]$Xml,
            [Parameter(Mandatory=$true)]$ClientInstallProperties,
            [Parameter(Mandatory=$false)]$FirstInstall=$false,
            [Parameter(Mandatory=$false)]$Log
            )

        if ($script:MonitorOnly) {
            if ($Log) { Add-Finding -Log $Log -Text 'Client reinstall needed; device excluded from remediation (NotifyOnly)' }
            return $false
        }

        if (Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue) {
            Write-Warning 'ConfigMgr Client install requested, but ccmsetup.exe is already running.'
            return $false
        }

        # Source of truth for ccmsetup.exe is the MP. Random-pick from configured list,
        # iterate on failure so a single down MP doesn't sink the install.
        $mps = @(Get-XMLConfigManagementPoints | Where-Object { Test-ManagementPointName -ManagementPoint $_ })
        if ($mps.Count -eq 0) {
            $text = 'ERROR: Client tagged for reinstall, but no valid Management Points are configured. Set Client.ManagementPoints in config (array of MP FQDNs).'
            Write-Error $text
            if ($Log) { New-ClientInstalledReason -Log $Log -Message 'Install failed: no management point configured.' }
            $script:FailureCount++
            return $false
        }

        # Deprecation warning: Client.Share is no longer used for ccmsetup resolution.
        $deprecatedShare = Get-XMLConfigClientShare
        if (-not [string]::IsNullOrWhiteSpace($deprecatedShare)) {
            Write-Warning "Client.Share ('$deprecatedShare') is deprecated. ccmsetup.exe is sourced from the MP. Remove the Share field from config to silence this warning."
        }

        $useHttps = Get-XMLConfigMPHttps
        $scheme = if ($useHttps) { 'https' } else { 'http' }
        Enable-Tls12

        $stateDir = Join-Path $env:ProgramData 'ConfigMgrClientHealth'
        if (-not (Initialize-SecureDirectory -Path $stateDir)) {
            Write-Error "ERROR: Could not create a protected download folder at '$stateDir'. ccmsetup.exe will not be downloaded."
            if ($Log) { New-ClientInstalledReason -Log $Log -Message 'Install failed: download folder not protected.' }
            $script:FailureCount++
            return $false
        }
        $downloadDir = Join-Path $stateDir 'ccmsetup'
        if (-not (Test-Path -LiteralPath $downloadDir)) { New-Item -Path $downloadDir -ItemType Directory -Force | Out-Null }
        $tempCcmSetup = Join-Path $downloadDir 'ccmsetup.exe'

        $shuffled = @($mps | Get-Random -Count $mps.Count)
        $ccmSetupPath = $null
        $selectedMp = $null
        $attemptErrors = @()

        foreach ($candidate in $shuffled) {
            $downloadUrl = "$($scheme)://$candidate/CCM_Client/ccmsetup.exe"
            try {
                if (Test-Path -LiteralPath $tempCcmSetup) { Remove-Item -LiteralPath $tempCcmSetup -Force -ErrorAction Stop }
                Write-Verbose "Downloading ccmsetup.exe from MP: $downloadUrl"
                Invoke-WebRequest -Uri $downloadUrl -OutFile $tempCcmSetup -UseBasicParsing -ErrorAction Stop
                if (-not (Test-Path -LiteralPath $tempCcmSetup -PathType Leaf)) { throw 'Download produced no file.' }
                if (-not (Test-CcmSetupSignature -Path $tempCcmSetup)) {
                    Remove-Item -LiteralPath $tempCcmSetup -Force -ErrorAction SilentlyContinue
                    throw 'Downloaded file failed signature validation.'
                }
                $ccmSetupPath = $tempCcmSetup
                $selectedMp = $candidate
                Write-Host "Downloaded ccmsetup.exe from Management Point: $candidate"
                break
            }
            catch {
                $attemptErrors += "${candidate}: $($_.Exception.Message)"
                Write-Warning "Failed to download ccmsetup.exe from $downloadUrl : $($_.Exception.Message)"
            }
        }

        if (-not $ccmSetupPath) {
            $text = 'ERROR: Client tagged for reinstall, but ccmsetup.exe could not be downloaded from any configured MP. '
            $text += "Tried: $([string]::Join('; ', $attemptErrors))"
            Write-Error $text
            if ($Log) { New-ClientInstalledReason -Log $Log -Message 'Install failed: ccmsetup download failed.' }
            $script:FailureCount++
            return $false
        }

        # ccmsetup switches go before client.msi properties. Stale MP / SMSMP / /mp tokens are replaced, so
        # the management point list is maintained in one place. The picked MP is first; the others follow.
        $orderedMps = @($selectedMp) + @($shuffled | Where-Object { $_ -ne $selectedMp })
        $mpValues = @($orderedMps | ForEach-Object { if ($useHttps) { "https://$_" } else { $_ } })
        $configTokens = @($ClientInstallProperties -split '\s+' | Where-Object {
            $_ -and ($_ -notmatch '^(SMSMP|MP|SMSMPLIST)=') -and ($_ -notmatch '^/mp:') -and ($_ -notmatch '^/forceinstall$')
        })
        $switches = @($configTokens | Where-Object { $_.StartsWith('/') })
        $properties = @($configTokens | Where-Object { -not $_.StartsWith('/') })
        $switches = @("/mp:$([string]::Join(';', $orderedMps))") + $switches
        # /forceinstall uninstalls the existing client first; without it a same-version install repairs in place.
        if ($Uninstall -eq $true) { $switches += '/forceinstall' }
        $properties += "SMSMP=$($mpValues[0])"
        if ($mpValues.Count -gt 1) { $properties += "SMSMPLIST=$([string]::Join(';', $mpValues))" }
        $argArray = @($switches + $properties)

        if ($FirstInstall -eq $true) { $text = 'Installing Configuration Manager Client.' }
        else { $text = 'Client tagged for reinstall. Reinstalling client...' }
        Write-Host $text

        Write-Verbose "Perform a test on a specific registry key required for ccmsetup to succeed."
        Test-CCMSetup1

        # Re-check immediately before execution; the download folder is protected, so this guards only
        # against replacement by another administrator-level process.
        if (-not (Test-CcmSetupSignature -Path $ccmSetupPath)) {
            Write-Error 'ERROR: ccmsetup.exe changed after download and failed signature validation. Install aborted.'
            if ($Log) { New-ClientInstalledReason -Log $Log -Message 'Install failed: ccmsetup signature invalid.' }
            $script:FailureCount++
            return $false
        }

        Write-Verbose "Client install string: $ccmSetupPath $([string]::Join(' ', $argArray))"
        $installStart = Get-Date
        Start-Process -FilePath $ccmSetupPath -ArgumentList $argArray -NoNewWindow
        Wait-CcmSetup -Activity 'installation' | Out-Null
        $script:ClientReinstalledThisRun = $true

        # The bootstrapper exits early and the ccmsetup service does the work; its result is in ccmsetup.log.
        $exitLine = Get-CMLogEntry -LogFile (Join-Path $env:windir 'ccmsetup\Logs\ccmsetup.log') -StartTime $installStart |
            Where-Object { $_.Message -match 'CcmSetup is exiting with return code (\d+)' } | Select-Object -Last 1
        if ($exitLine) {
            $returnCode = [int]([regex]::Match($exitLine.Message, 'return code (\d+)').Groups[1].Value)
            if ($returnCode -eq 7) { Write-Host 'ccmsetup finished; a restart is required.' }
            elseif ($returnCode -ne 0) {
                if ($Log) { New-ClientInstalledReason -Log $Log -Message "Install failed: ccmsetup return code $returnCode." }
                $script:FailureCount++
            }
        }

        if ($FirstInstall -eq $true) {
            Write-Host "ConfigMgr Client was installed for the first time. Waiting 6 minutes for client to syncronize policy before proceeding."
            Start-Sleep -Seconds 360
        }
        return $true
    }

    # winmgmt /verifyrepository sets exit code 1358 (ERROR_INTERNAL_DB_CORRUPTION) for an inconsistent repository.
    # A failed query alone can come from any provider and is reported, not repaired.
    Function Test-WMI {
        Param([Parameter(Mandatory=$true)]$Log)

        & (Join-Path $env:SystemRoot 'System32\wbem\winmgmt.exe') /verifyrepository | Out-Null
        $corrupt = ($LASTEXITCODE -eq 1358)

        if (-not $corrupt) {
            try {
                Invoke-WithRetry -OperationName 'WMI query' -MaxRetries 3 -DelaySeconds 10 -ScriptBlock {
                    Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop | Out-Null
                }
                $log.WMI = 'OK'
                Write-Host 'WMI Check: OK'
            }
            catch {
                $log.WMI = 'Query failed'
                Add-Finding -Log $Log -Text "WMI query failed: $($_.Exception.Message)"
            }
            return $false
        }

        if (ConvertTo-ConfigBoolean (Get-XMLConfigWMIRepairEnable)) {
            Write-Warning 'WMI Check: repository inconsistent. Salvaging the repository and tagging the ConfigMgr client for reinstall.'
            Repair-WMI
            $log.WMI = 'Repaired'
        }
        else {
            Write-Warning 'WMI Check: repository inconsistent. Autofix is disabled'
            $log.WMI = 'Corrupt'
        }
        return $true
    }

    # Microsoft's order is verify, salvage, verify. /resetrepository returns the repository to its state at
    # OS installation and drops namespaces that some software never rebuilds, so it is never run here.
    Function Repair-WMI {
        $winmgmt = Join-Path $env:SystemRoot 'System32\wbem\winmgmt.exe'
        $backup = Join-Path $env:ProgramData "ConfigMgrClientHealth\wmi-backup-$(Get-Date -Format 'yyyyMMddHHmmss').rep"
        if (Initialize-SecureDirectory -Path (Split-Path $backup -Parent)) { & $winmgmt /backup $backup | Out-Null }
        & $winmgmt /salvagerepository | Out-Null
        & $winmgmt /verifyrepository | Out-Null
        if ($LASTEXITCODE -eq 1358) { Write-Warning 'WMI repository still inconsistent after salvage. The client reinstall rebuilds the ConfigMgr namespaces.' }
        else { Write-Host 'WMI repository salvaged.' }
        # ccmexec does not start again by itself after WMI restarts.
        Start-Service -Name ccmexec -ErrorAction SilentlyContinue
    }

    # Test if the compliance state messages should be resent.
    Function Test-RefreshComplianceState {
        Param(
            $Days=0,
            [Parameter(Mandatory=$true)]$RegistryKey,
            [Parameter(Mandatory=$true)]$Log
        )
        $RegValueName="RefreshServerComplianceState"

        #Get the last time this script was ran.  If the registry isn't found just use the current date.
        Try { [datetime]$LastSent = Get-RegistryValue -Path $RegistryKey -Name $RegValueName }
        Catch { [datetime]$LastSent = Get-Date }

        Write-Verbose "The compliance states were last sent on $($LastSent)"
        #Determine the number of days until the next run.
        $NumberOfDays = (New-Timespan -Start (Get-Date) -End ($LastSent.AddDays($Days))).Days

        #Resend complianc states if the next interval has already arrived or randomly based on the number of days left until the next interval.
        If (($NumberOfDays -le 0) -or ((Get-Random -Maximum $NumberOfDays) -eq 0 )){
            Try{
                Write-Verbose "Resending compliance states."
                (New-Object -ComObject Microsoft.CCM.UpdatesStore).RefreshServerComplianceState()
                $LastSent=Get-Date
                Write-Output "Compliance States: Refreshed."
            }
            Catch{
                Write-Error "Failed to resend the compliance states."
                $LastSent=[datetime]::MinValue
            }
        }
        Else{
            Write-Output "Compliance States: OK."
        }

        Set-RegistryValue -Path $RegistryKey -Name $RegValueName -Value $LastSent
        # smalldatetime starts at 1900-01-01; MinValue marks a failed refresh and is reported as NULL.
        if ($LastSent -gt [datetime]'1900-01-02') { $Log.RefreshComplianceState = Get-SmallDateTime $LastSent }
        else { $Log.RefreshComplianceState = $null }


    }


    # Report only: Microsoft does not support changing the configuration of ConfigMgr services.
    Function Test-SMSTSMgr {
        Param([Parameter(Mandatory=$true)]$Log)
        $service = Get-Service -Name smstsmgr -ErrorAction SilentlyContinue
        if (-not $service) { Write-Host "SMSTSMgr: not installed"; return }
        $dependsOn = @($service.ServicesDependedOn | ForEach-Object { $_.Name })
        if ($dependsOn -contains 'ccmexec') { Add-Finding -Log $Log -Text 'smstsmgr depends on ccmexec' }
        else { Write-Host "SMSTSMgr: OK" }
    }


    # Windows Service Functions
    Function Test-Services {
        Param([Parameter(Mandatory=$false)]$Xml, $log, $Webservice, $ProfileID)

        $log.Services = 'OK'

        # Determine service list from JSON or XML config
        if ($script:JsonConfig) {
            Write-Verbose 'Test services from JSON configuration file'
            $serviceList = $script:JsonConfig.Services
        }
        else {
            Write-Verbose 'Test services from XML configuration file'
            $serviceList = $Xml.Configuration.Service
        }

        foreach ($service in $serviceList)
        {
            $startuptype = ($service.StartupType).ToLower()

            if ($startuptype -like "automatic (delayed start)") { $service.StartupType = "automaticd" }

            if ($service.Uptime) {
                $uptime = ($service.Uptime).ToLower()
                Test-Service -Name $service.Name -StartupType $service.StartupType -State ([string]$service.State) -Log $log -Uptime $uptime
            }
            else {
                Test-Service -Name $service.Name -StartupType $service.StartupType -State ([string]$service.State) -Log $log
            }
        }
    }

    Function Test-Service {
        param(
        [Parameter(Mandatory=$True,
                    HelpMessage='Name')]
                    [string]$Name,
        [Parameter(Mandatory=$True,
                    HelpMessage='StartupType: Automatic, Automatic (Delayed Start), Manual, Disabled')]
                    [string]$StartupType,
        [Parameter(Mandatory=$True,
                    HelpMessage='State: Running, Stopped, or empty to leave the state unchanged')]
                    [AllowEmptyString()]
                    [string]$State,
        [Parameter(Mandatory=$False,
                    HelpMessage='Updatime in days')]
                    [int]$Uptime,
        [Parameter(Mandatory=$True)]$log
        )

        $OSName = Get-OperatingSystem

        # StartupType can list accepted values separated by '|'; the first one is applied when none matches.
        # Handle all sorts of casing and mispelling of delayed and triggerd start in config.xml services
        $acceptedStartupTypes = @(foreach ($candidate in ($StartupType -split '\|')) {
            $candidate = $candidate.Trim()
            switch -Wildcard ($candidate.ToLower()) {
                "automaticd*" { "Automatic (Delayed Start)" }
                "automatic(d*" { "Automatic (Delayed Start)" }
                "automatic (d*" { "Automatic (Delayed Start)" }
                "automatic(t*" { "Automatic (Trigger Start)" }
                "automatict*" { "Automatic (Trigger Start)" }
                "automatic (t*" { "Automatic (Trigger Start)" }
                default { $candidate }
            }
        })
        $StartupType = $acceptedStartupTypes[0]

        if (-not (Get-Service -Name $Name -ErrorAction SilentlyContinue)) {
            Write-Warning "Service $Name is configured but does not exist."
            $log.Services = "Missing: $Name"
            return
        }

        $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$name"

        $DelayedAutostart = (Get-ItemProperty -Path $path).DelayedAutostart
        if ($DelayedAutostart -ne 1) {
            $DelayedAutostart = 0
        }

        $service = Get-Service -Name $Name
        $WMIService = Get-CimInstance -ClassName Win32_Service -Property StartMode, ProcessID, Status -Filter "Name='$Name'"
        $StartMode = ($WMIService.StartMode).ToLower()

        switch -Wildcard ($StartMode) {
            "auto*" {
                if ($DelayedAutostart -eq 1) { $serviceStartType = "Automatic (Delayed Start)" }
                else { $serviceStartType = "Automatic" }
            }

            <# This will be implemented at a later time.
            "automatic d*" {$serviceStartType = "Automatic (Delayed Start)"}
            "automatic (d*" {$serviceStartType = "Automatic (Delayed Start)"}
            "automatic (t*" {$serviceStartType = "Automatic (Trigger Start)"}
            "automatic t*" {$serviceStartType = "Automatic (Trigger Start)"}
            #>
            "manual" {$serviceStartType = "Manual"}
            "disabled" {$serviceStartType = "Disabled"}
        }

        Write-Verbose "Verify startup type"
        if ($acceptedStartupTypes -contains $serviceStartType)
        {
            $text = "Service $Name startup: OK"
            Write-Output $text
        }
        elseif ($StartupType -like "Automatic (Delayed Start)") {
            # Handle Automatic Trigger Start the dirty way for these two services. Implement in a nice way in future version.
            if ( (($name -eq "wuauserv") -or ($name -eq "W32Time")) -and (($OSName -like "Windows 10*") -or ($OSName -like "*Server 2016*")) ) {
                if ($service.StartType -ne "Automatic") {
                    $text = "Configuring service $Name StartupType to: Automatic (Trigger Start)..."
                    Set-Service -Name $service.Name -StartupType Automatic
                }
                else { $text = "Service $Name startup: OK" }
                Write-Output $text
            }
            else {
                # Automatic delayed requires the use of sc.exe
                & sc.exe config $Name start= delayed-auto | Out-Null
                $text = "Configuring service $Name StartupType to: $StartupType..."
                Write-Output $text
                $log.Services = 'Started'
            }
        }

        else {
            try {
                $text = "Configuring service $Name StartupType to: $StartupType..."
                Write-Output $text
                Set-Service -Name $service.Name -StartupType $StartupType
                $log.Services = 'Started'
            }
            catch {
                $text = "Failed to set $StartupType StartupType on service $Name"
                Write-Error $text
            }
        }

        if ([string]::IsNullOrWhiteSpace($State)) { return }

        if ($State -like 'Stopped') {
            Write-Verbose 'Verify service is stopped'
            if ($service.Status -eq 'Stopped') { Write-Output "Service $Name stopped: OK" }
            else {
                try {
                    Write-Output "Stopping service: $Name..."
                    Stop-Service -Name $Name -Force -ErrorAction Stop
                    $log.Services = 'Stopped'
                }
                catch { Write-Error "Failed to stop service $Name" }
            }
            return
        }

        Write-Verbose 'Verify service is running'
        if ($service.Status -eq "Running") {
            $text = 'Service ' +$Name+' running: OK'
            Write-Output $text

            #If we are checking uptime.
            If ($Uptime){
                Write-Verbose "Verify the $($Name) service hasn't exceeded uptime of $($Uptime) days."
                $ServiceUptime= Get-ServiceUpTime -Name $Name
                if ($ServiceUptime -ge $Uptime) {
                    try {

                        #Before restarting the service wait for some known processes to end.  Restarting the service while an app or updates is installing might cause issues.
                        $Timer = [Diagnostics.Stopwatch]::StartNew()
                        $WaitMinutes = 30
                        $ProcessesStopped=$True
                        While ((Get-Process -Name WUSA,wuauclt,setup,TrustedInstaller,msiexec,TiWorker,ccmsetup -ErrorAction SilentlyContinue).Count -gt 0){
                            $MinutesLeft = $WaitMinutes - $Timer.Elapsed.Minutes

                            If($MinutesLeft -le 0){
                                Write-Warning "Timed out waiting $($WaitMinutes) minutes for installation processes to complete.  Will not restart the $($Name) service."
                                $ProcessesStopped=$False
                                Break
                            }
                            Write-Warning "Waiting $($MinutesLeft) minutes for installation processes to complete."
                            Start-Sleep -Seconds 30
                        }
                        $Timer.Stop()

                        #If the processes are not running the restart the service.
                        If ($ProcessesStopped){
                            Write-Output "Restarting service: $($Name)..."
                            Restart-Service  -Name $service.Name -Force
                            Write-Output "Restarted service: $($Name)..."
                            $log.Services = 'Restarted'
                        }
                    } catch {
                        $text = "Failed to restart service $($Name)"
                        Write-Error $text
                    }
                }
                else {
                    Write-Output "Service $($Name) uptime: OK"
                }
            }
        }
        else {
            if ($WMIService.Status -eq 'Degraded') {
                try {
                    Write-Warning "Identified $Name service in a 'Degraded' state. Will force $Name process to stop."
                    $ServicePID = $WMIService | Select-Object -ExpandProperty ProcessID
                    Stop-Process -ID $ServicePID -Force:$true -Confirm:$false -ErrorAction Stop
                    Write-Verbose "Succesfully stopped the $Name service process which was in a degraded state."
                }
                Catch{
                    Write-Error "Failed to force $Name process to stop."
                }
            }
            try {
                $RetryService= $False
                $text = 'Starting service: ' + $Name + '...'
                Write-Output $text
                Start-Service -Name $service.Name -ErrorAction Stop
                $log.Services = 'Started'
            } catch {
                #Error 1290 (-2146233087) indicates that the service is sharing a thread with another service that is protected and cannot share its thread.
                #This is resolved by configuring the service to run on its own thread.
                If ($_.Exception.Hresult -eq '-2146233087'){
                    Write-Output "Failed to start service $Name because it's sharing a thread with another process.  Changing to use its own thread."
                    & cmd /c sc config $Name type= own
                    $RetryService= $True
                }
                Else{
                    $text = 'Failed to start service ' +$Name
                    Write-Error $text
                }
            }

            #If a recoverable error was found, try starting it again.
            If ($RetryService){
                try {
                    Start-Service -Name $service.Name -ErrorAction Stop
                    $log.Services = 'Started'
                } catch {
                    $text = 'Failed to start service ' +$Name
                    Write-Error $text
                }
            }
        }
    }

    function Test-AdminShare {
        Param([Parameter(Mandatory=$true)]$Log)
        Write-Verbose "Test the ADMIN$ and C$"
        $share = Get-CimInstance -ClassName Win32_Share | Where-Object {$_.Name -like 'ADMIN$'}
        #$shareClass = [WMICLASS]"WIN32_Share"  # Depreciated

        if ($share.Name -contains 'ADMIN$') {
            $text = 'Adminshare Admin$: OK'
            Write-Output $text
        }
        else { $fix = $true }

        $share = Get-CimInstance -ClassName Win32_Share | Where-Object {$_.Name -like 'C$'}
        #$shareClass = [WMICLASS]'WIN32_Share'  # Depreciated

        if ($share.Name -contains "C$") {
            $text = 'Adminshare C$: OK'
            Write-Output $text
        }
        else { $fix = $true }

        # AutoShareWks / AutoShareServer = 0 disables admin shares by design; restarting the Server service cannot fix that.
        $lanmanParameters = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -ErrorAction SilentlyContinue
        $sharesDisabled = ($lanmanParameters.PSObject.Properties['AutoShareWks'] -and $lanmanParameters.AutoShareWks -eq 0) -or
                          ($lanmanParameters.PSObject.Properties['AutoShareServer'] -and $lanmanParameters.AutoShareServer -eq 0)

        if (($fix -eq $true) -and $script:MonitorOnly) {
            Add-Finding -Log $Log -Text 'Admin shares missing'
            $log.AdminShare = 'Missing'
        }
        elseif (($fix -eq $true) -and $sharesDisabled) {
            Write-Warning 'Adminshares are disabled by the AutoShareWks/AutoShareServer registry setting. No remediation.'
            $log.AdminShare = 'Disabled'
        }
        elseif (($fix -eq $true) -and ((Get-CimInstance -ClassName Win32_OperatingSystem).ProductType -ne 1)) {
            # Restarting the Server service on a server drops every open SMB session.
            Add-Finding -Log $Log -Text 'Admin shares missing on a server; restart the computer'
            $log.AdminShare = 'Missing'
        }
        elseif ($fix -eq $true) {
            $text = 'Error with Adminshares. Remediating...'
            $log.AdminShare = 'Repaired'
            Write-Warning $text
            $runningDependents = @((Get-Service -Name server).DependentServices | Where-Object { $_.Status -eq 'Running' } | Select-Object -ExpandProperty Name)
            Stop-Service server -Force
            Start-Service server
            foreach ($dependent in $runningDependents) { Start-Service -Name $dependent -ErrorAction SilentlyContinue }
        }
        else { $log.AdminShare = 'OK' }
    }

    Function Test-DiskSpace {
        $XMLDiskSpace = Get-XMLConfigOSDiskFreeSpace
        $driveC = Get-CimInstance -ClassName Win32_LogicalDisk | Where-Object {$_.DeviceID -eq "$env:SystemDrive"} | Select-Object FreeSpace, Size
        $freeSpace = (($driveC.FreeSpace / $driveC.Size) * 100)

        if ($freeSpace -le $XMLDiskSpace) {
            $text = "Local disk $env:SystemDrive Less than $XMLDiskSpace % free space"
            Write-Error $text
        }
        else {
            $text ="Free space $env:SystemDrive OK"
            Write-Output $text
        }
    }



    Function Get-UBR {
        $UBR = (Get-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion').UBR
        Write-Output $UBR
    }

    Function Get-LastReboot {
        Param([Parameter(Mandatory=$false)][xml]$Xml)

        # Only run if option in config is enabled
        if (ConvertTo-ConfigBoolean (Get-XMLConfigRebootApplicationEnable)) {

            [float]$maxRebootDays = ConvertTo-ConfigInt -Value (Get-XMLConfigMaxRebootDays) -Default 7 -Minimum 1
            $wmi = Get-CimInstance -ClassName Win32_OperatingSystem

            $lastBootTime = $wmi.LastBootUpTime

            $uptime = (Get-Date) - $wmi.LastBootUpTime
            if ($uptime.TotalDays -lt $maxRebootDays) {
                $text = 'Last boot time: ' +$lastBootTime + ': OK'
                Write-Output $text
            }
            else {
                $text = 'Last boot time: ' +$lastBootTime + ': More than '+$maxRebootDays +' days since last reboot. Starting reboot application.'
                Write-Warning $text
                Start-RebootApplication
            }
        }
    }

    Function Get-RebootApplicationCommand {
        Param([Parameter(Mandatory=$false)][string]$CommandLine)

        $commandLine = ([string]$CommandLine).Trim()
        if (-not $commandLine) { return $null }
        if ($commandLine -match '^"([^"]+)"\s*(.*)$') { return [pscustomobject]@{ Execute = $Matches[1]; Argument = $Matches[2].Trim() } }
        # An unquoted path may contain spaces: split after the first ".exe".
        if ($commandLine -match '^(.+?\.exe)(\s+(.*))?$') { return [pscustomobject]@{ Execute = $Matches[1]; Argument = ([string]$Matches[3]).Trim() } }
        $parts = $commandLine -split '\s+', 2
        return [pscustomobject]@{ Execute = $parts[0]; Argument = if ($parts.Count -gt 1) { $parts[1] } else { '' } }
    }

    # The task runs in the session of each logged-on user (BUILTIN\Users). It is registered again on
    # every start, so a changed RebootApplication.Application takes effect.
    Function Start-RebootApplication {
        $taskName = 'ConfigMgr Client Health - Reboot on demand'
        $command = Get-RebootApplicationCommand -CommandLine (Get-XMLConfigRebootApplication)
        if (-not $command) {
            Write-Warning 'RebootApplication.Application is empty. No reboot application started.'
            return
        }
        try {
            if ($command.Argument) { $action = New-ScheduledTaskAction -Execute $command.Execute -Argument $command.Argument }
            else { $action = New-ScheduledTaskAction -Execute $command.Execute }
            $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
            Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
            Start-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop
        }
        catch { Write-Warning "Could not start the reboot application: $($_.Exception.Message)" }
    }

    Function Start-Ccmeval {
        Write-Host "Starting Built-in Configuration Manager Client Health Evaluation"
        $task = "Microsoft\Configuration Manager\Configuration Manager Health Evaluation"
        schtasks.exe /Run /TN $task | Out-Null
    }

    Function Test-MissingDrivers {
        Param([Parameter(Mandatory=$true)]$Log)
        $FileLogLevel = ([string](Get-XMLConfigLoggingLevel)).ToLower()
        $i = 0
        $devices = Get-CimInstance -ClassName Win32_PNPEntity | Where-Object{ ($_.ConfigManagerErrorCode -ne 0) -and ($_.ConfigManagerErrorCode -ne 22) -and ($_.Name -notlike "*PS/2*") } | Select-Object Name, DeviceID
        $devices | ForEach-Object {$i++}

        if ($null -ne $devices) {
            $text = "Drivers: $i unknown or faulty device(s)"
            Write-Warning $text
            $log.Drivers = "$i unknown or faulty driver(s)"

            foreach ($device in $devices) {
                $text = 'Missing or faulty driver: ' +$device.Name + '. Device ID: ' + $device.DeviceID
                Write-Warning $text
                if (-NOT($FileLogLevel -like "clientlocal")) { Out-LogFile -Xml $xml -Text $text -Severity 2}
            }
        }
        else {
            $text = "Drivers: OK"
            Write-Output $text
            $log.Drivers = 'OK'
        }
    }



    Function Test-SCCMHardwareInventoryScan {
        Param([Parameter(Mandatory=$true)]$Log)

        Write-Verbose "Start Test-SCCMHardwareInventoryScan"
        $days = ConvertTo-ConfigInt -Value (Get-XMLConfigHardwareInventoryDays) -Default 10 -Minimum 1
        $wmi = Get-CimInstance -Namespace root\ccm\invagt -ClassName InventoryActionStatus | Where-Object {$_.InventoryActionID -eq '{00000000-0000-0000-0000-000000000001}'} | Select-Object @{label='HWSCAN';expression={$_.LastCycleStartedDate}}
        $HWScanRaw = $wmi | Select-Object -ExpandProperty HWSCAN
        # Get-SmallDateTime returns the current time for $null, which would report a never-run scan as current.
        if ($null -eq $HWScanRaw) { $HWScanDate = $null }
        else { $HWScanDate = Get-SmallDateTime $HWScanRaw }
        $minDate = Get-SmallDateTime((Get-Date).AddDays(-$days))
        if (($null -eq $HWScanDate) -or ($HWScanDate -le $minDate)) {
            if (ConvertTo-ConfigBoolean (Get-XMLConfigHardwareInventoryFix)) {
                $text = "ConfigMgr Hardware Inventory scan: $HWScanDate. Starting hardware inventory scan of the client."
                Write-Host $Text
                Invoke-CCMTrigger -ScheduleID '{00000000-0000-0000-0000-000000000001}'

                # Get the new date after policy trigger
                $wmi = Get-CimInstance -Namespace root\ccm\invagt -ClassName InventoryActionStatus | Where-Object {$_.InventoryActionID -eq '{00000000-0000-0000-0000-000000000001}'} | Select-Object @{label='HWSCAN';expression={$_.LastCycleStartedDate}}
                $HWScanRaw = $wmi | Select-Object -ExpandProperty HWSCAN
                if ($null -ne $HWScanRaw) { $HWScanDate = Get-SmallDateTime -Date $HWScanRaw }
            }
            else {
                # No need to update anything if fix = false. Last date will still be set in log
            }


        }
        else {
            $text = "ConfigMgr Hardware Inventory scan: OK"
            Write-Output $text
        }
        $log.HWInventory = $HWScanDate
        Write-Verbose "End Test-SCCMHardwareInventoryScan"
    }



    # Get the clients SiteName in Active Directory
    Function Get-ClientSiteName {
        try {
            $obj = (Get-CimInstance -ClassName Win32_NTDomain).ClientSiteName
        }
        catch {$obj = $false}
        finally { if ($obj -ne $false) { Write-Output ($obj | Select-Object -First 1) } }
    }

    # Resolve site-specific config overrides from the Sites section of config.json
    Function Get-SiteConfig {
        Param([string]$PropertyName)

        if (-not $script:JsonConfig -or -not $script:JsonConfig.Sites) { return $null }

        if (-not $script:ResolvedADSite) {
            $script:ResolvedADSite = Get-ClientSiteName
            if (-not $script:ResolvedADSite) { $script:ResolvedADSite = '_none_' }
            Write-Verbose "AD Site resolved: $($script:ResolvedADSite)"
        }

        $sites = $script:JsonConfig.Sites
        $adSite = $script:ResolvedADSite

        # A present but empty value ("" or []) means "not set" and falls through to Default.
        $hasValue = {
            param($value)
            if ($null -eq $value) { return $false }
            if ($value -is [string]) { return -not [string]::IsNullOrWhiteSpace($value) }
            if ($value -is [array]) { return @($value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0 }
            return $true
        }

        # Try site-specific override first
        if ($adSite -ne '_none_' -and $sites.PSObject.Properties[$adSite]) {
            $siteObj = $sites.$adSite
            if ($siteObj.PSObject.Properties[$PropertyName] -and (& $hasValue $siteObj.$PropertyName)) {
                Write-Verbose "Site config: using $PropertyName from site '$adSite'"
                return $siteObj.$PropertyName
            }
        }

        # Fall back to Default
        if ($sites.PSObject.Properties['Default'] -and $sites.Default.PSObject.Properties[$PropertyName] -and (& $hasValue $sites.Default.$PropertyName)) {
            return $sites.Default.$PropertyName
        }

        return $null
    }

    Function Test-SoftwareMeteringPrepDriver {
        Param(
            [Parameter(Mandatory=$true)]$Log,
            [datetime]$StartTime = [datetime]::MinValue
        )
        # Returns $false when ccmexec must restart after the fix. Only lines written since the last run count,
        # so the log is not edited to stop an old error from triggering the fix again.
        $entries = @(Get-CMLogEntry -LogFile (Join-Path (Get-CCMLogDirectory) 'mtrmgr.log') -StartTime $StartTime)
        $failed = @($entries | Where-Object { $_.Message -match 'StartPrepDriver - OpenService Failed with Error|Software Metering failed to start PrepDriver' }).Count -gt 0

        if (-not $failed) {
            Write-Host "Software Metering - PrepDriver: OK"
            $Log.SWMetering = "OK"
            return $true
        }
        if (-not (ConvertTo-ConfigBoolean (Get-XMLConfigSoftwareMeteringFix))) {
            $Log.SWMetering = "Error"
            return $true
        }

        Write-Host "Software Metering - PrepDriver: Error. Remediating..."
        $inf = Join-Path (Get-CCMDirectory) 'prepdrv.inf'
        & (Join-Path $env:windir 'System32\rundll32.exe') SETUPAPI.DLL,InstallHinfSection DefaultInstall 128 $inf
        $Log.SWMetering = "Remediated"
        return $false
    }


    # SCCM Client evaluation policies - consolidated trigger function
    Function Invoke-CCMTrigger {
        Param([Parameter(Mandatory=$true)][string]$ScheduleID)
        try {
            Invoke-CimMethod -Namespace 'root\ccm' -ClassName 'sms_client' -MethodName 'TriggerSchedule' -Arguments @{sScheduleID = $ScheduleID} -ErrorAction Stop | Out-Null
        }
        catch { Write-Warning "Could not trigger client schedule $ScheduleID : $($_.Exception.Message)" }
    }


    <# Trigger codes
    {00000000-0000-0000-0000-000000000001} Hardware Inventory
    {00000000-0000-0000-0000-000000000002} Software Inventory
    {00000000-0000-0000-0000-000000000003} Discovery Inventory
    {00000000-0000-0000-0000-000000000010} File Collection
    {00000000-0000-0000-0000-000000000011} IDMIF Collection
    {00000000-0000-0000-0000-000000000012} Client Machine Authentication
    {00000000-0000-0000-0000-000000000021} Request Machine Assignments
    {00000000-0000-0000-0000-000000000022} Evaluate Machine Policies
    {00000000-0000-0000-0000-000000000023} Refresh Default MP Task
    {00000000-0000-0000-0000-000000000024} LS (Location Service) Refresh Locations Task
    {00000000-0000-0000-0000-000000000025} LS (Location Service) Timeout Refresh Task
    {00000000-0000-0000-0000-000000000026} Policy Agent Request Assignment (User)
    {00000000-0000-0000-0000-000000000027} Policy Agent Evaluate Assignment (User)
    {00000000-0000-0000-0000-000000000031} Software Metering Generating Usage Report
    {00000000-0000-0000-0000-000000000032} Source Update Message
    {00000000-0000-0000-0000-000000000037} Clearing proxy settings cache
    {00000000-0000-0000-0000-000000000040} Machine Policy Agent Cleanup
    {00000000-0000-0000-0000-000000000041} User Policy Agent Cleanup
    {00000000-0000-0000-0000-000000000042} Policy Agent Validate Machine Policy / Assignment
    {00000000-0000-0000-0000-000000000043} Policy Agent Validate User Policy / Assignment
    {00000000-0000-0000-0000-000000000051} Retrying/Refreshing certificates in AD on MP
    {00000000-0000-0000-0000-000000000061} Peer DP Status reporting
    {00000000-0000-0000-0000-000000000062} Peer DP Pending package check schedule
    {00000000-0000-0000-0000-000000000063} SUM Updates install schedule
    {00000000-0000-0000-0000-000000000101} Hardware Inventory Collection Cycle
    {00000000-0000-0000-0000-000000000102} Software Inventory Collection Cycle
    {00000000-0000-0000-0000-000000000103} Discovery Data Collection Cycle
    {00000000-0000-0000-0000-000000000104} File Collection Cycle
    {00000000-0000-0000-0000-000000000105} IDMIF Collection Cycle
    {00000000-0000-0000-0000-000000000106} Software Metering Usage Report Cycle
    {00000000-0000-0000-0000-000000000107} Windows Installer Source List Update Cycle
    {00000000-0000-0000-0000-000000000108} Software Updates Assignments Evaluation Cycle
    {00000000-0000-0000-0000-000000000109} Branch Distribution Point Maintenance Task
    {00000000-0000-0000-0000-000000000111} Send Unsent State Message
    {00000000-0000-0000-0000-000000000112} State System policy cache cleanout
    {00000000-0000-0000-0000-000000000113} Scan by Update Source
    {00000000-0000-0000-0000-000000000114} Update Store Policy
    {00000000-0000-0000-0000-000000000115} State system policy bulk send high
    {00000000-0000-0000-0000-000000000116} State system policy bulk send low
    {00000000-0000-0000-0000-000000000121} Application manager policy action
    {00000000-0000-0000-0000-000000000122} Application manager user policy action
    {00000000-0000-0000-0000-000000000123} Application manager global evaluation action
    {00000000-0000-0000-0000-000000000131} Power management start summarizer
    {00000000-0000-0000-0000-000000000221} Endpoint deployment reevaluate
    {00000000-0000-0000-0000-000000000222} Endpoint AM policy reevaluate
    {00000000-0000-0000-0000-000000000223} External event detection
    #>

    function Test-SQLConnection {
        $SQLServer = Get-XMLConfigSQLServer
        $Database = 'ClientHealth'
        $FileLogLevel = ([string](Get-XMLConfigLoggingLevel)).ToLower()

        $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
        $builder['Data Source'] = [string]$SQLServer
        $builder['Initial Catalog'] = $Database
        $builder['Integrated Security'] = $true
        $ConnectionString = $builder.ConnectionString

        try
        {
            $sqlConnection = New-Object System.Data.SqlClient.SqlConnection $ConnectionString;
            try { $sqlConnection.Open() }
            finally { $sqlConnection.Dispose() }

            $obj = $true;
            Write-Verbose "SQL connection test successfull"
        }
        catch {
            $text = "Error connecting to SQLDatabase $Database on SQL Server $SQLServer"
            Write-Error -Message $text
            if (-NOT($FileLogLevel -like "clientinstall")) { Out-LogFile -Xml $xml -Text $text -Severity 3}
            $obj = $false;
            Write-Verbose "SQL connection test failed"
        }
        finally {Write-Output $obj }
    }

    # Invoke-SqlCmd2 - Originally by Chad Miller, modified to support SqlParameters
    function Invoke-Sqlcmd2 {
        [CmdletBinding()]
        param(
        [Parameter(Position=0, Mandatory=$true)] [string]$ServerInstance,
        [Parameter(Position=1, Mandatory=$false)] [string]$Database,
        [Parameter(Position=2, Mandatory=$false)] [string]$Query,
        [Parameter(Position=3, Mandatory=$false)] [string]$Username,
        [Parameter(Position=4, Mandatory=$false)] [string]$Password,
        [Parameter(Position=5, Mandatory=$false)] [Int32]$QueryTimeout=600,
        [Parameter(Position=6, Mandatory=$false)] [Int32]$ConnectionTimeout=15,
        [Parameter(Position=7, Mandatory=$false)] [ValidateScript({test-path $_})] [string]$InputFile,
        [Parameter(Position=8, Mandatory=$false)] [ValidateSet("DataSet", "DataTable", "DataRow")] [string]$As="DataRow",
        [Parameter(Mandatory=$false)] [System.Data.SqlClient.SqlParameter[]]$SqlParameters
        )

        if ($InputFile)
        {
            $filePath = $(resolve-path $InputFile).path
            $Query =  [System.IO.File]::ReadAllText("$filePath")
        }

        $conn=new-object System.Data.SqlClient.SQLConnection

        $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
        $builder['Data Source'] = $ServerInstance
        if ($Database) { $builder['Initial Catalog'] = $Database }
        $builder['Connect Timeout'] = $ConnectionTimeout
        if ($Username) {
            $builder['Integrated Security'] = $false
            $builder['User ID'] = $Username
            $builder['Password'] = $Password
        }
        else { $builder['Integrated Security'] = $true }

        $conn.ConnectionString=$builder.ConnectionString

        #Following EventHandler is used for PRINT and RAISERROR T-SQL statements. Executed when -Verbose parameter specified by caller
        if ($PSBoundParameters.Verbose)
        {
            $conn.FireInfoMessageEventOnUserErrors=$true
            $handler = [System.Data.SqlClient.SqlInfoMessageEventHandler] {Write-Verbose "$($_)"}
            $conn.add_InfoMessage($handler)
        }

        $ds=New-Object system.Data.DataSet
        $cmd = $null
        try {
            $conn.Open()
            $cmd=new-object system.Data.SqlClient.SqlCommand($Query,$conn)
            $cmd.CommandTimeout=$QueryTimeout
            if ($SqlParameters) { $SqlParameters | ForEach-Object { [void]$cmd.Parameters.Add($_) } }
            $da=New-Object system.Data.SqlClient.SqlDataAdapter($cmd)
            [void]$da.fill($ds)
        }
        finally {
            # A SqlParameter can belong to one command only; clearing lets a retry reuse the same objects.
            if ($cmd) { $cmd.Parameters.Clear(); $cmd.Dispose() }
            $conn.Dispose()
        }
        switch ($As)
        {
            'DataSet'   { Write-Output ($ds) }
            'DataTable' { Write-Output ($ds.Tables) }
            'DataRow'   { Write-Output ($ds.Tables[0]) }
        }
    }



    # Start Getters - XML config file
    Function Get-LocalFilesPath {
        if ($script:JsonConfig) {
            $obj = [string]$script:JsonConfig.LocalFiles
        }
        elseif ($config) {
            $obj = $Xml.Configuration.LocalFiles
        }
        $obj = Expand-ConfigPath $obj
        if ([string]::IsNullOrWhiteSpace($obj)) { $obj = Join-path $env:SystemDrive "ClientHealth" }
        Return $obj
    }

    Function Get-XMLConfigClientVersion {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Client.Version }
        if ($config) {
            $obj = $Xml.Configuration.Client | Where-Object {$_.Name -like 'Version'} | Select-Object -ExpandProperty '#text'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigClientSitecode {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Client.SiteCode }
        if ($config) {
            $obj = $Xml.Configuration.Client | Where-Object {$_.Name -like 'SiteCode'} | Select-Object -ExpandProperty '#text'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigClientDomain {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Client.Domain }
        if ($config) {
            $obj = $Xml.Configuration.Client | Where-Object {$_.Name -like 'Domain'} | Select-Object -ExpandProperty '#text'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigClientAutoUpgrade {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Client.AutoUpgrade }
        if ($config) {
            $obj = $Xml.Configuration.Client | Where-Object {$_.Name -like 'AutoUpgrade'} | Select-Object -ExpandProperty '#text'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigClientMaxLogSize {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Client.Log.MaxSize }
        if ($config) {
            $obj = $Xml.Configuration.Client | Where-Object {$_.Name -like 'Log'} | Select-Object -ExpandProperty 'MaxLogSize'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigClientMaxLogHistory {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Client.Log.MaxHistory }
        if ($config) {
            $obj = $Xml.Configuration.Client | Where-Object {$_.Name -like 'Log'} | Select-Object -ExpandProperty 'MaxLogHistory'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigClientMaxLogSizeEnabled {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Client.Log.Enable }
        if ($config) {
            $obj = $Xml.Configuration.Client | Where-Object {$_.Name -like 'Log'} | Select-Object -ExpandProperty 'Enable'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigClientCache {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Client.Cache.Size }
        if ($config) {
            $obj = $Xml.Configuration.Client | Where-Object {$_.Name -like 'CacheSize'} | Select-Object -ExpandProperty 'Value'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigClientCacheDeleteOrphanedData {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Client.Cache.DeleteOrphanedData }
        if ($config) {
            $obj = $Xml.Configuration.Client | Where-Object {$_.Name -like 'CacheSize'} | Select-Object -ExpandProperty 'DeleteOrphanedData'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigClientCacheEnable {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Client.Cache.Enable }
        if ($config) {
            $obj = $Xml.Configuration.Client | Where-Object {$_.Name -like 'CacheSize'} | Select-Object -ExpandProperty 'Enable'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigClientShare {
        # DEPRECATED. Retained for back-compat detection only; ccmsetup.exe is sourced from MP HTTP, not a share.
        if ($script:JsonConfig) {
            $siteOverride = Get-SiteConfig -PropertyName 'ClientShare'
            if ($siteOverride) { return $siteOverride }
            return [string]$script:JsonConfig.Client.Share
        }
        if ($config) {
            $obj = $Xml.Configuration.Client | Where-Object {$_.Name -like 'Share'} | Select-Object -ExpandProperty '#text' -ErrorAction SilentlyContinue
        }
        return [string]$obj
    }

    Function Get-ManagementPointsFromInstallProperties {
        Param([Parameter(Mandatory=$false)]$InstallProperties)

        $mpList = @()
        foreach ($property in @($InstallProperties)) {
            $value = [string]$property
            $mp = $null

            if ($value -match '^(SMSMP|MP)=(.+)$') { $mp = $Matches[2] }
            elseif ($value -match '^/mp:(.+)$') { $mp = $Matches[1] }

            if ($mp) {
                $mp = $mp.Trim().Trim('"')
                if (-not [string]::IsNullOrWhiteSpace($mp) -and $mpList -notcontains $mp) {
                    $mpList += $mp
                }
            }
        }

        return $mpList
    }

    Function ConvertTo-ConfigBoolean {
        Param(
            [Parameter(Mandatory=$false)]$Value,
            [bool]$Default = $false
        )

        if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $Default }
        if ($Value -is [bool]) { return $Value }

        switch -Regex (([string]$Value).Trim()) {
            '^(?i:true|yes|on|1|enable|enabled)$' { return $true }
            '^(?i:false|no|off|0|disable|disabled)$' { return $false }
        }
        Write-Warning "Config value '$Value' is not a boolean. Using '$Default'."
        return $Default
    }

    # Reads Options.<Name>.<Property> from JSON or <Option Name="<Name>" <Property>="..."/> from XML.
    # A missing value returns $Default, converted to the type of $Default, so older configs get documented defaults.
    Function Get-ConfigOption {
        Param(
            [Parameter(Mandatory=$true)][string]$Name,
            [string]$Property = 'Enable',
            $Default = $null
        )

        $value = $null
        if ($script:JsonConfig) {
            $options = $script:JsonConfig.Options
            if ($options -and $options.PSObject.Properties[$Name]) {
                $node = $options.$Name
                if ($node -is [System.Management.Automation.PSCustomObject]) {
                    if ($node.PSObject.Properties[$Property]) { $value = $node.$Property }
                }
                elseif ($Property -eq 'Enable') { $value = $node }
            }
        }
        elseif ($config) {
            $node = @($Xml.Configuration.Option | Where-Object { $_.Name -eq $Name }) | Select-Object -First 1
            if ($node -and $node.HasAttribute($Property)) { $value = $node.GetAttribute($Property) }
        }

        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { return $Default }
        if ($Default -is [bool]) { return (ConvertTo-ConfigBoolean -Value $value -Default $Default) }
        if ($Default -is [int]) { return (ConvertTo-ConfigInt -Value $value -Default $Default) }
        return $value
    }

    # Report-only results of the extended checks, stored in the Findings column (varchar 1000).
    Function Add-Finding {
        Param(
            [Parameter(Mandatory=$true)]$Log,
            [Parameter(Mandatory=$true)][string]$Text
        )
        Write-Warning "Finding: $Text"
        if ([string]::IsNullOrEmpty($Log.Findings)) { $Log.Findings = $Text }
        elseif ($Log.Findings -notlike "*$Text*") { $Log.Findings = "$($Log.Findings); $Text" }
    }

    # A missing or non-numeric value must not become 0: 0 days and 0 history turn periodic actions into every-run actions.
    Function ConvertTo-ConfigInt {
        Param(
            [Parameter(Mandatory=$false)]$Value,
            [Parameter(Mandatory=$true)][int]$Default,
            [int]$Minimum = [int]::MinValue
        )

        $number = 0
        if ($null -ne $Value -and [int]::TryParse(([string]$Value).Trim(), [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
            if ($number -ge $Minimum) { return $number }
        }
        return $Default
    }

    # Expands %VAR% and $env:VAR only. ExpandString would execute $(...) found in a config value.
    Function Expand-ConfigPath {
        Param([Parameter(Mandatory=$false)]$Path)

        if ([string]::IsNullOrWhiteSpace([string]$Path)) { return [string]$Path }
        $expanded = [regex]::Replace([string]$Path, '\$env:([A-Za-z_][A-Za-z0-9_]*)', {
            param($match)
            $value = [Environment]::GetEnvironmentVariable($match.Groups[1].Value)
            if ($null -eq $value) { return $match.Value }
            return $value
        })
        return [Environment]::ExpandEnvironmentVariables($expanded)
    }

    Function Get-XMLConfigManagementPoints {
        # Returns an array of MP FQDNs for ccmsetup.exe download. Site-aware in JSON mode.
        # Falls back to legacy MP/SMSMP install tokens when no explicit list is configured.
        $mpList = @()
        if ($script:JsonConfig) {
            $siteOverride = Get-SiteConfig -PropertyName 'ManagementPoints'
            if ($siteOverride) { $mpList = @($siteOverride) }
            elseif ($script:JsonConfig.Client.ManagementPoints) { $mpList = @($script:JsonConfig.Client.ManagementPoints) }
            else { $mpList = @(Get-ManagementPointsFromInstallProperties -InstallProperties $script:JsonConfig.ClientInstallProperties) }
        }
        elseif ($config) {
            $mpRoot = $Xml.Configuration.ManagementPoints
            if ($mpRoot) {
                foreach ($node in $mpRoot.MP) { if ($node) { $mpList += [string]$node } }
            }
            if (-not $mpList) {
                $mpList = @(Get-ManagementPointsFromInstallProperties -InstallProperties $Xml.Configuration.ClientInstallProperty)
            }
        }
        return @($mpList | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    }

    Function Get-XMLConfigMPHttps {
        if ($script:JsonConfig) {
            $siteOverride = Get-SiteConfig -PropertyName 'MPHttps'
            if ($null -ne $siteOverride) { return ConvertTo-ConfigBoolean -Value $siteOverride }
            return ConvertTo-ConfigBoolean -Value $script:JsonConfig.Client.MPHttps
        }
        if ($config) {
            $obj = $Xml.Configuration.Client | Where-Object {$_.Name -like 'MPHttps'} | Select-Object -ExpandProperty '#text' -ErrorAction SilentlyContinue
            if ($obj) { return ConvertTo-ConfigBoolean -Value $obj }
        }
        return $false
    }

    Function Get-XMLConfigUpdatesShare {
        if ($script:JsonConfig) {
            $obj = $script:JsonConfig.Options.Updates.Share
            if (!$obj) { $obj = Join-Path $global:ScriptPath "Updates" }
            return $obj
        }
        if ($config) {
            $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'Updates'} | Select-Object -ExpandProperty 'Share'
        }
        If (!($obj)){$obj = Join-Path $global:ScriptPath "Updates"}
        Return $obj
    }

    Function Get-XMLConfigUpdatesEnable {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Options.Updates.Enable }
        if ($config) {
            $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'Updates'} | Select-Object -ExpandProperty 'Enable'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigUpdatesFix {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Options.Updates.Fix }
        if ($config) {
            $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'Updates'} | Select-Object -ExpandProperty 'Fix' }
        Write-Output $obj
    }

    Function Get-XMLConfigLoggingShare {
        if ($script:JsonConfig) {
            $siteOverride = Get-SiteConfig -PropertyName 'LogShare'
            $obj = if ($siteOverride) { $siteOverride } else { $script:JsonConfig.Logging.Share }
            return (Expand-ConfigPath $obj)
        }
        if ($config) {
            $obj = $Xml.Configuration.Log | Where-Object {$_.Name -like 'File'} | Select-Object -ExpandProperty 'Share'
        }
        Return (Expand-ConfigPath $obj)
    }

    Function Get-XMLConfigLoggingLocalFile {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Logging.LocalLogFile }
        if ($config) {
            $obj = $Xml.Configuration.Log | Where-Object {$_.Name -like 'File'} | Select-Object -ExpandProperty 'LocalLogFile'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigLoggingEnable {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Logging.FileEnabled }
        if ($config) {
            $obj = $Xml.Configuration.Log | Where-Object {$_.Name -like 'File'} | Select-Object -ExpandProperty 'Enable'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigLoggingMaxHistory {
        # Currently not configurable through console extension and webservice. TODO
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Logging.MaxHistory }
        if ($config) {
            $obj = $Xml.Configuration.Log | Where-Object {$_.Name -like 'File'} | Select-Object -ExpandProperty 'MaxLogHistory'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigLoggingLevel {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Logging.Level }
        if ($config) {
            $obj = $Xml.Configuration.Log | Where-Object {$_.Name -like 'File'} | Select-Object -ExpandProperty 'Level'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigLoggingTimeFormat {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Logging.TimeFormat }
        if ($config) {
            $obj = $Xml.Configuration.Log | Where-Object {$_.Name -like 'Time'} | Select-Object -ExpandProperty 'Format'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigPendingRebootEnable {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Options.PendingReboot.Enable }
        if ($config) {
            $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'PendingReboot'} | Select-Object -ExpandProperty 'Enable'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigPendingRebootApp {
        # TODO verify this function
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Options.PendingReboot.StartRebootApplication }
        if ($config) {
            $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'PendingReboot'} | Select-Object -ExpandProperty 'StartRebootApplication'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigMaxRebootDays {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Options.MaxRebootDays }
        if ($config) {
            $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'MaxRebootDays'} | Select-Object -ExpandProperty 'Days'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigRebootApplication {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Options.RebootApplication.Application }
        if ($config) {
            $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'RebootApplication'} | Select-Object -ExpandProperty 'Application'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigRebootApplicationEnable {
        ### TODO implement in webservice
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Options.RebootApplication.Enable }
        if ($config) {
            $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'RebootApplication'} | Select-Object -ExpandProperty 'Enable'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigDNSCheck {
        # TODO verify switch, skip test and monitor for console extension
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Options.DNSCheck.Enable }
        if ($config) {
            $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'DNSCheck'} | Select-Object -ExpandProperty 'Enable'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigCcmSQLCELog {
        # TODO implement monitor mode
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Options.CcmSQLCELog }
        if ($config) {
            $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'CcmSQLCELog'} | Select-Object -ExpandProperty 'Enable'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigDNSFix {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Options.DNSCheck.Fix }
        if ($config) {
            $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'DNSCheck'} | Select-Object -ExpandProperty 'Fix'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigDrivers {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Options.Drivers }
        if ($config) {
            $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'Drivers'} | Select-Object -ExpandProperty 'Enable'
        }
        Write-Output $obj
    }


    Function Get-XMLConfigOSDiskFreeSpace {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Options.OSDiskFreeSpace }
        if ($config) {
            $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'OSDiskFreeSpace'} | Select-Object -ExpandProperty '#text'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigHardwareInventoryEnable {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Options.HardwareInventory.Enable }
        if ($config) {
            $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'HardwareInventory'} | Select-Object -ExpandProperty 'Enable'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigHardwareInventoryFix {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Options.HardwareInventory.Fix }
        if ($config) {
            $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'HardwareInventory'} | Select-Object -ExpandProperty 'Fix'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigSoftwareMeteringEnable {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Options.SoftwareMetering.Enable }
        if ($config) {
            $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'SoftwareMetering'} | Select-Object -ExpandProperty 'Enable'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigSoftwareMeteringFix {
        # TODO implement this check in console extension and webservice
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Options.SoftwareMetering.Fix }
        if ($config) {
            $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'SoftwareMetering'} | Select-Object -ExpandProperty 'Fix'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigHardwareInventoryDays {
        # TODO implement this check in console extension and webservice
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Options.HardwareInventory.Days }
        if ($config) {
            $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'HardwareInventory'} | Select-Object -ExpandProperty 'Days'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigRemediationAdminShare {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Remediation.AdminShare }
        if ($config) {
            $obj = $Xml.Configuration.Remediation | Where-Object {$_.Name -like 'AdminShare'} | Select-Object -ExpandProperty 'Fix'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigRemediationClientProvisioningMode {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Remediation.ClientProvisioningMode }
        if ($config) {
            $obj = $Xml.Configuration.Remediation | Where-Object {$_.Name -like 'ClientProvisioningMode'} | Select-Object -ExpandProperty 'Fix'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigRemediationClientStateMessages {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Remediation.ClientStateMessages }
        if ($config) {
            $obj = $Xml.Configuration.Remediation | Where-Object {$_.Name -like 'ClientStateMessages'} | Select-Object -ExpandProperty 'Fix'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigRemediationClientWUAHandler {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Remediation.ClientWUAHandler.Fix }
        if ($config) {
            $obj = $Xml.Configuration.Remediation | Where-Object {$_.Name -like 'ClientWUAHandler'} | Select-Object -ExpandProperty 'Fix'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigRemediationClientWUAHandlerDays {
        # TODO implement days in console extension and webservice
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Remediation.ClientWUAHandler.Days }
        if ($config) {
            $obj = $Xml.Configuration.Remediation | Where-Object {$_.Name -like 'ClientWUAHandler'} | Select-Object -ExpandProperty 'Days'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigBITSCheck {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Options.BITSCheck.Enable }
        if ($config) {
            $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'BITSCheck'} | Select-Object -ExpandProperty 'Enable'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigBITSCheckFix {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Options.BITSCheck.Fix }
        if ($config) {
            $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'BITSCheck'} | Select-Object -ExpandProperty 'Fix'
        }
        Write-Output $obj
    }

	Function Get-XMLConfigClientSettingsCheck {
        # TODO implement in console extension and webservice
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Options.ClientSettingsCheck.Enable }
        $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'ClientSettingsCheck'} | Select-Object -ExpandProperty 'Enable'
        Write-Output $obj
	}

	Function Get-XMLConfigClientSettingsCheckFix {
        # TODO implement in console extension and webservice
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Options.ClientSettingsCheck.Fix }
        $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'ClientSettingsCheck'} | Select-Object -ExpandProperty 'Fix'
        Write-Output $obj
	}

    Function Get-XMLConfigWMI {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Options.WMI.Enable }
        if ($config) {
            $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'WMI'} | Select-Object -ExpandProperty 'Enable'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigWMIRepairEnable {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Options.WMI.Fix }
        if ($config) {
            $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'WMI'} | Select-Object -ExpandProperty 'Fix'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigRefreshComplianceState {
        # Measured in days
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Options.RefreshComplianceState.Enable }
        if ($config) {
            $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'RefreshComplianceState'} | Select-Object -ExpandProperty 'Enable'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigRefreshComplianceStateDays {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Options.RefreshComplianceState.Days }
        if ($config) {
            $obj = $Xml.Configuration.Option | Where-Object {$_.Name -like 'RefreshComplianceState'} | Select-Object -ExpandProperty 'Days'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigRemediationClientCertificate {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Remediation.ClientCertificate }
        if ($config) {
            $obj = $Xml.Configuration.Remediation | Where-Object {$_.Name -like 'ClientCertificate'} | Select-Object -ExpandProperty 'Fix'
        }
        Write-Output $obj
    }

    Function Get-XMLConfigSQLServer {
        if ($script:JsonConfig) {
            $siteOverride = Get-SiteConfig -PropertyName 'SQLServer'
            if ($siteOverride) { return [string]$siteOverride }
            return [string]$script:JsonConfig.Logging.SQL.Server
        }
        $obj = $Xml.Configuration.Log | Where-Object {$_.Name -like 'SQL'} | Select-Object -ExpandProperty 'Server'
        Write-Output $obj
    }

    Function Get-XMLConfigSQLLoggingEnable {
        if ($script:JsonConfig) { return [string]$script:JsonConfig.Logging.SQL.Enabled }
        $obj = $Xml.Configuration.Log | Where-Object {$_.Name -like 'SQL'} | Select-Object -ExpandProperty 'Enable'
        Write-Output $obj
    }



    # End Getters - XML config file


    Function Test-ConfigMgrHealthLogging {
        # Verifies that logfiles are not bigger than max history

        
        $localLogging = ([string](Get-XMLConfigLoggingLocalFile)).ToLower()
        $fileshareLogging = ([string](Get-XMLConfigLoggingEnable)).ToLower()

        if ($localLogging -eq "true") {
            $clientpath = Get-LocalFilesPath
            $logfile = "$clientpath\ClientHealth.log"
            Test-LogFileHistory -Logfile $logfile
        }


        if ($fileshareLogging -eq "true") {
            $logfile = Get-LogFileName
            Test-LogFileHistory -Logfile $logfile
        }
    }

    Function CleanUp {
        $clientpath = (Get-LocalFilesPath).ToLower()
        $forbidden = "$env:SystemDrive", "$env:SystemDrive\", "$env:SystemDrive\windows", "$env:SystemDrive\windows\"
        $NoDelete = $false
        foreach ($item in $forbidden) { if ($clientpath -like $item) { $NoDelete = $true } }

        # LocalFiles can be writable by standard users, and Remove-Item -Recurse can follow a planted junction.
        if (((Test-Path "$clientpath\Temp" -ErrorAction SilentlyContinue) -eq $True) -and ($NoDelete -eq $false) ) {
            Write-Verbose "Cleaning up temporary files in $clientpath\Temp"
            try { Remove-PathNoFollow -Path "$clientpath\Temp" } catch { Write-Verbose "Could not remove $clientpath\Temp: $_" }
        }

        # Keep the downloaded ccmsetup.exe while an install it started is still running.
        $stateDir = Join-Path $env:ProgramData 'ConfigMgrClientHealth'
        $downloads = @('updates', 'prereq')
        if (-not (Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue)) { $downloads += 'ccmsetup' }
        foreach ($folder in $downloads) {
            $path = Join-Path $stateDir $folder
            if (Test-Path -LiteralPath $path) {
                Write-Verbose "Removing downloaded files in $path"
                try { Remove-PathNoFollow -Path $path } catch { Write-Verbose "Could not remove ${path}: $_" }
            }
        }
    }

    Function New-LogObject {
       # Write-Verbose "Start New-LogObject"

        $OS = Get-CimInstance -ClassName Win32_OperatingSystem
        $CS = Get-CimInstance -ClassName Win32_ComputerSystem
        if ($CS.Manufacturer -like 'Lenovo') { $Model = (Get-CimInstance -ClassName Win32_ComputerSystemProduct).Version }
        else { $Model = $CS.Model }

        # Handles different OS languages
        $Hostname = Get-Hostname
        $OperatingSystem = $OS.Caption
        $Architecture = ($OS.OSArchitecture -replace ('([^0-9])(\.*)', '')) + '-Bit'
        $Build = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').BuildLabEx
        $Manufacturer = $CS.Manufacturer
        $ClientVersion = 'Unknown'
        $Sitecode = Get-Sitecode
        $Domain = Get-Domain
        [int]$MaxLogSize = 0
        $MaxLogHistory = 0
        $InstallDate = Get-SmallDateTime -Date ($OS.InstallDate)
        $InstallDate = $InstallDate -replace '\.', ':'
        $LastLoggedOnUser = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\').LastLoggedOnUser
        $CacheSize = Get-ClientCache
        $Services = 'Unknown'
        $Updates = 'Unknown'
        $DNS = 'Unknown'
        $Drivers = 'Unknown'
        $ClientCertificate = 'Unknown'
        $PendingReboot = 'Unknown'
        $RebootApp = 'Unknown'
        $LastBootTime = Get-SmallDateTime -Date ($OS.LastBootUpTime)
        $LastBootTime = $LastBootTime -replace '\.', ':'
        $OSDiskFreeSpace = Get-OSDiskFreeSpace
        $AdminShare = 'Unknown'
        $ProvisioningMode = 'Unknown'
        $StateMessages = 'Unknown'
        $WUAHandler = 'Unknown'
        $WMI = 'Unknown'
        $RefreshComplianceState = $null
        $smallDateTime = Get-SmallDateTime
        $smallDateTime = $smallDateTime -replace '\.', ':'
        [float]$PSVersion = [float]$psVersion = [float]$PSVersionTable.PSVersion.Major + ([float]$PSVersionTable.PSVersion.Minor / 10)
        [int]$PSBuild = [int]$PSVersionTable.PSVersion.Build
        if ($PSBuild -le 0) { $PSBuild = $null }
        $UBR = Get-UBR
        $BITS = $null
		$ClientSettings = $null

        $obj = New-Object PSObject -Property @{
            Hostname = $Hostname
            Operatingsystem = $OperatingSystem
            Architecture = $Architecture
            Build = $Build
            Manufacturer = $Manufacturer
            Model = $Model
            InstallDate = $InstallDate
            OSUpdates = $null
            LastLoggedOnUser = $LastLoggedOnUser
            ClientVersion = $ClientVersion
            PSVersion = $PSVersion
            PSBuild = $PSBuild
            Sitecode = $Sitecode
            Domain = $Domain
            MaxLogSize = $MaxLogSize
            MaxLogHistory = $MaxLogHistory
            CacheSize = $CacheSize
            ClientCertificate = $ClientCertificate
            ProvisioningMode = $ProvisioningMode
            DNS = $DNS
            Drivers = $Drivers
            Updates = $Updates
            PendingReboot = $PendingReboot
            LastBootTime = $LastBootTime
            OSDiskFreeSpace = $OSDiskFreeSpace
            Services = $Services
            AdminShare = $AdminShare
            StateMessages = $StateMessages
            WUAHandler = $WUAHandler
            WMI = $WMI
            RefreshComplianceState = $RefreshComplianceState
            ClientInstalled = $null
            Version = $Version
            Timestamp = $smallDateTime
            HWInventory = $null
            SWMetering = $null
			ClientSettings = $null
            BITS = $BITS
            PatchLevel = $UBR
            ClientInstalledReason = $null
            RebootApp = $RebootApp
            Findings = $null
        }
        Write-Output $obj
       # Write-Verbose "End New-LogObject"
    }

    Function Get-SmallDateTime {
        Param([Parameter(Mandatory=$false)]$Date)
        #Write-Verbose "Start Get-SmallDateTime"

        $UTC = ([string](Get-XMLConfigLoggingTimeFormat)).ToLower()

        if ($null -ne $Date) {
            if ($UTC -eq "utc") { $obj = (Get-UTCTime -DateTime $Date).ToString("yyyy-MM-dd HH:mm:ss") }
            else { $obj = ($Date).ToString("yyyy-MM-dd HH:mm:ss") }
        }
        else { $obj = Get-DateTime }
        $obj = $obj -replace '\.', ':'
        Write-Output $obj
        #Write-Verbose "End Get-SmallDateTime"
    }

    # Test some values are whole numbers before attempting to insert / update database
    Function Test-ValuesBeforeLogUpdate {
        Write-Verbose "Start Test-ValuesBeforeLogUpdate"
        [int]$Log.MaxLogSize = [Math]::Round($Log.MaxLogSize)
        [int]$Log.MaxLogHistory = [Math]::Round($Log.MaxLogHistory)
        [int]$Log.PSBuild = [Math]::Round($Log.PSBuild)
        [int]$Log.CacheSize = [Math]::Round($Log.CacheSize)
        Write-Verbose "End Test-ValuesBeforeLogUpdate"
    }

    # Log values are strings in 'yyyy-MM-dd HH:mm:ss' or numbers. Typed parameters keep SQL Server from
    # converting date strings with the login's DATEFORMAT, and a value that does not fit becomes NULL
    # instead of failing the whole upsert.
    Function ConvertTo-SqlValue {
        Param(
            [Parameter(Mandatory=$true)][System.Data.SqlDbType]$Type,
            [Parameter(Mandatory=$false)]$Value
        )

        if ($null -eq $Value) { return [DBNull]::Value }
        $text = ([string]$Value).Trim()
        if ($text -eq '') { return [DBNull]::Value }
        $invariant = [System.Globalization.CultureInfo]::InvariantCulture

        switch ($Type) {
            'Int' {
                $number = 0.0
                if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, $invariant, [ref]$number) -and
                    $number -ge [int]::MinValue -and $number -le [int]::MaxValue) { return [int][math]::Round($number) }
                return [DBNull]::Value
            }
            'Float' {
                $number = 0.0
                if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, $invariant, [ref]$number)) { return $number }
                return [DBNull]::Value
            }
            { $_ -eq 'SmallDateTime' -or $_ -eq 'DateTime' } {
                if ($Value -is [datetime]) { $date = $Value }
                else {
                    $date = [datetime]::MinValue
                    if (-not [datetime]::TryParseExact($text, 'yyyy-MM-dd HH:mm:ss', $invariant, [System.Globalization.DateTimeStyles]::None, [ref]$date)) { return [DBNull]::Value }
                }
                if ($Type -eq 'SmallDateTime' -and ($date -lt [datetime]'1900-01-01' -or $date -gt [datetime]'2079-06-06')) { return [DBNull]::Value }
                if ($Type -eq 'DateTime' -and $date -lt [datetime]'1753-01-01') { return [DBNull]::Value }
                return $date
            }
            default { return $text }
        }
    }

    Function New-SqlParam {
        Param(
            [Parameter(Mandatory=$true, Position=0)][string]$Name,
            [Parameter(Mandatory=$true, Position=1)][System.Data.SqlDbType]$Type,
            [Parameter(Mandatory=$true, Position=2)][int]$Size,
            [Parameter(Mandatory=$false, Position=3)]$Value
        )

        $p = New-Object System.Data.SqlClient.SqlParameter($Name, $Type)
        # SqlParameter truncates to Size; the column would otherwise reject the row.
        if ($Size -gt 0) { $p.Size = $Size }
        $p.Value = ConvertTo-SqlValue -Type $Type -Value $Value
        return $p
    }

    Function Update-SQL {
        Param(
            [Parameter(Mandatory=$true)]$Log,
            [Parameter(Mandatory=$false)]$Table
        )

        Write-Verbose "Start Update-SQL"
        Test-ValuesBeforeLogUpdate

        $SQLServer = Get-XMLConfigSQLServer
        $Database = 'ClientHealth'
        $table = 'dbo.Clients'
        $smallDateTime = Get-SmallDateTime


        $query = "BEGIN TRAN
        IF EXISTS (SELECT 1 FROM $table WITH (UPDLOCK,SERIALIZABLE) WHERE Hostname = @Hostname)
        BEGIN
            UPDATE $table SET
                Operatingsystem = @Operatingsystem, Architecture = @Architecture, Build = @Build,
                Manufacturer = @Manufacturer, Model = @Model, InstallDate = @InstallDate,
                OSUpdates = @OSUpdates, LastLoggedOnUser = @LastLoggedOnUser,
                ClientVersion = @ClientVersion, PSVersion = @PSVersion, PSBuild = @PSBuild,
                Sitecode = @Sitecode, Domain = @Domain, MaxLogSize = @MaxLogSize,
                MaxLogHistory = @MaxLogHistory, CacheSize = @CacheSize,
                ClientCertificate = @ClientCertificate, ProvisioningMode = @ProvisioningMode,
                DNS = @DNS, Drivers = @Drivers, Updates = @Updates,
                PendingReboot = @PendingReboot, LastBootTime = @LastBootTime,
                OSDiskFreeSpace = @OSDiskFreeSpace, Services = @Services,
                AdminShare = @AdminShare, StateMessages = @StateMessages,
                WUAHandler = @WUAHandler, WMI = @WMI,
                RefreshComplianceState = @RefreshComplianceState, HWInventory = @HWInventory,
                Version = @Version, ClientInstalled = COALESCE(@ClientInstalled, ClientInstalled),
                Timestamp = @Timestamp, SWMetering = @SWMetering, BITS = @BITS,
                PatchLevel = @PatchLevel, ClientInstalledReason = @ClientInstalledReason,
                Findings = @Findings
            WHERE Hostname = @Hostname
        END
        ELSE
        BEGIN
            INSERT INTO $table (
                Hostname, Operatingsystem, Architecture, Build, Manufacturer, Model,
                InstallDate, OSUpdates, LastLoggedOnUser, ClientVersion, PSVersion, PSBuild,
                Sitecode, Domain, MaxLogSize, MaxLogHistory, CacheSize, ClientCertificate,
                ProvisioningMode, DNS, Drivers, Updates, PendingReboot, LastBootTime,
                OSDiskFreeSpace, Services, AdminShare, StateMessages, WUAHandler, WMI,
                RefreshComplianceState, HWInventory, Version, ClientInstalled, Timestamp,
                SWMetering, BITS, PatchLevel, ClientInstalledReason, Findings
            ) VALUES (
                @Hostname, @Operatingsystem, @Architecture, @Build, @Manufacturer, @Model,
                @InstallDate, @OSUpdates, @LastLoggedOnUser, @ClientVersion, @PSVersion, @PSBuild,
                @Sitecode, @Domain, @MaxLogSize, @MaxLogHistory, @CacheSize, @ClientCertificate,
                @ProvisioningMode, @DNS, @Drivers, @Updates, @PendingReboot, @LastBootTime,
                @OSDiskFreeSpace, @Services, @AdminShare, @StateMessages, @WUAHandler, @WMI,
                @RefreshComplianceState, @HWInventory, @Version, @ClientInstalled, @Timestamp,
                @SWMetering, @BITS, @PatchLevel, @ClientInstalledReason, @Findings
            )
        END
        COMMIT TRAN"

        $sqlParams = @(
            (New-SqlParam '@Hostname'               VarChar 100 $log.Hostname)
            (New-SqlParam '@Operatingsystem'        VarChar 100 $log.Operatingsystem)
            (New-SqlParam '@Architecture'           VarChar 10  $log.Architecture)
            (New-SqlParam '@Build'                  VarChar 100 $log.Build)
            (New-SqlParam '@Manufacturer'           VarChar 100 $log.Manufacturer)
            (New-SqlParam '@Model'                  VarChar 100 $log.Model)
            (New-SqlParam '@InstallDate'            SmallDateTime 0 $log.InstallDate)
            (New-SqlParam '@OSUpdates'              SmallDateTime 0 $log.OSUpdates)
            (New-SqlParam '@LastLoggedOnUser'       VarChar 100 $log.LastLoggedOnUser)
            (New-SqlParam '@ClientVersion'          VarChar 100 $log.ClientVersion)
            (New-SqlParam '@PSVersion'              Float 0 $log.PSVersion)
            (New-SqlParam '@PSBuild'                Int 0 $log.PSBuild)
            (New-SqlParam '@Sitecode'               VarChar 3   $log.Sitecode)
            (New-SqlParam '@Domain'                 VarChar 100 $log.Domain)
            (New-SqlParam '@MaxLogSize'             Int 0 $log.MaxLogSize)
            (New-SqlParam '@MaxLogHistory'          Int 0 $log.MaxLogHistory)
            (New-SqlParam '@CacheSize'              Int 0 $log.CacheSize)
            (New-SqlParam '@ClientCertificate'      VarChar 50  $log.ClientCertificate)
            (New-SqlParam '@ProvisioningMode'       VarChar 50  $log.ProvisioningMode)
            (New-SqlParam '@DNS'                    VarChar 200 $log.DNS)
            (New-SqlParam '@Drivers'                VarChar 100 $log.Drivers)
            (New-SqlParam '@Updates'                VarChar 200 $log.Updates)
            (New-SqlParam '@PendingReboot'          VarChar 50  $log.PendingReboot)
            (New-SqlParam '@LastBootTime'           SmallDateTime 0 $log.LastBootTime)
            (New-SqlParam '@OSDiskFreeSpace'        Float 0 $log.OSDiskFreeSpace)
            (New-SqlParam '@Services'               VarChar 200 $log.Services)
            (New-SqlParam '@AdminShare'             VarChar 50  $log.AdminShare)
            (New-SqlParam '@StateMessages'          VarChar 50  $log.StateMessages)
            (New-SqlParam '@WUAHandler'             VarChar 50  $log.WUAHandler)
            (New-SqlParam '@WMI'                    VarChar 50  $log.WMI)
            (New-SqlParam '@RefreshComplianceState' SmallDateTime 0 $log.RefreshComplianceState)
            (New-SqlParam '@HWInventory'            SmallDateTime 0 $log.HWInventory)
            (New-SqlParam '@Version'                VarChar 10  $Version)
            (New-SqlParam '@ClientInstalled'        SmallDateTime 0 $log.ClientInstalled)
            (New-SqlParam '@Timestamp'              DateTime 0 $smallDateTime)
            (New-SqlParam '@SWMetering'             VarChar 50  $log.SWMetering)
            (New-SqlParam '@BITS'                   VarChar 50  $log.BITS)
            (New-SqlParam '@PatchLevel'             Int 0 $log.PatchLevel)
            (New-SqlParam '@ClientInstalledReason'  VarChar 200 $log.ClientInstalledReason)
            (New-SqlParam '@Findings'               VarChar 1000 $log.Findings)
        )

        try {
            Invoke-WithRetry -OperationName 'SQL Update' -ScriptBlock {
                Invoke-Sqlcmd2 -ServerInstance $SQLServer -Database $Database -Query $query -SqlParameters $sqlParams
            }
        }
        catch {
            $ErrorMessage = $_.Exception.Message
            Write-Error "Error updating SQL after retries: $ErrorMessage"
            $script:FailureCount++
            Out-LogFile -Xml $Xml -Text "ERROR Insert/Update SQL: $ErrorMessage" -Severity 3
            if ($LocalLogging -like 'true') { Out-LogFile -Xml $Xml -Text "ERROR Insert/Update SQL: $ErrorMessage" -Mode 'Local' -Severity 3 }
        }
        Write-Verbose "End Update-SQL"
    }

    Function Update-LogFile {
        Param(
            [Parameter(Mandatory=$true)]$Log,
            [Parameter(Mandatory=$false)]$Mode
            )
        # Start the logfile
        Write-Verbose "Start Update-LogFile"
        #$share = Get-XMLConfigLoggingShare

        Test-ValuesBeforeLogUpdate
        if ($Mode -eq 'Local') { $logfile = Join-Path (Get-LocalFilesPath) 'ClientHealth.log' }
        else { $logfile = Get-LogFileName }
        Test-LogFileHistory -Logfile $logfile
        $text = "<--- ConfigMgr Client Health Check starting --->"
        $text += $log | Select-Object Hostname, Operatingsystem, Architecture, Build, Model, InstallDate, OSUpdates, LastLoggedOnUser, ClientVersion, PSVersion, PSBuild, SiteCode, Domain, MaxLogSize, MaxLogHistory, CacheSize, ClientCertificate, ProvisioningMode, DNS, PendingReboot, LastBootTime, OSDiskFreeSpace, Services, AdminShare, StateMessages, WUAHandler, WMI, RefreshComplianceState, ClientInstalled, Version, Timestamp, HWInventory, SWMetering, BITS, ClientSettings, PatchLevel, ClientInstalledReason, Findings | Out-String
        $text = $text.replace("`t","")
        $text = $text.replace("  ","")
        $text = $text.replace(" :",":")
        $text = $text -creplace '(?m)^\s*\r?\n',''

        if ($Mode -eq 'Local') { Out-LogFile -Xml $xml -Text $text -Mode $Mode -Severity 1}
        elseif ($Mode -eq 'ClientInstalledFailed') { Out-LogFile -Xml $xml -Text $text -Mode $Mode -Severity 1}
        else { Out-LogFile -Xml $xml -Text $text -Severity 1}
        Write-Verbose "End Update-LogFile"
    }

    # Write-Log : CMTrace compatible log file


    # Validate config values to prevent injection via WMI filters and paths
    Function Test-ConfigValues {
        Param([Parameter(Mandatory=$false)]$Xml)

        # Validate service names (used in WMI filters)
        if ($script:JsonConfig) {
            foreach ($svc in $script:JsonConfig.Services) {
                if ($svc.Name -notmatch '\A[a-zA-Z0-9_\-\.]+\z') {
                    throw "Invalid service name in config: '$($svc.Name)'. Only alphanumeric, underscore, hyphen, and dot are allowed."
                }
            }
        }
        else {
            foreach ($svc in $Xml.Configuration.Service) {
                if ($svc.Name -notmatch '\A[a-zA-Z0-9_\-\.]+\z') {
                    throw "Invalid service name in config: '$($svc.Name)'. Only alphanumeric, underscore, hyphen, and dot are allowed."
                }
            }
        }

        # Validate site code
        $siteCode = Get-XMLConfigClientSitecode
        if ($siteCode -and $siteCode -notmatch '\A[A-Za-z0-9]{3}\z') {
            throw "Invalid site code in config: '$siteCode'. Must be exactly 3 alphanumeric characters."
        }

        # Validate domain
        $domain = Get-XMLConfigClientDomain
        if ($domain -and $domain -notmatch '\A[a-zA-Z0-9\.\-]+\z') {
            throw "Invalid domain in config: '$domain'. Contains unexpected characters."
        }

        # Validate management points before they are used in download URLs and ccmsetup args
        $managementPoints = @()
        $tokenManagementPoints = @()
        if ($script:JsonConfig) {
            $managementPoints += @($script:JsonConfig.Client.ManagementPoints)
            $tokenManagementPoints = @(Get-ManagementPointsFromInstallProperties -InstallProperties $script:JsonConfig.ClientInstallProperties)
            if ($script:JsonConfig.Sites) {
                foreach ($site in @($script:JsonConfig.Sites.PSObject.Properties)) {
                    if ($site.Value.PSObject.Properties['ManagementPoints']) {
                        $managementPoints += @($site.Value.ManagementPoints)
                    }
                }
            }
        }
        else {
            $mpRoot = $Xml.Configuration.ManagementPoints
            if ($mpRoot) {
                foreach ($node in @($mpRoot.MP)) { if ($node) { $managementPoints += [string]$node } }
            }
            $tokenManagementPoints = @(Get-ManagementPointsFromInstallProperties -InstallProperties $Xml.Configuration.ClientInstallProperty)
        }

        # Legacy SMSMP= / MP= / /mp: tokens are stripped before ccmsetup runs, and Resolve-Client skips invalid names.
        # A token such as 'mp01:80' must not stop every client in Begin.
        foreach ($mp in @($tokenManagementPoints | Where-Object { $_ })) {
            if (-not (Test-ManagementPointName -ManagementPoint ([string]$mp).Trim())) {
                Write-Warning "Ignoring invalid management point '$mp' in ClientInstallProperties."
            }
        }

        foreach ($mp in @($managementPoints | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)) {
            $mp = ([string]$mp).Trim()
            if (-not (Test-ManagementPointName -ManagementPoint $mp)) {
                throw "Invalid management point in config: '$mp'. Use a hostname or FQDN containing only letters, numbers, hyphen, and dot."
            }
        }

        Write-Verbose "Config validation passed"
    }

    #region Extended checks

    # HKLM\Software\Microsoft\CCM\CcmEval\NotifyOnly = TRUE excludes a device from automatic remediation.
    Function Test-MonitorOnly {
        $value = (Get-ItemProperty -Path 'HKLM:\Software\Microsoft\CCM\CcmEval' -Name NotifyOnly -ErrorAction SilentlyContinue).NotifyOnly
        return ([string]$value -eq 'TRUE')
    }

    # Turns off the Fix switches in the loaded config. Remediation, cache size, and log size checks still
    # run; they read $script:MonitorOnly and report instead of changing the device.
    Function Set-MonitorOnlyConfig {
        if ($script:JsonConfig) {
            $cfg = $script:JsonConfig
            if ($cfg.Client) {
                if ($cfg.Client.PSObject.Properties['AutoUpgrade']) { $cfg.Client.AutoUpgrade = $false }
                if ($cfg.Client.Cache) { $cfg.Client.Cache.DeleteOrphanedData = $false }
            }
            if ($cfg.Options) {
                foreach ($option in $cfg.Options.PSObject.Properties) {
                    if ($option.Value -is [System.Management.Automation.PSCustomObject] -and $option.Value.PSObject.Properties['Fix']) { $option.Value.Fix = $false }
                }
            }

        }
        elseif ($Xml) {
            foreach ($node in @($Xml.Configuration.Option)) { if ($node -and $node.HasAttribute('Fix')) { $node.SetAttribute('Fix', 'False') } }
            foreach ($node in @($Xml.Configuration.Client)) {
                if (-not $node) { continue }
                if ($node.Name -eq 'AutoUpgrade') { $node.InnerText = 'False' }
                if ($node.Name -eq 'CacheSize') { $node.SetAttribute('DeleteOrphanedData', 'False') }
            }
        }
    }

    # Option Fix flag combined with the device's NotifyOnly exclusion.
    Function Test-FixAllowed {
        Param([Parameter(Mandatory=$true)][string]$Name, [bool]$Default = $false)
        if ($script:MonitorOnly) { return $false }
        return (Get-ConfigOption -Name $Name -Property 'Fix' -Default $Default)
    }

    # Messages from a ConfigMgr log written at or after StartTime, oldest first.
    Function Get-CMLogEntry {
        Param(
            [Parameter(Mandatory=$true)][string]$LogFile,
            [datetime]$StartTime = [datetime]::MinValue
        )
        if (-not (Test-Path -LiteralPath $LogFile)) { return }
        $pattern = '<!\[LOG\[(?<Message>.*)\]LOG\]!><time="(?<Time>[\d:]+)\.\d+[+-]\d+" date="(?<Date>[\d-]+)"'
        $lines = @(Get-Content -LiteralPath $LogFile -ErrorAction SilentlyContinue)
        $entries = New-Object System.Collections.Generic.List[object]
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $m = [regex]::Match($lines[$i], $pattern)
            if (-not $m.Success) { continue }
            $time = [datetime]::MinValue
            if (-not [datetime]::TryParseExact("$($m.Groups['Date'].Value) $($m.Groups['Time'].Value)", 'MM-dd-yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$time)) { continue }
            if ($time -lt $StartTime) { break }
            $entries.Insert(0, [pscustomobject]@{ Time = $time; Message = $m.Groups['Message'].Value })
        }
        $entries
    }

    # Per-machine Windows Installer products whose name matches the pattern, with their cached package state.
    Function Get-InstalledMsiProduct {
        Param([Parameter(Mandatory=$true)][string]$NamePattern)
        $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products'
        foreach ($key in @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
            $props = Get-ItemProperty -Path (Join-Path $key.PSPath 'InstallProperties') -ErrorAction SilentlyContinue
            if ($props -and $props.DisplayName -match $NamePattern) {
                [pscustomobject]@{
                    Name         = $props.DisplayName
                    Version      = $props.DisplayVersion
                    LocalPackage = $props.LocalPackage
                    CacheExists  = [bool]($props.LocalPackage -and (Test-Path -LiteralPath $props.LocalPackage))
                }
            }
        }
    }

    Function Get-MsiFileProperty {
        Param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][string]$Property)
        $installer = $null; $db = $null; $view = $null; $record = $null
        try {
            $installer = New-Object -ComObject WindowsInstaller.Installer
            $db = $installer.OpenDatabase($Path, 0)
            $view = $db.OpenView("SELECT Value FROM Property WHERE Property='$Property'")
            $view.Execute()
            $record = $view.Fetch()
            if ($record) { return $record.StringData(1) }
            return $null
        }
        finally {
            # The database handle locks the file until the COM objects are released.
            if ($view) { $view.Close() }
            foreach ($o in @($record, $view, $db, $installer)) { if ($o) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($o) } }
        }
    }

    # Downloads a file from the client source of a configured management point (CCM_Client) into the
    # protected state folder and accepts it only with a valid Microsoft signature.
    Function Get-MPClientSourceFile {
        Param(
            [Parameter(Mandatory=$true)][string]$RelativePath,
            [string]$OriginalFilename
        )
        $stateDir = Join-Path $env:ProgramData 'ConfigMgrClientHealth'
        if (-not (Initialize-SecureDirectory -Path $stateDir)) { return $null }
        $downloadDir = Join-Path $stateDir 'prereq'
        if (-not (Test-Path -LiteralPath $downloadDir)) { New-Item -Path $downloadDir -ItemType Directory -Force | Out-Null }
        $target = Join-Path $downloadDir (Split-Path $RelativePath -Leaf)
        $scheme = if (Get-XMLConfigMPHttps) { 'https' } else { 'http' }
        Enable-Tls12
        foreach ($mp in @(Get-XMLConfigManagementPoints | Where-Object { Test-ManagementPointName -ManagementPoint $_ })) {
            try {
                if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force -ErrorAction Stop }
                Invoke-WebRequest -Uri "$($scheme)://$mp/CCM_Client/$RelativePath" -OutFile $target -UseBasicParsing -ErrorAction Stop
                if (Test-MicrosoftSignedFile -Path $target -OriginalFilename $OriginalFilename) { return $target }
                Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            }
            catch { Write-Warning "Could not download $RelativePath from $mp : $($_.Exception.Message)" }
        }
        return $null
    }

    # CoManagementSettings_Capabilities from CoManagementHandler.log; bit 0x10 = Intune owns the Windows Update workload.
    Function Get-CoManagementCapabilities {
        $log = Join-Path (Get-CCMLogDirectory) 'CoManagementHandler.log'
        if (-not (Test-Path -LiteralPath $log)) { return $null }
        $line = Select-String -LiteralPath $log -Pattern "Merged value for setting 'CoManagementSettings_Capabilities' is '(\d+)'" -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($line) { return [int]$line.Matches[0].Groups[1].Value }
        return $null
    }

    Function Test-CcmEvalTask {
        Param([Parameter(Mandatory=$true)]$Log)
        $task = Get-ScheduledTask -TaskPath '\Microsoft\Configuration Manager\' -TaskName 'Configuration Manager Health Evaluation' -ErrorAction SilentlyContinue
        if (-not $task) { Add-Finding -Log $Log -Text 'CcmEval task missing'; return }
        if ($task.State -eq 'Disabled') {
            if (Test-FixAllowed -Name 'CcmEvalTask' -Default $true) {
                Enable-ScheduledTask -InputObject $task -ErrorAction SilentlyContinue | Out-Null
                Write-Host 'CcmEval task: Disabled. Enabled.'
            }
            else { Add-Finding -Log $Log -Text 'CcmEval task disabled' }
        }
        $info = Get-ScheduledTaskInfo -InputObject $task -ErrorAction SilentlyContinue
        if ($info -and $info.LastRunTime -lt (Get-Date).AddDays(-3)) { Add-Finding -Log $Log -Text "CcmEval not run since $($info.LastRunTime.ToString('yyyy-MM-dd'))" }
        elseif ($info -and $info.LastTaskResult -ne 0) { Add-Finding -Log $Log -Text ('CcmEval last result 0x{0:X8}' -f $info.LastTaskResult) }
        else { Write-Host 'CcmEval task: OK' }
    }

    Function Test-ClientActivity {
        Param([Parameter(Mandatory=$true)]$Log)
        $days = Get-ConfigOption -Name 'ClientActivity' -Property 'Days' -Default 7
        $limit = (Get-Date).AddDays(-$days)
        $stale = @()
        $missingHeartbeat = $false
        # A site assignment change or a client reinstall clears InventoryActionStatus; a missing record is not a stale one.
        $heartbeat = (Get-CimInstance -Namespace root\ccm\invagt -ClassName InventoryActionStatus -ErrorAction SilentlyContinue | Where-Object { $_.InventoryActionID -eq '{00000000-0000-0000-0000-000000000003}' }).LastReportDate
        if ($null -eq $heartbeat) { $missingHeartbeat = $true }
        elseif ($heartbeat -lt $limit) { $stale += 'heartbeat' }
        $policyLog = Join-Path (Get-CCMLogDirectory) 'PolicyAgent.log'
        if (-not (Test-Path -LiteralPath $policyLog) -or (Get-Item -LiteralPath $policyLog).LastWriteTime -lt $limit) { $stale += 'policy' }

        if ($stale.Count -eq 0 -and -not $missingHeartbeat) { Write-Host 'Client activity: OK'; return }
        if ($missingHeartbeat) { Add-Finding -Log $Log -Text 'No heartbeat record' }
        if ($stale.Count -gt 0) { Add-Finding -Log $Log -Text "No $($stale -join ' or ') activity for $days days" }
        if (Test-FixAllowed -Name 'ClientActivity' -Default $true) {
            Invoke-CCMTrigger -ScheduleID '{00000000-0000-0000-0000-000000000021}'
            Invoke-CCMTrigger -ScheduleID '{00000000-0000-0000-0000-000000000022}'
            Invoke-CCMTrigger -ScheduleID '{00000000-0000-0000-0000-000000000003}'
        }
    }

    Function Test-WindowsUpdateSource {
        Param([Parameter(Mandatory=$true)]$Log)
        $policyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        $policy = Get-ItemProperty -Path $policyKey -ErrorAction SilentlyContinue
        $au = Get-ItemProperty -Path "$policyKey\AU" -ErrorAction SilentlyContinue
        $state = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\PolicyState' -ErrorAction SilentlyContinue
        $capabilities = Get-CoManagementCapabilities
        $intuneOwnsUpdates = ($null -ne $capabilities) -and (($capabilities -band 0x10) -ne 0)
        if ($au.UseWUServer -ne 1) { Write-Host 'Windows Update source: not managed by WSUS. Skipping.'; return }
        if ($intuneOwnsUpdates) { Write-Host 'Windows Update source: Intune owns the Windows Update workload. Skipping.'; return }

        # ConfigMgr 2409 and 2503 RTM wrote this value one level too high; Microsoft says to remove it.
        if ($policy -and $policy.PSObject.Properties['UseUpdateClassPolicySource']) {
            if (Test-FixAllowed -Name 'WindowsUpdateSource' -Default $true) {
                Remove-ItemProperty -Path $policyKey -Name 'UseUpdateClassPolicySource' -ErrorAction SilentlyContinue
                Restart-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
                Invoke-CCMTrigger -ScheduleID '{00000000-0000-0000-0000-000000000113}'
                Write-Host 'Windows Update source: removed UseUpdateClassPolicySource from the wrong registry path.'
            }
            else { Add-Finding -Log $Log -Text 'UseUpdateClassPolicySource at wrong registry path' }
        }

        $categories = 'Feature', 'Quality', 'Driver', 'Other'
        if ($au.UseUpdateClassPolicySource -eq 1) {
            $set = @($categories | Where-Object { $policy -and $policy.PSObject.Properties["SetPolicyDrivenUpdateSourceFor$($_)Updates"] })
            if ($set.Count -lt 4) { Add-Finding -Log $Log -Text "Scan source policy sets $($set.Count) of 4 update classes" }
        }
        $toWindowsUpdate = @($categories | Where-Object { $state -and $state.PSObject.Properties["SetPolicyDrivenUpdateSourceFor$($_)Updates"] -and $state."SetPolicyDrivenUpdateSourceFor$($_)Updates" -eq 0 })
        if ($toWindowsUpdate.Count -gt 0) { Add-Finding -Log $Log -Text "$($toWindowsUpdate -join ', ') updates scan Windows Update instead of WSUS" }
        if ($state.IsWUfBDualScanActive -eq 1) { Add-Finding -Log $Log -Text 'Windows Update dual scan active' }

        $leftovers = @($policy.PSObject.Properties | Where-Object { $_.Name -match '^(Defer(Feature|Quality)Updates|DeferUpgrade|Pause(Feature|Quality)Updates|ExcludeWUDriversInQualityUpdate)' } | Select-Object -ExpandProperty Name)
        if ($leftovers.Count -gt 0) { Add-Finding -Log $Log -Text "WSUS client has deferral policy: $($leftovers -join ', ')" }

        $build = [int](Get-CimInstance -ClassName Win32_OperatingSystem).BuildNumber
        if ($build -lt 22000 -and $policy.DisableDualScan -eq 1 -and $toWindowsUpdate.Count -gt 0) { Add-Finding -Log $Log -Text 'DisableDualScan conflicts with Windows Update scan source' }

        # KB36495448 for 2503 HFRU / 2509 clients writes this marker when it removes stale scan source policy.
        $clientVersion = ConvertTo-ClientVersion (Get-ClientVersion)
        if (($null -ne $capabilities) -and $clientVersion -and $clientVersion -ge [version]'5.0.9135.0' -and
            -not (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\CCM\SoftwareUpdates' -Name 'isScanSourcePolicyRemoved2' -ErrorAction SilentlyContinue)) {
            Add-Finding -Log $Log -Text 'Scan source policy hotfix KB36495448 not applied'
        }
    }

    # Scan error classes from Microsoft's software update scan troubleshooting guide.
    Function Test-WindowsUpdateScan {
        Param([Parameter(Mandatory=$true)]$Log, [datetime]$StartTime = [datetime]::MinValue)
        $entries = @(Get-CMLogEntry -LogFile (Join-Path (Get-CCMLogDirectory) 'WUAHandler.log') -StartTime $StartTime)
        if (@($entries | Where-Object { $_.Message -match 'overwritten by a higher authority \(Domain Controller\)' }).Count -gt 0) {
            $script:WsusDomainPolicyOverride = $true
            Add-Finding -Log $Log -Text 'Domain Group Policy overrides the WSUS server'
        }
        # Only scan and search failures count; WUAHandler also logs benign codes, such as 0x80070002 when no
        # resultant policy exists yet after a client install.
        $codes = @($entries | Where-Object { $_.Message -match 'scan|search' -and $_.Message -match 'fail|error' } | ForEach-Object { [regex]::Matches($_.Message, '0x[0-9A-Fa-f]{8}') | ForEach-Object { $_.Value.ToUpper() } } | Select-Object -Unique)
        if ($codes.Count -eq 0) { Write-Host 'Windows Update scan: OK'; return }

        $classes = [ordered]@{
            'corrupt Windows Update components' = '0X80245003','0X80070514','0X8DDD0018','0X80246008','0X80200013','0X80004015','0X800A0046','0X800A01AD','0X80070424','0X800B0100','0X80248011','0X80070002','0XC80003F3'
            'proxy'                             = '0X80244021','0X8024401B','0X80240030','0X8024402C'
            'timeout or authentication'         = '0X80072EE2','0X8024401C','0X80244023','0X80244017','0X80244018'
            'certificate'                       = '0X80072F0C'
        }
        $corrupt = $false
        foreach ($class in $classes.Keys) {
            $hit = @($codes | Where-Object { $classes[$class] -contains $_ })
            if ($hit.Count -gt 0) {
                Add-Finding -Log $Log -Text "Update scan errors ($class): $($hit -join ' ')"
                if ($class -like 'corrupt*') { $corrupt = $true }
            }
        }
        if (-not $corrupt -or -not (Test-FixAllowed -Name 'WindowsUpdateScan' -Default $false)) { return }

        # The reset clears Windows Update history, so it runs at most once per ResetDays.
        $resetDays = Get-ConfigOption -Name 'WindowsUpdateScan' -Property 'ResetDays' -Default 30
        $lastReset = Get-RegistryValue -Path 'HKLM:\Software\ConfigMgrClientHealth' -Name 'SoftwareDistributionReset'
        $lastResetDate = [datetime]::MinValue
        if ($lastReset) { [void][datetime]::TryParse([string]$lastReset, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$lastResetDate) }
        if ($lastResetDate -gt (Get-Date).AddDays(-$resetDays)) { Write-Host "Windows Update scan: reset skipped; last reset $($lastResetDate.ToString('yyyy-MM-dd'))."; return }

        $folder = Join-Path $env:SystemRoot 'SoftwareDistribution'
        try {
            Stop-Service -Name wuauserv -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $folder) { Rename-Item -LiteralPath $folder -NewName "SoftwareDistribution.old-$(Get-Date -Format 'yyyyMMddHHmmss')" -ErrorAction Stop }
            Start-Service -Name wuauserv -ErrorAction Stop
            Set-RegistryValue -Path 'HKLM:\Software\ConfigMgrClientHealth' -Name 'SoftwareDistributionReset' -Value ((Get-Date).ToString('o'))
            Invoke-CCMTrigger -ScheduleID '{00000000-0000-0000-0000-000000000113}'
            Write-Host 'Windows Update scan: SoftwareDistribution reset.'
        }
        catch {
            Start-Service -Name wuauserv -ErrorAction SilentlyContinue
            Add-Finding -Log $Log -Text "SoftwareDistribution reset failed: $($_.Exception.Message)"
        }
    }

    Function Test-TlsConfiguration {
        Param([Parameter(Mandatory=$true)]$Log)
        $netKeys = @('HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319', 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v2.0.50727',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v2.0.50727')
        $missing = @()
        foreach ($key in $netKeys) {
            if (-not (Test-Path -LiteralPath $key)) { continue }
            $values = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
            foreach ($name in 'SchUseStrongCrypto', 'SystemDefaultTlsVersions') { if ($values.$name -ne 1) { $missing += "$key\$name" } }
        }
        if ($missing.Count -gt 0) {
            # Documented for ConfigMgr clients; takes effect after a restart.
            if (Test-FixAllowed -Name 'TlsConfiguration' -Default $false) {
                foreach ($item in $missing) {
                    New-ItemProperty -LiteralPath (Split-Path $item -Parent) -Name (Split-Path $item -Leaf) -Value 1 -PropertyType DWord -Force | Out-Null
                }
                Add-Finding -Log $Log -Text '.NET strong crypto set; restart required'
            }
            else { Add-Finding -Log $Log -Text '.NET strong crypto not enabled' }
        }
        $tls12 = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client' -ErrorAction SilentlyContinue
        if ($tls12 -and (($tls12.PSObject.Properties['Enabled'] -and $tls12.Enabled -eq 0) -or $tls12.DisabledByDefault -eq 1)) { Add-Finding -Log $Log -Text 'TLS 1.2 client disabled in SChannel' }
        if ((Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\FipsAlgorithmPolicy' -ErrorAction SilentlyContinue).Enabled -eq 1) { Add-Finding -Log $Log -Text 'FIPS mode enabled' }
        $release = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
        if ($release -and $release -lt 528040) { Add-Finding -Log $Log -Text '.NET Framework older than 4.8' }
        if ($missing.Count -eq 0) { Write-Host 'TLS configuration: OK' }
    }

    Function Test-CoManagement {
        Param([Parameter(Mandatory=$true)]$Log, [datetime]$StartTime = [datetime]::MinValue)
        $capabilities = Get-CoManagementCapabilities
        if ($null -eq $capabilities) { Write-Host 'Co-management: not configured'; return }
        if ((($capabilities -band 0x10) -eq 0) -and (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update')) {
            $values = @((Get-Item -LiteralPath 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update').Property)
            if ($values.Count -gt 0) { Add-Finding -Log $Log -Text 'Intune Windows Update policy left on a ConfigMgr-managed device' }
        }
        $failure = @(Get-CMLogEntry -LogFile (Join-Path (Get-CCMLogDirectory) 'CoManagementHandler.log') -StartTime $StartTime | Where-Object { $_.Message -match 'MDM enrollment failed with error code (0x[0-9A-Fa-f]+)' }) | Select-Object -Last 1
        if ($failure) {
            $code = [regex]::Match($failure.Message, '0x[0-9A-Fa-f]+').Value
            $text = "Co-management enrollment failed $code"
            if (-not (Get-Service -Name dmwappushservice -ErrorAction SilentlyContinue)) { $text += ' (dmwappushservice missing)' }
            Add-Finding -Log $Log -Text $text
        }
        else { Write-Host 'Co-management: OK' }
    }

    Function Test-SecureChannel {
        Param([Parameter(Mandatory=$true)]$Log)
        if ((Get-CimInstance -ClassName Win32_ComputerSystem).PartOfDomain -ne $true) { return }
        try {
            if (Test-ComputerSecureChannel -ErrorAction Stop) { Write-Host 'Domain secure channel: OK' }
            else { Add-Finding -Log $Log -Text 'Domain secure channel broken' }
        }
        catch { Add-Finding -Log $Log -Text "Domain secure channel test failed: $($_.Exception.Message)" }
    }

    Function Test-ScriptPolicy {
        Param([Parameter(Mandatory=$true)]$Log)
        $policy = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell' -ErrorAction SilentlyContinue
        if ($policy -and $policy.EnableScripts -eq 1 -and $policy.ExecutionPolicy -in @('AllSigned', 'Restricted')) { Add-Finding -Log $Log -Text "Group Policy sets PowerShell execution policy $($policy.ExecutionPolicy)" }
        if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { Add-Finding -Log $Log -Text "PowerShell language mode $($ExecutionContext.SessionState.LanguageMode)" }
    }

    Function Test-SiteCommunication {
        Param([Parameter(Mandatory=$true)]$Log, [datetime]$StartTime = [datetime]::MinValue)
        $logDir = Get-CCMLogDirectory
        $signatures = [ordered]@{
            'CMG requires a client certificate' = 'CMGConnector_Clientcertificaterequired'
            'CMG refused the client'            = 'CMGConnector_Forbidden'
            'CMG token expired; reinstall with a new token or connect internally' = 'CMGService_Invalid_Token'
            'Certificate revocation check failed' = 'CERT_REV_FAILED'
            'Server certificate from an untrusted CA' = 'INVALID_CA'
            'Server certificate name mismatch' = 'CERT_CN_INVALID'
        }
        $messages = @(foreach ($file in 'LocationServices.log', 'CcmMessaging.log') { Get-CMLogEntry -LogFile (Join-Path $logDir $file) -StartTime $StartTime | Select-Object -ExpandProperty Message })
        $found = $false
        foreach ($text in $signatures.Keys) {
            if (@($messages | Where-Object { $_ -like "*$($signatures[$text])*" }).Count -gt 0) { Add-Finding -Log $Log -Text $text; $found = $true }
        }
        if (-not $found) { Write-Host 'Site communication: OK' }

        if (Get-ConfigOption -Name 'PkiCertificate' -Property 'Enable' -Default $false) {
            $warnDays = Get-ConfigOption -Name 'PkiCertificate' -Property 'Days' -Default 30
            $fqdn = [System.Net.Dns]::GetHostEntry('localhost').HostName
            $certs = @(Get-ChildItem -Path Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object {
                $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) -and
                ($_.EnhancedKeyUsageList | Where-Object { $_.ObjectId -eq '1.3.6.1.5.5.7.3.2' }) -and
                (($_.Subject -match [regex]::Escape($env:COMPUTERNAME)) -or ($_.DnsNameList.Unicode -contains $fqdn))
            })
            if ($certs.Count -eq 0) { Add-Finding -Log $Log -Text 'No valid PKI client authentication certificate' }
            elseif (($certs | Measure-Object -Property NotAfter -Maximum).Maximum -lt (Get-Date).AddDays($warnDays)) { Add-Finding -Log $Log -Text "PKI client certificate expires within $warnDays days" }
        }
    }

    Function Test-ClientIdentity {
        Param([Parameter(Mandatory=$true)]$Log)
        $ini = Join-Path $env:windir 'SMSCFG.ini'
        $iniId = $null
        if (Test-Path -LiteralPath $ini) {
            $line = Select-String -LiteralPath $ini -Pattern '^SMS Unique Identifier=(.+)$' | Select-Object -First 1
            if ($line) { $iniId = $line.Matches[0].Groups[1].Value.Trim() }
        }
        $wmiId = (Get-CimInstance -Namespace root\ccm -ClassName CCM_Client -ErrorAction SilentlyContinue).ClientId
        if ($iniId -and $wmiId -and $iniId -ne $wmiId) { Add-Finding -Log $Log -Text 'SMSCFG.ini and WMI client IDs differ' }
        $installDate = (Get-CimInstance -ClassName Win32_OperatingSystem).InstallDate
        $older = @(Get-ChildItem -Path Cert:\LocalMachine\SMS -ErrorAction SilentlyContinue | Where-Object { $_.NotBefore -lt $installDate.AddDays(-1) })
        if ($older.Count -gt 0) { Add-Finding -Log $Log -Text 'Client certificate older than the OS installation (cloned client)' }
        if (-not ($iniId -and $wmiId -and $iniId -ne $wmiId) -and $older.Count -eq 0) { Write-Host 'Client identity: OK' }
    }

    Function Test-DeliveryOptimization {
        Param([Parameter(Mandatory=$true)]$Log)
        $service = Get-Service -Name DoSvc -ErrorAction SilentlyContinue
        $mode = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' -ErrorAction SilentlyContinue).DODownloadMode
        if ($service -and $service.StartType -eq 'Disabled') { Add-Finding -Log $Log -Text 'Delivery Optimization service disabled' }
        elseif ($mode -eq 100) { Add-Finding -Log $Log -Text 'Delivery Optimization in bypass mode' }
        else { Write-Host 'Delivery Optimization: OK' }
    }

    # Windows Installer needs the cached package to repair, upgrade, or remove a product (error 1612 otherwise).
    Function Test-InstallerCache {
        Param([Parameter(Mandatory=$true)]$Log)
        $products = @(Get-InstalledMsiProduct -NamePattern '^(Configuration Manager Client|Microsoft Policy Platform|Microsoft Visual C\+\+ 20\d\d .*(Minimum|Additional) Runtime)')
        $broken = @($products | Where-Object { -not $_.CacheExists })
        if ($broken.Count -eq 0) { Write-Host 'Windows Installer cache: OK'; return }
        $fix = Test-FixAllowed -Name 'InstallerCache' -Default $true

        foreach ($product in $broken) {
            if ($product.Name -like 'Microsoft Policy Platform*' -and $fix) {
                $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'i386' }
                $msi = Get-MPClientSourceFile -RelativePath "$arch/MicrosoftPolicyPlatformSetup.msi"
                if ($msi -and (Get-MsiFileProperty -Path $msi -Property 'ProductVersion') -eq $product.Version) {
                    # REINSTALLMODE v runs from the source package and replaces the cached copy.
                    $logPath = Join-Path (Split-Path $msi -Parent) 'MicrosoftPolicyPlatformSetup-recache.log'
                    $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList @('/i', "`"$msi`"", 'REINSTALL=ALL', 'REINSTALLMODE=vomus', '/qn', '/norestart', '/l*v', "`"$logPath`"") -Wait -PassThru
                    if ($p.ExitCode -in 0, 3010) { Write-Host "Windows Installer cache: $($product.Name) recached."; continue }
                    Add-Finding -Log $Log -Text "Recache of $($product.Name) failed with $($p.ExitCode)"
                    continue
                }
                Add-Finding -Log $Log -Text "Cached installer missing: $($product.Name) $($product.Version) (no matching source on the management point)"
                continue
            }
            if ($product.Name -match 'Microsoft Visual C\+\+ .*\b(X64|X86)\b') { $script:VCRuntimeCacheBroken += @($Matches[1].ToLower()) }
            # ccmsetup /forceinstall from the management point rebuilds the client cache (client.msi cannot be run directly).
            if ($product.Name -eq 'Configuration Manager Client' -and $fix) {
                New-ClientInstalledReason -Log $Log -Message 'Client installer cache missing.'
                $script:ClientCacheReinstall = $true
                continue
            }
            Add-Finding -Log $Log -Text "Cached installer missing: $($product.Name) $($product.Version)"
        }
    }

    # ConfigMgr client 2107 and later requires the Visual C++ 2015-2022 runtime 14.28.29914 or later.
    Function Test-VCRuntime {
        Param([Parameter(Mandatory=$true)]$Log)
        $minimum = [version]'14.28.29914'
        $targets = @(@{ Arch = 'x86'; Key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x86'; Source = 'i386/vcredist_x86.exe'; Name = 'VC_redist.x86.exe'; Dll = (Join-Path $env:windir 'SysWOW64\vcruntime140.dll') })
        if ([Environment]::Is64BitOperatingSystem) {
            $targets += @{ Arch = 'x64'; Key = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'; Source = 'x64/vcredist_x64.exe'; Name = 'VC_redist.x64.exe'; Dll = (Join-Path $env:windir 'System32\vcruntime140.dll') }
        }
        else { $targets[0].Key = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x86'; $targets[0].Dll = (Join-Path $env:windir 'System32\vcruntime140.dll') }

        $ok = $true
        foreach ($t in $targets) {
            $reg = Get-ItemProperty -LiteralPath $t.Key -ErrorAction SilentlyContinue
            $installed = $null
            if ($reg -and $reg.Installed -eq 1) { [void][version]::TryParse(([string]$reg.Version).TrimStart('v'), [ref]$installed) }
            $problem = $null
            if ($null -eq $installed) { $problem = 'missing' }
            elseif ($installed -lt $minimum) { $problem = "version $installed below $minimum" }
            elseif (-not (Test-Path -LiteralPath $t.Dll)) { $problem = 'runtime DLL missing' }
            elseif (@($script:VCRuntimeCacheBroken) -contains $t.Arch) { $problem = 'cached installer missing' }
            if (-not $problem) { continue }
            $ok = $false

            if (-not (Test-FixAllowed -Name 'VCRuntime' -Default $true)) { Add-Finding -Log $Log -Text "VC++ runtime $($t.Arch) $problem"; continue }
            $exe = Get-MPClientSourceFile -RelativePath $t.Source -OriginalFilename $t.Name
            if (-not $exe) { Add-Finding -Log $Log -Text "VC++ runtime $($t.Arch) $problem; no installer on the management point"; continue }
            $sourceVersion = [version](Get-Item -LiteralPath $exe).VersionInfo.FileVersion
            # The installer refuses to repair or downgrade a newer runtime; it only installs or repairs its own version or older.
            if ($installed -and $sourceVersion -lt [version]"$($installed.Major).$($installed.Minor).$($installed.Build)") {
                Add-Finding -Log $Log -Text "VC++ runtime $($t.Arch) $problem; management point has older $sourceVersion"
                continue
            }
            $action = if ($installed) { '/repair' } else { '/install' }
            $logPath = Join-Path (Split-Path $exe -Parent) "vcredist_$($t.Arch).log"
            $p = Start-Process -FilePath $exe -ArgumentList @($action, '/quiet', '/norestart', '/log', "`"$logPath`"") -Wait -PassThru
            if ($p.ExitCode -in 0, 3010) { Write-Host "VC++ runtime $($t.Arch): $problem. $($action.TrimStart('/')) succeeded." }
            else { Add-Finding -Log $Log -Text "VC++ runtime $($t.Arch) $($action.TrimStart('/')) failed with $($p.ExitCode)" }
        }
        if ($ok) { Write-Host 'VC++ runtime: OK' }
    }

    #endregion

    #endregion

    # Set default restart values to false
    $newinstall = $false
    $restartCCMExec = $false
    $Reinstall = $false


    # If config.xml is used
    if ($Config) {

        # Validate config inputs before use
        Test-ConfigValues -Xml $Xml
        if ($script:ConfigRawToCache) { Save-ConfigCache -CachePath $ConfigCachePath -Content $script:ConfigRawToCache }

        $script:MonitorOnly = Test-MonitorOnly
        if ($script:MonitorOnly) {
            Write-Warning 'CcmEval NotifyOnly is set: this device is excluded from automatic remediation. Checks run in monitor mode.'
            Set-MonitorOnlyConfig
        }

        # Build the ConfigMgr Client Install Property string
        $propertyString = ""
        if ($script:JsonConfig) {
            foreach ($property in $script:JsonConfig.ClientInstallProperties) {
                $propertyString = $propertyString + $property + ' '
            }
        }
        else {
            foreach ($property in $Xml.Configuration.ClientInstallProperty) {
                $propertyString = $propertyString + $property
                $propertyString = $propertyString + ' '
            }
        }
        $clientCacheSize = Get-XMLConfigClientCache
        $clientInstallProperties = $propertyString
        $clientAutoUpgrade = ([string](Get-XMLConfigClientAutoUpgrade)).ToLower()
        $AdminShare = Get-XMLConfigRemediationAdminShare
        $ClientProvisioningMode = Get-XMLConfigRemediationClientProvisioningMode
        $ClientStateMessages = Get-XMLConfigRemediationClientStateMessages
        $ClientWUAHandler = Get-XMLConfigRemediationClientWUAHandler
        $LogShare = Get-XMLConfigLoggingShare
    }

}

Process {
    Write-Verbose "Starting precheck. Determing if script will run or not."
    # Veriy script is running with administrative priveleges.
    If (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))
    {
        $text = 'ERROR: Powershell not running as Administrator! Client Health aborting.'
        Out-LogFile -Xml $Xml -Text $text -Severity 3
        Write-Error $text
        Exit 1
    }
    else {
        # Will exit with errorcode 2 if in task sequence
        Test-InTaskSequence

        $StartupText1 = "PowerShell version: " + $PSVersionTable.PSVersion + ". Script executing with Administrator rights."
        Write-Host $StartupText1

        $StartupText2 = "ConfigMgr Client Health " +$Version+ " starting."
        Write-Host $StartupText2
    }


    # If config.xml is used
    $LocalLogging = ([string](Get-XMLConfigLoggingLocalFile)).ToLower()
    $FileLogging = ([string](Get-XMLConfigLoggingEnable)).ToLower()
    $FileLogLevel = ([string](Get-XMLConfigLoggingLevel)).ToLower()
    $SQLLogging = ([string](Get-XMLConfigSQLLoggingEnable)).ToLower()


    $RegistryKey = "HKLM:\Software\ConfigMgrClientHealth"
    $LastRunRegistryValueName = "LastRun"

    #Get the last run from the registry, defaulting to the minimum date value if the script has never ran.
    try{[datetime]$LastRun = Get-RegistryValue -Path $RegistryKey -Name $LastRunRegistryValueName}
    catch{$LastRun=[datetime]::MinValue}
    Write-Output "Script last ran: $($LastRun)"

    Write-Verbose "Testing if log files are bigger than max history for logfiles."
    Test-ConfigMgrHealthLogging

    # Create the log object containing the result of health check
    $Log = New-LogObject

    # Only test this is not using webservice
    if ($config) {
        Write-Verbose 'Testing SQL Server connection'
        if (($SQLLogging -like 'true') -and ((Test-SQLConnection) -eq $false)) {
            # Failed to create SQL connection. Logging this error to fileshare and aborting script.
            #Exit 1
        }
    }


    Write-Verbose 'Validating WMI is not corrupt...'
    $WMI = Get-XMLConfigWMI
    if ($WMI -like 'True') {
        Write-Verbose 'Checking if WMI is corrupt. Will reinstall configmgr client if WMI is rebuilt.'
        if ((Test-WMI -log $Log) -eq $true) {
            $reinstall = $true
            New-ClientInstalledReason -Log $Log -Message "Corrupt WMI."
        }
    }

    Write-Verbose 'Determining if compliance state should be resent...'
    if (ConvertTo-ConfigBoolean (Get-XMLConfigRefreshComplianceState)) {
        $RefreshComplianceStateDays = ConvertTo-ConfigInt -Value (Get-XMLConfigRefreshComplianceStateDays) -Default 7 -Minimum 1

        Write-Verbose "Checking if compliance state should be resent after $($RefreshComplianceStateDays) days."
        Test-RefreshComplianceState -Days $RefreshComplianceStateDays -RegistryKey $RegistryKey  -log $Log
    }

    Write-Verbose 'Testing if ConfigMgr client is installed. Installing if not.'
    Test-ConfigMgrClient -Log $Log
    # A reinstall performed by Test-ConfigMgrClient also covers a reinstall tagged by the WMI check.
    if ($script:ClientReinstalledThisRun) { $Reinstall = $false }

    Write-Verbose 'Validating if ConfigMgr client is running the minimum version...'
    if ((Test-ClientVersion -Log $log) -eq $true) {
        if ($clientAutoUpgrade -like 'true') {
            $reinstall = $true
            New-ClientInstalledReason -Log $Log -Message "Below minimum verison."
        }
    }

    <#
    Write-Verbose 'Validate that ConfigMgr client do not have CcmSQLCE.log and are not in debug mode'
    if (Test-CcmSQLCELog -eq $true) {
        # This is a very bad situation. ConfigMgr agent is fubar. Local SDF files are deleted by the test itself, now reinstalling client immediatly. Waiting 10 minutes before continuing with health check.
        Resolve-Client -Xml $xml -ClientInstallProperties $ClientInstallProperties
        Start-Sleep -Seconds 600
    }
    #>

    Write-Verbose 'Validating services...'
    if ($script:MonitorOnly) { $log.Services = 'Not checked (NotifyOnly)' }
    else { Test-Services -Xml $Xml -log $log }

    Write-Verbose 'Validating SMSTSMgr service is depenent on CCMExec service...'
    Test-SMSTSMgr -Log $Log

    Write-Verbose 'Validating ConfigMgr SiteCode...'
    Test-ClientSiteCode -Log $Log

    Write-Verbose 'Validating client cache size. Will restart configmgr client if cache size is changed'

    $CacheCheckEnabled = Get-XMLConfigClientCacheEnable
    if ($CacheCheckEnabled -like 'True') {
        $TestClientCacheSzie = Test-ClientCacheSize -Log $Log
        # This check is now able to set ClientCacheSize without restarting CCMExec service.
        if ($TestClientCacheSzie -eq $true) { $restartCCMExec = $false }
    }


    if (ConvertTo-ConfigBoolean (Get-XMLConfigClientMaxLogSizeEnabled)) {
        Write-Verbose 'Validating Max CCMClient Log Size...'
        $TestClientLogSize = Test-ClientLogSize -Log $Log
        if ($TestClientLogSize -eq $true) { $restartCCMExec = $true }
    }

    Write-Verbose 'Validating CCMClient provisioning mode...'
    if (($ClientProvisioningMode -like 'True') -eq $true) { Test-ProvisioningMode -log $log }
    Write-Verbose 'Validating CCMClient certificate...'

    if ((Test-CCMCertificateError -Log $Log -StartTime $LastRun) -eq $true) {
        $Reinstall = $true
        $Uninstall = $true
    }
    if (ConvertTo-ConfigBoolean (Get-XMLConfigHardwareInventoryEnable)) { Test-SCCMHardwareInventoryScan -Log $log }


    if (ConvertTo-ConfigBoolean (Get-XMLConfigSoftwareMeteringEnable)) {
        Write-Verbose "Testing software metering prep driver check"
        if ((Test-SoftwareMeteringPrepDriver -Log $Log -StartTime $LastRun) -eq $false) {$restartCCMExec = $true}
    }

    Write-Verbose 'Validating DNS...'
    if (ConvertTo-ConfigBoolean (Get-XMLConfigDNSCheck)) { Test-DNSConfiguration -Log $log }

    Write-Verbose 'Validating BITS'
    if (ConvertTo-ConfigBoolean (Get-XMLConfigBITSCheck)) {
        if ((Test-BITS -Log $Log) -eq $true) {
            #$Reinstall = $true
        }
    }

    Write-Verbose 'Validating ClientSettings'
	If (ConvertTo-ConfigBoolean (Get-XMLConfigClientSettingsCheck)) {
        Test-ClientSettingsConfiguration -Log $log
	}

    # Extended checks. One failing check is recorded as a finding and does not stop the run.
    $extendedChecks = [ordered]@{
        'CcmEvalTask'          = { Test-CcmEvalTask -Log $Log }
        'ClientActivity'       = { Test-ClientActivity -Log $Log }
        'WindowsUpdateSource'  = { Test-WindowsUpdateSource -Log $Log }
        'WindowsUpdateScan'    = { Test-WindowsUpdateScan -Log $Log -StartTime $LastRun }
        'TlsConfiguration'     = { Test-TlsConfiguration -Log $Log }
        'CoManagement'         = { Test-CoManagement -Log $Log -StartTime $LastRun }
        'SecureChannel'        = { Test-SecureChannel -Log $Log }
        'ScriptPolicy'         = { Test-ScriptPolicy -Log $Log }
        'SiteCommunication'    = { Test-SiteCommunication -Log $Log -StartTime $LastRun }
        'ClientIdentity'       = { Test-ClientIdentity -Log $Log }
        'DeliveryOptimization' = { Test-DeliveryOptimization -Log $Log }
        'InstallerCache'       = { Test-InstallerCache -Log $Log }
        'VCRuntime'            = { Test-VCRuntime -Log $Log }
    }
    foreach ($name in $extendedChecks.Keys) {
        if (-not (Get-ConfigOption -Name $name -Property 'Enable' -Default $true)) { continue }
        Write-Verbose "Running check $name..."
        try { & $extendedChecks[$name] }
        catch { Add-Finding -Log $Log -Text "Check $name failed: $($_.Exception.Message)" }
    }
    if ($script:ClientCacheReinstall) {
        $Reinstall = $true
        $Uninstall = $true
    }

    if (($ClientWUAHandler -like 'True') -eq $true) {
		Write-Verbose 'Validating Windows Update Scan not broken by bad group policy...'
        $days = Get-XMLConfigRemediationClientWUAHandlerDays
        Test-RegistryPol -Days $days -log $log -StartTime $LastRun

    }


    if (($ClientStateMessages -like 'True') -eq $true) {
        Write-Verbose 'Validating that CCMClient is sending state messages...'
        Test-UpdateStore -log $log
    }

    Write-Verbose 'Validating Admin$ and C$ are shared...'
    if (($AdminShare -like 'True') -eq $true) {Test-AdminShare -log $log}

    Write-Verbose 'Testing that all devices have functional drivers.'
    if (ConvertTo-ConfigBoolean (Get-XMLConfigDrivers)) {Test-MissingDrivers -Log $log}

    $UpdatesEnabled = Get-XMLConfigUpdatesEnable
    if ($UpdatesEnabled -like 'True') {
		Write-Verbose 'Validating required updates are installed...'
		Test-Update -Log $log
	}

    Write-Verbose "Validating $env:SystemDrive free diskspace (Only warning, no remediation)..."
    Test-DiskSpace
    Write-Verbose 'Getting install date of last OS patch for SQL log'
    Get-LastInstalledPatches -Log $log
    Write-Verbose 'Sending unsent state messages if any'
    Invoke-CCMTrigger -ScheduleID '{00000000-0000-0000-0000-000000000111}'
    Write-Verbose 'Getting Source Update Message policy and policy to trigger scan update source'

    if ($newinstall -eq $false) {
        Invoke-CCMTrigger -ScheduleID '{00000000-0000-0000-0000-000000000032}'
        Invoke-CCMTrigger -ScheduleID '{00000000-0000-0000-0000-000000000113}'
        Invoke-CCMTrigger -ScheduleID '{00000000-0000-0000-0000-000000000111}'
    }
    Invoke-CCMTrigger -ScheduleID '{00000000-0000-0000-0000-000000000022}'

    # Restart ConfigMgr client if tagged for restart and no reinstall tag
    if (($restartCCMExec -eq $true) -and ($Reinstall -eq $false)) {
        Write-Output "Restarting service CcmExec..."

        Restart-Service -Name CcmExec

        $Log.MaxLogSize = Get-ClientMaxLogSize
        $Log.MaxLogHistory = Get-ClientMaxLogHistory
        $log.CacheSize = Get-ClientCache
    }

    # Updating SQL Log object with current version number
    $log.Version = $Version

    Write-Verbose 'Cleaning up after healthcheck'
    CleanUp
    Write-Verbose 'Validating pending reboot...'
    Test-PendingReboot -log $log
    Write-Verbose 'Getting last reboot time'
    Get-LastReboot -Xml $xml

    if (ConvertTo-ConfigBoolean (Get-XMLConfigClientCacheDeleteOrphanedData)) {
        Write-Verbose "Removing orphaned ccm client cache items."
        Remove-CCMOrphanedCache
    }

    # Reinstall client if tagged for reinstall and configmgr client is not already installing
    $proc = Get-Process ccmsetup -ErrorAction SilentlyContinue

    if (($reinstall -eq $true) -and ($null -ne $proc) ) { Write-Warning "ConfigMgr Client set to reinstall, but ccmsetup.exe is already running." }
    elseif (($Reinstall -eq $true) -and $script:ClientReinstalledThisRun) { Write-Warning "ConfigMgr Client set to reinstall, but it was already reinstalled during this run." }
    elseif (($Reinstall -eq $true) -and ($null -eq $proc)) {
        Write-Verbose 'Reinstalling ConfigMgr Client'
        if (Resolve-Client -Xml $Xml -ClientInstallProperties $ClientInstallProperties -Log $Log) {
            # Add smalldate timestamp in SQL for when client was installed by Client Health.
            $log.ClientInstalled = Get-SmallDateTime
            $Log.MaxLogSize = Get-ClientMaxLogSize
            $Log.MaxLogHistory = Get-ClientMaxLogHistory
            $log.CacheSize = Get-ClientCache

            # Verify that installed client version is now equal or better that minimum required client version
            $NewClientVersion = Get-ClientVersion
            $MinimumClientVersion = Get-XMLConfigClientVersion

            if (-not (Test-ClientVersionAtLeast -Installed $NewClientVersion -Minimum $MinimumClientVersion)) {
                New-ClientInstalledReason -Log $Log -Message "Upgrade failed."
            }
        }
    }

    # Get the latest client version in case it was reinstalled by the script
    $log.ClientVersion = Get-ClientVersion

    # Trigger default Microsoft CM client health evaluation
    Start-Ccmeval
    Write-Verbose "End Process"
}

End {
    # Update database and logfile with results

    #Set the last run.
    $Date = Get-Date
    Set-RegistryValue -Path $RegistryKey -Name $LastRunRegistryValueName -Value $Date
    Write-Output "Setting last ran to $($Date)"

    if ($LocalLogging -like 'true') {
        Write-Output 'Updating local logfile with results'
        Update-LogFile -Log $log -Mode 'Local'
    }

    if (($FileLogging -like 'true') -and ($FileLogLevel -like 'full')) {
        Write-Output 'Updating fileshare logfile with results'
        Update-LogFile -Log $log
    }

    if (($SQLLogging -eq 'true') -and -not $PSBoundParameters.ContainsKey('Webservice')) {
        Write-Output 'Updating SQL database with results'
        Update-SQL -Log $log
    }

    if ($PSBoundParameters.ContainsKey('Webservice')) {
        Write-Output 'Updating SQL database with results using webservice'
        Update-Webservice -URI $Webservice -Log $Log
    }
    Write-Verbose "Client Health script finished"
    # Exit code 1 when a client install or a result upload failed; checks that only report do not count.
    if ($script:FailureCount -gt 0) { exit 1 }
    exit 0
}
