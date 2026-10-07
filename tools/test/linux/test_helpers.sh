#!/usr/bin/env bash
# The assertions under test run in subshells on purpose: their FAILED must not reach this file.
# shellcheck disable=SC2030,SC2031
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); source "$here/helpers.sh"; source "$here/../../../linux/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# probe cmd...: runs one assertion in a subshell with a clean FAILED, prints its output, then FAILED=<n>.
probe() { ( FAILED=0; "$@" 2>&1; echo "FAILED=$FAILED" ); }
# expect_fail label text cmd...: the assertion under test must print FAIL and text, and leave FAILED=1.
expect_fail() {
    local label=$1 text=$2 out; shift 2
    out=$(probe "$@")
    [[ $out == *"FAIL "*"$text"*"FAILED=1" ]] || assert_fail "$label" "got: $out"
}
printf 'one\n--flag=1\n' > "$tmp/f"
assert_eq FAILED=0 "$(probe assert_grep "$tmp/f" -- '--flag')" "assert_grep takes -- before a dash pattern"
assert_eq FAILED=0 "$(probe assert_not_grep "$tmp/f" -- '--absent')" "assert_not_grep takes -- and passes when absent"
expect_fail "assert_grep fails on an invalid regex" "grep error" assert_grep "$tmp/f" '['
expect_fail "assert_not_grep fails on an invalid regex" "grep error" assert_not_grep "$tmp/f" '['
expect_fail "assert_exit fails on a wrong exit code" "got exit 4" assert_exit 3 bash -c 'exit 4'
assert_eq $'error: x\nFAILED=0' "$(probe assert_exit 1 die x)" "assert_exit survives a command that exits"
( summary_add Pre OK; summary_print ) > "$tmp/s"
assert_grep "$tmp/s" '^Pre  *OK$'
assert_not_grep "$tmp/s" ' $'
exit "${FAILED:-0}"
