"""Generate an OpenShell sandbox policy from IP allowlist files.

Usage:
  policy-gen.py --uid UID --gid GID [--conf FILE]... [--host-port PORT]...

Each allowlist file has one entry per line:

    # comment
    <ip-or-cidr> [port[,port...]]     # ports default to 443

--conf files are trusted as-is (they come from the Nix store).

Entries are merged and grouped by port into hostless `allowed_ips` endpoints.
OpenShell rejects overlapping endpoints whose `allowed_ips` differ, so there
must be exactly one endpoint per port. The endpoints use `tls: skip`, so this is a plain L4
allowlist: no TLS interception, and non-HTTP traffic such as SSH is relayed.
Loopback, link-local and unspecified ranges are rejected here, because
OpenShell would otherwise block every connection to the whole endpoint.

Each --host-port adds an endpoint for `host.openshell.internal:<port>`, the
host machine. OpenShell allows it only through its trusted-gateway check
(rootless podman with pasta, where the alias is link-local), so a host port
cannot also appear in an IP allowlist entry.

Prints the policy as YAML on stdout.
"""

import argparse
import ipaddress
import sys
from typing import NoReturn

FORBIDDEN = [
    ipaddress.ip_network(n)
    for n in (
        "0.0.0.0/32",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "::/128",
        "::1/128",
        "fe80::/10",
    )
]


def die(msg) -> NoReturn:
    print(f"agent-harness: {msg}", file=sys.stderr)
    sys.exit(1)


def parse(path, entries):
    with open(path, encoding="utf-8") as f:
        for lineno, raw in enumerate(f, 1):
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) > 2:
                die(f"{path}:{lineno}: expected '<ip-or-cidr> [ports]'")
            try:
                net = ipaddress.ip_network(parts[0], strict=False)
            except ValueError as e:
                die(f"{path}:{lineno}: {e}")
            for bad in FORBIDDEN:
                if net.version == bad.version and net.overlaps(bad):
                    die(
                        f"{path}:{lineno}: {net} overlaps {bad}, which OpenShell never "
                        "allows (it would block the whole endpoint)"
                    )
            ports = [443]
            if len(parts) == 2:
                try:
                    ports = [int(p) for p in parts[1].split(",") if p]
                except ValueError:
                    die(f"{path}:{lineno}: bad port list '{parts[1]}'")
                if not ports or any(not 0 < p < 65536 for p in ports):
                    die(f"{path}:{lineno}: ports must be 1-65535")
            for p in ports:
                entries.setdefault(p, set()).add(str(net))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--uid", required=True)
    ap.add_argument("--gid", required=True)
    ap.add_argument("--conf", action="append", default=[])
    ap.add_argument("--host-port", action="append", type=int, default=[])
    a = ap.parse_args()

    for v in (a.uid, a.gid):
        if not v.isdigit() or int(v) == 0:
            die("refusing to run the sandbox as root")

    entries = {}
    for c in a.conf:
        parse(c, entries)

    host_ports = sorted(set(a.host_port))
    for p in host_ports:
        if not 0 < p < 65536:
            die(f"--host-port {p}: ports must be 1-65535")
        if p in entries:
            die(f"--host-port {p} is also an IP allowlist port; use one or the other")

    out = [
        "version: 1",
        "filesystem_policy:",
        "  include_workdir: true",
        # Listed explicitly: baseline paths are only added when a network
        # rule exists, and the harness lives in /nix/store either way.
        "  read_only: [/nix/store, /usr, /lib, /lib64, /bin, /etc, /proc, /dev/urandom]",
        # /dev/shm: Chromium (playwright MCP) needs shared memory.
        "  read_write: [/tmp, /dev/null, /dev/shm]",
        "landlock:",
        "  compatibility: hard_requirement",
        "process:",
        f'  run_as_user: "{a.uid}"',
        f'  run_as_group: "{a.gid}"',
    ]
    if entries or host_ports:
        out += ["network_policies:", "  allowlist:", "    endpoints:"]
        for port in host_ports:
            out += [
                "      - host: host.openshell.internal",
                f"        port: {port}",
                "        tls: skip",
            ]
        for port in sorted(entries):
            out += [
                f"      - port: {port}",
                "        tls: skip",
                "        allowed_ips:",
            ]
            out += [f'          - "{n}"' for n in sorted(entries[port])]
        # Any process in the sandbox: the allowlist is per destination, not
        # per binary (git, the harness, and tools it spawns all need it).
        out += ["    binaries:", '      - path: "/**"']
    else:
        print("agent-harness: allowlist is empty; sandbox has no network", file=sys.stderr)
    print("\n".join(out))


main()
