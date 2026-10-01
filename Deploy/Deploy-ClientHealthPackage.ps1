<#
.SYNOPSIS
    Copies ConfigMgr Client Health files to the local ProgramData directory.

.DESCRIPTION
    Run this as a CM Package Program to stage the health check script and
    config locally. After staging, the Configuration Baseline CI-Remediation
    script runs the local copy without needing network access.

    The staging folder is restricted to SYSTEM and Administrators, because the
    CI remediation runs the staged script as SYSTEM.

.EXAMPLE
    Deploy as CM Package with Program:
    powershell.exe -ExecutionPolicy Bypass -File Deploy-ClientHealthPackage.ps1
#>

# Test-TrustedDirectory, Remove-PathNoFollow and Initialize-SecureDirectory are identical copies of the
# functions in ConfigMgrClientHealth.ps1. Tests\ClientHealthBehavior.Tests.ps1 fails when they differ.

Function Test-TrustedDirectory {
    Param([Parameter(Mandatory=$true)][string]$Path)

    $trustedSids = @('S-1-5-18', 'S-1-5-32-544')
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $false }
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if ($trustedSids -notcontains $owner) { return $false }
        if (-not $acl.AreAccessRulesProtected) { return $false }
        foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -ne 'Allow') { continue }
            if ($trustedSids -notcontains $rule.IdentityReference.Value) { return $false }
        }
        return $true
    }
    catch { return $false }
}

Function Remove-PathNoFollow {
    Param([Parameter(Mandatory=$true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $isReparsePoint = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    if ($item.PSIsContainer) {
        if (-not $isReparsePoint) {
            foreach ($child in [System.IO.Directory]::GetFileSystemEntries($Path)) { Remove-PathNoFollow -Path $child }
        }
        [System.IO.Directory]::Delete($Path, $false)
    }
    else {
        [System.IO.File]::SetAttributes($Path, [System.IO.FileAttributes]::Normal)
        [System.IO.File]::Delete($Path)
    }
}

Function Initialize-SecureDirectory {
    Param([Parameter(Mandatory=$true)][string]$Path)

    $trustedSids = @('S-1-5-18', 'S-1-5-32-544')
    try {
        if (-not (Test-TrustedDirectory -Path $Path)) {
            if (Test-Path -LiteralPath $Path) {
                $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
                $owner = (Get-Acl -LiteralPath $Path -ErrorAction Stop).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or ($trustedSids -notcontains $owner)) {
                    $quarantine = "$Path.untrusted-$([guid]::NewGuid().ToString('N'))"
                    [System.IO.Directory]::Move($Path, $quarantine)
                    Write-Warning "Untrusted folder '$Path' was renamed to '$quarantine'."
                }
            }
            if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null }

            $acl = New-Object System.Security.AccessControl.DirectorySecurity
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($sid in $trustedSids) {
                $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
                $acl.AddAccessRule($rule)
            }
            Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop

            # An administrator whose default owner policy is "object creator" owns a new folder personally.
            $currentOwner = (Get-Acl -LiteralPath $Path -ErrorAction Stop).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
            if ($trustedSids -notcontains $currentOwner) {
                $ownerAcl = Get-Acl -LiteralPath $Path -ErrorAction Stop
                $ownerAcl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
                Set-Acl -LiteralPath $Path -AclObject $ownerAcl -ErrorAction Stop
            }
        }

        # A trusted folder can still hold an item that another account owns. Copy-Item -Force keeps the
        # owner and ACL of a file it overwrites, so a redeploy alone does not restore trust.
        $pending =New-Object System.Collections.Generic.Queue[string]
        $pending.Enqueue($Path)
        while ($pending.Count -gt 0) {
            foreach ($entry in [System.IO.Directory]::GetFileSystemEntries($pending.Dequeue())) {
                $child = Get-Item -LiteralPath $entry -Force -ErrorAction Stop
                $childOwner = (Get-Acl -LiteralPath $entry -ErrorAction Stop).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
                if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or ($trustedSids -notcontains $childOwner)) {
                    Write-Warning "Removing untrusted item '$entry'."
                    Remove-PathNoFollow -Path $entry
                }
                elseif ($child.PSIsContainer) { $pending.Enqueue($entry) }
            }
        }
    }
    catch {
        Write-Warning "Could not secure folder '$Path': $($_.Exception.Message)"
        return $false
    }
    return (Test-TrustedDirectory -Path $Path)
}

$SourceDir = $PSScriptRoot
$TargetDir = Join-Path $env:ProgramData 'ConfigMgrClientHealth'

$filesToCopy = @(
    'ConfigMgrClientHealth.ps1',
    'config.json'
)

# Check every source first: staging a new script with an old config is worse than staging nothing.
$missing = @($filesToCopy | Where-Object { -not (Test-Path -LiteralPath (Join-Path $SourceDir $_)) })
if ($missing.Count -gt 0) {
    foreach ($file in $missing) { Write-Error "Source file not found: $(Join-Path $SourceDir $file)" }
    exit 1
}

if (-not (Initialize-SecureDirectory -Path $TargetDir)) {
    Write-Error "Could not create a protected staging folder at $TargetDir."
    exit 1
}

$failed = $false
foreach ($file in $filesToCopy) {
    $src = Join-Path $SourceDir $file
    try {
        Copy-Item -LiteralPath $src -Destination $TargetDir -Force -ErrorAction Stop
        Write-Output "Copied: $file"
    }
    catch {
        Write-Error "Failed to copy ${file}: $($_.Exception.Message)"
        $failed = $true
    }
}

if ($failed) { exit 1 }
Write-Output "Staged to: $TargetDir"
exit 0