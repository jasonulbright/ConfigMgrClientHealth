# ConfigMgr Client Health (Community Fork)

Automated detection and remediation of common MECM/ConfigMgr client health issues. Validates 25+ health checks, remediates problems automatically, and logs results to SQL Server, file shares, and an optional REST API.

**This is a maintained community fork** of [AndersRodland/ConfigMgrClientHealth](https://github.com/AndersRodland/ConfigMgrClientHealth) (v0.8.3). The original tool is widely deployed in production MECM environments but was abandoned in 2023 with unpatched security vulnerabilities and deprecated WMI APIs.

---

## Table of Contents

- [What This Fork Changes](#what-this-fork-changes)
- [Requirements](#requirements)
- [Quick Start (Automated Setup)](#quick-start-automated-setup)
- [Manual Setup](#manual-setup)
  - [1. Create the Database](#1-create-the-database)
  - [2. Configure](#2-configure)
  - [3. Deploy](#3-deploy)
- [Configuration Reference](#configuration-reference)
  - [Client Settings](#client-settings)
  - [Client Install Properties](#client-install-properties)
  - [Logging](#logging)
  - [Health Check Options](#health-check-options)
  - [Service Monitoring](#service-monitoring)
  - [Remediation](#remediation)
  - [Site-Aware Configuration](#site-aware-configuration)
- [Health Checks](#health-checks)
- [Deployment Methods](#deployment-methods)
  - [Option A: Configuration Baseline (Recommended)](#option-a-configuration-baseline-recommended)
  - [Option B: Package + Scheduled Task](#option-b-package--scheduled-task)
  - [Option C: Scheduled Task via GPO](#option-c-scheduled-task-via-gpo)
- [Logging and Reporting](#logging-and-reporting)
  - [Local File Logging](#local-file-logging)
  - [Network Share Logging](#network-share-logging)
  - [SQL Database Logging](#sql-database-logging)
  - [REST API (Webservice)](#rest-api-webservice)
- [API Reference](#api-reference)
- [SQL Database Schema](#sql-database-schema)
- [Migrating from XML to JSON](#migrating-from-xml-to-json)
- [Tests](#tests)
- [Remediation Testing (Break Scripts)](#remediation-testing-break-scripts)
- [Troubleshooting](#troubleshooting)
- [License](#license)
- [Credits](#credits)

---

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
- **Automated setup wizard** -- `Install-ClientHealth.ps1` guides you through environment setup, generates config, creates the database, provisions MECM objects, and optionally installs the API webservice.
- **REST API webservice** -- Modern ASP.NET Core minimal API replaces the original IIS-hosted webservice. Runs as a Windows Service, no IIS required.

### Reliability

- **Retry logic** -- SQL writes use `Invoke-WithRetry` (3 attempts, 5-second delay) for transient failures.
- **No silent failures** -- All empty `catch{}` blocks replaced with `Write-Verbose` or `Write-Warning` logging.
- **Consolidated trigger functions** -- 5 separate schedule trigger functions merged into single `Invoke-CCMTrigger`.

---

## Requirements

| Component | Version | Purpose |
|-----------|---------|---------|
| PowerShell | 5.1+ (Windows PowerShell) | Script runtime |
| Windows | 10 / Server 2016+ | Target OS |
| ConfigMgr Client | Any supported version | Managed endpoint |
| SQL Server | 2016+ | Database logging (optional) |
| .NET | 10.0+ | API webservice only (optional) |
| MECM Admin Console | Any supported version | Setup wizard only |
| Permissions | Local Administrator or SYSTEM | Script execution |

---

## Quick Start (Automated Setup)

The setup wizard handles everything: config generation, database creation, file shares, and MECM object provisioning.

```powershell
.\Deploy\Install-ClientHealth.ps1
```

The wizard prompts for:

| Prompt | Validation | Example |
|--------|------------|---------|
| Site code | Exactly 3 alphanumeric chars | `MCM` |
| Site server FQDN | Must contain a dot | `sccm01.contoso.com` |
| Domain | Auto-detected from server FQDN | `contoso.com` |
| Management point FQDN | Defaults to site server | `sccm01.contoso.com` |
| SQL Server | Live connectivity test | `sccmdbs.contoso.com` |
| Client share UNC | Valid UNC path | `\\fileshare\ClientHealth$` |
| Log share UNC | Valid UNC path | `\\fileshare\ClientHealthLogs$` |
| Target collection | Free text | `All Systems` |
| CM client version | X.XX.XXXX.XXXX format | `5.00.9128.1007` |
| Install webservice? | y/n | `n` |

After confirmation, the wizard performs every step end-to-end:

1. Generates `config.json` with all values populated
2. Executes `CreateDatabase.sql` against your SQL Server and grants permissions
3. Creates or validates file shares (client share + log share)
4. Copies script + config to the client share
5. Creates the CM Package with a Program that stages files to `%ProgramData%\ConfigMgrClientHealth\`
6. Distributes content to all DP groups
7. Creates a Configuration Item with detection and remediation scripts embedded
8. Creates a Configuration Baseline, adds the CI, and deploys it to your target collection
9. Deploys the Package to your target collection on a weekly schedule

If you answered **yes** to the webservice prompt, the wizard also:

10. Runs `dotnet publish` to build a self-contained executable
11. If the target server is local: copies files to `C:\Program Files\ClientHealthApi\`, installs as a Windows Service via `sc.exe create`, starts the service
12. If the target server is remote: outputs the published files and provides the exact `sc.exe` command to run on the target

**There are zero manual steps after the wizard completes.** Everything -- Package, Program, CI, Baseline, deployments, database, shares, and optionally the webservice -- is provisioned automatically.

For unattended/scripted setup:

```powershell
.\Deploy\Install-ClientHealth.ps1 `
    -SiteCode 'MCM' `
    -SiteServer 'sccm01.contoso.com' `
    -Domain 'contoso.com' `
    -ManagementPoint 'sccm01.contoso.com' `
    -SqlServer 'sccmdbs.contoso.com' `
    -ClientSharePath '\\fileshare\ClientHealth$' `
    -LogSharePath '\\fileshare\ClientHealthLogs$' `
    -TargetCollection 'All Systems' `
    -ClientVersion '5.00.9128.1007'
```

---

## Manual Setup

### 1. Create the Database

Run `CreateDatabase.sql` on your SQL Server instance:

```sql
-- Execute the provided schema script
sqlcmd -S sccmdbs.contoso.com -i CreateDatabase.sql
```

Then grant computer accounts access:

```sql
USE ClientHealth
CREATE LOGIN [DOMAIN\Domain Computers] FROM WINDOWS
CREATE USER [DOMAIN\Domain Computers] FOR LOGIN [DOMAIN\Domain Computers]
ALTER ROLE db_datareader ADD MEMBER [DOMAIN\Domain Computers]
ALTER ROLE db_datawriter ADD MEMBER [DOMAIN\Domain Computers]
```

The database contains two tables:
- **Configuration** -- Tracks schema version (currently `0.7.5`)
- **Clients** -- One row per managed device (39 columns, `Hostname` as primary key)

### 2. Configure

Edit `config.json` for your environment. At minimum, update:

```json
{
    "Client": {
        "Version": "5.00.9128.1007",
        "SiteCode": "MCM",
        "Domain": "contoso.com"
    },
    "ClientInstallProperties": [
        "SMSSITECODE=MCM",
        "SMSMP=sccm01.contoso.com",
        "FSP=sccm01.contoso.com",
        "DNSSUFFIX=contoso.com",
        "/mp:sccm01.contoso.com"
    ],
    "Logging": {
        "Share": "\\\\fileshare\\ClientHealthLogs$",
        "SQL": {
            "Server": "sccmdbs.contoso.com",
            "Enabled": true
        }
    }
}
```

See [Configuration Reference](#configuration-reference) for all options.

### 3. Deploy

```powershell
# Test locally first
.\ConfigMgrClientHealth.ps1 -Config .\config.json -Verbose

# Or with XML config (backward compatible)
.\ConfigMgrClientHealth.ps1 -Config .\config.xml
```

The script accepts two parameters:

| Parameter | Type | Description |
|-----------|------|-------------|
| `-Config` | string | Path to config file (`.json` or `.xml`). Defaults to `config.json` in script directory. |
| `-Webservice` | string | URI to the REST API (e.g., `http://sccm01:5000`). Optional. |

---

## Configuration Reference

### Client Settings

| JSON Path | Type | Default | Description |
|-----------|------|---------|-------------|
| `LocalFiles` | string | `C:\ClientHealth` | Local temp directory for temporary files and local log |
| `Client.Version` | string | -- | Minimum required ConfigMgr agent version (e.g., `5.00.9128.1007`) |
| `Client.SiteCode` | string | -- | Expected 3-character MECM site code |
| `Client.Domain` | string | -- | Expected Active Directory domain |
| `Client.AutoUpgrade` | bool | `true` | Automatically upgrade agent if below minimum version |
| `Client.Share` | string | `""` | UNC path to a folder containing ccmsetup.exe. Optional -- if empty or unreachable, the script downloads a fresh copy from the Management Point (`http://<MP>/CCM_Client/ccmsetup.exe`). The MP is parsed from the `MP=` or `/MP:` entry in `ClientInstallProperties`. |
| `Client.Cache.Size` | int | `16384` | Client cache size in MB. Supports percentage strings (e.g., `"5%"`) |
| `Client.Cache.DeleteOrphanedData` | bool | `true` | Remove orphaned cache packages not tracked by CM |
| `Client.Cache.Enable` | bool | `true` | Enable cache size validation |
| `Client.Log.MaxSize` | int | `4096` | Maximum CCM log file size in KB |
| `Client.Log.MaxHistory` | int | `2` | Number of log rotations to keep |
| `Client.Log.Enable` | bool | `true` | Enable log size validation |

### Client Install Properties

Array of strings passed to `ccmsetup.exe` when installing or reinstalling the client. Each string is a separate argument.

```json
"ClientInstallProperties": [
    "SMSSITECODE=MCM",
    "MP=sccm01.contoso.com",
    "FSP=sccm01.contoso.com",
    "DNSSUFFIX=contoso.com",
    "/MP:sccm01.contoso.com",
    "/skipprereq:silverlight.exe"
]
```

There are two kinds of entries in this array:

**ccmsetup.exe parameters** (prefixed with `/`, lower case) control the installation process itself:

| Parameter | Description |
|-----------|-------------|
| `/mp:server.domain.com` | Management point to download installation files from. Can specify multiple separated by `;`. |
| `/skipprereq:file.exe` | Skip a specific prerequisite check |
| `/logon` | Don't reinstall if a client is already installed |
| `/UsePKICert` | Use PKI client certificate for HTTPS |
| `/NoCRLCheck` | Skip certificate revocation list check |
| `/forceinstall` | Uninstall any existing client first |

**client.msi properties** (UPPER CASE, `=` separated) configure the client after installation:

| Property | Description |
|----------|-------------|
| `SMSSITECODE=XXX` | Site code to assign the client to (3 chars, or `AUTO`) |
| `SMSMP=server.domain.com` | Initial management point. The client will discover and migrate to other MPs through normal MP rotation after registration. |
| `FSP=server.domain.com` | Fallback status point FQDN |
| `DNSSUFFIX=domain.com` | DNS domain for MP discovery. Not needed if the client is in the same domain as a published MP. |
| `CCMHTTPPORT=80` | HTTP port for client-to-site communication |
| `CCMHTTPSPORT=443` | HTTPS port for client-to-site communication |
| `RESETKEYINFORMATION=TRUE` | Remove stale trusted root key (useful when moving between hierarchies) |

> **Note:** `/Source:` is not needed. When reinstalling, the script first checks `Client.Share`, then downloads a fresh `ccmsetup.exe` directly from the MP via `http://<MP>/CCM_Client/ccmsetup.exe`. The MP FQDN is parsed from the `SMSMP=` or `/mp:` entry in this array. This avoids relying on potentially corrupt local files -- the whole reason this script exists.

> **Important:** The `/mp:` parameter and `SMSMP=` property serve different purposes. `/mp:` tells ccmsetup.exe where to download installation files from -- it has no effect after installation. `SMSMP=` sets the initial management point the client uses after it's installed. The client will naturally discover and fail over to other MPs through normal site operations. Both should be specified.

### Logging

| JSON Path | Type | Default | Description |
|-----------|------|---------|-------------|
| `Logging.Share` | string | -- | UNC path for centralized log files (one file per client) |
| `Logging.Level` | string | `Full` | `Full` logs everything; `ClientInstall` logs only install failures |
| `Logging.MaxHistory` | int | `8` | Max health check entries per log file before rotation |
| `Logging.LocalLogFile` | bool | `true` | Keep a local copy of the log at `%ProgramData%\ConfigMgrClientHealth\` |
| `Logging.FileEnabled` | bool | `true` | Enable network share logging |
| `Logging.TimeFormat` | string | `ClientLocal` | Timestamp format: `ClientLocal` or `UTC` |
| `Logging.SQL.Server` | string | -- | SQL Server instance for database logging |
| `Logging.SQL.Enabled` | bool | `true` | Enable SQL database logging |

Log files are written in CMTrace-compatible format, viewable in the CMTrace log viewer.

### Health Check Options

| JSON Path | Type | Default | Description |
|-----------|------|---------|-------------|
| `Options.CcmSQLCELog` | bool | `false` | Check for corruption in the client's local SQLCE database (CcmSQLCE.log) |
| `Options.BITSCheck.Enable` | bool | `true` | Validate BITS service and jobs |
| `Options.BITSCheck.Fix` | bool | `true` | Remove error jobs and reset BITS DACL |
| `Options.ClientSettingsCheck.Enable` | bool | `true` | Detect task-sequence orphaned client settings policies |
| `Options.ClientSettingsCheck.Fix` | bool | `true` | Remove orphaned policies |
| `Options.DNSCheck.Enable` | bool | `true` | Validate DNS records match local IP |
| `Options.DNSCheck.Fix` | bool | `true` | Re-register with DNS server |
| `Options.Drivers` | bool | `true` | Report faulty/unknown PnP devices (no auto-fix) |
| `Options.PatchLevel` | bool | `true` | Report Windows Update Build Revision (UBR) |
| `Options.Updates.Enable` | bool | `false` | Check for and install missing OS patches from a share |
| `Options.Updates.Fix` | bool | `true` | Install missing patches |
| `Options.Updates.Share` | string | `""` | UNC path to patch repository |
| `Options.PendingReboot.Enable` | bool | `true` | Detect pending reboots from CBS, WU, and SCCM |
| `Options.PendingReboot.StartRebootApplication` | bool | `false` | Launch reboot notification app when pending |
| `Options.RebootApplication.Enable` | bool | `false` | Enable custom reboot notification application |
| `Options.RebootApplication.Application` | string | `""` | Path to reboot notification executable |
| `Options.MaxRebootDays` | int | `7` | Force reboot if system uptime exceeds this many days |
| `Options.OSDiskFreeSpace` | int | `10` | Warn if OS disk free space drops below this percentage |
| `Options.HardwareInventory.Enable` | bool | `true` | Check if hardware inventory has run recently |
| `Options.HardwareInventory.Fix` | bool | `true` | Trigger inventory scan if stale |
| `Options.HardwareInventory.Days` | int | `10` | Maximum days since last inventory before remediation |
| `Options.SoftwareMetering.Enable` | bool | `true` | Check software metering prep driver |
| `Options.SoftwareMetering.Fix` | bool | `true` | Restart CCMExec to fix metering |
| `Options.WMI.Enable` | bool | `true` | Validate WMI repository integrity |
| `Options.WMI.Fix` | bool | `true` | Rebuild WMI repository if corrupt |
| `Options.RefreshComplianceState.Enable` | bool | `true` | Periodically refresh compliance state |
| `Options.RefreshComplianceState.Days` | int | `30` | Days between forced compliance refreshes |

### Service Monitoring

The `Services` array defines Windows services to monitor. Each entry specifies the desired state:

```json
"Services": [
    { "Name": "BITS",         "StartupType": "Automatic (Delayed Start)", "State": "Running", "Uptime": "" },
    { "Name": "winmgmt",      "StartupType": "Automatic",                 "State": "Running", "Uptime": "" },
    { "Name": "wuauserv",     "StartupType": "Automatic (Delayed Start)", "State": "Running", "Uptime": "" },
    { "Name": "lanmanserver", "StartupType": "Automatic",                 "State": "Running", "Uptime": "" },
    { "Name": "RpcSs",        "StartupType": "Automatic",                 "State": "Running", "Uptime": "" },
    { "Name": "W32Time",      "StartupType": "Automatic",                 "State": "Running", "Uptime": "" },
    { "Name": "ccmexec",      "StartupType": "Automatic (Delayed Start)", "State": "Running", "Uptime": "" }
]
```

| Property | Values | Description |
|----------|--------|-------------|
| `Name` | Service short name | Must be alphanumeric with hyphens, underscores, or dots |
| `StartupType` | `Automatic`, `Automatic (Delayed Start)`, `Automatic (Trigger Start)`, `Manual`, `Disabled` | Desired startup type |
| `State` | `Running`, `Stopped` | Desired service state |
| `Uptime` | Empty string or integer | If set to a number of days, the service is restarted when uptime exceeds that value |

You can add any Windows service to this list. The script will set the startup type and start/stop the service as configured.

### Remediation

| JSON Path | Type | Default | Description |
|-----------|------|---------|-------------|
| `Remediation.AdminShare` | bool | `true` | Re-enable ADMIN$ and C$ shares if disabled |
| `Remediation.ClientProvisioningMode` | bool | `true` | Exit provisioning mode if stuck |
| `Remediation.ClientStateMessages` | bool | `true` | Re-send state messages if forwarding fails |
| `Remediation.ClientWUAHandler.Fix` | bool | `true` | Fix WUA handler registry.pol issues |
| `Remediation.ClientWUAHandler.Days` | int | `30` | Age threshold (days) for stale registry.pol |
| `Remediation.ClientCertificate` | bool | `true` | Remove stale certificates causing registration failures |

### Site-Aware Configuration

For multi-site deployments, the `Sites` section provides per-site overrides. The script detects the client's AD site name via `Win32_NTDomain` and resolves configuration in this order:

1. `Sites.<ADSiteName>` -- exact site match
2. `Sites.Default` -- catch-all for VPN/ZPA/unknown sites
3. Top-level config values -- final fallback

```json
"Sites": {
    "NYC-Office":  { "SQLServer": "sql-nyc01.contoso.com",  "ClientShare": "\\\\dp-nyc01\\ClientHealth$" },
    "LAX-Office":  { "SQLServer": "sql-lax01.contoso.com" },
    "Default":     {}
}
```

Supported override properties: `SQLServer`, `ClientShare`, `LogShare`

---

## Health Checks

The script runs these checks in sequence. Each check logs its result and remediates if the corresponding config option is enabled.

| # | Check | What It Detects | Remediation | Config |
|---|-------|-----------------|-------------|--------|
| 1 | **WMI Repository** | Corrupt WMI (`winmgmt /verifyrepository`) | Re-registers WMI binaries, rebuilds repository | `Options.WMI` |
| 2 | **Compliance State** | Stale compliance evaluation | Triggers `RefreshServerComplianceState()` | `Options.RefreshComplianceState` |
| 3 | **CM Client Installed** | Client not installed, missing DB files, corrupt SQLCE, service won't start | Downloads fresh ccmsetup.exe from MP, reinstalls with configured properties | `Client.Version`, `Client.AutoUpgrade` |
| 4 | **Client Version** | Agent below minimum version | Upgrade via ccmsetup.exe | `Client.Version`, `Client.AutoUpgrade` |
| 5 | **Services** | Wrong startup type, not running, uptime exceeded | Set startup type, start/stop service | `Services` array |
| 6 | **Site Code** | Assigned to wrong site | Reassign via `SMS_Client.SetAssignedSite()` | `Client.SiteCode` |
| 7 | **Cache Size** | Cache too small or too large | Set via COM object (supports MB or percentage) | `Client.Cache` |
| 8 | **Log Size** | CCM log files too small/large | Update registry `HKLM:\SOFTWARE\Microsoft\CCM\Logging\@GLOBAL` | `Client.Log` |
| 9 | **Provisioning Mode** | Client stuck in provisioning mode | Disable via registry + CIM method | `Remediation.ClientProvisioningMode` |
| 10 | **Client Certificate** | Stale certificate blocking registration | Remove certificate file, trigger re-enrollment | `Remediation.ClientCertificate` |
| 11 | **Hardware Inventory** | Inventory not run in configured days | Trigger schedule `{00000000-0000-0000-0000-000000000001}` | `Options.HardwareInventory` |
| 12 | **Software Metering** | PrepDriver errors | Restart CCMExec service | `Options.SoftwareMetering` |
| 13 | **DNS** | FQDN mismatch, DNS IPs not in local config | Re-register DNS (`ipconfig /registerdns`) | `Options.DNSCheck` |
| 14 | **BITS** | Error/TransientError jobs | Remove bad jobs, reset BITS DACL | `Options.BITSCheck` |
| 15 | **Client Settings** | Orphaned task-sequence policies | Remove `CCM_ClientAgentConfig` where `PolicySource = "CcmTaskSequence"` | `Options.ClientSettingsCheck` |
| 16 | **WUA Handler** | registry.pol corruption, GP errors | Delete stale registry.pol, run `gpupdate` | `Remediation.ClientWUAHandler` |
| 17 | **State Messages** | Failed MP forwarding | Refresh server compliance state | `Remediation.ClientStateMessages` |
| 18 | **Admin Shares** | ADMIN$ / C$ missing | Restart Server service (`lanmanserver`) | `Remediation.AdminShare` |
| 19 | **Missing Drivers** | Faulty PnP devices (error code != 0, 22) | Report only -- no auto-fix | `Options.Drivers` |
| 20 | **OS Updates** | Missing patches (from share) | Install from configured update share | `Options.Updates` |
| 21 | **Disk Space** | OS drive below threshold | Report only -- no auto-fix | `Options.OSDiskFreeSpace` |
| 22 | **Pending Reboot** | CBS, Windows Update, SCCM SDK | Launch reboot app or force reboot if uptime > max days | `Options.PendingReboot`, `Options.MaxRebootDays` |
| 23 | **Orphaned Cache** | Cache folders not tracked by CM | Delete orphaned folders | `Client.Cache.DeleteOrphanedData` |
| 24 | **CCMSETUP AppData** | SYSTEM profile AppData path incorrect | Fix registry value | Always runs |
| 25 | **SMSTSMgr Dependency** | SMSTSMgr not dependent on CCMExec | Set service dependency | Always runs |

After all checks complete, the script:
- Triggers machine policy evaluation
- Triggers state message resend
- Triggers update scan
- Restarts CCMExec if any check flagged it
- Runs CCMEval
- Writes `LastRun` timestamp to `HKLM:\Software\ConfigMgrClientHealth`

---

## Deployment Methods

### Option A: Configuration Baseline (Recommended)

This is the preferred approach. The script and config are cached locally, so clients work even when disconnected from the network.

The setup wizard (`Install-ClientHealth.ps1`) creates all of these objects automatically. For manual setup:

**Step 1: Create a CM Package**

Create a Package with source directory containing:
- `ConfigMgrClientHealth.ps1`
- `config.json`
- `Deploy-ClientHealthPackage.ps1`

Create a Program:
```
powershell.exe -ExecutionPolicy Bypass -File Deploy-ClientHealthPackage.ps1
```
This copies the script and config to `%ProgramData%\ConfigMgrClientHealth\` on each client.

**Step 2: Create a Configuration Item**

Discovery script (`CI-Detection.ps1`) -- returns `$true` if the health check ran within 7 days:
```powershell
$RegPath = 'HKLM:\Software\ConfigMgrClientHealth'
$lastRun = (Get-ItemProperty -Path $RegPath -Name 'LastRun' -ErrorAction SilentlyContinue).LastRun
if ($null -eq $lastRun) { return $false }
try {
    $daysSince = (New-TimeSpan -Start ([datetime]$lastRun) -End (Get-Date)).TotalDays
    return ($daysSince -le 7)
}
catch { return $false }
```

Remediation script (`CI-Remediation.ps1`) -- invokes the locally cached copy:
```powershell
$ScriptDir = Join-Path $env:ProgramData 'ConfigMgrClientHealth'
$ScriptPath = Join-Path $ScriptDir 'ConfigMgrClientHealth.ps1'
$ConfigPath = Join-Path $ScriptDir 'config.json'

if (-not (Test-Path $ScriptPath)) {
    Write-Error "ConfigMgrClientHealth.ps1 not found at $ScriptPath. Deploy the package first."
    exit 1
}
if (-not (Test-Path $ConfigPath)) {
    Write-Error "config.json not found at $ConfigPath. Deploy the package first."
    exit 1
}
try { & $ScriptPath -Config $ConfigPath }
catch {
    Write-Error "ConfigMgr Client Health failed: $_"
    exit 1
}
```

CI settings:
- Data type: Boolean
- Compliance rule: Value equals `True`
- Enable remediation
- Run scripts as 64-bit
- Run in SYSTEM context (not per-user)

**Step 3: Create a Configuration Baseline**

- Add the CI
- Deploy to `All Systems` (or a scoped collection)
- Evaluation schedule: once per day
- Enable remediation

### Option B: Package + Scheduled Task

1. Create a Package with source files (script + config.json)
2. Program: `powershell.exe -ExecutionPolicy Bypass -File ConfigMgrClientHealth.ps1 -Config config.json`
3. Deploy as Required to All Systems on a weekly schedule

### Option C: Scheduled Task via GPO

Create a scheduled task that runs weekly as SYSTEM:
```
powershell.exe -ExecutionPolicy Bypass -File "\\server\ClientHealth$\ConfigMgrClientHealth.ps1" -Config "\\server\ClientHealth$\config.json"
```

> **Note:** Options B and C require network access to the script/config share at runtime. Option A caches locally and works offline via config caching.

---

## Logging and Reporting

The script supports four independent logging destinations. Enable any combination.

### Local File Logging

- **Config:** `Logging.LocalLogFile = true`
- **Location:** `%ProgramData%\ConfigMgrClientHealth\ClientHealth.log`
- **Format:** CMTrace-compatible (open with CMTrace or OneTrace)
- **Severity levels:** 1 = Information, 2 = Warning, 3 = Error

### Network Share Logging

- **Config:** `Logging.FileEnabled = true`, `Logging.Level = "Full"`
- **Location:** `<Logging.Share>\<Hostname>.log`
- **Format:** CMTrace-compatible, one log file per client
- **History:** Auto-rotates when entries exceed `Logging.MaxHistory`

### SQL Database Logging

- **Config:** `Logging.SQL.Enabled = true`, `Logging.SQL.Server = "..."`
- **Database:** `ClientHealth`, table `dbo.Clients`
- **Pattern:** UPSERT (update if hostname exists, insert if new)
- **Security:** All queries use parameterized `SqlParameter` objects
- **Retry:** 3 attempts with 5-second delay via `Invoke-WithRetry`

### REST API (Webservice)

- **Config:** Pass `-Webservice http://server:5000` at runtime
- **Endpoint:** `POST /api/Clients`
- **Format:** JSON, automatic timestamp
- **Advantage:** No direct SQL access required from clients

---

## API Reference

The optional REST API webservice provides centralized health data access. Built with ASP.NET Core minimal APIs, it runs as a Windows Service (no IIS required).

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` | Health check -- returns `{ Status, Version, Timestamp }` |
| `GET` | `/api/Clients` | List all clients (paginated: `?skip=0&take=50`) |
| `GET` | `/api/Clients/{hostname}` | Get a specific client record |
| `POST` | `/api/Clients` | Create or update a client (UPSERT) |
| `PUT` | `/api/Clients/{hostname}` | Update an existing client |
| `DELETE` | `/api/Clients/{hostname}` | Delete a client record |

### Configuration

Edit `Webservice/ClientHealthApi/appsettings.json`:

```json
{
  "ConnectionStrings": {
    "ClientHealth": "Server=sccmdbs.contoso.com;Database=ClientHealth;Trusted_Connection=True;TrustServerCertificate=True;"
  }
}
```

### Installation

The setup wizard handles this automatically. For manual installation:

```powershell
# Publish self-contained
dotnet publish Webservice/ClientHealthApi/ClientHealthApi.csproj -c Release -o C:\ClientHealthApi --self-contained -r win-x64

# Install as Windows Service
sc.exe create ClientHealthApi binPath= "C:\ClientHealthApi\ClientHealthApi.exe --urls=http://*:5000" start= delayed-auto
sc.exe description ClientHealthApi "ConfigMgr Client Health REST API"
net start ClientHealthApi
```

The webservice can run on any Windows server -- it does not need to be on the site server or SQL server.

### Example Usage

```powershell
# Query a specific client
Invoke-RestMethod -Uri 'http://sccm01:5000/api/Clients/WORKSTATION-01'

# List all clients (first 50)
Invoke-RestMethod -Uri 'http://sccm01:5000/api/Clients?take=50'

# Health check
Invoke-RestMethod -Uri 'http://sccm01:5000/'
```

---

## SQL Database Schema

The `ClientHealth` database stores one row per managed device. Created by `CreateDatabase.sql`.

| Column | Type | Description |
|--------|------|-------------|
| `Hostname` | varchar(100) | **Primary key.** Computer name. |
| `OperatingSystem` | varchar(100) | OS caption with architecture |
| `Architecture` | varchar(10) | x64 or x86 |
| `Build` | varchar(100) | OS build number |
| `Manufacturer` | varchar(100) | Hardware manufacturer |
| `Model` | varchar(100) | Hardware model |
| `InstallDate` | smalldatetime | OS install date |
| `OSUpdates` | smalldatetime | Last OS update date |
| `LastLoggedOnUser` | varchar(100) | Last interactive logon |
| `ClientVersion` | varchar(100) | CM client version |
| `PSVersion` | float | PowerShell version |
| `PSBuild` | int | PowerShell build number |
| `Sitecode` | varchar(3) | Assigned CM site code |
| `Domain` | varchar(100) | AD domain |
| `MaxLogSize` | int | Configured max log size (KB) |
| `MaxLogHistory` | int | Configured log rotation count |
| `CacheSize` | int | Client cache size (MB) |
| `ClientCertificate` | varchar(50) | Certificate status |
| `ProvisioningMode` | varchar(50) | Provisioning mode status |
| `DNS` | varchar(200) | DNS validation result |
| `Drivers` | varchar(100) | Driver status |
| `Updates` | varchar(200) | Update status |
| `PendingReboot` | varchar(50) | Pending reboot status |
| `LastBootTime` | smalldatetime | Last system boot |
| `OSDiskFreeSpace` | float | Free disk space (%) |
| `Services` | varchar(200) | Service health status |
| `AdminShare` | varchar(50) | Admin share status |
| `StateMessages` | varchar(50) | State message status |
| `WUAHandler` | varchar(50) | WUA handler status |
| `WMI` | varchar(50) | WMI repository status |
| `RefreshComplianceState` | smalldatetime | Last compliance refresh |
| `ClientInstalled` | smalldatetime | Client install timestamp |
| `Version` | varchar(10) | Script version that last ran |
| `Timestamp` | datetime | Record last updated |
| `HWInventory` | smalldatetime | Last HW inventory |
| `SWMetering` | varchar(50) | Software metering status |
| `BITS` | varchar(50) | BITS service status |
| `PatchLevel` | int | Windows UBR |
| `ClientInstalledReason` | varchar(200) | Why client was reinstalled |

---

## Migrating from XML to JSON

The script accepts both formats -- no immediate migration required. To convert:

1. Create a `config.json` based on the template in this repo
2. Map your XML values to the JSON structure (see [Configuration Reference](#configuration-reference))
3. Test with `-Config config.json -Verbose`
4. Deploy the new config alongside the script
5. The script caches JSON configs locally, so VPN clients will work offline after first run

A conversion helper is included:

```powershell
.\Convert-ConfigXmlToJson.ps1
```

---

## Tests

128 Pester tests validate script integrity, security, configuration generation, and deployment automation:

```powershell
Invoke-Pester .\Tests\ -Output Detailed
```

**Test coverage includes:**

| Area | Tests |
|------|-------|
| Script integrity (parses, required blocks present) | 5 |
| Security (no Invoke-Expression, parameterized SQL, no hardcoded credentials) | 8 |
| CIM migration (no Get-WmiObject, no Invoke-WmiMethod, no [wmiclass]) | 9 |
| Error handling (no empty catch blocks, retry logic) | 3 |
| Client install safety (Start-Process, argument arrays) | 3 |
| JSON config schema | 15 |
| XML config schema | 9 |
| JSON/XML backward compatibility | 4 |
| Site-aware config resolution | 6 |
| Config caching mechanism | 4 |
| SQL schema alignment | 5 |
| Setup wizard (Install-ClientHealth.ps1) | 51 |
| Setup wizard config generation | 20 |
| Setup wizard security | 5 |

---

## Remediation Testing (Break Scripts)

The `Tests/BreakScripts/` directory contains scripts that intentionally introduce specific health issues on a lab endpoint so you can validate that the health check detects and remediates each one in isolation.

### Prerequisites

- A lab VM with the ConfigMgr client installed (do **not** run these on production endpoints)
- Local administrator rights
- Set the safety flag in your PowerShell session before any break script will execute:

```powershell
$env:YOURLAB = 'true'
```

Every break script checks for this flag and refuses to run without it.

### Available Scripts

| Script | What It Breaks | Health Check Validated |
|--------|---------------|----------------------|
| `Break-Services.ps1` | Stops BITS and ccmexec, sets wuauserv startup to Disabled | Service monitoring and startup type correction |
| `Break-SiteCode.ps1` | Reassigns the client to site code `ZZZ` via COM | Site code validation and reassignment |
| `Break-CacheSize.ps1` | Sets client cache to 1 MB via COM | Cache size detection and correction |
| `Break-LogSize.ps1` | Sets CCM log max size to 100 KB and history to 0 via registry | Log size and history correction |
| `Break-ProvisioningMode.ps1` | Enables provisioning mode via registry | Provisioning mode detection and exit |
| `Break-AdminShares.ps1` | Disables ADMIN$ and C$ shares via `AutoShareWks` registry key | Admin share re-enablement via Server service restart |
| `Break-HWInventory.ps1` | Deletes the hardware inventory timestamp from WMI | Stale inventory detection and scan trigger |
| `Break-WUAHandler.ps1` | Overwrites `registry.pol` with a zero-byte file and backdates it 60 days | WUA handler / GPO corruption detection, `gpupdate` repair |
| `Break-ComplianceState.ps1` | Sets last compliance state refresh to 61 days ago in registry | Compliance state staleness detection and forced refresh |
| `Break-LastRun.ps1` | Deletes the `LastRun` registry value used by CI detection | Baseline non-compliance trigger, remediation script execution |
| `Break-All.ps1` | Runs all 10 break scripts in sequence | Full end-to-end health check and remediation validation |
| `Get-HealthState.ps1` | Read-only snapshot of current health state (safe to run anywhere) | Pre/post comparison to verify remediation worked |

### Testing Workflow

**Step 1: Capture baseline state**

```powershell
$env:YOURLAB = 'true'
.\Tests\BreakScripts\Get-HealthState.ps1
```

This prints a color-coded report of every health item: green for OK, red for broken, yellow for warnings. Save or screenshot this for comparison.

**Step 2: Break one or more items**

Break a single item for targeted testing:

```powershell
.\Tests\BreakScripts\Break-Services.ps1
```

Or break everything at once for a full validation run:

```powershell
.\Tests\BreakScripts\Break-All.ps1
```

**Step 3: Confirm the broken state**

```powershell
.\Tests\BreakScripts\Get-HealthState.ps1
```

You should see red entries for everything you broke.

**Step 4: Run the health check**

```powershell
.\ConfigMgrClientHealth.ps1 -Config .\config.json -Verbose
```

The `-Verbose` flag shows every detection and remediation action in real time. Watch for each broken item being detected and fixed.

**Step 5: Verify remediation**

```powershell
.\Tests\BreakScripts\Get-HealthState.ps1
```

All items should be green again. If any remain red, check the log at `%ProgramData%\ConfigMgrClientHealth\ClientHealth.log` (CMTrace format) for details on what failed and why.

### What These Scripts Do NOT Touch

These scripts are designed to be safe for lab use:

- No disk partition changes, boot configuration edits, or system file deletion
- No WMI repository corruption (WMI rebuild is destructive and takes minutes to recover)
- No client uninstallation (reinstall takes 10+ minutes and requires MP access)
- No DNS record manipulation (affects network connectivity beyond the client)

If you need to test WMI repair or client reinstallation, those scenarios are better tested by stopping the `winmgmt` service and renaming the WMI repository folder, or by manually uninstalling the client -- both of which require manual revert steps that don't lend themselves to a simple break/fix script.

---

## Troubleshooting

### Script doesn't run / exits immediately

- **Not running as Administrator:** The script requires local admin or SYSTEM context. Check with `whoami /priv`.
- **Task sequence detected:** The script exits (code 2) if it detects an active OSD task sequence to avoid interference.
- **Config file not found:** Verify the `-Config` path is accessible. Check share permissions.

### Client keeps reinstalling

- **Version mismatch:** The minimum version in config (`Client.Version`) must match what's available. Check `Client.AutoUpgrade` setting.
- **WMI corrupt:** If WMI is rebuilt, the client is tagged for reinstall. Check `WMI` status in logs.

### SQL logging not working

- **Connectivity:** Verify the SQL server is reachable from the client. The script uses Windows Authentication -- the computer account needs `db_datareader` and `db_datawriter` on the `ClientHealth` database.
- **Module missing:** SQL logging requires the `SqlServer` or `SQLPS` PowerShell module. The `SQLPS` module ships with SQL Server Management Studio.

### Config caching

- **Cache location:** `%ProgramData%\ConfigMgrClientHealth\config.json.cache`
- **When used:** The cached copy is loaded automatically when the network config path is unreachable (VPN disconnect, share offline).
- **Force refresh:** Delete the cache file to force a fresh load on next run.

### Baseline shows non-compliant

- **Package not deployed:** The CI remediation script expects files at `%ProgramData%\ConfigMgrClientHealth\`. Deploy the staging package first.
- **Script errored:** Check the local log at `%ProgramData%\ConfigMgrClientHealth\ClientHealth.log` (CMTrace format).
- **7-day window:** Detection checks if `LastRun` is within 7 days. If the baseline evaluates before the package deploys, it will show non-compliant until the next cycle.

### Log files

| Log | Location | Format |
|-----|----------|--------|
| Client local | `%ProgramData%\ConfigMgrClientHealth\ClientHealth.log` | CMTrace |
| Network share | `<Logging.Share>\<Hostname>.log` | CMTrace |
| SQL database | `ClientHealth.dbo.Clients` | Query with SSMS |
| Webservice | Kestrel console or Windows Event Log | Standard .NET logging |

---

## License

This project is licensed under the [Creative Commons Attribution-NoDerivatives 4.0](https://creativecommons.org/licenses/by-nd/4.0/) license, inherited from the original project by Anders Rodland.

---

## Credits

- **Anders Rodland** -- Original author ([andersrodland.com](https://www.andersrodland.com))
- **Chad Miller** -- `Invoke-Sqlcmd2` function
- **Jason Ulbright** -- Community fork maintainer (security hardening, CIM migration, JSON config, site-aware deployment, automated setup wizard, REST API webservice)
