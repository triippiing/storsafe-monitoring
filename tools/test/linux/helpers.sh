#!/usr/bin/env bash
# Assertion helpers for the Linux installer tests. Source this file from a test_*.sh script.
# A failed assertion prints "FAIL <label>" (with a detail line) and sets FAILED=1; the test file
# ends with: exit "$FAILED". The helpers never exit on their own, so one run reports every failure.

# Read by the sourcing test file, which ends with exit "$FAILED".
# shellcheck disable=SC2034
FAILED=0

# Records a failed assertion: the label line, then an indented detail line when one is given.
assert_fail() {
    echo "FAIL $1"
    if [[ -n ${2:-} ]]; then
        echo "    $2"
    fi
    FAILED=1
}

# assert_eq expected actual [label]: the two strings must be identical.
assert_eq() {
    local expected=$1 actual=$2 label=${3:-assert_eq}
    if [[ $actual != "$expected" ]]; then
        assert_fail "$label" "expected '$expected', got '$actual'"
    fi
}

# assert_file path: the path must be an existing regular file.
assert_file() {
    if [[ ! -f $1 ]]; then
        assert_fail "file exists: $1"
    fi
}

# assert_grep file pattern: a line of the file must match the pattern (grep basic regex).
# A "--" before the pattern is accepted, for patterns that start with a dash. A grep error
# (for example an invalid regex) fails the assertion.
assert_grep() {
    local file=$1 rc=0
    shift
    if [[ ${1:-} == -- ]]; then
        shift
    fi
    if [[ ! -r $file ]]; then
        assert_fail "$file matches $1" "cannot read $file"
        return 0
    fi
    grep -q -- "$1" "$file" || rc=$?
    if [[ $rc -gt 1 ]]; then
        assert_fail "$file matches $1" "grep error (exit $rc)"
    elif [[ $rc -eq 1 ]]; then
        assert_fail "$file matches $1"
    fi
}

# assert_not_grep file pattern: no line of the file may match the pattern. The file must exist,
# and a grep error (for example an invalid regex) fails the assertion.
assert_not_grep() {
    local file=$1 rc=0
    shift
    if [[ ${1:-} == -- ]]; then
        shift
    fi
    if [[ ! -r $file ]]; then
        assert_fail "$file does not match $1" "cannot read $file"
        return 0
    fi
    grep -q -- "$1" "$file" || rc=$?
    if [[ $rc -gt 1 ]]; then
        assert_fail "$file does not match $1" "grep error (exit $rc)"
    elif [[ $rc -eq 0 ]]; then
        assert_fail "$file does not match $1" "a line matches"
    fi
}

# assert_exit code cmd...: runs the command in a subshell (so a command that calls exit, like die,
# does not end the test) and compares its exit code with the expected one.
assert_exit() {
    local want=$1 rc=0
    shift
    ( "$@" ) || rc=$?
    if [[ $rc -ne $want ]]; then
        assert_fail "exit $want from: $*" "got exit $rc"
    fi
}

# make_fake_tarballs <dir>: writes stand-ins for the four release tarballs the installer extracts
# into <dir>: node_exporter, Prometheus, Grafana (each in its top folder, with executable stubs
# that do nothing) and PowerShell (a pwsh stub at the archive root). The names follow the real
# releases.
make_fake_tarballs() {
    local dir=$1 work top
    mkdir -p "$dir"
    work=$(mktemp -d)
    top=node_exporter-1.9.1.linux-amd64
    mkdir -p "$work/$top"
    fake_stub "$work/$top/node_exporter"
    tar -czf "$dir/$top.tar.gz" -C "$work" "$top"
    top=prometheus-3.15.0.linux-amd64
    mkdir -p "$work/$top"
    fake_stub "$work/$top/prometheus"
    fake_stub "$work/$top/promtool"
    printf 'global:\n  scrape_interval: 15s\n' > "$work/$top/prometheus.yml"
    tar -czf "$dir/$top.tar.gz" -C "$work" "$top"
    top=grafana-v12.0.2
    mkdir -p "$work/$top/bin" "$work/$top/conf/provisioning/datasources" "$work/$top/conf/provisioning/dashboards"
    fake_stub "$work/$top/bin/grafana"
    tar -czf "$dir/grafana-12.0.2.linux-amd64.tar.gz" -C "$work" "$top"
    mkdir -p "$work/ps"
    fake_stub "$work/ps/pwsh"
    tar -czf "$dir/powershell-7.4.6-linux-x64.tar.gz" -C "$work/ps" pwsh
    rm -rf "$work"
    return 0
}

# fake_stub <file>: writes an executable shell script that does nothing and exits 0.
fake_stub() {
    printf '#!/bin/sh\nexit 0\n' > "$1"
    chmod 755 "$1"
    return 0
}

# make_systemctl_shim <dir>: writes an executable <dir>/systemctl, a stand-in for the real one. It
# appends its arguments as one space-joined line to $SYSTEMCTL_LOG and exits 0, except for these
# (the unit is the last argument, and the lists are space-separated unit names):
#   is-active [--quiet] <unit>  exits 0 when the unit is in $SYSTEMCTL_ACTIVE, else 3 like the real
#                               systemctl; without --quiet it prints active or inactive
#   is-failed [--quiet] <unit>  exits 0 only when the unit is in $SYSTEMCTL_FAILED (default empty),
#                               else 1
#   cat <unit>                  exits 0 when the unit is in $SYSTEMCTL_PRESENT, else 1
#   is-enabled <unit>           exits 0 and prints enabled when the unit is in $SYSTEMCTL_PRESENT,
#                               else exits 1
#   list-timers ... <timer>     prints one fixed line for storsafe-collector.timer: next run
#                               "Tue 2026-10-06 22:10:00 UTC" when the timer is in
#                               $SYSTEMCTL_ACTIVE, else n/a in the first four fields
#   show <unit> -p <key>        ignores its arguments and prints fixed ExecMainExitTimestamp and
#                               ExecMainStatus lines whatever the key is; the timestamp is
#                               $SYSTEMCTL_EXIT_TIMESTAMP (default "Tue 2026-10-06 22:05:00 UTC";
#                               set it empty for a service that never ran) and the status is
#                               $SYSTEMCTL_EXEC_STATUS (default 0)
# Put <dir> first on the PATH of the run under test.
make_systemctl_shim() {
    mkdir -p "$1"
    cat > "$1/systemctl" << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG:-/dev/null}"
for unit in "$@"; do :; done
quiet=
[ "${2:-}" = --quiet ] && quiet=1
case $1 in
    is-active)
        case " ${SYSTEMCTL_ACTIVE:-} " in
            *" $unit "*) [ -n "$quiet" ] || echo active; exit 0 ;;
        esac
        [ -n "$quiet" ] || echo inactive
        exit 3
        ;;
    is-failed)
        case " ${SYSTEMCTL_FAILED:-} " in
            *" $unit "*) exit 0 ;;
        esac
        exit 1
        ;;
    cat | is-enabled)
        case " ${SYSTEMCTL_PRESENT:-} " in
            *" $unit "*) [ "$1" = cat ] || echo enabled; exit 0 ;;
        esac
        exit 1
        ;;
    list-timers)
        case " ${SYSTEMCTL_ACTIVE:-} " in
            *" storsafe-collector.timer "*)
                echo 'Tue 2026-10-06 22:10:00 UTC 4min 32s left' \
                    'Tue 2026-10-06 22:05:00 UTC 27s ago' \
                    'storsafe-collector.timer storsafe-collector.service'
                ;;
            *)
                echo 'n/a n/a n/a n/a storsafe-collector.timer storsafe-collector.service'
                ;;
        esac
        exit 0
        ;;
    show)
        echo "ExecMainExitTimestamp=${SYSTEMCTL_EXIT_TIMESTAMP-Tue 2026-10-06 22:05:00 UTC}"
        echo "ExecMainStatus=${SYSTEMCTL_EXEC_STATUS:-0}"
        exit 0
        ;;
esac
exit 0
EOF
    chmod 755 "$1/systemctl"
    return 0
}
