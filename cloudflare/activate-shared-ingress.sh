#!/bin/bash

set -euo pipefail

PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
export LANG=C
export LC_ALL=C
umask 077

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
VALIDATOR="$SCRIPT_DIR/validate-shared-ingress.sh"
TEMPLATE="$SCRIPT_DIR/shared-ingress.yml.template"

mode=""
contract=""
candidate=""
backup_dir=""
backup_file=""
config_installed=0
completed=0
lock_acquired=0

fail() {
  printf 'activate-shared-ingress: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage:
  activate-shared-ingress.sh CONTRACT --dry-run CANDIDATE_CONFIG
  activate-shared-ingress.sh CONTRACT --rehearse-rollback PROTECTED_BASELINE_CONFIG
  sudo activate-shared-ingress.sh CONTRACT --apply \
    --confirm-access-ssh-ready --confirm-shared-ingress-change CANDIDATE_CONFIG
EOF
  exit 2
}

[ "$#" -ge 1 ] || usage
contract="$1"
shift

case "${1:-}" in
  --dry-run)
    [ "$#" -eq 2 ] || usage
    mode="dry-run"
    candidate="$2"
    ;;
  --rehearse-rollback)
    [ "$#" -eq 2 ] || usage
    mode="rehearse-rollback"
    candidate="$2"
    ;;
  --apply)
    [ "$#" -eq 4 ] || usage
    [ "${2:-}" = "--confirm-access-ssh-ready" ] || usage
    [ "${3:-}" = "--confirm-shared-ingress-change" ] || usage
    mode="apply"
    candidate="$4"
    ;;
  *) usage ;;
esac

[ -x "$VALIDATOR" ] || fail "ingress validator is unavailable"
[ -f "$TEMPLATE" ] || fail "canonical ingress template is unavailable"
[ -f "$contract" ] && [ ! -L "$contract" ] || fail "contract is unavailable"

# Validate the contract before using any of its values in shell operations.
"$VALIDATOR" --template "$contract" "$TEMPLATE" >/dev/null

contract_value() {
  key="$1"
  /usr/bin/python3 - "$contract" "$key" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
for part in sys.argv[2].split("."):
    value = value[int(part)] if isinstance(value, list) else value[part]
print(value)
PY
}

CONFIG=$(contract_value runtime.active_config)
CANDIDATE_ROOT=$(contract_value runtime.candidate_root)
BACKUP_ROOT=$(contract_value runtime.backup_root)
EXPECTED_USER=$(contract_value runtime.expected_user)
EXPECTED_GROUP=$(contract_value runtime.expected_group)
EXPECTED_TUNNEL_NAME=$(contract_value runtime.tunnel_name)
SERVICE_TARGET=$(contract_value runtime.service_target)
CLOUDFLARED_BIN="${SHARED_INGRESS_CLOUDFLARED_BIN:-$(contract_value runtime.cloudflared_bin)}"
LOCK_DIR=$(contract_value runtime.lock_dir)
SSH_HOST=$(contract_value local_ssh.host)
SSH_PORT=$(contract_value local_ssh.port)

verify_protected_file() {
  file="$1"
  label="$2"
  [ -f "$file" ] && [ ! -L "$file" ] || fail "$label is unavailable"
  [ "$(/usr/bin/stat -f '%OLp' "$file")" = "600" ] || fail "$label must have mode 600"
  [ "$(/usr/bin/stat -f '%Su' "$file")" = "$EXPECTED_USER" ] || {
    fail "$label must be owned by $EXPECTED_USER"
  }
}

verify_protected_file "$contract" "runtime contract"

service_pid() {
  /bin/launchctl print "$SERVICE_TARGET" 2>/dev/null |
    /usr/bin/awk '$1 == "pid" {print $3; exit}'
}

wait_for_replacement() {
  old_pid="$1"
  attempt=0
  while [ "$attempt" -lt 40 ]; do
    replacement_pid=$(service_pid || true)
    if [ -n "$replacement_pid" ] && [ "$replacement_pid" != "$old_pid" ] && \
      /bin/kill -0 "$replacement_pid" 2>/dev/null; then
      printf '%s' "$replacement_pid"
      return 0
    fi
    attempt=$((attempt + 1))
    /bin/sleep 1
  done
  return 1
}

verify_process() {
  pid="$1"
  case "$pid" in
    ''|*[!0-9]*) fail "tunnel service does not have a numeric process id" ;;
  esac
  owner=$(/bin/ps -o user= -p "$pid" | /usr/bin/xargs)
  [ "$owner" = "$EXPECTED_USER" ] || fail "tunnel process owner is unexpected"
  command=$(/bin/ps -o command= -p "$pid")
  case "$command" in
    *"$CLOUDFLARED_BIN tunnel --config $CONFIG run $EXPECTED_TUNNEL_NAME"*) ;;
    *) fail "tunnel process command does not match the host contract" ;;
  esac
}

check_json_status() {
  url="$1"
  expected="$2"
  payload=$(/usr/bin/curl --fail --silent --show-error \
    --connect-timeout 5 --max-time 12 "$url")
  printf '%s' "$payload" | /usr/bin/python3 -c '
import json
import sys

expected = sys.argv[1]
payload = json.load(sys.stdin)
if payload.get("status") != expected:
    raise SystemExit(f"expected status {expected!r}")
' "$expected"
}

health_contract() {
  /usr/bin/python3 - "$contract" <<'PY'
import json
import sys

contract = json.load(open(sys.argv[1], encoding="utf-8"))
for route in contract["routes"]:
    for check in route.get("health_checks", []):
        print(f"{check['url']}\t{check['expected_status']}")
PY
}

check_all_health() {
  checks=$(health_contract)
  tab=$(printf '\t')
  while IFS="$tab" read -r url expected; do
    [ -n "$url" ] || continue
    check_json_status "$url" "$expected"
  done <<EOF
$checks
EOF
}

wait_for_all_health() {
  attempt=0
  while [ "$attempt" -lt 30 ]; do
    if check_all_health >/dev/null 2>&1; then
      return 0
    fi
    attempt=$((attempt + 1))
    /bin/sleep 2
  done
  return 1
}

config_scalar() {
  file="$1"
  key="$2"
  /usr/bin/awk -v key="$key" '$1 == key ":" {print $2; exit}' "$file"
}

verify_current_baseline() {
  "$CLOUDFLARED_BIN" tunnel --config "$CONFIG" ingress validate >/dev/null
  index=0
  while [ "$index" -lt 2 ]; do
    probe_url=$(contract_value "routes.$index.probe_url")
    hostname=$(contract_value "routes.$index.hostname")
    service=$(contract_value "routes.$index.service")
    output=$("$CLOUDFLARED_BIN" tunnel --config "$CONFIG" ingress rule "$probe_url")
    printf '%s\n' "$output" | /usr/bin/grep -Fq "hostname: $hostname" || {
      fail "current ingress changed an accepted HTTP hostname"
    }
    printf '%s\n' "$output" | /usr/bin/grep -Fq "service: $service" || {
      fail "current ingress changed an accepted HTTP service"
    }
    index=$((index + 1))
  done
  catchall=$(contract_value routes.3.service)
  output=$("$CLOUDFLARED_BIN" tunnel --config "$CONFIG" ingress rule \
    "https://unmatched.invalid/")
  printf '%s\n' "$output" | /usr/bin/grep -Fq "service: $catchall" || {
    fail "current ingress changed the terminal catch-all"
  }
}

verify_candidate_identity() {
  current_tunnel=$(config_scalar "$CONFIG" tunnel)
  candidate_tunnel=$(config_scalar "$candidate" tunnel)
  [ -n "$current_tunnel" ] && [ "$candidate_tunnel" = "$current_tunnel" ] || {
    fail "candidate tunnel identity does not match the active tunnel"
  }
  current_credentials=$(config_scalar "$CONFIG" credentials-file)
  candidate_credentials=$(config_scalar "$candidate" credentials-file)
  [ -n "$current_credentials" ] && [ "$candidate_credentials" = "$current_credentials" ] || {
    fail "candidate credentials path does not match the active tunnel"
  }
}

preflight() {
  [ -x "$CLOUDFLARED_BIN" ] || fail "cloudflared is unavailable"
  [ -f "$CONFIG" ] && [ ! -L "$CONFIG" ] || fail "active tunnel config is unavailable"
  "$VALIDATOR" "$contract" "$candidate"
  verify_current_baseline
  verify_candidate_identity
  current_pid=$(service_pid || true)
  verify_process "$current_pid"
  check_all_health
  /usr/bin/nc -z -w 3 "$SSH_HOST" "$SSH_PORT" >/dev/null 2>&1 || {
    fail "local SSH is not listening on the contracted address"
  }
}

restore_on_failure() {
  status=$?
  trap - EXIT INT TERM
  set +e
  if [ "$status" -ne 0 ] && [ "$config_installed" -eq 1 ] && \
    [ "$completed" -eq 0 ] && [ -f "$backup_file" ]; then
    printf 'activate-shared-ingress: activation failed; restoring protected baseline\n' >&2
    /usr/bin/install -o "$EXPECTED_USER" -g "$EXPECTED_GROUP" -m 600 \
      "$backup_file" "$CONFIG.restore"
    /bin/mv -f "$CONFIG.restore" "$CONFIG"
    rollback_old_pid=$(service_pid || true)
    /bin/launchctl kickstart -k "$SERVICE_TARGET"
    rollback_pid=$(wait_for_replacement "$rollback_old_pid" || true)
    if [ -n "$rollback_pid" ]; then
      verify_process "$rollback_pid" || true
    fi
    verify_current_baseline || true
    if wait_for_all_health; then
      printf 'activate-shared-ingress: protected baseline restored; applications are healthy\n' >&2
    else
      printf 'activate-shared-ingress: rollback attempted; health requires local-console inspection\n' >&2
    fi
  fi
  if [ "$lock_acquired" -eq 1 ]; then
    /bin/rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
  exit "$status"
}
trap restore_on_failure EXIT
trap 'exit 130' INT TERM

if [ "$mode" = "rehearse-rollback" ]; then
  [ "$(/usr/bin/id -un)" = "$EXPECTED_USER" ] || {
    fail "rollback rehearsal must run as $EXPECTED_USER"
  }
  verify_protected_file "$candidate" "protected baseline"
  rehearsal=$(/usr/bin/mktemp /tmp/shared-ingress-rollback.XXXXXX.yml)
  /bin/cp -p "$candidate" "$rehearsal"
  /bin/chmod 600 "$rehearsal"
  /usr/bin/cmp "$candidate" "$rehearsal"
  "$CLOUDFLARED_BIN" tunnel --config "$rehearsal" ingress validate >/dev/null
  index=0
  while [ "$index" -lt 2 ]; do
    probe_url=$(contract_value "routes.$index.probe_url")
    "$CLOUDFLARED_BIN" tunnel --config "$rehearsal" ingress rule "$probe_url" >/dev/null
    index=$((index + 1))
  done
  /bin/rm -f "$rehearsal"
  completed=1
  printf 'activate-shared-ingress: rollback file is readable, exact, and syntactically valid\n'
  exit 0
fi

case "$candidate" in
  "$CANDIDATE_ROOT"/*) ;;
  *) fail "candidate must be under the contracted protected candidates directory" ;;
esac

if [ "$mode" = "dry-run" ]; then
  [ "$(/usr/bin/id -un)" = "$EXPECTED_USER" ] || fail "dry run must run as $EXPECTED_USER"
  preflight
  completed=1
  printf 'activate-shared-ingress: dry run passed; no file, process, route, or service changed\n'
  exit 0
fi

[ "$(/usr/bin/id -u)" -eq 0 ] || fail "activation must run as root"
if ! /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
  fail "another shared-ingress activation is active"
fi
lock_acquired=1

preflight
old_pid=$(service_pid)
timestamp=$(/bin/date -u +%Y%m%dT%H%M%SZ)
backup_dir="$BACKUP_ROOT/$timestamp"
backup_file="$backup_dir/$(basename "$CONFIG")"

/bin/mkdir -p "$BACKUP_ROOT"
/usr/sbin/chown "$EXPECTED_USER:$EXPECTED_GROUP" "$BACKUP_ROOT"
/bin/chmod 700 "$BACKUP_ROOT"
/bin/mkdir "$backup_dir"
/usr/sbin/chown "$EXPECTED_USER:$EXPECTED_GROUP" "$backup_dir"
/bin/chmod 700 "$backup_dir"
/usr/bin/install -o "$EXPECTED_USER" -g "$EXPECTED_GROUP" -m 600 "$CONFIG" "$backup_file"
{
  printf 'captured_at_utc=%s\n' "$timestamp"
  /usr/bin/shasum -a 256 "$backup_file" "$candidate"
} > "$backup_dir/MANIFEST.sha256"
/usr/sbin/chown "$EXPECTED_USER:$EXPECTED_GROUP" "$backup_dir/MANIFEST.sha256"
/bin/chmod 600 "$backup_dir/MANIFEST.sha256"

/usr/bin/install -o "$EXPECTED_USER" -g "$EXPECTED_GROUP" -m 600 \
  "$candidate" "$CONFIG.next"
/bin/mv -f "$CONFIG.next" "$CONFIG"
config_installed=1

/bin/launchctl kickstart -k "$SERVICE_TARGET"
new_pid=$(wait_for_replacement "$old_pid") || fail "launchd did not start a replacement process"
verify_process "$new_pid"
"$VALIDATOR" "$contract" "$CONFIG"
wait_for_all_health || fail "applications did not become healthy after tunnel restart"
/usr/bin/nc -z -w 3 "$SSH_HOST" "$SSH_PORT" >/dev/null 2>&1 || {
  fail "local SSH became unavailable"
}

completed=1
/bin/rmdir "$LOCK_DIR"
lock_acquired=0
printf 'activate-shared-ingress: activated canonical ingress through %s\n' "$SERVICE_TARGET"
printf 'activate-shared-ingress: protected rollback directory: %s\n' "$backup_dir"

