#!/usr/bin/env bash
# Downloads the four third-party tarballs into installers/ (node_exporter, Prometheus, Grafana,
# PowerShell). This is the Linux counterpart of Get-StorSafeInstallers.ps1.
#
# Versions default to the ones this package targets; override them with the --*-version
# options. Check https://github.com/prometheus/node_exporter/releases, https://prometheus.io/download/,
# https://grafana.com/grafana/download?platform=linux and
# https://github.com/PowerShell/PowerShell/releases (the 7.6 LTS line) for newer ones.
# Files that already exist are kept unless --force. curl uses the proxy settings of the environment
# (https_proxy, no_proxy); run the script with them set if the host needs a proxy.
#
# If the host has no internet access, run --print-urls on a machine that has, download the four URLs
# there and copy the files into installers/.
#
# Exit status: 0 when every file is in place, 1 when the destination folder cannot be created, 2 when a
# download failed (the others are still tried) or the command line is wrong.
#
# Examples:
#   linux/get-installers.sh
#   linux/get-installers.sh --grafana-version 12.1.0
#   linux/get-installers.sh --print-urls
set -euo pipefail

node_exporter_version=1.12.1
prometheus_version=3.15.0
grafana_version=12.0.2
powershell_version=7.6.6
dest=""
force=0
print_urls=0

usage() {
    cat << EOF
usage: get-installers.sh [--dest DIR] [--force] [--print-urls]
                         [--node-exporter-version V] [--prometheus-version V]
                         [--grafana-version V] [--powershell-version V]

  --dest DIR                  folder for the tarballs (default: installers/ next to linux/)
  --force                     download again even when the file exists
  --print-urls                print the four download URLs and exit
  --node-exporter-version V   default $node_exporter_version
  --prometheus-version V      default $prometheus_version
  --grafana-version V         default $grafana_version
  --powershell-version V      default $powershell_version
  -h, --help                  show this text
EOF
}

# Prints "error: <message>" and the usage text to stderr and exits 2.
usage_error() {
    printf 'error: %s\n' "$1" >&2
    usage >&2
    exit 2
}

# need_value "$@": the option in $1 must be followed by a value that is not empty and does not start
# with a dash (that would be the next option; give a folder such as -x as ./-x).
need_value() {
    if [[ $# -lt 2 || -z $2 || $2 == -* ]]; then
        usage_error "$1 needs a value"
    fi
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -h | --help) usage; exit 0 ;;
        --force) force=1; shift ;;
        --print-urls) print_urls=1; shift ;;
        --dest) need_value "$@"; dest=$2; shift 2 ;;
        --node-exporter-version) need_value "$@"; node_exporter_version=$2; shift 2 ;;
        --prometheus-version) need_value "$@"; prometheus_version=$2; shift 2 ;;
        --grafana-version) need_value "$@"; grafana_version=$2; shift 2 ;;
        --powershell-version) need_value "$@"; powershell_version=$2; shift 2 ;;
        *) usage_error "unknown option: $1" ;;
    esac
done

# installers/ sits next to linux/, found from this script and not from the current directory.
if [[ -z $dest ]]; then
    script_dir=$(cd "$(dirname "$(realpath "$0")")" && pwd)
    dest=$(dirname "$script_dir")/installers
fi

names=(
    "node_exporter-$node_exporter_version.linux-amd64.tar.gz"
    "prometheus-$prometheus_version.linux-amd64.tar.gz"
    "grafana-$grafana_version.linux-amd64.tar.gz"
    "powershell-$powershell_version-linux-x64.tar.gz"
)
urls=(
    "https://github.com/prometheus/node_exporter/releases/download/v$node_exporter_version/${names[0]}"
    "https://github.com/prometheus/prometheus/releases/download/v$prometheus_version/${names[1]}"
    "https://dl.grafana.com/oss/release/${names[2]}"
    "https://github.com/PowerShell/PowerShell/releases/download/v$powershell_version/${names[3]}"
)

if [[ $print_urls -eq 1 ]]; then
    printf '%s\n' "${urls[@]}"
    exit 0
fi

# size_mb <file>: prints the size of the file in MB with one decimal, like "12.3".
size_mb() {
    local bytes tenths
    bytes=$(stat -c %s "$1")
    tenths=$(((bytes * 10 + 524288) / 1048576))
    printf '%d.%d' $((tenths / 10)) $((tenths % 10))
}

if ! mkdir -p "$dest"; then
    echo "error: cannot create $dest" >&2
    exit 1
fi

# A failed download is a warning, not an abort: the other files are still tried and the exit
# status 2 comes at the end.
failed=0
for ((i = 0; i < ${#names[@]}; i++)); do
    name=${names[i]}
    url=${urls[i]}
    path=$dest/$name
    part=$path.part
    if [[ -e $path && $force -eq 0 ]]; then
        echo "exists  $name"
        continue
    fi
    echo "get     $url"
    rm -f "$part"
    if "${STORSAFE_CURL:-curl}" -fL --retry 3 -o "$part" "$url" && mv -f "$part" "$path"; then
        echo "ok      $name ($(size_mb "$path") MB)"
    else
        failed=$((failed + 1))
        rm -f "$part"
        echo "warning: download failed: $url" >&2
        echo "         download it by hand into $dest" >&2
    fi
done

# The table of the files in dest, the first column as wide as the longest name.
rows=()
width=4
for f in "$dest"/*; do
    name=${f##*/}
    if [[ ! -f $f || $name == README.txt ]]; then
        continue
    fi
    rows+=("$name")
    if [[ ${#name} -gt $width ]]; then
        width=${#name}
    fi
done
if [[ ${#rows[@]} -gt 0 ]]; then
    echo
    printf '%-*s  %s\n' "$width" File Size
    for ((i = 0; i < ${#rows[@]}; i++)); do
        printf '%-*s  %s MB\n' "$width" "${rows[i]}" "$(size_mb "$dest/${rows[i]}")"
    done
fi

if [[ $failed -gt 0 ]]; then
    exit 2
fi
exit 0
