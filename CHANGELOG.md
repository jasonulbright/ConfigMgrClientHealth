# Changelog

## [0.8.4] - 2026-10-01

113 changes since 0.8.3, including 14 new client health checks.

### Upgrading
- The IIS webservice is replaced by a new API. The old one won't work with this version.
- Update the clients and the API together. Older clients can't authenticate to the new API.
- Run the setup wizard again. It updates the database, package and CI in place.
- Give the API server's computer account access to the ClientHealth database.
- Missing `Options` blocks in your config fall back to the defaults in the README.
- 1.0.0 through 1.0.3 were pulled. This release replaces them.

### Security
- SQL writes use parameters instead of string-built queries.
- No more `Invoke-Expression`. Config values are validated, and paths only expand environment variables.
- Downloaded installers only run with a valid, unrevoked Microsoft signature.
- Fixed privilege escalation in the local staging and download folders, and cleanup no longer follows links.
- The API requires Windows authentication by default and checks the SQL server certificate when it can.
- Only domain computers can write to the log share.

### New
- JSON config, per-AD-site overrides, and a cached copy for clients that are offline.
- Setup wizard for the database, shares, package, CI, baseline and API.
- A self-hosted API instead of the IIS webservice, plus a Findings column for things a person should look at.
- Break scripts for testing on a lab client, and an XML to JSON converter.
- `NotifyOnly=TRUE` on a device turns the script into report-only mode there.
- New checks: CcmEval task, client activity, Windows Update source and scan errors, TLS and .NET strong crypto, co-management, secure channel, script policy, CMG and PKI certificates, cloned client IDs, Delivery Optimization.
- Missing MSI caches get rebuilt: the client by a reinstall, Policy Platform from the MP.
- A missing or broken VC++ runtime gets installed or repaired from the MP.

### Client fixes
- The CI starts the health run as a scheduled task, so the 60 second compliance script timeout no longer kills it.
- WMI: salvage instead of reset, and a failed query is reported instead of "repaired".
- A missing client certificate or a broken client WMI namespace now means a reinstall. Key files and the namespace are left alone.
- registry.pol is only renamed when it's corrupt or WUAHandler logs the documented error, at most once a week. Group Policy errors are reported.
- BITS service permissions are no longer touched. Only failed jobs older than a week are removed.
- Provisioning mode is cleared through WMI, and only after the client's own 48 hour window.
- The cache size from your client settings wins over the config.
- ccmsetup gets every MP, the HTTPS prefix when you use it, and `/forceinstall` instead of a separate uninstall. Its result comes from ccmsetup.log.
- The client is reinstalled at most once per run, the script stops waiting on ccmsetup after an hour, and it skips the client WMI check while ccmsetup is running.
- Admin shares and the task sequence service dependency are reported on servers instead of changed.
- A low client database file count and CcmSQLCE.log activity are reported, not used as a reason to reinstall.
- Only state messages that have been stuck for over an hour are resent.
- Updates install through DISM, so checkpoint updates work.
- BITS and Windows Update are fine on Manual startup.
- Windows 11, Server 2022 and Server 2025 are detected, and current Windows builds map to the right update folders.
- Disabled settings are respected for orphaned cache cleanup, compliance refresh and four other checks.
- Pending reboot and reboot app checks work with JSON config, and component servicing reboots are detected.
- SQL writes retry, store zeros as zeros, and send dates independent of the server's language. The last install time is kept when a run doesn't reinstall.
- Exit code 1 when a client install or the result upload fails.
- Plenty of smaller fixes: version comparison, missing services, services set to Stopped, DNS registration policy, log size minimum, locale-safe reboot app task, UTF-8 webservice posts, and dead code removed.

### API fixes
- Records with empty numbers or dates are accepted, and over-long values are shortened instead of rejected.
- Hostnames that differ only in case or trailing spaces are treated as the same machine.
- Two first reports from the same machine at the same time no longer fail.
- The client's time stamp is stored, same as the SQL path. List pages are capped at 1000 records.

### Setup fixes
- Tables are created in the ClientHealth database, not wherever the connection landed.
- A rerun updates the CI scripts, DP content and deployments without creating a second baseline deployment.
- The staging program reruns every time and runs outside maintenance windows.
- A partly created CI is removed, and deployment failures are reported.
- The API service is installed with a correct path, and its port and firewall rule are updated on a rerun.
- Nothing is staged when a package source file is missing, and a staged script owned by a non-admin won't run.
- A local server given by FQDN is detected, and unattended mode validates every value.
- The XML converter moves MP settings to the new management point list.

---

## [0.8.3] - 2023 (Original by Anders Rodland)

### Fixed
- Client max log history setting
- Client cache size setting
- ClientInstallProperty /skipprereq parsing with semicolons
- Defender signature update exclusion criteria

### Changed
- Debug logging enabled by default in webservice
