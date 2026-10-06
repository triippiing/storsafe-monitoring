#!/usr/bin/env bash
# Runs linux/storsafe-control.sh with a systemctl shim first on the PATH; nothing here reaches the
# real systemd. Needs root, like the installer tests: the script refuses stop, start, pause and
# resume otherwise. Needs no mock API: nothing listens on ports 9182, 9090 or 3000 here.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); source "$here/helpers.sh"; source "$here/../../../linux/lib.sh"
ctl=$here/../../../linux/storsafe-control.sh; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# quiet cmd...: runs the command with its output discarded, so a passing run prints nothing
# shellcheck disable=SC2329 # called through assert_exit
quiet() { "$@" > /dev/null 2>&1; }
make_systemctl_shim "$tmp/bin"; export SYSTEMCTL_LOG=$tmp/log PATH="$tmp/bin:$PATH"
export SYSTEMCTL_PRESENT="storsafe-collector.service storsafe-collector.timer storsafe-node-exporter.service" SYSTEMCTL_ACTIVE="storsafe-collector.timer storsafe-node-exporter.service"
assert_exit 2 quiet "$ctl" bogus
"$ctl" status > "$tmp/st"; assert_grep "$tmp/st" '^storsafe-prometheus.service *absent'; assert_grep "$tmp/st" 'not answering on 9182'
: > "$SYSTEMCTL_LOG"; export SYSTEMCTL_ACTIVE=""
assert_exit 0 quiet "$ctl" pause;  assert_grep "$SYSTEMCTL_LOG" '^stop storsafe-collector.timer$'; assert_not_grep "$SYSTEMCTL_LOG" 'prometheus'
: > "$SYSTEMCTL_LOG"; export SYSTEMCTL_ACTIVE="storsafe-collector.timer storsafe-collector.service storsafe-node-exporter.service"
assert_exit 0 quiet "$ctl" resume; assert_grep "$SYSTEMCTL_LOG" '^start storsafe-collector.service$'
: > "$SYSTEMCTL_LOG"; export SYSTEMCTL_ACTIVE=""
assert_exit 0 quiet "$ctl" stop; assert_eq "$(printf 'stop storsafe-collector.timer\nstop storsafe-node-exporter.service')" "$(grep '^stop' "$SYSTEMCTL_LOG")" "stop order, present units only"
export SYSTEMCTL_ACTIVE="storsafe-collector.timer"   # node_exporter did not stop
assert_exit 1 quiet "$ctl" stop
assert_exit 1 quiet "$ctl" pause                     # the timer is still listed active

# The status table: header, one row per unit with its Active and Enabled state, the details.
assert_grep "$tmp/st" '^Unit  *Active  *Enabled  *Detail$'
assert_grep "$tmp/st" '^storsafe-collector.timer  *active  *enabled  *next run Tue 2026-10-06 22:10:00 UTC$'
assert_grep "$tmp/st" '^storsafe-collector.service  *inactive  *enabled  *last run Tue 2026-10-06 22:05:00 UTC, result OK$'
assert_grep "$tmp/st" '^storsafe-node-exporter.service  *active  *enabled  *not answering on 9182$'
assert_grep "$tmp/st" '^storsafe-grafana.service *absent$'
assert_eq 6 "$(wc -l < "$tmp/st" | tr -d ' ')" "status: header and five rows"
# The collector's exit code in words, in status (only the service installed, so no port is probed).
for pair in '2:a check failed' '3:config error' '1:exit 1'; do
    SYSTEMCTL_PRESENT=storsafe-collector.service SYSTEMCTL_EXEC_STATUS=${pair%%:*} "$ctl" status > "$tmp/st2"
    assert_grep "$tmp/st2" ", result ${pair#*:}\$"
done
# A service that never ran has no exit time; a timer that is not active has no next run.
SYSTEMCTL_PRESENT=storsafe-collector.service SYSTEMCTL_EXIT_TIMESTAMP="" "$ctl" status > "$tmp/st2"
assert_grep "$tmp/st2" '^storsafe-collector.service  *inactive  *enabled  *not run yet$'
SYSTEMCTL_PRESENT=storsafe-collector.timer SYSTEMCTL_ACTIVE="" "$ctl" status > "$tmp/st2"
assert_grep "$tmp/st2" '^storsafe-collector.timer  *inactive  *enabled  *next run n/a$'

# All five units installed and active. status probes the two stack ports as well (nothing listens
# here); stop takes the timer, node_exporter, Prometheus and Grafana down in that order.
s=storsafe; stack="$s-prometheus.service $s-grafana.service"
export SYSTEMCTL_PRESENT="$SYSTEMCTL_PRESENT $stack"
export SYSTEMCTL_ACTIVE="storsafe-collector.timer storsafe-node-exporter.service $stack"
# order verb unit...: the log lines a run that took the verb on each unit leaves, one per unit
order() { local verb=$1 unit; shift; for unit in "$@"; do echo "$verb $unit"; done; }
"$ctl" status > "$tmp/st3"
assert_grep "$tmp/st3" '^storsafe-prometheus.service  *active  *enabled  *not answering on 9090$'
assert_grep "$tmp/st3" '^storsafe-grafana.service  *active  *enabled  *not answering on 3000$'
assert_eq 6 "$(wc -l < "$tmp/st3" | tr -d ' ')" "status, all five units: header and five rows"
: > "$SYSTEMCTL_LOG"; active=$SYSTEMCTL_ACTIVE; export SYSTEMCTL_ACTIVE=""
assert_exit 0 quiet "$ctl" stop
assert_eq "$(order stop "$s-collector.timer" "$s-node-exporter.service" \
    "$s-prometheus.service" "$s-grafana.service")" "$(grep '^stop' "$SYSTEMCTL_LOG")" "stop order, all five"
# pause with all five installed touches the timer only
: > "$SYSTEMCTL_LOG"; export SYSTEMCTL_ACTIVE="storsafe-node-exporter.service $stack"
assert_exit 0 quiet "$ctl" pause
assert_eq "stop $s-collector.timer" "$(grep '^stop' "$SYSTEMCTL_LOG")" "pause stops the timer only"
export SYSTEMCTL_ACTIVE=$active

# start: the reverse of stop, all five units; the timer's Wants= runs the collector, so start does
# not start the service itself; the collector line says the run did not fail.
: > "$SYSTEMCTL_LOG"
assert_exit 0 quiet "$ctl" start
assert_eq "$(order start "$s-grafana.service" "$s-prometheus.service" \
    "$s-node-exporter.service" "$s-collector.timer")" "$(grep '^start' "$SYSTEMCTL_LOG")" "start order"
"$ctl" start > "$tmp/out"
assert_grep "$tmp/out" '^storsafe-collector.timer  active$'; assert_grep "$tmp/out" '^storsafe-collector.service  ran, result OK$'
export SYSTEMCTL_ACTIVE="storsafe-collector.timer storsafe-node-exporter.service storsafe-grafana.service"   # Prometheus did not start
assert_exit 1 quiet "$ctl" start
export SYSTEMCTL_ACTIVE="storsafe-collector.timer storsafe-node-exporter.service storsafe-prometheus.service storsafe-grafana.service"

# resume: the timer, then the collector service; the service is judged by is-failed, not is-active
# (a oneshot is inactive after a good run), and a failed run is exit 1.
: > "$SYSTEMCTL_LOG"
assert_exit 0 quiet "$ctl" resume
assert_eq "$(printf 'start storsafe-collector.timer\nstart storsafe-collector.service')" "$(grep '^start' "$SYSTEMCTL_LOG")" "resume order"
rc=0; SYSTEMCTL_FAILED="storsafe-collector.service" SYSTEMCTL_EXEC_STATUS=2 "$ctl" resume > "$tmp/out" 2>&1 || rc=$?
assert_eq 1 "$rc" "resume with a failed collector run exits 1"
assert_grep "$tmp/out" '^storsafe-collector.service  failed, result a check failed$'
export SYSTEMCTL_ACTIVE=""                                          # the timer did not start
assert_exit 1 quiet "$ctl" resume
# stop on a host with nothing installed: every unit absent, exit 0
export SYSTEMCTL_PRESENT=""
"$ctl" stop > "$tmp/out"; assert_exit 0 quiet "$ctl" stop; assert_eq 4 "$(grep -c '  absent$' "$tmp/out")" "absent units are reported"

# The command line: no action, an extra argument and an unknown one are usage errors (2), --help is 0.
assert_exit 2 quiet "$ctl"
assert_exit 2 quiet "$ctl" status extra
assert_exit 2 quiet "$ctl" Status
assert_exit 0 quiet "$ctl" --help
"$ctl" --help > "$tmp/out"; assert_grep "$tmp/out" '^usage: storsafe-control.sh <status|stop|start|pause|resume>$'
"$ctl" bogus > "$tmp/out" 2> "$tmp/err" || true; assert_not_grep "$tmp/out" 'usage'; assert_grep "$tmp/err" '^usage: '
exit "${FAILED:-0}"
