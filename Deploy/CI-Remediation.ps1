# Configuration Item Remediation Script
# Invokes ConfigMgr Client Health from the locally cached copy.
#
# Prerequisites:
#   1. Deploy the script + config.json to %ProgramData%\ConfigMgrClientHealth\ via CM Package
#   2. Create a CI with CI-Detection.ps1 as Discovery and this script as Remediation
#   3. Create a Baseline, add the CI, deploy to All Systems
#
# The script caches config.json locally after first successful network load,
# so subsequent runs work even if the network config path is unreachable.

$ScriptDir = Join-Path $env:ProgramData 'ConfigMgrClientHealth'
$ScriptPath = Join-Path $ScriptDir 'ConfigMgrClientHealth.ps1'
$ConfigPath = Join-Path $ScriptDir 'config.json'

if (-not (Test-Path $ScriptPath)) {
    Write-Error "ConfigMgrClientHealth.ps1 not found at $ScriptPath. Deploy the package first."
    exit 1
}

if (-not (Test-Path $ConfigPath)) {
    Write-Error "config.json not found at $ConfigPath. Deploy the package first."
    exit 1
}

try {
    & $ScriptPath -Config $ConfigPath
}
catch {
    Write-Error "ConfigMgr Client Health failed: $_"
    exit 1
}
