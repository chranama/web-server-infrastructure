#!/bin/bash

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEMPLATE="$ROOT/macos/cloudflared-launchdaemon.plist.template"
WORK_FILE=$(/usr/bin/mktemp /tmp/cloudflared-launchdaemon.XXXXXX.plist)

cleanup() {
  /bin/rm -f -- "$WORK_FILE"
}
trap cleanup EXIT INT TERM

/usr/bin/sed \
  -e 's|__SERVICE_LABEL__|dev.example.tunnel|g' \
  -e 's|__SERVICE_USER__|example-server|g' \
  -e 's|__CLOUDFLARED_BIN__|/usr/local/bin/cloudflared|g' \
  -e 's|__ACTIVE_CONFIG__|/Users/example-server/.cloudflared/example-tunnel.yml|g' \
  -e 's|__TUNNEL_NAME__|example-tunnel|g' \
  -e 's|__RUNTIME_ROOT__|/Users/example-server/web-server-infrastructure-runtime|g' \
  "$TEMPLATE" > "$WORK_FILE"

if /usr/bin/grep -Eq '__[A-Z0-9_]+__' "$WORK_FILE"; then
  printf 'test-plist-template: unresolved placeholder\n' >&2
  exit 1
fi

/usr/bin/plutil -lint "$WORK_FILE"
printf 'test-plist-template: rendered launchd template passed\n'

