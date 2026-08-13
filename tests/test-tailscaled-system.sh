#!/bin/bash

set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
export LANG=C
export LC_ALL=C
umask 077

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEMPLATE="$ROOT/macos/tailscaled-launchdaemon.plist.template"
VALIDATOR="$ROOT/macos/validate-tailscaled-candidate.sh"
INSTALLER="$ROOT/macos/install-tailscaled-system.sh"
CUTOVER="$ROOT/macos/cutover-tailscaled-system.sh"
VERIFIER="$ROOT/macos/verify-tailscaled-system.sh"
CLIENT_TEMPLATE="$ROOT/macos/ssh-client-tailscale.conf.template"
WORK_DIR=$(/usr/bin/mktemp -d /tmp/tailscaled-system-tests.XXXXXX)
CANDIDATE="$WORK_DIR/candidate"

cleanup() {
  /bin/rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT INT TERM

/bin/mkdir -m 700 "$CANDIDATE"
/bin/cp "$TEMPLATE" "$CANDIDATE/com.tailscale.tailscaled.plist"
/bin/chmod 600 "$CANDIDATE/com.tailscale.tailscaled.plist"

for binary in tailscale tailscaled; do
  /usr/bin/sed "s/__BINARY__/$binary/g" > "$CANDIDATE/$binary" <<'EOF'
#!/bin/bash
# fake __BINARY__ candidate
if [ "${1:-}" = "--version" ] || [ "${1:-}" = "version" ]; then
  printf '%s\n' '1.2.3'
  exit 0
fi
exit 1
EOF
  /bin/chmod 700 "$CANDIDATE/$binary"
done

cli_sha=$(/usr/bin/shasum -a 256 "$CANDIDATE/tailscale" | /usr/bin/awk '{print $1}')
daemon_sha=$(/usr/bin/shasum -a 256 "$CANDIDATE/tailscaled" | /usr/bin/awk '{print $1}')
owner=$(/usr/bin/id -un)

"$VALIDATOR" "$CANDIDATE" "$owner" 1.2.3 "$cli_sha" "$daemon_sha"

if "$VALIDATOR" "$CANDIDATE" "$owner" 1.2.3 "$daemon_sha" "$cli_sha" > "$WORK_DIR/bad-hash.out" 2>&1; then
  printf 'test-tailscaled-system: validator accepted swapped hashes\n' >&2
  exit 1
fi
/usr/bin/grep -Eq 'checksum mismatch' "$WORK_DIR/bad-hash.out"

if "$INSTALLER" --apply --confirm-cloudflare-recovery --confirm-gui-stopped \
  "$CANDIDATE" "$owner" 1.2.3 "$cli_sha" "$daemon_sha" "$WORK_DIR/backups" \
  > "$WORK_DIR/non-root-install.out" 2>&1; then
  printf 'test-tailscaled-system: installer unexpectedly ran without root\n' >&2
  exit 1
fi
/usr/bin/grep -Eq 'run as root' "$WORK_DIR/non-root-install.out"

if "$CUTOVER" --apply --confirm-cloudflare-recovery \
  "$CANDIDATE" "$owner" 1.2.3 "$cli_sha" "$daemon_sha" "$WORK_DIR/backups" \
  "$WORK_DIR/auth-key" example-server 192.0.2.1 \
  > "$WORK_DIR/non-root-cutover.out" 2>&1; then
  printf 'test-tailscaled-system: cutover unexpectedly ran without root\n' >&2
  exit 1
fi
/usr/bin/grep -Eq 'run as root' "$WORK_DIR/non-root-cutover.out"
/usr/bin/grep -Fq -- '--auth-key="file:$AUTH_KEY_FILE"' "$CUTOVER"
/usr/bin/grep -Fq -- '--advertise-tags=tag:web-server' "$CUTOVER"
/usr/bin/grep -Fq -- '--ssh=false' "$CUTOVER"
/usr/bin/grep -Fq -- '/bin/launchctl disable "gui/$EXPECTED_UID/$LOGIN_HELPER"' "$CUTOVER"
/usr/bin/grep -Fq -- '/bin/rm -f -- "$AUTH_KEY_FILE"' "$CUTOVER"
/usr/bin/grep -Fq -- 'cutover failed; restoring the prior GUI path' "$CUTOVER"

if "$VERIFIER" 1.2.3 example-server 192.0.2.1 > "$WORK_DIR/non-root-verify.out" 2>&1; then
  printf 'test-tailscaled-system: verifier unexpectedly ran without root\n' >&2
  exit 1
fi
/usr/bin/grep -Eq 'run as root' "$WORK_DIR/non-root-verify.out"

/usr/bin/sed \
  -e 's|__SSH_ALIAS__|example-server|g' \
  -e 's|__MAGICDNS_NAME__|example-server.example.ts.net|g' \
  -e 's|__TRUSTED_HOST_KEY_ALIAS__|192.0.2.10|g' \
  -e 's|__ADMIN_USER__|example-admin|g' \
  -e 's|__IDENTITY_FILE__|~/.ssh/id_ed25519_example|g' \
  "$CLIENT_TEMPLATE" > "$WORK_DIR/ssh-client.conf"

if /usr/bin/grep -Eq '__[A-Z0-9_]+__' "$WORK_DIR/ssh-client.conf"; then
  printf 'test-tailscaled-system: unresolved client placeholder\n' >&2
  exit 1
fi
/usr/bin/grep -Eq '^Host example-server$' "$WORK_DIR/ssh-client.conf"
/usr/bin/grep -Eq '^[[:space:]]+HostName example-server\.example\.ts\.net$' "$WORK_DIR/ssh-client.conf"
/usr/bin/grep -Eq '^[[:space:]]+HostKeyAlias 192\.0\.2\.10$' "$WORK_DIR/ssh-client.conf"

printf 'test-tailscaled-system: candidate, safety gates, and client template passed\n'
