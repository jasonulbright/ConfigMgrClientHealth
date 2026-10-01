# ConfigMgr Client Health (Community Fork)

Finds and fixes the usual ConfigMgr client problems: broken WMI, stuck provisioning mode, a corrupt registry.pol, wrong cache size, missing admin shares, services that won't start, and a long list of others. Results go to a local log, a log share, SQL, or a small REST API.

This is a fork of Anders Rodland's [ConfigMgrClientHealth](https://github.com/AndersRodland/ConfigMgrClientHealth). The original stopped at 0.8.3 in 2023. Plenty of shops still run it, but it had some security problems and used the old WMI cmdlets. This fork fixes those and adds checks for things that broke in Windows and ConfigMgr since then.

---

## Table of Contents

- [What's Different in This Fork](#whats-different-in-this-fork)
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
- [Remediation Testing (Break Scripts)](#remediation-testing-break-scripts)
- [Troubleshooting](#troubleshooting)
- [License](#license)
- [Credits](#credits)

---

## What's Different in This Fork

### Security

The SQL writes are parameterized now. The original built the whole UPSERT out of string concatenation. `Invoke-Expression` is gone, and config values (service names, site codes, domains, MPs) are validated before they get anywhere near a WMI filter or a command line. Paths in the config expand `%VAR%` and `$env:VAR` and nothing else.

A downloaded `ccmsetup.exe` (or VC++ redist, or Policy Platform MSI) only runs if it carries a valid, unrevoked Microsoft signature. `%ProgramData%\ConfigMgrClientHealth` is locked to SYSTEM and Administrators, and the CI won't run a staged script that somebody else owns.

The API uses Windows authentication by default, and a computer can only write its own record.

### Everything else

- CIM instead of `Get-WmiObject` throughout.
- JSON config. XML still works, and `Convert-ConfigXmlToJson.ps1` converts it.
- Per-AD-site overrides for the SQL server, log share and management points, so one config covers every site.
- The last good config is cached locally, so clients on VPN keep working when the share is unreachable.
- `Install-ClientHealth.ps1` sets up the database, shares, package, CI, baseline and API in one go.
- The IIS webservice is replaced by a small ASP.NET Core API that runs as a Windows service.
- Client reinstalls download `ccmsetup.exe` straight from your management points and try the next one if one is down. No client share needed.
- New report-only checks write to a Findings column, so you can see problems the script shouldn't fix on its own.
- Set `NotifyOnly=TRUE` on a device and the script reports everything and changes nothing there.

---

## Requirements

| Component | Version | Purpose |
|-----------|---------|---------|
| PowerShell | 5.1+ (Windows PowerShell) | Script runtime |
| Windows | 10, 11 / Server 2016-2025 | Target OS |
| ConfigMgr Client | Any supported version | Managed endpoint |
| SQL Server | 2016+ | Database logging (optional) |
| .NET | 10.0+ | API webservice only (optional) |
| MECM Admin Console | Any supported version | Setup wizard only |
| Permissions | Local Administrator or SYSTEM | Script execution |

---

## Quick Start (Automated Setup)

Run the setup wizard from a machine with the ConfigMgr console. It writes the config, creates the database and shares, and builds the ConfigMgr objects.

```powershell
.\Deploy\Install-ClientHealth.ps1
```

The wizard prompts for:

| Prompt | Validation | Example |
|--------|------------|---------|
| Site code | Exactly 3 alphanumeric chars | `MCM` |
| Site server FQDN | Must contain a dot | `sccm01.contoso.com` |
| Domain | Auto-detected from server FQDN | `contoso.com` |
| Management point FQDN(s) | Defaults to site server; comma-separated for multiple MPs | `sccm01.contoso.com,sccm02.contoso.com` |
| Download ccmsetup.exe over HTTPS? | y/n; default `n` | `n` |
| SQL Server | Live connectivity test | `sccmdbs.contoso.com` |
| Client share UNC | Valid UNC path | `\\fileshare\ClientHealth$` |
| Log share UNC | Valid UNC path | `\\fileshare\ClientHealthLogs$` |
| Target collection | Free text | `All Systems` |
| CM client version | X.XX.XXXX.XXXX format | `5.00.9128.1007` |
| Install webservice? | y/n | `n` |

Once you confirm, it:

1. Writes `config.json`.
2. Runs `CreateDatabase.sql` and grants access.
3. Creates the client share and the log share. Only `DOMAIN\Domain Computers` can write to the log share.
4. Copies the script and config to the client share.
5. Creates the package and a program that stages the files to `%ProgramData%\ConfigMgrClientHealth\`. If the package already exists, it updates the content on the DPs.
6. Distributes the content to all DP groups.
7. Creates the configuration item with the detection and remediation scripts. On a rerun it updates the scripts in the existing CI.
8. Creates the baseline and deploys it to your target collection.
9. Deploys the package to the same collection weekly. The program reruns every time, so config changes reach the clients.

If you said yes to the webservice, it also publishes the API with `dotnet publish`. On a local server it installs it under `C:\Program Files\ClientHealthApi\` as a service, opens the port for the Domain firewall profile and starts it. For a remote server it gives you the files and the commands to run there.

You can run the wizard again after an upgrade. It updates what's already there instead of creating duplicates.

If you use the API, you still have to give the API server's computer account access to the database yourself.

For unattended/scripted setup:

```powershell
.\Deploy\Install-ClientHealth.ps1 `
    -SiteCode 'MCM' `
    -SiteServer 'sccm01.contoso.com' `
    -Domain 'contoso.com' `
    -ManagementPoints 'sccm01.contoso.com','sccm02.contoso.com' `
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
- **Clients** -- One row per managed device (40 columns, `Hostname` as primary key)

### 2. Configure

Edit `config.json` for your environment. At minimum, update:

```json
{
    "Client": {
        "Version": "5.00.9128.1007",
        "SiteCode": "MCM",
        "Domain": "contoso.com",
        "ManagementPoints": [
            "sccm01.contoso.com",
            "sccm02.contoso.com"
        ],
        "MPHttps": false
    },
    "ClientInstallProperties": [
        "SMSSITECODE=MCM",
        "FSP=sccm01.contoso.com",
        "DNSSUFFIX=contoso.com"
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
| `LocalFiles` | string | `C:\ClientHealth` | Folder for the local log and temporary files. The wizard sets `C:\ProgramData\ConfigMgrClientHealth`, which the script keeps locked to SYSTEM and Administrators. Use that path. |
| `Client.Version` | string | -- | Minimum required ConfigMgr agent version (e.g., `5.00.9128.1007`) |
| `Client.SiteCode` | string | -- | Expected 3-character MECM site code |
| `Client.Domain` | string | -- | Expected Active Directory domain |
| `Client.AutoUpgrade` | bool | `true` | Automatically upgrade agent if below minimum version |
| `Client.ManagementPoints` | string[] | -- | Management point FQDNs used to download `ccmsetup.exe`. The script shuffles the list and downloads from the first MP that answers. All of them go on the ccmsetup command line. |
| `Client.MPHttps` | bool | `false` | Download `ccmsetup.exe` from MPs over HTTPS instead of HTTP. |
| `Client.Cache.Size` | int | `16384` | Client cache size in MB, or a percentage string such as `"5%"`. If a client setting configures the cache size, that wins and the script only reports the difference. |
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
    "FSP=sccm01.contoso.com",
    "DNSSUFFIX=contoso.com"
]
```

Don't put `SMSMP=`, `MP=`, or `/mp:` here in a JSON config. List your MPs in `Client.ManagementPoints` instead. At install time the script strips any MP entries from this array and builds them itself: `/mp:` with every MP (the one it downloaded from first), `SMSMP=` with that MP, and `SMSMPLIST=` when you have more than one. Legacy configs that still contain `SMSMP=`, `MP=`, or `/mp:` are read as a fallback when `Client.ManagementPoints` is missing.

There are two kinds of entries in this array:

**ccmsetup.exe parameters** (prefixed with `/`, lower case) control the installation process itself:

| Parameter | Description |
|-----------|-------------|
| `/mp:server.domain.com` | Management point to download installation files from. Managed by the script at runtime from `Client.ManagementPoints`. |
| `/skipprereq:file.exe` | Skip a specific prerequisite check |
| `/logon` | Don't reinstall if a client is already installed |
| `/UsePKICert` | Use PKI client certificate for HTTPS |
| `/NoCRLCheck` | Skip certificate revocation list check |
| `/forceinstall` | Uninstall any existing client first |

**client.msi properties** (UPPER CASE, `=` separated) configure the client after installation:

| Property | Description |
|----------|-------------|
| `SMSSITECODE=XXX` | Site code to assign the client to (3 chars, or `AUTO`) |
| `SMSMP=server.domain.com` | Initial management point. Managed by the script at runtime from `Client.ManagementPoints`. |
| `FSP=server.domain.com` | Fallback status point FQDN |
| `DNSSUFFIX=domain.com` | DNS domain for MP discovery. Not needed if the client is in the same domain as a published MP. |
| `CCMHTTPPORT=80` | HTTP port for client-to-site communication |
| `CCMHTTPSPORT=443` | HTTPS port for client-to-site communication |
| `RESETKEYINFORMATION=TRUE` | Remove stale trusted root key (useful when moving between hierarchies) |

You don't need `/Source:`. A reinstall downloads `ccmsetup.exe` from `http(s)://<MP>/CCM_Client/ccmsetup.exe`, so it never depends on files already on the client.

`/mp:` and `SMSMP=` do different jobs. `/mp:` is where ccmsetup downloads the install files from. `SMSMP=` is the first MP the installed client talks to. The script sets both, so leave them out of the config.

### Logging

| JSON Path | Type | Default | Description |
|-----------|------|---------|-------------|
| `Logging.Share` | string | -- | UNC path for centralized log files (one file per client) |
| `Logging.Level` | string | `Full` | `Full` logs everything; `ClientInstall` logs only install failures |
| `Logging.MaxHistory` | int | `8` | Max health check entries per log file before rotation |
| `Logging.LocalLogFile` | bool | `true` | Keep a local log at `<LocalFiles>\ClientHealth.log` |
| `Logging.FileEnabled` | bool | `true` | Enable network share logging |
| `Logging.TimeFormat` | string | `ClientLocal` | Timestamp format: `ClientLocal` or `UTC` |
| `Logging.SQL.Server` | string | -- | SQL Server instance for database logging |
| `Logging.SQL.Enabled` | bool | `true` | Enable SQL database logging |

Log files are written in CMTrace-compatible format, viewable in the CMTrace log viewer.

### Health Check Options

| JSON Path | Type | Default | Description |
|-----------|------|---------|-------------|
| `Options.CcmSQLCELog` | bool | `false` | Warn when CcmSQLCE.log is active outside debug logging. Report only: current clients write this log during normal operation, so the script never reinstalls the client from this check. |
| `Options.BITSCheck.Enable` | bool | `true` | Find BITS jobs in the final `Error` state |
| `Options.BITSCheck.Fix` | bool | `true` | Remove jobs in `Error` state for longer than `Days`. The BITS service permissions are never changed. |
| `Options.BITSCheck.Days` | int | `7` | Minimum age of an `Error` job before it is removed |
| `Options.ClientSettingsCheck.Enable` | bool | `true` | Detect task-sequence orphaned client settings policies |
| `Options.ClientSettingsCheck.Fix` | bool | `true` | Remove orphaned policies |
| `Options.DNSCheck.Enable` | bool | `true` | Validate DNS records match local IP |
| `Options.DNSCheck.Fix` | bool | `true` | Re-register with DNS server. Skipped, and reported, when policy or every adapter turns dynamic DNS update off. |
| `Options.Drivers` | bool | `true` | Report faulty/unknown PnP devices (no auto-fix) |
| `Options.PatchLevel` | bool | `true` | Report Windows Update Build Revision (UBR) |
| `Options.Updates.Enable` | bool | `false` | Check for and install missing OS patches from a share |
| `Options.Updates.Fix` | bool | `true` | Install missing patches with DISM (`Add-WindowsPackage`). All `.msu` files of the share folder are staged together, so checkpoint updates are found. |
| `Options.Updates.Share` | string | `""` | UNC path to patch repository |
| `Options.PendingReboot.Enable` | bool | `true` | Detect pending reboots from CBS, WU, and SCCM |
| `Options.PendingReboot.StartRebootApplication` | bool | `false` | Launch reboot notification app when pending |
| `Options.RebootApplication.Enable` | bool | `false` | Enable custom reboot notification application |
| `Options.RebootApplication.Application` | string | `""` | Path to reboot notification executable |
| `Options.MaxRebootDays` | int | `7` | Start the reboot application when uptime is longer than this many days. Only when `RebootApplication.Enable` is true. |
| `Options.OSDiskFreeSpace` | int | `10` | Warn if OS disk free space drops below this percentage |
| `Options.HardwareInventory.Enable` | bool | `true` | Check if hardware inventory has run recently |
| `Options.HardwareInventory.Fix` | bool | `true` | Trigger inventory scan if stale |
| `Options.HardwareInventory.Days` | int | `10` | Maximum days since last inventory before remediation |
| `Options.SoftwareMetering.Enable` | bool | `true` | Check software metering prep driver |
| `Options.SoftwareMetering.Fix` | bool | `true` | Reinstall the prep driver and restart CCMExec. Only log lines since the last run count. |
| `Options.WMI.Enable` | bool | `true` | Validate WMI repository integrity (`winmgmt /verifyrepository` exit code 1358). A failed query is reported only. |
| `Options.WMI.Fix` | bool | `true` | Back up, then salvage the repository and reinstall the client. The repository is never reset. |
| `Options.RefreshComplianceState.Enable` | bool | `true` | Periodically refresh compliance state |
| `Options.RefreshComplianceState.Days` | int | `30` | Days between forced compliance refreshes |

### Extended Checks

Each check has its own `Options.<Name>` block. A missing block uses the default shown. Report-only results go to the `Findings` column (SQL and API) and to the logs.

| JSON Path | Default | What it checks | Fix (when `Fix` is true) |
|-----------|---------|----------------|--------------------------|
| `Options.CcmEvalTask` | Enable `true`, Fix `true` | The built-in client health task is missing, disabled, not run for 3 days, or failed | Enable the task. A missing task is reported. |
| `Options.ClientActivity` | Enable `true`, Fix `true`, Days `7` | No heartbeat (DDR) record, or no heartbeat or policy activity within `Days` | Trigger machine policy and discovery |
| `Options.WindowsUpdateSource` | Enable `true`, Fix `true` | WSUS-managed clients only (skipped when Intune owns the Windows Update workload): scan-source and dual-scan conflicts, leftover deferral policies, scan source hotfix KB36495448 not applied | Remove `UseUpdateClassPolicySource` from the wrong registry path (written by ConfigMgr 2409/2503 RTM). Everything else is reported. |
| `Options.WindowsUpdateScan` | Enable `true`, Fix `false`, ResetDays `30` | Scan errors in WUAHandler.log since the last run, by class (corrupt components, proxy, timeout, certificate); domain policy overriding the WSUS server | For corrupt components only: rename `SoftwareDistribution` (at most once per `ResetDays`). This clears the Windows Update history. |
| `Options.TlsConfiguration` | Enable `true`, Fix `false` | .NET strong crypto, TLS 1.2 client in SChannel, FIPS mode, .NET older than 4.8 | Set `SchUseStrongCrypto` and `SystemDefaultTlsVersions` (restart required). SChannel and FIPS are reported. |
| `Options.CoManagement` | Enable `true` | Intune Windows Update policy left on a ConfigMgr-managed device; MDM enrollment failures | Report only |
| `Options.SecureChannel` | Enable `true` | Broken domain secure channel | Report only |
| `Options.ScriptPolicy` | Enable `true` | Group Policy execution policy AllSigned/Restricted; PowerShell not in Full Language mode | Report only |
| `Options.SiteCommunication` | Enable `true` | CMG and certificate errors in LocationServices.log and CcmMessaging.log since the last run | Report only |
| `Options.PkiCertificate` | Enable `false`, Days `30` | No valid PKI client authentication certificate, or one that expires within `Days` (PKI/HTTPS sites) | Report only |
| `Options.ClientIdentity` | Enable `true` | Cloned client: SMSCFG.ini and WMI client IDs differ, or client certificates older than the OS install | Report only |
| `Options.DeliveryOptimization` | Enable `true` | Delivery Optimization service disabled or in bypass mode | Report only |
| `Options.InstallerCache` | Enable `true`, Fix `true` | Missing cached MSI in `%windir%\Installer` for the ConfigMgr client, Microsoft Policy Platform, and the Visual C++ runtimes. A missing cache makes upgrades and repairs fail with 1612. | Client: reinstall with `/forceinstall`. Policy Platform: recache from the management point when the MSI versions match. Visual C++: repaired by `VCRuntime`. |
| `Options.VCRuntime` | Enable `true`, Fix `true` | Visual C++ 2015-2022 runtime missing, older than 14.28.29914, runtime DLL missing, or cached installer missing | Install or repair from the management point (`CCM_Client\x64` / `i386`) when its version is not older than the installed one |

All downloads from the management point must have a valid Microsoft Authenticode signature.

**Device opt-out:** when `HKLM\Software\Microsoft\CCM\CcmEval\NotifyOnly` is `TRUE`, the script runs every check in monitor mode and changes nothing on the device.

### Service Monitoring

The `Services` array defines Windows services to monitor. Each entry specifies the desired state:

```json
"Services": [
    { "Name": "BITS",         "StartupType": "Manual|Automatic|Automatic (Delayed Start)", "State": "", "Uptime": "" },
    { "Name": "winmgmt",      "StartupType": "Automatic",                 "State": "Running", "Uptime": "" },
    { "Name": "wuauserv",     "StartupType": "Manual|Automatic|Automatic (Delayed Start)", "State": "", "Uptime": "" },
    { "Name": "lanmanserver", "StartupType": "Automatic",                 "State": "Running", "Uptime": "" },
    { "Name": "RpcSs",        "StartupType": "Automatic",                 "State": "Running", "Uptime": "" },
    { "Name": "W32Time",      "StartupType": "Automatic",                 "State": "Running", "Uptime": "" },
    { "Name": "ccmexec",      "StartupType": "Automatic (Delayed Start)", "State": "Running", "Uptime": "" }
]
```

| Property | Values | Description |
|----------|--------|-------------|
| `Name` | Service short name | Must be alphanumeric with hyphens, underscores, or dots |
| `StartupType` | `Automatic`, `Automatic (Delayed Start)`, `Automatic (Trigger Start)`, `Manual`, `Disabled`. Separate accepted values with `\|`. | Accepted startup types. When the current type is not in the list, the first one is set. |
| `State` | `Running`, `Stopped`, or empty | Desired service state. Empty leaves the state unchanged. |
| `Uptime` | Empty string or integer | If set to a number of days, the service is restarted when uptime exceeds that value |

You can add any Windows service to this list. The script will set the startup type and start/stop the service as configured. A listed service that does not exist is reported as `Missing: <name>`. BITS and wuauserv accept Manual: Windows starts them on demand, and the ConfigMgr client health check accepts Manual or Automatic for both.

### Remediation

| JSON Path | Type | Default | Description |
|-----------|------|---------|-------------|
| `Remediation.AdminShare` | bool | `true` | Restart the Server service when ADMIN$ or C$ is missing, on client OS only. Servers and shares disabled by `AutoShareWks`/`AutoShareServer` are reported. |
| `Remediation.ClientProvisioningMode` | bool | `true` | Leave provisioning mode through `SMS_Client.SetClientProvisioningMode`, after the client's own 48-hour window |
| `Remediation.ClientStateMessages` | bool | `true` | Send state messages that are unsent for more than 1 hour |
| `Remediation.ClientWUAHandler.Fix` | bool | `true` | When registry.pol has no valid `PReg` header, or WUAHandler.log reports "overwritten by a higher authority" with 0x87d00692, rename registry.pol, run `gpupdate`, restart CCMExec, and start the update scan and deployment cycles. The log trigger is skipped when a domain controller is the source. |
| `Remediation.ClientWUAHandler.Days` | int | `7` | Minimum days between two registry.pol repairs |
| `Remediation.ClientCertificate` | bool | `true` | Reinstall the client (`/forceinstall`) when ClientIDManagerStartup.log reports a missing certificate since the last run |

### Site-Aware Configuration

For multi-site deployments, the `Sites` section provides per-site overrides. The script detects the client's AD site name via `Win32_NTDomain` and resolves configuration in this order:

1. `Sites.<ADSiteName>` -- exact site match
2. `Sites.Default` -- catch-all for VPN/ZPA/unknown sites
3. Top-level config values -- final fallback

```json
"Sites": {
    "NYC-Office":  {
        "SQLServer": "sql-nyc01.contoso.com",
        "ManagementPoints": [ "mp-nyc01.contoso.com", "mp-nyc02.contoso.com" ],
        "LogShare": "\\\\dp-nyc01\\ClientHealthLogs$"
    },
    "LAX-Office":  {
        "SQLServer": "sql-lax01.contoso.com",
        "ManagementPoints": [ "mp-lax01.contoso.com" ]
    },
    "Default":     {}
}
```

You can override `SQLServer`, `ManagementPoints`, `MPHttps` and `LogShare`. Most people use it for `ManagementPoints`, so each site reinstalls from its local MPs instead of going across the WAN.

---

## Health Checks

The checks run in this order. Each one logs its result and fixes the problem if its config option allows it.

| # | Check | What It Detects | Remediation | Config |
|---|-------|-----------------|-------------|--------|
| 1 | **WMI Repository** | Inconsistent repository (`winmgmt /verifyrepository` exit code 1358) | Back up, salvage, reinstall the client. Never resets the repository. | `Options.WMI` |
| 2 | **Compliance State** | Stale compliance evaluation | Triggers `RefreshServerComplianceState()` | `Options.RefreshComplianceState` |
| 3 | **CM Client Installed** | Client not installed, `SMS_Client` unreachable, service won't start | Picks an MP from `Client.ManagementPoints` (random, retries the next on failure), downloads a signed `ccmsetup.exe`, reinstalls with `/mp:` listing all MPs, `SMSMP=`, `SMSMPLIST=`, and `/forceinstall` when the client must be removed first. Reads the result from ccmsetup.log. | `Client.ManagementPoints`, `Client.MPHttps`, `Client.Version`, `Client.AutoUpgrade` |
| 4 | **Client Version** | Agent below minimum version | Upgrade via ccmsetup.exe | `Client.Version`, `Client.AutoUpgrade` |
| 5 | **Services** | Wrong startup type, not running, uptime exceeded | Set startup type, start/stop service | `Services` array |
| 6 | **Site Code** | Assigned to wrong site | Reassign via `SMS_Client.SetAssignedSite()` | `Client.SiteCode` |
| 7 | **Cache Size** | Cache too small or too large | Set via COM object (supports MB or percentage). Report only when a client setting configures the cache size. | `Client.Cache` |
| 8 | **Log Size** | CCM log files too small/large | Update registry `HKLM:\SOFTWARE\Microsoft\CCM\Logging\@GLOBAL` | `Client.Log` |
| 9 | **Provisioning Mode** | Client in provisioning mode beyond its 48-hour window | `SMS_Client.SetClientProvisioningMode` | `Remediation.ClientProvisioningMode` |
| 10 | **Client Certificate** | Missing client certificate or rejected registration since the last run | Client reinstall for a missing certificate; a rejected registration is reported | `Remediation.ClientCertificate` |
| 11 | **Hardware Inventory** | Inventory not run in configured days | Trigger schedule `{00000000-0000-0000-0000-000000000001}` | `Options.HardwareInventory` |
| 12 | **Software Metering** | PrepDriver errors since the last run | Reinstall prepdrv.inf, restart CCMExec | `Options.SoftwareMetering` |
| 13 | **DNS** | FQDN mismatch, DNS IPs not in local config | Re-register DNS (`ipconfig /registerdns`) | `Options.DNSCheck` |
| 14 | **BITS** | Jobs in `Error` state older than `Days` | Remove those jobs | `Options.BITSCheck` |
| 15 | **Client Settings** | Orphaned task-sequence policies | Remove `CCM_ClientAgentConfig` where `PolicySource = "CcmTaskSequence"` | `Options.ClientSettingsCheck` |
| 16 | **WUA Handler** | registry.pol without a valid `PReg` header; "Overwritten by a higher authority" with 0x87d00692 since the last run; Group Policy errors (reported) | Rename registry.pol, `gpupdate`, restart CCMExec, scan and deployment cycles | `Remediation.ClientWUAHandler` |
| 17 | **State Messages** | State messages unsent for more than 1 hour | Send unsent state messages (schedule 111) | `Remediation.ClientStateMessages` |
| 18 | **Admin Shares** | ADMIN$ / C$ missing | Restart Server service on client OS; report on servers | `Remediation.AdminShare` |
| 19 | **Missing Drivers** | Faulty PnP devices (error code != 0, 22) | Report only | `Options.Drivers` |
| 20 | **OS Updates** | Missing patches (from share) | Install with DISM from configured update share | `Options.Updates` |
| 21 | **Disk Space** | OS drive below threshold | Report only | `Options.OSDiskFreeSpace` |
| 22 | **Pending Reboot** | CBS, Windows Update, SCCM SDK | Start the reboot application when a reboot is pending or uptime is longer than `MaxRebootDays`. Never reboots on its own. | `Options.PendingReboot`, `Options.MaxRebootDays` |
| 23 | **Orphaned Cache** | Cache folders not tracked by CM | Delete orphaned folders | `Client.Cache.DeleteOrphanedData` |
| 24 | **CCMSETUP AppData** | SYSTEM profile AppData path incorrect | Fix registry value | Always runs |
| 25 | **SMSTSMgr Dependency** | SMSTSMgr depends on CCMExec | Report only (changing ConfigMgr service configuration is not supported) | Always runs |
| 26 | **Extended checks** | See [Extended Checks](#extended-checks) | Per check | `Options.<Name>` |

At the end it resends state messages, starts the update source and scan cycles and machine policy evaluation, and restarts CCMExec if a check asked for it. Then it writes `LastRun` to `HKLM:\Software\ConfigMgrClientHealth`. The exit code is 1 if a client install or the result upload failed, otherwise 0.

---

## Deployment Methods

### Option A: Configuration Baseline (Recommended)

Use this one if you can. The script and config live on the client, so it still runs when the client is off the network.

The setup wizard creates all of this for you. To do it by hand:

**Step 1: Create a CM Package**

Create a Package with source directory containing:
- `ConfigMgrClientHealth.ps1`
- `config.json`
- `Deploy-ClientHealthPackage.ps1`

Create a Program:
```
powershell.exe -ExecutionPolicy Bypass -File Deploy-ClientHealthPackage.ps1
```
This copies the script and config to `%ProgramData%\ConfigMgrClientHealth\` on each client. The program restricts that folder to SYSTEM and Administrators, and exits with code 1 if a file does not copy.

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

Remediation script: use the full content of `Deploy/CI-Remediation.ps1`. It checks that SYSTEM or Administrators own the folder, the script, and the config; if they do not, it exits with code 1 and runs nothing. It then starts the health check in the scheduled task `ConfigMgr Client Health` (SYSTEM, 2-hour limit) and returns at once. The client stops a compliance script after the client setting **Script execution timeout** (60 seconds by default, 600 at most), and a health run or a client reinstall takes longer. Detection reports compliant after the task updates `LastRun`. The setup wizard updates these scripts in an existing configuration item.

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

B and C need the share to be reachable when the script runs. A doesn't.

---

## Logging and Reporting

There are four places results can go. Turn on whichever ones you want.

### Local File Logging

- **Config:** `Logging.LocalLogFile = true`
- **Location:** `<LocalFiles>\ClientHealth.log` (`C:\ProgramData\ConfigMgrClientHealth\ClientHealth.log` with a wizard config)
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
- **Format:** JSON (UTF-8)
- **Authentication:** The client sends the computer account credentials (`-UseDefaultCredentials`)
- Clients don't need access to SQL.

---

## API Reference

The API is optional. It's a small ASP.NET Core app that runs as a Windows service, no IIS.

### Endpoints

| Method | Path | Access | Description |
|--------|------|--------|-------------|
| `GET` | `/` | Anonymous | Health check -- returns `{ Status, Version, Timestamp }` |
| `GET` | `/api/Clients` | Admin group | List clients (paginated: `?skip=0&take=50`, `take` is 1-1000) |
| `GET` | `/api/Clients/{hostname}` | Admin group | Get a specific client record |
| `POST` | `/api/Clients` | Own computer account or admin group | Create or update a client (UPSERT) |
| `PUT` | `/api/Clients/{hostname}` | Own computer account or admin group | Update an existing client |
| `DELETE` | `/api/Clients/{hostname}` | Admin group | Delete a client record |

The API accepts a record only for the computer account that sends it: `DOMAIN\PC01$` can write the record `PC01` only. Values that do not fit the database are corrected before the write: long strings are shortened to the column length, and dates outside the `smalldatetime` range become NULL.

### Configuration

Edit `Webservice/ClientHealthApi/appsettings.json`:

```json
{
  "Authentication": {
    "Mode": "Negotiate",
    "AdminGroup": "CONTOSO\\ClientHealth Admins"
  },
  "ConnectionStrings": {
    "ClientHealth": "Server=sccmdbs.contoso.com;Database=ClientHealth;Trusted_Connection=True;TrustServerCertificate=True;"
  }
}
```

| Setting | Values | Default | Description |
|---------|--------|---------|-------------|
| `Authentication:Mode` | `Negotiate`, `None` | `Negotiate` | `None` disables authentication. Any caller can then read, change, or delete records. |
| `Authentication:AdminGroup` | Windows group | `BUILTIN\Administrators` | Members can read and delete all records and write any record. |

The service account needs `db_datareader` and `db_datawriter` on the `ClientHealth` database. The wizard installs the service as LocalSystem, so grant access to the computer account of the API server (`DOMAIN\SERVER$`).

### Installation

The wizard does this for you. By hand:

```powershell
# Publish self-contained
dotnet publish Webservice/ClientHealthApi/ClientHealthApi.csproj -c Release -o 'C:\Program Files\ClientHealthApi' --self-contained -r win-x64

# Install as Windows Service
New-Service -Name ClientHealthApi -BinaryPathName '"C:\Program Files\ClientHealthApi\ClientHealthApi.exe" --urls=http://*:5000' -StartupType Automatic
New-NetFirewallRule -DisplayName 'ConfigMgr Client Health API (TCP 5000)' -Direction Inbound -Protocol TCP -LocalPort 5000 -Action Allow -Profile Domain
Start-Service ClientHealthApi
```

It can run on any Windows server. It doesn't have to be the site server or the SQL server.

### Example Usage

```powershell
# Query a specific client
Invoke-RestMethod -Uri 'http://sccm01:5000/api/Clients/WORKSTATION-01' -UseDefaultCredentials

# List all clients (first 50)
Invoke-RestMethod -Uri 'http://sccm01:5000/api/Clients?take=50' -UseDefaultCredentials

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
| `Timestamp` | datetime | Record last updated, in the client's `Logging.TimeFormat` (the API uses server UTC only when the client sends no value) |
| `HWInventory` | smalldatetime | Last HW inventory |
| `SWMetering` | varchar(50) | Software metering status |
| `BITS` | varchar(50) | BITS service status |
| `PatchLevel` | int | Windows UBR |
| `ClientInstalledReason` | varchar(200) | Why client was reinstalled |
| `Findings` | varchar(1000) | Report-only results of the checks, separated by `; ` |

---

## Migrating from XML to JSON

XML still works, so there's no rush. When you want to switch, convert it:

```powershell
.\Convert-ConfigXmlToJson.ps1 -XmlPath .\config.xml
```

Test the result with `-Config config.json -Verbose` on one machine before you deploy it.

The converter writes `Client.ManagementPoints` from the `MP=`, `SMSMP=`, or `/mp:` install properties and removes those properties. It does not copy `Client.Share`. If it finds no management point, it shows a warning; add `Client.ManagementPoints` before you deploy the output.

### Deprecated fields

| Field | Status | Replacement |
|-------|--------|-------------|
| `Client.Share` (and `<ClientShare>` in XML) | Deprecated. Setting it triggers a warning at reinstall. | Configure `Client.ManagementPoints` instead. `ccmsetup.exe` is downloaded directly from the selected MP -- no UNC share required. |
| `SMSMP=` / `MP=` / `/mp:` in `ClientInstallProperties` | Honored only as a legacy fallback when `Client.ManagementPoints` is missing. | Move MPs into `Client.ManagementPoints`. The script injects the picked MP into the `ccmsetup.exe` command line at runtime. |

---

## Remediation Testing (Break Scripts)

`Tests/BreakScripts/` has scripts that break specific things on a lab client, so you can watch the health check find and fix each one.

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
| `Break-LogSize.ps1` | Sets CCM log max size to 100 bytes and history to 0 via registry | Log size and history correction |
| `Break-ProvisioningMode.ps1` | Enables provisioning mode via registry | Provisioning mode detection and exit |
| `Break-AdminShares.ps1` | Deletes the ADMIN$ and C$ shares (`net share /delete`) | Admin share re-creation via Server service restart |
| `Break-HWInventory.ps1` | Deletes the hardware inventory timestamp from WMI | Stale inventory detection and scan trigger |
| `Break-WUAHandler.ps1` | Overwrites `registry.pol` with a zero-byte file and backdates it 60 days | Corrupt registry.pol detection, `gpupdate` repair |
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

Green is OK, red is broken, yellow is a warning. Keep the output so you can compare later.

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

`-Verbose` shows each problem as it's found and fixed.

**Step 5: Verify remediation**

```powershell
.\Tests\BreakScripts\Get-HealthState.ps1
```

Everything should be green again. Some fixes are asynchronous: hardware inventory, for example, can take a second health run to show up, especially after a site code change. If something stays red, look in `ClientHealth.log` in the `LocalFiles` folder.

### What they don't break

They don't touch disks, boot config, system files, DNS records, the WMI repository, or the client install. WMI repair and client reinstall are worth testing, but do that by hand on a VM you can roll back.

---

## Troubleshooting

### Script doesn't run / exits immediately

- **Not running as Administrator:** The script requires local admin or SYSTEM context. Check with `whoami /priv`.
- **Task sequence detected:** The script exits (code 2) if it detects an active OSD task sequence to avoid interference.
- **Config file not found:** Verify the `-Config` path is accessible. Check share permissions.

### Client keeps reinstalling

- **Version mismatch:** The minimum version in config (`Client.Version`) must match what's available. Check `Client.AutoUpgrade` setting.
- **WMI corrupt:** After a WMI salvage the client is reinstalled. Check the `WMI` status in the log.
- **Client cache missing:** A missing cached client MSI in `%windir%\Installer` triggers a `/forceinstall` reinstall. Check the `InstallerCache` finding.

### SQL logging not working

- **Connectivity:** Verify the SQL server is reachable from the client. The script uses Windows Authentication -- the computer account needs `db_datareader` and `db_datawriter` on the `ClientHealth` database.
- **Modules:** The client script uses the .NET SQL client and needs no PowerShell module. The setup wizard needs the `SqlServer` or `SQLPS` module to create the database.

### Client reinstall does not start

- **Signature check failed:** The log shows `ccmsetup.exe signature status is ...`. The file from the management point is not a valid Microsoft-signed file. Check the `CCM_Client` folder on the management point and any proxy between the client and the management point.
- **No management point:** Set `Client.ManagementPoints` in the config.
- **Protected folder:** The log shows `Could not create a protected download folder`. Check the permissions of `%ProgramData%\ConfigMgrClientHealth`.

### Config caching

- **Cache location:** `%ProgramData%\ConfigMgrClientHealth\config.json.cache`
- **When written:** Only after the config passes validation.
- **When used:** The cached copy is loaded automatically when the network config path is unreachable (VPN disconnect, share offline). The script ignores the cache if the folder is not restricted to SYSTEM and Administrators.
- **Force refresh:** Delete the cache file to force a fresh load on next run.

### Baseline shows non-compliant

- **Package not deployed:** The CI remediation script expects files at `%ProgramData%\ConfigMgrClientHealth\`. Deploy the staging package first.
- **Untrusted folder:** The CI remediation log shows `is not owned by SYSTEM or Administrators`. Rerun the package program. It secures the folder and restages the files.
- **Script errored:** Check the local log at `<LocalFiles>\ClientHealth.log` (CMTrace format).
- **7-day window:** Detection checks if `LastRun` is within 7 days. If the baseline evaluates before the package deploys, it will show non-compliant until the next cycle.

### Log files

| Log | Location | Format |
|-----|----------|--------|
| Client local | `<LocalFiles>\ClientHealth.log` | CMTrace |
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
- **Jason Ulbright** -- this fork
