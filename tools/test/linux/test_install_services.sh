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
: > "$SYSTEMCTL_LOG"; sed -i 's/RestartSec=5/RestartSec=6/' "$tmp/units/storsafe-node-exporter.service"   # simulate a template change
PATH="$tmp/bin:$PATH" "$inst" --root "$root" --user "$(id -un)" --unit-dir "$tmp/units" --skip-credentials > /dev/null 2>&1 || true
assert_grep "$tmp/sc.log" '^restart storsafe-node-exporter.service$'
: > "$SYSTEMCTL_LOG"
PATH="$tmp/bin:$PATH" "$inst" --uninstall --root "$root" --unit-dir "$tmp/units" > "$tmp/un" 2>&1
assert_grep "$tmp/sc.log" '^disable --now storsafe-collector.timer$'
[ -e "$tmp/units/storsafe-prometheus.service" ] && { echo "FAIL unit not removed"; FAILED=1; }
assert_grep "$tmp/un" 'userdel'
exit "${FAILED:-0}"
