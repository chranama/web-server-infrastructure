#!/bin/bash

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

for forbidden in config/contract.json candidates backups logs evidence source-version; do
  if [ -e "$forbidden" ]; then
    printf 'test-no-secrets: forbidden runtime path exists: %s\n' "$forbidden" >&2
    exit 1
  fi
done

if /usr/bin/find . -type l -print -quit | /usr/bin/grep -q .; then
  printf 'test-no-secrets: symbolic links are not permitted in the public source tree\n' >&2
  exit 1
fi

tracked_files=$(/usr/bin/find . -type f ! -path './.git/*' -print)
if printf '%s\n' "$tracked_files" | /usr/bin/grep -E \
  '(^|/)(\.env($|\.)|id_(rsa|dsa|ecdsa|ed25519)$)|\.(pem|key|p12)$|credentials.*\.json$'; then
  printf 'test-no-secrets: secret-shaped file name found\n' >&2
  exit 1
fi

if /usr/bin/grep -RIEq \
  --exclude-dir=.git \
  --exclude='test-no-secrets.sh' \
  '(-----BEGIN (OPENSSH|RSA|EC|DSA) PRIVATE KEY-----|sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|cloudflared access token|CF-Access-Client-Secret[[:space:]]*[:=][[:space:]]*[^_[:space:]][^[:space:]]+)' \
  .; then
  printf 'test-no-secrets: secret-shaped value found\n' >&2
  exit 1
fi

if /usr/bin/grep -RIEq \
  --exclude-dir=.git \
  --exclude='test-no-secrets.sh' \
  '(chranama-server|100\.[0-9]+\.[0-9]+\.[0-9]+|ssh-ed25519[[:space:]]+[A-Za-z0-9+/]{40,}|[0-9a-f]{64})' \
  .; then
  printf 'test-no-secrets: host-specific identity or evidence found\n' >&2
  exit 1
fi

printf 'test-no-secrets: repository boundary passed\n'

