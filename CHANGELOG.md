# Changelog

## [1.0.2] - 2026-03-30

### Added
- **Remediation break scripts** -- 12 scripts in `Tests/BreakScripts/` that intentionally introduce specific health issues on lab endpoints for validation testing. Includes `Break-All.ps1` for full end-to-end testing and `Get-HealthState.ps1` for read-only pre/post comparison. Safety-gated behind `$env:YOURLAB = 'true'`.
- **README: Remediation Testing section** -- full testing workflow documentation with step-by-step instructions, script reference table, safety notes, and scope limitations.

---

## [1.0.1] - 2026-03-30

### Added
- **Automated setup wizard** -- `Deploy/Install-ClientHealth.ps1` guides through environment setup, generates config.json, creates the ClientHealth SQL database, provisions all MECM objects (Package, Program, CI, Baseline, deployments), and optionally installs the REST API webservice as a Windows Service. Supports interactive and unattended modes.
- **51 Pester tests** for the setup wizard -- config generation, function contracts, security, compatibility with the main script.
- **ccmsetup.exe download from MP** -- `Resolve-Client` now downloads a fresh `ccmsetup.exe` from `http://<MP>/CCM_Client/ccmsetup.exe` when `Client.Share` is empty or unreachable, avoiding reliance on potentially corrupt local files.

### Changed
- **ClientInstallProperties corrected per Microsoft docs** -- replaced undocumented `MP=` with documented `SMSMP=` (client.msi property for initial management point). `/mp:` ccmsetup parameter retained for installation source. Removed `/Source:` (unnecessary) and `/skipprereq:silverlight.exe` (obsolete).
- **Comprehensive README** -- full configuration reference, all 25 health checks documented, API reference, deployment walkthroughs, troubleshooting guide.

### Fixed
- **CI creation used nonexistent cmdlets** -- replaced `New-CMComplianceSettingScript` / `Add-CMComplianceSettingScript -Setting -Rule` (don't exist) with single `Add-CMComplianceSettingScript` call using `-ValueRule` parameter set, verified against Microsoft docs.
- **`Resolve-Client` would `Exit 1` with empty `Client.Share`** -- the original script required a file share with ccmsetup.exe staged. Now gracefully falls back to MP download.

---

## [1.0.0] - 2026-03-30 (Community Fork)

### Security (Critical)
- **SQL injection eliminated** -- `Update-SQL` rewritten with `SqlParameter` objects. `Invoke-Sqlcmd2` extended to accept `-SqlParameters`. All 39 log properties are parameterized.
- **Command injection eliminated** -- 3 `Invoke-Expression` calls replaced with `Start-Process -ArgumentList` (ccmsetup.exe) and `& operator` (sc.exe). Backtick-semicolon escaping removed.
- **Config input validation** -- `Test-ConfigValues` validates service names, site codes, and domains against regex patterns before use in WMI filters.

### Added
- **JSON configuration** -- `config.json` with cleaner structure, native types, and array-based install properties. XML backward compatibility preserved.
- **Site-aware configuration** -- `Get-SiteConfig` resolves per-site overrides (SQLServer, ClientShare, LogShare) from AD site detection via `Win32_NTDomain`.
- **Config caching** -- Last-known-good JSON config cached to `%ProgramData%\ConfigMgrClientHealth\`. Falls back to cache when network config unreachable.
- **Retry logic** -- `Invoke-WithRetry` helper (3 attempts, 5s delay) applied to SQL writes.
- **Consolidated trigger function** -- `Invoke-CCMTrigger -ScheduleID` replaces 5 separate trigger functions.
- **77 Pester tests** -- Security, CIM migration, error handling, JSON config, site-aware, caching, SQL schema alignment.

### Changed
- **Full CIM migration** -- All 55 `Get-WmiObject` replaced with `Get-CimInstance`. All `Invoke-WmiMethod` replaced with `Invoke-CimMethod`. All `[wmiclass]` replaced with `Invoke-CimMethod`. `$PowerShellVersion` branching removed.
- **Error handling** -- All empty `catch{}` blocks now log via `Write-Verbose` or `Write-Warning`.
- **`-Config` parameter** accepts both `.xml` and `.json` extensions.

### Removed
- `$PowerShellVersion` variable and all PS version branching (CIM works on PS 5.1+)
- `Invoke-Expression` usage (security risk)
- String-concatenated SQL queries (injection risk)
- 5 duplicate trigger functions (consolidated into `Invoke-CCMTrigger`)

---

## [0.8.3] - 2023 (Original by Anders Rodland)

### Fixed
- Client max log history setting
- Client cache size setting
- ClientInstallProperty /skipprereq parsing with semicolons
- Defender signature update exclusion criteria

### Changed
- Debug logging enabled by default in webservice
