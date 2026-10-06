#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); source "$here/helpers.sh"; source "$here/../../../linux/lib.sh"
inst=$here/../../../linux/install.sh; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
assert_exit 0 "$inst" --help
assert_exit 2 "$inst" --bogus
assert_exit 2 "$inst" --listen 9182 --no-services --root "$tmp/r"
assert_exit 2 "$inst" --listen :9182 --no-services --root "$tmp/r"
assert_exit 1 "$inst" --no-services --root "$tmp/with space"
mkdir -p "$tmp/noconfig"; cp "$here/../../../StorSafe.config.example.json" "$tmp/noconfig/"
out=$("$inst" --no-services --root "$tmp/noconfig/" --user "$(id -un)" 2>&1 || true)
assert_file "$tmp/noconfig/StorSafe.config.json"
echo "$out" | grep -q 'edit the Servers list' || { echo "FAIL config hint"; FAILED=1; }
echo "$out" | grep -q "$tmp/noconfig//" && { echo "FAIL double slash in root"; FAILED=1; }
out=$(cd "$tmp" && "$inst" --no-services --root noconfig --user "$(id -un)" 2>&1 || true)
echo "$out" | grep -q "$tmp/noconfig" || { echo "FAIL relative root not made absolute"; FAILED=1; }
# broken pwsh: a fake that exits 1 must stop the installer with the package hint
mkdir -p "$tmp/bin"; printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/pwsh"; chmod +x "$tmp/bin/pwsh"
printf 'ID=rocky\nID_LIKE=rhel\n' > "$tmp/os"
out=$(PATH="$tmp/bin:$PATH" OS_RELEASE_FILE=$tmp/os "$inst" --no-services --root "$tmp/noconfig" --user "$(id -un)" 2>&1 || true)
echo "$out" | grep -q 'dnf install libicu' || { echo "FAIL icu hint"; FAILED=1; }
# every option is in the usage text, with its default where it has one
usage=$("$inst" --help)
for opt in --root --user --interval-minutes --retention-days --collector-only --listen --skip-credentials --no-services --unit-dir --uninstall; do
  echo "$usage" | grep -q -- "$opt" || { echo "FAIL usage lacks $opt"; FAILED=1; }
done
echo "$usage" | grep -q '/opt/storsafe-monitoring' || { echo "FAIL usage lacks the default root"; FAILED=1; }
# a missing value or a value out of range is a usage error, not a run
assert_exit 2 "$inst" --root
assert_exit 2 "$inst" --user --no-services
assert_exit 2 "$inst" --interval-minutes 0 --no-services --root "$tmp/r"
assert_exit 2 "$inst" --interval-minutes 61 --no-services --root "$tmp/r"
assert_exit 2 "$inst" --interval-minutes 5x --no-services --root "$tmp/r"
assert_exit 2 "$inst" --retention-days 0 --no-services --root "$tmp/r"
assert_exit 2 "$inst" --retention-days 3651 --no-services --root "$tmp/r"
assert_exit 2 "$inst" --listen 127.0.0.1:99999 --no-services --root "$tmp/r"
# a folder that is not the package is refused before anything is changed
mkdir -p "$tmp/empty"
out=$("$inst" --no-services --root "$tmp/empty" --user "$(id -un)" 2>&1 || true)
echo "$out" | grep -q 'does not contain the package' || { echo "FAIL package hint"; FAILED=1; }
assert_exit 1 "$inst" --no-services --root "$tmp/empty" --user "$(id -un)"
# no pwsh and no tarball: the summary says what to download, and the installer stops
mkdir -p "$tmp/minbin"
for t in bash dirname realpath uname curl tar gzip sort tail id mkdir chown chmod cp ln; do
  p=$(command -v "$t" || true); if [[ -n $p ]]; then ln -sf "$p" "$tmp/minbin/$t"; fi
done
out=$(PATH=$tmp/minbin "$inst" --no-services --root "$tmp/noconfig" --user "$(id -un)" 2>&1 || true)
echo "$out" | grep -Eq '^PowerShell +Missing installer +put powershell-<ver>-linux-x64.tar.gz in installers/ and re-run$' || { echo "FAIL missing pwsh row"; FAILED=1; }
assert_exit 1 env PATH="$tmp/minbin" "$inst" --no-services --root "$tmp/noconfig" --user "$(id -un)"
# a working pwsh and a config: every step reports OK, the folders exist, creds is 0700, exit 0
mkdir -p "$tmp/okbin" "$tmp/ok"; printf '#!/bin/sh\necho "PowerShell 7.4.6"\n' > "$tmp/okbin/pwsh"; chmod +x "$tmp/okbin/pwsh"
cp "$here/../../../StorSafe.config.example.json" "$tmp/ok/"; cp "$tmp/ok/StorSafe.config.example.json" "$tmp/ok/StorSafe.config.json"
out=$(PATH="$tmp/okbin:$PATH" OS_RELEASE_FILE=$tmp/os "$inst" --no-services --root "$tmp/ok" --user "$(id -un)" 2>&1) || { echo "FAIL full run exit"; FAILED=1; }
echo "$out" | grep -q "^Install folder: $tmp/ok\$" || { echo "FAIL install folder line"; FAILED=1; }
echo "$out" | grep -Eq '^Preconditions +OK +rhel, x86_64$' || { echo "FAIL preconditions row"; FAILED=1; }
echo "$out" | grep -Eq "^PowerShell +OK +$tmp/okbin/pwsh 7\.4\.6\$" || { echo "FAIL powershell row"; FAILED=1; }
echo "$out" | grep -Eq "^User +OK +$(id -un)\$" || { echo "FAIL user row"; FAILED=1; }
echo "$out" | grep -Eq "^Config +OK +$tmp/ok/StorSafe.config.json\$" || { echo "FAIL config row"; FAILED=1; }
for d in creds state events metrics reports; do [ -d "$tmp/ok/$d" ] || { echo "FAIL folder $d"; FAILED=1; }; done
assert_eq 700 "$(stat -c %a "$tmp/ok/creds")" "creds mode"
exit "${FAILED:-0}"
