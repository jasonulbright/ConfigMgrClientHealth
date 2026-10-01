<#
.SYNOPSIS
    Deletes the administrative shares (ADMIN$, C$) until the next Server service start.
.DESCRIPTION
    Validates that ConfigMgrClientHealth detects missing admin shares
    and restores them by restarting the Server service.
.NOTES
    Run on a LAB endpoint only. Set $env:YOURLAB = 'true' first.
    Setting AutoShareWks/AutoShareServer to 0 is a policy choice, not a fault. The health script
    reports that state as 'Disabled' and does not change it, so this script does not use it.
#>
#Requires -RunAsAdministrator

if ($env:YOURLAB -ne 'true') {
    Write-Error "Safety check failed. Set `$env:YOURLAB = 'true' before running break scripts."
    exit 1
}

$systemShare = ($env:SystemDrive.TrimEnd(':')) + '$'
foreach ($share in @('ADMIN$', $systemShare)) {
    Write-Host "[Break-AdminShares] Deleting share $share..." -ForegroundColor Yellow
    & net.exe share $share /delete /y 2>&1 | Out-Null
}

# Verify shares are gone
$remaining = @(Get-CimInstance -ClassName Win32_Share | Where-Object { $_.Name -in @('ADMIN$', $systemShare) })
if ($remaining.Count -gt 0) {
    Write-Host "[Break-AdminShares] Warning: still present: $($remaining.Name -join ', ')" -ForegroundColor Yellow
}
else {
    Write-Host '[Break-AdminShares] Done. Admin shares deleted' -ForegroundColor Red
}
