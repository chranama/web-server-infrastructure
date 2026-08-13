#!/bin/bash

set -euo pipefail

PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
export LANG=C
export LC_ALL=C
umask 077

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEMPLATE="$ROOT/cloudflare/shared-ingress.yml.template"
VALIDATOR="$ROOT/cloudflare/validate-shared-ingress.sh"
CONTRACT="$ROOT/config/contract.example.json"
WORK_DIR=$(/usr/bin/mktemp -d /tmp/shared-ingress-tests.XXXXXX)
export SHARED_INGRESS_CLOUDFLARED_BIN="${SHARED_INGRESS_CLOUDFLARED_BIN:-$ROOT/tests/fake-cloudflared.py}"

cleanup() {
  /bin/rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT INT TERM

expect_reject() {
  name="$1"
  contract="$2"
  file="$3"
  if "$VALIDATOR" --template "$contract" "$file" >"$WORK_DIR/$name.out" 2>&1; then
    printf 'test-shared-ingress: expected rejection: %s\n' "$name" >&2
    exit 1
  fi
  printf 'test-shared-ingress: rejected %s\n' "$name"
}

"$VALIDATOR" --template "$CONTRACT" "$TEMPLATE"

/usr/bin/python3 - "$CONTRACT" "$TEMPLATE" "$WORK_DIR" <<'PY'
import json
import sys
from copy import deepcopy
from pathlib import Path

contract_path = Path(sys.argv[1])
template_path = Path(sys.argv[2])
root = Path(sys.argv[3])
contract = json.loads(contract_path.read_text(encoding="utf-8"))
template = template_path.read_text(encoding="utf-8")


def write_contract(name: str, value: dict) -> None:
    (root / name).write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


(root / "malformed.yml").write_text(template + "unexpected: true\n", encoding="utf-8")

changed_one = deepcopy(contract)
changed_one["routes"][0]["service"] = "http://127.0.0.1:9080"
write_contract("changed-one.json", changed_one)

changed_two = deepcopy(contract)
changed_two["routes"][1]["service"] = "http://127.0.0.1:9081"
write_contract("changed-two.json", changed_two)

missing_ssh = deepcopy(contract)
missing_ssh["routes"].pop(2)
write_contract("missing-ssh.json", missing_ssh)

misplaced = deepcopy(contract)
misplaced["routes"][2], misplaced["routes"][3] = misplaced["routes"][3], misplaced["routes"][2]
write_contract("misplaced-catchall.json", misplaced)

wildcard = deepcopy(contract)
wildcard["routes"][0]["hostname"] = "*.example.test"
wildcard["routes"][0]["probe_url"] = "https://*.example.test/health"
write_contract("wildcard.json", wildcard)

extra = deepcopy(contract)
extra["runtime"]["unexpected"] = "value"
write_contract("extra-field.json", extra)

unsafe = deepcopy(contract)
unsafe["routes"][0]["service"] = "http://192.0.2.20:8080"
write_contract("non-loopback.json", unsafe)

(root / "missing-placeholder.yml").write_text(
    template.replace("__SSH_HOSTNAME__", "ssh.example.test"), encoding="utf-8"
)
PY

expect_reject malformed "$CONTRACT" "$WORK_DIR/malformed.yml"
expect_reject changed-first-origin "$WORK_DIR/changed-one.json" "$TEMPLATE"
expect_reject changed-second-origin "$WORK_DIR/changed-two.json" "$TEMPLATE"
expect_reject missing-ssh-route "$WORK_DIR/missing-ssh.json" "$TEMPLATE"
expect_reject misplaced-catchall "$WORK_DIR/misplaced-catchall.json" "$TEMPLATE"
expect_reject unexpected-wildcard "$WORK_DIR/wildcard.json" "$TEMPLATE"
expect_reject extra-contract-field "$WORK_DIR/extra-field.json" "$TEMPLATE"
expect_reject non-loopback-origin "$WORK_DIR/non-loopback.json" "$TEMPLATE"
expect_reject altered-template-placeholder "$CONTRACT" "$WORK_DIR/missing-placeholder.yml"

printf 'test-shared-ingress: all positive and negative cases passed\n'
