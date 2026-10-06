#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); source "$here/helpers.sh"; source "$here/../../../linux/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
repo=$here/../../..; ver=$(cat "$repo/VERSION")
python3 "$repo/tools/build-package.py" > /dev/null
assert_file "$repo/dist/StorSafe-monitoring-v$ver.tar.gz"
tar -tzvf "$repo/dist/StorSafe-monitoring-v$ver.tar.gz" > "$tmp/list"
assert_grep "$tmp/list" '^-rwxr-xr-x .* StorSafeMonitoring/linux/get-installers.sh$'
assert_grep "$tmp/list" '^-rw-r--r-- .* StorSafeMonitoring/linux/systemd/storsafe-collector.timer$'
assert_grep "$tmp/list" ' StorSafeMonitoring/Export-StorSafeMetrics.ps1$'
assert_not_grep "$tmp/list" ' StorSafeMonitoring/tools/'
assert_not_grep "$tmp/list" ' StorSafeMonitoring/\.\(github\|superpowers\)/'
assert_grep "$tmp/list" ' StorSafeMonitoring/monitoring/grafana/storsafe-datasource.yaml$'
zipn=$(python3 -c "import zipfile,sys; print(len(zipfile.ZipFile(sys.argv[1]).namelist()))" "$repo/dist/StorSafe-monitoring-v$ver.zip"); tarn=$(grep -c . "$tmp/list")
assert_eq "$zipn" "$tarn" "zip and tar carry the same number of entries"
assert_eq "$tarn" "$(grep -c ' root/root ' "$tmp/list")" "every tar entry is owned by root/root"
assert_grep "$repo/monitoring/prometheus.yml" "regex: 'storsafe_.\*|windows_textfile_.\*|node_textfile_.\*'"
assert_grep "$repo/.gitattributes" '^linux/\*\* text eol=lf$'
exit "${FAILED:-0}"
