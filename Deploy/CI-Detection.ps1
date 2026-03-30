# Configuration Item Detection Script
# Returns $true (compliant) if ConfigMgr Client Health ran within the last 7 days.
# Returns $false (non-compliant) to trigger remediation.
#
# Usage: Create a CI in MECM with this as the Discovery script (PowerShell).
#        Data type: Boolean. Compliance rule: Value = True.

$RegPath = 'HKLM:\Software\ConfigMgrClientHealth'
$lastRun = (Get-ItemProperty -Path $RegPath -Name 'LastRun' -ErrorAction SilentlyContinue).LastRun

if ($null -eq $lastRun) { return $false }

try {
    $daysSince = (New-TimeSpan -Start ([datetime]$lastRun) -End (Get-Date)).TotalDays
    return ($daysSince -le 7)
}
catch { return $false }
