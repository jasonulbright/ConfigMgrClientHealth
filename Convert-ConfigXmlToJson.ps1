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

# Build the JSON structure
$config = [ordered]@{
    LocalFiles = $xml.Configuration.LocalFiles

    Client = [ordered]@{
        Version     = Get-XmlValue $xml.Configuration.Client 'Version'
        SiteCode    = Get-XmlValue $xml.Configuration.Client 'SiteCode'
        Domain      = Get-XmlValue $xml.Configuration.Client 'Domain'
        AutoUpgrade = Get-XmlBool (Get-XmlValue $xml.Configuration.Client 'AutoUpgrade')
        Share       = Get-XmlValue $xml.Configuration.Client 'Share'
        Cache = [ordered]@{
            Size              = [int](($xml.Configuration.Client | Where-Object { $_.Name -like 'CacheSize' }).Value)
            DeleteOrphanedData = Get-XmlBool (($xml.Configuration.Client | Where-Object { $_.Name -like 'CacheSize' }).DeleteOrphanedData)
            Enable            = Get-XmlBool (($xml.Configuration.Client | Where-Object { $_.Name -like 'CacheSize' }).Enable)
        }
        Log = [ordered]@{
            MaxSize    = [int](($xml.Configuration.Client | Where-Object { $_.Name -like 'Log' }).MaxLogSize)
            MaxHistory = [int](($xml.Configuration.Client | Where-Object { $_.Name -like 'Log' }).MaxLogHistory)
            Enable     = Get-XmlBool (($xml.Configuration.Client | Where-Object { $_.Name -like 'Log' }).Enable)
        }
    }

    ClientInstallProperties = @($xml.Configuration.ClientInstallProperty)

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
