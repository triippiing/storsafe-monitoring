# Linux Monitoring Host Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install and run the existing StorSafe monitoring package on a Linux host (full stack or collector-only) with a bash installer, systemd units and a control script, shipped as 5.1.0 in the same repository.

**Architecture:** The repository root stays the shared package; everything Linux-specific lives in `linux/` (installer, downloader, control script, systemd unit templates, a small shared shell library). The unchanged PowerShell collector runs under PowerShell 7 from a systemd timer as a dedicated service user; node_exporter, Prometheus and Grafana are extracted from upstream tarballs into the install folder, exactly as the Windows installer does with its MSIs and zips. Shell code is tested with plain bash test scripts that use fake tarballs and a `systemctl` shim on `PATH`, so everything but a real boot runs in a container.

**Tech Stack:** bash 4+ (`set -euo pipefail`, shellcheck clean), systemd, PowerShell 7.4 (tarball), node_exporter, Prometheus 3.15.0, Grafana 12.0.2, Python 3 (existing tools), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-06-linux-host-design.md`

## Global Constraints

- Every shell script starts with `#!/usr/bin/env bash` and `set -euo pipefail`, passes `shellcheck` with no warnings, and has LF endings (`.gitattributes` enforces `linux/** text eol=lf`).
- Unit templates use only these placeholders: `__ROOT__`, `__USER__`, `__PWSH__`, `__LISTEN__`, `__RETENTION__`, `__INTERVAL__`, `__RUNTIME__`. A rendered file that still contains `__[A-Z]+__` is a hard error.
- Default install folder `/opt/storsafe-monitoring`; a path containing a space is rejected. URLs use `127.0.0.1`, never `localhost`.
- Service user default `storsafe`; `creds/` mode 0700, credential files 0600, both owned by that user. Units carry `NoNewPrivileges=true` and `PrivateTmp=true` and contain no secret.
- Distro package names appear only in the preconditions step (`libicu` on the RHEL family, `libicu72` on Debian 12, `libicu74` on Ubuntu 24.04).
- Nothing in `*.ps1` / `*.psm1` changes; Windows PowerShell 5.1 behaviour is untouched. Every appliance call stays read-only.
- Ports: node_exporter 9182, Prometheus 9090 (always 127.0.0.1), Grafana 3000. Prometheus flags identical to the Windows task. Timer: `OnBootSec=1min`, `OnUnitActiveSec=<interval>min`, `AccuracySec=15s`, `Persistent=false`. Collector `RuntimeMaxSec` = `max(120, (interval-1)*60)` seconds (240 for the default 5).
- Version 5.1.0 with a `CHANGELOG.md` entry; README and `CLAUDE.md` updated in the same release.
- Commit subjects are short imperative sentences in the repository's existing style (no `feat:` prefixes).

## Review Focus

1. `--root` given with a trailing slash or as a relative path: everything must still render as one absolute path without a double slash. Test in Task 5.
2. Re-running the installer after a newer tarball was dropped into `installers/`: the component is re-extracted and its `.version` marker updated; an unchanged tarball is left alone. Test in Task 6.
3. `pwsh` present but unable to start (missing ICU): the PowerShell step reports the detected family's package line and the installer stops before touching units. Test in Task 5.
4. `--listen` with a malformed value (`9182`, `:9182`, `host`): exit code 2 with a usage message, nothing written. Test in Task 5.
5. The control script asked to `pause` on a collector-only host that has no Prometheus or Grafana unit: the missing units are reported as absent and the exit code is still 0. Test in Task 8.

---

## File Structure

| File | Responsibility |
|---|---|
| `linux/lib.sh` | Sourced by the installer and the control script: logging, summary table, template rendering, OS family detection, HTTP and port probes. |
| `linux/get-installers.sh` | Downloads the four tarballs into `installers/`; prints the URLs for offline hosts. |
| `linux/install.sh` | Installer and uninstaller: argument parsing, the eleven steps of the spec, `--no-services`, `--uninstall`. |
| `linux/storsafe-control.sh` | `status`, `stop`, `start`, `pause`, `resume`. |
| `linux/systemd/storsafe-collector.service`, `storsafe-collector.timer`, `storsafe-node-exporter.service`, `storsafe-prometheus.service`, `storsafe-grafana.service` | Unit templates. |
| `tools/test/linux/helpers.sh` | `assert_eq`, `assert_file`, `assert_grep`, `assert_not_grep`, `assert_exit`, `make_fake_tarballs`, `make_systemctl_shim`. |
| `tools/test/linux/run.sh` | Runs every `test_*.sh` in the folder, prints a pass/fail line each, exits non-zero on any failure. |
| `tools/test/linux/test_*.sh` | One test file per task, named below. |
| `tools/build-package.py` (modify) | Also writes the tar.gz with 0755 on `linux/*.sh`. |
| `monitoring/prometheus.yml`, `.gitattributes`, `.gitignore` (modify) | Shared-file changes from the spec. |
| `.github/workflows/ci.yml` | Lint, kit, container smoke, full systemd run. |
| `README.md`, `CLAUDE.md`, `CHANGELOG.md`, `VERSION` (modify) | Documentation and release. |

Local test prerequisites (all present in the cloud container and on the CI runner): bash 5, Python 3, `pwsh` on `PATH` (in the container: `export PATH=/tmp/claude-0/-home-claude/a5e03ec0-6153-584b-8e35-1fe4611daf2d/scratchpad/pwsh:$PATH`), the mock API started with `python3 tools/test/mock_api.py 18080` (use `setsid nohup ... &` in the container). `shellcheck` is not in the container: fetch the static binary from `https://github.com/koalaman/shellcheck/releases` into the scratchpad before Task 1's lint step, or run the lint step in CI only and say so in the commit message.

---

### Task 1: Test harness and shared library

**Files:**
- Create: `tools/test/linux/helpers.sh`, `tools/test/linux/run.sh`, `linux/lib.sh`
- Test: `tools/test/linux/test_lib.sh`

**Interfaces:**
- Produces, in `linux/lib.sh` (sourced, never executed):
  - `log_step "<title>"` prints a blank line then `== <title>`.
  - `summary_add "<step>" "<result>" "<note>"` appends a row; `summary_print` prints a three-column table with the header `Step  Result  Note` and column widths fitted to the content.
  - `die "<message>"` prints `error: <message>` to stderr and exits 1.
  - `detect_family` prints `rhel`, `debian` or `unknown` from `ID` and `ID_LIKE` in the file named by `OS_RELEASE_FILE` (default `/etc/os-release`).
  - `render_template <src> <dst> KEY=VALUE...` replaces each `__KEY__` and returns 1, printing the leftover names, if any `__[A-Z]+__` remains in the output.
  - `http_ok <url> <timeout_seconds>` returns 0 as soon as `curl -fsS -o /dev/null --max-time 5 <url>` succeeds, polling every 2 s, else 1 after the timeout.
  - `port_in_use <port>` returns 0 when something listens on `127.0.0.1:<port>` (uses `ss -ltn` when present, otherwise `/dev/tcp`).
  - `runtime_max_sec <interval_minutes>` prints `max(120, (interval-1)*60)`.
- Produces, in `tools/test/linux/helpers.sh`: `assert_eq expected actual [label]`, `assert_file path`, `assert_grep file pattern`, `assert_not_grep file pattern`, `assert_exit code cmd...` (runs the command, compares the exit code), `make_fake_tarballs <dir>` (Task 6 defines the contents), `make_systemctl_shim <dir>` (Task 7 defines the contents). Each failed assertion prints `FAIL <label>` and sets `FAILED=1`; a test file ends with `exit $FAILED`.

- [ ] **Step 1: Write the failing test**

```bash
# tools/test/linux/test_lib.sh
#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); source "$here/helpers.sh"; source "$here/../../../linux/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf 'ID=rocky\nID_LIKE="rhel centos fedora"\n' > "$tmp/os"; OS_RELEASE_FILE=$tmp/os
assert_eq rhel "$(detect_family)" "rocky is rhel family"
printf 'ID=ubuntu\nID_LIKE=debian\n' > "$tmp/os";  assert_eq debian "$(detect_family)" "ubuntu is debian family"
printf 'ID=alpine\n' > "$tmp/os";                  assert_eq unknown "$(detect_family)" "alpine is unknown"
printf 'A=__ROOT__ B=__USER__\n' > "$tmp/t"
render_template "$tmp/t" "$tmp/out" ROOT=/opt/x USER=storsafe
assert_grep "$tmp/out" '^A=/opt/x B=storsafe$'
assert_exit 1 render_template "$tmp/t" "$tmp/out2" ROOT=/opt/x        # USER left over
assert_eq 240 "$(runtime_max_sec 5)" "runtime for 5 min"
assert_eq 120 "$(runtime_max_sec 2)" "runtime floor"
summary_add Pre OK "all good"; summary_add Grafana Check "not answering on 3000"
summary_print | grep -q '^Grafana *Check *not answering on 3000$' || { echo "FAIL summary row"; FAILED=1; }
assert_exit 1 http_ok http://127.0.0.1:1/ 3
exit "${FAILED:-0}"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tools/test/linux/test_lib.sh`
Expected: fails with `helpers.sh: No such file or directory`.

- [ ] **Step 3: Write `tools/test/linux/helpers.sh`, `tools/test/linux/run.sh` and `linux/lib.sh`**

`run.sh` loops over `tools/test/linux/test_*.sh`, runs each with `bash`, prints `PASS <name>` or `FAIL <name>`, exits 1 if any failed. `lib.sh` must be safe to source under `set -u` (initialise `SUMMARY_ROWS=()`).

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tools/test/linux/run.sh`
Expected: `PASS test_lib.sh`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add linux/lib.sh tools/test/linux/
git commit -m "Add the Linux shell library and test harness"
```

---

### Task 2: systemd unit templates

**Files:**
- Create: `linux/systemd/storsafe-collector.service`, `linux/systemd/storsafe-collector.timer`, `linux/systemd/storsafe-node-exporter.service`, `linux/systemd/storsafe-prometheus.service`, `linux/systemd/storsafe-grafana.service`
- Test: `tools/test/linux/test_templates.sh`

**Interfaces:**
- Consumes: `render_template` from Task 1.
- Produces: the five templates with exactly the placeholders listed in Global Constraints. Fixed lines the test checks:
  - collector service: `Type=oneshot`, `User=__USER__`, `WorkingDirectory=__ROOT__`, `ExecStart=__PWSH__ -NoProfile -NonInteractive -File __ROOT__/Export-StorSafeMetrics.ps1 -All -NonInteractive`, `RuntimeMaxSec=__RUNTIME__`, `NoNewPrivileges=true`, `PrivateTmp=true`.
  - timer: `OnBootSec=1min`, `OnUnitActiveSec=__INTERVAL__min`, `AccuracySec=15s`, `Persistent=false`, `WantedBy=timers.target`.
  - node_exporter: `ExecStart=__ROOT__/node_exporter/node_exporter --collector.textfile.directory=__ROOT__/metrics --web.listen-address=__LISTEN__`, `Restart=always`, `RestartSec=5`.
  - prometheus: `ExecStart=__ROOT__/prometheus/prometheus --config.file=__ROOT__/prometheus/prometheus.yml --storage.tsdb.path=__ROOT__/prometheus/data --storage.tsdb.retention.time=__RETENTION__d --web.listen-address=127.0.0.1:9090`, `WorkingDirectory=__ROOT__/prometheus`.
  - grafana: `ExecStart=__ROOT__/grafana/bin/grafana server --homepath __ROOT__/grafana`, `Environment=GF_PATHS_DATA=__ROOT__/grafana/data`, `Environment=GF_PATHS_LOGS=__ROOT__/grafana/data/log`, `Environment=GF_SERVER_HTTP_PORT=3000`, `WorkingDirectory=__ROOT__/grafana`.
  - all services: `User=__USER__`, `[Install] WantedBy=multi-user.target`, `After=network-online.target`.

- [ ] **Step 1: Write the failing test**

```bash
# tools/test/linux/test_templates.sh (same header as test_lib.sh)
units=$here/../../../linux/systemd; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for f in storsafe-collector.service storsafe-collector.timer storsafe-node-exporter.service storsafe-prometheus.service storsafe-grafana.service; do
  assert_file "$units/$f"
  render_template "$units/$f" "$tmp/$f" ROOT=/opt/sm USER=storsafe PWSH=/usr/bin/pwsh LISTEN=127.0.0.1:9182 RETENTION=180 INTERVAL=5 RUNTIME=240 \
    || { echo "FAIL render $f"; FAILED=1; }
  assert_not_grep "$tmp/$f" '__[A-Z]*__'
done
assert_grep "$tmp/storsafe-collector.service" '^ExecStart=/usr/bin/pwsh -NoProfile -NonInteractive -File /opt/sm/Export-StorSafeMetrics.ps1 -All -NonInteractive$'
assert_grep "$tmp/storsafe-collector.service" '^RuntimeMaxSec=240$'
assert_grep "$tmp/storsafe-collector.timer" '^OnUnitActiveSec=5min$'
assert_grep "$tmp/storsafe-node-exporter.service" -- '--web.listen-address=127.0.0.1:9182'
assert_grep "$tmp/storsafe-prometheus.service" -- '--storage.tsdb.retention.time=180d --web.listen-address=127.0.0.1:9090'
assert_grep "$tmp/storsafe-grafana.service" '^Environment=GF_PATHS_LOGS=/opt/sm/grafana/data/log$'
for f in storsafe-collector.service storsafe-node-exporter.service storsafe-prometheus.service storsafe-grafana.service; do
  assert_grep "$tmp/$f" '^NoNewPrivileges=true$'; assert_grep "$tmp/$f" '^User=storsafe$'
done
exit "${FAILED:-0}"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tools/test/linux/test_templates.sh`
Expected: `FAIL` lines for the five missing files.

- [ ] **Step 3: Write the five templates**

Each has a one-line `Description=` naming the StorSafe component. The timer's `[Unit]` has `Requires=storsafe-collector.service`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tools/test/linux/run.sh`
Expected: `PASS test_lib.sh`, `PASS test_templates.sh`.

- [ ] **Step 5: Commit**

```bash
git add linux/systemd/ tools/test/linux/test_templates.sh
git commit -m "Add systemd unit templates for the Linux host"
```

---

### Task 3: Tarball downloader

**Files:**
- Create: `linux/get-installers.sh`
- Test: `tools/test/linux/test_get_installers.sh`

**Interfaces:**
- Produces: `linux/get-installers.sh [--dest DIR] [--force] [--print-urls] [--node-exporter-version V] [--prometheus-version V] [--grafana-version V] [--powershell-version V]`. Defaults: dest `<repo>/installers`; Prometheus `3.15.0` and Grafana `12.0.2` (the Windows downloader's values); node_exporter and PowerShell at the newest 1.x and 7.4.x releases listed on their GitHub release pages on the day of implementation (the implementer looks them up and pins them in the script header comment, as the Windows script does).
- File names and URLs:
  - `node_exporter-<v>.linux-amd64.tar.gz` from `https://github.com/prometheus/node_exporter/releases/download/v<v>/`
  - `prometheus-<v>.linux-amd64.tar.gz` from `https://github.com/prometheus/prometheus/releases/download/v<v>/`
  - `grafana-<v>.linux-amd64.tar.gz` from `https://dl.grafana.com/oss/release/`
  - `powershell-<v>-linux-x64.tar.gz` from `https://github.com/PowerShell/PowerShell/releases/download/v<v>/`
- Behaviour copied from `Get-StorSafeInstallers.ps1`: existing files are kept unless `--force`; downloads go to `<name>.part` then are renamed; output lines `exists  <name>`, `get     <url>`, `ok      <name> (<MB> MB)`; a failed download prints a warning with the URL and the script exits 2 at the end; a table of the files in `dest` is printed last. The fetch command is `${STORSAFE_CURL:-curl} -fL --retry 3 -o <part> <url>` so tests substitute a fake.

- [ ] **Step 1: Write the failing test**

```bash
# tools/test/linux/test_get_installers.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/fakecurl" <<'EOF'
#!/usr/bin/env bash
out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; url=$1; shift; done
echo "$url" >> "${FAKE_LOG:?}"; [[ "$url" == *fail* ]] && exit 22; echo data > "$out"
EOF
chmod +x "$tmp/fakecurl"; export STORSAFE_CURL=$tmp/fakecurl FAKE_LOG=$tmp/log
gi=$here/../../../linux/get-installers.sh
assert_exit 0 "$gi" --dest "$tmp/inst" --prometheus-version 3.15.0 --grafana-version 12.0.2 --node-exporter-version 1.9.1 --powershell-version 7.4.6
assert_file "$tmp/inst/prometheus-3.15.0.linux-amd64.tar.gz"; assert_file "$tmp/inst/grafana-12.0.2.linux-amd64.tar.gz"
assert_file "$tmp/inst/node_exporter-1.9.1.linux-amd64.tar.gz"; assert_file "$tmp/inst/powershell-7.4.6-linux-x64.tar.gz"
assert_grep "$tmp/log" '^https://github.com/prometheus/prometheus/releases/download/v3.15.0/prometheus-3.15.0.linux-amd64.tar.gz$'
assert_grep "$tmp/log" '^https://dl.grafana.com/oss/release/grafana-12.0.2.linux-amd64.tar.gz$'
assert_eq 4 "$(wc -l < "$tmp/log")" "four downloads"
"$gi" --dest "$tmp/inst" --prometheus-version 3.15.0 --grafana-version 12.0.2 --node-exporter-version 1.9.1 --powershell-version 7.4.6 | grep -q '^exists  prometheus' || { echo "FAIL exists"; FAILED=1; }
assert_eq 4 "$(wc -l < "$tmp/log")" "second run downloads nothing"
assert_exit 2 "$gi" --dest "$tmp/inst2" --grafana-version fail
assert_exit 0 "$gi" --print-urls
exit "${FAILED:-0}"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tools/test/linux/test_get_installers.sh`
Expected: `FAIL` on the first `assert_exit` (script missing).

- [ ] **Step 3: Write `linux/get-installers.sh`**

Header comment in the style of the PowerShell script (what it downloads, where to check for newer versions, the offline instruction). Argument parsing with a `while [ $# -gt 0 ]; case "$1"` loop and a `usage` function; unknown options exit 2.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tools/test/linux/run.sh`
Expected: all three test files `PASS`.

- [ ] **Step 5: Commit**

```bash
git add linux/get-installers.sh tools/test/linux/test_get_installers.sh
git commit -m "Add the Linux tarball downloader"
```

---

### Task 4: Shared-file changes and the tar.gz package

**Files:**
- Modify: `.gitattributes`, `.gitignore`, `monitoring/prometheus.yml:1-14`, `tools/build-package.py`
- Test: `tools/test/linux/test_build_package.sh`

**Interfaces:**
- Produces: `python3 tools/build-package.py` writes both `dist/StorSafe-monitoring-v<VERSION>.zip` and `dist/StorSafe-monitoring-v<VERSION>.tar.gz`, same file list, top folder `StorSafeMonitoring/`, mode `0755` on every `linux/*.sh` entry in the tar and `0644` elsewhere; it prints both paths. `SKIP_DIRS` gains `grafana` and `node_exporter`; `.gitignore` gains `grafana/` and `node_exporter/`.
- `.gitattributes` gains `linux/** text eol=lf` and `.github/** text eol=lf`.
- `monitoring/prometheus.yml` keep regex becomes `'storsafe_.*|windows_textfile_.*|node_textfile_.*'`; the header comment names both exporters.

- [ ] **Step 1: Write the failing test**

```bash
# tools/test/linux/test_build_package.sh
repo=$here/../../..; ver=$(cat "$repo/VERSION")
python3 "$repo/tools/build-package.py" > /dev/null
assert_file "$repo/dist/StorSafe-monitoring-v$ver.tar.gz"
tar -tzvf "$repo/dist/StorSafe-monitoring-v$ver.tar.gz" > "$tmp/list"
assert_grep "$tmp/list" '^-rwxr-xr-x .* StorSafeMonitoring/linux/get-installers.sh$'
assert_grep "$tmp/list" '^-rw-r--r-- .* StorSafeMonitoring/linux/systemd/storsafe-collector.timer$'
assert_grep "$tmp/list" ' StorSafeMonitoring/Export-StorSafeMetrics.ps1$'
assert_not_grep "$tmp/list" ' StorSafeMonitoring/tools/'
zipn=$(python3 -c "import zipfile,sys; print(len(zipfile.ZipFile(sys.argv[1]).namelist()))" "$repo/dist/StorSafe-monitoring-v$ver.zip"); tarn=$(grep -c . "$tmp/list")
assert_eq "$zipn" "$tarn" "zip and tar carry the same number of entries"
assert_grep "$repo/monitoring/prometheus.yml" "regex: 'storsafe_.\*|windows_textfile_.\*|node_textfile_.\*'"
assert_grep "$repo/.gitattributes" '^linux/\*\* text eol=lf$'
exit "${FAILED:-0}"
```

(The shared `tmp` and `here` setup is the same header as `test_lib.sh`.)

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tools/test/linux/test_build_package.sh`
Expected: `FAIL` on the tar.gz `assert_file`.

- [ ] **Step 3: Make the changes**

In `build-package.py` use `tarfile.open(..., "w:gz")` with a `filter` function that sets `tarinfo.mode` to `0o755` for names matching `linux/*.sh` and `0o644` otherwise, `uid`/`gid` 0, `uname`/`gname` `root`, so the archive is reproducible. Keep the zip code as it is.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tools/test/linux/run.sh`
Expected: four `PASS` lines.

- [ ] **Step 5: Commit**

```bash
git add .gitattributes .gitignore monitoring/prometheus.yml tools/build-package.py tools/test/linux/test_build_package.sh
git commit -m "Build a tar.gz package and share prometheus.yml between both exporters"
```

---

### Task 5: Installer skeleton: arguments, preconditions, PowerShell, user, config

**Files:**
- Create: `linux/install.sh`
- Test: `tools/test/linux/test_install_args.sh`

**Interfaces:**
- Consumes: everything in `linux/lib.sh` (Task 1).
- Produces: `linux/install.sh` with this exact option set, parsed before anything else:
  `--root DIR` (default `/opt/storsafe-monitoring`, made absolute with `realpath -m`, trailing slash removed, rejected with exit 1 if it contains a space), `--user NAME` (default `storsafe`), `--interval-minutes N` (1..60, default 5), `--retention-days N` (1..3650, default 180), `--collector-only`, `--listen ADDR:PORT` (must match `^[^: ]+:[0-9]+$`, default `127.0.0.1:9182`, or `0.0.0.0:9182` with `--collector-only`), `--skip-credentials`, `--no-services`, `--unit-dir DIR` (default `/etc/systemd/system`; documented as for tests and containers), `--uninstall`, `-h`/`--help`. Unknown options print usage and exit 2. The script sources `$(dirname "$(realpath "$0")")/lib.sh`. Globals set for later tasks: `ROOT USER_NAME INTERVAL RETENTION COLLECTOR_ONLY LISTEN SKIP_CREDENTIALS NO_SERVICES UNIT_DIR PWSH_BIN INSTALLERS` (`INSTALLERS=$ROOT/installers`).
- Step functions, each ending in a `summary_add`: `step_preconditions`, `step_powershell`, `step_user`, `step_config`. `main` calls them in order, then (from Task 6 and 7) the remaining steps, then `summary_print`. Steps after `step_config` run through `run_step <label> <fn>`, which calls the function, and on a non-zero return adds a `Check` row `<label>  Check  failed; see the output above` when the step added no row itself, so later steps still run (spec section 7).
  - `step_preconditions`: must be root (`EUID`), `systemctl` on `PATH` unless `NO_SERVICES=1`, `uname -m` is `x86_64`, `curl` and `tar` present, otherwise `die`. For each of 9182, 9090 (full stack only) and 3000 (full stack only) `port_in_use` adds a `Check` row `port N already in use` instead of failing.
  - `step_powershell`: `PWSH_BIN=$(command -v pwsh || true)`; if empty, extract `$INSTALLERS/powershell-*-linux-x64.tar.gz` into `/opt/microsoft/powershell/7` (no `--strip-components`), `chmod 755 .../pwsh`, `ln -sf` to `/usr/bin/pwsh`, `PWSH_BIN=/usr/bin/pwsh`; no tarball means `summary_add PowerShell "Missing installer" "put powershell-<ver>-linux-x64.tar.gz in installers/ and re-run"` and the installer stops (exit 1) after printing the summary. Then `"$PWSH_BIN" -NoProfile -v` must succeed; if it fails, add a `Check` row whose note is the package line for `detect_family` (`dnf install libicu` for `rhel`; `apt-get install libicu72` for `debian`, with `libicu74` named too) and stop. (The test puts a fake `pwsh` first on `PATH`.)
  - `step_user`: `id -u "$USER_NAME"` or `useradd --system --home-dir "$ROOT" --no-create-home --shell /usr/sbin/nologin "$USER_NAME"` (`/sbin/nologin` where `/usr/sbin/nologin` is absent); create `creds state events metrics reports` under `$ROOT`; `chown` them to the user; `chmod 700 creds`.
  - `step_config`: if `$ROOT/StorSafe.config.json` is missing, copy `StorSafe.config.example.json` to it, add a `Check` row `edit the Servers list, then re-run`, print the summary and exit 1.

- [ ] **Step 1: Write the failing test**

```bash
# tools/test/linux/test_install_args.sh
inst=$here/../../../linux/install.sh; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
assert_exit 0 "$inst" --help
assert_exit 2 "$inst" --bogus
assert_exit 2 "$inst" --listen 9182 --no-services --root "$tmp/r"
assert_exit 2 "$inst" --listen :9182 --no-services --root "$tmp/r"
assert_exit 1 "$inst" --no-services --root "$tmp/with space"
mkdir -p "$tmp/noconfig"; cp "$here/../../../StorSafe.config.example.json" "$tmp/noconfig/"
out=$("$inst" --no-services --root "$tmp/noconfig/" --user "$(id -un)" 2>&1 || true)
assert_file "$tmp/noconfig/StorSafe.config.json"
echo "$out" | grep -q 'edit the Servers list' || { echo "FAIL config hint"; FAILED=1; }
echo "$out" | grep -q "$tmp/noconfig//" && { echo "FAIL double slash in root"; FAILED=1; }
out=$(cd "$tmp" && "$inst" --no-services --root noconfig --user "$(id -un)" 2>&1 || true)
echo "$out" | grep -q "$tmp/noconfig" || { echo "FAIL relative root not made absolute"; FAILED=1; }
# broken pwsh: a fake that exits 1 must stop the installer with the package hint
mkdir -p "$tmp/bin"; printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/pwsh"; chmod +x "$tmp/bin/pwsh"
printf 'ID=rocky\nID_LIKE=rhel\n' > "$tmp/os"
out=$(PATH="$tmp/bin:$PATH" OS_RELEASE_FILE=$tmp/os "$inst" --no-services --root "$tmp/noconfig" --user "$(id -un)" 2>&1 || true)
echo "$out" | grep -q 'dnf install libicu' || { echo "FAIL icu hint"; FAILED=1; }
exit "${FAILED:-0}"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tools/test/linux/test_install_args.sh`
Expected: `FAIL` on the first `assert_exit` (script missing).

- [ ] **Step 3: Write `linux/install.sh` up to `step_config`**

`main` for now: parse, `step_preconditions`, `step_powershell`, `step_user`, `step_config`, `summary_print`. The usage text lists every option with its default, one per line, in the order above.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tools/test/linux/run.sh` (as root in the container, with the real `pwsh` on `PATH`)
Expected: five `PASS` lines.

- [ ] **Step 5: Commit**

```bash
git add linux/install.sh tools/test/linux/test_install_args.sh
git commit -m "Add the Linux installer: arguments, preconditions, PowerShell, user and config steps"
```

---

### Task 6: Installer: credentials, collector test run, components, unit rendering

**Files:**
- Modify: `linux/install.sh`, `tools/test/linux/helpers.sh` (`make_fake_tarballs`)
- Test: `tools/test/linux/test_install_no_services.sh`

**Interfaces:**
- Consumes: Task 5 globals and step functions; `render_template`, `runtime_max_sec` (Task 1); templates (Task 2).
- Produces, appended to `main` after `step_config`: `step_credentials`, `step_collector_test`, `step_node_exporter`, `step_prometheus`, `step_grafana`, `render_units`, and `print_next_steps` (after `summary_print`).
  - `step_credentials`: skipped with a `Skipped` row when `SKIP_CREDENTIALS=1`; otherwise, for each server in the config whose `CredentialFile` (relative paths resolved against `$ROOT`) is missing, run `New-StorSafeCredentialFile -Path <file>` through `run_as_user` (below) with `Import-Module $ROOT/StorSafe.psm1`, then `chmod 600`. Server names and credential paths are read with `"$PWSH_BIN" -NoProfile -Command` that imports the module and prints `name<TAB>credentialfile` per server (the module's `Get-StorSafeConfig`, which `Export-StorSafeMetrics.ps1` already uses, resolves relative paths).
  - `run_as_user <cmd...>`: runs the command directly when `USER_NAME` equals the current user, otherwise `runuser -u "$USER_NAME" -- <cmd...>`.
  - `step_collector_test`: `run_as_user "$PWSH_BIN" -NoProfile -NonInteractive -File "$ROOT/Export-StorSafeMetrics.ps1" -All -NonInteractive`; exit 3 or a missing `$ROOT/metrics/storsafe.prom` stops the installer (summary printed, exit 1); exit 2 is a `Check` row `a check failed; see the output above`; exit 0 is `OK` with the collector's `Wrote ...` line as the note.
  - `extract_component <name> <glob> <strip>`: finds the newest `$INSTALLERS/<glob>`; `Missing installer` row and return 1 when none; compares the tarball's basename with `$ROOT/<name>/.version`; when different (or absent) empties `$ROOT/<name>` except `data/`, runs `tar -xzf <file> -C $ROOT/<name> --strip-components=<strip>`, writes the basename to `.version`, returns 0 with an `OK` row `extracted <basename>`; when equal, `OK` row `already extracted <basename>`.
  - `step_node_exporter`: `extract_component node_exporter 'node_exporter-*.linux-amd64.tar.gz' 1`.
  - `step_prometheus`: `Skipped` row when `COLLECTOR_ONLY=1`; else `extract_component prometheus 'prometheus-*.linux-amd64.tar.gz' 1`, then copy `$ROOT/monitoring/prometheus.yml` to `$ROOT/prometheus/prometheus.yml` (always), `mkdir -p $ROOT/prometheus/data` owned by the user.
  - `step_grafana`: `Skipped` when `COLLECTOR_ONLY=1`; else `extract_component grafana 'grafana-*.linux-amd64.tar.gz' 1`, then copy `monitoring/grafana/storsafe-datasource.yaml` to `$ROOT/grafana/conf/provisioning/datasources/` and write `storsafe-dashboards.yaml` into `.../provisioning/dashboards/` with `__DASHBOARD_DIR__` replaced by `$ROOT/monitoring/dashboards` (plain `sed`, this placeholder belongs to the Grafana file, not to `render_template`), `mkdir -p $ROOT/grafana/data/log` owned by the user.
  - `render_units`: renders the collector service and timer and the node_exporter service into `$UNIT_DIR`, plus Prometheus and Grafana unless `COLLECTOR_ONLY=1`, with `ROOT=$ROOT USER=$USER_NAME PWSH=$PWSH_BIN LISTEN=$LISTEN RETENTION=$RETENTION INTERVAL=$INTERVAL RUNTIME=$(runtime_max_sec "$INTERVAL")`. A leftover placeholder is a `die`. Records in `CHANGED_UNITS` the names whose rendered content differs from the file that was there before (Task 7 restarts those).
  - `print_next_steps`: full stack: the Grafana URL `http://<host>:3000` and the two control commands; collector-only: the scrape job block for an existing Prometheus (`job_name: storsafe`, target `<this host>:9182`, the same `metric_relabel_configs` as `monitoring/prometheus.yml`) and the sentence pointing at `monitoring/dashboards/*.json` for import plus the data source uid `storsafe-prometheus`.
- `make_fake_tarballs <dir>` (helpers): writes `node_exporter-1.9.1.linux-amd64.tar.gz` (top folder `node_exporter-1.9.1.linux-amd64/` with an executable `node_exporter` that is `#!/bin/sh` + `exit 0`), `prometheus-3.15.0.linux-amd64.tar.gz` (`prometheus`, `promtool` stubs and a `prometheus.yml`), `grafana-12.0.2.linux-amd64.tar.gz` (top folder `grafana-v12.0.2/` with `bin/grafana` stub and empty `conf/provisioning/datasources` and `conf/provisioning/dashboards`), and `powershell-7.4.6-linux-x64.tar.gz` (a `pwsh` stub at the archive root).

- [ ] **Step 1: Write the failing test**

```bash
# tools/test/linux/test_install_no_services.sh  (needs the mock API on 127.0.0.1:18080 and pwsh on PATH)
inst=$here/../../../linux/install.sh; repo=$here/../../..; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
root=$tmp/root; mkdir -p "$root"; (cd "$repo" && git archive HEAD | tar -x -C "$root")
cp "$repo/tools/test/mock.config.json" "$root/StorSafe.config.json"; cp "$repo/tools/test/mock-credential.xml" "$root/"
make_fake_tarballs "$root/installers"
assert_exit 0 "$inst" --no-services --root "$root" --user "$(id -un)" --unit-dir "$tmp/units" --skip-credentials
assert_file "$root/metrics/storsafe.prom"
assert_file "$root/node_exporter/node_exporter"; assert_eq node_exporter-1.9.1.linux-amd64.tar.gz "$(cat "$root/node_exporter/.version")"
assert_file "$root/prometheus/prometheus.yml"; assert_file "$root/grafana/bin/grafana"
assert_grep "$root/grafana/conf/provisioning/dashboards/storsafe-dashboards.yaml" "path: '$root/monitoring/dashboards'"
for u in storsafe-collector.service storsafe-collector.timer storsafe-node-exporter.service storsafe-prometheus.service storsafe-grafana.service; do
  assert_file "$tmp/units/$u"; assert_not_grep "$tmp/units/$u" '__[A-Z]*__'
done
assert_grep "$tmp/units/storsafe-node-exporter.service" -- '--web.listen-address=127.0.0.1:9182'
# second run: nothing re-extracted; newer tarball: re-extracted
out=$("$inst" --no-services --root "$root" --user "$(id -un)" --unit-dir "$tmp/units" --skip-credentials)
echo "$out" | grep -q 'already extracted node_exporter-1.9.1' || { echo "FAIL idempotent"; FAILED=1; }
cp "$root/installers/node_exporter-1.9.1.linux-amd64.tar.gz" "$root/installers/node_exporter-1.9.2.linux-amd64.tar.gz"
"$inst" --no-services --root "$root" --user "$(id -un)" --unit-dir "$tmp/units" --skip-credentials > /dev/null
assert_eq node_exporter-1.9.2.linux-amd64.tar.gz "$(cat "$root/node_exporter/.version")" "newer tarball wins"
# collector-only: no Prometheus or Grafana, node_exporter on all interfaces, scrape job printed
rm -rf "$tmp/units2"
out=$("$inst" --no-services --collector-only --root "$root" --user "$(id -un)" --unit-dir "$tmp/units2" --skip-credentials)
[ -e "$tmp/units2/storsafe-prometheus.service" ] && { echo "FAIL prometheus unit in collector-only"; FAILED=1; }
assert_grep "$tmp/units2/storsafe-node-exporter.service" -- '--web.listen-address=0.0.0.0:9182'
echo "$out" | grep -q 'job_name: storsafe' || { echo "FAIL scrape job"; FAILED=1; }
exit "${FAILED:-0}"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tools/test/linux/test_install_no_services.sh`
Expected: `FAIL` at `assert_file .../metrics/storsafe.prom` or earlier (`make_fake_tarballs` undefined).

- [ ] **Step 3: Implement `make_fake_tarballs` and the step functions**

Collector-only `LISTEN` default is decided after parsing: if `--listen` was not given and `COLLECTOR_ONLY=1`, `LISTEN=0.0.0.0:9182`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tools/test/linux/run.sh`
Expected: six `PASS` lines.

- [ ] **Step 5: Commit**

```bash
git add linux/install.sh tools/test/linux/helpers.sh tools/test/linux/test_install_no_services.sh
git commit -m "Linux installer: credentials, collector test run, components and unit rendering"
```

---

### Task 7: Installer: services, uninstall, re-run

**Files:**
- Modify: `linux/install.sh`, `tools/test/linux/helpers.sh` (`make_systemctl_shim`)
- Test: `tools/test/linux/test_install_services.sh`

**Interfaces:**
- Consumes: `CHANGED_UNITS`, `render_units`, `http_ok` (Tasks 1 and 6).
- Produces:
  - `systemctl_run <args...>`: runs `systemctl <args>`, or when `NO_SERVICES=1` prints `would run: systemctl <args>` and returns 0 (spec: `--no-services` prints the commands it would run).
  - `step_services` (adds a `Skipped` row `--no-services; commands printed above` when `NO_SERVICES=1`, after printing them through `systemctl_run`): `systemctl daemon-reload`; `systemctl enable --now` for each rendered unit (the timer, not the collector service); `systemctl restart` for every name in `CHANGED_UNITS` that is already active; then `http_ok` on `http://127.0.0.1:9182/metrics` and, full stack, `http://127.0.0.1:9090/-/ready` and `http://127.0.0.1:3000/api/health`, `${STORSAFE_HTTP_TIMEOUT:-60}` seconds each, `OK` or `Check` row `not answering on <port> after <N> s` per component.
  - `do_uninstall` (when `--uninstall`): for each of the five unit names, `systemctl disable --now <unit>` if the file exists in `$UNIT_DIR`, remove the file, then `daemon-reload`; summary rows per unit; final note listing what was left (folder, user, PowerShell) and the manual commands.
  - `make_systemctl_shim <dir>` (helpers): writes `<dir>/systemctl` that appends its arguments as one line to `$SYSTEMCTL_LOG` and exits 0, and answers `is-active <unit>` with exit 0 when the unit's name is listed in `$SYSTEMCTL_ACTIVE` (a space-separated env var), else 3.

- [ ] **Step 1: Write the failing test**

```bash
# tools/test/linux/test_install_services.sh (same setup lines as test_install_no_services.sh, then:)
make_systemctl_shim "$tmp/bin"; export SYSTEMCTL_LOG=$tmp/sc.log SYSTEMCTL_ACTIVE="storsafe-node-exporter.service"
PATH="$tmp/bin:$PATH" "$inst" --root "$root" --user "$(id -un)" --unit-dir "$tmp/units" --skip-credentials > "$tmp/out" 2>&1 || true
assert_grep "$tmp/sc.log" '^daemon-reload$'
assert_grep "$tmp/sc.log" '^enable --now storsafe-collector.timer$'
assert_grep "$tmp/sc.log" '^enable --now storsafe-grafana.service$'
assert_not_grep "$tmp/sc.log" '^enable --now storsafe-collector.service$'
assert_grep "$tmp/out" 'not answering on 9090 after 2 s'        # nothing really listens; STORSAFE_HTTP_TIMEOUT=2 is exported in the setup lines
: > "$SYSTEMCTL_LOG"; sed -i 's/RestartSec=5/RestartSec=6/' "$tmp/units/storsafe-node-exporter.service"   # simulate a template change
PATH="$tmp/bin:$PATH" "$inst" --root "$root" --user "$(id -un)" --unit-dir "$tmp/units" --skip-credentials > /dev/null 2>&1 || true
assert_grep "$tmp/sc.log" '^restart storsafe-node-exporter.service$'
: > "$SYSTEMCTL_LOG"
PATH="$tmp/bin:$PATH" "$inst" --uninstall --root "$root" --unit-dir "$tmp/units" > "$tmp/un" 2>&1
assert_grep "$tmp/sc.log" '^disable --now storsafe-collector.timer$'
[ -e "$tmp/units/storsafe-prometheus.service" ] && { echo "FAIL unit not removed"; FAILED=1; }
assert_grep "$tmp/un" 'userdel'
exit "${FAILED:-0}"
```

The test exports `STORSAFE_HTTP_TIMEOUT=2` so the three waits take six seconds instead of three minutes.

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tools/test/linux/test_install_services.sh`
Expected: `FAIL` on `daemon-reload` (step not implemented) or `make_systemctl_shim` undefined.

- [ ] **Step 3: Implement `step_services`, `do_uninstall`, `make_systemctl_shim`**

`main` order is now: parse; if `--uninstall` then preconditions (root only) and `do_uninstall` and exit; else the steps of Tasks 5 and 6, `render_units`, `step_services`, `summary_print`, `print_next_steps`. The exit code is 1 when any row is `Check` or `Missing installer`, else 0.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tools/test/linux/run.sh`
Expected: seven `PASS` lines.

- [ ] **Step 5: Commit**

```bash
git add linux/install.sh tools/test/linux/helpers.sh tools/test/linux/test_install_services.sh
git commit -m "Linux installer: enable the units, wait for the ports, add --uninstall"
```

---

### Task 8: Control script

**Files:**
- Create: `linux/storsafe-control.sh`
- Test: `tools/test/linux/test_control.sh`

**Interfaces:**
- Consumes: `make_systemctl_shim` (Task 7), `http_ok` (Task 1).
- Produces: `linux/storsafe-control.sh <status|stop|start|pause|resume>`; any other argument prints usage and exits 2. Unit names are the five from Task 2; "present" means `systemctl cat <unit>` succeeds (the shim answers `cat` with exit 0 when the name is in `$SYSTEMCTL_PRESENT`, else 1).
  - `status`: a table `Unit  Active  Enabled  Detail` with one row per present unit (`systemctl is-active`, `is-enabled`); the timer's detail is `next run <value of NextElapseUSecRealtime from systemctl show>`; the collector service's detail is `last run <ExecMainExitTimestamp>, result <ExecMainStatus translated: 0 OK, 2 a check failed, 3 config error>`; node_exporter, Prometheus and Grafana details say `answering on <port>` or `not answering on <port>` from `http_ok` with a 3 s timeout. Absent units get the row `<unit>  absent`. Exit 0.
  - `stop`: `systemctl stop` the timer, then node_exporter, Prometheus, Grafana (present ones only). `start`: the reverse order. `pause`: `systemctl stop storsafe-collector.timer`. `resume`: `systemctl start storsafe-collector.timer` then `systemctl start storsafe-collector.service`. After each action the script checks `is-active` (or inactive for stop/pause) on every unit it touched and exits 1 if one is not in the expected state; absent units are reported as `absent` and never cause a non-zero exit.

- [ ] **Step 1: Write the failing test**

```bash
# tools/test/linux/test_control.sh
ctl=$here/../../../linux/storsafe-control.sh; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
make_systemctl_shim "$tmp/bin"; export SYSTEMCTL_LOG=$tmp/log PATH="$tmp/bin:$PATH"
export SYSTEMCTL_PRESENT="storsafe-collector.service storsafe-collector.timer storsafe-node-exporter.service" SYSTEMCTL_ACTIVE="storsafe-collector.timer storsafe-node-exporter.service"
assert_exit 2 "$ctl" bogus
"$ctl" status > "$tmp/st"; assert_grep "$tmp/st" '^storsafe-prometheus.service *absent'; assert_grep "$tmp/st" 'not answering on 9182'
: > "$SYSTEMCTL_LOG"; export SYSTEMCTL_ACTIVE=""
assert_exit 0 "$ctl" pause;  assert_grep "$SYSTEMCTL_LOG" '^stop storsafe-collector.timer$'; assert_not_grep "$SYSTEMCTL_LOG" 'prometheus'
: > "$SYSTEMCTL_LOG"; export SYSTEMCTL_ACTIVE="storsafe-collector.timer storsafe-collector.service storsafe-node-exporter.service"
assert_exit 0 "$ctl" resume; assert_grep "$SYSTEMCTL_LOG" '^start storsafe-collector.service$'
: > "$SYSTEMCTL_LOG"; export SYSTEMCTL_ACTIVE=""
assert_exit 0 "$ctl" stop; assert_eq "$(printf 'stop storsafe-collector.timer\nstop storsafe-node-exporter.service')" "$(grep '^stop' "$SYSTEMCTL_LOG")" "stop order, present units only"
export SYSTEMCTL_ACTIVE="storsafe-collector.timer"   # node_exporter did not stop
assert_exit 1 "$ctl" stop
exit "${FAILED:-0}"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tools/test/linux/test_control.sh`
Expected: `FAIL` on the first `assert_exit` (script missing).

- [ ] **Step 3: Extend the shim and write `linux/storsafe-control.sh`**

First extend `make_systemctl_shim` for `cat` (exit 0 when the unit is in `$SYSTEMCTL_PRESENT`, else 1), `is-enabled` (exit 0 when present) and `show` (prints `NextElapseUSecRealtime=` and `ExecMainStatus=0` lines); the Task 7 test must still pass. Then write the script. Header comment with the five actions in the words of `StorSafeMonitoringControl.ps1`'s synopsis and the example `sudo /opt/storsafe-monitoring/linux/storsafe-control.sh status`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tools/test/linux/run.sh`
Expected: eight `PASS` lines.

- [ ] **Step 5: Commit**

```bash
git add linux/storsafe-control.sh tools/test/linux/helpers.sh tools/test/linux/test_control.sh
git commit -m "Add the Linux control script"
```

---

### Task 9: Continuous integration

**Files:**
- Create: `.github/workflows/ci.yml`, `tools/test/linux/smoke.sh`

**Interfaces:**
- Produces `tools/test/linux/smoke.sh [--services]`, run from the repository root by CI (and by hand on a VM): copies the checkout to `$ROOT` (`/opt/storsafe-monitoring` with `--services`, a temp dir otherwise), puts `tools/test/mock.config.json` and `tools/test/mock-credential.xml` in place as `StorSafe.config.json` and `mock-credential.xml`, starts `tools/test/mock_api.py 18080` in the background, runs `linux/get-installers.sh --dest $ROOT/installers`, then `linux/install.sh --root $ROOT --skip-credentials` with `--collector-only --no-services --unit-dir $ROOT/units --user root` (without `--services`) or the full stack as root (with `--services`); asserts `metrics/storsafe.prom` exists and no rendered unit holds a placeholder; with `--services` also: `curl -fsS` on `127.0.0.1:9182/metrics`, `9090/-/ready`, `3000/api/health`, `python3 tools/test/validate_dashboards.py --prom http://127.0.0.1:9090 --servers MOCK-A,MOCK-B` reporting `errors 0`, `storsafe-control.sh status`, `pause`, `resume`, `stop`, `start`, and finally `install.sh --uninstall`.
- `ci.yml` on push and pull request, four jobs:
  1. `lint` (ubuntu-latest): `sudo apt-get install -y shellcheck`; `shellcheck linux/*.sh tools/test/linux/*.sh`; `bash -n` on the same; `pwsh -NoProfile -Command` running `[System.Management.Automation.Language.Parser]::ParseFile` over every `*.ps1`/`*.psm1` and failing on any error; `python3 -m py_compile tools/*.py tools/test/*.py`.
  2. `kit` (ubuntu-latest): the three steps of `tools/test/README.md` plus `bash tools/test/linux/run.sh`; `promtool` and `prometheus` come from the Prometheus tarball that `linux/get-installers.sh --dest /tmp/inst` downloads.
  3. `smoke` (matrix `container: [rockylinux:9, debian:12]`): install `curl tar python3 git` and the ICU package for the family (`dnf install -y libicu` / `apt-get install -y libicu72`), then `bash tools/test/linux/smoke.sh`.
  4. `full` (ubuntu-latest, needs `lint`): `sudo bash tools/test/linux/smoke.sh --services`.

- [ ] **Step 1: Write `smoke.sh` and run it locally without `--services`**

Run: `bash tools/test/linux/smoke.sh` (container, mock not already running on 18080, or stop it first with `fuser -k 18080/tcp`)
Expected: last line `smoke OK`, exit 0.

- [ ] **Step 2: Write `.github/workflows/ci.yml`**

Validate with `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))"` (PyYAML is present on the runner; if absent locally, `python3 -m pip install pyyaml` once).

- [ ] **Step 3: Commit and push, then read the Actions result**

```bash
git add .github/workflows/ci.yml tools/test/linux/smoke.sh
git commit -m "Add CI: lint, test kit, container smoke tests and a full systemd run"
git push
```

Expected: all four jobs green on the push. A red job is fixed in this task before moving on (the session can read job logs through the GitHub tools).

---

### Task 10: Documentation, version and package

**Files:**
- Modify: `README.md`, `CLAUDE.md`, `CHANGELOG.md`, `VERSION`, `installers/README.txt`
- Verify: `tools/test/linux/run.sh`, `python3 tools/build-package.py`

**Interfaces:**
- Consumes: every flag name and file name from Tasks 3, 5, 7 and 8 exactly as implemented.

- [ ] **Step 1: README**

Add to the Layout table rows for `linux\install.sh`, `linux\get-installers.sh`, `linux\storsafe-control.sh`, `linux\systemd\`, and `grafana\` / `node_exporter\` as created-at-install folders. Add a section "Install on a Linux machine" after "Install on a new Windows machine" with the same structure: prerequisites (RHEL family 8/9 or Debian 12/Ubuntu LTS, x86_64, systemd, root via sudo, `curl`, `tar`, the ICU package line per family, network to the appliances and, for the download step only, to GitHub and dl.grafana.com), the steps (`git clone` or extract the tar.gz to `/opt/storsafe-monitoring`; `sudo linux/get-installers.sh` or copy the four tarballs into `installers/`; copy and edit the config; `sudo linux/install.sh`; check with `linux/storsafe-control.sh status` and the three URLs), the collector-only variant (`--collector-only`, the firewall lines `firewall-cmd --permanent --add-port=9182/tcp && firewall-cmd --reload` and `ufw allow 9182/tcp`, the scrape job block, the dashboard import note), the credential-file paragraph (no DPAPI on Linux; `creds/` 0700, files 0600, owned by `storsafe`), and the Grafana first-login note (default admin login, change it, same as the Windows section). Add Linux paragraphs to "Stopping and starting for maintenance" (the control script, `journalctl -u storsafe-collector`), "Upgrading an existing install" (`tar -xzf StorSafe-monitoring-v<ver>.tar.gz --strip-components=1 -C /opt/storsafe-monitoring --exclude=StorSafe.config.json --exclude='creds/*'` or `git pull`, then re-run `install.sh` with the same flags) and "Uninstall" (`sudo linux/install.sh --uninstall`, then the `rm -rf`, `userdel storsafe` and `rm -rf /opt/microsoft/powershell` lines). Mention `linux/get-installers.sh --print-urls` for offline hosts. Update the architecture block under the title to name node_exporter beside windows_exporter.

- [ ] **Step 2: CLAUDE.md, CHANGELOG, VERSION, installers/README.txt**

`CLAUDE.md`: a layout line for `linux\` and `tools\test\linux\`; under Hard rules a bullet: shell scripts use `set -euo pipefail`, pass shellcheck, keep LF endings, keep the unit placeholder names, and name distro packages only in the preconditions step; under Testing notes: `bash tools/test/linux/run.sh` needs `pwsh` on `PATH` and the mock on 18080, `smoke.sh --services` needs a systemd host. `CHANGELOG.md`: a `## 5.1.0 (<date>)` entry listing the Linux host support, the collector-only mode, the tar.gz package, the shared `prometheus.yml` regex and CI. `VERSION`: `5.1.0`. `installers/README.txt`: the four Linux tarball names next to the Windows ones.

- [ ] **Step 3: Verify**

Run: `bash tools/test/linux/run.sh && python3 tools/build-package.py | head -2 && python3 tools/test/validate_dashboards.py --prom http://127.0.0.1:9090 --servers STORSAFE-01,STORSAFE-02` (the last against the sandbox Prometheus of the screenshot setup if it is still running, otherwise the kit's Prometheus on 19090 without `--prom`).
Expected: all `PASS`, both archive paths printed, `errors 0`. Also `git grep -n 'localhost' linux/ README.md` returns only the pre-existing Windows `http://localhost:3000` wording of the Windows sections, if any, and nothing new.

- [ ] **Step 4: Commit and push**

```bash
git add README.md CLAUDE.md CHANGELOG.md VERSION installers/README.txt
git commit -m "Document the Linux host; 5.1.0"
git push
```

Expected: CI green. Tell the maintainer that 5.1.0 is ready for the acceptance test on a RHEL VM and for tagging.
