#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); source "$here/helpers.sh"; source "$here/../../../linux/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/fakecurl" <<'EOF'
#!/usr/bin/env bash
ARGV="$*"; out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; url=$1; shift; done
echo "$url" >> "${FAKE_LOG:?}"; echo "$ARGV" >> "${FAKE_ARGV:?}"
echo partial > "$out"; [[ "$url" == *fail* ]] && exit 22; echo data > "$out"
EOF
chmod +x "$tmp/fakecurl"; export STORSAFE_CURL=$tmp/fakecurl FAKE_LOG=$tmp/log FAKE_ARGV=$tmp/argv
gi=$here/../../../linux/get-installers.sh
# capture <stdout file> <stderr file> cmd...: runs the command with its output kept for the asserts.
capture() { local o=$1 e=$2; shift 2; "$@" > "$o" 2> "$e"; }
vers=(--prometheus-version 3.15.0 --grafana-version 12.0.2 --node-exporter-version 1.9.1 --powershell-version 7.4.6)

[[ -x $gi ]] || assert_fail "get-installers.sh is executable"

# A first run downloads all four tarballs, prints get/ok lines and ends with the table of files.
assert_exit 0 capture "$tmp/out1" "$tmp/err1" "$gi" --dest "$tmp/inst" "${vers[@]}"
assert_file "$tmp/inst/prometheus-3.15.0.linux-amd64.tar.gz"; assert_file "$tmp/inst/grafana-12.0.2.linux-amd64.tar.gz"
assert_file "$tmp/inst/node_exporter-1.9.1.linux-amd64.tar.gz"; assert_file "$tmp/inst/powershell-7.4.6-linux-x64.tar.gz"
assert_grep "$tmp/log" '^https://github.com/prometheus/prometheus/releases/download/v3.15.0/prometheus-3.15.0.linux-amd64.tar.gz$'
assert_grep "$tmp/log" '^https://dl.grafana.com/oss/release/grafana-12.0.2.linux-amd64.tar.gz$'
assert_grep "$tmp/log" '^https://github.com/prometheus/node_exporter/releases/download/v1.9.1/node_exporter-1.9.1.linux-amd64.tar.gz$'
assert_grep "$tmp/log" '^https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/powershell-7.4.6-linux-x64.tar.gz$'
assert_eq 4 "$(wc -l < "$tmp/log")" "four downloads"
# The fetch command: curl -fL --retry 3 into <name>.part with the URL last; the file is moved into place afterwards.
assert_eq 4 "$(grep -c '^-fL --retry 3 -o [^ ]*\.part https://[^ ]*$' "$tmp/argv" || true)" "every fetch is curl -fL --retry 3 -o <part> <url>"
assert_grep "$tmp/argv" '^-fL --retry 3 -o [^ ]*/inst/grafana-12\.0\.2\.linux-amd64\.tar\.gz\.part https://dl\.grafana\.com/oss/release/grafana-12\.0\.2\.linux-amd64\.tar\.gz$'
assert_eq data "$(<"$tmp/inst/grafana-12.0.2.linux-amd64.tar.gz")" "the finished file is the moved .part"
assert_grep "$tmp/out1" '^get     https://dl.grafana.com/oss/release/grafana-12.0.2.linux-amd64.tar.gz$'
assert_grep "$tmp/out1" '^ok      grafana-12.0.2.linux-amd64.tar.gz (0.0 MB)$'
assert_grep "$tmp/out1" '^File  *Size$'
assert_grep "$tmp/out1" '^powershell-7.4.6-linux-x64.tar.gz  *0.0 MB$'
assert_eq 0 "$(find "$tmp/inst" -name '*.part' | wc -l)" "no .part file left"
assert_eq "" "$(<"$tmp/err1")" "a clean run writes nothing to stderr"

# A second run keeps the existing files and downloads nothing.
assert_exit 0 capture "$tmp/out2" "$tmp/err2" "$gi" --dest "$tmp/inst" "${vers[@]}"
assert_grep "$tmp/out2" '^exists  prometheus-3.15.0.linux-amd64.tar.gz$'
assert_grep "$tmp/out2" '^exists  powershell-7.4.6-linux-x64.tar.gz$'
assert_not_grep "$tmp/out2" '^get '
assert_eq 4 "$(wc -l < "$tmp/log")" "second run downloads nothing"

# --force fetches them again.
assert_exit 0 capture "$tmp/out3" "$tmp/err3" "$gi" --dest "$tmp/inst" --force "${vers[@]}"
assert_eq 8 "$(wc -l < "$tmp/log")" "--force downloads again"
assert_not_grep "$tmp/out3" '^exists '

# A failed download is a warning: every file is still tried, the table is still printed, exit 2 comes last.
: > "$tmp/log"
mkdir -p "$tmp/inst2"; echo junk > "$tmp/inst2/grafana-fail.linux-amd64.tar.gz.part"
assert_exit 2 capture "$tmp/out4" "$tmp/err4" "$gi" --dest "$tmp/inst2" --grafana-version fail
assert_eq 4 "$(wc -l < "$tmp/log")" "a failed download does not stop the others"
assert_grep "$tmp/err4" '^warning: download failed: https://dl.grafana.com/oss/release/grafana-fail.linux-amd64.tar.gz$'
assert_file "$tmp/inst2/node_exporter-1.12.1.linux-amd64.tar.gz"; assert_file "$tmp/inst2/powershell-7.6.6-linux-x64.tar.gz"
assert_eq 0 "$(find "$tmp/inst2" -name '*grafana*' | wc -l)" "no grafana file or .part after the failure"
assert_eq 0 "$(find "$tmp/inst2" -name '*.part' | wc -l)" "the partial file of the failed fetch is removed"
assert_grep "$tmp/out4" '^File  *Size$'

# --print-urls prints the four default URLs, touches no file and starts no download.
: > "$tmp/log"
assert_exit 0 capture "$tmp/out5" "$tmp/err5" "$gi" --dest "$tmp/none" --print-urls
assert_eq "https://github.com/prometheus/node_exporter/releases/download/v1.12.1/node_exporter-1.12.1.linux-amd64.tar.gz
https://github.com/prometheus/prometheus/releases/download/v3.15.0/prometheus-3.15.0.linux-amd64.tar.gz
https://dl.grafana.com/oss/release/grafana-12.0.2.linux-amd64.tar.gz
https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/powershell-7.6.6-linux-x64.tar.gz" "$(<"$tmp/out5")" "default URLs"
[[ ! -e $tmp/none ]] || assert_fail "--print-urls creates nothing"
assert_eq 0 "$(wc -l < "$tmp/log")" "--print-urls downloads nothing"
assert_exit 0 capture "$tmp/out6" "$tmp/err6" "$gi" --print-urls --grafana-version 12.1.0
assert_grep "$tmp/out6" '^https://dl.grafana.com/oss/release/grafana-12.1.0.linux-amd64.tar.gz$'

# Without --dest the files go to <repo>/installers, found from the script, not from the current directory.
mkdir -p "$tmp/repo/linux" "$tmp/elsewhere"; cp "$gi" "$tmp/repo/linux/get-installers.sh"
from_elsewhere() { cd "$tmp/elsewhere" && ../repo/linux/get-installers.sh "$@" > /dev/null; }
assert_exit 0 from_elsewhere "${vers[@]}"
assert_file "$tmp/repo/installers/prometheus-3.15.0.linux-amd64.tar.gz"
assert_eq 0 "$(find "$tmp/elsewhere" -mindepth 1 | wc -l)" "nothing is written to the current directory"
# Run through a symlink, the files go next to the real script, not next to the link.
ln -s "$tmp/repo/linux/get-installers.sh" "$tmp/elsewhere/gi"
from_link() { cd "$tmp/elsewhere" && ./gi "$@" > /dev/null; }
assert_exit 0 from_link "${vers[@]}" --prometheus-version 3.15.1
assert_file "$tmp/repo/installers/prometheus-3.15.1.linux-amd64.tar.gz"
[[ ! -e $tmp/installers ]] || assert_fail "a symlinked script writes next to the link's folder"
assert_eq 1 "$(find "$tmp/elsewhere" -mindepth 1 | wc -l)" "only the symlink is in the current directory"

# Usage: --help prints to stdout and exits 0; bad options print to stderr and exit 2 without creating anything.
assert_exit 0 capture "$tmp/out7" "$tmp/err7" "$gi" --help
assert_grep "$tmp/out7" '^usage: '
assert_exit 2 capture "$tmp/out8" "$tmp/err8" "$gi" --dest "$tmp/bad" --bogus
assert_grep "$tmp/err8" '^usage: '
assert_eq "" "$(<"$tmp/out8")" "usage error writes nothing to stdout"
assert_exit 2 capture "$tmp/out9" "$tmp/err9" "$gi" --dest "$tmp/bad" --grafana-version
assert_grep "$tmp/err9" '^error: --grafana-version needs a value$'
assert_exit 2 capture "$tmp/out10" "$tmp/err10" "$gi" --dest
assert_exit 2 capture "$tmp/out11" "$tmp/err11" "$gi" --dest "$tmp/bad" --grafana-version --force
assert_grep "$tmp/err11" '^error: --grafana-version needs a value$'
[[ ! -e $tmp/bad ]] || assert_fail "a usage error creates nothing"
exit "${FAILED:-0}"
