#!/usr/bin/env bash
# Shared shell library for the Linux monitoring host: install.sh and storsafe-control.sh source it.
# Never execute this file. It sets no shell options and is safe to source under set -euo pipefail.
# Every function returns explicitly, so none of them trips set -e in the caller.

# Rows collected by summary_add, one string per row: step TAB result TAB note.
SUMMARY_ROWS=()

# Prints a blank line, then "== <title>": the heading of one installer step.
log_step() {
    printf '\n== %s\n' "$1"
}

# Records one row for the final table. The note may be empty.
summary_add() {
    SUMMARY_ROWS+=("$1"$'\t'"$2"$'\t'"$3")
}

# Prints the collected rows as a three-column table (Step, Result, Note), columns fitted to the
# content, separated by two spaces, with no trailing spaces on any line.
summary_print() {
    local w1=4 w2=6 i row step rest result note line
    for ((i = 0; i < ${#SUMMARY_ROWS[@]}; i++)); do
        row=${SUMMARY_ROWS[i]}
        step=${row%%$'\t'*}
        rest=${row#*$'\t'}
        result=${rest%%$'\t'*}
        if [[ ${#step} -gt $w1 ]]; then w1=${#step}; fi
        if [[ ${#result} -gt $w2 ]]; then w2=${#result}; fi
    done
    line=$(printf '%-*s  %-*s  %s' "$w1" Step "$w2" Result Note)
    printf '%s\n' "$line"
    for ((i = 0; i < ${#SUMMARY_ROWS[@]}; i++)); do
        row=${SUMMARY_ROWS[i]}
        step=${row%%$'\t'*}
        rest=${row#*$'\t'}
        result=${rest%%$'\t'*}
        note=${rest#*$'\t'}
        line=$(printf '%-*s  %-*s  %s' "$w1" "$step" "$w2" "$result" "$note")
        # Cut the padding left behind when the note is empty.
        printf '%s\n' "${line%"${line##*[! ]}"}"
    done
    return 0
}

# Prints "error: <message>" to stderr and exits 1.
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

# Prints rhel, debian or unknown, from ID and ID_LIKE in $OS_RELEASE_FILE (default /etc/os-release).
# The file is parsed, not sourced, so its other variables do not leak into the caller.
detect_family() {
    local file=${OS_RELEASE_FILE:-/etc/os-release} id="" like="" key value
    if [[ ! -r $file ]]; then
        echo unknown
        return 0
    fi
    while IFS='=' read -r key value || [[ -n $key ]]; do
        value=${value//\"/}
        value=${value//\'/}
        case $key in
            ID) id=$value ;;
            ID_LIKE) like=$value ;;
        esac
    done < "$file"
    case " $id $like " in
        *" rhel "* | *" centos "* | *" fedora "*) echo rhel ;;
        *" debian "* | *" ubuntu "*) echo debian ;;
        *) echo unknown ;;
    esac
    return 0
}

# render_template <src> <dst> KEY=VALUE...: copies src to dst with every __KEY__ replaced by its
# value (a single line; slashes, ampersands and backslashes are fine). Returns 1 and prints the
# names to stderr when a __NAME__ placeholder is left in dst. dst is written in either case.
render_template() {
    local src=$1 dst=$2 arg key value names
    shift 2
    # The empty first expression keeps the array non-empty when no KEY=VALUE is given.
    local -a sedargs=(-e '')
    for arg in "$@"; do
        if [[ $arg != *=* ]]; then
            echo "error: render_template: expected KEY=VALUE, got '$arg'" >&2
            return 1
        fi
        key=${arg%%=*}
        value=${arg#*=}
        # Escape what sed treats specially in the replacement (backslash, ampersand, delimiter).
        value=$(printf '%s' "$value" | sed -e 's/[\\&|]/\\&/g')
        sedargs+=(-e "s|__${key}__|${value}|g")
    done
    if ! sed "${sedargs[@]}" "$src" > "$dst"; then
        echo "error: cannot render $src to $dst" >&2
        return 1
    fi
    if grep -qE '__[A-Z]+__' "$dst"; then
        names=$(grep -oE '__[A-Z]+__' "$dst" | sed -e 's/^__//' -e 's/__$//' | sort -u | tr '\n' ' ')
        echo "error: unrendered placeholders in $dst: ${names% }" >&2
        return 1
    fi
    return 0
}

# http_ok <url> <timeout_seconds>: returns 0 as soon as a GET of the url succeeds, trying every
# 2 s, or 1 when it has not succeeded after the timeout.
http_ok() {
    local url=$1 timeout=$2 start=$SECONDS left
    while :; do
        if curl -fsS -o /dev/null --max-time 5 "$url"; then
            return 0
        fi
        left=$((timeout - (SECONDS - start)))
        if [[ $left -le 0 ]]; then
            return 1
        fi
        if [[ $left -gt 2 ]]; then left=2; fi
        sleep "$left"
    done
}

# port_in_use <port>: returns 0 when something listens on the TCP port, 1 otherwise. Uses ss when
# it is installed, else tries to connect to 127.0.0.1 through bash's /dev/tcp.
port_in_use() {
    local port=$1
    if command -v ss > /dev/null 2>&1; then
        if ss -ltn 2> /dev/null | awk -v port="$port" '$4 ~ (":" port "$") { found = 1 } END { exit !found }'; then
            return 0
        fi
        return 1
    fi
    # The port reaches the inner shell as $1, so the single quotes are intended.
    # shellcheck disable=SC2016
    if timeout 1 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1"' _ "$port" > /dev/null 2>&1; then
        return 0
    fi
    return 1
}

# runtime_max_sec <interval_minutes>: prints the RuntimeMaxSec for the collector service, one
# minute less than the interval but never below 120 s.
runtime_max_sec() {
    local sec=$(($1 - 1))
    sec=$((sec * 60))
    if [[ $sec -lt 120 ]]; then
        sec=120
    fi
    echo "$sec"
    return 0
}
