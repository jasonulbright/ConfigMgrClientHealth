<#
.SYNOPSIS
    Disables administrative shares (ADMIN$, C$) via registry.
.DESCRIPTION
    Validates that ConfigMgrClientHealth detects missing admin shares
    and re-enables them by restarting the Server service.
.NOTES
    Run on a LAB endpoint only. Set $env:YOURLAB = 'true' first.
    Requires a service restart to take effect, which the health script does.
#>
#Requires -RunAsAdministrator

if ($env:YOURLAB -ne 'true') {
    Write-Error "Safety check failed. Set `$env:YOURLAB = 'true' before running break scripts."
    exit 1
}

$regPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'

Write-Host '[Break-AdminShares] Disabling AutoShareWks (admin shares)...' -ForegroundColor Yellow
Set-ItemProperty -Path $regPath -Name 'AutoShareWks' -Value 0 -Type DWord -ErrorAction SilentlyContinue
# Also set server variant for Server OS
Set-ItemProperty -Path $regPath -Name 'AutoShareServer' -Value 0 -Type DWord -ErrorAction SilentlyContinue

Write-Host '[Break-AdminShares] Restarting LanmanServer to apply...' -ForegroundColor Yellow
Restart-Service -Name LanmanServer -Force

# Verify shares are gone
Start-Sleep -Seconds 2
$adminShare = Get-CimInstance -ClassName Win32_Share | Where-Object { $_.Name -eq 'ADMIN$' }
if ($adminShare) {
    Write-Host '[Break-AdminShares] Warning: ADMIN$ still present. May need a reboot.' -ForegroundColor Yellow
}
else {
    Write-Host '[Break-AdminShares] Done. Admin shares disabled' -ForegroundColor Red
}
