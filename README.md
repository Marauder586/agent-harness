# agent-harness

Run coding-agent harnesses (Claude Code and Pi today) inside [OpenShell](https://github.com/ai-openshell/openshell) sandboxes from a Nix config. Each sandbox can reach only an IP allowlist. Skills, MCP servers and LLM endpoints are declared once and wired into every harness you enable.

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

The flake installs the `openshell` CLI, but not the gateway that runs sandboxes. Set that up first:

- **A running OpenShell gateway.** Use OpenShell's installer, or `openshell gateway add`. `openshell status` must show it.
- **A container engine the gateway uses.** Rootless podman is recommended, and Hindsight requires it. On NixOS, `virtualisation.podman.enable = true`.
- **Bind mounts allowed.** The current directory is bind-mounted read-write at `/sandbox/work`. The gateway's driver config must allow this:

  ```toml
  [openshell.drivers.podman]   # or .docker
  allow_driver_config = true
  enable_bind_mounts = true

  [openshell.drivers.podman.resource_admission]
  enabled = false
  ```

  Alternatively, set `programs.agent-harness.workspace.mount = false` and copy files in and out with `openshell sandbox upload` and `openshell sandbox download`.

- **Rootless podman:** the sandbox runs as your host UID and GID, which keeps files in the mounted project owned by you. Under rootless podman those IDs are remapped, so check file ownership after a first run.

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
        programs.agent-harness.harnesses.pi.enable = true;
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
    {programs.agent-harness.harnesses.pi.enable = true;}
  ];
};
```

### 4. Give the sandbox a model and a network

A sandbox with an empty allowlist has no network, and a harness with no model can't do anything. The smallest working Pi setup points it at one OpenAI-compatible model endpoint:

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

The provider's address and port are added to the allowlist automatically. See [LLM providers](#llm-providers).

### 5. Rebuild and run

```shell
sudo nixos-rebuild switch --flake .#myhost   # or: home-manager switch --flake .#me
cd ~/Projects/something
agent-pi                                      # the default `command`; arguments are passed to the harness
```

The first launch loads the harness image into the engine, which takes a moment. After that each launch creates a new sandbox, and removes it when the harness exits (unless `keep = true`).

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
| `extraPackages` | `[]` | Extra tools on PATH in the sandbox. |
| `environment` | `{}` | Fixed variables set in the sandbox. Readable by the agent, so no secrets. |
| `providers` | `[]` | OpenShell providers to attach. The safe way to pass API keys: the agent sees a placeholder. |
| `envFrom` | `[]` | Host variables copied in. The agent can read them, so don't use this for secrets. |
| `autoProviders` | `false` | Let OpenShell attach providers it detects. |
| `keep` | `false` | Keep the sandbox after exit. |
| `extraArgs` | `[]` | Arguments always passed to the harness. |
| `host.enable` / `host.command` / `host.extensions` / `host.environment` | off / harness name / `[]` / `{}` | The [unsandboxed host command](#unsandboxed-host-command). `host.command` must differ from `command`. |

Shared options: `secretEnvFiles` (variable name to host file; see [API keys](#llm-providers)), `openshell.engine` (`"docker"` or `"podman"`, must match the gateway's driver; if `docker` on the host is podman's shim, use `"podman"`), `openshell.package`, `workspace.mount` and `workspace.target`, and `image.base`.

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
| HOME | `/sandbox`, discarded on exit | your real HOME |
| Network | the allowlist only | unrestricted |
| State dir (`$AGENT_HARNESS_STATE`) | `/sandbox/.pi` | `$XDG_STATE_HOME/agent-harness/pi` (default `~/.local/state/…`) |
| Pi config dir | `/sandbox/.pi/agent` | `$AGENT_HARNESS_STATE/agent`, rewritten each launch (stale `models.json`, `mcp.json` and `agents/` are removed); sessions persist. A hand-managed `~/.pi` is never touched. |
| Skills, extensions, MCP servers, LLM registry, Hindsight | same | same, plus `host.extensions` |
| MCP servers | as defined | built with `sandboxed = false`: `playwright` keeps Chromium's own sandbox and writes to `$AGENT_HARNESS_STATE/playwright-mcp` |
| `secretEnvFiles` (API keys) | passed with `--env` | exported into the process; never on a command line |

`host.environment` overrides `environment` for the host; Hindsight uses it to point the host command at `http://127.0.0.1:9077`. Harness tools go after your PATH; only a directory holding the harness binary itself goes first, so a child started by name (e.g. pi-subagents' `pi` fallback) gets the real harness, not a same-named sandboxed command. Claude Code has no host mode, because its launch writes skills into `~/.claude`.

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
| Claude Code | Only when `default` is an `api = "anthropic-messages"` provider: `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`, `ANTHROPIC_AUTH_TOKEN`. Other APIs can't drive Claude Code. |
| Hindsight | `default` becomes its extraction LLM. `hindsight.llm.*` overrides it. |
| Network | An IP-address `baseUrl` is added to `network.allow` on its port. For a hostname, set the provider's `allow` to the addresses it resolves to. Loopback and link-local addresses fail evaluation, since the sandbox can never reach them: for a model served on this machine, listen on a LAN address and use that. |

Provider fields: `baseUrl`, `api` (`openai-completions`, `openai-responses`, `anthropic-messages`), `apiKeyFile`, `models`, `compat` (Pi compatibility overrides), `displayName`, `allow`. Model fields: `id`, `name`, `reasoning`, `input`, `contextWindow`, `maxTokens`, `extra` (merged into the Pi model entry: `cost`, `samplingParams`, and so on).

**API keys:** `apiKeyFile` becomes a `secretEnvFiles` entry: it is read on the host at each launch and passed into the sandbox as `AGENT_LLM_<NAME>_API_KEY`. The agent can read it, and it appears in the host process list while the launcher runs. Keep the file out of the Nix store (`/run/secrets/…` from sops-nix or agenix, or a file in your home directory). For a key the agent must not see, attach an OpenShell provider (`harnesses.<h>.providers`) instead and leave `apiKeyFile` unset.

### Network allowlist

A sandbox can reach only what the allowlist names: `programs.agent-harness.network.allow`, plus the entries LLM providers add. Everything else is denied, and loopback and link-local addresses are always denied. The list is part of your Nix config and baked into the store, so neither the user nor the agent can widen it at run time.

```nix
programs.agent-harness.network.allow = [
  "10.0.0.5/32"                              # bare string: port 443 only
  {cidr = "10.0.1.0/24"; ports = [443 22];}
];
```

The generated policy has one hostless `allowed_ips` endpoint per port, with `tls: skip`, for every binary. It is a layer-4 allowlist: no TLS interception and no per-request rules. Hostnames still work, because OpenShell resolves them and checks the resolved address. Anything that resolves outside the list is denied. That includes most SaaS endpoints, whose IP addresses change.

**Services on the host:** `network.hostPorts = [9077]` lets the sandbox reach a service on the host machine as `host.openshell.internal:9077`. This works only with a rootless podman gateway: OpenShell lets this alias through only when it maps to pasta's link-local host address. A port cannot be in both `hostPorts` and `allow`. The service must listen on a non-loopback address, because pasta delivers these connections to the host's own interface address.

### Memory (Hindsight)

```nix
programs.agent-harness.hindsight.enable = true;
```

This gives agents long-term memory from [Hindsight](https://hindsight.vectorize.io), served from this machine. Each host runs its own server and keeps its own memory.

- **Server:** the pinned `hindsight-api` image runs as the systemd user service `agent-hindsight` under rootless podman, on port 9077 (`hindsight.port`). Memory lives in the podman volume `agent-hindsight-data`. The first start pulls a 4.3 GB image. The server uses about 1.6 GB of RAM.
- **Models:** embeddings use `BAAI/bge-small-en-v1.5` (33M parameters) and reranking `hindsight-ai/hs-rerank-1` (114M). Both are bundled in the image and run on CPU, offline. Knowledge-bank embeddings reuse bge-small instead of the 744M EmbeddingGemma 2 default.
- **LLM:** fact extraction and reflection need a chat model. It defaults to `llm.default`. Override with `hindsight.llm.{provider,baseUrl,model,apiKeyFile}`. With no LLM, the server is not started (rebuilds show a warning), and agents run without memory. A keyless endpoint gets the dummy key `none`, which the server requires.
- **Agents:** `hindsight.enable` adds the `hindsight` extension to `extensions` of each harness in `hindsight.harnesses` (default: every harness that has one, today `pi`), pointed at `http://host.openshell.internal:9077`. The extension is `extensions/pi/hindsight/`: `dist/pi.js` from the pinned `@vectorize-io/hindsight-coding-agents` npm tarball, plus the helper scripts it spawns. Recall is injected before each turn, and the transcript is saved after it.
- **Network:** the port is added to `network.hostPorts`, so this requires `openshell.engine = "podman"` with a rootless gateway.

> [!WARNING]
> The Hindsight server has no authentication and listens on every host address. Keep port 9077 closed in the host firewall. NixOS's firewall is on by default and does not open it.

Check the server with `systemctl --user status agent-hindsight` and `curl http://127.0.0.1:9077/health`.

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
| `playwright` | Browser automation with nixpkgs' `playwright-mcp` and its bundled headless Chromium. In the sandbox it runs with `--no-sandbox`, because OpenShell is the isolation boundary, and the browser reaches only the allowlist, plus servers inside the sandbox such as a dev server on localhost. The host command keeps Chromium's sandbox and writes output under its state dir. It blocks `file:` URLs. |
| `rea` | [REA](https://github.com/morluto/rea) reverse engineering (263 tools), from the pinned npm `6.10.1` tarball instead of `npx`, which the allowlist would block. Native engines (Ghidra, Hopper, IDA) and `frida` are not included; add one with `extraPackages`. Static JavaScript and Electron analysis needs none. |

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

**`mcp-adapter`** reads the same `mcp.json`, so `mcpServers` works unchanged. Instead of codemode scripts, the model gets one `mcp` proxy tool for search and calls. Servers start on first use and stop after 10 idle minutes. It also adds MCP prompts, elicitation, sampling and Tasks. When it is selected, the harness adds `-builtin:mcp` to `settings.json`, so the built-in never runs alongside it. Pi's `codemode` is no longer turned on automatically; add `"+codemode"` to `settings.defaultTools` to keep it. MCP servers that use OAuth can't keep tokens in an OS keychain inside the sandbox.

**`subagents`** adds the `subagent`, `subagent_kill` and `subagent_resume` tools, the `/subagents` overlay (Alt+S), and an opt-in orchestrator mode (`PI_ORCHESTRATOR_MODE = "1"` in `environment`). The model can only launch named agents, read from `~/.pi/agent/agents/` and the project's `.pi/agents/`. The harness ships three background agents: `scout` (read-only search), `worker` (implementation) and `reviewer` (read-only review), from `extensions/pi/subagents/agents/`. A project agent with the same name replaces one. Each child is a headless `pi -p` process in the same sandbox, with the same settings, skills, extensions and allowlist; children run with `--no-approve` and inherit every environment variable. Limits: agents with `mode: interactive` (upstream's default) need a terminal multiplexer around Pi, which the sandbox does not have, so set `mode: background` in project agents. `llm-as-a-verifier` agents fail, because they install a Python venv from PyPI on first use.

**`claude-bridge`** registers the `claude-bridge` provider, with every Claude model in Pi's Anthropic catalog (`claude-bridge/claude-opus-5-5`, and so on). It adds no tools or commands. Pi's tools are bridged into Claude Code, so tool calls still go through Pi. Selecting the extension puts this flake's `claude-code` package on PATH (its `passthru.packages`), and the bridge is patched to run that binary instead of the Agent SDK's per-platform native one. Claude Code is a separate process that Pi starts, so it sees the same allowlist and environment, and writes its session files under `/sandbox/.claude`.

The bridge does not authenticate by itself, and nothing is configured for it by default. A fresh sandbox has no Claude Code login, so a turn fails with `Not logged in · Please run /login`. Claude Code uses `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN` from Pi's environment (metered API billing), or a subscription login in `~/.claude`, which is deleted with the sandbox. It also needs to reach `api.anthropic.com`, a SaaS endpoint that an IP allowlist does not handle well (see [Network allowlist](#network-allowlist)). Any `llm` provider with `api = "anthropic-messages"` does not affect the bridge.

---

## Extend it

The flake uses the same dendritic flake-parts layout as `~/nix-config`. Every `.nix` file under `modules/` is a flake-parts module, auto-imported by `import-tree`, and no file lists skills, harnesses, extensions or MCP servers by hand.

| Path | What it is |
|---|---|
| `skills/<name>/SKILL.md` | A harness-agnostic [Agent Skill](https://agentskills.io/specification). Adding one makes `<name>` a valid `skills` value for every harness. The frontmatter must declare `name: <name>`. |
| `skills/<name>/skill.nix` | Optional. The packages the skill needs: `{pkgs}: { packages = [ pkgs.glab ]; }`. Stripped from the installed skill. |
| `extensions/<harness>/<name>` | Harness-specific add-ons: Pi extension files, or Claude Code plugin directories. A directory with a `default.nix` (`{pkgs, inputs, flakePackages}: drv`, taking the arguments it names) is built with Nix, e.g. from a pinned npm tarball. Its `passthru` can set `packages` (a list of packages put on PATH, in the sandbox and for the host command, whenever the extension is selected), `piAgentsDir` (ship Pi subagent definitions) or `disablesPiBuiltinMcp`. `lib/pi-npm-extension.nix` builds a Pi extension from an npm tarball and a lockfile. |
| `mcp-servers/<name>.nix` | One stdio MCP server: a function of any of `{pkgs, inputs, flakePackages, sandboxed ? true}` returning `{ description; server; packages ? []; }`, where `server` is one entry in the shared `mcpServers` format. `sandboxed` is false for the host command's copy; there, `@AGENT_HARNESS_STATE@` in a string becomes the host state dir. |
| `modules/harnesses/<name>.nix` | One harness definition: its package, whether it `supportsHost`, and how to start it with skills, extensions, settings, MCP config and (optionally) the LLM registry. `launch` writes only under `$AGENT_HARNESS_STATE`. Adding one makes `programs.agent-harness.harnesses.<name>` appear. The shape is documented in `modules/harnesses/claude-code.nix`. |
| `modules/skills-upstream.nix` | Registers every skill from pinned upstream repos, and declares the tools those skills need. |
| `modules/home/agent-harness.nix` | The home-manager module. Generates options from the registries, and builds images and wrappers. |
| `modules/home/llm.nix` | The LLM provider registry. |
| `modules/home/hindsight.nix` | Hindsight memory: the local server and the harness extension. |
| `lib/policy-gen.py` | Turns the allowlist and host ports into an OpenShell policy at launch time. |

Rules for anything you add: pin its source (a `flake = false` input or a fixed-output fetch), and fetch everything at build time. The sandbox can't download at run time.

---

## Maintenance

**Images.** Each harness image is a pinned `debian:bookworm-slim` with the harness and its tool closure layered on top; OpenShell does not support scratch or distroless images. Images are built by Nix and loaded into the engine on first launch. `programs.agent-harness.images.<harness>` exposes each image's stream script, for pushing to a remote gateway's registry.

**Updating.** In your config, `nix flake update agent-harness` picks up a new revision of this flake. Inside this repo, every upstream is a pinned input: `nix flake update <input>` bumps one (`caveman`, `impeccable`, `rea-agents`, and so on). An npm tarball input is pinned by its URL, so change the version in `flake.nix`. For `mcp-adapter` and `claude-bridge`, also regenerate the lockfile as described in its `default.nix` and update `npmDepsHash`. The Hindsight server image is pinned by digest in `hindsight.image`.

**Checks.**

```shell
nix flake check
```

The checks verify that skill names match their directories, test the policy generator (including the cases it must reject), and build every harness wrapper through home-manager with every skill, extension, MCP server, an LLM registry and Hindsight turned on. That build names each sandboxed command after its harness and host commands `<name>-unleashed`, and checks that the host command puts only the real harness binary ahead of your PATH and that its `mcp.json` keeps Chromium's sandbox. It also evaluates broken configs (a loopback provider, a `default` with no providers) and checks their assertions fire.

**Troubleshooting.**

| Symptom | Check |
|---|---|
| `agent-<harness>` can't reach the gateway | `openshell status`. |
| Image load fails | `openshell.engine` matches the gateway's driver. |
| The project directory isn't mounted | The gateway's `enable_bind_mounts` and `allow_driver_config`. |
| A request is blocked | The address and port are in `network.allow`. Hostnames must resolve inside the list. |
| Pi runs without memory | `systemctl --user status agent-hindsight`, and that an LLM is set (rebuilds warn when it isn't). |
