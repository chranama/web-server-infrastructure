# Operations

## Required tools

- macOS with launchd
- Bash and Python 3
- a locally managed Cloudflare Tunnel and `cloudflared`
- an existing independent administration path
- application health endpoints that do not trigger paid or mutating work

## Promote a reviewed commit

1. Select an exact commit whose CI passed.
2. Check out that commit in the server source directory; do not track a moving branch during the
   change.
3. Run the contract, plist, and secret-boundary tests.
4. Copy the reviewed scripts and templates into the protected runtime `installed/` directory.
5. Write the full commit identifier to protected `runtime/source-version`.
6. Confirm the checkout, installed files, and recorded commit agree before rendering a candidate.

Do not configure automatic pulls or activation.

## Prepare the host contract

Copy `config/contract.example.json` to protected runtime state, replace all example values, and set
mode 600. The contract defines exactly two HTTP routes, one SSH route, one terminal catch-all,
health checks, launchd identity, live configuration, and protected candidate and backup roots.

The contract contains no credential value, but it is protected because it describes the concrete
host.

## Render and validate

Render the ingress template using the contract's hostnames and services plus the active tunnel UUID
and credential-file path. Do not read or copy the credential contents. The output must be a regular
non-symlink file, owned by the configured service user, mode 600, inside the configured candidate
root.

```bash
installed/cloudflare/validate-shared-ingress.sh \
  runtime/contract.json runtime/candidates/shared-ingress.next.yml

installed/cloudflare/activate-shared-ingress.sh \
  runtime/contract.json --dry-run runtime/candidates/shared-ingress.next.yml
```

The validator requires the exact ordered contract and rejects alternate origins, missing routes,
wildcards, extra fields, unresolved placeholders, unsafe candidate permissions, and unsafe tunnel
credentials.

## Activate

Activate only when both applications have no active work, every preflight passes, Access and origin
SSH policy are ready, and an independent recovery path is available:

```bash
sudo installed/cloudflare/activate-shared-ingress.sh \
  runtime/contract.json --apply \
  --confirm-access-ssh-ready \
  --confirm-shared-ingress-change \
  runtime/candidates/shared-ingress.next.yml
```

Activation backs up the live configuration, atomically replaces it, restarts only the configured
launchd service, verifies the replacement process and exact routes, and waits for application
health. A failure after replacement restores the protected baseline and rechecks both applications.

## Recovery

Stay on the independent administration path or local console. Validate the protected pre-change
configuration, restore that exact file with the expected owner and mode, restart only the tunnel
service, verify its process contract, and rerun every local and public health check. Use an
application's own rollback if routing is not the demonstrated cause.

