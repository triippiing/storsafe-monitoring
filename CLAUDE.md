# CLAUDE.md

Guidance for Claude Code (and people) working in this repository. Read README.md first: it is the
operator-facing document and describes the stack, install, maintenance and every metric.

## What this is

A monitoring package for FalconStor StorSafe (VTL + deduplication) appliances: a PowerShell collector
polls each appliance's REST API (`/obd/...`) and writes Prometheus text files; windows_exporter,
Prometheus and Grafana run on one Windows host. A clone of this repository is an install folder.
Target estate: dozens of appliances (not primary/secondary pairs), StorSafe 11.x, one Windows
monitoring host per site, collector running as a scheduled task under Windows PowerShell 5.1.
The same package also installs on one Linux host (RHEL family 8/9, Debian 12, Ubuntu LTS; x86_64,
systemd): `linux/install.sh` sets up node_exporter instead of windows_exporter and systemd units and a
timer instead of scheduled tasks, and the collector runs under PowerShell 7 there, as the `storsafe`
service account.

## Hard rules

- **Read-only against the appliances.** Every API call is a GET plus login/logout, except
  `PUT /server/event`, which only downloads the event log as CSV. Never add calls that change
  appliance state (rescans, failover preflight, restarts, config writes). Admin/CLI tooling is a
  separate, deferred piece of work and must be dry-run by default if it is ever built.
- **No secrets, no site data in git.** Credentials live only in DPAPI files under `creds\`
  (`New-StorSafeCredentialFile`), never in scripts, config or docs. (On Linux there is no DPAPI: the
  files are unencrypted Export-Clixml, protected by `creds/` mode 0700 and files 0600 owned by the
  service user.) `StorSafe.config.json` is git-ignored; only `StorSafe.config.example.json` with
  template names is committed. Do not collect or publish SNMP settings (community strings), encryption
  keys, X-ray bundles or user names.
- **Windows PowerShell 5.1 compatibility** for everything the scheduled task runs. No PowerShell 7-only
  syntax (`??`, ternary, `-Parallel`, `Invoke-WebRequest -Body` on GET). A GET that needs a JSON body
  goes through `Invoke-StorSafeCurlGet` (curl.exe). Test on `pwsh` here, but keep 5.1 in mind.
- **Install path without spaces**, `127.0.0.1` rather than `localhost` in URLs, and operators run
  things from cmd.exe: give `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ...` forms in docs.
- **Shell scripts** (`linux\`, `tools\test\linux\`): every script that is executed starts with
  `#!/usr/bin/env bash` and `set -euo pipefail`; the sourced libraries (`linux/lib.sh`,
  `tools/test/linux/helpers.sh`) carry the shebang only and set no options. All pass shellcheck with no
  warnings and keep LF endings (`.gitattributes` enforces that). Unit templates in `linux\systemd\` use
  only the placeholders `__ROOT__`, `__USER__`, `__PWSH__`, `__LISTEN__`, `__RETENTION__`, `__INTERVAL__`
  and `__RUNTIME__`; a placeholder left in a rendered unit is an installer error. Distro package names
  appear only in `icu_package_line` in `linux/install.sh` (the hint the PowerShell step prints).

## Layout

- Root: the package (`Export-StorSafeMetrics.ps1` collector, `StorSafe.psm1` client, installer,
  `Get-StorSafeInstallers.ps1`, `StorSafeMonitoringControl.ps1`, report scripts, `monitoring\`).
- `linux\`: the Linux host: `install.sh` (`--collector-only` for a host that already runs Prometheus and
  Grafana), `get-installers.sh`, `storsafe-control.sh`, `lib.sh` (shared functions) and `systemd\` (unit and
  timer templates the installer renders). The install folder is the same package, extracted from the
  tar.gz or cloned to `/opt/storsafe-monitoring`; `monitoring\prometheus.yml` and the Grafana
  provisioning are shared with Windows. `node_exporter\`, `prometheus\` and `grafana\` are unpacked
  into it at install and are git-ignored.
- `tools\build-dashboards.py` generates `monitoring\dashboards\*.json`. **Edit the generator, never the
  JSON.** `tools\build-package.py` builds `dist\StorSafe-monitoring-v<VERSION>.zip` and `.tar.gz`.
- `tools\test\`: mock StorSafe API (`mock_api.py`), test config, dashboard query validator, README with
  the test procedure. No real appliance is needed or reachable from a cloud session.
- `tools\test\linux\`: tests of the Linux scripts (`run.sh` runs every `test_*.sh`) and `smoke.sh` (an
  install against the mock API). `.github\workflows\ci.yml` runs lint, the test kit, the container smoke
  tests and a full systemd install.
- `docs\`: API map and plan, review of the original scripts, dashboard design notes and decisions.
  `docs\images\`: README screenshots rendered from the mock API (template names only).

## How the collector is built

`$checks` is an ordered hashtable of script blocks, one per API area, each `param($c, $l, $x)`
(connection, base labels, per-appliance lookup cache). Checks are independent: a failure sets
`storsafe_check_success{check} 0` and the rest continue. Emit metrics with `Add-Metric name help value
labels` and build labels with `New-Label $l 'k' v ...`; label values go through `ConvertTo-LabelValue`.
Cadences: every run, 15 min, 60 min (cached in `state\checkcache-*.json`). Per-appliance state files
in `state\` (`events-*`, `jobs-*`, `maintenance-*`). Parallel mode spawns one child process per
appliance with `-Server` and `-FileName storsafe-<server>.prom`; collector-wide metrics are written
only by the parent (sequential mode) or the parent summary (parallel mode).

## Workflow for a change

1. Make the change; keep the style of the surrounding code (comment density, helper use, naming).
2. Run the test kit in `tools\test\README.md` (mock API, collector run, `promtool check metrics`,
   dashboard validator must report `errors 0`). Syntax-check every `.ps1`/`.psm1` with the PowerShell
   parser. If `linux\` changed, also run `bash tools/test/linux/run.sh` and shellcheck.
3. If a dashboard changed, regenerate with `python3 tools/build-dashboards.py` and commit the JSON.
4. If anything user-visible changed: bump `VERSION`, add a `CHANGELOG.md` entry, update README.md
   (metrics reference, settings table, cadence table) in the same commit.
5. Commit to `main` (or a branch and PR). Tags and GitHub Releases are created by the maintainer
   (`git tag -a vX.Y.Z` + push); the zip and tar.gz from `tools/build-package.py` are the release assets.

## Decisions already made (don't re-open without asking)

- Option B stack (collector → windows_exporter textfile → Prometheus → Grafana on Windows), no
  Alertmanager; alerting via Grafana rules (draft table in README, not yet configured).
- Linux host (5.1.0): the same stack with node_exporter's textfile collector, as systemd services under
  the `storsafe` account. The collector is a oneshot service run by a timer, so pausing means
  `storsafe-control.sh pause` (stops the timer), never stopping the service. `prometheus.yml` is shared
  and keeps `storsafe_.*|windows_textfile_.*|node_textfile_.*`.
- Dashboards: Fleet, Activity, Instance (server picker, one URL per appliance), Patch Management,
  Events. Activity tables: dedupe jobs use the collector's first-seen time as the start time (the API
  has none); replication rows show target and phase (no drive involved); reclamation/prune rows show
  status only and only while running (the API gives idle/running/failed and nothing else).
- Uptime is not in the REST API (the console's "Service Uptime" is a web GUI value); SNMP `sysUpTime`
  is the agreed fallback if ever wanted.
- Deferred by the maintainer: alert rules, an admin CLI, moving the collector from a root login to a
  read-only (type R) appliance account.

## Testing notes

`pwsh` 7, Python 3 and a Prometheus/promtool binary are enough; see `tools\test\README.md`. The mock
reports reclamation running for its first two status calls, so two collector runs exercise the
maintenance transition tracking. Running the real collector against real appliances is the
maintainer's job; a cloud session cannot reach them.

`bash tools/test/linux/run.sh` needs `pwsh` on the `PATH`, the mock API on port 18080 and root (the
installer tests); the kit's `prometheus-test.yml` needs Prometheus 3. `smoke.sh` installs collector-only
into a temporary folder without systemd; `smoke.sh --services` installs the full stack as systemd
services in `/opt/storsafe-monitoring` and needs a systemd host (a throwaway VM or a CI runner).
