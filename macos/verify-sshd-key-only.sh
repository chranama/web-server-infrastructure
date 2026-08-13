#!/bin/bash

set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
export LANG=C
export LC_ALL=C

usage() {
  printf 'usage: sudo %s <admin-user> <connection-host> <connection-address>\n' "$0" >&2
  exit 64
}

[ "$#" -eq 3 ] || usage

ADMIN_USER=$1
CONNECTION_HOST=$2
CONNECTION_ADDRESS=$3

case "$ADMIN_USER" in
  ''|*[!A-Za-z0-9._-]*)
    printf 'verify-sshd-key-only: invalid administration user\n' >&2
    exit 65
    ;;
esac

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
  printf 'verify-sshd-key-only: run as root so sshd can read host keys\n' >&2
  exit 77
fi

EFFECTIVE=$(/usr/sbin/sshd -T -C "user=$ADMIN_USER,host=$CONNECTION_HOST,addr=$CONNECTION_ADDRESS")

require_value() {
  keyword=$1
  expected=$2
  actual=$(printf '%s\n' "$EFFECTIVE" | /usr/bin/awk -v key="$keyword" '$1 == key { print $2; exit }')
  if [ "$actual" != "$expected" ]; then
    printf 'verify-sshd-key-only: %s is %s, expected %s\n' \
      "$keyword" "${actual:-unset}" "$expected" >&2
    exit 1
  fi
}

require_value pubkeyauthentication yes
require_value authenticationmethods publickey
require_value passwordauthentication no
require_value kbdinteractiveauthentication no

printf 'verify-sshd-key-only: effective key-only policy passed for %s\n' "$ADMIN_USER"
