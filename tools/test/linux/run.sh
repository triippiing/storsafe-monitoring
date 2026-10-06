#!/usr/bin/env bash
# Runs every test_*.sh next to this script with bash and prints PASS/FAIL per file, then a total.
# The output of a passing test is hidden; a failing test's output is shown under its FAIL line.
# Exit status is 1 when any test failed.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
passed=0
failed=0

for t in "$here"/test_*.sh; do
    # An unmatched glob stays literal: nothing to run.
    [[ -e $t ]] || continue
    name=$(basename "$t")
    out=$(mktemp)
    if bash "$t" > "$out" 2>&1; then
        echo "PASS $name"
        passed=$((passed + 1))
    else
        echo "FAIL $name"
        sed 's/^/    /' "$out"
        failed=$((failed + 1))
    fi
    rm -f "$out"
done

echo "$passed passed, $failed failed"
if [[ $failed -gt 0 ]]; then
    exit 1
fi
