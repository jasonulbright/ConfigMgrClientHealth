<#
.SYNOPSIS
    Stops critical services and sets wuauserv to Disabled.
.DESCRIPTION
    Validates that ConfigMgrClientHealth detects and remediates:
    - Stopped BITS service
    - Stopped ccmexec service
    - Disabled wuauserv startup type
.NOTES
    Run on a LAB endpoint only. Set $env:YOURLAB = 'true' first.
#>
#Requires -RunAsAdministrator

if ($env:YOURLAB -ne 'true') {
    Write-Error "Safety check failed. Set `$env:YOURLAB = 'true' before running break scripts."
    exit 1
}

Write-Host '[Break-Services] Stopping BITS...' -ForegroundColor Yellow
Stop-Service -Name BITS -Force -ErrorAction SilentlyContinue

Write-Host '[Break-Services] Stopping ccmexec...' -ForegroundColor Yellow
Stop-Service -Name ccmexec -Force -ErrorAction SilentlyContinue

Write-Host '[Break-Services] Setting wuauserv startup to Disabled...' -ForegroundColor Yellow
Set-Service -Name wuauserv -StartupType Disabled -ErrorAction SilentlyContinue
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue

Write-Host '[Break-Services] Done. BITS=Stopped, ccmexec=Stopped, wuauserv=Disabled+Stopped' -ForegroundColor Red
