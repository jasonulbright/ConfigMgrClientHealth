<#
.SYNOPSIS
    Corrupts registry.pol with a zero-byte file.
.DESCRIPTION
    Validates that ConfigMgrClientHealth detects a corrupt/stale
    registry.pol and repairs it via gpupdate.
.NOTES
    Run on a LAB endpoint only. Set $env:YOURLAB = 'true' first.
#>
#Requires -RunAsAdministrator

if ($env:YOURLAB -ne 'true') {
    Write-Error "Safety check failed. Set `$env:YOURLAB = 'true' before running break scripts."
    exit 1
}

$registryPol = "$env:windir\System32\GroupPolicy\Machine\registry.pol"

if (Test-Path $registryPol) {
    $originalSize = (Get-Item $registryPol).Length
    Write-Host "[Break-WUAHandler] Current registry.pol size: $originalSize bytes" -ForegroundColor Gray
}

Write-Host '[Break-WUAHandler] Overwriting registry.pol with zero-byte file...' -ForegroundColor Yellow
$dir = Split-Path $registryPol -Parent
if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
[System.IO.File]::WriteAllBytes($registryPol, [byte[]]@())

# Backdate the file to trigger the age check
$staleDate = (Get-Date).AddDays(-60)
(Get-Item $registryPol).LastWriteTime = $staleDate

Write-Host "[Break-WUAHandler] Done. registry.pol is now 0 bytes, dated $($staleDate.ToString('yyyy-MM-dd'))" -ForegroundColor Red
