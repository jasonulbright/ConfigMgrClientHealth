# Configuration Item Remediation Script
# Starts ConfigMgr Client Health from the locally cached copy in the scheduled task
# 'ConfigMgr Client Health' (SYSTEM) and returns without waiting for the run.
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

# This script runs as SYSTEM. A standard user can create folders under ProgramData, so the
# staged folder and files must be owned by SYSTEM or Administrators and must not be reparse points.
function Test-TrustedOwner {
    param([string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $false }
        $owner = (Get-Acl -LiteralPath $Path -ErrorAction Stop).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        return (@('S-1-5-18', 'S-1-5-32-544') -contains $owner)
    }
    catch { return $false }
}

if (-not (Test-Path $ScriptPath)) {
    Write-Error "ConfigMgrClientHealth.ps1 not found at $ScriptPath. Deploy the package first."
    exit 1
}

if (-not (Test-Path $ConfigPath)) {
    Write-Error "config.json not found at $ConfigPath. Deploy the package first."
    exit 1
}

foreach ($path in @($ScriptDir, $ScriptPath, $ConfigPath)) {
    if (-not (Test-TrustedOwner -Path $path)) {
        Write-Error "$path is not owned by SYSTEM or Administrators. Refusing to run. Redeploy the package."
        exit 1
    }
}

# The client stops a compliance script after ScriptExecutionTimeout (60 s by default, 600 s at most).
# A health run, and any client reinstall, takes longer, so the run happens in a scheduled task
# and this script returns at once. Detection reports compliance after the task updates LastRun.
$taskName = 'ConfigMgr Client Health'
try {
    $existing = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($existing -and $existing.State -eq 'Running') {
        Write-Output "$taskName is already running."
        exit 0
    }

    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $powershell -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Config `"$ConfigPath`""
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName -TaskPath '\'
    Write-Output "$taskName started."
    exit 0
}
catch {
    Write-Error "Could not start ConfigMgr Client Health: $_"
    exit 1
}
