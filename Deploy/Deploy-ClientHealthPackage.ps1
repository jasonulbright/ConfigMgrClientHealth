<#
.SYNOPSIS
    Copies ConfigMgr Client Health files to the local ProgramData directory.

.DESCRIPTION
    Run this as a CM Package Program to stage the health check script and
    config locally. After staging, the Configuration Baseline CI-Remediation
    script runs the local copy without needing network access.

.EXAMPLE
    Deploy as CM Package with Program:
    powershell.exe -ExecutionPolicy Bypass -File Deploy-ClientHealthPackage.ps1
#>

$SourceDir = $PSScriptRoot
$TargetDir = Join-Path $env:ProgramData 'ConfigMgrClientHealth'

if (-not (Test-Path $TargetDir)) {
    New-Item -Path $TargetDir -ItemType Directory -Force | Out-Null
}

# Copy script and config
$filesToCopy = @(
    'ConfigMgrClientHealth.ps1',
    'config.json'
)

foreach ($file in $filesToCopy) {
    $src = Join-Path $SourceDir $file
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $TargetDir -Force
        Write-Output "Copied: $file"
    } else {
        Write-Warning "Source file not found: $src"
    }
}

Write-Output "Staged to: $TargetDir"
