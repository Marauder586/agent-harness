"""Turn a host dev shell environment into a shell file for the sandbox.

Usage:
  devshell-env.py --json FILE              [--workspace SRC DST]
  devshell-env.py --direnv BASE_ENV NEW_ENV [--workspace SRC DST]

--json reads `nix print-dev-env --json` output and keeps its exported
variables. --direnv reads two `env -0` dumps, taken with
`direnv exec / env -0` (the shell's environment with any loaded direnv
state reverted) and `direnv exec "$PWD" env -0`, and keeps what the .envrc
added or changed.

Variables that describe the host session (HOME, TERM, XDG_*, SSH_*, ...),
the build sandbox (TMPDIR, NIX_BUILD_TOP, ...) or direnv itself are
dropped. --workspace rewrites the host project path SRC to DST, where the
project is mounted in the sandbox.

PATH is handled on its own: the dev shell's new entries are prepended to
the sandbox PATH, keeping only /nix/store paths and paths inside the
workspace (anything else does not exist in the sandbox; dropped entries are
listed on stderr).

Prints a POSIX shell file on stdout that `agent-launch` sources:
  [ -n "${NAME+x}" ] || export NAME='value'    # sandbox's own value wins
  export PATH='entries'"${PATH:+:$PATH}"
Prints nothing when the dev shell changes nothing.
"""

import argparse
import json
import re
import shlex
import sys

DROP = {
    # The host session.
    "HOME", "USER", "LOGNAME", "SHELL", "PWD", "OLDPWD", "SHLVL", "COLORTERM",
    "DISPLAY", "HOSTNAME", "PPID", "UID", "BASHOPTS", "SHELLOPTS", "TZ", "_",
    # Temp dirs and build-sandbox leftovers (nix develop drops these too).
    "TMP", "TMPDIR", "TEMP", "TEMPDIR", "NIX_BUILD_TOP", "NIX_LOG_FD",
    "NIX_ENFORCE_PURITY", "NIX_REMOTE",
    # Set by direnv / handled separately.
    "PATH",
}
DROP_PREFIXES = (
    "TERM", "WAYLAND_", "DBUS_", "XDG_", "SSH_", "GPG_", "DIRENV_", "__",
    "OPENSHELL_",
)
# stdenv's placeholder for "no CA bundle": it would break TLS in the sandbox.
DROP_VALUES = {"/no-cert-file.crt"}
NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")


def read_env0(path):
    with open(path, "rb") as f:
        data = f.read().decode("utf-8", "surrogateescape")
    env = {}
    for item in data.split("\0"):
        k, sep, v = item.partition("=")
        if sep:
            env[k] = v
    return env


def from_json(path):
    with open(path, encoding="utf-8") as f:
        variables = json.load(f).get("variables", {})
    env = {
        k: v["value"]
        for k, v in variables.items()
        if v.get("type") == "exported" and isinstance(v.get("value"), str)
    }
    return env, [], env.get("PATH", "")


def from_direnv(base_path, new_path):
    base, new = read_env0(base_path), read_env0(new_path)
    changed = {k: v for k, v in new.items() if base.get(k) != v}
    base_dirs = base.get("PATH", "").split(":")
    return changed, base_dirs, new.get("PATH", "")


def main():
    ap = argparse.ArgumentParser()
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--json")
    src.add_argument("--direnv", nargs=2, metavar=("BASE_ENV", "NEW_ENV"))
    ap.add_argument("--workspace", nargs=2, metavar=("SRC", "DST"))
    a = ap.parse_args()

    if a.json:
        env, base_dirs, path = from_json(a.json)
    else:
        env, base_dirs, path = from_direnv(*a.direnv)

    remap = lambda v: v  # noqa: E731
    keep = lambda d: d.startswith("/nix/store/")  # noqa: E731
    if a.workspace:
        ws_src, ws_dst = (p.rstrip("/") or "/" for p in a.workspace)
        pat = re.compile(r"(?<![^\s:=])" + re.escape(ws_src) + r"(?=$|[/:\s])")
        remap = lambda v: pat.sub(lambda _: ws_dst, v)  # noqa: E731
        keep = lambda d: d.startswith(("/nix/store/", ws_dst + "/")) or d == ws_dst  # noqa: E731

    out = []
    for k in sorted(env):
        v = env[k]
        if k in DROP or k.startswith(DROP_PREFIXES) or v in DROP_VALUES:
            continue
        if not NAME.match(k):
            continue
        out.append(f'[ -n "${{{k}+x}}" ] || export {k}={shlex.quote(remap(v))}')

    seen = set(base_dirs)
    dirs, dropped = [], []
    for d in path.split(":"):
        if not d or d in seen:
            continue
        seen.add(d)
        d = remap(d)
        if keep(d):
            dirs.append(d)
        else:
            dropped.append(d)
    if dropped:
        print(
            "agent-harness: dev shell PATH entries outside /nix/store and the project, "
            "left out: " + ":".join(dropped),
            file=sys.stderr,
        )
    if dirs:
        out.append(f'export PATH={shlex.quote(":".join(dirs))}"${{PATH:+:$PATH}}"')

    if out:
        print("# agent-harness: dev shell environment (generated on the host)")
        print("\n".join(out))


main()
