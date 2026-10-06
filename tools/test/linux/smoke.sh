#!/usr/bin/env bash
# Smoke test of the Linux install against the mock StorSafe API, for CI and for a fresh VM. Run it
# as root from anywhere (the repository is found from this script) and it ends with "smoke OK",
# or prints which step failed and exits non-zero.
#
#   smoke.sh              collector-only install into a temporary folder, no systemd: the files
#                         are written and the collector runs once as root
#   smoke.sh --services   the full stack as systemd services in /opt/storsafe-monitoring: checks
#                         the three ports and the dashboard queries, runs storsafe-control.sh
#                         and uninstalls again. Changes the host: use a throwaway VM or runner.
#                         A failed run leaves the services in place to look at; remove them with
#                         linux/install.sh --root /opt/storsafe-monitoring --uninstall.
#
# The working tree is copied into the install folder (without .git, .claude, .superpowers, dist,
# the test output and the runtime folders of a working clone), the mock config and credential are
# put in place, and the installers are downloaded by linux/get-installers.sh. SMOKE_INSTALLERS=<folder>
# copies the *.tar.gz files of that folder instead, for a host with no internet access. Needs
# curl, tar, python3, and port 18080 for the mock API; the PowerShell tarball is extracted by the
# installer when pwsh is not on the PATH, which needs the ICU library.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$here/../../.." && pwd)
# shellcheck source=../../../linux/lib.sh
source "$REPO/linux/lib.sh"

MOCK_PORT=18080
SERVICES=0
ROOT=""
TMP=""
MOCK_PID=""
STEP="start"

usage() {
    cat << 'EOF'
usage: smoke.sh [--services]

  --services   install the full stack as systemd services in /opt/storsafe-monitoring and
               exercise it (changes the host; for CI runners and throwaway VMs)
  -h, --help   show this text

SMOKE_INSTALLERS=<folder> copies the *.tar.gz files of that folder instead of downloading.
EOF
}

# step <title>: names the step that is running, for the failure message, and prints its heading.
step() {
    STEP=$1
    log_step "$1"
}

# Runs on every exit: stops the mock API this script started (only that process), removes the
# temporary folder and, when the run failed, says which step it was and shows the mock's output.
cleanup() {
    local rc=$?
    trap - EXIT
    if [[ $rc -ne 0 ]]; then
        printf '\nsmoke FAILED in step: %s\n' "$STEP" >&2
        if [[ -n $TMP && -s $TMP/mock.log ]]; then
            echo '--- last lines of the mock API output' >&2
            tail -n 20 "$TMP/mock.log" >&2
        fi
    fi
    if [[ -n $MOCK_PID ]]; then
        kill "$MOCK_PID" 2> /dev/null || true
        wait "$MOCK_PID" 2> /dev/null || true
    fi
    if [[ -n $TMP ]]; then
        rm -rf "$TMP"
    fi
    exit "$rc"
}

# parse_args "$@": sets SERVICES. -h/--help prints the usage and exits 0.
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h | --help) usage; exit 0 ;;
            --services) SERVICES=1; shift ;;
            *) printf 'error: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
        esac
    done
    return 0
}

# Stops unless the host can run the test: root, the tools, a free mock port, and with --services
# a running systemd.
check_host() {
    local tool
    if [[ $EUID -ne 0 ]]; then
        die 'run this script as root (for example with sudo)'
    fi
    for tool in curl tar python3; do
        if ! command -v "$tool" > /dev/null 2>&1; then
            die "$tool not found: install it with your package manager and re-run"
        fi
    done
    if [[ $SERVICES -eq 1 && ! -d /run/systemd/system ]]; then
        die 'systemd is not running on this host: --services needs it (run without --services here)'
    fi
    if port_in_use "$MOCK_PORT"; then
        die "port $MOCK_PORT is already in use: stop whatever listens there (a running mock_api.py?) and re-run"
    fi
    return 0
}

# Sets ROOT and copies the working tree into it. A --services run uses the default install folder
# and refuses to touch one that holds a config this script did not write.
prepare_root() {
    local -a exclude=()
    local item
    TMP=$(mktemp -d)
    if [[ $SERVICES -eq 1 ]]; then
        ROOT=/opt/storsafe-monitoring
        if [[ -e $ROOT/StorSafe.config.json && ! -e $ROOT/.smoke-test ]]; then
            die "$ROOT already holds a StorSafe.config.json that this script did not write: refusing to overwrite a real install"
        fi
    else
        ROOT=$TMP/root
    fi
    mkdir -p "$ROOT"
    chmod 755 "$ROOT"
    touch "$ROOT/.smoke-test"
    # Version control, tool and planning folders, build and test output, and the runtime folders of
    # a working clone (a stale metrics/storsafe.prom would make the check below pass without a
    # collector run).
    for item in .git .claude .superpowers dist tools/test/out creds state events metrics reports installers; do
        exclude+=("--exclude=./$item")
    done
    tar -C "$REPO" --anchored "${exclude[@]}" -cf - . | tar -C "$ROOT" --no-same-owner -xf -
    echo "Copied $REPO to $ROOT"
    return 0
}

# The mock config without the two Defaults keys that point at out/state and out/events: the
# installer creates and chowns its own state/ and events/ folders, which the collector uses
# instead. The mock credential must stay readable by the service account.
place_mock_config() {
    python3 -c '
import json, sys
config = json.load(open(sys.argv[1]))
for key in ("StateDirectory", "EventLogDirectory"):
    config["Defaults"].pop(key, None)
with open(sys.argv[2], "w") as out:
    json.dump(config, out, indent=2)
' "$REPO/tools/test/mock.config.json" "$ROOT/StorSafe.config.json"
    cp "$REPO/tools/test/mock-credential.xml" "$ROOT/mock-credential.xml"
    chmod 644 "$ROOT/StorSafe.config.json" "$ROOT/mock-credential.xml"
    return 0
}

# Puts the four tarballs in $ROOT/installers: downloaded, or copied from SMOKE_INSTALLERS.
get_installers() {
    mkdir -p "$ROOT/installers"
    if [[ -n ${SMOKE_INSTALLERS:-} ]]; then
        if ! compgen -G "$SMOKE_INSTALLERS/*.tar.gz" > /dev/null; then
            die "no *.tar.gz file in SMOKE_INSTALLERS=$SMOKE_INSTALLERS"
        fi
        cp "$SMOKE_INSTALLERS"/*.tar.gz "$ROOT/installers/"
    else
        "$ROOT/linux/get-installers.sh" --dest "$ROOT/installers"
    fi
    return 0
}

# Starts tools/test/mock_api.py in the background and waits until it answers. Any HTTP answer will
# do (the mock wants a login first, so a plain GET is a 401).
start_mock() {
    local tries
    python3 "$REPO/tools/test/mock_api.py" "$MOCK_PORT" > "$TMP/mock.log" 2>&1 &
    MOCK_PID=$!
    for ((tries = 0; tries < 15; tries++)); do
        if ! kill -0 "$MOCK_PID" 2> /dev/null; then
            die 'the mock API exited at once'
        fi
        if curl -s -o /dev/null --noproxy '*' --max-time 2 "http://127.0.0.1:$MOCK_PORT/"; then
            echo "Mock API answering on 127.0.0.1:$MOCK_PORT (pid $MOCK_PID)"
            return 0
        fi
        sleep 1
    done
    die "the mock API does not answer on 127.0.0.1:$MOCK_PORT"
}

# Runs the installer: the collector only, with no systemd and the units written to $ROOT/units, or
# (--services) the full stack as the default service account.
run_install() {
    if [[ $SERVICES -eq 1 ]]; then
        "$ROOT/linux/install.sh" --root "$ROOT" --skip-credentials
    else
        "$ROOT/linux/install.sh" --root "$ROOT" --skip-credentials --collector-only --no-services \
            --unit-dir "$ROOT/units" --user root
    fi
    return 0
}

# assert_no_placeholders <file>...: fails when a file still holds an unrendered __NAME__ and when
# there is no file at all.
assert_no_placeholders() {
    local rc=0
    if [[ $# -eq 0 ]]; then
        die 'no rendered unit file found'
    fi
    grep -nE '__[A-Z]+__' "$@" || rc=$?
    if [[ $rc -eq 0 ]]; then
        die 'a rendered unit file still holds a placeholder (lines above)'
    elif [[ $rc -ne 1 ]]; then
        die "grep failed with exit $rc"
    fi
    echo "No placeholder left in $# unit file(s)"
    return 0
}

# check_files: the collector wrote its metrics and every rendered unit is complete.
check_files() {
    local -a units=()
    if [[ ! -s $ROOT/metrics/storsafe.prom ]]; then
        die "$ROOT/metrics/storsafe.prom is missing or empty"
    fi
    echo "Found $ROOT/metrics/storsafe.prom ($(wc -l < "$ROOT/metrics/storsafe.prom") lines)"
    if [[ $SERVICES -eq 1 ]]; then
        mapfile -t units < <(compgen -G '/etc/systemd/system/storsafe-*' || true)
    else
        mapfile -t units < <(compgen -G "$ROOT/units/*" || true)
    fi
    assert_no_placeholders "${units[@]}"
    return 0
}

# assert_http <url>: fails unless a GET answers 2xx.
assert_http() {
    if ! curl -fsS -o /dev/null --noproxy '*' --max-time 10 "$1"; then
        die "no answer from $1"
    fi
    echo "OK $1"
    return 0
}

# prometheus_has_collector_info: succeeds when Prometheus holds at least one storsafe_collector_info
# series, that is when the collector's metrics went through node_exporter and one scrape.
prometheus_has_collector_info() {
    curl -fsS -o - --noproxy '*' --max-time 10 --get --data-urlencode 'query=storsafe_collector_info' \
        http://127.0.0.1:9090/api/v1/query 2> /dev/null |
        python3 -c 'import json, sys; sys.exit(0 if json.load(sys.stdin)["data"]["result"] else 1)' 2> /dev/null
}

# Waits up to 150 s (the scrape interval is 60 s) for the collector's series in Prometheus.
wait_for_prometheus_data() {
    local start=$SECONDS
    while ! prometheus_has_collector_info; do
        if [[ $((SECONDS - start)) -ge 150 ]]; then
            die 'Prometheus holds no storsafe_collector_info after 150 s'
        fi
        sleep 5
    done
    echo "storsafe_collector_info is in Prometheus after $((SECONDS - start)) s"
    return 0
}

# The dashboard queries run against the real Prometheus; the validator's last line must say
# "errors 0".
validate_dashboards() {
    local out
    if ! out=$(python3 "$REPO/tools/test/validate_dashboards.py" --prom http://127.0.0.1:9090 --servers MOCK-A,MOCK-B); then
        printf '%s\n' "$out"
        die 'validate_dashboards.py failed'
    fi
    printf '%s\n' "$out"
    if ! grep -Eq '(^| )errors 0( |$)' <<< "$out"; then
        die 'validate_dashboards.py did not report "errors 0"'
    fi
    return 0
}

# Runs storsafe-control.sh with each action; every one must exit 0 (set -e stops the script).
exercise_control() {
    local action
    for action in status pause resume stop start; do
        echo "-- storsafe-control.sh $action"
        "$ROOT/linux/storsafe-control.sh" "$action"
    done
    return 0
}

# Removes the units and checks that none is left. The install folder stays, as designed.
uninstall() {
    "$ROOT/linux/install.sh" --root "$ROOT" --uninstall
    if compgen -G '/etc/systemd/system/storsafe-*' > /dev/null; then
        die 'a storsafe unit file is left in /etc/systemd/system after --uninstall'
    fi
    return 0
}

main() {
    parse_args "$@"
    trap cleanup EXIT
    step 'Host'
    check_host
    step 'Install folder'
    prepare_root
    step 'Mock config and credential'
    place_mock_config
    step 'Installers'
    get_installers
    step 'Mock API'
    start_mock
    step 'Install'
    run_install
    step 'Files'
    check_files
    if [[ $SERVICES -eq 1 ]]; then
        step 'Service endpoints'
        assert_http http://127.0.0.1:9182/metrics
        assert_http http://127.0.0.1:9090/-/ready
        assert_http http://127.0.0.1:3000/api/health
        step 'Metrics in Prometheus'
        wait_for_prometheus_data
        step 'Dashboard queries'
        validate_dashboards
        step 'storsafe-control.sh'
        exercise_control
        step 'Uninstall'
        uninstall
    fi
    echo
    echo 'smoke OK'
    return 0
}

main "$@"
