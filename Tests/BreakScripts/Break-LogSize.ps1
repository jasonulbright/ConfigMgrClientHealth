<#
.SYNOPSIS
    Sets CCM log max size to 100 KB and history to 0.
.DESCRIPTION
    Validates that ConfigMgrClientHealth detects wrong log settings
    and corrects them to the configured values.
.NOTES
    Run on a LAB endpoint only. Set $env:YOURLAB = 'true' first.
#>
#Requires -RunAsAdministrator

if ($env:YOURLAB -ne 'true') {
    Write-Error "Safety check failed. Set `$env:YOURLAB = 'true' before running break scripts."
    exit 1
}

$regPath = 'HKLM:\SOFTWARE\Microsoft\CCM\Logging\@GLOBAL'

if (-not (Test-Path $regPath)) {
    Write-Error "[Break-LogSize] Registry path not found: $regPath. Is the ConfigMgr client installed?"
    exit 1
}

$currentSize = (Get-ItemProperty -Path $regPath -Name 'LogMaxSize' -ErrorAction SilentlyContinue).LogMaxSize
$currentHistory = (Get-ItemProperty -Path $regPath -Name 'LogMaxHistory' -ErrorAction SilentlyContinue).LogMaxHistory
Write-Host "[Break-LogSize] Current: LogMaxSize=$currentSize, LogMaxHistory=$currentHistory" -ForegroundColor Gray

Write-Host '[Break-LogSize] Setting LogMaxSize=100, LogMaxHistory=0...' -ForegroundColor Yellow
Set-ItemProperty -Path $regPath -Name 'LogMaxSize' -Value 100 -Type DWord
Set-ItemProperty -Path $regPath -Name 'LogMaxHistory' -Value 0 -Type DWord

Write-Host '[Break-LogSize] Done. Log size=100 KB, history=0' -ForegroundColor Red
