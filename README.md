# agent-harness

Run coding-agent harnesses (Claude Code and Pi today) inside [OpenShell](https://github.com/ai-openshell/openshell) sandboxes from a Nix config. Each sandbox can reach only what its OpenShell network policies allow. Skills, MCP servers and LLM endpoints are declared once and wired into every harness you enable.

What you get on a host:

- A command per enabled harness, by default `agent-<harness>` (`agent-pi`, `agent-claude-code`; rename it with `command`). Run it from a project directory: the directory is mounted into a fresh sandbox, and the harness starts there.
- Sandbox images built by Nix, with the harness, its skills, extensions, MCP servers and tools baked in. Nothing is downloaded inside the sandbox at run time.
- Optionally, a local [Hindsight](https://hindsight.vectorize.io) server that gives agents long-term memory.

Contents:

1. [Wire it into your config](#wire-it-into-your-config)
2. [Configure it](#configure-it)
3. [What's bundled](#whats-bundled)
4. [Extend it](#extend-it)
5. [Maintenance](#maintenance)

---

## Wire it into your config

### 1. Prerequisites

On home-manager the flake runs the OpenShell gateway for you (`openshell.gateway`, on by default): a systemd user service `openshell-gateway`, built from the same source and version as the `openshell` CLI, on `https://127.0.0.1:17670` with mTLS, registered with the CLI as `openshell`. You only need:

- **x86_64-linux.** The default `image.base` is an amd64 digest; on aarch64, set `image.base` to an arm64 image.
- **A container engine**, with its CLI on your PATH (the wrapper runs `podman image inspect` and `load`). Rootless podman is recommended, and Hindsight requires it. On NixOS, `virtualisation.podman.enable = true`: it provides the podman 5.x user API socket (`podman.socket`) the gateway's driver talks to, and cgroups v2. Set `openshell.engine` to match (default `"docker"`).
- **Non-NixOS (standalone home-manager):** podman 5.x from the distribution (it brings the `podman.socket` user unit and needs cgroups v2), `/etc/subuid` and `/etc/subgid` entries for your user, and the distribution's setuid `newuidmap`/`newgidmap` (`uidmap` or `shadow-utils`; don't put Nix's `shadow` on your profile PATH). Run `systemctl --user enable --now podman.socket`. A podman installed through home-manager ships no enabled `podman.socket`, and the gateway only `Wants=` it, so link the package's units:

  ```nix
  xdg.configFile = let u = "${pkgs.podman}/share/systemd/user"; in {
    "systemd/user/podman.socket".source = "${u}/podman.socket";
    "systemd/user/podman.service".source = "${u}/podman.service";
    "systemd/user/sockets.target.wants/podman.socket".source = "${u}/podman.socket";
  };
  ```

  The gateway and Hindsight services find podman in `/run/wrappers/bin`, `/run/current-system/sw/bin`, the home-manager profile's `bin`, `/usr/bin` and `/bin`. Many distributions have no firewall by default: block port 9077 (Hindsight, unauthenticated, all addresses), 9999 (Hindsight dashboard, when enabled) and the gateway's 17670 on the LAN address.
- **Optional: lingering** (`users.users.<you>.linger = true` on NixOS, `loginctl enable-linger $USER` elsewhere) keeps the gateway running after you log out.

The service starts with your session, and each sandboxed run starts it if it isn't running (waiting up to 30 s for the port; on failure the wrapper prints a `journalctl` hint and exits 1). Check it with `systemctl --user status openshell-gateway` and `openshell status` (read its output: the exit code is 0 even when the gateway is unreachable). Logs: `journalctl --user -u openshell-gateway`.

**Your own gateway instead** (a remote gateway, OpenShell's installer, a gateway you already run): set `openshell.gateway.enable = false`, register it with `openshell gateway add`, and check `openshell status`. Its driver must allow bind mounts: the current directory (read-write at `/sandbox/work/<dirname>`; see `workspace.target`), the per-project state directory (read-write at `/sandbox/.persist`, see [Sessions](#sessions)) and, for [dev shells](#dev-shells), the host's `/nix/store` and the captured environment (read-only):

```toml
[openshell.drivers.podman]   # or .docker
enable_bind_mounts = true
```

Without bind mounts, set `programs.agent-harness.workspace.mount = false`, `harnesses.<h>.persist = false` and `devshell.auto = false`, don't pass `--devshell`, and copy files in and out with `openshell sandbox upload` and `openshell sandbox download`.

- **Rootless podman:** the sandbox runs as your host UID and GID, which keeps files in the mounted project owned by you. Rootless podman maps your UID to root inside containers, so the sandbox user could not write the project; the flake's gateway sets `userns = "keep-id"` on the podman driver to map it to itself. With your own gateway, add that line to its `[openshell.drivers.podman]` table.

### 2. Add the flake input

```nix
# flake.nix
inputs.agent-harness = {
  url = "github:Marauder586/agent-harness";
  # Optional: share your nixpkgs-unstable. Omit to use the flake's own pin.
  inputs.nixpkgs.follows = "nixpkgs-unstable";
};
```

For a local checkout, use `url = "git+file:///home/<you>/agent-harness"`, or keep the GitHub URL and test local edits with `--override-input agent-harness path:$HOME/agent-harness`.

The flake exports one home-manager module, covering harnesses, LLM providers and Hindsight: `modules.homeManager.agent-harness`, also available as `homeManagerModules.default`.

### 3. Import the modules

Pick the shape that matches your config.

**Dendritic / flake-parts config** (like `~/nix-config`): wrap it in your own aspect, so a host turns it on by importing that aspect.

```nix
# modules/home/pi-agent.nix
{inputs, ...}: {
  flake.modules.homeManager.pi-agent = {
    imports = [inputs.agent-harness.modules.homeManager.agent-harness];
    programs.agent-harness = {
      openshell.engine = "podman";
      harnesses.pi.enable = true;
    };
  };
}

# hosts/<host>.nix, inside home-manager.users.<you>.imports:
config.flake.modules.homeManager.pi-agent
```

**Plain flake, home-manager as a NixOS module:**

```nix
nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
  modules = [
    home-manager.nixosModules.home-manager
    {
      home-manager.users.me = {
        imports = [inputs.agent-harness.homeManagerModules.default];
        programs.agent-harness = {
          openshell.engine = "podman";
          harnesses.pi.enable = true;
        };
      };
    }
  ];
};
```

**Standalone home-manager (any distribution):**

```nix
homeConfigurations.me = home-manager.lib.homeManagerConfiguration {
  inherit pkgs;
  modules = [
    inputs.agent-harness.homeManagerModules.default
    {
      programs.agent-harness = {
        openshell.engine = "podman";
        harnesses.pi.enable = true;
      };
    }
  ];
};
```

### 4. Give the sandbox a model and a network

A sandbox with no network policies has no network, and a harness with no model can't do anything. The smallest working Pi setup points it at one OpenAI-compatible model endpoint:

```nix
programs.agent-harness = {
  openshell.engine = "podman";            # the engine your gateway uses
  harnesses.pi = {
    enable = true;
    skills = ["commit-message"];
  };
  llm = {
    providers.local = {
      baseUrl = "http://10.0.0.20:8000/v1"; # any OpenAI-compatible server
      models = [{id = "my-model";}];
    };
    default = {provider = "local"; model = "my-model";};
  };
};
```

The provider gets a network policy for its address and port automatically. See [LLM providers](#llm-providers).

### 5. Rebuild and run

```shell
sudo nixos-rebuild switch --flake .#myhost   # or: home-manager switch --flake .#me
cd ~/Projects/something
agent-pi                                      # the default `command`; arguments are passed to the harness
```

The first launch loads the harness image into the engine, which takes a moment. After that each launch creates a new sandbox, named `<harness>-<directory>-<6 hex>` (cut to OpenShell's 19-character limit; for `claude-code` the directory part is dropped), and removes it when the harness exits. With `keep = true` it stays: find it with `openshell sandbox list` and reattach with `openshell sandbox connect`.

---

## Configure it

Everything lives under `programs.agent-harness`.

### Harnesses

`harnesses.<name>` exists for each file in `modules/harnesses/` (today `pi` and `claude-code`).

```nix
programs.agent-harness.harnesses.pi = {
  enable = true;
  skills = ["commit-message" "gitlab" "caveman"];
  extensions = ["ws-edit" "mcp-adapter" "subagents"];
  mcpServers = ["playwright" "rea"];
  settings = {defaultThinkingLevel = "high";};   # merged into Pi's settings.json
};

programs.agent-harness.harnesses.claude-code = {
  enable = true;
  skills = ["gitlab" "commit-message"];
  providers = ["anthropic"];        # OpenShell provider holding the API key
};
```

| Option | Default | Purpose |
|---|---|---|
| `enable` | `false` | Build the image and install the command. |
| `command` | `agent-<name>` | Name of the sandboxed command installed on the host (e.g. `"pi"`). |
| `skills` | `[]` | Skills to install. Checked at evaluation time against [what's bundled](#skills). |
| `extensions` | `[]` | Add-ons from `extensions/<harness>/`. |
| `extraExtensions` | `[]` | Extension paths from outside `extensions/`, such as one built in your own config. |
| `mcpServers` | `[]` | MCP servers from `mcp-servers/`. |
| `settings` | `{}` | Merged over the harness defaults: Claude Code's `--settings`, or Pi's `settings.json`. |
| `package` | unstable build | The harness CLI. |
| `extraPackages` | `[]` | Extra tools on PATH, in the sandbox and for the host command. |
| `environment` | `{}` | Fixed variables set in the sandbox and for the host command. Readable by the agent, so no secrets. |
| `providers` | `[]` | OpenShell providers to attach. The safe way to pass API keys: the agent sees a placeholder. |
| `envFrom` | `[]` | Host variables copied in. The agent can read them, so don't use this for secrets. |
| `autoProviders` | `false` | Let OpenShell attach providers it detects. |
| `persist` | `true` | Keep per-project state across sandboxed runs, for harnesses that declare `persists` (today: Pi; see [Sessions](#sessions)). |
| `keep` | `false` | Keep the sandbox after exit. |
| `extraArgs` | `[]` | Arguments always passed to the harness. |
| `host.enable` / `host.command` / `host.extensions` / `host.environment` | off / harness name / `[]` / `{}` | The [unsandboxed host command](#unsandboxed-host-command). `host.command` must differ from `command`. |

Shared options: `secretEnvFiles` (variable name to host file, names validated; see [API keys](#llm-providers)), `openshell.engine` (default `"docker"`; `"docker"` or `"podman"`, must match the gateway's driver; if `docker` on the host is podman's shim, use `"podman"`), `openshell.package`, `workspace.mount` and `workspace.target` (default `null`: the project is mounted at `/sandbox/work/<dirname>`. Hindsight names a project's memory bank after that directory name, so each project gets its own bank. Hindsight's path-based settings (`mapPathToBank`, `optInPaths`) see the sandbox path, not the host path. Set a fixed path to mount every project there; that puts every project in one Hindsight bank), `devshell.auto` (see [Dev shells](#dev-shells)), `nixStore.overlay.enable` and `nixStore.overlay.package` (see [Writable Nix store](#writable-nix-store)), `hostTools.enable` and `hostTools.variables` (see [Host tools](#host-tools)), `image.base` (default: a pinned amd64 `debian:bookworm-slim`) and the read-only `images` (each harness image's stream script).

### Gateway

`openshell.gateway` runs the local gateway as the systemd user service `openshell-gateway` while any harness is enabled.

| Option | Default | Purpose |
|---|---|---|
| `enable` | `true` | Run and register the gateway. Set `false` to bring your own. |
| `package` | this flake's build | `openshell-gateway`; keep its version equal to `openshell.package`. |
| `port` | `17670` | Loopback port of the mTLS API. |
| `settings` | see below | Written to `~/.config/openshell/gateway.toml`. |

`settings` defaults to `openshell.version = 1`, `bind_address = "127.0.0.1:<port>"`, `compute_drivers = [<engine>]`, `[openshell.drivers.<engine>] enable_bind_mounts = true` (the workspace and dev shell mounts) and, for podman, `userns = "keep-id"`; anything you set is merged over that. Extra `OPENSHELL_*` variables and secrets (such as `OPENSHELL_DB_URL`) go in `~/.config/openshell/gateway.env`.

On each start the service generates the local PKI if missing (`openshell-gateway generate-certs`: server certificate and CA under `~/.local/state/openshell/tls`, client bundle under `~/.config/openshell/gateways/openshell/mtls`), then runs `openshell gateway add https://127.0.0.1:<port> --local --name openshell` unless a gateway named `openshell` is already registered. If it is registered with another endpoint (e.g. after changing `port`), the service only logs a warning and leaves it: run `openshell gateway remove openshell` and restart the service. The TLS directory also holds the sandbox JWT signing key (`jwt/`), and the server certificate also covers `host.openshell.internal`. The API is loopback-only and needs the client certificate, which only your user can read, so other local users cannot drive it. For sandbox callbacks the rootless podman driver opens a second TLS listener on the same port of the host's default-route address, limited to the sandbox gRPC calls and authenticated with gateway-minted sandbox tokens; keep that port closed in the host firewall (the NixOS default).

### Unsandboxed host command

Sometimes you don't want the sandbox. A harness that supports it (today: Pi) can also install a plain host command with the same configuration:

```nix
programs.agent-harness.harnesses.pi = {
  enable = true;                       # agent-pi: sandboxed
  host = {
    enable = true;                     # pi: unsandboxed, same config
    extensions = ["claude-bridge"];    # loaded only by the host command
  };
};
```

To make plain `pi` the sandboxed one, rename both (they must differ; evaluation fails otherwise):

```nix
programs.agent-harness.harnesses.pi = {
  command = "pi";                      # sandboxed
  host.command = "pi-unleashed";       # unsandboxed
};
```

| | `agent-pi` (sandbox, default name) | `pi` (host, default name) |
|---|---|---|
| Runs as | your UID in an OpenShell sandbox | you, directly on the host |
| HOME | `/sandbox`, discarded on exit (unless `keep`), except the per-project `/sandbox/.persist` mount | your real HOME |
| Network | `network.policies` only | unrestricted |
| State dir (`$AGENT_HARNESS_STATE`) | `/sandbox/.pi` | `$XDG_STATE_HOME/agent-harness/pi` (default `~/.local/state/…`) |
| Pi config dir | `/sandbox/.pi/agent` | `$AGENT_HARNESS_STATE/agent`, rewritten each launch (stale `models.json`, `mcp.json` and `agents/` are removed); sessions persist. A hand-managed `~/.pi` is never touched. |
| Skills, extensions, MCP servers, LLM registry, Hindsight | same | same, plus `host.extensions` |
| MCP servers | as defined | built with `sandboxed = false`: `playwright` keeps Chromium's own sandbox and writes to `$AGENT_HARNESS_STATE/playwright-mcp` |
| `secretEnvFiles` (API keys) | passed with `--env` | exported into the process; never on a command line |

`host.environment` overrides `environment` for the host; Hindsight uses it to point the host command at `http://127.0.0.1:9077`. Harness tools go after your PATH; only a directory holding the harness binary itself goes first, so a child started by name (e.g. pi-subagents' `pi` fallback) gets the real harness, not a same-named sandboxed command. Claude Code has no host mode, because its launch writes skills into `~/.claude`. Dev shells apply only to the sandboxed command; the host command runs in your own shell environment.

### Sessions

The sandbox is deleted on exit, so per-project state lives on the host: `$XDG_STATE_HOME/agent-harness/<harness>-sandbox/projects/<first 16 hex of sha256(project path)>/` (its `.path` file names the project), mounted read-write at `/sandbox/.persist` and exported to the harness's launch as `$AGENT_HARNESS_PERSIST`. Only harnesses that declare `persists` get the mount (today: Pi, whose sessions live there, so `agent-pi -c`, `agent-pi --resume` and `/resume` work per project). Claude Code doesn't use it yet: its sessions live in `/sandbox/.claude` and are deleted with the sandbox. The directory is keyed by the host path, not by the project's directory name, so two projects with the same name stay apart. The agent can read and edit this directory. Sandboxed and host-command sessions stay separate (the host command keeps them under `$XDG_STATE_HOME/agent-harness/pi/agent`). Turn it off with `harnesses.<h>.persist = false`.

### Dev shells

Projects usually define their toolchain in a dev shell: a direnv `.envrc` (`use flake`, `use nix`, nix-direnv) or a flake's `devShells`. None of those tools exist in the sandbox, so the sandboxed command evaluates the dev shell **on the host** at launch and carries the result in:

1. The environment is captured on the host and filtered (see below).
2. It is written to a private temp directory (mode 0700, removed when the command exits), mounted read-only at `/sandbox/.devshell`. It never goes on a command line.
3. The host's `/nix/store` is bind-mounted read-only over the image's, so every store path the dev shell names exists in the sandbox. The image's own paths come from the host store too, and the installed command keeps them alive (GC-rooted through your profile).
4. `agent-launch` loads the file before the harness starts.

Nothing changes for a project without a dev shell: no store mount, no env file. The command prints one line saying where the dev shell came from.

**Which dev shell**, first match wins. Leading flags (the last one wins) override `AGENT_DEVSHELL`, which overrides detection:

| Source | What happens |
|---|---|
| `--devshell <installable>` or `--devshell=<installable>` | `nix print-dev-env --json <installable>`, e.g. `--devshell ~/src/foo#rust`. A failure aborts the launch. |
| `--no-devshell` | No dev shell. |
| `AGENT_DEVSHELL=<installable>` / `AGENT_DEVSHELL=none` | The same, from the environment. |
| `.envrc` that direnv applies to `$PWD` (parent directories count), with `direnv` on PATH | Loaded with `direnv exec`. Only if you have run `direnv allow`; otherwise the command prints `.envrc not allowed (direnv allow); starting without dev shell` and goes on without one (it does not fall back to the flake). |
| `./flake.nix` with `devShells.<system>.default` | `nix print-dev-env --json`. A flake without one is skipped silently. |

Automatic detection (the last two rows) is on by default; turn it off with `programs.agent-harness.devshell.auto = false`. The flags are recognised only as the **leading** arguments and are removed before the rest go to the harness, so `agent-pi --no-devshell -c` works, and `agent-pi -c --no-devshell` passes `--no-devshell` to Pi.

If direnv or `nix print-dev-env` fails during automatic detection, its error is shown and the agent starts without a dev shell: a broken `.envrc` should not lock you out of the agent, and the warning makes the missing tools obvious.

The `.envrc` is loaded with `direnv exec "$PWD" env` and compared with `direnv exec / env` (your environment with any loaded direnv state undone). Only what the `.envrc` adds or changes is passed in. This works the same whether or not your shell already has the project's direnv environment loaded, and the `.envrc` sees your own PATH, not the wrapper's.

**What is passed in:**

- Dropped: host-session and build-sandbox variables (`HOME`, `USER`, `LOGNAME`, `SHELL`, `PWD`, `OLDPWD`, `SHLVL`, `TERM*`, `COLORTERM`, `DISPLAY`, `WAYLAND_*`, `DBUS_*`, `XDG_*`, `SSH_*`, `GPG_*`, `TZ`, `HOSTNAME`, `PPID`, `UID`, `BASHOPTS`, `SHELLOPTS`, `_`, `NIX_REMOTE`), temp dirs (`TMP`, `TMPDIR`, `TEMP`, `TEMPDIR`, `NIX_BUILD_TOP`), `DIRENV_*`, `__*`, `OPENSHELL_*`, `NIX_ENFORCE_PURITY`, `NIX_LOG_FD`, stdenv's `/no-cert-file.crt` placeholder and names that aren't valid identifiers. With `print-dev-env`, only exported variables.
- Paths under the project directory are rewritten to `/sandbox/work/<dirname>`, or to `workspace.target` when set (only when `workspace.mount` is true).
- `PATH`: the dev shell's new entries go in front of the sandbox PATH. Only `/nix/store` entries and entries inside the project are kept; others (e.g. `~/.cargo/bin`) don't exist in the sandbox and are listed in a notice.
- **Precedence:** a dev shell variable is set only if the sandbox doesn't already have it, so the image, OpenShell itself, `envFrom` and `secretEnvFiles` win. The harness's `environment` is applied afterwards and wins too.

**Tradeoffs:**

- The agent can read the whole host Nix store (read-only). It is world-readable on the host anyway, but don't keep secrets in it.
- Everything the `.envrc` exports, including secrets from dotenv files, becomes visible to the agent.
- The `.envrc` runs on the host with your privileges, as it would in your shell, and only once you have allowed it with direnv. A flake dev shell is evaluated and built on the host.

**Limits:**

- There is no Nix daemon in the sandbox. With the [writable Nix store](#writable-nix-store) (the default with podman) the agent can still `nix build`, `nix develop` and `nix flake check` inside it; without it, add the tools to the dev shell instead.
- `print-dev-env` (the flake and `--devshell` paths) does not run the dev shell's `shellHook`; direnv's `use flake` does.
- Tools from outside the Nix store (asdf, pyenv, rustup, Homebrew) don't exist in the sandbox; neither do variables pointing at such paths. Dev shell entries in `/run/current-system` or `/nix/var/nix/profiles` are dropped too; [host tools](#host-tools) brings in your profiles.
- Automatic flake detection evaluates the flake on every launch (cached by Nix after the first time); use `--no-devshell` to skip it.

### Host tools

```nix
programs.agent-harness.hostTools.enable = true;
```

This puts your own Nix-installed tools in every sandbox: the system profile, home-manager's, `~/.nix-profile`. At each launch the wrapper reads a few path-list variables from your shell (`hostTools.variables`, default `PATH`, `MANPATH`, `INFOPATH`, `XDG_DATA_DIRS`, `TERMINFO_DIRS`, `LOCALE_ARCHIVE`):

1. Each entry is resolved through its symlinks. `/run/current-system/sw/bin`, `/etc/profiles/per-user/<you>/bin` and `~/.nix-profile/bin` all end in a `/nix/store/…/bin` directory.
2. Only entries that land in `/nix/store` are kept, in order, without duplicates. Everything else doesn't exist in the sandbox and is left out quietly: `/run/wrappers/bin` (setuid `sudo` and friends), `~/.local/bin`, `~/.cargo/bin`, `/usr/bin` on other distributions.
3. The result goes in the same private file as the dev shell's environment, at `/sandbox/.devshell/host-env`, and the host's `/nix/store` is mounted read-only.
4. The kept store paths are registered as GC roots for the length of the session (indirect roots in the wrapper's temp dir, gone when it exits). That is done with `nix-store --add-root`, when `nix-store` is on your PATH, so a switch plus garbage collection mid-session can't delete them.

Only the listed variables are read. The rest of your environment, tokens included, never reaches the sandbox this way.

**Precedence:** host PATH entries go **after** the sandbox's own PATH, so they only fill gaps. The harness, the base tools, skill and MCP tools (e.g. the `python3` with `anthropic` that `caveman-compress` needs) and the dev shell all win over a same-named host tool. The other variables are set only where the sandbox and the dev shell left them unset.

**Tradeoffs and limits:**

- The agent can read the whole host Nix store, as with dev shells. Don't keep secrets in it.
- Mounting the Nix daemon socket is deliberately not offered: builds would run on the host, and fixed-output derivations get the host's network, outside the network policies. The [writable Nix store](#writable-nix-store) runs Nix inside the sandbox instead.
- Programs that read host `/etc` (`/etc/nix/nix.conf`, `/etc/gitconfig`) see the image's Debian `/etc` instead.
- The paths are taken at launch. A tool installed while the sandbox runs needs a new session.

### Writable Nix store

```nix
programs.agent-harness.nixStore.overlay.enable = true;   # the default with openshell.engine = "podman"
```

Every sandbox gets a writable `/nix/store`, so agents can run `nix build`, `nix develop`, `nix shell` and `nix flake check` there, including on dev shells and flakes they just changed, without the Nix daemon:

1. `/nix/store` in the sandbox is a [fuse-overlayfs](https://github.com/containers/fuse-overlayfs) mount. The host's store is the read-only lower layer and a per-project upper layer is on the host, under `$XDG_STATE_HOME/agent-harness/nix-overlay/<first 16 hex of sha256(project path)>/` (its `.path` file names the project). Every host store path is visible. New paths go to the upper layer and stay for the next session of that project, for every harness.
2. The wrapper mounts it inside rootless podman's namespace (`podman unshare`), where the gateway's containers see it. The mount stays up between sessions and is shared by concurrent sessions of the same project. Kernel overlayfs can't be used here: an unprivileged mount can't turn on `redirect_dir`, and without it `rename()` of a new directory into the store fails with `EXDEV`, which Nix can't recover from.
3. Inside, `agent-launch` sets `NIX_CONFIG` to Nix's experimental [local-overlay store](https://nix.dev/manual/nix/latest/store/types/experimental-local-overlay-store). The lower store and its database are mounted read-only at `/sandbox/.nix-store-overlay/lower` and `lower-state`; the upper layer and its own database are at `/sandbox/.nix-store-overlay/upper` and `state`. The image ships its own `nix` (`nixStore.overlay.package`, default `pkgs.nix`).
4. Builds run as the agent's user with `sandbox = false`: OpenShell is the sandbox. Substitution, flake fetching and fixed-output downloads all run inside it, through OpenShell's proxy, under the [network policies](#network-policies). `NIX_SSL_CERT_FILE` is set to OpenShell's CA bundle so `nix` trusts its TLS inspection.

Allow what Nix fetches in `network.policies`: `cache.nixos.org` for substitution, `channels.nixos.org` and `releases.nixos.org` for `nixpkgs#…`, `api.github.com`, `github.com` and `codeload.github.com` for `github:` inputs, and the source hosts of anything that must be built. Fixed-output downloads are run by `curl` or `git` from the store, not `nix`, so their `binaries` must include those. They may also use nixpkgs' own CA bundle instead of OpenShell's, so an endpoint with `protocol = "rest"` (TLS inspection) can fail for them; use an uninspected endpoint (no `protocol`) for build source hosts.

**Tradeoffs and limits:**

- The agent can read the whole host store, as with dev shells and host tools.
- Garbage-collecting the host store can delete paths a project's upper layer depends on. Nix requires the lower store to only grow. If a project's store breaks, delete its `nix-overlay/<hash>` directory (unmount it first with `podman unshare umount <dir>/merged`, or let a reboot do it).
- Paths built in the sandbox exist only in that project's upper layer, not in the host store. Your own shell and direnv build them again on the host.
- Builds run on CPU and disk inside the sandbox, at fuse-overlayfs speed. The upper layer grows with what agents build; it is not garbage-collected.
- The local-overlay store is an experimental Nix feature.
- Needs `openshell.engine = "podman"` (rootless) and `/dev/fuse` on the host.

### LLM providers

Define each model endpoint once. Every provider is wired into every enabled harness, and `default` picks the model they start with.

```nix
programs.agent-harness.llm = {
  providers.sparks = {
    displayName = "Sparks";
    baseUrl = "http://10.0.0.20:8000/v1";       # OpenAI-compatible (vLLM, SGLang, Ollama)
    apiKeyFile = "/run/secrets/sparks-key";      # optional
    models = [
      {
        id = "glm-5.3";
        reasoning = true;
        contextWindow = 200000;
        maxTokens = 32768;
      }
    ];
    # compat.thinkingFormat = "qwen-chat-template";   # Pi override, if auto-detection is wrong
  };
  default = {provider = "sparks"; model = "glm-5.3";};
};
```

| Target | What it gets |
|---|---|
| Pi | A `models.json` provider per entry, and `default` as `defaultProvider` / `defaultModel`. |
| Claude Code | Only when `default` is an `api = "anthropic-messages"` provider: `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`, and `ANTHROPIC_AUTH_TOKEN` when the provider has an `apiKeyFile`. Other APIs can't drive Claude Code. |
| Hindsight | `default` becomes its extraction LLM. `hindsight.llm.*` overrides it. |
| Network | The provider gets the network policy `llm-<name>`: one endpoint for the `baseUrl`'s host and port (80/443 if omitted), for every binary, uninspected. A literal IPv4 host also gets `allowed_ips` for exactly that address. Override it with the provider's `network`, an entry in OpenShell's schema, or set `network = null` when another policy covers the endpoint. Loopback, link-local and `localhost` fail evaluation, since the sandbox can never reach them: for a model served on this machine, listen on a LAN address and use that. |

Provider fields: `baseUrl`, `api` (`openai-completions`, `openai-responses`, `anthropic-messages`), `apiKeyFile`, `models`, `compat` (Pi compatibility overrides), `displayName`, `network`. Model fields: `id`, `name`, `reasoning`, `input`, `contextWindow`, `maxTokens`, `extra` (merged into the Pi model entry: `cost`, `samplingParams`, and so on).

**API keys:** `apiKeyFile` becomes a `secretEnvFiles` entry: it is read on the host at each launch and passed into the sandbox as `AGENT_LLM_<NAME>_API_KEY`. The agent can read it, and it appears in the host process list while the launcher runs. Keep the file out of the Nix store (`/run/secrets/…` from sops-nix or agenix, or a file in your home directory). For a key the agent must not see, attach an OpenShell provider (`harnesses.<h>.providers`) instead and leave `apiKeyFile` unset.

### Network policies

A sandbox can reach only what `programs.agent-harness.network.policies` allows, plus the entries LLM providers (`llm-<name>`) and Hindsight (`hindsight`) add. Everything else is denied. The option is OpenShell's own [`network_policies`](https://github.com/ai-openshell/openshell/blob/main/docs/reference/policy-schema.mdx) map, in OpenShell's schema, copied into every sandbox's policy unchanged. OpenShell validates it when the sandbox is created. The module checks only that each name is plain (letters, digits, `_`, `.`, `-`) and that each entry has `endpoints` and `binaries`, which OpenShell requires. The policies are part of your Nix config and baked into the store, so neither you nor the agent can widen them at run time.

```nix
programs.agent-harness.network.policies = {
  # A named service: the requested name must match, OpenShell resolves it
  # and checks the address. `protocol = "rest"` inspects each HTTPS request
  # (method, path), with `access` or explicit `rules`.
  gitlab = {
    endpoints = [{ host = "gitlab.example.com"; port = 443; protocol = "rest"; access = "read-write"; }];
    binaries = [{ path = "/**"; }];
  };
  # A name and an address: both must match.
  inference = {
    endpoints = [{ host = "llm.lan"; port = 8000; allowed_ips = [ "10.0.0.9/32" ]; }];
    binaries = [{ path = "/**"; }];
  };
  # Addresses only (hostless): any name that resolves into the range passes.
  # Plain TCP relay, e.g. for SSH.
  lan-ssh = {
    endpoints = [{ port = 22; tls = "skip"; allowed_ips = [ "10.0.1.0/24" ]; }];
    binaries = [{ path = "/**"; }];
  };
};
```

How OpenShell treats the three forms:

| | `host` | `host` and `allowed_ips` | hostless `allowed_ips` |
|---|---|---|---|
| What must match | The requested name, exactly or by a first-label wildcard (`*.example.com`). | Name and resolved address. | Only the resolved address, whatever the name. |
| Private ranges (10.x, 192.168.x) | An exact host may resolve to them; a wildcard may not. | Only the listed ones. | Only the listed ones. |
| Request inspection (`protocol = "rest"` and the others), provider credentials | Yes | Yes | No |
| `protocol = "tcp"` (transparent, non-HTTP) | Yes | Yes | No |

In every form, loopback, link-local (including `169.254.169.254`) and `0.0.0.0` are always blocked. `binaries` limits which programs may use the entry (`/**` is any). Names are resolved by OpenShell's supervisor, not the agent, through the container's `/etc/hosts` and `/etc/resolv.conf`, which podman derives from the host's. The supervisor connects only to the addresses it checked.

Prefer exact `host` entries, with `protocol = "rest"` and narrow `rules` where the agent shouldn't have full access: an allowed host is also a path for data to leave (pushing to any repository, posting a gist). Wildcards let the agent encode data in DNS lookups. Hostless `allowed_ips` matches any name that resolves into the range.

`network.allow` and `network.hostPorts` were removed. Setting either fails with the equivalent `network.policies` entry. A service on the host is an entry with `endpoints = [{ host = "host.openshell.internal"; port = <port>; tls = "skip"; }]`. This works only with a rootless podman gateway: OpenShell lets the alias through only when it maps to pasta's link-local host address. The service must listen on a non-loopback address, because pasta delivers these connections to the host's own interface address.

### Memory (Hindsight)

```nix
programs.agent-harness.hindsight.enable = true;
```

This gives agents long-term memory from [Hindsight](https://hindsight.vectorize.io), served from this machine. Each host runs its own server and keeps its own memory.

- **Server:** the pinned `hindsight-api` image runs as the systemd user service `agent-hindsight` under rootless podman, on port 9077 (`hindsight.port`). Memory lives in the podman volume `agent-hindsight-data`. The first start pulls a large image (roughly 4 GB), and the server uses on the order of 1.6 GB of RAM (approximate figures).
- **Models:** embeddings use `BAAI/bge-small-en-v1.5` (33M parameters) and reranking `hindsight-ai/hs-rerank-1` (114M). Both are bundled in the image and run on CPU, offline. Knowledge-bank embeddings reuse bge-small instead of the 744M EmbeddingGemma 2 default.
- **LLM:** fact extraction and reflection need a chat model. It defaults to `llm.default`. Its provider type is `anthropic` for an `anthropic-messages` default, else `openai`. Override with `hindsight.llm.{provider,baseUrl,model,apiKeyFile}`. With no LLM, the server is not started (rebuilds show a warning), and agents run without memory. A keyless endpoint gets the dummy key `none`, which the server requires. `hindsight.mentalModelRefreshLLMMaxConcurrent` caps how many mental model refresh LLM calls the server runs at once (`HINDSIGHT_API_MENTAL_MODEL_REFRESH_LLM_MAX_CONCURRENT`), `hindsight.llmMaxConcurrent` all LLM calls server-wide (`HINDSIGHT_API_LLM_MAX_CONCURRENT`), and `hindsight.{workers,workerMaxSlots}` size the background worker pool and each worker's slots (`HINDSIGHT_API_WORKERS`, `HINDSIGHT_API_WORKER_MAX_SLOTS`); null (the default) uses the server's own default for each.
- **Agents:** `hindsight.enable` adds the `hindsight` extension to `extensions` of each harness in `hindsight.harnesses` (default: every harness that has one, today `pi`), pointed at `http://host.openshell.internal:9077`. The extension is `extensions/pi/hindsight/`: `dist/pi.js` from the pinned `@vectorize-io/hindsight-coding-agents` npm tarball, plus the helper scripts it spawns. Recall is injected before each turn, and the transcript is saved after it. Agents get `HINDSIGHT_AUTO_UPDATE=false`. `hindsight.maxParallelRetains` caps how many retain (memory-save) queries the extension sends to the server at once (default: the extension's own 10); lower it to soften the burst of extraction LLM calls a session end can trigger. Extra server settings go in `hindsight.extraEnvironment` (`HINDSIGHT_API_*`; not for secrets, since they appear on the podman command line). Pinned: image `hindsight-api` 1.3.0, extension `hindsight-coding-agents` 0.9.0.
- **Mental model refreshes:** the extension's pages (Hindsight mental models) refresh on a cron by default. `hindsight.mentalModels.trigger` picks `"cron"` (default), `"auto-refresh"` (after every consolidation, so whenever new memories are processed: most current, one LLM synthesis per page each time) or `"manual"`. `hindsight.mentalModels.cron` sets the schedule (default `"H * * * *"`, UTC). An `H` field gets a per-page value hashed from the bank and page name, so pages don't refresh all at once: `"H H * * *"` is daily. A scheduled tick is skipped when nothing new arrived. Every session re-syncs the extension's existing pages to these settings. They reach the extension as `HINDSIGHT_PAGE_TRIGGER_TYPE` and `HINDSIGHT_PAGE_TRIGGER_CRON`, which a `~/.hindsight/coding-agent.json` on the host would override for host commands. Server side, `hindsight.mentalModels.minRefreshIntervalSeconds` sets a floor between two refreshes of one model, whatever triggered them (`HINDSIGHT_API_MENTAL_MODEL_MIN_REFRESH_INTERVAL_SECONDS`, server default 0). `hindsight.mentalModels.refreshTickSeconds` sets how often the server looks for due cron refreshes (`HINDSIGHT_API_MENTAL_MODEL_REFRESH_TICK_SECONDS`, server default 300). Null leaves the server default.
- **Dashboard:** `hindsight.dashboard.enable = true` runs the Hindsight Control Plane, the web UI for browsing banks, entities and recall results (`hindsight.dashboard.port`, default 9999). It is a second, stateless container (systemd user service `agent-hindsight-dashboard`, pinned `hindsight-control-plane` image) that proxies the API server-side, so the browser only ever talks to the dashboard. It runs with host networking to reach the API's published port without podman network setup. The dashboard has no login; set `hindsight.dashboard.accessKeyFile` to a file holding an access key. It needs the server (and therefore an LLM) to be configured. Both Hindsight images are pinned by digest in their `image` options.
- **CLI:** `hindsight.enable` also puts the `hindsight` CLI in your own terminal: the prebuilt release binary, pinned to the same version as the server images. It is preset to the local server with `HINDSIGHT_API_URL=http://127.0.0.1:9077` (follows `hindsight.port`); that variable wins over everything, so set your own (or a `HINDSIGHT_PROFILE`) to reach another server or a Hindsight Cloud bank.
- **Network:** adds the network policy `hindsight`, an endpoint for `host.openshell.internal:<port>` with `tls: skip`, so this requires `openshell.engine = "podman"` with a rootless gateway.

> [!WARNING]
> The Hindsight server has no authentication and listens on every host address. Keep port 9077 closed in the host firewall (and 9999, the dashboard's port, when `hindsight.dashboard.enable` is on without `dashboard.accessKeyFile`). NixOS's firewall is on by default and does not open it.

Check the server with `systemctl --user status agent-hindsight` and `curl http://127.0.0.1:9077/health`; the dashboard (when enabled) with `systemctl --user status agent-hindsight-dashboard` and `http://127.0.0.1:9999`.

---

## What's bundled

### Skills

| Source | Skills | Tools added to the sandbox |
|---|---|---|
| `skills/` (this repo) | `commit-message`, `gitlab` | Declared in each skill's `skill.nix`. |
| `claude-plugins-official` | `frontend-design` | none |
| `impeccable` (`skill-v4.10.0`, generic `.agents/` build) | `impeccable` | The engine binary. Version and hash are read from the skill's own `VERSION` and `engine-checksums.txt`, so the skill never downloads it. |
| `caveman` (`v4.2.0`) | `caveman`, `ultracave`, `megacave`, `cavecrew`, `caveman-commit`, `caveman-review`, `caveman-compress`, `caveman-explore`, `caveman-help`, `investigate-first`, `lean-build`, `migration`, `safe-refactor`, `surgical-patch`, `verify-and-stop`, plus the Cloud skills `caveman-setup`, `-manage`, `-learn`, `-optimize`, `-discover`, `-evidence-review`, `-stats` | python3 with `anthropic` and `tiktoken`, for `caveman-compress`. The Cloud skills need the `caveman` CLI and Caveman Cloud, which are not installed. |
| `rea-agents` (npm `6.10.1`) | `reverse-engineer-anything` | None. Pair it with the `rea` MCP server, built from the same tarball. |

The upstream skills are the skill content of the Claude Code plugins in nix-config's `remote-ai.nix`. Plugin parts that aren't skills are not covered: the `*-lsp` language-server configs, caveman's mode hooks and status line, the format-on-edit hook, and `no-agent-summary.js`. Claude Code versions of those would go in `extensions/claude-code/`, and Pi versions in `extensions/pi/`.

### MCP servers

| Name | What it is |
|---|---|
| `playwright` | Browser automation with nixpkgs' `playwright-mcp` and its bundled headless Chromium. In the sandbox it runs with `--no-sandbox`, because OpenShell is the isolation boundary, and the browser reaches only what the network policies allow, plus servers inside the sandbox such as a dev server on localhost. Output goes to `/tmp/playwright-mcp` and is discarded with the sandbox; save under the project directory to keep it. The host command keeps Chromium's sandbox and writes output under its state dir. |
| `rea` | [REA](https://github.com/morluto/rea) reverse engineering (roughly 260 tools), from the pinned npm `6.10.1` tarball instead of `npx`, which the network policies would block. Native engines (Ghidra, Hopper, IDA) and `frida` are not included; add one with `extraPackages`. Static JavaScript and Electron analysis needs none. |

Claude Code gets the selected servers through `--mcp-config`. Pi gets them as `$AGENT_HARNESS_STATE/agent/mcp.json`.

### Pi extensions

| Name | What it is |
|---|---|
| `ws-edit` | Whitespace-insensitive replacement for Pi's `edit` tool. |
| `mcp-adapter` | [pi-mcp-adapter](https://github.com/nicobailon/pi-mcp-adapter) `7.0.1`. Replaces Pi's built-in MCP support. |
| `subagents` | [pi-subagents](https://github.com/edxeth/pi-subagents) `v2.9.2`. Named subagents as background `pi -p` children. |
| `ask-user-question` | [rpiv-ask-user-question](https://github.com/juicesharp/rpiv-mono) `2.15.0`. The `ask_user_question` tool: a structured questionnaire (typed options, multi-select, free text, previews) the model puts to you instead of guessing. Hidden when Pi has no UI (`-p`, headless subagents). English only: the optional `rpiv-i18n` translations are left out. |
| `claude-bridge` | [pi-claude-bridge](https://github.com/elidickinson/pi-claude-bridge) `0.11.0`. Claude Code as a Pi model provider, through the Claude Agent SDK. Brings Claude Code into the sandbox. |
| `hindsight` | Hindsight memory. Selected by `hindsight.enable`; see [Memory](#memory-hindsight). |
| `superpowers` | [obra/superpowers](https://github.com/obra/superpowers) `v7.0.2`: the development-methodology skills (brainstorming, planning, red/green TDD, subagent-driven development, …) plus the package's own extension, which injects the `using-superpowers` bootstrap into every provider request at session start and after compaction, so the skills trigger automatically. The 15 skills ride along via the extension's `piSkillsDir` (a settings.json `skills` entry filters every package's own skills away, so they could not load from the package manifest). Built from the pinned `superpowers` input (a git tag; not on npm). |
| `turn-timestamp` | Right-aligned dim `HH:MM:SS` timestamp appended to the transcript when an agent run settles (including aborts). Same grey as the footer's model name; TUI-only, but persisted, so past timestamps survive reload. |

**`mcp-adapter`** reads the same `mcp.json`, so `mcpServers` works unchanged. Instead of codemode scripts, the model gets one `mcp` proxy tool for search and calls. Servers start on first use and stop after 10 idle minutes. It also adds MCP prompts, elicitation, sampling and Tasks. When it is selected, the harness adds `-builtin:mcp` to `settings.json`, so the built-in never runs alongside it. Pi's `codemode` may no longer be on automatically (unverified); add `"+codemode"` to `settings.defaultTools` to keep it. MCP servers that use OAuth can't keep tokens in an OS keychain inside the sandbox.

**`subagents`** adds the `subagent`, `subagent_kill` and `subagent_resume` tools, the `/subagents` overlay (Alt+S), and an opt-in orchestrator mode (`PI_ORCHESTRATOR_MODE = "1"` in `environment`). The model can only launch named agents, read from `$PI_CODING_AGENT_DIR/agents/` and the project's `.pi/agents/`. The harness ships three background agents: `scout` (read-only search), `worker` (implementation) and `reviewer` (read-only review), from `extensions/pi/subagents/agents/`; they are rewritten into `$PI_CODING_AGENT_DIR/agents/` on every launch, so put your own agents in the project's `.pi/agents/`. A project agent with the same name replaces one. Each child is a headless `pi -p` process in the same sandbox, with the same settings, skills, extensions and network policies; children run with `--no-approve` (as far as we know) and inherit every environment variable. Limits: agents with `mode: interactive` (upstream's default) need a terminal multiplexer around Pi, which the sandbox does not have, so set `mode: background` in project agents. `llm-as-a-verifier` agents fail, because they install a Python venv from PyPI on first use.

**`claude-bridge`** registers the `claude-bridge` provider, with every Claude model in Pi's Anthropic catalog (`claude-bridge/claude-opus-5-5`, and so on). It adds no tools or commands. Pi's tools are bridged into Claude Code, so tool calls still go through Pi. Selecting the extension puts this flake's `claude-code` package on PATH (its `passthru.packages`), and the bridge is patched to run that binary instead of the Agent SDK's per-platform native one (`provider.pathToClaudeCodeExecutable` in `$PI_CODING_AGENT_DIR/claude-bridge.json` overrides it). Claude Code is a separate process that Pi starts, so it sees the same allowlist and environment, and writes its session files under `/sandbox/.claude`.

The bridge does not authenticate by itself, and nothing is configured for it by default. A fresh sandbox has no Claude Code login, so a turn fails with `Not logged in · Please run /login`. Claude Code uses `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN` from Pi's environment (metered API billing), or a subscription login in `~/.claude`, which is deleted with the sandbox. It also needs to reach `api.anthropic.com`, which needs a network policy entry for it (see [Network policies](#network-policies)). Any `llm` provider with `api = "anthropic-messages"` does not affect the bridge.

---

## Extend it

The flake uses the same dendritic flake-parts layout as `~/nix-config`. Every `.nix` file under `modules/` is a flake-parts module, auto-imported by `import-tree`, and no file lists skills, harnesses, extensions or MCP servers by hand.

| Path | What it is |
|---|---|
| `skills/<name>/SKILL.md` | A harness-agnostic [Agent Skill](https://agentskills.io/specification). Adding one makes `<name>` a valid `skills` value for every harness. The frontmatter must declare `name: <name>`. |
| `skills/<name>/skill.nix` | Optional. The packages the skill needs: `{pkgs}: { packages = [ pkgs.glab ]; }`. Stripped from the installed skill. |
| `extensions/<harness>/<name>` | Harness-specific add-ons: Pi extension files, or Claude Code plugin directories. A directory with a `default.nix` (`{pkgs, inputs, flakePackages}: drv`, taking the arguments it names) is built with Nix, e.g. from a pinned npm tarball. Its `passthru` can set `packages` (a list of packages put on PATH, in the sandbox and for the host command, whenever the extension is selected), `piAgentsDir` (ship Pi subagent definitions) or `disablesPiBuiltinMcp`. `lib/pi-npm-extension.nix` builds a Pi extension from an npm tarball and a lockfile. |
| `mcp-servers/<name>.nix` | One stdio MCP server: a function of any of `{pkgs, inputs, flakePackages, sandboxed ? true}` returning `{ description; server; packages ? []; }`, where `server` is one entry in the shared `mcpServers` format. `sandboxed` is false for the host command's copy; there, `@AGENT_HARNESS_STATE@` in a string becomes the host state dir. |
| `modules/harnesses/<name>.nix` | One harness definition: its package, whether it `supportsHost` (runs unsandboxed) or `persists` (uses `$AGENT_HARNESS_PERSIST`), and how to start it with skills, extensions, settings, MCP config and (optionally) the LLM registry. A harness with `supportsHost = true` must write only under `$AGENT_HARNESS_STATE` at launch. Adding one makes `programs.agent-harness.harnesses.<name>` appear. The shape is documented in `modules/harnesses/claude-code.nix`. |
| `modules/skills-upstream.nix` | Registers every skill from pinned upstream repos, and declares the tools those skills need. |
| `modules/home/agent-harness.nix` | The home-manager module. Generates options from the registries, and builds images and wrappers. |
| `modules/home/llm.nix` | The LLM provider registry. |
| `modules/home/hindsight.nix` | Hindsight memory: the prebuilt `hindsight` CLI binary (version-pinned with the server images), the local server, the optional dashboard and the harness extension. |
| `modules/home/openshell-gateway.nix` | The gateway systemd service, its config and PKI. |
| `lib/policy-gen.py` | Builds the OpenShell policy at launch: its filesystem, Landlock and process sections, plus `network.policies` unchanged. |
| `lib/devshell-env.py` | Filters the captured dev shell environment into the env file. |
| `modules/checks.nix` | The flake checks. |

Rules for anything you add: pin its source (a `flake = false` input or a fixed-output fetch), and fetch everything at build time. The sandbox can't download at run time.

---

## Maintenance

**Images.** Each harness image is a pinned `debian:bookworm-slim` with the harness and its tool closure layered on top; OpenShell does not support scratch or distroless images. Its supervisor needs `ip` and `nft` at fixed paths, so `/usr/sbin/ip` and `/usr/sbin/nft` link into Nix's iproute2 and nftables. Images are built by Nix and loaded into the engine on first launch. `programs.agent-harness.images.<harness>` exposes each image's stream script, for pushing to a remote gateway's registry.

**Updating.** In your config, `nix flake update agent-harness` picks up a new revision of this flake. Inside this repo, every upstream is a pinned input: `nix flake update <input>` bumps one (`caveman`, `impeccable`, `rea-agents`, and so on). An npm tarball input is pinned by its URL, so change the version in `flake.nix`. For `mcp-adapter` and `claude-bridge`, also regenerate the lockfile as described in its `default.nix` and update `npmDepsHash`. `nix flake update nixpkgs` bumps `openshell`, the gateway (built from the CLI's derivation), `claude-code` and `pi-coding-agent`. `ask-user-question` has two tarball inputs (`rpiv-ask-user-question`, `rpiv-config`) that move together; after changing a tarball URL in `flake.nix`, run `nix flake update <input>`. The Hindsight server image is pinned by digest in `hindsight.image`.

**Checks.**

```shell
nix flake check
```

Five checks:

- `skill-names`: skill names match their directories.
- `policy-gen`: the policy generator, including the cases it must reject (loopback and link-local entries, root UID/GID).
- `home-manager`: builds every harness wrapper through home-manager with every skill, extension, MCP server, an LLM registry and Hindsight turned on. Each sandboxed command is named after its harness and host commands `<name>-unleashed`; the host command puts only the real harness binary ahead of your PATH and its `mcp.json` keeps Chromium's sandbox. It also evaluates broken configs (a loopback provider, a `default` naming a provider not in `llm.providers`) and checks their assertions fire.
- `openshell-gateway`: the gateway and CLI have the same version, the service and config are generated, and the gateway starts on the generated `gateway.toml` offline (it gets as far as looking for the podman socket).
- `devshell`: drives the real `agent-pi` wrapper against fake openshell/podman/direnv/nix: flag parsing, env filtering, the 0700 env dir, mounts and the per-project `/sandbox/.persist` (and that `agent-claude-code` gets none).

**Troubleshooting.**

| Symptom | Check |
|---|---|
| `agent-harness: starting openshell-gateway`, then a failure | `journalctl --user -u openshell-gateway`. |
| Image load fails | `openshell.engine` matches the gateway's driver. |
| The project directory isn't mounted | The gateway's `enable_bind_mounts` (`openshell.gateway.settings`). |
| `openshell status` shows no gateway | `systemctl --user status openshell-gateway`. |
| A request is blocked | A `network.policies` entry matches the host and port, and its `binaries` include the program. With `allowed_ips`, the name must also resolve inside the list. OpenShell's log names the denial reason. |
| Pi runs without memory | `systemctl --user status agent-hindsight`, and that an LLM is set (rebuilds warn when it isn't). |
| The dashboard is down or empty | `systemctl --user status agent-hindsight-dashboard`, and that the server is running. |
