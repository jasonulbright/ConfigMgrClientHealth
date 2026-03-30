<#
.SYNOPSIS
    Puts the ConfigMgr client into provisioning mode.
.DESCRIPTION
    Validates that ConfigMgrClientHealth detects the client is stuck
    in provisioning mode and exits it.
.NOTES
    Run on a LAB endpoint only. Set $env:YOURLAB = 'true' first.
#>
#Requires -RunAsAdministrator

if ($env:YOURLAB -ne 'true') {
    Write-Error "Safety check failed. Set `$env:YOURLAB = 'true' before running break scripts."
    exit 1
}

$regPath = 'HKLM:\SOFTWARE\Microsoft\CCM\CcmExec'

if (-not (Test-Path $regPath)) {
    Write-Error "[Break-ProvisioningMode] Registry path not found: $regPath. Is the ConfigMgr client installed?"
    exit 1
}

$current = (Get-ItemProperty -Path $regPath -Name 'ProvisioningMode' -ErrorAction SilentlyContinue).ProvisioningMode
Write-Host "[Break-ProvisioningMode] Current ProvisioningMode: $current" -ForegroundColor Gray

Write-Host '[Break-ProvisioningMode] Enabling provisioning mode...' -ForegroundColor Yellow
Set-ItemProperty -Path $regPath -Name 'ProvisioningMode' -Value 'true' -Type String

Write-Host '[Break-ProvisioningMode] Done. Client is now in provisioning mode' -ForegroundColor Red
