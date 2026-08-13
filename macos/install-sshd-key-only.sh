#!/bin/bash

set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
export LANG=C
export LC_ALL=C
umask 077

usage() {
  printf 'usage: sudo %s <candidate> <target> <backup-root> <admin-user> <connection-host> <connection-address>\n' "$0" >&2
  exit 64
}

[ "$#" -eq 6 ] || usage

CANDIDATE=$1
TARGET=$2
BACKUP_ROOT=$3
ADMIN_USER=$4
CONNECTION_HOST=$5
CONNECTION_ADDRESS=$6
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
VERIFIER="$SCRIPT_DIR/verify-sshd-key-only.sh"

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
  printf 'install-sshd-key-only: run as root\n' >&2
  exit 77
fi

case "$TARGET" in
  /etc/ssh/sshd_config.d/0[0-9][0-9]-*.conf) ;;
  *)
    printf 'install-sshd-key-only: target must be an early numbered sshd_config.d file\n' >&2
    exit 65
    ;;
esac

case "$ADMIN_USER" in
  ''|*[!A-Za-z0-9._-]*)
    printf 'install-sshd-key-only: invalid administration user\n' >&2
    exit 65
    ;;
esac

if [ ! -f "$CANDIDATE" ] || [ -L "$CANDIDATE" ] || [ ! -x "$VERIFIER" ]; then
  printf 'install-sshd-key-only: unsafe candidate or missing verifier\n' >&2
  exit 66
fi

if /usr/bin/grep -Eq '__[A-Z0-9_]+__' "$CANDIDATE"; then
  printf 'install-sshd-key-only: unresolved candidate placeholder\n' >&2
  exit 65
fi

/usr/bin/grep -Eq "^Match User $ADMIN_USER$" "$CANDIDATE"
/usr/bin/grep -Eq '^[[:space:]]+AuthenticationMethods publickey$' "$CANDIDATE"
/usr/bin/grep -Eq '^[[:space:]]+PasswordAuthentication no$' "$CANDIDATE"
/usr/bin/grep -Eq '^[[:space:]]+KbdInteractiveAuthentication no$' "$CANDIDATE"

/usr/sbin/sshd -t

STAMP=$(/bin/date -u +%Y%m%dT%H%M%SZ)
BACKUP_DIR="$BACKUP_ROOT/$STAMP"
/bin/mkdir -p "$BACKUP_DIR"
/bin/chmod 700 "$BACKUP_ROOT" "$BACKUP_DIR"
/bin/cp -p /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config"

HAD_TARGET=no
if [ -e "$TARGET" ]; then
  if [ ! -f "$TARGET" ] || [ -L "$TARGET" ]; then
    printf 'install-sshd-key-only: unsafe existing target\n' >&2
    exit 66
  fi
  HAD_TARGET=yes
  /bin/cp -p "$TARGET" "$BACKUP_DIR/target.conf"
else
  : > "$BACKUP_DIR/target.absent"
fi

rollback() {
  if [ "$HAD_TARGET" = yes ]; then
    /usr/bin/install -o root -g wheel -m 644 "$BACKUP_DIR/target.conf" "$TARGET"
  else
    /bin/rm -f -- "$TARGET"
  fi
  /usr/sbin/sshd -t
}

/usr/bin/install -o root -g wheel -m 644 "$CANDIDATE" "$TARGET"

if ! /usr/sbin/sshd -t || ! "$VERIFIER" "$ADMIN_USER" "$CONNECTION_HOST" "$CONNECTION_ADDRESS"; then
  printf 'install-sshd-key-only: validation failed; restoring prior target state\n' >&2
  rollback
  exit 1
fi

printf 'install-sshd-key-only: installed key-only policy; rollback copy: %s\n' "$BACKUP_DIR"
