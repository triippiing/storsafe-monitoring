# Changelog

The package version is in `VERSION`, printed by the installer, and published by the collector as `storsafe_collector_info{version="..."}` (visible on the Instance dashboard, Collector row).

## 5.1.0 (2026-10-06)

- Linux host support: `linux/install.sh` installs the stack on RHEL family 8/9, Debian 12 or Ubuntu LTS (x86_64, systemd) and is idempotent: service account `storsafe`, PowerShell 7 from its tarball when `pwsh` is missing, credential prompts, node_exporter, Prometheus and Grafana unpacked into the install folder, systemd units and a collector timer rendered from `linux/systemd/`, and `--uninstall`. `linux/storsafe-control.sh` (status / stop / start / pause / resume) and `linux/get-installers.sh` (downloads the four tarballs; `--print-urls` for offline hosts) are the counterparts of the Windows scripts. Nothing in the collector, the module or the dashboards changed.
- Collector-only mode: `install.sh --collector-only` installs the collector and node_exporter for a host that sends its metrics to an existing Prometheus and Grafana (node_exporter then listens on `0.0.0.0:9182`; `--listen` changes it). The installer prints the scrape job to add.
- Package: `tools/build-package.py` also builds `dist/StorSafe-monitoring-v<VERSION>.tar.gz`, the same files as the zip with the `linux/` scripts executable.
- `monitoring/prometheus.yml` is shared by both installs; its keep regex is now `storsafe_.*|windows_textfile_.*|node_textfile_.*`, so the textfile collector's own health metrics are kept from either exporter.
- CI (`.github/workflows/ci.yml`): shellcheck and parse checks, the test kit against the mock API, the Linux install in Rocky Linux 9 and Debian 12 containers, and a full systemd install on a runner.
- Test kit: `tools/test/linux/` (nine tests run by `run.sh`, and `smoke.sh`); `tools/test/prometheus-test.yml` now needs Prometheus 3 (`fallback_scrape_protocol`).
- README: Install on a Linux machine, Linux paragraphs for upgrade, maintenance and uninstall; the architecture block names node_exporter. `CLAUDE.md` describes the Linux layout, the shell-script rules and the Linux tests.

## 5.0.1 (2026-10-05)

- Dashboards: tables built from several queries (dedupe jobs, replication jobs, policies, reclamation policy, and the others that combine an `_info` series with values) now show one row per item. Grafana's merge transformation refused to join rows because each query's `__name__` differed, so the generator drops `__name__` and `Time` before merging.
- Instance dashboard: Collector row shows the package version, last run, failing checks and collection time.
- README: screenshots of the five dashboards and the Prometheus/exporter pages (`docs/images`), rendered from the test kit's mock API.
- Test kit: the mock API uses documentation addresses (192.0.2.x) only, names replica sources VTL-SRC-1/2 and gives the Nightly policy a replication target, so the Instance replication tables render with data.

## 5.0.0 (2026-10-01)

- Five dashboards for a multi-appliance estate replace Estate and Detail: **Fleet**, **Activity**, **Instance**, **Patch Management**, **Events**. When upgrading, delete `monitoring\dashboards\storsafe-estate.json` and `storsafe-detail.json`.
- Collector (49 checks): per-job dedupe and replication checks (`dedupejobs`, `replicationjobs`) with collector-recorded first-seen times; reclamation/prune run tracking (running since, last run start/end/duration/result); parallel collection with `-MaxParallel` (one process per appliance when there are more than two, each writing `storsafe-<server>.prom`); `storsafe_event_recent` now carries the event time as its value; `storsafe_collector_info` version metric.
- Package: `VERSION`, this changelog, `Get-StorSafeInstallers.ps1` (downloads the three third-party installers), `StorSafeMonitoringControl.ps1` (status / stop / start / pause / resume), README sections for a clean install and host maintenance.

## 4.1 (2026-10-01)

- Fixed HTTP 415 on `GET /virtualtape` (tape inventory): the call needs a JSON body; on Windows PowerShell 5.1 it is sent through `curl.exe`.

## 4.0 (2026-10-01)

- Collector v2: 47 independent checks on 5/15/60-minute cadences with a result cache; event log download (`PUT /server/event`) with a daily CSV archive; run-history ratios; tape inventory; replica age; physical libraries; import/export jobs; hourly configuration checks. `DisabledChecks` and `CollectEventLog` settings. "StorSafe Detail" dashboard.

## 3.0 (2026-10-01)

- First self-contained package: `Install-StorSafeMonitoring.ps1` (credential files, windows_exporter, Prometheus as a startup task, Grafana with a provisioned data source and dashboard, collector task), collector v1, "StorSafe Estate" dashboard, ad-hoc report scripts.
