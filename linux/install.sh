#!/usr/bin/env bash
# Installs the StorSafe monitoring stack from this folder on a Linux host: the service account,
# PowerShell 7 for the collector, credential files, node_exporter, Prometheus, Grafana (with data
# source and dashboards provisioned) and the systemd units and timer that run them. This is the
# Linux counterpart of Install-StorSafeMonitoring.ps1.
#
# Extract the package where it should live (default /opt/storsafe-monitoring; the path must not
# contain a space) or clone it there, and run this script as root, e.g. with sudo. The folder is the
# install root:
#
#   <root>/metrics      node_exporter textfile directory (storsafe.prom)
#   <root>/reports      CSV reports from the report scripts
#   <root>/creds        credential files (mode 0700, owned by the service account)
#   <root>/installers   drop the third-party tarballs here (linux/get-installers.sh fills it)
#   <root>/state        collector state (event log bookmark, cached hourly checks)
#   <root>/events       daily raw event log CSVs per appliance
#   <root>/node_exporter, prometheus, grafana
#                       extracted from the tarballs in installers/ (Prometheus and Grafana unless
#                       --collector-only); a newer tarball there is an upgrade, data/ is kept
#
# Unlike the Windows installer this does not need to run as the account that runs the collector:
# the collector runs as a dedicated system account (default storsafe), created if it is missing.
#
# Each step is idempotent and can be re-run after adding installers or editing the config. The
# summary at the end lists every step as OK, Skipped, Missing installer or Check. A step that
# nothing after it can work without stops the installer: the preconditions with an error message,
# PowerShell, the user, the config and the collector test run (a config or credential error) after
# printing the summary of what was done so far.
#
# Exit status: 0 when the installer ran through, 1 when a step stopped it, 2 when the command line
# is wrong.
#
# Examples:
#   sudo /opt/storsafe-monitoring/linux/install.sh
#   sudo /opt/storsafe-monitoring/linux/install.sh --collector-only --interval-minutes 2
#   sudo /opt/storsafe-monitoring/linux/install.sh --root /srv/storsafe --user svc-storsafe
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

# Where the PowerShell tarball is extracted (Microsoft's own packages use this folder too) and the
# link that puts pwsh on the PATH.
PWSH_HOME=/opt/microsoft/powershell/7
PWSH_LINK=/usr/bin/pwsh
PWSH_BIN=""

# Unit names whose service must be restarted if it runs: a rendered unit file or a config or
# program that changed since the last run. Filled by mark_changed, read by the services step.
CHANGED_UNITS=()

usage() {
    cat << 'EOF'
usage: install.sh [--root DIR] [--user NAME] [--interval-minutes N] [--retention-days N]
                  [--collector-only] [--listen ADDR:PORT] [--skip-credentials]
                  [--no-services] [--unit-dir DIR] [--uninstall]

  --root DIR              install folder, the folder holding this package
                          (default /opt/storsafe-monitoring; no spaces)
  --user NAME             system account that runs the collector and the services; created if
                          missing (default storsafe)
  --interval-minutes N    minutes between collector runs, 1..60 (default 5)
  --retention-days N      Prometheus data retention in days, 1..3650 (default 180)
  --collector-only        install the collector and node_exporter only, for a host that already
                          runs Prometheus and Grafana (default: the full stack)
  --listen ADDR:PORT      address node_exporter serves the metrics on (default 127.0.0.1:9182;
                          0.0.0.0:9182 with --collector-only)
  --skip-credentials      do not prompt for missing appliance credential files
  --no-services           do not require or use systemd: write the files, start nothing
  --unit-dir DIR          folder the systemd unit files are written to
                          (default /etc/systemd/system; for tests and containers)
  --uninstall             stop and remove the units; the folder, the user and PowerShell stay
  -h, --help              show this text
EOF
}

# Prints "error: <message>" and the usage text to stderr and exits 2.
usage_error() {
    printf 'error: %s\n' "$1" >&2
    usage >&2
    exit 2
}

# need_value "$@": the option in $1 must be followed by a value that is not empty and does not start
# with a dash (that would be the next option; give a folder such as -x as ./-x).
need_value() {
    if [[ $# -lt 2 || -z $2 || $2 == -* ]]; then
        usage_error "$1 needs a value"
    fi
}

# need_int <option> <value> <min> <max>: usage error unless the value is a whole number in range.
# The regex comes first so that the arithmetic never sees a leading zero (octal) or a non-number.
need_int() {
    if [[ ! $2 =~ ^[1-9][0-9]{0,5}$ ]] || [[ $2 -lt $3 || $2 -gt $4 ]]; then
        usage_error "$1 must be a whole number from $3 to $4"
    fi
}

# need_listen <value>: usage error unless the value is ADDR:PORT (no colon or space in ADDR) with a
# port from 1 to 65535 and no leading zero, so that the port can be probed and rendered as it is.
need_listen() {
    local re='^[^: ]+:[0-9]+$' port_re='^[1-9][0-9]{0,4}$' port=${1##*:}
    if [[ ! $1 =~ $re || ! $port =~ $port_re ]] || [[ $port -gt 65535 ]]; then
        usage_error "--listen must be ADDR:PORT with a port from 1 to 65535, for example 127.0.0.1:9182"
    fi
}

# parse_args "$@": sets the settings below as globals, all before any step runs. Read by the steps:
# ROOT USER_NAME INTERVAL RETENTION COLLECTOR_ONLY LISTEN SKIP_CREDENTIALS NO_SERVICES UNIT_DIR
# UNINSTALL INSTALLERS. -h/--help prints the usage and exits 0 as soon as it is seen.
# shellcheck disable=SC2034
parse_args() {
    local listen_given=0
    ROOT=/opt/storsafe-monitoring
    USER_NAME=storsafe
    INTERVAL=5
    RETENTION=180
    COLLECTOR_ONLY=0
    LISTEN=127.0.0.1:9182
    SKIP_CREDENTIALS=0
    NO_SERVICES=0
    UNIT_DIR=/etc/systemd/system
    UNINSTALL=0

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h | --help) usage; exit 0 ;;
            --root) need_value "$@"; ROOT=$(realpath -m -- "$2"); shift 2 ;;
            --user) need_value "$@"; USER_NAME=$2; shift 2 ;;
            --interval-minutes) need_value "$@"; need_int "$1" "$2" 1 60; INTERVAL=$2; shift 2 ;;
            --retention-days) need_value "$@"; need_int "$1" "$2" 1 3650; RETENTION=$2; shift 2 ;;
            --collector-only) COLLECTOR_ONLY=1; shift ;;
            --listen) need_value "$@"; need_listen "$2"; LISTEN=$2; listen_given=1; shift 2 ;;
            --skip-credentials) SKIP_CREDENTIALS=1; shift ;;
            --no-services) NO_SERVICES=1; shift ;;
            --unit-dir) need_value "$@"; UNIT_DIR=$(realpath -m -- "$2"); shift 2 ;;
            --uninstall) UNINSTALL=1; shift ;;
            *) usage_error "unknown option: $1" ;;
        esac
    done

    # A collector-only host is scraped by a Prometheus somewhere else, so it listens on every interface.
    if [[ $COLLECTOR_ONLY -eq 1 && $listen_given -eq 0 ]]; then
        LISTEN=0.0.0.0:9182
    fi
    # The units and the Prometheus config take the path unquoted, so a space would break them.
    if [[ $ROOT == *[[:space:]]* ]]; then
        die "the install folder '$ROOT' contains a space; move the package to a path without spaces (e.g. /opt/storsafe-monitoring) and pass --root"
    fi
    INSTALLERS=$ROOT/installers
}

# Prints the summary collected so far and exits 1: the end of a step that nothing after it can work
# without.
stop_here() {
    log_step 'Install summary'
    summary_print
    exit 1
}

# run_step <label> <function>: runs one installer step so that a failure is a Check row and the
# steps after it still run. A step that returns non-zero without adding a row of its own gets
# "<label>  Check  failed; see the output above". Inside "if !" set -e is off for the whole step,
# so a step must test the commands it cares about and return 1 itself.
run_step() {
    local label=$1 fn=$2 before=${#SUMMARY_ROWS[@]}
    if ! "$fn"; then
        if [[ ${#SUMMARY_ROWS[@]} -le $before ]]; then
            summary_add "$label" Check 'failed; see the output above'
        fi
    fi
    return 0
}

# find_installer <glob>: prints the newest file in $INSTALLERS that matches the glob (version
# order), or nothing when there is none.
find_installer() {
    compgen -G "$INSTALLERS/$1" | sort -V | tail -n 1 || true
    return 0
}

# icu_package_line: prints the command that installs the ICU library PowerShell needs, for the
# distribution family. The package names live here and nowhere else.
icu_package_line() {
    case $(detect_family) in
        rhel) echo 'dnf install libicu' ;;
        debian) echo 'apt-get install libicu72 (Debian 12) or libicu74 (Ubuntu 24.04)' ;;
        *) echo "install your distribution's ICU package" ;;
    esac
    return 0
}

# run_as_user <cmd...>: runs the command as the service account: directly when the installer already
# runs as that account (tests), through runuser otherwise.
run_as_user() {
    if [[ $(id -un) == "$USER_NAME" ]]; then
        "$@"
    else
        runuser -u "$USER_NAME" -- "$@"
    fi
}

# mark_changed <unit>: records that the unit needs a restart (once; the services step restarts it
# when it is running).
mark_changed() {
    case " ${CHANGED_UNITS[*]:-} " in
        *" $1 "*) return 0 ;;
    esac
    CHANGED_UNITS+=("$1")
    return 0
}

# place_file <src> <dst> <unit>: copies src over dst (mode 0644) unless dst already has the same
# content; a copy that changed dst marks the unit as changed, because the service only reads its
# config at start. Returns 1 when the copy fails.
place_file() {
    if cmp -s "$1" "$2"; then
        return 0
    fi
    if ! install -m 644 "$1" "$2"; then
        return 1
    fi
    mark_changed "$3"
}

# ---------------------------------------------------------------------------
# 1. Preconditions
# ---------------------------------------------------------------------------
# Root, systemd (unless --no-services), x86_64, curl, tar and gzip (tar -z), and the package itself
# are required (die). A port that something already listens on is only a Check row: a re-run finds
# the stack's own services there. With --no-services nothing is started, so no port is probed.
step_preconditions() {
    local arch family tool port
    local -a ports=()
    log_step 'Preconditions'
    if [[ $EUID -ne 0 ]]; then
        die 'run this script as root (for example with sudo)'
    fi
    if [[ $NO_SERVICES -eq 0 ]] && ! command -v systemctl > /dev/null 2>&1; then
        die 'systemctl not found: this installer needs systemd (use --no-services to write the files only)'
    fi
    arch=$(uname -m)
    if [[ $arch != x86_64 ]]; then
        die "unsupported architecture $arch: the installer and the tarballs it uses are x86_64 only"
    fi
    for tool in curl tar gzip; do
        if ! command -v "$tool" > /dev/null 2>&1; then
            die "$tool not found: install it with your package manager and re-run"
        fi
    done
    if [[ ! -f $ROOT/StorSafe.config.example.json ]]; then
        die "$ROOT does not contain the package (StorSafe.config.example.json is missing): extract or clone it there, or pass --root"
    fi
    family=$(detect_family)
    summary_add Preconditions OK "$family, $arch"
    if [[ $NO_SERVICES -eq 0 ]]; then
        # The collector's port is the one node_exporter is told to listen on.
        ports=("${LISTEN##*:}")
        if [[ $COLLECTOR_ONLY -eq 0 ]]; then
            ports+=(9090 3000)
        fi
        for port in "${ports[@]}"; do
            if port_in_use "$port"; then
                summary_add Preconditions Check "port $port already in use"
            fi
        done
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 2. PowerShell
# ---------------------------------------------------------------------------
# Uses the pwsh on the PATH, else extracts the PowerShell tarball from installers/. The step stops
# the installer when there is no tarball or when pwsh does not start (almost always a missing ICU
# library).
step_powershell() {
    local tarball version
    log_step 'PowerShell'
    PWSH_BIN=$(command -v pwsh || true)
    if [[ -z $PWSH_BIN ]]; then
        tarball=$(find_installer 'powershell-*-linux-x64.tar.gz')
        if [[ -z $tarball ]]; then
            summary_add PowerShell 'Missing installer' 'put powershell-<ver>-linux-x64.tar.gz in installers/ and re-run'
            stop_here
        fi
        echo "Extracting $tarball to $PWSH_HOME"
        if ! mkdir -p "$PWSH_HOME" ||
            ! tar -xzf "$tarball" -C "$PWSH_HOME" ||
            ! chmod 755 "$PWSH_HOME/pwsh" ||
            ! ln -sf "$PWSH_HOME/pwsh" "$PWSH_LINK"; then
            summary_add PowerShell Check "cannot install $tarball; see the output above"
            stop_here
        fi
        PWSH_BIN=$PWSH_LINK
    fi
    if ! version=$("$PWSH_BIN" -NoProfile -v 2>&1); then
        if [[ -n $version ]]; then
            printf '%s\n' "$version" >&2
        fi
        summary_add PowerShell Check "pwsh does not start; install ICU: $(icu_package_line)"
        stop_here
    fi
    version=${version%%$'\n'*}
    summary_add PowerShell OK "$PWSH_BIN ${version#PowerShell }"
    return 0
}

# ---------------------------------------------------------------------------
# 3. Service user
# ---------------------------------------------------------------------------
# The account that runs the collector and the services. The folders it writes to belong to it;
# the rest of the install folder stays root-owned.
step_user() {
    local shell=/usr/sbin/nologin note=$USER_NAME folder
    local -a dirs=()
    for folder in creds state events metrics reports; do
        dirs+=("$ROOT/$folder")
    done
    log_step "Service user $USER_NAME"
    if ! id -u "$USER_NAME" > /dev/null 2>&1; then
        if [[ ! -x $shell ]]; then
            shell=/sbin/nologin
        fi
        if ! useradd --system --home-dir "$ROOT" --no-create-home --shell "$shell" "$USER_NAME"; then
            summary_add User Check "cannot create $USER_NAME; see the output above"
            stop_here
        fi
        note="$USER_NAME (created)"
    fi
    if ! mkdir -p "${dirs[@]}" ||
        ! chown -R "$USER_NAME:" "${dirs[@]}" ||
        ! chmod 700 "$ROOT/creds"; then
        summary_add User Check "cannot prepare the folders under $ROOT; see the output above"
        stop_here
    fi
    summary_add User OK "$note"
    return 0
}

# ---------------------------------------------------------------------------
# 4. Config
# ---------------------------------------------------------------------------
# A missing StorSafe.config.json is created from the example and the installer stops, so the
# operator can edit the Servers list, exactly like the Windows installer.
step_config() {
    local config=$ROOT/StorSafe.config.json
    log_step 'Config'
    if [[ ! -f $config ]]; then
        if ! cp "$ROOT/StorSafe.config.example.json" "$config"; then
            summary_add Config Check "cannot create $config; see the output above"
            stop_here
        fi
        echo "Created $config from StorSafe.config.example.json."
        summary_add Config Check 'edit the Servers list, then re-run'
        stop_here
    fi
    summary_add Config OK "$config"
    return 0
}

# ---------------------------------------------------------------------------
# 5. Credential files
# ---------------------------------------------------------------------------
# Every appliance in the config needs its credential file (CredentialFile, relative paths resolve
# against the install folder). A missing one is prompted for and saved as the service account, which
# is the only account that can use it. The Servers list is read with the same module the collector
# uses, so the paths are the ones it will look for.
step_credentials() {
    local listing name file list_ps create_ps made=0 present=0 failed=0
    local -A seen=()
    # The PowerShell code is single-quoted on purpose: its $ are PowerShell's, and the paths come in
    # through the environment so that no quoting of them is needed.
    # shellcheck disable=SC2016
    list_ps='
        $ErrorActionPreference = "Stop"
        Import-Module (Join-Path $env:STORSAFE_ROOT "StorSafe.psm1") -DisableNameChecking
        $config = Import-StorSafeConfig -Path (Join-Path $env:STORSAFE_ROOT "StorSafe.config.json")
        foreach ($s in $config.Servers) { "{0}`t{1}" -f $s.Name, $s.CredentialFile }
    '
    # shellcheck disable=SC2016
    create_ps='
        $ErrorActionPreference = "Stop"
        Import-Module (Join-Path $env:STORSAFE_ROOT "StorSafe.psm1") -DisableNameChecking
        New-StorSafeCredentialFile -Path $env:STORSAFE_FILE
    '
    log_step 'Credential files'
    if [[ $SKIP_CREDENTIALS -eq 1 ]]; then
        summary_add Credentials Skipped '--skip-credentials'
        return 0
    fi
    if ! listing=$(STORSAFE_ROOT=$ROOT "$PWSH_BIN" -NoProfile -NonInteractive -Command "$list_ps"); then
        summary_add Credentials Check 'could not read the Servers list; see the output above'
        return 1
    fi
    # The list comes in on fd 3 so that the prompt below keeps the terminal as its stdin.
    while IFS=$'\t' read -r -u 3 name file; do
        if [[ -z $file ]]; then
            echo "warning: $name has no CredentialFile in the config; the collector will fail for it" >&2
            continue
        fi
        # Appliances may share one credential file: ask for it once.
        if [[ -n ${seen[$file]:-} ]]; then
            continue
        fi
        seen[$file]=1
        if [[ -f $file ]]; then
            echo "$name: $file exists"
            present=$((present + 1))
            continue
        fi
        echo "Creating $file for $name"
        # Interactive on purpose: no -NonInteractive, Get-Credential asks on the terminal.
        if (cd "$ROOT" && run_as_user env STORSAFE_ROOT="$ROOT" STORSAFE_FILE="$file" "$PWSH_BIN" -NoProfile -Command "$create_ps") &&
            [[ -f $file ]] && chmod 600 "$file" && chown "$USER_NAME:" "$file"; then
            made=$((made + 1))
        else
            failed=$((failed + 1))
        fi
    done 3<<< "$listing"
    if [[ $failed -gt 0 ]]; then
        summary_add Credentials Check "$failed credential file(s) not created; see the output above"
        return 1
    fi
    if [[ $made -gt 0 ]]; then
        summary_add Credentials OK "created $made"
    else
        summary_add Credentials OK "$present file(s) present"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 6. Collector test run
# ---------------------------------------------------------------------------
# One real run, as the service account and from the install folder like the service, with the output
# on the screen. Exit 2 (a check failed) is a Check row; exit 3 (config or credential error) or no
# metrics file means nothing after this step can be verified, so the installer stops.
step_collector_test() {
    local log rc=0 wrote prom=$ROOT/metrics/storsafe.prom
    log_step 'Collector test run'
    if ! log=$(mktemp); then
        summary_add 'Collector test' Check 'cannot create a temporary file; see the output above'
        return 1
    fi
    # Under pipefail the pipeline's status is the collector's, tee does not fail.
    (cd "$ROOT" && run_as_user "$PWSH_BIN" -NoProfile -NonInteractive -File "$ROOT/Export-StorSafeMetrics.ps1" -All -NonInteractive) 2>&1 | tee "$log" || rc=$?
    wrote=$(grep '^Wrote ' "$log" | tail -n 1 || true)
    rm -f "$log"
    if [[ $rc -eq 3 || ! -f $prom ]]; then
        summary_add 'Collector test' Check 'config error; see the output above'
        stop_here
    fi
    case $rc in
        0) summary_add 'Collector test' OK "${wrote:-$prom written}" ;;
        2) summary_add 'Collector test' Check 'a check failed; see the output above' ;;
        *) summary_add 'Collector test' Check "the collector exited with code $rc; see the output above" ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# 7. node_exporter, Prometheus and Grafana
# ---------------------------------------------------------------------------
# extract_component <name> <glob> <strip> [label]: unpacks the newest $INSTALLERS/<glob> into
# $ROOT/<name> unless the folder already holds it (the tarball's file name is kept in
# <name>/.version), so a newer tarball in installers/ is an upgrade. An upgrade replaces everything
# in the folder except data/, and the folder belongs to the service account afterwards (the
# service writes below it). Adds the summary row (named <label>, default <name>) and returns 1 when
# there is no tarball or it cannot be unpacked.
extract_component() {
    local name=$1 glob=$2 strip=$3 label=${4:-$1} dir=$ROOT/$1 tarball base have=""
    tarball=$(find_installer "$glob")
    if [[ -z $tarball ]]; then
        summary_add "$label" 'Missing installer' "put ${glob/\*/<ver>} in installers/ and re-run"
        return 1
    fi
    base=$(basename "$tarball")
    if [[ -f $dir/.version ]]; then
        read -r have < "$dir/.version" || true
    fi
    if [[ $have == "$base" ]]; then
        summary_add "$label" OK "already extracted $base"
        return 0
    fi
    echo "Extracting $base to $dir"
    if ! mkdir -p "$dir" ||
        ! find "$dir" -mindepth 1 -maxdepth 1 ! -name data -exec rm -rf {} + ||
        ! tar -xzf "$tarball" -C "$dir" --strip-components="$strip" ||
        ! printf '%s\n' "$base" > "$dir/.version" ||
        ! chown -R "$USER_NAME:" "$dir"; then
        summary_add "$label" Check "cannot extract $base; see the output above"
        return 1
    fi
    # The program on disk is new, the running one is not.
    mark_changed "storsafe-${name//_/-}.service"
    summary_add "$label" OK "extracted $base"
    return 0
}

step_node_exporter() {
    log_step 'node_exporter'
    extract_component node_exporter 'node_exporter-*.linux-amd64.tar.gz' 1
}

# monitoring/prometheus.yml is shared with the Windows install and is the source of truth: it
# replaces the config the tarball ships, on every run.
step_prometheus() {
    local dir=$ROOT/prometheus
    log_step 'Prometheus'
    if [[ $COLLECTOR_ONLY -eq 1 ]]; then
        summary_add Prometheus Skipped '--collector-only'
        return 0
    fi
    extract_component prometheus 'prometheus-*.linux-amd64.tar.gz' 1 Prometheus || return 1
    if ! place_file "$ROOT/monitoring/prometheus.yml" "$dir/prometheus.yml" storsafe-prometheus.service ||
        ! mkdir -p "$dir/data" ||
        ! chown "$USER_NAME:" "$dir/data"; then
        summary_add Prometheus Check "cannot write the config and data folder in $dir; see the output above"
        return 1
    fi
    return 0
}

# Grafana gets the data source and the dashboard provider from monitoring/grafana/, the same files
# the Windows install uses; the provider's __DASHBOARD_DIR__ becomes the dashboards in this package.
step_grafana() {
    local dir=$ROOT/grafana prov=$ROOT/grafana/conf/provisioning rendered dashboards
    log_step 'Grafana'
    if [[ $COLLECTOR_ONLY -eq 1 ]]; then
        summary_add Grafana Skipped '--collector-only'
        return 0
    fi
    extract_component grafana 'grafana-*.linux-amd64.tar.gz' 1 Grafana || return 1
    # Escape what sed treats specially in the replacement (backslash, ampersand, delimiter).
    dashboards=$(printf '%s' "$ROOT/monitoring/dashboards" | sed -e 's/[\\&|]/\\&/g')
    if ! rendered=$(mktemp); then
        summary_add Grafana Check 'cannot create a temporary file; see the output above'
        return 1
    fi
    if ! mkdir -p "$prov/datasources" "$prov/dashboards" "$dir/data/log" ||
        ! chown "$USER_NAME:" "$dir/data" "$dir/data/log" ||
        ! sed "s|__DASHBOARD_DIR__|$dashboards|g" "$ROOT/monitoring/grafana/storsafe-dashboards.yaml" > "$rendered" ||
        ! place_file "$ROOT/monitoring/grafana/storsafe-datasource.yaml" "$prov/datasources/storsafe-datasource.yaml" storsafe-grafana.service ||
        ! place_file "$rendered" "$prov/dashboards/storsafe-dashboards.yaml" storsafe-grafana.service; then
        rm -f "$rendered"
        summary_add Grafana Check "cannot write the provisioning files and data folder in $dir; see the output above"
        return 1
    fi
    rm -f "$rendered"
    return 0
}

# ---------------------------------------------------------------------------
# 8. Systemd units
# ---------------------------------------------------------------------------
# Renders the unit files from linux/systemd/ into $UNIT_DIR. Each is rendered to a temporary file
# first, so that a unit is only replaced, and only recorded in CHANGED_UNITS, when its content
# differs from the file that was there. A placeholder left in a rendered unit is a bug in the
# package, not in the installation, and stops the installer. Nothing is enabled or started here.
render_units() {
    local name rendered changed=0
    local -a names=(storsafe-collector.service storsafe-collector.timer storsafe-node-exporter.service)
    if [[ $COLLECTOR_ONLY -eq 0 ]]; then
        names+=(storsafe-prometheus.service storsafe-grafana.service)
    fi
    log_step 'Systemd units'
    if ! mkdir -p "$UNIT_DIR"; then
        summary_add Units Check "cannot create $UNIT_DIR; see the output above"
        return 1
    fi
    for name in "${names[@]}"; do
        if ! rendered=$(mktemp "$UNIT_DIR/.$name.XXXXXX"); then
            summary_add Units Check "cannot write to $UNIT_DIR; see the output above"
            return 1
        fi
        if ! render_template "$ROOT/linux/systemd/$name" "$rendered" \
            ROOT="$ROOT" USER="$USER_NAME" PWSH="$PWSH_BIN" LISTEN="$LISTEN" RETENTION="$RETENTION" \
            INTERVAL="$INTERVAL" RUNTIME="$(runtime_max_sec "$INTERVAL")"; then
            rm -f "$rendered"
            die "cannot render the unit $name from $ROOT/linux/systemd: see the message above"
        fi
        if cmp -s "$rendered" "$UNIT_DIR/$name"; then
            rm -f "$rendered"
            continue
        fi
        if ! chmod 644 "$rendered" || ! mv -f "$rendered" "$UNIT_DIR/$name"; then
            rm -f "$rendered"
            summary_add Units Check "cannot write $UNIT_DIR/$name; see the output above"
            return 1
        fi
        mark_changed "$name"
        changed=$((changed + 1))
    done
    summary_add Units OK "${#names[@]} unit file(s) in $UNIT_DIR, $changed new or changed"
    return 0
}

# What the operator does next, after the summary. The scrape job repeats the one in
# monitoring/prometheus.yml (same keep regex), with this host as the target.
print_next_steps() {
    local host port=${LISTEN##*:}
    host=$(hostname -f 2> /dev/null || hostname 2> /dev/null || uname -n)
    log_step 'Next steps'
    if [[ $COLLECTOR_ONLY -eq 0 ]]; then
        cat << EOF
Open Grafana at http://$host:3000 (first login admin / admin, you are asked to change the
password), then Dashboards > StorSafe.

Check the stack, and pause or resume collecting (for example during appliance maintenance):
  sudo $ROOT/linux/storsafe-control.sh status
  sudo $ROOT/linux/storsafe-control.sh pause
  sudo $ROOT/linux/storsafe-control.sh resume
EOF
    else
        cat << EOF
node_exporter serves the metrics on $LISTEN. Add this job to scrape_configs in the prometheus.yml
of your Prometheus server and reload it (allow port $port from that server in the firewall):

  - job_name: storsafe
    static_configs:
      - targets: ['$host:$port']
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'storsafe_.*|windows_textfile_.*|node_textfile_.*'
        action: keep

Import the dashboards in $ROOT/monitoring/dashboards/*.json into your Grafana
(Dashboards > New > Import) and point them at the Prometheus data source with uid
storsafe-prometheus.
EOF
    fi
    return 0
}

main() {
    parse_args "$@"
    echo "Install folder: $ROOT"
    if [[ $UNINSTALL -eq 1 ]]; then
        die '--uninstall is not available yet'
    fi
    step_preconditions
    step_powershell
    step_user
    step_config
    run_step Credentials step_credentials
    run_step 'Collector test' step_collector_test
    run_step node_exporter step_node_exporter
    run_step Prometheus step_prometheus
    run_step Grafana step_grafana
    run_step Units render_units
    log_step 'Install summary'
    summary_print
    print_next_steps
}

main "$@"
