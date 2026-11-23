# agent-harness

Run coding-agent harnesses (Claude Code and Pi today) inside [OpenShell](https://github.com/ai-openshell/openshell) sandboxes. The sandboxes can reach only an IP allowlist. Skills are written once and work in every harness.

## Layout

The flake uses the same dendritic flake-parts layout as `~/nix-config`. Every `.nix` file under `modules/` is a flake-parts module, auto-imported by `import-tree`.

| Path | What it is |
|---|---|
| `skills/<name>/SKILL.md` | A harness-agnostic [Agent Skill](https://agentskills.io/specification). Discovered automatically. |
| `skills/<name>/skill.nix` | Optional. The packages the skill needs: `{pkgs}: { packages = [ pkgs.glab ]; }`. Stripped from the installed skill. |
| `extensions/<harness>/<name>` | Optional harness-specific add-ons: Pi extension files, or Claude Code plugin directories. Discovered automatically. |
| `modules/harnesses/<name>.nix` | One harness definition: its package, and how to start it with a skills directory. |
| `modules/home/agent-harness.nix` | The home-manager module. Generates options from the harness and skill registries, and builds images and wrappers. |
| `modules/nixos/openshell-network.nix` | NixOS module that writes the root-owned `/etc/openshell/network.conf`. |
| `lib/policy-gen.py` | Turns allowlists into an OpenShell policy at launch time. |

| `mcp-servers/<name>.nix` | One stdio MCP server in the shared `mcpServers` format, `{pkgs}: { description; server; packages ? []; }`. Discovered automatically and selected per harness with `mcpServers = [ "<name>" ]`. Claude Code gets it through `--mcp-config`; Pi gets it as `~/.pi/agent/mcp.json`. |
| `modules/skills-upstream.nix` | Registers every skill from pinned upstream repos, and declares the tools those skills need. |

### Upstream skills

These are the skills from the Claude Code plugins in nix-config's `remote-ai.nix`. Each repo is a pinned `flake = false` input; update one with `nix flake update <input>`.

| Input | Skills | Tools added |
|---|---|---|
| `claude-plugins-official` | `frontend-design` | none |
| `impeccable` (`skill-v4.10.0`, generic `.agents/` build) | `impeccable` | The engine binary. Version and hash are read from the skill's own `VERSION` and `engine-checksums.txt`, so the skill never downloads it. |
| `caveman` (`v4.2.0`) | `caveman`, `ultracave`, `megacave`, `cavecrew`, `caveman-commit`, `caveman-review`, `caveman-compress`, `caveman-explore`, `caveman-help`, `investigate-first`, `lean-build`, `migration`, `safe-refactor`, `surgical-patch`, `verify-and-stop`, plus the Cloud skills `caveman-setup`, `-manage`, `-learn`, `-optimize`, `-discover`, `-evidence-review`, `-stats` | python3 with `anthropic` and `tiktoken`, for `caveman-compress` |

The Cloud skills need the `caveman` CLI and network access to Caveman Cloud. Like `remote-ai.nix`, this flake does not install that CLI.

The rest of `remote-ai.nix` is not skill content, so it is not covered here:
- **Plugins that aren't skills:** the `*-lsp` plugins are Claude Code language-server configs. (`playwright` is an MCP server and is covered by `mcp-servers/playwright.nix`. It runs nixpkgs' `playwright-mcp` with its bundled headless Chromium and `--no-sandbox`, because OpenShell is the isolation boundary. The browser reaches only the allowlist, plus servers inside the sandbox such as a dev server on localhost. It blocks `file:` URLs.)
- **Hooks:** caveman's mode hooks and status line, and the format-on-edit hook.
- **`no-agent-summary.js`.**

Claude Code versions of these belong in `extensions/claude-code/`, and Pi versions in `extensions/pi/`. Caveman ships a Pi extension in `packages/pi-extension`.

No file lists skills or harnesses by hand:

- **New skill:** add `skills/<name>/SKILL.md`. It becomes a valid value in every harness's `skills` option.
- **New harness:** add `modules/harnesses/<name>.nix`. `programs.agent-harness.harnesses.<name>` appears.

## Use it from home-manager

Add the input:

```nix
inputs.agent-harness = {
  url = "git+file:///home/marauder/agent-harness"; # or a git remote
  inputs.nixpkgs.follows = "nixpkgs-unstable";
};
```

Import the module and choose harnesses and skills:

```nix
imports = [ inputs.agent-harness.modules.homeManager.agent-harness ];
# (non-dendritic configs: inputs.agent-harness.homeManagerModules.default)

programs.agent-harness = {
  openshell.engine = "podman";          # must match the gateway's compute driver
  network.allow = [
    "10.0.0.5/32"                        # bare string: port 443 only
    { cidr = "10.0.1.0/24"; ports = [ 443 22 ]; }
  ];
  harnesses.claude-code = {
    enable = true;
    skills = [ "gitlab" "commit-message" ];
    providers = [ "anthropic" ];         # OpenShell provider holding the API key
  };
  harnesses.pi = {
    enable = true;
    skills = [ "gitlab" ];
    extensions = [ "ws-edit" ];
    settings = { defaultProvider = "openrouter"; };
  };
};
```

Each enabled harness gets a command, `agent-claude-code` or `agent-pi` by default; set `command` to change it. Run it from a project directory. Arguments are passed through to the harness.

### Per-harness options

| Option | Default | Purpose |
|---|---|---|
| `enable` | `false` | Build the image and install the command. |
| `skills` | `[]` | Skills from `skills/` to install. Checked at evaluation time. |
| `extensions` | `[]` | Add-ons from `extensions/<harness>/`. |
| `settings` | `{}` | Merged over the harness defaults: Claude Code's `--settings`, or Pi's `settings.json`. |
| `package` | unstable build | The harness CLI. |
| `extraPackages` | `[]` | Extra tools on PATH in the sandbox. |
| `providers` | `[]` | OpenShell providers to attach. Use these for API keys. |
| `envFrom` | `[]` | Host variables copied in. The agent can read them, so don't use this for secrets. |
| `autoProviders` | `false` | Let OpenShell attach providers it detects. |
| `keep` | `false` | Keep the sandbox after exit. |
| `extraArgs` | `[]` | Arguments always passed to the harness. |

## Network allowlist

A sandbox can reach only what the allowlist names. Everything else is denied, and loopback and link-local addresses are always denied. There are two sources, and every launch merges them:

1. **home-manager:** `programs.agent-harness.network.allow`, baked into the store.
2. **The root-owned file at `network.allowFile`** (default `/etc/openshell/network.conf`). It is read at each launch. A missing file adds nothing. If the file or any parent directory is not owned by root, or is writable by group or others, the launch fails. This stops the user, or the agent, from widening their own allowlist.

On NixOS:

```nix
imports = [ inputs.agent-harness.modules.nixos.openshell-network ];
services.openshell-network.allow = [ "10.0.0.5/32" { cidr = "10.0.1.0/24"; ports = [ 443 22 ]; } ];
```

On other distributions:

```shell
sudo install -d -m 755 /etc/openshell
printf '10.0.0.5/32 443,22\n10.0.1.0/24\n' | sudo tee /etc/openshell/network.conf
sudo chmod 444 /etc/openshell/network.conf
```

The file format is one entry per line: `<ip-or-cidr> [port,port,...]`. Ports default to 443, and `#` starts a comment.

The generated policy has one hostless `allowed_ips` endpoint per port, with `tls: skip`, for every binary. It is a layer-4 allowlist: no TLS interception and no per-request rules. Hostnames still work, because OpenShell resolves them and checks the resolved address. Anything that resolves outside the list is denied. That includes most SaaS endpoints, whose IP addresses change.

## Gateway prerequisites

These are not managed by this flake:

- **A running gateway:** OpenShell's installer, or `openshell gateway add`. `openshell status` must show it.
- **Matching engine:** `openshell.engine` must be the engine the gateway's Docker or Podman driver uses, because images are loaded into it. If `docker` on the host is podman's compatibility shim, set `"podman"`.
- **Bind mounts for the project directory.** The current directory is bind-mounted read-write at `/sandbox/work`. The gateway's driver config must allow this:

  ```toml
  [openshell.drivers.docker]   # or .podman
  allow_driver_config = true
  enable_bind_mounts = true

  [openshell.drivers.docker.resource_admission]
  enabled = false
  ```

  Alternatively, set `workspace.mount = false` and copy files in and out with `openshell sandbox upload` and `openshell sandbox download`.

- **Rootless podman:** the sandbox runs as your host UID and GID, which keeps files in the mounted project owned by you. Under rootless podman, those IDs are remapped. Check file ownership after a first run.

## Images

Each harness image is a pinned `debian:bookworm-slim` with the harness and tool closure layered on top. OpenShell does not support scratch or distroless images. The images are built by Nix and loaded into the engine on first launch. `programs.agent-harness.images.<harness>` exposes each image's stream script, for pushing to a remote gateway's registry.

## Checks

```shell
nix flake check
```

The checks verify that skill names match their directories, test the policy generator (including the cases it must reject), and build both harness wrappers through home-manager.
