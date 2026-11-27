"""Generate an OpenShell sandbox policy.

Usage:
  policy-gen.py --uid UID --gid GID [--network-policies FILE]
                [--read-write PATH]...

--network-policies names a JSON file (from the Nix store) holding an
OpenShell `network_policies` map, in OpenShell's own schema:

    {"gitlab": {"endpoints": [{"host": "gitlab.example.com", "port": 443}],
                "binaries": [{"path": "/**"}]}}

It is copied into the policy unchanged. OpenShell validates it when the
sandbox is created; only the shape (a map of objects) is checked here.

This script owns the rest of the policy: the filesystem rules, Landlock and
the process identity, which the wrapper must control.

Prints the policy on stdout as JSON, which is valid YAML.
"""

import argparse
import json
import os
import sys
from typing import NoReturn


def die(msg) -> NoReturn:
    print(f"agent-harness: {msg}", file=sys.stderr)
    sys.exit(1)


def load_network_policies(path):
    with open(path, encoding="utf-8") as f:
        policies = json.load(f)
    if not isinstance(policies, dict) or not all(
        isinstance(k, str) and isinstance(v, dict) for k, v in policies.items()
    ):
        die(f"{path}: network_policies must be a map of named policy objects")
    return policies


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--uid", required=True)
    ap.add_argument("--gid", required=True)
    ap.add_argument("--network-policies")
    # Extra writable paths, e.g. the project mount. Listed explicitly so a
    # custom workspace.target outside the workdir (/sandbox) stays writable.
    ap.add_argument("--read-write", action="append", default=[])
    a = ap.parse_args()

    for v in (a.uid, a.gid):
        if not v.isdigit() or int(v) == 0:
            die("refusing to run the sandbox as root")

    for p in a.read_write:
        if not p.startswith("/") or "\n" in p or os.path.normpath(p) == "/":
            die(f"--read-write {p!r}: must be an absolute path other than /")

    policy = {
        "version": 1,
        "filesystem_policy": {
            "include_workdir": True,
            # Listed explicitly: baseline paths are only added when a network
            # rule exists, and the harness lives in /nix/store either way.
            # A path given with --read-write (e.g. /nix/store, when it is a
            # writable overlay) is left out here.
            "read_only": [
                p
                for p in ["/nix/store", "/usr", "/lib", "/lib64", "/bin", "/etc", "/proc", "/dev/urandom"]
                if p not in {os.path.normpath(q) for q in a.read_write}
            ],
            # /dev/shm: Chromium (playwright MCP) needs shared memory.
            "read_write": ["/tmp", "/dev/null", "/dev/shm"]
            + [os.path.normpath(p) for p in a.read_write],
        },
        "landlock": {"compatibility": "hard_requirement"},
        "process": {"run_as_user": a.uid, "run_as_group": a.gid},
    }

    network = load_network_policies(a.network_policies) if a.network_policies else {}
    if network:
        policy["network_policies"] = network
    else:
        print("agent-harness: no network policies; sandbox has no network", file=sys.stderr)
    json.dump(policy, sys.stdout, indent=2)
    print()


main()
