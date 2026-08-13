# Web Server Infrastructure

This repository contains the reusable, non-secret infrastructure code for operating multiple
independent applications behind one locally managed Cloudflare Tunnel on a macOS server. It keeps
shared ingress ownership outside either application and makes route changes explicit, validated,
and recoverable.

The implementation supports a deliberately small deployment:

- two HTTP applications with separate loopback origins and health checks;
- one Access-protected SSH route to the host's existing OpenSSH service;
- a terminal 404 catch-all;
- one launchd-managed `cloudflared` connector; and
- guarded activation with a protected backup and automatic rollback.

It is not a high-availability design. The applications still share one computer, network
connection, tunnel process, Cloudflare account, and domain.

## Repository boundary

This repository contains templates, validation, activation mechanics, tests, and sanitized
operating guidance. It must never contain a rendered production configuration, credential,
private key, session, backup, log, host-security finding, application secret, or execution
evidence.

On a server, keep the checkout separate from mutable runtime state:

```text
~/src/web-server-infrastructure/          clean checkout at a reviewed commit
~/web-server-infrastructure-runtime/      installed code, candidates, backups, logs, evidence
~/.cloudflared/                           active configuration and tunnel credential
```

These names are a project convention. The important property is that reviewed source and mutable
or secret state do not share a directory.

## Workflow

1. Copy `config/contract.example.json` to a protected runtime `contract.json` and replace every
   example value with the host contract.
2. Render `cloudflare/shared-ingress.yml.template` only inside the protected candidate directory.
3. Validate the exact contract and candidate.
4. Run the activation script in `--dry-run` mode.
5. Activate only after application work is quiescent and an independent recovery path is ready.
6. Record the reviewed source commit represented by the installed copy.

The live configuration is never edited in place and is never run directly from this checkout.
The server does not automatically pull or activate new commits.

See [architecture](docs/architecture.md) for the trust and ownership boundaries and
[operations](docs/operations.md) for the promotion, validation, SSH hardening, client setup,
activation, and recovery sequence.

## Example applications

This infrastructure was extracted from the shared host used by
[MealCheck](https://github.com/chranama/MealCheck) and the
[Treasury label-review prototype](https://github.com/chranama/treasury-takehome). Those projects
remain independently deployable and do not require this repository for local development.

## Development checks

The local tests require Bash, Python 3, and macOS `plutil`. Contract tests use a deterministic
`cloudflared` test double; CI and server promotion repeat them against the real binary:

```bash
bash tests/test-shared-ingress.sh
bash tests/test-plist-template.sh
bash tests/test-ssh-templates.sh
bash tests/test-no-secrets.sh
```

## License

MIT
