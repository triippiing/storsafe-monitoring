# Linux monitoring host: design

Date: 2026-10-06. Status: approved in conversation, awaiting review of this document.

## Why

The repository is public and people want to run the monitoring on Linux. Windows stays supported
exactly as it is today, and a Linux-only install (no Windows anywhere) must work. The appliances,
the REST API use (read-only) and the dashboards do not change.

## Decisions made during brainstorming

| Topic | Decision |
|---|---|
| Collector | The existing PowerShell collector and client run unchanged under PowerShell 7 on Linux. No rewrite. |
| Distributions | Tested on the RHEL family (RHEL, Rocky, Alma 8 and 9) and on Debian 12 / Ubuntu LTS. Anything else with systemd is best effort. |
| Scope of the installer | Full stack on one host, plus a `--collector-only` switch for people who already run Prometheus and Grafana. |
| Repository shape | One repository. The root stays the shared package; a new `linux/` folder holds the Linux-specific files. No platform folders, no move of the Windows files. |
| Containers | Out of scope. A docker/podman variant comes later in a separate repository. |
| Version | 5.1.0 (new feature, user-visible). |

## Out of scope

Containers, RPM/DEB packaging, AIX, a custom SELinux policy, alert rules, the read-only (type R)
appliance account, and any change to the collector's metrics or the dashboards' content.

## 1. Layout

The root remains the package both platforms share: `Export-StorSafeMetrics.ps1`, `StorSafe.psm1`,
`StorSafe.config.example.json`, `monitoring\`, `VERSION`, `CHANGELOG.md`, `README.md`. The Windows
scripts stay at the root so existing installs, the documented paths and the robocopy upgrade are
untouched.

New files:

| Path | Purpose |
|---|---|
| `linux/install.sh` | Installer and uninstaller, run with sudo. Idempotent. |
| `linux/get-installers.sh` | Downloads the four upstream tarballs into `installers/` (node_exporter, Prometheus, Grafana, PowerShell). Skips files that already exist. Same offline pattern as `Get-StorSafeInstallers.ps1`. |
| `linux/storsafe-control.sh` | `status`, `stop`, `start`, `pause`, `resume`, the Linux twin of `StorSafeMonitoringControl.ps1`. |
| `linux/systemd/storsafe-collector.service`, `.timer` | Collector run and its 5-minute timer. |
| `linux/systemd/storsafe-node-exporter.service` | node_exporter with the textfile collector on `metrics/`. |
| `linux/systemd/storsafe-prometheus.service` | Prometheus bound to 127.0.0.1:9090. |
| `linux/systemd/storsafe-grafana.service` | Grafana on port 3000 with file provisioning. |
| `.github/workflows/ci.yml` | Lint, test kit, install smoke tests (see section 6). |
| `docs/superpowers/specs/` | This document. |

Unit files are templates: `__ROOT__`, `__USER__`, `__LISTEN__` and `__RETENTION__` are replaced by
`install.sh` when it writes them to `/etc/systemd/system/`.

Install folder: `/opt/storsafe-monitoring` by default (`--root` overrides; no spaces allowed, as on
Windows). A git clone or an extracted tar.gz is the install folder. Runtime subfolders are the same
as on Windows (`creds/`, `state/`, `events/`, `metrics/`, `reports/`, `installers/`) and the third-party
components live inside the folder: `prometheus/` (binary, config, `data/`), `grafana/` (the extracted
tarball with `data/` and `conf/provisioning/`), `node_exporter/`. PowerShell goes to
`/opt/microsoft/powershell/7` with `/usr/bin/pwsh` linked, which is where Microsoft's own packages put it.

Shared file changes:

- `monitoring/prometheus.yml`: the keep regex becomes `storsafe_.*|windows_textfile_.*|node_textfile_.*`
  so one file serves both exporters. The dashboards reference no exporter-specific metric.
- `.gitattributes`: `linux/** text eol=lf` so a Windows checkout cannot give the shell scripts and
  unit files CRLF endings.
- `tools/build-package.py`: builds `dist/StorSafe-monitoring-v<VERSION>.tar.gz` next to the zip. Both
  archives contain the same tree, including `linux/`; the tar.gz carries mode 0755 on the `.sh` files.

## 2. Installer (`linux/install.sh`)

```
sudo linux/install.sh [--root /opt/storsafe-monitoring] [--user storsafe] [--interval-minutes 5]
                      [--retention-days 180] [--collector-only] [--listen ADDR:PORT]
                      [--skip-credentials] [--no-services] [--uninstall]
```

The flags mirror the Windows installer's parameters (`IntervalMinutes`, `PrometheusRetentionDays`,
`SkipCredentials`) plus the Linux-only ones. `--no-services` does everything except `systemctl`
(it prints the commands it would run); it exists for containers and CI.

Steps, in the same order as the Windows installer, each reported in a summary table as `OK`,
`Skipped`, `Missing installer` or `Check` with a one-line note:

1. **Preconditions.** Running as root; systemd present (unless `--no-services`); x86_64; the root path
   contains no space; `curl` and `tar` present; ports 9182, 9090 and 3000 not already bound by
   something else (reported as `Check`, not fatal). PowerShell needs ICU: `libicu` on the RHEL family,
   `libicu72` on Debian 12, `libicu74` on Ubuntu 24.04; the installer detects the family, prints the
   matching package line when the library is absent, and stops if `pwsh -v` fails after installation.
2. **PowerShell.** If `pwsh` is already on the PATH it is used as found. Otherwise the PowerShell
   tarball from `installers/` is extracted to `/opt/microsoft/powershell/7` and `/usr/bin/pwsh` is
   linked. Missing tarball: `Missing installer`.
3. **Service user.** A system account (default `storsafe`, no login shell, home = install folder)
   is created if absent. It owns `creds/` (0700), `state/`, `events/`, `metrics/`, `reports/`,
   `prometheus/data`, `grafana/data`. Everything else in the folder is root-owned and world-readable.
4. **Config.** If `StorSafe.config.json` is missing, the example is copied into place and the
   installer stops with the instruction to edit the Servers list, exactly as on Windows.
5. **Credential files.** For each server whose `CredentialFile` does not exist, the installer prompts
   and runs `New-StorSafeCredentialFile` as the service user, then sets mode 0600. `--skip-credentials`
   skips the step. Linux has no DPAPI: `Export-Clixml` stores the password without encryption, so the
   file ownership and modes are the protection, and the README says so plainly.
6. **Collector test run.** `Export-StorSafeMetrics.ps1 -All -NonInteractive` as the service user, which
   must produce `metrics/storsafe.prom`. A failure stops the installer before any unit is enabled.
7. **node_exporter.** Tarball extracted to `node_exporter/`; unit written with
   `--collector.textfile.directory=<root>/metrics --web.listen-address=<listen>`. `<listen>` is
   `127.0.0.1:9182` for the full stack and `0.0.0.0:9182` with `--collector-only` (`--listen` overrides
   both). Default host collectors stay enabled; the bundled Prometheus drops them through the keep regex.
8. **Prometheus.** Skipped with `--collector-only`. Tarball extracted to `prometheus/`,
   `monitoring/prometheus.yml` copied in (refreshed on every run), unit written with the same flags as
   the Windows task: `--config.file`, `--storage.tsdb.path=<root>/prometheus/data`,
   `--storage.tsdb.retention.time=<days>d`, `--web.listen-address=127.0.0.1:9090`.
9. **Grafana.** Skipped with `--collector-only`. Tarball extracted to `grafana/`; the data source
   file and the dashboard provider file (with `__DASHBOARD_DIR__` replaced by
   `<root>/monitoring/dashboards`) copied into `grafana/conf/provisioning/`; unit runs
   `bin/grafana server --homepath <root>/grafana` with `GF_PATHS_DATA=<root>/grafana/data`,
   `GF_PATHS_LOGS=<root>/grafana/data/log` (the only writable paths) and `GF_SERVER_HTTP_PORT=3000`. The default admin password is Grafana's own, with the README telling
   the operator to change it on first login, as on Windows.
10. **Units.** The relevant units are written, `systemctl daemon-reload`, enabled and started; the
    installer waits for `/-/ready`, `/metrics` and `/api/health` like the Windows `Wait-HttpOk` and
    reports `Check` if a port is not answering within 60 s.
11. **Summary** table, then the next steps: the Grafana URL, or with `--collector-only` the scrape job
    snippet for an existing Prometheus and the dashboard import steps.

Re-running the installer refreshes configs and unit files, restarts units whose files changed, and
leaves already-extracted tarballs alone (a `.version` marker in each component folder records what was
extracted). `--uninstall` stops and disables the four units, removes them from `/etc/systemd/system/`
and runs `daemon-reload`; the install folder, the service user and PowerShell are left for the
operator, and the summary says so.

## 3. Services, user and credentials

| Unit | Type | Runs as | Key settings |
|---|---|---|---|
| `storsafe-collector.service` | oneshot | `storsafe` | `WorkingDirectory=<root>`, `ExecStart=/usr/bin/pwsh -NoProfile -NonInteractive -File <root>/Export-StorSafeMetrics.ps1 -All -NonInteractive`, `RuntimeMaxSec=240` (the Windows task's execution limit), stdout/stderr to the journal |
| `storsafe-collector.timer` | timer | - | `OnBootSec=1min`, `OnUnitActiveSec=<interval>min`, `AccuracySec=15s`, `Persistent=false` |
| `storsafe-node-exporter.service` | simple | `storsafe` | `Restart=always`, `RestartSec=5` |
| `storsafe-prometheus.service` | simple | `storsafe` | `Restart=always`, `RestartSec=5`, `WorkingDirectory=<root>/prometheus` |
| `storsafe-grafana.service` | simple | `storsafe` | `Restart=always`, `RestartSec=5`, `WorkingDirectory=<root>/grafana`, `GF_*` environment |

All units carry `NoNewPrivileges=true` and `PrivateTmp=true`; nothing in them is a secret. All four
are enabled at boot. The collector's exit codes are the existing ones (0 OK, 2 a check failed, 3
config error); `storsafe-control.sh status` translates them the way the Windows script does.

Network exposure: Prometheus and node_exporter bind 127.0.0.1 in the full stack; Grafana listens on
all interfaces on 3000 as it does on Windows. With `--collector-only`, node_exporter binds all
interfaces and the README gives the `firewall-cmd` and `ufw` lines for 9182. The collector itself only
makes outbound HTTPS calls to the appliances.

SELinux: binaries under `/opt` started by systemd run in the unconfined service domain on RHEL in
enforcing mode, so no policy module is shipped. The README notes this and the `ausearch` command to
check if a site runs a stricter baseline.

Logs: `journalctl -u storsafe-collector` (one entry per run with the same summary line the Windows
task writes), `journalctl -u storsafe-prometheus`, `journalctl -u storsafe-grafana`.

## 4. Control, upgrade, uninstall

`linux/storsafe-control.sh <status|stop|start|pause|resume>`, same semantics as the Windows script:

- `status`: one row per unit with active/enabled state; the timer's next run; the last collector
  result from `systemctl show -p ExecMainStatus,ExecMainExitTimestamp`; whether 9182, 9090 and 3000
  answer.
- `stop` / `start`: the timer first, then node_exporter, Prometheus, Grafana (reverse order on start).
  Units that are not installed (collector-only) are reported as absent and skipped.
- `pause` / `resume`: the timer only, for appliance maintenance; `resume` also runs the collector once
  with `systemctl start storsafe-collector.service`.

Upgrade: extract the new tar.gz over the install folder (or `git pull`), keeping
`StorSafe.config.json` and `creds/`, then re-run `install.sh` with the same flags. The README gives
the `tar --exclude` form, the twin of the robocopy line.

Uninstall: `sudo linux/install.sh --uninstall`, then delete the folder, the user and
`/opt/microsoft/powershell` by hand if wanted (commands listed in the README).

## 5. Packaging and documentation

- `VERSION` 5.1.0 and a `CHANGELOG.md` entry.
- `tools/build-package.py` writes the zip as today and the tar.gz (same file list, same top folder,
  `.sh` files 0755).
- `linux/get-installers.sh` pins versions the same way `Get-StorSafeInstallers.ps1` does: Prometheus
  3.15.0 and Grafana 12.0.2 to match Windows, node_exporter and PowerShell 7 LTS at the newest
  releases verified during implementation. Download URLs are the GitHub release pages for
  node_exporter, Prometheus and PowerShell and `dl.grafana.com` for Grafana.
- `README.md`: Linux rows in the Layout table; an "Install on a Linux machine" section after the
  Windows one (prerequisites, `get-installers.sh`, config, `install.sh`, checks, the collector-only
  variant with the scrape job and dashboard import); Linux paragraphs in "Stopping and starting",
  "Upgrading" and "Uninstall"; the credential-file note.
- `CLAUDE.md`: layout line for `linux/`; rules: `set -euo pipefail`, shellcheck clean, LF endings,
  no distro package names outside the preconditions step, every unit template keeps the placeholder
  names above.

## 6. Testing

Existing kit (`tools/test/README.md`) already runs the collector on Linux with `pwsh` against the mock
API and validates every dashboard query; it stays the first step of every change.

New checks, all wired into `.github/workflows/ci.yml` and runnable by hand:

1. **Lint.** `shellcheck linux/*.sh`, `bash -n`, the PowerShell parser over every `.ps1`/`.psm1`,
   `python3 -m py_compile` over `tools/`.
2. **Kit.** Mock API, collector run, `promtool check metrics`, dashboard validator (`errors 0`).
3. **Install smoke, no systemd.** Containers `rockylinux:9` and `debian:12` run
   `get-installers.sh` then `install.sh --collector-only --no-services --skip-credentials` with the
   mock credential file against the mock API, and check that `metrics/storsafe.prom` exists and that
   the unit files rendered without a leftover placeholder.
4. **Full stack with systemd.** On the `ubuntu-latest` runner: `install.sh` (full stack) against the
   mock, then `curl` on 127.0.0.1:9182, 9090 and 3000, the dashboard validator against the bundled
   Prometheus, `storsafe-control.sh status`, `pause`, `resume`, and `--uninstall`.

What cannot be tested from a cloud session or a container is the first boot on a real RHEL VM with
SELinux enforcing and a real firewall; that is the maintainer's acceptance test before tagging 5.1.0.

## 7. Error handling

- `set -euo pipefail` everywhere; each installer step is a function wrapped so a failure is recorded
  in the summary as `Check` and later steps still run, except preconditions, PowerShell, config and the
  collector test run, which stop the installer because nothing after them can work.
- No unit is enabled before the collector test run has succeeded.
- A missing tarball is `Missing installer` with the exact file name to put in `installers/`.
- A placeholder left in a rendered unit file is a hard error (guards against a renamed placeholder).
- The control script exits non-zero when any unit it was asked to change is not in the expected
  state afterwards, so it can be used from other scripts.
