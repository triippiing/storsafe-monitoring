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
#
# Unlike the Windows installer this does not need to run as the account that runs the collector:
# the collector runs as a dedicated system account (default storsafe), created if it is missing.
#
# Each step is idempotent and can be re-run after adding installers or editing the config. The
# summary at the end lists every step as OK, Skipped, Missing installer or Check. A step that
# nothing after it can work without stops the installer: the preconditions with an error message,
# PowerShell, the user and the config after printing the summary of what was done so far.
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
    log_step 'Install summary'
    summary_print
}

main "$@"
