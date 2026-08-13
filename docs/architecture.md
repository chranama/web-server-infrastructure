# Architecture

## Ownership

The shared host owns the Cloudflare connector, ordered ingress contract, protected configuration,
and rollback mechanics. Each application owns its process, listener, health behavior, data,
secrets, release procedure, and application rollback.

An ordinary application release may verify its public route, but it must not edit the shared
configuration or restart `cloudflared`.

## Request paths

```text
public HTTPS -> Cloudflare -> one tunnel connector -> application-one loopback origin
                                             \----> application-two loopback origin

operator cloudflared -> Cloudflare Access -> same connector -> loopback OpenSSH
```

The SSH route is a network reachability layer, not the origin authentication mechanism. A
deny-by-default Access policy and MFA should protect the hostname, while OpenSSH should still
require the accepted public key. Publishing raw router TCP/22 or enabling passwords is outside this
design.

## Source, runtime, and secrets

The public Git checkout contains only reusable source. A protected runtime tree receives an
explicitly promoted copy and records its source commit. Host values are rendered into a protected
candidate outside Git. `cloudflared`, OpenSSH, Tailscale, and the applications retain their own
credential or state locations.

This prevents a repository update from becoming a live infrastructure change and keeps runtime
material out of source control.

## Failure boundaries

Separate application processes and ports isolate ordinary application restarts. One connector
still means a tunnel restart can interrupt both public routes and the secondary SSH path. The
activation procedure therefore requires an independent recovery path, validates all routes, checks
both applications before and after replacement, and restores the prior configuration on failure.

Multiple tunnels on the same host would not provide host, power, network, domain, account, or
provider availability. Split tunnels when credentials, owners, hosts, compliance boundaries, or
availability targets genuinely diverge.

