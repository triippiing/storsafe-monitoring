#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); source "$here/helpers.sh"; source "$here/../../../linux/lib.sh"
units=$here/../../../linux/systemd; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for f in storsafe-collector.service storsafe-collector.timer storsafe-node-exporter.service storsafe-prometheus.service storsafe-grafana.service; do
  assert_file "$units/$f"
  render_template "$units/$f" "$tmp/$f" ROOT=/opt/sm USER=storsafe PWSH=/usr/bin/pwsh LISTEN=127.0.0.1:9182 RETENTION=180 INTERVAL=5 RUNTIME=240 \
    || { echo "FAIL render $f"; FAILED=1; }
  assert_not_grep "$tmp/$f" '__[A-Z]*__'
done
assert_grep "$tmp/storsafe-collector.service" '^ExecStart=/usr/bin/pwsh -NoProfile -NonInteractive -File /opt/sm/Export-StorSafeMetrics.ps1 -All -NonInteractive$'
assert_grep "$tmp/storsafe-collector.service" '^RuntimeMaxSec=240$'
assert_grep "$tmp/storsafe-collector.service" '^TimeoutStartSec=240$'
assert_grep "$tmp/storsafe-collector.service" '^SuccessExitStatus=2$'
assert_grep "$tmp/storsafe-collector.timer" '^OnUnitActiveSec=5min$'
assert_grep "$tmp/storsafe-node-exporter.service" -- '--web.listen-address=127.0.0.1:9182'
assert_grep "$tmp/storsafe-prometheus.service" -- '--storage.tsdb.retention.time=180d --web.listen-address=127.0.0.1:9090'
assert_grep "$tmp/storsafe-grafana.service" '^Environment=GF_PATHS_LOGS=/opt/sm/grafana/data/log$'
for f in storsafe-collector.service storsafe-node-exporter.service storsafe-prometheus.service storsafe-grafana.service; do
  assert_grep "$tmp/$f" '^NoNewPrivileges=true$'; assert_grep "$tmp/$f" '^User=storsafe$'
done
exit "${FAILED:-0}"
