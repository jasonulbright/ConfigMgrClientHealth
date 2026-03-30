# ConfigMgr Client Health (Community Fork)

Automated detection and remediation of common MECM/ConfigMgr client health issues. Runs as a scheduled task or Configuration Baseline on managed Windows devices, validates 35+ health checks, remediates problems automatically, and logs results to SQL Server.

**This is a maintained community fork** of [AndersRodland/ConfigMgrClientHealth](https://github.com/AndersRodland/ConfigMgrClientHealth) (v0.8.3, abandoned 2023). The original tool is widely deployed in production MECM environments but had unpatched security vulnerabilities and used deprecated WMI APIs.

## What This Fork Changes

### Security (Critical)
- **SQL injection eliminated** -- `Update-SQL` rewritten with parameterized queries (`SqlParameter` objects). The original built 39-column UPSERT queries via string concatenation.
- **Command injection eliminated** -- All `Invoke-Expression` calls replaced with `Start-Process -ArgumentList` arrays for ccmsetup.exe and `& operator` for sc.exe.
- **Config input validation** -- Service names, site codes, and domains validated against regex patterns before use in WMI filters.

### Modernization
- **Full CIM migration** -- All 55 `Get-WmiObject` calls replaced with `Get-CimInstance`. All `Invoke-WmiMethod` replaced with `Invoke-CimMethod`. PowerShell version branching removed (CIM works on PS 5.1+).
- **JSON configuration** -- New `config.json` format alongside backward-compatible XML support. Cleaner structure, native boolean/integer types, array-based install properties.
- **Site-aware configuration** -- Per-site overrides for SQL Server, client share, and log share via AD site detection. Supports 300+ site deployments without hardcoded server names.
- **Config caching** -- Caches last-known-good config locally. VPN/ZPA clients continue operating when the network config path is unreachable.

### Reliability
- **Retry logic** -- SQL writes use `Invoke-WithRetry` (3 attempts, 5-second delay) for transient failures.
- **No silent failures** -- All empty `catch{}` blocks replaced with `Write-Verbose` or `Write-Warning` logging.
- **Consolidated trigger functions** -- 5 separate schedule trigger functions merged into single `Invoke-CCMTrigger`.

### Tests
- **77 Pester tests** covering security, CIM migration, error handling, JSON config, site-aware resolution, config caching, and SQL schema alignment.

## Requirements

| Component | Version |
|-----------|---------|
| PowerShell | 5.1+ (Windows PowerShell) |
| OS | Windows 10 / Server 2016+ |
| ConfigMgr Client | Any supported version |
| SQL Server | 2016+ (for database logging) |
| Permissions | Local Administrator or SYSTEM |

## Quick Start

### 1. Create the Database

Run `CreateDatabase.sql` on your SQL Server instance. Grant the computer accounts `db_datareader` and `db_datawriter` on the `ClientHealth` database:

```sql
USE ClientHealth
CREATE USER [DOMAIN\Domain Computers] FOR LOGIN [DOMAIN\Domain Computers]
ALTER ROLE db_datareader ADD MEMBER [DOMAIN\Domain Computers]
ALTER ROLE db_datawriter ADD MEMBER [DOMAIN\Domain Computers]
```

### 2. Configure

Copy `config.json` and edit for your environment:

```json
{
    "Client": {
        "Version": "5.00.9012.1010",
        "SiteCode": "PS1",
        "Domain": "contoso.com",
        "Share": "\\\\sccm01\\ClientHealth$\\Client"
    },
    "ClientInstallProperties": [
        "SMSSITECODE=PS1",
        "MP=sccm01.contoso.com",
        "/Source:\\\\sccm01\\ClientHealth$\\Client"
    ],
    "Logging": {
        "SQL": { "Server": "sccm01.contoso.com", "Enabled": true }
    },
    "Sites": {
        "NYC-Office":  { "SQLServer": "sql-nyc01", "ClientShare": "\\\\dp-nyc01\\ClientHealth$\\Client" },
        "LAX-Office":  { "SQLServer": "sql-lax01" },
        "Default":     { "SQLServer": "sql-hq01.contoso.com" }
    }
}
```

The `Sites` section is optional. If present, the script detects the client's AD site and uses site-specific overrides for SQL Server, client share, and log share. The `Default` entry catches VPN/ZPA clients.

### 3. Run

```powershell
.\ConfigMgrClientHealth.ps1 -Config .\config.json
```

Or with XML config (backward compatible):
```powershell
.\ConfigMgrClientHealth.ps1 -Config .\config.xml
```

## Deployment at Scale

### Option A: Configuration Baseline (Recommended)

Deploy via MECM Configuration Baseline for automatic compliance evaluation and remediation.

**CI Detection Script** (checks if health script ran within 7 days):
```powershell
$lastRun = (Get-ItemProperty -Path 'HKLM:\Software\ConfigMgrClientHealth' -Name 'LastRun' -ErrorAction SilentlyContinue).LastRun
if ($null -eq $lastRun) { return $false }
return ((New-TimeSpan -Start ([datetime]$lastRun) -End (Get-Date)).TotalDays -le 7)
```

**CI Remediation Script**:
```powershell
& "$env:ProgramData\ConfigMgrClientHealth\ConfigMgrClientHealth.ps1" -Config "$env:ProgramData\ConfigMgrClientHealth\config.json"
```

**Setup:**
1. Create a Package with the script + config.json as source
2. Distribute to all DP groups
3. Create a Program that copies the package to `%ProgramData%\ConfigMgrClientHealth\`
4. Create a Configuration Item with the detection and remediation scripts above
5. Create a Configuration Baseline, add the CI, deploy to All Systems

### Option B: Package + Scheduled Task

1. Create a Package with source files (script + config.json)
2. Program: `powershell.exe -ExecutionPolicy Bypass -File ConfigMgrClientHealth.ps1 -Config config.json`
3. Deploy as Required to All Systems on a weekly schedule

### Option C: Scheduled Task via GPO

Create a scheduled task that runs weekly as SYSTEM:
```
powershell.exe -ExecutionPolicy Bypass -File "\\server\ClientHealth$\ConfigMgrClientHealth.ps1" -Config "\\server\ClientHealth$\config.json"
```

Note: Options B and C require network access to the script/config share at runtime. Option A caches locally and works offline via config caching.

## Configuration Reference

### config.json

| Section | Key | Type | Description |
|---------|-----|------|-------------|
| `LocalFiles` | | string | Local temp directory (default: `C:\ClientHealth`) |
| `Client.Version` | | string | Minimum required ConfigMgr agent version |
| `Client.SiteCode` | | string | Target site code (3 chars) |
| `Client.Domain` | | string | Expected AD domain |
| `Client.AutoUpgrade` | | bool | Auto-upgrade agent if below minimum version |
| `Client.Share` | | string | UNC path to ccmsetup.exe source files |
| `Client.Cache.Size` | | int | Cache size in MB |
| `Client.Cache.DeleteOrphanedData` | | bool | Remove orphaned cache packages |
| `Client.Log.MaxSize` | | int | Max log file size in KB |
| `Client.Log.MaxHistory` | | int | Number of log rotations to keep |
| `ClientInstallProperties` | | array | ccmsetup.exe parameters |
| `Logging.Share` | | string | UNC path for network log files |
| `Logging.Level` | | string | `Full` or `ClientInstall` |
| `Logging.LocalLogFile` | | bool | Keep local log copy |
| `Logging.FileEnabled` | | bool | Enable network file logging |
| `Logging.TimeFormat` | | string | `ClientLocal` or `UTC` |
| `Logging.SQL.Server` | | string | SQL Server instance |
| `Logging.SQL.Enabled` | | bool | Enable SQL database logging |
| `Options.*` | | various | Health check toggles (Enable/Fix/Days) |
| `Services` | | array | Services to monitor (Name, StartupType, State, Uptime) |
| `Remediation.*` | | various | Remediation action toggles |
| `Sites.*` | | object | Per-site overrides (SQLServer, ClientShare, LogShare) |

### Site-Aware Configuration

The script detects the client's AD site via `Win32_NTDomain` and resolves configuration overrides:

1. Check `Sites.<ADSiteName>` for site-specific values
2. Fall back to `Sites.Default`
3. Fall back to top-level config values

Supported site override properties: `SQLServer`, `ClientShare`, `LogShare`

## Health Checks

| Check | Remediation | Config Key |
|-------|-------------|------------|
| ConfigMgr client installed | Install/reinstall via ccmsetup.exe | `Client.Version`, `Client.AutoUpgrade` |
| Client version | Upgrade to minimum version | `Client.Version` |
| Client site code | Reassign via COM | `Client.SiteCode` |
| Client cache size | Set via COM | `Client.Cache.Size` |
| Client log size | Set via registry | `Client.Log.MaxSize` |
| Provisioning mode | Exit via registry + WMI method | `Remediation.ClientProvisioningMode` |
| Client certificate | Reinstall client | `Remediation.ClientCertificate` |
| WMI repository | Rebuild repository | `Options.WMI` |
| BITS service | Reset DACL, remove bad jobs | `Options.BITSCheck` |
| DNS resolution | Re-register DNS | `Options.DNSCheck` |
| Admin shares (C$, ADMIN$) | Re-enable via registry | `Remediation.AdminShare` |
| Hardware inventory | Trigger if stale | `Options.HardwareInventory` |
| Software metering | Fix PrepDriver errors | `Options.SoftwareMetering` |
| Pending reboot | Detect and optionally force | `Options.PendingReboot` |
| State messages | Refresh compliance state | `Remediation.ClientStateMessages` |
| WUA handler | Fix registry.pol, gpupdate | `Remediation.ClientWUAHandler` |
| OS disk free space | Report only | `Options.OSDiskFreeSpace` |
| Missing drivers | Report faulty PnP devices | `Options.Drivers` |
| Windows updates | Install from share | `Options.Updates` |
| Service state | Start/configure services | `Services` array |
| Compliance state | Resend at interval | `Options.RefreshComplianceState` |
| Client settings | Remove orphaned policies | `Options.ClientSettingsCheck` |
| Patch level | Report UBR | `Options.PatchLevel` |

## Migrating from XML to JSON

If you have an existing `config.xml` deployment, the script accepts both formats — no immediate migration required. To convert:

1. Create a `config.json` based on the template in this repo
2. Map your XML values to the JSON structure (see Configuration Reference)
3. Test with `-Config config.json -Verbose`
4. Deploy the new config alongside the script
5. The script caches JSON configs locally, so VPN clients will work offline after first run

## SQL Database

The script logs to a `ClientHealth` database with a single `Clients` table (39 columns). Schema is created by `CreateDatabase.sql`. The table uses `Hostname` as the primary key and performs an UPSERT (update if exists, insert if new) on each run.

All SQL writes use parameterized queries — no string concatenation, no injection risk.

## Tests

77 Pester tests validate:
- Script parses without errors
- No `Invoke-Expression` usage
- Parameterized SQL (no string concatenation)
- Config input validation exists
- No `Get-WmiObject` / `Invoke-WmiMethod` / `[wmiclass]` in executable code
- No empty catch blocks
- JSON config schema integrity
- Backward XML/JSON compatibility
- Site-aware config resolution
- Config caching mechanism
- SQL schema alignment with Update-SQL parameters

```powershell
Invoke-Pester .\Tests\ -Output Detailed
```

## License

This project is licensed under the [Creative Commons Attribution-NoDerivatives 4.0](https://creativecommons.org/licenses/by-nd/4.0/) license, inherited from the original project by Anders Rodland.

## Credits

- **Anders Rodland** -- Original author ([andersrodland.com](https://www.andersrodland.com))
- **Chad Miller** -- `Invoke-Sqlcmd2` function
- **Jason Ulbright** -- Community fork maintainer (security hardening, CIM migration, JSON config, site-aware deployment)
