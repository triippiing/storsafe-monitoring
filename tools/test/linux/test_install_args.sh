#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); source "$here/helpers.sh"; source "$here/../../../linux/lib.sh"
inst=$here/../../../linux/install.sh; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# quiet cmd...: runs the command with its output discarded, so a passing run prints nothing
# shellcheck disable=SC2329 # called through assert_exit
quiet() { "$@" > /dev/null 2>&1; }
assert_exit 0 quiet "$inst" --help
assert_exit 2 quiet "$inst" --bogus
assert_exit 2 quiet "$inst" --listen 9182 --no-services --root "$tmp/r"
assert_exit 2 quiet "$inst" --listen :9182 --no-services --root "$tmp/r"
assert_exit 1 quiet "$inst" --no-services --root "$tmp/with space"
# the refusal is for the space: a root that does not exist would also exit 1, with another message
out=$("$inst" --no-services --root "$tmp/with space" 2>&1 || true)
echo "$out" | grep -q 'contains a space' || { echo "FAIL space message"; FAILED=1; }
mkdir -p "$tmp/noconfig"; cp "$here/../../../StorSafe.config.example.json" "$tmp/noconfig/"
out=$(umask 077; "$inst" --no-services --root "$tmp/noconfig/" --user "$(id -un)" 2>&1 || true)
assert_file "$tmp/noconfig/StorSafe.config.json"
assert_eq 644 "$(stat -c %a "$tmp/noconfig/StorSafe.config.json")" "the new config is readable by the service account, whatever umask root has"
echo "$out" | grep -q 'edit the Servers list' || { echo "FAIL config hint"; FAILED=1; }
echo "$out" | grep -q "$tmp/noconfig//" && { echo "FAIL double slash in root"; FAILED=1; }
out=$(cd "$tmp" && "$inst" --no-services --root noconfig --user "$(id -un)" 2>&1 || true)
echo "$out" | grep -q "$tmp/noconfig" || { echo "FAIL relative root not made absolute"; FAILED=1; }
# broken pwsh: a fake that exits 1 must stop the installer with the package hint
mkdir -p "$tmp/bin"; printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/pwsh"; chmod +x "$tmp/bin/pwsh"
printf 'ID=rocky\nID_LIKE=rhel\n' > "$tmp/os"
out=$(PATH="$tmp/bin:$PATH" OS_RELEASE_FILE=$tmp/os "$inst" --no-services --root "$tmp/noconfig" --user "$(id -un)" 2>&1 || true)
echo "$out" | grep -q 'dnf install libicu' || { echo "FAIL icu hint"; FAILED=1; }
# the Debian family names the package after the release: the hint gives two names and the command that finds the right one
printf 'ID=ubuntu\nID_LIKE=debian\n' > "$tmp/os2"
out=$(PATH="$tmp/bin:$PATH" OS_RELEASE_FILE=$tmp/os2 "$inst" --no-services --root "$tmp/noconfig" --user "$(id -un)" 2>&1 || true)
echo "$out" | grep -q 'apt-get install libicu72 (Debian 12) or libicu74 (Ubuntu 24.04)' || { echo "FAIL debian icu names"; FAILED=1; }
echo "$out" | grep -qF "apt-cache search --names-only '^libicu[0-9]+\$'" || { echo "FAIL debian icu search command"; FAILED=1; }
# every option is in the usage text, with its default where it has one
usage=$("$inst" --help)
for opt in --root --user --interval-minutes --retention-days --collector-only --listen --skip-credentials --no-services --unit-dir --uninstall; do
  echo "$usage" | grep -q -- "$opt" || { echo "FAIL usage lacks $opt"; FAILED=1; }
done
echo "$usage" | grep -q '/opt/storsafe-monitoring' || { echo "FAIL usage lacks the default root"; FAILED=1; }
# a missing value or a value out of range is a usage error, not a run
assert_exit 2 quiet "$inst" --root
assert_exit 2 quiet "$inst" --user --no-services
assert_exit 2 quiet "$inst" --interval-minutes 0 --no-services --root "$tmp/r"
assert_exit 2 quiet "$inst" --interval-minutes 61 --no-services --root "$tmp/r"
assert_exit 2 quiet "$inst" --interval-minutes 5x --no-services --root "$tmp/r"
assert_exit 2 quiet "$inst" --retention-days 0 --no-services --root "$tmp/r"
assert_exit 2 quiet "$inst" --retention-days 3651 --no-services --root "$tmp/r"
assert_exit 2 quiet "$inst" --listen 127.0.0.1:99999 --no-services --root "$tmp/r"
assert_exit 2 quiet "$inst" --listen 127.0.0.1:09182 --no-services --root "$tmp/r"
assert_exit 2 quiet "$inst" --listen 127.0.0.1:0 --no-services --root "$tmp/r"
# a folder that is not the package is refused before anything is changed
mkdir -p "$tmp/empty"
out=$("$inst" --no-services --root "$tmp/empty" --user "$(id -un)" 2>&1 || true)
echo "$out" | grep -q 'does not contain the package' || { echo "FAIL package hint"; FAILED=1; }
assert_exit 1 quiet "$inst" --no-services --root "$tmp/empty" --user "$(id -un)"
# no pwsh and no tarball: the summary says what to download, and the installer stops
mkdir -p "$tmp/minbin"
for t in bash dirname realpath uname curl tar gzip sort tail id mkdir chown chmod cp ln; do
  p=$(command -v "$t" || true); if [[ -n $p ]]; then ln -sf "$p" "$tmp/minbin/$t"; fi
done
out=$(PATH=$tmp/minbin "$inst" --no-services --root "$tmp/noconfig" --user "$(id -un)" 2>&1 || true)
echo "$out" | grep -Eq '^PowerShell +Missing installer +put powershell-<ver>-linux-x64.tar.gz in installers/ and re-run$' || { echo "FAIL missing pwsh row"; FAILED=1; }
assert_exit 1 quiet env PATH="$tmp/minbin" "$inst" --no-services --root "$tmp/noconfig" --user "$(id -un)"
# a working pwsh and a config: every step up to Config reports OK, the folders exist, creds is 0700.
# The stub pwsh writes no metrics file, so the installer stops at the collector test run (exit 1).
mkdir -p "$tmp/okbin" "$tmp/ok"; printf '#!/bin/sh\necho "PowerShell 7.4.6"\n' > "$tmp/okbin/pwsh"; chmod +x "$tmp/okbin/pwsh"
cp "$here/../../../StorSafe.config.example.json" "$tmp/ok/"; cp "$tmp/ok/StorSafe.config.example.json" "$tmp/ok/StorSafe.config.json"
rc=0; out=$(PATH="$tmp/okbin:$PATH" OS_RELEASE_FILE=$tmp/os "$inst" --no-services --root "$tmp/ok" --user "$(id -un)" --skip-credentials 2>&1) || rc=$?
assert_eq 1 "$rc" "full run stops at the collector test"
echo "$out" | grep -Eq '^Collector test +Check +config error; see the output above$' || { echo "FAIL collector test row"; FAILED=1; }
echo "$out" | grep -q "^Install folder: $tmp/ok\$" || { echo "FAIL install folder line"; FAILED=1; }
echo "$out" | grep -Eq '^Preconditions +OK +rhel, x86_64$' || { echo "FAIL preconditions row"; FAILED=1; }
echo "$out" | grep -Eq "^PowerShell +OK +$tmp/okbin/pwsh 7\.4\.6\$" || { echo "FAIL powershell row"; FAILED=1; }
echo "$out" | grep -Eq "^User +OK +$(id -un)\$" || { echo "FAIL user row"; FAILED=1; }
echo "$out" | grep -Eq "^Config +OK +$tmp/ok/StorSafe.config.json\$" || { echo "FAIL config row"; FAILED=1; }
for d in creds state events metrics reports; do [ -d "$tmp/ok/$d" ] || { echo "FAIL folder $d"; FAILED=1; }; done
assert_eq 700 "$(stat -c %a "$tmp/ok/creds")" "creds mode"
exit "${FAILED:-0}"
