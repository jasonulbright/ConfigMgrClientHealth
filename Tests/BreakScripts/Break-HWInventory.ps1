<#
.SYNOPSIS
    Deletes the last hardware inventory timestamp from WMI.
.DESCRIPTION
    Validates that ConfigMgrClientHealth detects stale hardware inventory
    and triggers a new inventory scan.
.NOTES
    Run on a LAB endpoint only. Set $env:YOURLAB = 'true' first.
#>
#Requires -RunAsAdministrator

if ($env:YOURLAB -ne 'true') {
    Write-Error "Safety check failed. Set `$env:YOURLAB = 'true' before running break scripts."
    exit 1
}

try {
    $hwInv = Get-CimInstance -Namespace 'root\ccm\invagt' -ClassName 'InventoryActionStatus' |
        Where-Object { $_.InventoryActionID -eq '{00000000-0000-0000-0000-000000000001}' }

    if ($hwInv) {
        $lastRun = $hwInv.LastCycleStartedDate
        Write-Host "[Break-HWInventory] Current last HW inventory: $lastRun" -ForegroundColor Gray
        Write-Host '[Break-HWInventory] Removing HW inventory status record...' -ForegroundColor Yellow
        $hwInv | Remove-CimInstance
        Write-Host '[Break-HWInventory] Done. HW inventory timestamp deleted' -ForegroundColor Red
    }
    else {
        Write-Host '[Break-HWInventory] No HW inventory record found. Already in a broken state.' -ForegroundColor Yellow
    }
}
catch {
    Write-Error "[Break-HWInventory] Failed: $_. Is the ConfigMgr client installed?"
}
