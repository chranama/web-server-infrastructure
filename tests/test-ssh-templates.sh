#!/bin/bash

set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
export LANG=C
export LC_ALL=C
umask 077

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SERVER_TEMPLATE="$ROOT/macos/sshd-key-only.conf.template"
CLIENT_TEMPLATE="$ROOT/macos/ssh-client-cloudflare.conf.template"
VERIFIER="$ROOT/macos/verify-sshd-key-only.sh"
INSTALLER="$ROOT/macos/install-sshd-key-only.sh"
WORK_DIR=$(/usr/bin/mktemp -d /tmp/ssh-template-tests.XXXXXX)

cleanup() {
  /bin/rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT INT TERM

/usr/bin/sed 's|__ADMIN_USER__|example-server|g' "$SERVER_TEMPLATE" > "$WORK_DIR/20-example-key-only.conf"
/usr/bin/sed \
  -e 's|__SSH_ALIAS__|example-server-cf|g' \
  -e 's|__SSH_HOSTNAME__|ssh.example.test|g' \
  -e 's|__TRUSTED_HOST_KEY_ALIAS__|192.0.2.10|g' \
  -e 's|__ADMIN_USER__|example-server|g' \
  -e 's|__IDENTITY_FILE__|~/.ssh/id_ed25519_example|g' \
  -e 's|__CLOUDFLARED_BIN__|/opt/homebrew/bin/cloudflared|g' \
  "$CLIENT_TEMPLATE" > "$WORK_DIR/ssh-client.conf"

if /usr/bin/grep -Eq '__[A-Z0-9_]+__' "$WORK_DIR/20-example-key-only.conf" "$WORK_DIR/ssh-client.conf"; then
  printf 'test-ssh-templates: unresolved placeholder\n' >&2
  exit 1
fi

/usr/bin/grep -Eq '^Match User example-server$' "$WORK_DIR/20-example-key-only.conf"
/usr/bin/grep -Eq '^[[:space:]]+AuthenticationMethods publickey$' "$WORK_DIR/20-example-key-only.conf"
/usr/bin/grep -Eq '^[[:space:]]+PasswordAuthentication no$' "$WORK_DIR/20-example-key-only.conf"
/usr/bin/grep -Eq '^[[:space:]]+KbdInteractiveAuthentication no$' "$WORK_DIR/20-example-key-only.conf"

/usr/bin/grep -Eq '^Host example-server-cf$' "$WORK_DIR/ssh-client.conf"
/usr/bin/grep -Eq '^[[:space:]]+HostKeyAlias 192\.0\.2\.10$' "$WORK_DIR/ssh-client.conf"
/usr/bin/grep -Eq '^[[:space:]]+ProxyCommand /opt/homebrew/bin/cloudflared access ssh --hostname %h$' "$WORK_DIR/ssh-client.conf"
/usr/bin/grep -Eq '^[[:space:]]+IdentitiesOnly yes$' "$WORK_DIR/ssh-client.conf"

if "$VERIFIER" example-server example.test 192.0.2.1 >"$WORK_DIR/non-root.out" 2>&1; then
  printf 'test-ssh-templates: verifier unexpectedly ran without root\n' >&2
  exit 1
fi
/usr/bin/grep -Eq 'run as root' "$WORK_DIR/non-root.out"

if "$INSTALLER" \
  "$WORK_DIR/20-example-key-only.conf" \
  /etc/ssh/sshd_config.d/020-example-key-only.conf \
  "$WORK_DIR/backups" \
  example-server example.test 192.0.2.1 >"$WORK_DIR/installer-non-root.out" 2>&1; then
  printf 'test-ssh-templates: installer unexpectedly ran without root\n' >&2
  exit 1
fi
/usr/bin/grep -Eq 'run as root' "$WORK_DIR/installer-non-root.out"

printf 'test-ssh-templates: rendered SSH templates passed\n'
