#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); source "$here/helpers.sh"; source "$here/../../../linux/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf 'ID=rocky\nID_LIKE="rhel centos fedora"\n' > "$tmp/os"; OS_RELEASE_FILE=$tmp/os
assert_eq rhel "$(detect_family)" "rocky is rhel family"
printf 'ID=ubuntu\nID_LIKE=debian\n' > "$tmp/os";  assert_eq debian "$(detect_family)" "ubuntu is debian family"
printf 'ID=alpine\n' > "$tmp/os";                  assert_eq unknown "$(detect_family)" "alpine is unknown"
printf 'A=__ROOT__ B=__USER__\n' > "$tmp/t"
render_template "$tmp/t" "$tmp/out" ROOT=/opt/x USER=storsafe
assert_grep "$tmp/out" '^A=/opt/x B=storsafe$'
assert_exit 1 render_template "$tmp/t" "$tmp/out2" ROOT=/opt/x        # USER left over
assert_eq 240 "$(runtime_max_sec 5)" "runtime for 5 min"
assert_eq 120 "$(runtime_max_sec 2)" "runtime floor"
summary_add Pre OK "all good"; summary_add Grafana Check "not answering on 3000"
summary_print | grep -q '^Grafana *Check *not answering on 3000$' || { echo "FAIL summary row"; FAILED=1; }
assert_exit 1 http_ok http://127.0.0.1:1/ 3
exit "${FAILED:-0}"
