#!/bin/bash

set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
export LANG=C
export LC_ALL=C

fail() {
  printf 'validate-tailscaled-candidate: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: %s CANDIDATE_ROOT EXPECTED_OWNER VERSION CLI_SHA256 DAEMON_SHA256\n' "$0" >&2
  exit 64
}

[ "$#" -eq 5 ] || usage

CANDIDATE_ROOT=$1
EXPECTED_OWNER=$2
EXPECTED_VERSION=$3
CLI_SHA256=$4
DAEMON_SHA256=$5
CLI="$CANDIDATE_ROOT/tailscale"
DAEMON="$CANDIDATE_ROOT/tailscaled"
PLIST="$CANDIDATE_ROOT/com.tailscale.tailscaled.plist"

case "$EXPECTED_OWNER" in
  ''|*[!A-Za-z0-9._-]*) fail "invalid expected owner" ;;
esac
case "$EXPECTED_VERSION" in
  ''|*[!0-9.]*) fail "invalid expected version" ;;
esac
printf '%s\n%s\n' "$CLI_SHA256" "$DAEMON_SHA256" |
  /usr/bin/grep -Eqv '^[0-9a-f]{64}$' && fail "invalid expected SHA-256" || true

[ -d "$CANDIDATE_ROOT" ] && [ ! -L "$CANDIDATE_ROOT" ] || fail "unsafe candidate root"
[ "$(/usr/bin/stat -f '%OLp' "$CANDIDATE_ROOT")" = "700" ] || fail "candidate root must have mode 700"
[ "$(/usr/bin/stat -f '%Su' "$CANDIDATE_ROOT")" = "$EXPECTED_OWNER" ] || fail "candidate root owner mismatch"

for file in "$CLI" "$DAEMON"; do
  [ -f "$file" ] && [ ! -L "$file" ] && [ -x "$file" ] || fail "unsafe candidate binary"
  [ "$(/usr/bin/stat -f '%OLp' "$file")" = "700" ] || fail "candidate binaries must have mode 700"
  [ "$(/usr/bin/stat -f '%Su' "$file")" = "$EXPECTED_OWNER" ] || fail "candidate binary owner mismatch"
done

[ -f "$PLIST" ] && [ ! -L "$PLIST" ] || fail "unsafe candidate plist"
[ "$(/usr/bin/stat -f '%OLp' "$PLIST")" = "600" ] || fail "candidate plist must have mode 600"
[ "$(/usr/bin/stat -f '%Su' "$PLIST")" = "$EXPECTED_OWNER" ] || fail "candidate plist owner mismatch"

[ "$(/usr/bin/shasum -a 256 "$CLI" | /usr/bin/awk '{print $1}')" = "$CLI_SHA256" ] || fail "tailscale checksum mismatch"
[ "$(/usr/bin/shasum -a 256 "$DAEMON" | /usr/bin/awk '{print $1}')" = "$DAEMON_SHA256" ] || fail "tailscaled checksum mismatch"

[ "$("$CLI" version | /usr/bin/awk 'NR == 1 {print $1}')" = "$EXPECTED_VERSION" ] || fail "tailscale version mismatch"
[ "$("$DAEMON" --version | /usr/bin/awk 'NR == 1 {print $1}')" = "$EXPECTED_VERSION" ] || fail "tailscaled version mismatch"

/usr/bin/plutil -lint "$PLIST" >/dev/null
if /usr/bin/grep -Eq '__[A-Z0-9_]+__|tskey-auth-' "$PLIST"; then
  fail "candidate plist contains a placeholder or bootstrap credential"
fi

/usr/bin/python3 - "$PLIST" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    value = plistlib.load(stream)

checks = {
    "Label": "com.tailscale.tailscaled",
    "ProgramArguments": [
        "/usr/local/bin/tailscaled",
        "--state=/Library/Tailscale/tailscaled.state",
        "--statedir=/Library/Tailscale",
        "--socket=/var/run/tailscaled.socket",
    ],
    "WorkingDirectory": "/Library/Tailscale",
    "RunAtLoad": True,
    "KeepAlive": True,
    "StandardOutPath": "/Library/Logs/Tailscale/tailscaled.out.log",
    "StandardErrorPath": "/Library/Logs/Tailscale/tailscaled.err.log",
    "ProcessType": "Background",
}
for key, expected in checks.items():
    if value.get(key) != expected:
        raise SystemExit(f"unexpected {key}")
if "UserName" in value:
    raise SystemExit("system daemon must not declare a user-scoped identity")
PY

printf 'validate-tailscaled-candidate: pinned system daemon candidate passed\n'
