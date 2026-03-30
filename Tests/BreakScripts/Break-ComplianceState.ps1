<#
.SYNOPSIS
    Sets the last compliance state refresh to 60+ days ago.
.DESCRIPTION
    Validates that ConfigMgrClientHealth detects a stale compliance state
    and triggers a refresh.
.NOTES
    Run on a LAB endpoint only. Set $env:YOURLAB = 'true' first.
#>
#Requires -RunAsAdministrator

if ($env:YOURLAB -ne 'true') {
    Write-Error "Safety check failed. Set `$env:YOURLAB = 'true' before running break scripts."
    exit 1
}

$regPath = 'HKLM:\Software\ConfigMgrClientHealth'
$staleDate = (Get-Date).AddDays(-61).ToString('yyyy-MM-dd HH:mm:ss')

if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}

$current = (Get-ItemProperty -Path $regPath -Name 'LastComplianceStateSent' -ErrorAction SilentlyContinue).LastComplianceStateSent
Write-Host "[Break-ComplianceState] Current LastComplianceStateSent: $current" -ForegroundColor Gray

Write-Host "[Break-ComplianceState] Setting to: $staleDate" -ForegroundColor Yellow
Set-ItemProperty -Path $regPath -Name 'LastComplianceStateSent' -Value $staleDate -Type String

Write-Host '[Break-ComplianceState] Done. Compliance state is now 61 days stale' -ForegroundColor Red
