<#
.SYNOPSIS
    Read-only snapshot of current client health state.
.DESCRIPTION
    Checks every item the break scripts target and reports current state.
    Run before and after breaking things to compare.
.NOTES
    Safe to run anywhere -- makes no changes.
#>
#Requires -RunAsAdministrator

function Write-State {
    param([string]$Label, [string]$Value, [string]$Status = 'Info')
    $color = switch ($Status) {
        'OK'    { 'Green' }
        'Bad'   { 'Red' }
        'Warn'  { 'Yellow' }
        default { 'Gray' }
    }
    Write-Host ("  {0,-30} {1}" -f $Label, $Value) -ForegroundColor $color
}

Write-Host ''
Write-Host '=== ConfigMgr Client Health State ===' -ForegroundColor Cyan
Write-Host ''

# Services
Write-Host '-- Services --' -ForegroundColor White
foreach ($svcName in @('BITS', 'ccmexec', 'wuauserv', 'winmgmt', 'lanmanserver', 'W32Time')) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($svc) {
        $startup = (Get-CimInstance -ClassName Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue).StartMode
        $status = if ($svc.Status -eq 'Running') { 'OK' } else { 'Bad' }
        Write-State $svcName "$($svc.Status) ($startup)" $status
    }
    else {
        Write-State $svcName 'Not found' 'Warn'
    }
}

# Site code
Write-Host '-- Client Configuration --' -ForegroundColor White
try {
    $client = New-Object -ComObject Microsoft.SMS.Client
    Write-State 'Site Code' $client.GetAssignedSite() 'Info'
}
catch { Write-State 'Site Code' 'Cannot read (client not installed?)' 'Bad' }

# Cache size
try {
    $uiResource = New-Object -ComObject UIResource.UIResourceMgr
    $cache = $uiResource.GetCacheInfo()
    $cacheStatus = if ($cache.TotalSize -ge 1024) { 'OK' } else { 'Bad' }
    Write-State 'Cache Size' "$($cache.TotalSize) MB" $cacheStatus
}
catch { Write-State 'Cache Size' 'Cannot read' 'Warn' }

# Log settings
$logRegPath = 'HKLM:\SOFTWARE\Microsoft\CCM\Logging\@GLOBAL'
if (Test-Path $logRegPath) {
    $logSize = (Get-ItemProperty -Path $logRegPath -Name 'LogMaxSize' -ErrorAction SilentlyContinue).LogMaxSize
    $logHistory = (Get-ItemProperty -Path $logRegPath -Name 'LogMaxHistory' -ErrorAction SilentlyContinue).LogMaxHistory
    $logStatus = if ($logSize -ge 1024) { 'OK' } else { 'Bad' }
    Write-State 'Log MaxSize' "$logSize KB" $logStatus
    Write-State 'Log MaxHistory' $logHistory $(if ($logHistory -ge 1) { 'OK' } else { 'Bad' })
}
else { Write-State 'Log Settings' 'Registry path not found' 'Warn' }

# Provisioning mode
$provRegPath = 'HKLM:\SOFTWARE\Microsoft\CCM\CcmExec'
if (Test-Path $provRegPath) {
    $provMode = (Get-ItemProperty -Path $provRegPath -Name 'ProvisioningMode' -ErrorAction SilentlyContinue).ProvisioningMode
    $provStatus = if ($provMode -eq 'true') { 'Bad' } else { 'OK' }
    Write-State 'Provisioning Mode' $provMode $provStatus
}
else { Write-State 'Provisioning Mode' 'Registry path not found' 'Warn' }

# Admin shares
Write-Host '-- Shares --' -ForegroundColor White
$adminShare = Get-CimInstance -ClassName Win32_Share -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'ADMIN$' }
$cShare = Get-CimInstance -ClassName Win32_Share -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'C$' }
Write-State 'ADMIN$' $(if ($adminShare) { 'Present' } else { 'Missing' }) $(if ($adminShare) { 'OK' } else { 'Bad' })
Write-State 'C$' $(if ($cShare) { 'Present' } else { 'Missing' }) $(if ($cShare) { 'OK' } else { 'Bad' })

# HW Inventory
Write-Host '-- Inventory & Compliance --' -ForegroundColor White
try {
    $hwInv = Get-CimInstance -Namespace 'root\ccm\invagt' -ClassName 'InventoryActionStatus' -ErrorAction Stop |
        Where-Object { $_.InventoryActionID -eq '{00000000-0000-0000-0000-000000000001}' }
    if ($hwInv) {
        $daysSince = (New-TimeSpan -Start $hwInv.LastCycleStartedDate -End (Get-Date)).TotalDays
        $invStatus = if ($daysSince -le 10) { 'OK' } else { 'Bad' }
        Write-State 'HW Inventory' "$([math]::Round($daysSince,1)) days ago" $invStatus
    }
    else { Write-State 'HW Inventory' 'No record' 'Bad' }
}
catch { Write-State 'HW Inventory' 'Cannot query WMI' 'Warn' }

# Compliance state
$chRegPath = 'HKLM:\Software\ConfigMgrClientHealth'
$lastCompliance = (Get-ItemProperty -Path $chRegPath -Name 'LastComplianceStateSent' -ErrorAction SilentlyContinue).LastComplianceStateSent
if ($lastCompliance) {
    $compDays = (New-TimeSpan -Start ([datetime]$lastCompliance) -End (Get-Date)).TotalDays
    $compStatus = if ($compDays -le 30) { 'OK' } else { 'Bad' }
    Write-State 'Compliance State' "$([math]::Round($compDays,1)) days ago" $compStatus
}
else { Write-State 'Compliance State' 'Never sent' 'Warn' }

# LastRun
$lastRun = (Get-ItemProperty -Path $chRegPath -Name 'LastRun' -ErrorAction SilentlyContinue).LastRun
if ($lastRun) {
    $runDays = (New-TimeSpan -Start ([datetime]$lastRun) -End (Get-Date)).TotalDays
    $runStatus = if ($runDays -le 7) { 'OK' } else { 'Bad' }
    Write-State 'LastRun' "$lastRun ($([math]::Round($runDays,1)) days ago)" $runStatus
}
else { Write-State 'LastRun' 'Never run / deleted' 'Bad' }

# registry.pol
Write-Host '-- GPO --' -ForegroundColor White
$registryPol = "$env:windir\System32\GroupPolicy\Machine\registry.pol"
if (Test-Path $registryPol) {
    $polFile = Get-Item $registryPol
    $polAge = (New-TimeSpan -Start $polFile.LastWriteTime -End (Get-Date)).TotalDays
    $polStatus = if ($polFile.Length -gt 0 -and $polAge -le 30) { 'OK' } else { 'Bad' }
    Write-State 'registry.pol' "$($polFile.Length) bytes, $([math]::Round($polAge,1)) days old" $polStatus
}
else { Write-State 'registry.pol' 'Not found' 'Warn' }

# WMI
Write-Host '-- WMI --' -ForegroundColor White
try {
    $wmiResult = & winmgmt /verifyrepository 2>&1
    $wmiStatus = if ($wmiResult -match 'consistent') { 'OK' } else { 'Bad' }
    Write-State 'WMI Repository' ($wmiResult -join ' ').Trim() $wmiStatus
}
catch { Write-State 'WMI Repository' 'Cannot verify' 'Warn' }

Write-Host ''
Write-Host '=== End ===' -ForegroundColor Cyan
Write-Host ''
