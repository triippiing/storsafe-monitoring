#!/usr/bin/env bash
# Assertion helpers for the Linux installer tests. Source this file from a test_*.sh script.
# A failed assertion prints "FAIL <label>" (with a detail line) and sets FAILED=1; the test file
# ends with: exit "$FAILED". The helpers never exit on their own, so one run reports every failure.

# Read by the sourcing test file, which ends with exit "$FAILED".
# shellcheck disable=SC2034
FAILED=0

# Records a failed assertion: the label line, then an indented detail line when one is given.
assert_fail() {
    echo "FAIL $1"
    if [[ -n ${2:-} ]]; then
        echo "    $2"
    fi
    FAILED=1
}

# assert_eq expected actual [label]: the two strings must be identical.
assert_eq() {
    local expected=$1 actual=$2 label=${3:-assert_eq}
    if [[ $actual != "$expected" ]]; then
        assert_fail "$label" "expected '$expected', got '$actual'"
    fi
}

# assert_file path: the path must be an existing regular file.
assert_file() {
    if [[ ! -f $1 ]]; then
        assert_fail "file exists: $1"
    fi
}

# assert_grep file pattern: a line of the file must match the pattern (grep basic regex).
# A "--" before the pattern is accepted, for patterns that start with a dash.
assert_grep() {
    local file=$1 rc=0
    shift
    if [[ ${1:-} == -- ]]; then
        shift
    fi
    if [[ ! -r $file ]]; then
        assert_fail "$file matches $1" "cannot read $file"
        return 0
    fi
    grep -q -- "$1" "$file" || rc=$?
    if [[ $rc -ne 0 ]]; then
        assert_fail "$file matches $1"
    fi
}

# assert_not_grep file pattern: no line of the file may match the pattern. The file must exist.
assert_not_grep() {
    local file=$1 rc=0
    shift
    if [[ ${1:-} == -- ]]; then
        shift
    fi
    if [[ ! -r $file ]]; then
        assert_fail "$file does not match $1" "cannot read $file"
        return 0
    fi
    grep -q -- "$1" "$file" || rc=$?
    if [[ $rc -eq 0 ]]; then
        assert_fail "$file does not match $1" "a line matches"
    fi
}

# assert_exit code cmd...: runs the command and compares its exit code with the expected one.
assert_exit() {
    local want=$1 rc=0
    shift
    "$@" || rc=$?
    if [[ $rc -ne $want ]]; then
        assert_fail "exit $want from: $*" "got exit $rc"
    fi
}

# make_fake_tarballs <dir>: placeholder, Task 6 fills in the fake release tarballs.
make_fake_tarballs() {
    mkdir -p "$1"
    return 0
}

# make_systemctl_shim <dir>: placeholder, Task 7 fills in the systemctl stand-in.
make_systemctl_shim() {
    mkdir -p "$1"
    return 0
}
