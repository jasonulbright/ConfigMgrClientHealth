<#
.SYNOPSIS
    Sets the ConfigMgr client cache to 1 MB.
.DESCRIPTION
    Validates that ConfigMgrClientHealth detects the undersized cache
    and sets it to the configured value.
.NOTES
    Run on a LAB endpoint only. Set $env:YOURLAB = 'true' first.
#>
#Requires -RunAsAdministrator

if ($env:YOURLAB -ne 'true') {
    Write-Error "Safety check failed. Set `$env:YOURLAB = 'true' before running break scripts."
    exit 1
}

try {
    $uiResource = New-Object -ComObject UIResource.UIResourceMgr
    $cache = $uiResource.GetCacheInfo()
    $currentSize = $cache.TotalSize
    Write-Host "[Break-CacheSize] Current cache size: ${currentSize} MB" -ForegroundColor Gray
    Write-Host '[Break-CacheSize] Setting cache size to 1 MB...' -ForegroundColor Yellow
    $cache.TotalSize = 1
    Write-Host '[Break-CacheSize] Done. Cache set to 1 MB' -ForegroundColor Red
}
catch {
    Write-Error "[Break-CacheSize] Failed: $_. Is the ConfigMgr client installed?"
}
