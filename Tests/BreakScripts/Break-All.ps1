<#
.SYNOPSIS
    Runs all break scripts in sequence to create a fully broken client.
.DESCRIPTION
    After running this, execute ConfigMgrClientHealth.ps1 and verify
    that every issue is detected and remediated. Use Get-HealthState.ps1
    before and after to compare.
.NOTES
    Run on a LAB endpoint only. Set $env:YOURLAB = 'true' first.
#>
#Requires -RunAsAdministrator

if ($env:YOURLAB -ne 'true') {
    Write-Error "Safety check failed. Set `$env:YOURLAB = 'true' before running break scripts."
    exit 1
}

$scriptDir = $PSScriptRoot

Write-Host ''
Write-Host '=============================================' -ForegroundColor Red
Write-Host '  BREAKING EVERYTHING -- LAB USE ONLY' -ForegroundColor Red
Write-Host '=============================================' -ForegroundColor Red
Write-Host ''

$scripts = @(
    'Break-Services.ps1',
    'Break-SiteCode.ps1',
    'Break-CacheSize.ps1',
    'Break-LogSize.ps1',
    'Break-ProvisioningMode.ps1',
    'Break-AdminShares.ps1',
    'Break-HWInventory.ps1',
    'Break-WUAHandler.ps1',
    'Break-ComplianceState.ps1',
    'Break-LastRun.ps1'
)

foreach ($script in $scripts) {
    $path = Join-Path $scriptDir $script
    if (Test-Path $path) {
        Write-Host ''
        Write-Host "--- Running $script ---" -ForegroundColor Magenta
        & $path
    }
    else {
        Write-Warning "Script not found: $path"
    }
}

Write-Host ''
Write-Host '=============================================' -ForegroundColor Red
Write-Host '  ALL BREAKS APPLIED' -ForegroundColor Red
Write-Host '=============================================' -ForegroundColor Red
Write-Host ''
Write-Host '  Next steps:' -ForegroundColor Cyan
Write-Host '    1. Run Get-HealthState.ps1 to confirm everything is broken'
Write-Host '    2. Run ConfigMgrClientHealth.ps1 -Config config.json -Verbose'
Write-Host '    3. Run Get-HealthState.ps1 again to verify remediation'
Write-Host ''
