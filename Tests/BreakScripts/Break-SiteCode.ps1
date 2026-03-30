<#
.SYNOPSIS
    Reassigns the ConfigMgr client to a wrong site code.
.DESCRIPTION
    Validates that ConfigMgrClientHealth detects the wrong site code
    and reassigns the client to the correct one from config.
.NOTES
    Run on a LAB endpoint only. Set $env:YOURLAB = 'true' first.
#>
#Requires -RunAsAdministrator

if ($env:YOURLAB -ne 'true') {
    Write-Error "Safety check failed. Set `$env:YOURLAB = 'true' before running break scripts."
    exit 1
}

$wrongSiteCode = 'ZZZ'

try {
    $client = New-Object -ComObject Microsoft.SMS.Client
    $currentSite = $client.GetAssignedSite()
    Write-Host "[Break-SiteCode] Current site code: $currentSite" -ForegroundColor Gray
    Write-Host "[Break-SiteCode] Setting site code to: $wrongSiteCode" -ForegroundColor Yellow
    $client.SetAssignedSite($wrongSiteCode)
    Write-Host "[Break-SiteCode] Done. Site code changed from $currentSite to $wrongSiteCode" -ForegroundColor Red
}
catch {
    Write-Error "[Break-SiteCode] Failed: $_. Is the ConfigMgr client installed?"
}
