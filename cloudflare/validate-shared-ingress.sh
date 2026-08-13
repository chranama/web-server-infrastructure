#!/bin/bash

set -euo pipefail

PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
export LANG=C
export LC_ALL=C
umask 077

mode="rendered"
contract=""
candidate=""
validation_file=""

fail() {
  printf 'validate-shared-ingress: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "$validation_file" ] && [ "$validation_file" != "$candidate" ]; then
    /bin/rm -f -- "$validation_file"
  fi
}
trap cleanup EXIT INT TERM

case "${1:-}" in
  --template)
    [ "$#" -eq 3 ] || fail "usage: validate-shared-ingress.sh [--template] CONTRACT CONFIG"
    mode="template"
    contract="$2"
    candidate="$3"
    ;;
  '')
    fail "usage: validate-shared-ingress.sh [--template] CONTRACT CONFIG"
    ;;
  *)
    [ "$#" -eq 2 ] || fail "usage: validate-shared-ingress.sh [--template] CONTRACT CONFIG"
    contract="$1"
    candidate="$2"
    ;;
esac

[ -f "$contract" ] && [ ! -L "$contract" ] || fail "contract must be a regular non-symlink file"
[ -f "$candidate" ] && [ ! -L "$candidate" ] || fail "configuration must be a regular non-symlink file"

if [ "$mode" = "template" ]; then
  validation_file=$(/usr/bin/mktemp /tmp/shared-ingress-template.XXXXXX.yml)
else
  validation_file="$candidate"
fi

/usr/bin/python3 - "$contract" "$candidate" "$validation_file" "$mode" <<'PY'
from __future__ import annotations

import json
import os
import pwd
import re
import sys
import uuid
from pathlib import Path
from urllib.parse import urlparse

contract_path = Path(sys.argv[1])
candidate_path = Path(sys.argv[2])
validation_path = Path(sys.argv[3])
mode = sys.argv[4]


def stop(message: str) -> None:
    raise SystemExit(message)


def exact_keys(value: dict[str, object], expected: set[str], name: str) -> None:
    if set(value) != expected:
        stop(f"{name} must contain exactly: {', '.join(sorted(expected))}")


try:
    contract = json.loads(contract_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    stop(f"contract is not valid JSON: {error}")

if not isinstance(contract, dict):
    stop("contract must be a JSON object")
exact_keys(contract, {"version", "runtime", "routes", "local_ssh"}, "contract")
if contract["version"] != 1:
    stop("contract version must be 1")

runtime = contract["runtime"]
if not isinstance(runtime, dict):
    stop("runtime must be an object")
runtime_keys = {
    "active_config",
    "candidate_root",
    "backup_root",
    "expected_user",
    "expected_group",
    "tunnel_name",
    "service_target",
    "cloudflared_bin",
    "lock_dir",
}
exact_keys(runtime, runtime_keys, "runtime")
for key in runtime_keys:
    if not isinstance(runtime[key], str) or not runtime[key]:
        stop(f"runtime.{key} must be a non-empty string")
for key in ("active_config", "candidate_root", "backup_root", "cloudflared_bin", "lock_dir"):
    if not Path(runtime[key]).is_absolute():
        stop(f"runtime.{key} must be an absolute path")
if not runtime["service_target"].startswith("system/"):
    stop("runtime.service_target must identify a system launchd service")
for key in ("expected_user", "expected_group", "tunnel_name"):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", runtime[key]):
        stop(f"runtime.{key} contains unsupported characters")

local_ssh = contract["local_ssh"]
if not isinstance(local_ssh, dict):
    stop("local_ssh must be an object")
exact_keys(local_ssh, {"host", "port"}, "local_ssh")
if local_ssh["host"] != "127.0.0.1":
    stop("local_ssh.host must be 127.0.0.1")
if not isinstance(local_ssh["port"], int) or not 1 <= local_ssh["port"] <= 65535:
    stop("local_ssh.port must be an integer TCP port")

routes = contract["routes"]
if not isinstance(routes, list) or len(routes) != 4:
    stop("routes must contain exactly two HTTP routes, one SSH route, and one catch-all")
expected_kinds = ["http", "http", "ssh", "catchall"]
hostnames: set[str] = set()
for index, (route, kind) in enumerate(zip(routes, expected_kinds)):
    if not isinstance(route, dict):
        stop(f"routes[{index}] must be an object")
    if route.get("kind") != kind:
        stop(f"routes[{index}].kind must be {kind}")
    if kind == "http":
        exact_keys(
            route,
            {"name", "kind", "hostname", "service", "probe_url", "health_checks"},
            f"routes[{index}]",
        )
    elif kind == "ssh":
        exact_keys(
            route,
            {"name", "kind", "hostname", "service", "probe_url"},
            f"routes[{index}]",
        )
    else:
        exact_keys(route, {"name", "kind", "service"}, f"routes[{index}]")
    if not isinstance(route["name"], str) or not re.fullmatch(r"[a-z0-9-]+", route["name"]):
        stop(f"routes[{index}].name must use lowercase letters, digits, and hyphens")
    if kind == "catchall":
        if route["service"] != "http_status:404":
            stop("terminal catch-all must be http_status:404")
        continue
    hostname = route["hostname"]
    if not isinstance(hostname, str) or not re.fullmatch(
        r"(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}",
        hostname,
    ):
        stop(f"routes[{index}].hostname is not an exact DNS hostname")
    if "*" in hostname or hostname in hostnames:
        stop("route hostnames must be unique and may not use wildcards")
    hostnames.add(hostname)
    service = route["service"]
    expected_scheme = "http" if kind == "http" else "ssh"
    parsed_service = urlparse(service)
    if (
        parsed_service.scheme != expected_scheme
        or parsed_service.hostname != "127.0.0.1"
        or parsed_service.port is None
        or parsed_service.path not in ("", "/")
    ):
        stop(f"routes[{index}].service must be {expected_scheme} to a loopback TCP port")
    probe = urlparse(route["probe_url"])
    if probe.scheme != "https" or probe.hostname != hostname:
        stop(f"routes[{index}].probe_url must use HTTPS on its exact hostname")
    if kind == "http":
        checks = route["health_checks"]
        if not isinstance(checks, list) or not checks:
            stop(f"routes[{index}].health_checks must be a non-empty list")
        check_urls: list[str] = []
        for check_index, check in enumerate(checks):
            if not isinstance(check, dict):
                stop(f"routes[{index}].health_checks[{check_index}] must be an object")
            exact_keys(
                check,
                {"url", "expected_status"},
                f"routes[{index}].health_checks[{check_index}]",
            )
            parsed_check = urlparse(check["url"])
            if parsed_check.scheme not in ("http", "https") or not parsed_check.hostname:
                stop(f"routes[{index}].health_checks[{check_index}].url is invalid")
            if not isinstance(check["expected_status"], str) or not check["expected_status"]:
                stop(f"routes[{index}].health_checks[{check_index}].expected_status is invalid")
            check_urls.append(check["url"])
        local_origin = f"{parsed_service.scheme}://{parsed_service.hostname}:{parsed_service.port}"
        if not any(url.startswith(f"{local_origin}/") for url in check_urls):
            stop(f"routes[{index}] must health-check its exact loopback origin")
        if route["probe_url"] not in check_urls:
            stop(f"routes[{index}] must health-check its exact public probe URL")

if mode == "rendered":
    expected_uid = pwd.getpwnam(runtime["expected_user"]).pw_uid
    for path, label in ((contract_path, "contract"), (candidate_path, "candidate")):
        stat = path.stat()
        if stat.st_uid != expected_uid:
            stop(f"{label} must be owned by {runtime['expected_user']}")
        if stat.st_mode & 0o077:
            stop(f"{label} must not grant group or other access")

template_values = {
    "__TUNNEL_UUID__": "00000000-0000-4000-8000-000000000001",
    "__CLOUDFLARED_CREDENTIALS_FILE__": "/private/nonexistent/cloudflared-credentials.json",
    "__HTTP_ONE_HOSTNAME__": routes[0]["hostname"],
    "__HTTP_ONE_SERVICE__": routes[0]["service"],
    "__HTTP_TWO_HOSTNAME__": routes[1]["hostname"],
    "__HTTP_TWO_SERVICE__": routes[1]["service"],
    "__SSH_HOSTNAME__": routes[2]["hostname"],
    "__SSH_SERVICE__": routes[2]["service"],
    "__CATCHALL_SERVICE__": routes[3]["service"],
}

if mode == "template":
    text = candidate_path.read_text(encoding="utf-8")
    for placeholder, value in template_values.items():
        if text.count(placeholder) != 1:
            stop(f"template must contain {placeholder} exactly once")
        text = text.replace(placeholder, value)
    if "__" in text:
        stop("template contains an unresolved placeholder")
    validation_path.write_text(text, encoding="utf-8")
    validation_path.chmod(0o600)

lines = validation_path.read_text(encoding="utf-8").splitlines()
scalars: dict[str, str] = {}
actual_routes: list[dict[str, str]] = []
in_ingress = False
for number, raw in enumerate(lines, start=1):
    stripped = raw.strip()
    if not stripped or stripped.startswith("#"):
        continue
    scalar = re.fullmatch(r"(tunnel|credentials-file):[ \t]+([^ \t#]+)[ \t]*", raw)
    if scalar and not in_ingress:
        key, value = scalar.groups()
        if key in scalars:
            stop(f"line {number}: duplicate {key}")
        scalars[key] = value
        continue
    if raw == "ingress:":
        if in_ingress:
            stop(f"line {number}: duplicate ingress")
        in_ingress = True
        continue
    if not in_ingress:
        stop(f"line {number}: unexpected top-level content")
    hostname_match = re.fullmatch(r"  - hostname:[ \t]+([^ \t#]+)[ \t]*", raw)
    if hostname_match:
        actual_routes.append({"hostname": hostname_match.group(1)})
        continue
    service_match = re.fullmatch(r"    service:[ \t]+([^ \t#]+)[ \t]*", raw)
    if service_match and actual_routes and "service" not in actual_routes[-1]:
        actual_routes[-1]["service"] = service_match.group(1)
        continue
    catchall_match = re.fullmatch(r"  - service:[ \t]+([^ \t#]+)[ \t]*", raw)
    if catchall_match:
        actual_routes.append({"service": catchall_match.group(1)})
        continue
    stop(f"line {number}: unsupported ingress syntax or field")

if set(scalars) != {"tunnel", "credentials-file"}:
    stop("configuration must contain exactly tunnel and credentials-file scalars")
try:
    tunnel_id = uuid.UUID(scalars["tunnel"])
except ValueError as error:
    stop(f"tunnel must be a canonical UUID: {error}")
if str(tunnel_id) != scalars["tunnel"]:
    stop("tunnel must be a lowercase canonical UUID")
credentials = Path(scalars["credentials-file"])
if not credentials.is_absolute() or "__" in scalars["credentials-file"]:
    stop("credentials-file must be an absolute resolved path")
if mode == "rendered":
    if not credentials.is_file() or credentials.is_symlink():
        stop("credentials-file must be an existing regular non-symlink file")
    if credentials.stat().st_mode & 0o077:
        stop("credentials-file must not grant group or other access")

expected_routes = [
    {"hostname": routes[0]["hostname"], "service": routes[0]["service"]},
    {"hostname": routes[1]["hostname"], "service": routes[1]["service"]},
    {"hostname": routes[2]["hostname"], "service": routes[2]["service"]},
    {"service": routes[3]["service"]},
]
if actual_routes != expected_routes:
    stop("ingress routes must exactly match the ordered contract")
PY

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

CLOUDFLARED_BIN="${SHARED_INGRESS_CLOUDFLARED_BIN:-$(contract_value runtime.cloudflared_bin)}"
[ -x "$CLOUDFLARED_BIN" ] || fail "cloudflared is unavailable at the configured path"
"$CLOUDFLARED_BIN" tunnel --config "$validation_file" ingress validate >/dev/null

assert_rule() {
  index="$1"
  probe_url=$(contract_value "routes.$index.probe_url")
  hostname=$(contract_value "routes.$index.hostname")
  service=$(contract_value "routes.$index.service")
  output=$("$CLOUDFLARED_BIN" tunnel --config "$validation_file" ingress rule "$probe_url")
  printf '%s\n' "$output" | /usr/bin/grep -Fq "Matched rule #$index" || {
    fail "$probe_url did not match rule $index"
  }
  printf '%s\n' "$output" | /usr/bin/grep -Fq "hostname: $hostname" || {
    fail "$probe_url matched an unexpected hostname"
  }
  printf '%s\n' "$output" | /usr/bin/grep -Fq "service: $service" || {
    fail "$probe_url matched an unexpected service"
  }
}

assert_rule 0
assert_rule 1
assert_rule 2
catchall_service=$(contract_value routes.3.service)
catchall_output=$("$CLOUDFLARED_BIN" tunnel --config "$validation_file" ingress rule \
  "https://unmatched.invalid/")
printf '%s\n' "$catchall_output" | /usr/bin/grep -Fq "Matched rule #3" || {
  fail "unmatched URL did not reach the terminal catch-all"
}
printf '%s\n' "$catchall_output" | /usr/bin/grep -Fq "service: $catchall_service" || {
  fail "terminal catch-all has an unexpected service"
}

printf 'validate-shared-ingress: ordered route contract passed (%s mode)\n' "$mode"
