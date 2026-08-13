#!/bin/bash

set -euo pipefail

PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
export LANG=C
export LC_ALL=C
umask 077

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
INSTALLER="$SCRIPT_DIR/install-tailscaled-system.sh"
LABEL="com.tailscale.tailscaled"
PLIST_TARGET="/Library/LaunchDaemons/$LABEL.plist"
CLI_TARGET="/usr/local/bin/tailscale"
DAEMON_TARGET="/usr/local/bin/tailscaled"
STATE_FILE="/Library/Tailscale/tailscaled.state"
SOCKET="/var/run/tailscaled.socket"
GUI_EXECUTABLE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
LOGIN_HELPER="io.tailscale.ipn.macsys.login-item-helper"

fail() {
  printf 'cutover-tailscaled-system: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: sudo cutover-tailscaled-system.sh \
  --apply --confirm-cloudflare-recovery \
  CANDIDATE_ROOT EXPECTED_OWNER VERSION CLI_SHA256 DAEMON_SHA256 \
  BACKUP_ROOT AUTH_KEY_FILE HOSTNAME PEER
EOF
  exit 64
}

[ "$#" -eq 11 ] || usage
[ "$1" = "--apply" ] || usage
[ "$2" = "--confirm-cloudflare-recovery" ] || usage
CANDIDATE_ROOT=$3
EXPECTED_OWNER=$4
EXPECTED_VERSION=$5
CLI_SHA256=$6
DAEMON_SHA256=$7
BACKUP_ROOT=$8
AUTH_KEY_FILE=$9
EXPECTED_HOSTNAME=${10}
EXPECTED_PEER=${11}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail "run as root"
[ -x "$INSTALLER" ] || fail "system installer is unavailable"
EXPECTED_UID=$(/usr/bin/id -u "$EXPECTED_OWNER")
[ "$(/usr/bin/stat -f %Su /dev/console)" = "$EXPECTED_OWNER" ] ||
  fail "expected operator is not the active console user"
[ -f "$AUTH_KEY_FILE" ] && [ ! -L "$AUTH_KEY_FILE" ] || fail "unsafe auth key file"
[ "$(/usr/bin/stat -f %Su "$AUTH_KEY_FILE")" = "$EXPECTED_OWNER" ] ||
  fail "auth key file owner mismatch"
[ "$(/usr/bin/stat -f %Lp "$AUTH_KEY_FILE")" = "600" ] || fail "auth key file mode must be 600"
[ "$(/usr/bin/stat -f %z "$AUTH_KEY_FILE")" -gt 20 ] || fail "auth key file is empty or invalid"

STAMP=$(/bin/date -u +%Y%m%dT%H%M%SZ)
CUTOVER_BACKUP_ROOT="$BACKUP_ROOT/cutover-$STAMP"
GUI_WAS_RUNNING=0
HELPER_WAS_DISABLED=0
SYSTEM_INSTALLED=0
COMPLETED=0
INSTALL_BACKUP=""

if /usr/bin/pgrep -u "$EXPECTED_UID" -f "^$GUI_EXECUTABLE($| )" >/dev/null; then
  GUI_WAS_RUNNING=1
fi
if /bin/launchctl print-disabled "gui/$EXPECTED_UID" 2>/dev/null |
  /usr/bin/grep -q "\"$LOGIN_HELPER\" => true"; then
  HELPER_WAS_DISABLED=1
fi

restore_target() {
  target=$1
  name=$2
  mode=$3
  if [ -f "$INSTALL_BACKUP/$name" ]; then
    /usr/bin/install -o root -g wheel -m "$mode" "$INSTALL_BACKUP/$name" "$target"
  elif [ -f "$INSTALL_BACKUP/$name.absent" ]; then
    /bin/rm -f -- "$target"
  fi
}

rollback() {
  status=$?
  trap - EXIT INT TERM
  set +e
  if [ "$status" -ne 0 ] && [ "$COMPLETED" -eq 0 ]; then
    printf 'cutover-tailscaled-system: cutover failed; restoring the prior GUI path\n' >&2
    if [ "$SYSTEM_INSTALLED" -eq 1 ]; then
      /bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
      if [ -n "$INSTALL_BACKUP" ]; then
        if [ -f "$STATE_FILE" ]; then
          /bin/mv "$STATE_FILE" "$INSTALL_BACKUP/tailscaled.state.failed"
          /bin/chmod 600 "$INSTALL_BACKUP/tailscaled.state.failed"
        fi
        restore_target "$CLI_TARGET" tailscale 755
        restore_target "$DAEMON_TARGET" tailscaled 755
        restore_target "$PLIST_TARGET" launchdaemon.plist 644
      fi
      /bin/rm -f -- "$SOCKET"
    fi
    if [ "$HELPER_WAS_DISABLED" -eq 0 ]; then
      /bin/launchctl enable "gui/$EXPECTED_UID/$LOGIN_HELPER" >/dev/null 2>&1 || true
    fi
    if [ "$GUI_WAS_RUNNING" -eq 1 ]; then
      /bin/launchctl asuser "$EXPECTED_UID" /usr/bin/open -a Tailscale >/dev/null 2>&1 || true
    fi
  fi
  exit "$status"
}
trap rollback EXIT INT TERM

printf 'cutover-tailscaled-system: stopping GUI Tailscale and disabling its login helper\n'
/bin/launchctl asuser "$EXPECTED_UID" /usr/bin/osascript \
  -e 'tell application "Tailscale" to quit' >/dev/null 2>&1 || true
attempt=0
while /usr/bin/pgrep -u "$EXPECTED_UID" -f "^$GUI_EXECUTABLE($| )" >/dev/null; do
  [ "$attempt" -lt 15 ] || fail "GUI Tailscale did not stop"
  attempt=$((attempt + 1))
  /bin/sleep 1
done
/bin/launchctl disable "gui/$EXPECTED_UID/$LOGIN_HELPER"
/bin/launchctl bootout "gui/$EXPECTED_UID/$LOGIN_HELPER" >/dev/null 2>&1 || true

"$INSTALLER" \
  --apply --confirm-cloudflare-recovery --confirm-gui-stopped \
  "$CANDIDATE_ROOT" "$EXPECTED_OWNER" "$EXPECTED_VERSION" \
  "$CLI_SHA256" "$DAEMON_SHA256" "$CUTOVER_BACKUP_ROOT"
SYSTEM_INSTALLED=1
INSTALL_BACKUP=$(/usr/bin/find "$CUTOVER_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -print)
[ -n "$INSTALL_BACKUP" ] && [ "$(printf '%s\n' "$INSTALL_BACKUP" | /usr/bin/wc -l)" -eq 1 ] ||
  fail "unable to identify the installation rollback directory"

printf 'cutover-tailscaled-system: enrolling the tagged system node\n'
"$CLI_TARGET" up \
  --auth-key="file:$AUTH_KEY_FILE" \
  --hostname="$EXPECTED_HOSTNAME" \
  --operator="$EXPECTED_OWNER" \
  --accept-dns=true \
  --accept-routes=false \
  --advertise-connector=false \
  --advertise-exit-node=false \
  --advertise-routes= \
  --advertise-tags=tag:web-server \
  --exit-node= \
  --exit-node-allow-lan-access=false \
  --report-posture=false \
  --shields-up=false \
  --ssh=false \
  --reset \
  --timeout=45s

"$SCRIPT_DIR/verify-tailscaled-system.sh" "$EXPECTED_VERSION" "$EXPECTED_HOSTNAME" "$EXPECTED_PEER"
/bin/rm -f -- "$AUTH_KEY_FILE"
COMPLETED=1
printf 'cutover-tailscaled-system: cutover passed; bootstrap key removed; rollback copy: %s\n' \
  "$INSTALL_BACKUP"
