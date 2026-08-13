#!/usr/bin/env python3

from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import urlparse


def fail(message: str) -> None:
    print(f"fake-cloudflared: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_routes(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        fail("configuration does not exist")
    routes: list[dict[str, str]] = []
    in_ingress = False
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if raw == "ingress:":
            in_ingress = True
            continue
        if not in_ingress:
            continue
        hostname = re.fullmatch(r"  - hostname:\s+(\S+)\s*", raw)
        if hostname:
            routes.append({"hostname": hostname.group(1)})
            continue
        service = re.fullmatch(r"    service:\s+(\S+)\s*", raw)
        if service and routes and "service" not in routes[-1]:
            routes[-1]["service"] = service.group(1)
            continue
        catchall = re.fullmatch(r"  - service:\s+(\S+)\s*", raw)
        if catchall:
            routes.append({"service": catchall.group(1)})
            continue
        fail("unsupported ingress content")
    if not routes or any("service" not in route for route in routes):
        fail("incomplete ingress routes")
    return routes


def main() -> None:
    args = sys.argv[1:]
    if len(args) < 5 or args[0:2] != ["tunnel", "--config"] or args[3] != "ingress":
        fail("unsupported command")
    config = Path(args[2])
    action = args[4]
    routes = read_routes(config)
    if action == "validate" and len(args) == 5:
        return
    if action != "rule" or len(args) != 6:
        fail("unsupported ingress action")
    hostname = urlparse(args[5]).hostname
    for index, route in enumerate(routes):
        if route.get("hostname") in (None, hostname):
            print(f"Matched rule #{index}")
            if "hostname" in route:
                print(f"hostname: {route['hostname']}")
            print(f"service: {route['service']}")
            return
    fail("no matching rule")


if __name__ == "__main__":
    main()

