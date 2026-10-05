# StorSafe Monitoring

A self-contained package that monitors FalconStor StorSafe (VTL and deduplication) appliances using a PowerShell collector, windows_exporter, Prometheus and Grafana, all on one Windows host. It talks to the appliances' REST API only; nothing is installed on them. Not affiliated with FalconStor. Every StorSafe API call it makes is read-only: GETs, plus login/logout, plus one `PUT /server/event` that only downloads the event log as CSV and changes nothing.

```
StorSafe API --(Export-StorSafeMetrics.ps1, every 5 min)--> metrics\storsafe.prom
   --> windows_exporter :9182 --> Prometheus 127.0.0.1:9090 --> Grafana :3000 (dashboard + alerts)
```

## Layout

| Path | Contents |
|---|---|
| `VERSION`, `CHANGELOG.md` | Package version and what changed between versions |
| `Install-StorSafeMonitoring.ps1` | One-shot installer (idempotent, safe to re-run) |
| `Get-StorSafeInstallers.ps1` | Downloads the three third-party installers into `installers\` |
| `StorSafeMonitoringControl.ps1` | Status / Stop / Start / Pause / Resume of the whole stack, for maintenance |
| `StorSafe.psm1` | Shared API client |
| `StorSafe.config.json` | Appliances and settings. **Edit the Servers list before installing.** |
| `Export-StorSafeMetrics.ps1` | Metrics collector (run by the scheduled task) |
| `Get-StorSafeActivity.ps1`, `Get-StorSafeLoadedTapes.ps1` | Ad-hoc CSV/console reports |
| `metrics\` | windows_exporter textfile directory (`storsafe.prom`, plus `storsafe-<server>.prom` per appliance in parallel mode) |
| `reports\` | CSV output of the Get-* scripts (30-day retention) |
| `creds\` | DPAPI credential files (created by the installer) |
| `installers\` | Put the third-party installers here (see `installers\README.txt`) |
| `state\` | Collector state: event log bookmark/counters and cached hourly checks (safe to delete) |
| `events\` | Raw event log, one CSV per appliance per day (90-day retention) |
| `prometheus\` | Created at install: Prometheus binaries, config and data |
| `monitoring\` | prometheus.yml, Grafana provisioning, dashboard JSON, task registration script |

## Install on a new Windows machine

What you need:

- Windows 10/11 or Windows Server 2016 or later, 64-bit, with Windows PowerShell 5.1 (built in). About 2 GB of disk for the stack plus Prometheus data (roughly 50 MB per appliance per month at the default 180-day retention).
- A local Administrator account for the install, and the account the collector will run as (it can be the same one; the installer asks for its password so the scheduled task runs while logged off).
- Network access from this machine to every appliance on the API port (https 443 by default) and, for the installer download step only, to github.com and grafana.com (or the three installer files copied in by hand).
- For each appliance, an API account. A read-only (type R) account is recommended.

Steps, from an elevated cmd prompt (right-click Command Prompt > Run as administrator), logged on as the account that will run the collector:

1. Extract the release zip and copy the `StorSafeMonitoring` folder to a path **without spaces**, e.g. `C:\StorSafeMonitoring` (or, with git on the machine, `git clone https://github.com/triippiing/storsafe-monitoring.git C:\StorSafeMonitoring`; the checkout is the package). The windows_exporter MSI can't handle spaces in the metrics path, so the installer refuses to run from such a folder.
2. Get the third-party installers into `installers\`:
   ```
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\StorSafeMonitoring\Get-StorSafeInstallers.ps1
   ```
   (add `-Proxy http://proxy:port` if the machine needs one; with no internet access, download the three URLs it prints on another machine and copy the files in).
3. Copy `StorSafe.config.example.json` to `StorSafe.config.json` (the installer does this for you if the file is missing, then stops so you can edit it) and fill in the `Servers` list: a name, IP or hostname, and credential file name per appliance. Under `Defaults`, check `Scheme` and `SkipCertificateCheck` (true for self-signed appliance certificates). The example shows every setting; the real file is ignored by git.
4. Run the installer:
   ```
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\StorSafeMonitoring\Install-StorSafeMonitoring.ps1
   ```
   It prompts for each appliance's API account, then for the collector account's Windows password. It then installs windows_exporter, Prometheus (as a startup task), Grafana (with the data source and dashboards provisioned) and the collector task, runs the collector once, and prints a summary table. Every step is idempotent: if a step reports a missing installer, add the file and re-run.
5. Check it:
   ```
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\StorSafeMonitoring\StorSafeMonitoringControl.ps1 Status
   ```
   All four components should show Running/Ready and answering. Then open http://localhost:3000 (first login admin/admin, you are asked to change it) and go to **Dashboards > StorSafe**:

- **StorSafe Fleet**: one row per appliance (API up, failed checks, pool used, offline devices, queues, events, replica age), red rows at the top. Click a server name to open its Instance page.
- **StorSafe Activity**: live job tables across the estate: dedupe jobs (server, policy, barcode, state, drive, progress, first seen), replication jobs (source, target, phase, progress), reclamation/prune runs in progress, latest policy run per appliance, import/export.
- **StorSafe Instance**: everything for one appliance, chosen from the Server picker (health, capacity, deduplication, replication, tapes, events, platform, collector). Each appliance has its own URL: `/d/storsafe-instance?var-server=NAME`.
- **StorSafe Patch Management**: product version, build and patch level, installed patches and patch coverage, RHEL release, kernel, make/model, memory, clock offset.
- **StorSafe Events**: warnings, errors and criticals across the estate, with counts over time and a filterable table.

The dashboards are file-provisioned from `monitoring\dashboards\`; deleting a JSON file there removes that dashboard from Grafana.

Ports: Grafana 3000 (all interfaces; put it behind the Windows firewall or bind it to 127.0.0.1 in Grafana's `conf\custom.ini` if only local use is wanted), Prometheus 9090 and windows_exporter 9182 (127.0.0.1 only, nothing to open). Everything restarts by itself after a reboot.

Adding an appliance later: add it to `Servers` in the config, then create its credential file as the collector account:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module C:\StorSafeMonitoring\StorSafe.psm1; New-StorSafeCredentialFile -Path C:\StorSafeMonitoring\creds\NEWNAME.xml"
```

The next collector run picks it up; the Fleet, Activity and Patch pages show it automatically and it appears in the Instance page's server picker.

## Upgrading an existing install

Read `CHANGELOG.md` for what changed, then copy the new files over the install folder, keeping your `StorSafe.config.json` and `creds\`. From an elevated cmd prompt, with the new zip extracted to `C:\Temp\StorSafeMonitoring`:

```
robocopy C:\Temp\StorSafeMonitoring C:\StorSafeMonitoring /E /XF StorSafe.config.json /XD creds
```

Upgrading from v4.x: the Estate and Detail dashboards are replaced by the five above, so delete their JSON files and Grafana drops them within a minute:

```
del C:\StorSafeMonitoring\monitoring\dashboards\storsafe-estate.json C:\StorSafeMonitoring\monitoring\dashboards\storsafe-detail.json
```

Nothing needs restarting. The next collector run picks up the new checks (run it by hand to see the output straight away), and Grafana loads the new dashboard within a minute.

## What the collector reads

Each check is independent: a failure shows as `storsafe_check_success{check="..."} 0` and the rest carry on.

| Cadence | Checks |
|---|---|
| Every run (5 min) | version, time, failover, storagepool, physicaldevice, adapters, storagethreshold, deduperepository, reclamation, dedupepolicy, dedupehistory, dedupeactivity, dedupequeue, dedupejobs, replicationqueue, uniquereplicationqueue, replicationsetting, replicationjobs, virtuallibrary, virtualdrive, tapecaching, physicallibrary, iejob, eventlog |
| Every 15 min | tapeinventory (pages through every virtual tape), tapecachingreclaim |
| Every 60 min | serverinfo, patches, serveroptions, encryption, failoverconfig, network, bonding, ntp, dedupereplication, lvitsource, reclamationpolicy, dedupecleanup, tleproperties, iejobproperties, activitydatabase, clients, fcinitiators, iscsi, hostedbackup, users, objectstorage, syslogalert, autosave |

The 15- and 60-minute checks are cached in `state\` and re-published on the runs in between. `-Refresh` ignores the cache.

Per-job detail (`dedupejobs`, `replicationjobs`) reads one API call per queued job, capped at 100 jobs per appliance per run. The API has no start time for a dedupe job, so the collector records when it first saw each job (`state\jobs-*.json`); reclamation and prune give only idle/running/failed, so the collector tracks their transitions (`state\maintenance-*.json`) to give each run a start, end and duration, accurate to one collector interval.

**Parallel collection.** With more than two appliances the collector runs one child process per appliance, up to `-MaxParallel` at a time (default: 1 for up to two appliances, otherwise one worker per four appliances, at most 8). Each appliance then writes its own `metrics\storsafe-<server>.prom` and `storsafe.prom` carries only the collector summary (`storsafe_collector_server_exit_code{server}`, `storsafe_collector_parallel_processes`, `storsafe_collector_run_duration_seconds`). `-MaxParallel 1` forces the single-process mode. The scheduled task needs no change; windows_exporter reads every `.prom` file in `metrics\`.

Optional settings under `Defaults` in `StorSafe.config.json`:

| Setting | Default | Meaning |
|---|---|---|
| `DisabledChecks` | `[]` | Checks to skip, e.g. `["tapecaching", "objectstorage"]` for features you don't use |
| `CollectEventLog` | `true` | Download new event log entries every run |
| `EventLogDirectory` | `events` | Where the raw daily CSVs go |
| `EventLogRetentionDays` | `90` | Older CSVs are deleted |
| `StateDirectory` | `state` | Collector state |

Not collected on purpose: SNMP settings (they include community strings and passwords), encryption keys, X-ray, failover preflight checks and device rescans (they make the appliance do work), user names, and the system variable list. Hardware sensors aren't in the API; use IPMI/iDRAC or SNMP for those.

The installer steps are:

| # | Step | What it does |
|---|---|---|
| 1 | Credentials | Creates `creds\<server>.xml` for each appliance, readable only by this user on this machine, and restricts the folder ACL |
| 2 | Collector test | Runs the collector once and reports the result |
| 3 | windows_exporter | Silent MSI install with the textfile collector pointed at `metrics\` |
| 4 | Prometheus | Extracts to `prometheus\` and runs at startup as SYSTEM (scheduled task "StorSafe Prometheus"). Listens on localhost only, 180-day retention |
| 5 | Grafana | Silent MSI install, plus a provisioned data source ("StorSafe Prometheus") and dashboard |
| 6 | Collector task | Scheduled task "StorSafe Metrics Collector", every 5 minutes |

Switches:
- `-SkipExporter`, `-SkipPrometheus` or `-SkipGrafana` if the server already runs that component.
- `-IntervalMinutes`, `-PrometheusRetentionDays`.
- `-RunAsUser DOMAIN\svc-account` to run the task as a different account. If you use it, create the credential files while logged on as that account.

## Day-to-day

```powershell
.\Get-StorSafeActivity.ps1                 # interactive: menu + prompts
.\Get-StorSafeActivity.ps1 -All -NonInteractive -IncludeTapeInventory
.\Get-StorSafeLoadedTapes.ps1 -Server STORSAFE-01
.\Export-StorSafeMetrics.ps1 -All -NonInteractive   # manual collector run (-MaxParallel 1 to force one process)
(Get-ScheduledTaskInfo 'StorSafe Metrics Collector').LastTaskResult   # 0 OK, 2 a check failed
```

Exit codes for all scripts: 0 OK/idle, 1 informational (work active, tapes loaded), 2 attention or API error, 3 usage/config error.

A check for a feature you don't use (e.g. `tapecaching`) shows as `storsafe_check_success{check="tapecaching"} 0`. Add it to `DisabledChecks` in the config to stop it running.

## Stopping and starting for maintenance

`StorSafeMonitoringControl.ps1` drives the four components (collector task, Prometheus task, windows_exporter service, Grafana service). From an elevated cmd prompt:

| Situation | Command |
|---|---|
| See what is running | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\StorSafeMonitoring\StorSafeMonitoringControl.ps1 Status` |
| Host maintenance (patching, disk work): stop everything cleanly | `... StorSafeMonitoringControl.ps1 Stop` |
| Afterwards | `... StorSafeMonitoringControl.ps1 Start` |
| An appliance is being patched or rebooted: stop polling so it logs no failed checks or logins | `... StorSafeMonitoringControl.ps1 Pause` |
| Appliance back | `... StorSafeMonitoringControl.ps1 Resume` |

Notes:

- `Stop` disables the collector task, stops Prometheus (its scheduled task), then Grafana and windows_exporter. Nothing restarts until `Start`, not even after a reboot, so a stopped host can't come back half-running. `Start` reverses it and runs the collector once.
- A plain reboot without `Stop` is fine too: the services are Automatic, Prometheus starts at boot, and the collector task resumes its 5-minute schedule. Prometheus replays its write-ahead log at start, which can take a minute or two.
- `Pause` only disables the collector task. Prometheus and Grafana keep running, the dashboards keep the last collected values, and the Instance page's collector row shows how old they are. To pause just one appliance of many, remove it from `Servers` in the config instead (and put it back afterwards); the collector reads the config every run.
- If you have set up the "Collector stopped" alert from the table below, expect it to fire while paused or stopped; silence it in Grafana (Alerting > Silences) for the maintenance window.
- The same things by hand: tasks `StorSafe Metrics Collector` and `StorSafe Prometheus` in Task Scheduler (`schtasks /Change /TN "StorSafe Metrics Collector" /DISABLE`), services `windows_exporter` and `Grafana` (`net stop Grafana`).
- Full backup of the monitoring host's state is the install folder plus Grafana's data (`%ProgramFiles%\GrafanaLabs\grafana\data`, for users and any alert rules you add). `creds\` only works on this machine for this user, so a restore elsewhere means re-running the installer's credential step.

## Versioning

`VERSION` holds the package version (also printed by the installer and published as `storsafe_collector_info{version="..."}`, shown on the Instance dashboard's Collector row), and `CHANGELOG.md` lists what changed. Keep the extracted release zips; an upgrade is always "copy the new release over the install folder" as above, so the previous zip is the rollback.

## Alert rules (Grafana > Alerting > Alert rules > New, data source "StorSafe Prometheus")

| Alert | Query | For | Severity |
|---|---|---|---|
| Appliance API down | `storsafe_up == 0` | 10m | Critical |
| Collector stopped | `time() - storsafe_collector_last_run_timestamp_seconds > 900` | 5m | Critical |
| Failover not normal | `storsafe_failover_healthy == 0` | 5m | Critical |
| LUN offline | `storsafe_physicaldevice_online == 0` | 5m | Critical |
| Pool near threshold | `100 * storsafe_storagepool_used_bytes / storsafe_storagepool_size_bytes > on(server) group_left() (storsafe_storage_threshold_percent - 5)` | 30m | Warning |
| Reclaim/prune failed | `storsafe_dedupe_maintenance_status{status="failed"} == 1` | 15m | Major |
| Dedupe policy error | `storsafe_dedupe_policy_status{status=~"error\|failed"} == 1` | 15m | Major |
| Policy suspended with tapes | `storsafe_dedupe_policy_suspended == 1 and on(server, policy) storsafe_dedupe_policy_tapes > 0` | 1h | Warning |
| Replication suspended | `storsafe_replication_suspended == 1` | 30m | Major |
| Unique replication stuck | `time() - (storsafe_unique_replication_oldest_job_start_timestamp_seconds > 0) > 43200` | 30m | Warning |
| Collector check failing | `storsafe_check_success == 0` | 30m | Warning |

Add a contact point (email or Teams webhook) under Alerting > Contact points.

## Metrics reference

| Metric | Labels |
|---|---|
| `storsafe_up` | server |
| `storsafe_info` | server, product, version, build, apiversion |
| `storsafe_check_success` | server, check |
| `storsafe_collect_duration_seconds`, `storsafe_collector_last_run_timestamp_seconds`, `storsafe_collector_run_duration_seconds`, `storsafe_collector_parallel_processes`, `storsafe_collector_server_exit_code`, `storsafe_collector_info` | server / none / server / version |
| `storsafe_failover_status` (one-hot), `storsafe_failover_healthy` | server, status |
| `storsafe_storagepool_size_bytes`, `_used_bytes` | server, pool, resourcetype |
| `storsafe_physicaldevice_size_bytes`, `_used_bytes`, `_online` | server, acsl, name, category, reservation |
| `storsafe_storage_threshold_percent` | server |
| `storsafe_dedupe_maintenance_status` (one-hot), `_running_since_timestamp_seconds`, `_last_run_start_timestamp_seconds`, `_last_run_end_timestamp_seconds`, `_last_run_duration_seconds`, `_last_run_result` (one-hot) | server, process (reclaim/prune), status / result |
| `storsafe_dedupe_policy_status` (one-hot), `_suspended`, `_tapes`, `_last_run_timestamp_seconds`, `_next_run_timestamp_seconds` | server, policy, status / trigger |
| `storsafe_dedupe_queue_jobs_total`, `_jobs`, `_undeduped_bytes`, `_throughput_bytes_per_second` | server, state |
| `storsafe_replication_queue_jobs_total`, `_jobs` | server, queue (classic/unique), state |
| `storsafe_dedupe_job_info` (one per queued tape), `_progress_percent`, `_throughput_bytes_per_second`, `_undeduped_bytes`, `_data_bytes`, `_scanned_bytes`, `_first_seen_timestamp_seconds`, `storsafe_dedupe_jobs_detailed` | server, policy, barcode (+ tape, state, trigger, drive, destination_drive, replicationmode, parser on `_info`) |
| `storsafe_replication_job_info` (one per job and target), `_progress_percent`, `_throughput_bytes_per_second`, `_total_bytes`, `_transmitted_bytes`, `_remaining_seconds`, `_first_seen_timestamp_seconds`, `_start_timestamp_seconds` (unique queue), `_next_retry_timestamp_seconds`, `_retries_left` (classic queue), `storsafe_replication_jobs_detailed` | server, queue (dedupe/classic/classic-dedupe/unique), barcode, target (+ direction, policy, tape, source, targetip, state, phase, mode on `_info`) |
| `storsafe_unique_replication_oldest_job_start_timestamp_seconds`, `storsafe_replication_suspended` | server |
| `storsafe_vtl_slots`, `_tapes`, `_drives`, `_loaded_drives` | server, library |
| `storsafe_virtualized_disk_size_bytes`, `_used_bytes`, `storsafe_tapecaching_unmigrated_bytes`, `_reclaimable_bytes`, `_reclaim_eligible_tapes` | server |
| `storsafe_check_last_success_timestamp_seconds` | server, check |
| `storsafe_time_seconds`, `storsafe_time_offset_seconds` | server |
| `storsafe_adapter_paths` | server, adapter, vendor, type, mode, wwpn |
| `storsafe_dedupe_repository_enabled`, `_info`, `_failover_enabled`, `_failover_status`, `_taken_over`, `_associated_servers` | server (+ cluster, type, mode / status) |
| `storsafe_dedupe_repository_disk_size_bytes`, `_disk_online` | server, node, role (data/index/folder), name |
| `storsafe_dedupe_policy_info`, `storsafe_dedupe_policy_replication_suspended` | server, policy, cluster, replicationmode / target |
| `storsafe_dedupe_runs_24h` | server, policy, status |
| `storsafe_dedupe_24h_scanned_bytes`, `_unique_bytes`, `_ratio`, `_replicated_bytes`, `_replicated_unique_bytes`, `_tapes`, `_duration_seconds` | server, policy |
| `storsafe_dedupe_run_last_timestamp_seconds`, `storsafe_dedupe_run_last_status` | server, policy (+ status, trigger) |
| `storsafe_dedupe_completed_run_timestamp_seconds`, `_ratio`, `_scanned_bytes`, `_unique_bytes`, `_tapes`, `_duration_seconds`, `_replicated_bytes`, `_replicated_unique_bytes`, `_replication_ratio`, `_replication_duration_seconds` | server, policy |
| `storsafe_dedupe_active_scans(_total)`, `_scan_throughput_bytes_per_second`, `_scan_remaining_bytes`, `_replications(_total)`, `_replication_throughput_bytes_per_second`, `_replication_remaining_bytes`, `_replication_remaining_seconds` | server, policy (+ status / phase) |
| `storsafe_standalone_drives`, `storsafe_standalone_drive_loaded` | server, drive, barcode |
| `storsafe_tapes_total`, `storsafe_tapes`, `_size_bytes`, `_used_bytes`, `_empty` | server, location |
| `storsafe_vtl_tape_size_bytes`, `_tape_used_bytes`, `_tapes_empty` | server, library |
| `storsafe_tapes_by_status` | server, field, status |
| `storsafe_tapes_with_property` | server, property |
| `storsafe_replica_tapes`, `_oldest_replicated_timestamp_seconds`, `_newest_replicated_timestamp_seconds` | server, source |
| `storsafe_replica_tapes_not_replicated_within` | server, source, age (24h/48h/7d/never) |
| `storsafe_physical_libraries`, `storsafe_physical_library_status`, `_disabled`, `_tapes`, `_loaded_tapes`, `_slots` | server, library, serialno / status |
| `storsafe_physical_drive_status`, `_disabled` | server, library, drive, status, barcode |
| `storsafe_iejob_total`, `_jobs`, `_jobs_by_type`, `_running_transferred_bytes`, `_oldest_running_start_timestamp_seconds` | server (+ status, jobtype) |
| `storsafe_events_total` (counter), `storsafe_events_new` | server, severity |
| `storsafe_event_recent` (20 newest non-informational; value is the event time, Unix seconds) | server, severity, time, id, message |
| `storsafe_eventlog_columns_detected` | server |
| `storsafe_server_info`, `_memory_bytes`, `_swap_bytes`, `_cpus`, `_storsight_running` | server (+ hostname, role, make, model, osversion, ...) |
| `storsafe_patches_installed`, `storsafe_patch_info` | server, patch, description |
| `storsafe_server_option_enabled`, `storsafe_encryption_option` | server, option |
| `storsafe_failover_config_info`, `_selfcheck_interval_seconds`, `_heartbeat_interval_seconds`, `_autorecovery_enabled` | server (+ type, partner, partnerip, powercontrol) |
| `storsafe_nic_speed_mbps`, `_mtu`, `_dhcp`, `storsafe_network_info`, `storsafe_network_service_enabled`, `storsafe_bond_members`, `storsafe_ntp_servers` | server, nic / group / service |
| `storsafe_dedupe_replication_partners`, `_partner_info`, `_connections`, `_timeout_seconds`, `storsafe_replica_source_info` | server, direction, partner |
| `storsafe_reclamation_policy_enabled`, `_usage_check_interval_seconds`, `_schedule_info`, `storsafe_dedupe_cleanup_needed` | server (+ trigger) |
| `storsafe_vtl_compression_enabled`, `_retain_tape_enabled`, `storsafe_tapecaching_*_threshold_percent`, `storsafe_iejob_retry_*`, `storsafe_activity_db_*` | server |
| `storsafe_clients(_total)`, `storsafe_fc_initiators`, `storsafe_iscsi_targets`, `storsafe_iscsi_initiators`, `storsafe_hosted_backup_devices(_total)`, `storsafe_user_accounts`, `storsafe_objectstorage_accounts(_total)` | server (+ protocol / assigned / type / provider) |
| `storsafe_syslog_alert_enabled`, `_patterns`, `_check_interval_seconds`, `storsafe_config_autosave_enabled`, `_copies` | server |

## Repository

The package is the repository root, so a clone is an install folder. Not part of the package:

| Path | Contents |
|---|---|
| `tools\build-dashboards.py` | Generates the five dashboards in `monitoring\dashboards\` (edit this, not the JSON) |
| `tools\build-package.py` | Builds `dist\StorSafe-monitoring-v<VERSION>.zip` |
| `tools\test\` | Mock StorSafe API, test config and dashboard query validator; see `tools\test\README.md` |
| `docs\` | API map and plan, review of the original scripts, dashboard design notes |

Releasing a change: bump `VERSION`, add a `CHANGELOG.md` entry, regenerate dashboards if `tools\build-dashboards.py` changed, run the tests in `tools\test\README.md`, commit, tag `v<VERSION>`, and build the zip. `creds\`, `state\`, `events\`, `metrics\`, `reports\` and `installers\` are ignored by git apart from their README.txt, so a clone that is also a running install stays clean.

## Uninstall

```powershell
Unregister-ScheduledTask 'StorSafe Metrics Collector','StorSafe Prometheus' -Confirm:$false
# Then remove windows_exporter and Grafana from Apps & features, and delete the folder.
```
