# Changelog

## [1.0.3] - 2026-04-30

### Changed
- **MP-only ccmsetup resolution** -- `Resolve-Client` no longer reads `Client.Share` when sourcing `ccmsetup.exe`. Configure `Client.ManagementPoints` (array of MP FQDNs) and the script picks one at random, downloads from `http(s)://<MP>/CCM_Client/ccmsetup.exe`, retries the next MP on failure, and injects `SMSMP=`/`/mp:` into the install args at runtime so MPs are maintained in one place.
- **`Client.MPHttps`** -- new boolean controls HTTP vs HTTPS for the ccmsetup download. Defaults to HTTP.
- **`Client.Share` deprecated** -- still read for back-compat warning, never used as a download source. Setting it now emits a deprecation warning at reinstall.
- **Setup wizard** -- prompts for comma-separated MP list and HTTPS y/n. Generated `config.json` writes `Client.ManagementPoints` + `Client.MPHttps`, drops `SMSMP=`/`/mp:` from `ClientInstallProperties` (script injects them at runtime). Wizard validates MP inputs (rejects URL-shaped or whitespace-laden values, rejects empty arrays).
- **Per-site MP overrides** -- `Sites.<ADSiteName>.ManagementPoints` and `Sites.<ADSiteName>.MPHttps` honored via `Get-SiteConfig`, so each AD site picks from its local MPs without bouncing across WAN.

### Added
- **Multi-MP random pick with iterate-on-failure** -- a single down MP no longer fails the install if a peer is reachable.
- **Legacy MP fallback** -- when `Client.ManagementPoints` is missing, the script scrapes any `MP=`, `SMSMP=`, or `/mp:` token from `ClientInstallProperties` so existing configs still work pre-migration.
- **`Test-ConfigValues` validates Management Points** -- rejects URL-shaped or malformed FQDNs in JSON, site overrides, and the legacy fallback path before they can become download URLs or ccmsetup args.
- **`ClientHealthDateTimeConverter`** -- API JSON converter accepts the client's `yyyy-MM-dd HH:mm:ss` timestamp format. The minimal-API default JSON binder previously rejected client posts with a 400 before SQL ever saw the row.
- **`ConvertTo-ConfigBoolean`** helper -- handles the PowerShell `[bool]'False' -> $true` trap when reading XML/JSON booleans.

### Fixed
- **JSON config cache fallback was unreachable** -- removed the `[ValidateScript({Test-Path})]` attribute on `-Config` so a missing remote config file no longer blocks param binding before the cache lookup runs.
- **JSON `LocalFiles` was ignored** -- `Get-LocalFilesPath` always read the XML path; now correctly checks `$script:JsonConfig.LocalFiles` first and falls back to the SystemDrive default when blank.
- **Webservice URL trailing slash** -- `Update-Webservice` now `TrimEnd('/')` before appending the API route, so `-Webservice http://host:5000/` and `-Webservice http://host:5000` both produce a clean `http://host:5000/api/Clients`.
- **`ccmsetup.exe` could be run from a phantom path** -- old code accepted any directory that existed at `Client.Share` and assumed `ccmsetup.exe` was inside; now verifies the binary is actually present before using it (and the share path is gone entirely from the resolve flow).
- **SQL migration block** -- `Drivers` column migration was paired with `ALTER COLUMN Build` (re-altering Build twice, never altering Drivers); fixed. DNS / Updates / Services migrations checked `CHARACTER_MAXIMUM_LENGTH = 100` while ALTERing to `200`, making them re-run on every execution; fixed by matching WHERE to the new size. Nullable columns aligned with the original CREATE TABLE schema.
- **Stripped legacy MP tokens at install time** -- `Resolve-Client` strips `SMSMP=`, `MP=`, and `/mp:` from `ClientInstallProperties` before injecting the picked MP, so legacy configs don't end up sending two different MPs to ccmsetup.

### Removed
- **Three stranded webservice helpers** -- `Get-ConfigFromWebservice`, `Get-ConfigClientInstallPropertiesFromWebService`, `Get-ConfigServicesFromWebservice`. Defined but never called; targeted routes (`/ConfigurationProfile*`) don't exist on the .NET 10 API surface.

---

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
