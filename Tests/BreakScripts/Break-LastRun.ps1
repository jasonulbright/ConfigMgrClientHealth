<#
.SYNOPSIS
    Deletes the ConfigMgrClientHealth LastRun registry value.
.DESCRIPTION
    Validates that the CI detection script returns non-compliant
    and triggers the CI remediation script to run the health check.
.NOTES
    Run on a LAB endpoint only. Set $env:YOURLAB = 'true' first.
#>
#Requires -RunAsAdministrator

if ($env:YOURLAB -ne 'true') {
    Write-Error "Safety check failed. Set `$env:YOURLAB = 'true' before running break scripts."
    exit 1
}

$regPath = 'HKLM:\Software\ConfigMgrClientHealth'

$current = (Get-ItemProperty -Path $regPath -Name 'LastRun' -ErrorAction SilentlyContinue).LastRun
if ($current) {
    Write-Host "[Break-LastRun] Current LastRun: $current" -ForegroundColor Gray
    Write-Host '[Break-LastRun] Removing LastRun value...' -ForegroundColor Yellow
    Remove-ItemProperty -Path $regPath -Name 'LastRun' -ErrorAction SilentlyContinue
    Write-Host '[Break-LastRun] Done. LastRun deleted -- CI detection will return non-compliant' -ForegroundColor Red
}
else {
    Write-Host '[Break-LastRun] LastRun already missing. Already in non-compliant state.' -ForegroundColor Yellow
}
