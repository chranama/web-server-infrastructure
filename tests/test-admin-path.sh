#!/bin/bash

set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
export LANG=C
export LC_ALL=C
umask 077

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHECKER="$ROOT/macos/check-admin-path.sh"
WORK_DIR=$(/usr/bin/mktemp -d /tmp/admin-path-tests.XXXXXX)
FAKE_BIN="$WORK_DIR/bin"
CALLS="$WORK_DIR/calls"

cleanup() {
  /bin/rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT INT TERM

/bin/mkdir -m 700 "$FAKE_BIN"
/usr/bin/touch "$CALLS"
/bin/chmod 600 "$CALLS"

/usr/bin/sed "s|__CALLS__|$CALLS|g" > "$FAKE_BIN/ssh" <<'FAKE'
#!/bin/bash
set -eu
printf '%s\n' "$*" >> __CALLS__
if [ "${1:-}" = "-G" ]; then
  printf 'user example-admin\n'
  printf 'hostname example.invalid\n'
  printf 'hostkeyalias trusted-origin\n'
  exit 0
fi
/bin/cat >/dev/null
exit "${FAKE_SSH_EXIT:-0}"
FAKE
/bin/chmod 700 "$FAKE_BIN/ssh"

ADMIN_PATH_SSH_BIN="$FAKE_BIN/ssh" "$CHECKER" mealcheck-server > "$WORK_DIR/primary.out"
ADMIN_PATH_SSH_BIN="$FAKE_BIN/ssh" "$CHECKER" mealcheck-server-cf > "$WORK_DIR/secondary.out"
/usr/bin/grep -Fq 'Configuration-only check passed' "$WORK_DIR/primary.out"
/usr/bin/grep -Fq 'Selected administration alias: mealcheck-server-cf' "$WORK_DIR/secondary.out"

before=$(/usr/bin/wc -l < "$CALLS")
if ADMIN_PATH_SSH_BIN="$FAKE_BIN/ssh" "$CHECKER" unsupported-host \
  > "$WORK_DIR/unsupported.out" 2>&1; then
  printf 'test-admin-path: unsupported alias was accepted\n' >&2
  exit 1
fi
after=$(/usr/bin/wc -l < "$CALLS")
[ "$before" -eq "$after" ] || {
  printf 'test-admin-path: unsupported alias reached ssh\n' >&2
  exit 1
}
/usr/bin/grep -Fq 'usage:' "$WORK_DIR/unsupported.out"

: > "$CALLS"
if FAKE_SSH_EXIT=23 ADMIN_PATH_SSH_BIN="$FAKE_BIN/ssh" \
  "$CHECKER" --connect mealcheck-server \
  > "$WORK_DIR/failed-primary.out" 2>&1; then
  printf 'test-admin-path: simulated primary failure was accepted\n' >&2
  exit 1
fi
[ "$(/usr/bin/wc -l < "$CALLS")" -eq 2 ]
if /usr/bin/grep -q 'mealcheck-server-cf' "$CALLS"; then
  printf 'test-admin-path: primary failure silently attempted the secondary alias\n' >&2
  exit 1
fi

: > "$CALLS"
ADMIN_PATH_SSH_BIN="$FAKE_BIN/ssh" "$CHECKER" --connect mealcheck-server-cf \
  > "$WORK_DIR/secondary-connect.out"
/usr/bin/grep -Fq 'Read-only administration-path check passed through mealcheck-server-cf' \
  "$WORK_DIR/secondary-connect.out"

printf 'test-admin-path: alias validation, config-only mode, and no-fallback behavior passed\n'
