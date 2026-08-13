#!/bin/bash

set -euo pipefail

PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
export LANG=C
export LC_ALL=C
umask 077

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
VALIDATOR="$SCRIPT_DIR/validate-tailscaled-candidate.sh"
LABEL="com.tailscale.tailscaled"
PLIST_TARGET="/Library/LaunchDaemons/$LABEL.plist"
CLI_TARGET="/usr/local/bin/tailscale"
DAEMON_TARGET="/usr/local/bin/tailscaled"
STATE_DIR="/Library/Tailscale"
LOG_DIR="/Library/Logs/Tailscale"
SOCKET="/var/run/tailscaled.socket"
LOCK_DIR="/tmp/com.tailscale.tailscaled.install.lock"

fail() {
  printf 'install-tailscaled-system: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: sudo install-tailscaled-system.sh \
  --apply --confirm-cloudflare-recovery --confirm-gui-stopped \
  CANDIDATE_ROOT EXPECTED_OWNER VERSION CLI_SHA256 DAEMON_SHA256 BACKUP_ROOT
EOF
  exit 64
}

[ "$#" -eq 9 ] || usage
[ "$1" = "--apply" ] || usage
[ "$2" = "--confirm-cloudflare-recovery" ] || usage
[ "$3" = "--confirm-gui-stopped" ] || usage
CANDIDATE_ROOT=$4
EXPECTED_OWNER=$5
EXPECTED_VERSION=$6
CLI_SHA256=$7
DAEMON_SHA256=$8
BACKUP_ROOT=$9

[ "$(/usr/bin/id -u)" -eq 0 ] || fail "run as root"
[ -x "$VALIDATOR" ] || fail "candidate validator is unavailable"
"$VALIDATOR" "$CANDIDATE_ROOT" "$EXPECTED_OWNER" "$EXPECTED_VERSION" "$CLI_SHA256" "$DAEMON_SHA256"

if /usr/bin/pgrep -f '^/Applications/Tailscale.app/Contents/MacOS/Tailscale($| )' >/dev/null; then
  fail "GUI Tailscale process is still active"
fi
if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
  fail "system tailscaled service already exists"
fi
if [ -e "$STATE_DIR/tailscaled.state" ]; then
  fail "system tailscaled state already exists"
fi
if ! /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
  fail "another system tailscaled installation is in progress"
fi

STAMP=$(/bin/date -u +%Y%m%dT%H%M%SZ)
BACKUP_DIR="$BACKUP_ROOT/$STAMP"
installed=0
completed=0

backup_target() {
  target=$1
  name=$2
  if [ -e "$target" ]; then
    [ -f "$target" ] && [ ! -L "$target" ] || fail "unsafe existing $name target"
    /bin/cp -p "$target" "$BACKUP_DIR/$name"
  else
    : > "$BACKUP_DIR/$name.absent"
  fi
}

restore_target() {
  target=$1
  name=$2
  mode=$3
  if [ -f "$BACKUP_DIR/$name" ]; then
    /usr/bin/install -o root -g wheel -m "$mode" "$BACKUP_DIR/$name" "$target"
  else
    /bin/rm -f -- "$target"
  fi
}

rollback() {
  status=$?
  trap - EXIT INT TERM
  set +e
  if [ "$status" -ne 0 ] && [ "$installed" -eq 1 ] && [ "$completed" -eq 0 ]; then
    printf 'install-tailscaled-system: activation failed; restoring prior files\n' >&2
    /bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
    restore_target "$CLI_TARGET" tailscale 755
    restore_target "$DAEMON_TARGET" tailscaled 755
    restore_target "$PLIST_TARGET" launchdaemon.plist 644
    if [ -f "$STATE_DIR/tailscaled.state" ]; then
      /bin/mv "$STATE_DIR/tailscaled.state" "$BACKUP_DIR/tailscaled.state.failed"
      /bin/chmod 600 "$BACKUP_DIR/tailscaled.state.failed"
    fi
    /bin/rm -f -- "$SOCKET"
  fi
  /bin/rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
  exit "$status"
}
trap rollback EXIT INT TERM

/bin/mkdir -p "$BACKUP_DIR" "$STATE_DIR" "$LOG_DIR"
/bin/chmod 700 "$BACKUP_ROOT" "$BACKUP_DIR" "$STATE_DIR"
/bin/chmod 750 "$LOG_DIR"
/usr/sbin/chown root:wheel "$BACKUP_ROOT" "$BACKUP_DIR" "$STATE_DIR" "$LOG_DIR"

backup_target "$CLI_TARGET" tailscale
backup_target "$DAEMON_TARGET" tailscaled
backup_target "$PLIST_TARGET" launchdaemon.plist

/usr/bin/install -o root -g wheel -m 755 "$CANDIDATE_ROOT/tailscale" "$CLI_TARGET"
/usr/bin/install -o root -g wheel -m 755 "$CANDIDATE_ROOT/tailscaled" "$DAEMON_TARGET"
/usr/bin/install -o root -g wheel -m 644 "$CANDIDATE_ROOT/com.tailscale.tailscaled.plist" "$PLIST_TARGET"
/usr/bin/touch "$LOG_DIR/tailscaled.out.log" "$LOG_DIR/tailscaled.err.log"
/usr/sbin/chown root:wheel "$LOG_DIR/tailscaled.out.log" "$LOG_DIR/tailscaled.err.log"
/bin/chmod 640 "$LOG_DIR/tailscaled.out.log" "$LOG_DIR/tailscaled.err.log"
/usr/bin/plutil -lint "$PLIST_TARGET" >/dev/null
installed=1

/bin/launchctl bootstrap system "$PLIST_TARGET"
/bin/launchctl kickstart -k "system/$LABEL"

attempt=0
pid=""
while [ "$attempt" -lt 30 ]; do
  pid=$(/bin/launchctl print "system/$LABEL" 2>/dev/null | /usr/bin/awk '$1 == "pid" {print $3; exit}')
  if [ -n "$pid" ] && [ -S "$SOCKET" ] && /bin/kill -0 "$pid" 2>/dev/null; then
    break
  fi
  attempt=$((attempt + 1))
  /bin/sleep 1
done
[ -n "$pid" ] && [ -S "$SOCKET" ] || fail "system tailscaled did not become ready"

owner=$(/bin/ps -o user= -p "$pid" | /usr/bin/xargs)
[ "$owner" = "root" ] || fail "system tailscaled process is not root-owned"
command=$(/bin/ps -o command= -p "$pid")
case "$command" in
  *"$DAEMON_TARGET --state=$STATE_DIR/tailscaled.state --statedir=$STATE_DIR --socket=$SOCKET"*) ;;
  *) fail "system tailscaled command does not match the reviewed contract" ;;
esac

completed=1
printf 'install-tailscaled-system: system daemon installed; rollback copy: %s\n' "$BACKUP_DIR"
