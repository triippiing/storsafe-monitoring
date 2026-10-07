#!/usr/bin/env bash
# Needs the mock StorSafe API on 127.0.0.1:18080 (tools/test/mock_api.py 18080) and pwsh on the PATH.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); source "$here/helpers.sh"; source "$here/../../../linux/lib.sh"
inst=$here/../../../linux/install.sh; repo=$here/../../..; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
root=$tmp/root; mkdir -p "$root"; (cd "$repo" && git archive HEAD | tar -x -C "$root")
cp "$repo/tools/test/mock.config.json" "$root/StorSafe.config.json"; cp "$repo/tools/test/mock-credential.xml" "$root/"
make_fake_tarballs "$root/installers"
# A hardened host: root's umask is 027, and the package folder, a folder, the config and two files are not
# readable by others. The installer makes them so (go+rX, never less) and creates its own folders 0755.
chmod 750 "$root" "$root/monitoring/dashboards"; chmod 640 "$root/StorSafe.psm1" "$root/monitoring/prometheus.yml" "$root/StorSafe.config.json"
# first_run: the first installer run with its output kept, so that the summary rows can be checked
# shellcheck disable=SC2329 # called through assert_exit
first_run() { ( umask 027; "$inst" --no-services --root "$root" --user "$(id -un)" --unit-dir "$tmp/units" --skip-credentials ) > "$tmp/run1.out" 2>&1; }
assert_exit 0 first_run
assert_file "$root/metrics/storsafe.prom"
assert_file "$root/node_exporter/node_exporter"; assert_eq node_exporter-1.9.1.linux-amd64.tar.gz "$(cat "$root/node_exporter/.version")"
assert_file "$root/prometheus/prometheus.yml"; assert_file "$root/grafana/bin/grafana"
assert_grep "$root/grafana/conf/provisioning/dashboards/storsafe-dashboards.yaml" "path: '$root/monitoring/dashboards'"
for u in storsafe-collector.service storsafe-collector.timer storsafe-node-exporter.service storsafe-prometheus.service storsafe-grafana.service; do
  assert_file "$tmp/units/$u"; assert_not_grep "$tmp/units/$u" '__[A-Z]*__'
done
assert_grep "$tmp/units/storsafe-node-exporter.service" -- '--web.listen-address=127.0.0.1:9182'
# the summary has a row per step, and the collector row carries the collector's own line
assert_grep "$tmp/run1.out" '^Credentials  *Skipped  *--skip-credentials$'
assert_grep "$tmp/run1.out" '^Collector test  *OK  *Wrote [0-9]* samples for 2 server(s) to '
assert_grep "$tmp/run1.out" '^node_exporter  *OK  *extracted node_exporter-1.9.1.linux-amd64.tar.gz$'
assert_grep "$tmp/run1.out" '^Prometheus  *OK  *extracted prometheus-3.15.0.linux-amd64.tar.gz$'
assert_grep "$tmp/run1.out" '^Grafana  *OK  *extracted grafana-12.0.2.linux-amd64.tar.gz$'
assert_grep "$tmp/run1.out" '^Units  *OK  *5 unit file(s) in '
assert_grep "$tmp/run1.out" 'Open Grafana at http://.*:3000'
assert_grep "$tmp/run1.out" "^Package permissions  *OK  *readable by $(id -un)\$"
for p in "" monitoring/dashboards node_exporter prometheus grafana grafana/conf/provisioning/dashboards; do
  assert_eq 755 "$(stat -c %a "$root/$p")" "mode of folder $root/$p"
done
for p in StorSafe.psm1 StorSafe.config.json monitoring/prometheus.yml; do assert_eq 644 "$(stat -c %a "$root/$p")" "mode of $p"; done
assert_eq 700 "$(stat -c %a "$root/creds")" "creds stays 0700"
# the unpacked programs belong to root, not to the owner the tarball carries (uid 1001, like the upstream ones),
# and the data folders to the service account
for p in node_exporter/node_exporter prometheus/prometheus prometheus/prometheus.yml grafana/bin/grafana; do assert_eq 0 "$(stat -c %u "$root/$p")" "owner of $p"; done
for p in prometheus/data grafana/data; do assert_eq "$(id -un)" "$(stat -c %U "$root/$p")" "owner of $p"; done
# the shared prometheus.yml is what Prometheus gets, and the data folders exist
assert_eq "" "$(diff "$root/monitoring/prometheus.yml" "$root/prometheus/prometheus.yml")" "prometheus.yml is the shared file"
for d in prometheus/data grafana/data/log; do [ -d "$root/$d" ] || { echo "FAIL folder $d"; FAILED=1; }; done
assert_file "$root/grafana/conf/provisioning/datasources/storsafe-datasource.yaml"
assert_eq 644 "$(stat -c %a "$tmp/units/storsafe-collector.service")" "unit mode"
# second run: nothing re-extracted; newer tarball: re-extracted
out=$("$inst" --no-services --root "$root" --user "$(id -un)" --unit-dir "$tmp/units" --skip-credentials)
echo "$out" | grep -q 'already extracted node_exporter-1.9.1' || { echo "FAIL idempotent"; FAILED=1; }
# the credential file of the mock config is there, so a run without --skip-credentials asks for nothing
out=$("$inst" --no-services --root "$root" --user "$(id -un)" --unit-dir "$tmp/units" < /dev/null)
echo "$out" | grep -Eq '^Credentials +OK +1 file\(s\) present$' || { echo "FAIL credentials present"; FAILED=1; }
# an upgrade empties the component folder except data/, also when the folder is a symlink (a data disk)
mkdir -p "$root/node_exporter/data"; touch "$root/node_exporter/data/keep" "$root/node_exporter/stray"
mv "$root/node_exporter" "$tmp/ne_real"; ln -s "$tmp/ne_real" "$root/node_exporter"
cp "$root/installers/node_exporter-1.9.1.linux-amd64.tar.gz" "$root/installers/node_exporter-1.9.2.linux-amd64.tar.gz"
"$inst" --no-services --root "$root" --user "$(id -un)" --unit-dir "$tmp/units" --skip-credentials > /dev/null
assert_eq node_exporter-1.9.2.linux-amd64.tar.gz "$(cat "$root/node_exporter/.version")" "newer tarball wins"
assert_file "$root/node_exporter/data/keep"
[ -e "$root/node_exporter/stray" ] && { echo "FAIL stray file kept by the upgrade"; FAILED=1; }
assert_file "$root/node_exporter/node_exporter"
# collector-only: no Prometheus or Grafana, node_exporter on all interfaces, scrape job printed
rm -rf "$tmp/units2"
out=$("$inst" --no-services --collector-only --root "$root" --user "$(id -un)" --unit-dir "$tmp/units2" --skip-credentials)
[ -e "$tmp/units2/storsafe-prometheus.service" ] && { echo "FAIL prometheus unit in collector-only"; FAILED=1; }
assert_grep "$tmp/units2/storsafe-node-exporter.service" -- '--web.listen-address=0.0.0.0:9182'
echo "$out" | grep -q 'job_name: storsafe' || { echo "FAIL scrape job"; FAILED=1; }
# With a service account of its own (nobody stands in for it; a runuser shim lets the collector test run as root)
# it owns what the service writes, and the programs stay root's.
if id -u nobody > /dev/null 2>&1; then
  root2=$tmp/root2; mkdir -p "$root2"; (cd "$repo" && git archive HEAD | tar -x -C "$root2")
  cp "$repo/tools/test/mock.config.json" "$root2/StorSafe.config.json"; cp "$repo/tools/test/mock-credential.xml" "$root2/"
  make_fake_tarballs "$root2/installers"; make_runuser_shim "$tmp/shimbin"
  PATH="$tmp/shimbin:$PATH" "$inst" --no-services --root "$root2" --user nobody --unit-dir "$tmp/units4" --skip-credentials > "$tmp/run2.out" 2>&1 || { cat "$tmp/run2.out"; FAILED=1; }
  for p in node_exporter node_exporter/node_exporter prometheus prometheus/prometheus prometheus/prometheus.yml grafana/bin/grafana grafana/conf/provisioning/datasources/storsafe-datasource.yaml; do
    assert_eq root "$(stat -c %U "$root2/$p")" "owner of $p"
  done
  for p in creds state metrics prometheus/data grafana/data grafana/data/log; do assert_eq nobody "$(stat -c %U "$root2/$p")" "owner of $p"; done
  # With the real runuser the account must be able to read the package. $tmp is 0700, so it cannot: the installer says so and
  # stops. Once the folder above is open, the check passes.
  if runuser -u nobody -- true > /dev/null 2>&1; then
    rc=0; out=$("$inst" --no-services --root "$root2" --user nobody --unit-dir "$tmp/units4" --skip-credentials 2>&1) || rc=$?
    assert_eq 1 "$rc" "a package the account cannot read stops the installer"
    echo "$out" | grep -Eq "^Package permissions +Check +$root2/StorSafe.psm1 is not readable by nobody; check the folders above $root2\$" || { echo "FAIL unreadable package row"; FAILED=1; }
    echo "$out" | grep -q '^Collector test' && { echo "FAIL the installer went on after the unreadable package"; FAILED=1; }
    chmod 755 "$tmp"
    out=$("$inst" --no-services --root "$root2" --user nobody --unit-dir "$tmp/units4" --skip-credentials 2>&1 || true)
    echo "$out" | grep -Eq '^Package permissions +OK +readable by nobody$' || { echo "FAIL readable package row"; FAILED=1; }
  fi
fi
exit "${FAILED:-0}"
