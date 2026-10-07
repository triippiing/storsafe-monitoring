#!/usr/bin/env bash
# Needs the mock StorSafe API on 127.0.0.1:18080 (tools/test/mock_api.py 18080) and pwsh on the PATH.
# Runs the installer with a systemctl shim first on the PATH, so the services step really runs.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); source "$here/helpers.sh"; source "$here/../../../linux/lib.sh"
inst=$here/../../../linux/install.sh; repo=$here/../../..; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
root=$tmp/root; mkdir -p "$root"; (cd "$repo" && git archive HEAD | tar -x -C "$root")
cp "$repo/tools/test/mock.config.json" "$root/StorSafe.config.json"; cp "$repo/tools/test/mock-credential.xml" "$root/"
make_fake_tarballs "$root/installers"
export STORSAFE_HTTP_TIMEOUT=2
make_systemctl_shim "$tmp/bin"; export SYSTEMCTL_LOG=$tmp/sc.log SYSTEMCTL_ACTIVE="storsafe-node-exporter.service"
PATH="$tmp/bin:$PATH" "$inst" --root "$root" --user "$(id -un)" --unit-dir "$tmp/units" --skip-credentials > "$tmp/out" 2>&1 || true
assert_grep "$tmp/sc.log" '^daemon-reload$'
assert_grep "$tmp/sc.log" '^enable --now storsafe-collector.timer$'
assert_grep "$tmp/sc.log" '^enable --now storsafe-grafana.service$'
assert_not_grep "$tmp/sc.log" '^enable --now storsafe-collector.service$'
assert_grep "$tmp/out" 'not answering on 9090 after 2 s'        # nothing really listens; STORSAFE_HTTP_TIMEOUT=2 is exported in the setup lines
# systemd must be told about the new unit files before it enables them
reload_line=$(grep -n -m 1 '^daemon-reload$' "$tmp/sc.log" | cut -d: -f1 || true)
enable_line=$(grep -n -m 1 '^enable --now ' "$tmp/sc.log" | cut -d: -f1 || true)
[[ -n $reload_line && -n $enable_line && $reload_line -lt $enable_line ]] || assert_fail "daemon-reload comes before the first enable --now" "daemon-reload on line '$reload_line', first enable on line '$enable_line'"
: > "$SYSTEMCTL_LOG"; sed -i 's/RestartSec=5/RestartSec=6/' "$tmp/units/storsafe-node-exporter.service"   # simulate a template change
PATH="$tmp/bin:$PATH" "$inst" --root "$root" --user "$(id -un)" --unit-dir "$tmp/units" --skip-credentials > /dev/null 2>&1 || true
assert_grep "$tmp/sc.log" '^restart storsafe-node-exporter.service$'
# a changed timer that runs is restarted too (a running timer keeps its old schedule), the oneshot service never is
: > "$SYSTEMCTL_LOG"; sed -i 's/AccuracySec=15s/AccuracySec=16s/' "$tmp/units/storsafe-collector.timer"
export SYSTEMCTL_ACTIVE="storsafe-node-exporter.service storsafe-collector.timer"
PATH="$tmp/bin:$PATH" "$inst" --root "$root" --user "$(id -un)" --unit-dir "$tmp/units" --skip-credentials > /dev/null 2>&1 || true
assert_grep "$tmp/sc.log" '^restart storsafe-collector.timer$'
assert_not_grep "$tmp/sc.log" '^restart storsafe-collector.service$'
assert_not_grep "$tmp/sc.log" '^restart storsafe-node-exporter.service$'
# negative control: nothing changed since the last run, so nothing is restarted
: > "$SYSTEMCTL_LOG"
PATH="$tmp/bin:$PATH" "$inst" --root "$root" --user "$(id -un)" --unit-dir "$tmp/units" --skip-credentials > /dev/null 2>&1 || true
assert_grep "$tmp/sc.log" '^daemon-reload$'
assert_not_grep "$tmp/sc.log" '^restart'
# A component without its program (a missing tarball, or one that cannot be unpacked) is neither enabled nor
# waited for, whatever its unit file says, and the Services row names it; the others are started as usual.
root2=$tmp/root2; mkdir -p "$root2"; (cd "$repo" && git archive HEAD | tar -x -C "$root2")
cp "$repo/tools/test/mock.config.json" "$root2/StorSafe.config.json"; cp "$repo/tools/test/mock-credential.xml" "$root2/"
make_fake_tarballs "$root2/installers"; rm "$root2"/installers/node_exporter-*.tar.gz
printf 'not a tarball\n' > "$root2/installers/prometheus-3.15.0.linux-amd64.tar.gz"
: > "$SYSTEMCTL_LOG"
PATH="$tmp/bin:$PATH" "$inst" --root "$root2" --user "$(id -un)" --unit-dir "$tmp/units2" --skip-credentials > "$tmp/out2" 2>&1 || true
assert_grep "$tmp/out2" '^node_exporter  *Missing installer  *put node_exporter-<ver>.linux-amd64.tar.gz in installers/ and re-run$'
assert_grep "$tmp/out2" '^Prometheus  *Check  *cannot extract prometheus-3.15.0.linux-amd64.tar.gz'
assert_grep "$tmp/out2" '^Services  *Check  *storsafe-node-exporter.service not enabled: installer missing; storsafe-prometheus.service not enabled: its step failed$'
assert_grep "$tmp/sc.log" '^enable --now storsafe-grafana.service$'
assert_grep "$tmp/sc.log" '^enable --now storsafe-collector.timer$'
assert_not_grep "$tmp/sc.log" '^enable --now storsafe-node-exporter.service$'
assert_not_grep "$tmp/sc.log" '^enable --now storsafe-prometheus.service$'
assert_not_grep "$tmp/out2" '^node_exporter  *\(OK\|Check\)'                  # no wait row for a unit that was not enabled
assert_not_grep "$tmp/out2" '^Prometheus  *\(OK  *answering\|Check  *not answering\)'
assert_grep "$tmp/out2" '^Grafana  *Check  *not answering on 3000 after 2 s$'    # the units that were enabled are waited for
PATH="$tmp/bin:$PATH" "$inst" --no-services --root "$root2" --user "$(id -un)" --unit-dir "$tmp/units2b" --skip-credentials > "$tmp/out2b" 2>&1 || true
assert_grep "$tmp/out2b" '^would run: systemctl enable --now storsafe-grafana.service$'
assert_not_grep "$tmp/out2b" 'systemctl enable --now storsafe-node-exporter.service'
assert_grep "$tmp/out2b" '^Services  *Skipped  *--no-services; commands printed above; storsafe-node-exporter.service not enabled: installer missing; '
# --no-services --uninstall removes the files but runs nothing, and the summary says so
cp -r "$tmp/units" "$tmp/units3"; : > "$SYSTEMCTL_LOG"
PATH="$tmp/bin:$PATH" "$inst" --no-services --uninstall --root "$root" --unit-dir "$tmp/units3" > "$tmp/un3" 2>&1 || true
assert_grep "$tmp/un3" '^storsafe-collector.timer  *OK  *removed (disable not run: --no-services)$'
assert_grep "$tmp/un3" '^would run: systemctl disable --now storsafe-collector.timer$'
assert_not_grep "$tmp/sc.log" '^disable'
[ -e "$tmp/units3/storsafe-collector.timer" ] && { echo "FAIL unit not removed with --no-services"; FAILED=1; }
: > "$SYSTEMCTL_LOG"
rc=0
PATH="$tmp/bin:$PATH" "$inst" --uninstall --root "$root" --unit-dir "$tmp/units" > "$tmp/un" 2>&1 || rc=$?
assert_eq 0 "$rc" "uninstall exit code"
assert_grep "$tmp/sc.log" '^disable --now storsafe-collector.timer$'
[ -e "$tmp/units/storsafe-prometheus.service" ] && { echo "FAIL unit not removed"; FAILED=1; }
# the userdel hint names the account the units run as (User= of the collector unit), not the default of this run
assert_grep "$tmp/un" "^  userdel $(id -un)\$"
assert_not_grep "$tmp/un" 'userdel storsafe'
# with no unit file to read it falls back to --user (the default is storsafe)
PATH="$tmp/bin:$PATH" "$inst" --uninstall --root "$root" --user svc-storsafe --unit-dir "$tmp/units" > "$tmp/un2" 2>&1 || true
assert_grep "$tmp/un2" '^  userdel svc-storsafe$'
exit "${FAILED:-0}"
