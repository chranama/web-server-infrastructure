#!/bin/bash

set -euo pipefail

PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
export LANG=C
export LC_ALL=C

fail() {
  printf 'verify-tailscaled-system: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: sudo %s EXPECTED_VERSION EXPECTED_HOSTNAME EXPECTED_PEER\n' "$0" >&2
  exit 64
}

[ "$#" -eq 3 ] || usage
EXPECTED_VERSION=$1
EXPECTED_HOSTNAME=$2
EXPECTED_PEER=$3
LABEL="com.tailscale.tailscaled"
CLI="/usr/local/bin/tailscale"
DAEMON="/usr/local/bin/tailscaled"
SOCKET="/var/run/tailscaled.socket"

[ "$(/usr/bin/id -u)" -eq 0 ] || fail "run as root"
[ -x "$CLI" ] && [ -x "$DAEMON" ] || fail "system binaries are unavailable"
[ -S "$SOCKET" ] || fail "system daemon socket is unavailable"
[ "$("$CLI" version | /usr/bin/awk 'NR == 1 {print $1}')" = "$EXPECTED_VERSION" ] || fail "CLI version mismatch"

pid=$(/bin/launchctl print "system/$LABEL" 2>/dev/null | /usr/bin/awk '$1 == "pid" {print $3; exit}')
case "$pid" in
  ''|*[!0-9]*) fail "system daemon does not have a numeric pid" ;;
esac
[ "$(/bin/ps -o user= -p "$pid" | /usr/bin/xargs)" = "root" ] || fail "system daemon is not root-owned"
command=$(/bin/ps -o command= -p "$pid")
case "$command" in
  *"$DAEMON --state=/Library/Tailscale/tailscaled.state --statedir=/Library/Tailscale --socket=$SOCKET"*) ;;
  *) fail "system daemon command mismatch" ;;
esac

status=$(/usr/local/bin/tailscale status --json)
printf '%s' "$status" | /usr/bin/python3 -c '
import json
import sys
expected = sys.argv[1]
value = json.load(sys.stdin)
self_node = value.get("Self") or {}
if value.get("BackendState") != "Running":
    raise SystemExit("backend is not running")
if not self_node.get("Online"):
    raise SystemExit("node is not online")
if self_node.get("HostName") != expected:
    raise SystemExit("hostname mismatch")
if not value.get("TailscaleIPs"):
    raise SystemExit("node has no Tailscale address")
' "$EXPECTED_HOSTNAME"

prefs=$(/usr/local/bin/tailscale debug prefs)
printf '%s' "$prefs" | /usr/bin/python3 -c '
import json
import sys
if json.load(sys.stdin).get("RunSSH"):
    raise SystemExit("Tailscale SSH must remain disabled")
'

/usr/local/bin/tailscale ping --timeout=10s "$EXPECTED_PEER" >/dev/null
printf 'verify-tailscaled-system: system node, standard SSH boundary, and peer reachability passed\n'
