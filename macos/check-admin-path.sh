#!/bin/bash

set -euo pipefail

PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export PATH
export LANG=C
export LC_ALL=C

fail() {
  printf 'check-admin-path: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: %s [--connect] mealcheck-server|mealcheck-server-cf\n' "$0" >&2
  exit 64
}

CONNECT=0
case "$#:${1:-}" in
  1:mealcheck-server|1:mealcheck-server-cf)
    REMOTE_HOST=$1
    ;;
  2:--connect)
    REMOTE_HOST=$2
    CONNECT=1
    ;;
  *) usage ;;
esac

case "$REMOTE_HOST" in
  mealcheck-server|mealcheck-server-cf) ;;
  *) fail "unsupported administration alias: $REMOTE_HOST" ;;
esac

SSH_BIN=${ADMIN_PATH_SSH_BIN:-}
if [ -z "$SSH_BIN" ]; then
  SSH_BIN=$(command -v ssh) || fail "ssh is unavailable"
fi
[ -x "$SSH_BIN" ] || fail "SSH executable is unavailable"

effective=$("$SSH_BIN" -G -T "$REMOTE_HOST") || fail "cannot resolve SSH configuration for $REMOTE_HOST"
hostname=$(printf '%s\n' "$effective" | /usr/bin/awk '$1 == "hostname" {print $2; exit}')
user=$(printf '%s\n' "$effective" | /usr/bin/awk '$1 == "user" {print $2; exit}')
host_key_alias=$(printf '%s\n' "$effective" | /usr/bin/awk '$1 == "hostkeyalias" {print $2; exit}')

[ -n "$hostname" ] || fail "effective SSH hostname is empty"
[ -n "$user" ] || fail "effective SSH user is empty"
[ -n "$host_key_alias" ] || fail "effective SSH configuration lacks HostKeyAlias"

printf 'Selected administration alias: %s\n' "$REMOTE_HOST"
printf 'Effective host: %s; trusted host-key alias: %s\n' "$hostname" "$host_key_alias"

if [ "$CONNECT" -eq 0 ]; then
  printf 'Configuration-only check passed; no network connection was attempted.\n'
  exit 0
fi

printf 'Starting read-only remote checks; no fallback alias will be attempted.\n'
"$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=20 "$REMOTE_HOST" /bin/bash -s <<'REMOTE'
set -euo pipefail

for service in \
  system/com.tailscale.tailscaled \
  system/dev.mealcheck.tunnel \
  system/dev.mealcheck.server \
  system/dev.mealcheck.label-review; do
  /bin/launchctl print "$service" >/dev/null
  printf 'ok service %s\n' "$service"
done

/usr/local/bin/tailscale status --json | /usr/bin/python3 -c '
import json
import sys

value = json.load(sys.stdin)
self_node = value.get("Self") or {}
if value.get("BackendState") != "Running" or not self_node.get("Online"):
    raise SystemExit("system Tailscale node is not online")
if self_node.get("Tags") != ["tag:web-server"]:
    raise SystemExit("unexpected system Tailscale tags")
'

/usr/local/bin/tailscale debug prefs | /usr/bin/python3 -c '
import json
import sys

if json.load(sys.stdin).get("RunSSH"):
    raise SystemExit("Tailscale SSH must remain disabled")
'

/usr/bin/curl -fsS --connect-timeout 5 --max-time 10 \
  http://127.0.0.1:8080/api/health >/dev/null
/usr/bin/curl -fsS --connect-timeout 5 --max-time 10 \
  http://127.0.0.1:8081/healthz >/dev/null
/usr/bin/curl -fsS --connect-timeout 5 --max-time 10 \
  http://127.0.0.1:8081/readyz >/dev/null
printf 'ok local application health\n'
REMOTE

printf 'Read-only administration-path check passed through %s.\n' "$REMOTE_HOST"
