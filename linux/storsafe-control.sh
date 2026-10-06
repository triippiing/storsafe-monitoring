#!/usr/bin/env bash
# Shows, stops, starts, pauses or resumes the StorSafe monitoring components on this host. This is
# the Linux counterpart of StorSafeMonitoringControl.ps1. Nothing here touches the appliances.
#
# Components: the collector timer (storsafe-collector.timer) and the oneshot service it starts
# (storsafe-collector.service; journalctl -u storsafe-collector shows the output of its last run),
# and the node_exporter, Prometheus and Grafana services (storsafe-node-exporter,
# storsafe-prometheus and storsafe-grafana). A collector-only install has the first three units
# only; a unit that is not installed is reported as absent and skipped.
#
#   status   state of each component, the last collector result, and whether node_exporter,
#            Prometheus and Grafana answer on their ports
#   stop     before host maintenance: stop the collector timer, then node_exporter, Prometheus and
#            Grafana. The units stay enabled, so they start again at the next boot.
#   start    start Grafana, Prometheus and node_exporter, then the collector timer, which runs the
#            collector once
#   pause    appliance maintenance: stop the collector timer only, so a rebooting appliance produces
#            no failed checks or login events. node_exporter, Prometheus and Grafana keep running
#            and show the last values. A collector run already in progress finishes.
#   resume   start the collector timer and run the collector once
#
# After stop, start, pause and resume the script checks that every unit it touched is in the
# expected state (the collector service: that its run did not fail) and exits 1 if not. Run those
# four as root (for example with sudo); status needs no root.
#
# Exit status: 0 when the action ran and every unit is as expected, 1 when a unit is not, or the
# action needs root, 2 when the command line is wrong.
#
# Examples:
#   sudo /opt/storsafe-monitoring/linux/storsafe-control.sh status
#   sudo /opt/storsafe-monitoring/linux/storsafe-control.sh stop
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

TIMER=storsafe-collector.timer
COLLECTOR=storsafe-collector.service
NODE_EXPORTER=storsafe-node-exporter.service
PROMETHEUS=storsafe-prometheus.service
GRAFANA=storsafe-grafana.service

usage() {
    cat << 'USAGE'
usage: storsafe-control.sh <status|stop|start|pause|resume>

  status   state of each component, the last collector result, and whether node_exporter,
           Prometheus and Grafana answer on their ports
  stop     before host maintenance: stop the collector timer, then node_exporter, Prometheus and
           Grafana (they start again at the next boot)
  start    start Grafana, Prometheus, node_exporter and the collector timer, which runs the
           collector once
  pause    appliance maintenance: stop the collector timer only; Prometheus and Grafana keep
           running and show the last values
  resume   start the collector timer and run the collector once

stop, start, pause and resume need root (for example sudo).
USAGE
}

# unit_present <unit>: returns 0 when systemd knows the unit (its file is installed).
unit_present() {
    systemctl cat "$1" > /dev/null 2>&1
}

# unit_word <is-active|is-enabled> <unit> <word if the exit status is 0> <word if it is not>:
# prints the one-word answer systemctl gives (active, inactive, failed, enabled, disabled, static,
# ...), or the word for the exit status when systemctl printed nothing.
unit_word() {
    local word rc=0
    word=$(systemctl "$1" "$2" 2> /dev/null) || rc=$?
    if [[ -z $word ]]; then
        if [[ $rc -eq 0 ]]; then
            word=$3
        else
            word=$4
        fi
    fi
    echo "$word"
}

# unit_prop <unit> <key>: prints the value of a systemctl show property, or n/a when it is missing
# or empty.
unit_prop() {
    local out line value=""
    out=$(systemctl show "$1" -p "$2" 2> /dev/null) || true
    while IFS= read -r line; do
        if [[ $line == "$2="* ]]; then
            value=${line#"$2="}
        fi
    done <<< "$out"
    echo "${value:-n/a}"
}

# timer_next_run: prints when the collector timer runs next, as systemctl list-timers prints it
# ("Tue 2026-10-06 22:10:00 UTC"), or n/a when the timer is not scheduled. The property
# NextElapseUSecRealtime is no use here: systemd fills it for OnCalendar timers only, and this
# timer is monotonic (OnBootSec, OnUnitActiveSec).
timer_next_run() {
    local out next date clock zone
    out=$(systemctl list-timers --all --no-legend "$TIMER" 2> /dev/null) || true
    # The first line only: NEXT is its first four fields (day, date, time, time zone).
    read -r next date clock zone _ <<< "$out" || true
    if [[ -z $zone || $next == n/a || $next == - ]]; then
        echo n/a
    else
        echo "$next $date $clock $zone"
    fi
}

# collector_detail: prints "last run <time>, result <...>", or "not run yet" when the service has
# no exit time.
collector_detail() {
    local when
    when=$(unit_prop "$COLLECTOR" ExecMainExitTimestamp)
    if [[ $when == n/a ]]; then
        echo 'not run yet'
    else
        echo "last run $when, result $(exec_result "$(unit_prop "$COLLECTOR" ExecMainStatus)")"
    fi
}

# exec_result <ExecMainStatus>: the collector's exit code in words.
exec_result() {
    case $1 in
        0) echo OK ;;
        2) echo 'a check failed' ;;
        3) echo 'config error' ;;
        n/a) echo n/a ;;
        *) echo "exit $1" ;;
    esac
}

# probe <url> <port>: prints "answering on <port>" or "not answering on <port>" (3 s timeout).
probe() {
    if http_ok "$1" 3; then
        echo "answering on $2"
    else
        echo "not answering on $2"
    fi
}

# unit_detail <unit>: the Detail column of the status table.
unit_detail() {
    case $1 in
        "$TIMER") echo "next run $(timer_next_run)" ;;
        "$COLLECTOR") collector_detail ;;
        "$NODE_EXPORTER") probe http://127.0.0.1:9182/metrics 9182 ;;
        "$PROMETHEUS") probe http://127.0.0.1:9090/-/ready 9090 ;;
        "$GRAFANA") probe http://127.0.0.1:3000/api/health 3000 ;;
        *) echo "" ;;
    esac
}

# show_status: prints the table Unit, Active, Enabled, Detail, one row per unit, columns fitted to
# the content and separated by two spaces. A unit that is not installed gets the row
# "<unit>  absent".
show_status() {
    local -a units=("$TIMER" "$COLLECTOR" "$NODE_EXPORTER" "$PROMETHEUS" "$GRAFANA")
    local -a col1=() col2=() col3=() col4=()
    local w1=4 w2=6 w3=7 i unit line
    for unit in "${units[@]}"; do
        col1+=("$unit")
        if unit_present "$unit"; then
            col2+=("$(unit_word is-active "$unit" active inactive)")
            col3+=("$(unit_word is-enabled "$unit" enabled disabled)")
            col4+=("$(unit_detail "$unit")")
        else
            col2+=(absent)
            col3+=("")
            col4+=("")
        fi
    done
    for ((i = 0; i < ${#units[@]}; i++)); do
        if [[ ${#col1[i]} -gt $w1 ]]; then w1=${#col1[i]}; fi
        if [[ ${#col2[i]} -gt $w2 ]]; then w2=${#col2[i]}; fi
        if [[ ${#col3[i]} -gt $w3 ]]; then w3=${#col3[i]}; fi
    done
    line=$(printf '%-*s  %-*s  %-*s  %s' "$w1" Unit "$w2" Active "$w3" Enabled Detail)
    printf '%s\n' "$line"
    for ((i = 0; i < ${#units[@]}; i++)); do
        line=$(printf '%-*s  %-*s  %-*s  %s' \
            "$w1" "${col1[i]}" "$w2" "${col2[i]}" "$w3" "${col3[i]}" "${col4[i]}")
        # Cut the padding left behind by empty columns.
        printf '%s\n' "${line%"${line##*[! ]}"}"
    done
    return 0
}

# change_units <start|stop> <unit>...: runs systemctl with the verb on each installed unit, in
# order. A failure is reported here and judged by check_units, which looks at the state that
# resulted.
change_units() {
    local verb=$1 unit
    shift
    for unit in "$@"; do
        if unit_present "$unit"; then
            if ! systemctl "$verb" "$unit"; then
                echo "warning: systemctl $verb $unit failed" >&2
            fi
        fi
    done
    return 0
}

# collector_line: prints how the oneshot collector service stands: "ran, result <...>", "failed,
# result <...>" (and returns 1) or "running now". It is a oneshot, so is-active says inactive after
# a good run; "not failed" is what counts.
collector_line() {
    local result
    result=$(exec_result "$(unit_prop "$COLLECTOR" ExecMainStatus)")
    if systemctl is-failed --quiet "$COLLECTOR" 2> /dev/null; then
        echo "failed, result $result"
        return 1
    fi
    if [[ $(unit_prop "$COLLECTOR" ActiveState) == activating ]]; then
        echo 'running now'
        return 0
    fi
    echo "ran, result $result"
    return 0
}

# check_units <active|inactive> <unit>...: prints one line per unit, "<unit>  <state>", and returns
# 1 when an installed unit is not in the expected state. A missing unit is "absent" and never an
# error. The collector service is judged by collector_line, not by is-active.
check_units() {
    local expected=$1 unit state bad=0
    shift
    for unit in "$@"; do
        if ! unit_present "$unit"; then
            printf '%s  absent\n' "$unit"
        elif [[ $unit == "$COLLECTOR" ]]; then
            state=$(collector_line) || bad=$((bad + 1))
            printf '%s  %s\n' "$unit" "$state"
        else
            state=$(unit_word is-active "$unit" active inactive)
            printf '%s  %s\n' "$unit" "$state"
            if [[ $state != "$expected" ]]; then
                bad=$((bad + 1))
            fi
        fi
    done
    [[ $bad -eq 0 ]]
}

# finish <active|inactive> <message> <unit>...: checks the units, then prints the message, or stops
# with exit status 1 when a unit is not as expected.
finish() {
    local expected=$1 message=$2
    shift 2
    if ! check_units "$expected" "$@"; then
        die 'a unit is not in the expected state (see above)'
    fi
    echo "$message"
    return 0
}

action_stop() {
    local -a units=("$TIMER" "$NODE_EXPORTER" "$PROMETHEUS" "$GRAFANA")
    local msg='Stopped. The units stay enabled and start again at the next boot;'
    msg+=' run start when the maintenance is over.'
    change_units stop "${units[@]}"
    finish inactive "$msg" "${units[@]}"
}

action_start() {
    local -a units=("$GRAFANA" "$PROMETHEUS" "$NODE_EXPORTER" "$TIMER")
    local msg='Started. The collector runs once now and then on its timer; Prometheus replays'
    msg+=' its write-ahead log first (a minute or two after a long run).'
    change_units start "${units[@]}"
    # The timer wants the collector service, so starting the timer runs the collector once.
    finish active "$msg" "${units[@]}" "$COLLECTOR"
}

action_pause() {
    local msg='Paused. Dashboards keep the last collected values. The timer starts again at the'
    msg+=' next boot; use resume afterwards.'
    change_units stop "$TIMER"
    finish inactive "$msg" "$TIMER"
}

action_resume() {
    change_units start "$TIMER"
    if unit_present "$COLLECTOR"; then
        echo 'Running the collector once (a few seconds per appliance)...'
    fi
    # A oneshot: this returns when the run has ended.
    change_units start "$COLLECTOR"
    finish active 'Resumed. The collector runs on its timer again.' "$TIMER" "$COLLECTOR"
}

if [[ $# -eq 0 ]]; then
    usage >&2
    exit 2
fi
case $1 in
    -h | --help)
        usage
        exit 0
        ;;
    status | stop | start | pause | resume) ;;
    *)
        echo "error: unknown action '$1'" >&2
        usage >&2
        exit 2
        ;;
esac
if [[ $# -gt 1 ]]; then
    echo "error: unexpected argument '$2'" >&2
    usage >&2
    exit 2
fi
action=$1

if [[ $action != status && $EUID -ne 0 ]]; then
    die "'$action' needs root: run it with sudo"
fi
if ! command -v systemctl > /dev/null 2>&1; then
    die 'systemctl not found: this script needs systemd'
fi

case $action in
    status) show_status ;;
    stop) action_stop ;;
    start) action_start ;;
    pause) action_pause ;;
    resume) action_resume ;;
esac
