<#
.SYNOPSIS
    Converts a ConfigMgr Client Health config.xml to config.json format.

.DESCRIPTION
    Reads an existing config.xml and produces an equivalent config.json
    with the new JSON structure. Preserves all settings, services, and
    remediation options.

.PARAMETER XmlPath
    Path to the existing config.xml file.

.PARAMETER OutputPath
    Path for the output config.json file. Defaults to config.json in the
    same directory as the XML file.

.EXAMPLE
    .\Convert-ConfigXmlToJson.ps1 -XmlPath .\config.xml
    .\Convert-ConfigXmlToJson.ps1 -XmlPath \\server\share\config.xml -OutputPath C:\temp\config.json
#>
param(
    [Parameter(Mandatory)]
    [ValidateScript({Test-Path $_})]
    [string]$XmlPath,

    [string]$OutputPath
)

if (-not $OutputPath) {
    $OutputPath = Join-Path (Split-Path $XmlPath -Parent) 'config.json'
}

[xml]$xml = Get-Content $XmlPath

# Helper to extract XML values
function Get-XmlValue {
    param($Node, $Name, $Property = '#text')
    $item = $Node | Where-Object { $_.Name -like $Name }
    if ($null -eq $item) { return $null }
    try { return $item.$Property } catch { return $null }
}

function Get-XmlBool {
    param($Value)
    if ($null -eq $Value) { return $false }
    return ($Value.ToString().ToLower() -eq 'true')
}

$installProperties = @($xml.Configuration.ClientInstallProperty | ForEach-Object { [string]$_ } | Where-Object { $_ })

$managementPoints = @()
if ($xml.Configuration.ManagementPoints) {
    $managementPoints = @($xml.Configuration.ManagementPoints.MP | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
}
if ($managementPoints.Count -eq 0) {
    foreach ($token in $installProperties) {
        if ($token -match '^(SMSMP|MP)=(.+)$') { $managementPoints += $Matches[2].Trim().Trim('"') }
        elseif ($token -match '^/mp:(.+)$') { $managementPoints += $Matches[1].Trim().Trim('"') }
    }
    $managementPoints = @($managementPoints | Select-Object -Unique)
}
if ($managementPoints.Count -eq 0) {
    Write-Warning 'No management point found in config.xml. Add Client.ManagementPoints to the output before deploying; client installs fail without it.'
}

# The client script injects SMSMP= and /mp: from Client.ManagementPoints at install time.
$installProperties = @($installProperties | Where-Object { $_ -notmatch '^(SMSMP|MP)=' -and $_ -notmatch '^/mp:' })

$cacheNode = $xml.Configuration.Client | Where-Object { $_.Name -like 'CacheSize' }
$cacheSize = [string]$cacheNode.Value
$cacheSizeNumber = 0
# A percentage size such as "10%" stays a string; the client script supports both forms.
$cacheSizeValue = if ([int]::TryParse($cacheSize, [ref]$cacheSizeNumber)) { $cacheSizeNumber } else { $cacheSize }

$legacyShare = Get-XmlValue $xml.Configuration.Client 'Share'
if ($legacyShare) {
    Write-Warning "Client.Share ('$legacyShare') is not converted. ccmsetup.exe is downloaded from the management points."
}

$mpHttps = Get-XmlBool (Get-XmlValue $xml.Configuration.Client 'MPHttps')

# Option attribute with the documented default when the attribute is absent (older config.xml files).
function Get-OptionValue {
    param([string]$Name, [string]$Property, $Default)
    $node = $xml.Configuration.Option | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $node -or -not $node.HasAttribute($Property)) { return $Default }
    $value = $node.GetAttribute($Property)
    if ($Default -is [bool]) { return ($value -eq 'True') }
    if ($Default -is [int]) { $n = 0; if ([int]::TryParse($value, [ref]$n)) { return $n }; return $Default }
    return $value
}

# Build the JSON structure
$config = [ordered]@{
    LocalFiles = $xml.Configuration.LocalFiles

    Client = [ordered]@{
        Version     = Get-XmlValue $xml.Configuration.Client 'Version'
        SiteCode    = Get-XmlValue $xml.Configuration.Client 'SiteCode'
        Domain      = Get-XmlValue $xml.Configuration.Client 'Domain'
        AutoUpgrade = Get-XmlBool (Get-XmlValue $xml.Configuration.Client 'AutoUpgrade')
        ManagementPoints = @($managementPoints)
        MPHttps     = $mpHttps
        Cache = [ordered]@{
            Size              = $cacheSizeValue
            DeleteOrphanedData = Get-XmlBool $cacheNode.DeleteOrphanedData
            Enable            = Get-XmlBool $cacheNode.Enable
        }
        Log = [ordered]@{
            MaxSize    = [int](($xml.Configuration.Client | Where-Object { $_.Name -like 'Log' }).MaxLogSize)
            MaxHistory = [int](($xml.Configuration.Client | Where-Object { $_.Name -like 'Log' }).MaxLogHistory)
            Enable     = Get-XmlBool (($xml.Configuration.Client | Where-Object { $_.Name -like 'Log' }).Enable)
        }
    }

    ClientInstallProperties = @($installProperties)

    Logging = [ordered]@{
        Share        = ($xml.Configuration.Log | Where-Object { $_.Name -like 'File' }).Share
        Level        = ($xml.Configuration.Log | Where-Object { $_.Name -like 'File' }).Level
        MaxHistory   = [int](($xml.Configuration.Log | Where-Object { $_.Name -like 'File' }).MaxLogHistory)
        LocalLogFile = Get-XmlBool (($xml.Configuration.Log | Where-Object { $_.Name -like 'File' }).LocalLogFile)
        FileEnabled  = Get-XmlBool (($xml.Configuration.Log | Where-Object { $_.Name -like 'File' }).Enable)
        TimeFormat   = ($xml.Configuration.Log | Where-Object { $_.Name -like 'Time' }).Format
        SQL = [ordered]@{
            Server  = ($xml.Configuration.Log | Where-Object { $_.Name -like 'SQL' }).Server
            Enabled = Get-XmlBool (($xml.Configuration.Log | Where-Object { $_.Name -like 'SQL' }).Enable)
        }
    }

    Options = [ordered]@{
        CcmSQLCELog       = Get-XmlBool (Get-XmlValue $xml.Configuration.Option 'CcmSQLCELog' 'Enable')
        BITSCheck          = [ordered]@{
            Enable = Get-XmlBool (Get-XmlValue $xml.Configuration.Option 'BITSCheck' 'Enable')
            Fix    = Get-XmlBool (Get-XmlValue $xml.Configuration.Option 'BITSCheck' 'Fix')
            Days   = Get-OptionValue 'BITSCheck' 'Days' 7
        }
        ClientSettingsCheck = [ordered]@{
            Enable = Get-XmlBool (Get-XmlValue $xml.Configuration.Option 'ClientSettingsCheck' 'Enable')
            Fix    = Get-XmlBool (Get-XmlValue $xml.Configuration.Option 'ClientSettingsCheck' 'Fix')
        }
        DNSCheck           = [ordered]@{
            Enable = Get-XmlBool (Get-XmlValue $xml.Configuration.Option 'DNSCheck' 'Enable')
            Fix    = Get-XmlBool (Get-XmlValue $xml.Configuration.Option 'DNSCheck' 'Fix')
        }
        Drivers            = Get-XmlBool (Get-XmlValue $xml.Configuration.Option 'Drivers' 'Enable')
        PatchLevel         = Get-XmlBool (Get-XmlValue $xml.Configuration.Option 'PatchLevel' 'Enable')
        Updates            = [ordered]@{
            Share  = Get-XmlValue $xml.Configuration.Option 'Updates' 'Share'
            Enable = Get-XmlBool (Get-XmlValue $xml.Configuration.Option 'Updates' 'Enable')
            Fix    = Get-XmlBool (Get-XmlValue $xml.Configuration.Option 'Updates' 'Fix')
        }
        PendingReboot      = [ordered]@{
            Enable                 = Get-XmlBool (Get-XmlValue $xml.Configuration.Option 'PendingReboot' 'Enable')
            StartRebootApplication = Get-XmlBool (Get-XmlValue $xml.Configuration.Option 'PendingReboot' 'StartRebootApplication')
        }
        RebootApplication  = [ordered]@{
            Enable      = Get-XmlBool (Get-XmlValue $xml.Configuration.Option 'RebootApplication' 'Enable')
            Application = Get-XmlValue $xml.Configuration.Option 'RebootApplication' 'Application'
        }
        MaxRebootDays      = [int](Get-XmlValue $xml.Configuration.Option 'MaxRebootDays' 'Days')
        OSDiskFreeSpace    = [int](Get-XmlValue $xml.Configuration.Option 'OSDiskFreeSpace')
        HardwareInventory  = [ordered]@{
            Enable = Get-XmlBool (Get-XmlValue $xml.Configuration.Option 'HardwareInventory' 'Enable')
            Fix    = Get-XmlBool (Get-XmlValue $xml.Configuration.Option 'HardwareInventory' 'Fix')
            Days   = [int](Get-XmlValue $xml.Configuration.Option 'HardwareInventory' 'Days')
        }
        SoftwareMetering   = [ordered]@{
            Enable = Get-XmlBool (Get-XmlValue $xml.Configuration.Option 'SoftwareMetering' 'Enable')
            Fix    = Get-XmlBool (Get-XmlValue $xml.Configuration.Option 'SoftwareMetering' 'Fix')
        }
        WMI                = [ordered]@{
            Enable = Get-XmlBool (Get-XmlValue $xml.Configuration.Option 'WMI' 'Enable')
            Fix    = Get-XmlBool (Get-XmlValue $xml.Configuration.Option 'WMI' 'Fix')
        }
        RefreshComplianceState = [ordered]@{
            Enable = Get-XmlBool (Get-XmlValue $xml.Configuration.Option 'RefreshComplianceState' 'Enable')
            Days   = [int](Get-XmlValue $xml.Configuration.Option 'RefreshComplianceState' 'Days')
        }
        CcmEvalTask          = [ordered]@{ Enable = Get-OptionValue 'CcmEvalTask' 'Enable' $true; Fix = Get-OptionValue 'CcmEvalTask' 'Fix' $true }
        ClientActivity       = [ordered]@{ Enable = Get-OptionValue 'ClientActivity' 'Enable' $true; Fix = Get-OptionValue 'ClientActivity' 'Fix' $true; Days = Get-OptionValue 'ClientActivity' 'Days' 7 }
        WindowsUpdateSource  = [ordered]@{ Enable = Get-OptionValue 'WindowsUpdateSource' 'Enable' $true; Fix = Get-OptionValue 'WindowsUpdateSource' 'Fix' $true }
        WindowsUpdateScan    = [ordered]@{ Enable = Get-OptionValue 'WindowsUpdateScan' 'Enable' $true; Fix = Get-OptionValue 'WindowsUpdateScan' 'Fix' $false; ResetDays = Get-OptionValue 'WindowsUpdateScan' 'ResetDays' 30 }
        TlsConfiguration     = [ordered]@{ Enable = Get-OptionValue 'TlsConfiguration' 'Enable' $true; Fix = Get-OptionValue 'TlsConfiguration' 'Fix' $false }
        CoManagement         = [ordered]@{ Enable = Get-OptionValue 'CoManagement' 'Enable' $true }
        SecureChannel        = [ordered]@{ Enable = Get-OptionValue 'SecureChannel' 'Enable' $true }
        ScriptPolicy         = [ordered]@{ Enable = Get-OptionValue 'ScriptPolicy' 'Enable' $true }
        SiteCommunication    = [ordered]@{ Enable = Get-OptionValue 'SiteCommunication' 'Enable' $true }
        PkiCertificate       = [ordered]@{ Enable = Get-OptionValue 'PkiCertificate' 'Enable' $false; Days = Get-OptionValue 'PkiCertificate' 'Days' 30 }
        ClientIdentity       = [ordered]@{ Enable = Get-OptionValue 'ClientIdentity' 'Enable' $true }
        DeliveryOptimization = [ordered]@{ Enable = Get-OptionValue 'DeliveryOptimization' 'Enable' $true }
        InstallerCache       = [ordered]@{ Enable = Get-OptionValue 'InstallerCache' 'Enable' $true; Fix = Get-OptionValue 'InstallerCache' 'Fix' $true }
        VCRuntime            = [ordered]@{ Enable = Get-OptionValue 'VCRuntime' 'Enable' $true; Fix = Get-OptionValue 'VCRuntime' 'Fix' $true }
    }

    Services = @(
        foreach ($svc in $xml.Configuration.Service) {
            [ordered]@{
                Name        = $svc.Name
                StartupType = $svc.StartupType
                State       = $svc.State
                Uptime      = $svc.Uptime
            }
        }
    )

    Remediation = [ordered]@{
        AdminShare              = Get-XmlBool (($xml.Configuration.Remediation | Where-Object { $_.Name -like 'AdminShare' }).Fix)
        ClientProvisioningMode  = Get-XmlBool (($xml.Configuration.Remediation | Where-Object { $_.Name -like 'ClientProvisioningMode' }).Fix)
        ClientStateMessages     = Get-XmlBool (($xml.Configuration.Remediation | Where-Object { $_.Name -like 'ClientStateMessages' }).Fix)
        ClientWUAHandler        = [ordered]@{
            Fix  = Get-XmlBool (($xml.Configuration.Remediation | Where-Object { $_.Name -like 'ClientWUAHandler' }).Fix)
            Days = [int](($xml.Configuration.Remediation | Where-Object { $_.Name -like 'ClientWUAHandler' }).Days)
        }
        ClientCertificate       = Get-XmlBool (($xml.Configuration.Remediation | Where-Object { $_.Name -like 'ClientCertificate' }).Fix)
    }

    Sites = [ordered]@{
        Default = [ordered]@{}
    }
}

$json = $config | ConvertTo-Json -Depth 5
$json | Set-Content -Path $OutputPath -Encoding UTF8
Write-Host "Converted: $XmlPath -> $OutputPath" -ForegroundColor Green
Write-Host "Review the output and update the Sites section for your environment."
