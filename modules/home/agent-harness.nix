# Home-manager aspect: run any registered harness inside an OpenShell sandbox.
#
# Import it (inputs.agent-harness.modules.homeManager.agent-harness, or
# .homeManagerModules.default), then turn harnesses on and choose their
# skills. One `programs.agent-harness.harnesses.<name>` option set is
# generated per file in modules/harnesses/, and each harness's `skills` /
# `extensions` options are enums built from skills/ and
# extensions/<harness>/. No list is kept by hand anywhere:
#
#   programs.agent-harness = {
#     network.allow = [ "10.0.0.5/32" { cidr = "10.0.1.0/24"; ports = [443 22]; } ];
#     harnesses.claude-code = { enable = true; skills = [ "gitlab" ]; };
#     harnesses.pi = { enable = true; skills = [ "gitlab" "commit-message" ];
#                      extensions = [ "ws-edit" ]; };
#   };
#
# Each enabled harness gets a command (`command`, default `agent-<harness>`)
# that:
#   1. loads the harness's Nix-built OCI image into docker/podman if missing,
#   2. builds an OpenShell policy from network.allow and network.hostPorts
#      (lib/policy-gen.py),
#   3. runs `openshell sandbox create --from <image> --policy <policy>
#      --no-keep -- agent-launch "$@"`, with $PWD bind-mounted at
#      /sandbox/work,
#   4. if the project has a dev shell (direnv .envrc, flake devShell, or
#      `--devshell <installable>`), evaluates it on the host, mounts its
#      environment (lib/devshell-env.py) and the host's /nix/store
#      read-only, and `agent-launch` loads it before the harness starts.
#
# Harnesses with `supportsHost = true` (pi) can also get an unsandboxed
# command (`host.*`): the same launch script run on the host, writing only
# under $XDG_STATE_HOME/agent-harness/<harness>. See README.md.
#
# Needs an OpenShell gateway with the matching compute driver
# (`openshell status`): openshell-gateway.nix runs one by default, with the
# bind-mount opt-in $PWD needs. See README.md.
{
  config,
  inputs,
  withSystem,
  ...
}: let
  skillsRegistry = config.flake.agentSkills;
  harnessRegistry = config.flake.agentHarnesses;
  mcpRegistry = config.flake.agentMcpServers;
in {
  flake.modules.homeManager.agent-harness = {
    config,
    pkgs,
    lib,
    ...
  }: let
    hl = import ../../lib {inherit lib;};
    cfg = config.programs.agent-harness;
    system = pkgs.stdenv.hostPlatform.system;
    flakePackages = withSystem system ({config, ...}: config.packages);

    enabled = lib.filterAttrs (_: h: h.enable) cfg.harnesses;

    allowConf = pkgs.writeText "agent-harness-allow.conf" (hl.renderAllowConf cfg.network.allow);
    policyGen = ../../lib/policy-gen.py;
    devshellEnv = ../../lib/devshell-env.py;
    # Where the wrapper mounts the captured dev shell environment (a
    # directory holding `env`), read-only. Under /sandbox, which the
    # policy's workdir rule already makes readable.
    devshellDir = "/sandbox/.devshell";
    # Per-project persistent state (sessions), mounted read-write from
    # $XDG_STATE_HOME/agent-harness/<harness>-sandbox/projects/<hash>.
    persistDir = "/sandbox/.persist";

    # Tools every sandbox gets, whatever the harness: a shell and coreutils
    # for the agent's bash tool, git, and the search tools Pi otherwise
    # tries to download.
    baseTools = with pkgs; [
      bashInteractive
      coreutils
      findutils
      diffutils
      gnugrep
      gnused
      gawk
      gnutar
      gzip
      which
      less
      procps
      git
      openssh
      curl
      jq
      ripgrep
      fd
    ];

    # One directory of <skill>/SKILL.md entries: the only thing a harness
    # is told about skills.
    mkSkillsDir = name: names:
      pkgs.runCommand "agent-${name}-skills" {} ''
        mkdir -p $out
        ${lib.concatMapStrings (s: "cp -r ${skillsRegistry.${s}.src} $out/${s}\n") names}
      '';

    # A registry extension is a path, or a function (extensions/<harness>/
    # <name>/default.nix) that builds one from `pkgs`, `inputs` (this
    # flake's inputs) and `flakePackages` (this flake's packages, e.g.
    # claude-code, built with unfree allowed).
    extensionArgs = {inherit pkgs inputs flakePackages;};
    buildExtension = e:
      if lib.isFunction e
      then hl.callWith e extensionArgs
      else e;

    # Tools an extension needs at run time (its passthru.packages), put on
    # PATH whenever it is selected. Plain-file extensions have none.
    extensionPackages = e: e.packages or [];

    # Host files read into environment variables at each launch
    # (secretEnvFiles), as shell lines for the sandbox and host wrappers.
    secretFiles =
      lib.mapAttrsToList (n: f: {
        inherit n;
        f = lib.escapeShellArg f;
      })
      cfg.secretEnvFiles;

    exports = env: lib.concatStrings (lib.mapAttrsToList (k: v: "export ${lib.toShellVar k v}\n") env);

    mkHarness = name: hcfg: let
      def = harnessRegistry.${name};
      skillsDir = mkSkillsDir name hcfg.skills;
      buildNamed = names: map (e: buildExtension def.extensions.${e}) (lib.unique names);
      extensions = buildNamed hcfg.extensions ++ hcfg.extraExtensions;
      hostExtensions = extensions ++ buildNamed (lib.subtractLists hcfg.extensions hcfg.host.extensions);

      # Selected MCP servers, evaluated against the consumer's pkgs, and
      # rendered as the shared `mcpServers` JSON every harness reads. The
      # host command gets its own copy built with `sandboxed = false`.
      mcpFor = sandboxed:
        lib.genAttrs hcfg.mcpServers (s:
          hl.callWith mcpRegistry.${s} (extensionArgs // {inherit sandboxed;}));
      mcp = mcpFor true;
      renderMcp = file: servers:
        if servers == {}
        then null
        else
          pkgs.writeText file (builtins.toJSON {
            mcpServers = lib.mapAttrs (_: m:
              m.server
              // lib.optionalAttrs (m ? description) {inherit (m) description;})
            servers;
          });
      mcpConfig = renderMcp "agent-${name}-mcp.json" mcp;
      # Host servers may name "@AGENT_HARNESS_STATE@"; the host wrapper
      # fills it in and writes the result here.
      hostMcpTemplate = renderMcp "agent-${name}-host-mcp.json" (mcpFor false);
      hostMcpConfig =
        if hostMcpTemplate == null
        then null
        else ''"$AGENT_HARNESS_STATE/mcp-servers.json"'';

      launchScript = exts: mcpConfig:
        hl.callWith def.launch {
          inherit pkgs mcpConfig;
          inherit (hcfg) package settings;
          skills = skillsDir;
          extensions = exts;
          llm = cfg.llm;
        };

      launcher = pkgs.writeShellScriptBin "agent-launch" ''
        set -eu
        export HOME=/sandbox
        export AGENT_HARNESS_STATE="$HOME/.${name}"
        # The host dev shell, if the wrapper captured one: it only fills
        # variables the sandbox does not already have, and prepends its PATH.
        # `environment` below still wins.
        if [ -f ${devshellDir}/env ]; then . ${devshellDir}/env; fi
        if [ -d ${persistDir} ]; then export AGENT_HARNESS_PERSIST=${persistDir}; fi
        ${exports hcfg.environment}
        cd ${cfg.workspace.target} 2>/dev/null || cd "$HOME"
        ${launchScript extensions mcpConfig}
      '';

      # Everything a harness run needs on PATH, besides the harness itself.
      toolPaths = exts:
        baseTools
        ++ lib.concatMap (s: skillsRegistry.${s}.packages pkgs) hcfg.skills
        ++ lib.concatMap (m: m.packages or []) (lib.attrValues mcp)
        ++ lib.concatMap extensionPackages exts
        ++ hcfg.extraPackages;

      # Unsandboxed: same launch script, run on the host as the user.
      hostEnv = pkgs.buildEnv {
        name = "agent-${name}-host-env";
        paths = toolPaths hostExtensions;
      };
      # Only the harness's own binary, under its real name. It goes first on
      # PATH so a child started by name (e.g. pi-subagents' `pi` fallback)
      # gets the real harness, not a same-named command in home.packages
      # (such as the sandboxed wrapper, when `command` is the harness name).
      # It holds nothing else, so the user's other tools stay unshadowed;
      # the harness's other tools (hostEnv) go after the user's own PATH.
      hostBin = let
        exe = lib.getExe hcfg.package;
      in
        pkgs.runCommand "agent-${name}-host-bin" {} ''
          mkdir -p $out/bin
          ln -s ${exe} $out/bin/${baseNameOf exe}
        '';
      hostWrapper = pkgs.writeShellScriptBin hcfg.host.command ''
        set -eu
        # hostBin first, the harness's tools after the user's PATH (see hostBin).
        export PATH="${hostBin}/bin:''${PATH:+$PATH:}${hostEnv}/bin"
        ${exports (hcfg.environment // hcfg.host.environment)}
        ${lib.concatMapStrings (s: ''
            ${s.n}=$(cat ${s.f})
            export ${s.n}
          '')
          secretFiles}
        export AGENT_HARNESS_STATE="''${XDG_STATE_HOME:-$HOME/.local/state}/agent-harness/${name}"
        mkdir -p "$AGENT_HARNESS_STATE"
        ${lib.optionalString (hostMcpTemplate != null) ''
          ${lib.getExe pkgs.jq} --arg s "$AGENT_HARNESS_STATE" \
            'walk(if type == "string" then gsub("@AGENT_HARNESS_STATE@"; $s) else . end)' \
            ${hostMcpTemplate} > ${hostMcpConfig}
        ''}
        set -- ${lib.escapeShellArgs hcfg.extraArgs} "$@"
        ${launchScript hostExtensions hostMcpConfig}
      '';

      env = pkgs.buildEnv {
        name = "agent-${name}-env";
        paths = [hcfg.package launcher] ++ toolPaths extensions;
      };

      # Store paths are referenced from `config`, so they land in the image
      # closure without symlinking anything over the base image's /bin.
      # Only cacert goes in `contents`, to supply /etc/ssl/certs (the slim
      # base has none). OpenShell's supervisor sets up the sandbox network
      # with `ip` and `nft`, which it looks up only at fixed paths
      # (/usr/sbin, /sbin, ...); the slim base has neither.
      image = pkgs.dockerTools.streamLayeredImage {
        name = "agent-harness-${name}";
        fromImage = cfg.image.base;
        contents = [pkgs.cacert];
        extraCommands = ''
          mkdir -p usr/sbin
          ln -s ${pkgs.iproute2}/bin/ip usr/sbin/ip
          ln -s ${pkgs.nftables}/bin/nft usr/sbin/nft
        '';
        config = {
          WorkingDir = "/sandbox";
          Env = [
            "PATH=${env}/bin:/usr/local/bin:/usr/bin:/bin"
            "HOME=/sandbox"
            "LANG=C.UTF-8"
          ];
        };
      };

      imageRef =
        lib.optionalString (cfg.openshell.engine == "podman") "localhost/"
        + "${image.imageName}:${image.imageTag}";
      # The host's own engine from PATH, not a pinned one: it must share the
      # gateway's image storage, socket, and containers config.
      engine = cfg.openshell.engine;

      wrapperInputs = [cfg.openshell.package pkgs.jq pkgs.python3 pkgs.coreutils];
      wrapper = pkgs.writeShellApplication {
        name = hcfg.command;
        runtimeInputs = wrapperInputs;
        text = ''
          # The caller's PATH, without the runtimeInputs writeShellApplication
          # put in front: direnv, nix and the .envrc see the user's own tools.
          hostPath=''${PATH#"${lib.makeBinPath wrapperInputs}:"}

          # Dev shell selection: leading --devshell/--no-devshell flags, then
          # $AGENT_DEVSHELL, then devshell.auto. Everything after the first
          # other argument goes to the harness untouched.
          devshell=''${AGENT_DEVSHELL:-}
          while [ $# -gt 0 ]; do
            case $1 in
              --devshell)
                [ $# -ge 2 ] || { echo "agent-harness: --devshell needs an installable (e.g. .#default)" >&2; exit 2; }
                devshell=$2
                shift 2
                ;;
              --devshell=*) devshell=''${1#--devshell=}; shift ;;
              --no-devshell) devshell=none; shift ;;
              *) break ;;
            esac
          done
          devshell=''${devshell:-${
            if cfg.devshell.auto
            then "auto"
            else "none"
          }}

          ${lib.optionalString cfg.openshell.gateway.enable ''
            # The gateway service starts with the user session, but a switch
            # may not have started it (or it stopped): start it on demand.
            if ! systemctl --user is-active --quiet openshell-gateway; then
              echo "agent-harness: starting openshell-gateway" >&2
              if ! systemctl --user start openshell-gateway; then
                echo "agent-harness: see 'journalctl --user -u openshell-gateway'" >&2
                exit 1
              fi
              # `openshell status` exits 0 even when unreachable; wait for the port.
              for _ in $(seq 30); do
                (: </dev/tcp/127.0.0.1/${toString cfg.openshell.gateway.port}) 2>/dev/null && break
                sleep 1
              done
            fi
          ''}
          ref=${lib.escapeShellArg imageRef}
          if ! ${engine} image inspect "$ref" >/dev/null 2>&1; then
            echo "agent-harness: loading $ref into ${cfg.openshell.engine}" >&2
            ${image} | ${engine} load >&2
          fi

          # Private (0700) scratch dir: the policy, and the dev shell env,
          # which can hold secrets from the .envrc.
          work=$(mktemp -d -t agent-harness.XXXXXX)
          trap 'rm -rf "$work"' EXIT
          policy=$work/policy.yaml
          python3 -I ${policyGen} \
            --uid "$(id -u)" --gid "$(id -g)" \
            --conf ${allowConf} \
            ${lib.concatMapStringsSep " " (p: "--host-port ${toString p}") cfg.network.hostPorts} \
            > "$policy"

          # <harness>-<dir>-<6 hex>, at most 19 chars: OpenShell's limit for
          # sandbox names (MAX_ROUTABLE_NAME_LEN). The dir part is cut to fit.
          rand=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
          base=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-' | tr -s '-')
          base=''${base#-}
          room=$((19 - ${toString (lib.stringLength name)} - 8))
          if [ "$room" -gt 0 ]; then base=''${base:0:room}; base=''${base%-}; else base=""; fi
          name="${name}''${base:+-$base}-$rand"

          args=(sandbox create --name "$name" --from "$ref" --policy "$policy")
          ${lib.optionalString (!hcfg.keep) "args+=(--no-keep)"}
          ${lib.optionalString (!hcfg.autoProviders) "args+=(--no-auto-providers)"}
          ${lib.concatMapStrings (p: "args+=(--provider ${lib.escapeShellArg p})\n") hcfg.providers}
          ${lib.concatMapStrings (v: ''
              if [ -n "''${${v}+set}" ]; then args+=(--env "${v}=''${${v}}"); fi
            '')
            hcfg.envFrom}
          ${lib.concatMapStrings (s: ''
              args+=(--env "${s.n}=$(cat ${s.f})")
            '')
            secretFiles}
          mounts='[]'
          addMount() {
            mounts=$(jq -c --arg src "$1" --arg dst "$2" --argjson ro "$3" \
              '. + [{type: "bind", source: $src, target: $dst, read_only: $ro}]' <<<"$mounts")
          }
          ${lib.optionalString cfg.workspace.mount ''
            addMount "$PWD" ${lib.escapeShellArg cfg.workspace.target} false
          ''}
          ${lib.optionalString hcfg.persist ''
            # One directory per project path, so sessions (all recorded under
            # the same sandbox cwd) stay apart and `--continue` finds them.
            persist="''${XDG_STATE_HOME:-$HOME/.local/state}/agent-harness/${name}-sandbox/projects/$(printf %s "$PWD" | sha256sum | cut -c1-16)"
            mkdir -p "$persist"
            printf '%s\n' "$PWD" > "$persist/.path"
            addMount "$persist" ${persistDir} false
          ''}

          # Dev shell: evaluated on the host, its environment written to
          # $work/devshell/env and mounted with the host's /nix/store.
          mkdir -m 700 "$work/devshell"
          envFile=$work/devshell/env
          toEnvFile() {
            python3 -I ${devshellEnv} "$@" ${lib.optionalString cfg.workspace.mount
            "--workspace \"$PWD\" ${lib.escapeShellArg cfg.workspace.target}"} > "$envFile"
          }
          hostCmd() {
            local bin
            bin=$(PATH=$hostPath; command -v "$1") || return 1
            shift
            PATH=$hostPath "$bin" "$@"
          }
          fromInstallable() {
            hostCmd nix print-dev-env --json "$1" > "$work/devshell.json" && toEnvFile --json "$work/devshell.json"
          }
          devshellFrom=""
          case $devshell in
            none) ;;
            auto)
              rc=""
              if (PATH=$hostPath; command -v direnv >/dev/null); then
                rc=$(hostCmd direnv status --json 2>/dev/null | jq -r '.state.foundRC // empty | "\(.allowed) \(.path)"') || rc=""
              fi
              if [ -n "$rc" ]; then
                # 0 allowed, 1 not allowed, 2 denied. Never allow it ourselves.
                if [ "''${rc%% *}" != 0 ]; then
                  echo "agent-harness: ''${rc#* } not allowed (direnv allow); starting without dev shell" >&2
                elif hostCmd direnv exec / ${pkgs.coreutils}/bin/env -0 > "$work/base.env" \
                  && hostCmd direnv exec "$PWD" ${pkgs.coreutils}/bin/env -0 > "$work/shell.env"; then
                  toEnvFile --direnv "$work/base.env" "$work/shell.env"
                  devshellFrom="''${rc#* }"
                else
                  echo "agent-harness: direnv failed (see above); starting without dev shell" >&2
                fi
              elif [ -f flake.nix ] && (PATH=$hostPath; command -v nix >/dev/null); then
                if has=$(hostCmd nix eval --json "$PWD#devShells.${system}" \
                  --apply 'builtins.hasAttr "default"' 2>"$work/eval.err"); then
                  if [ "$has" = true ]; then
                    if fromInstallable "$PWD#devShells.${system}.default"; then
                      devshellFrom="$PWD/flake.nix"
                    else
                      echo "agent-harness: nix print-dev-env failed (see above); starting without dev shell" >&2
                    fi
                  fi
                elif [[ $(<"$work/eval.err") != *"does not provide attribute"* ]]; then
                  cat "$work/eval.err" >&2
                  echo "agent-harness: could not evaluate flake.nix; starting without dev shell" >&2
                fi
              fi
              ;;
            *)
              # Asked for explicitly: a failure is fatal.
              fromInstallable "$devshell" || { echo "agent-harness: dev shell $devshell failed" >&2; exit 1; }
              devshellFrom=$devshell
              ;;
          esac
          if [ -n "$devshellFrom" ] && [ -s "$envFile" ]; then
            echo "agent-harness: dev shell from $devshellFrom (host /nix/store mounted read-only)" >&2
            addMount "$work/devshell" ${devshellDir} true
            addMount /nix/store /nix/store true
          fi

          if [ "$mounts" != '[]' ]; then
            args+=(--driver-config-json "$(jq -cn --argjson m "$mounts" '{${cfg.openshell.engine}: {mounts: $m}}')")
          fi
          openshell "''${args[@]}" -- agent-launch ${lib.escapeShellArgs hcfg.extraArgs} "$@"
        '';
      };
    in {
      inherit image wrapper;
      hostWrappers = lib.optional hcfg.host.enable hostWrapper;
    };

    built = lib.mapAttrs mkHarness enabled;

    harnessModule = name: def: {
      options = {
        enable = lib.mkEnableOption "${def.description} inside an OpenShell sandbox";

        package = lib.mkOption {
          type = lib.types.package;
          default = def.defaultPackage {inherit flakePackages pkgs;};
          defaultText = lib.literalMD "this flake's nixpkgs-unstable build";
          description = "The ${name} package to put in the sandbox image.";
        };

        host = {
          enable = lib.mkEnableOption "an unsandboxed ${name} command on the host, with the same configuration";
          command = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = ''
              Name of the unsandboxed host command. Must differ from
              `command`; when `command` takes the harness name, pick another
              (e.g. `${name}-unleashed`).
            '';
          };
          extensions = lib.mkOption {
            type = lib.types.listOf (lib.types.enum (lib.attrNames def.extensions));
            default = [];
            example = ["claude-bridge"];
            description = "Extensions loaded only by the host command (e.g. ones that need the host's own logins).";
          };
          environment = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = {};
            description = "Overrides of `environment` for the host command (e.g. host URLs instead of host.openshell.internal).";
          };
        };

        command = lib.mkOption {
          type = lib.types.str;
          default = "agent-${name}";
          example = name;
          description = "Name of the command that starts ${name} in a sandbox (on the host's PATH).";
        };

        skills = lib.mkOption {
          type = lib.types.listOf (lib.types.enum (lib.attrNames skillsRegistry));
          default = [];
          example = ["gitlab"];
          description = "Skills from this flake's skills/ directory to install.";
        };

        mcpServers = lib.mkOption {
          type = lib.types.listOf (lib.types.enum (lib.attrNames mcpRegistry));
          default = [];
          example = ["playwright"];
          description = "MCP servers from this flake's mcp-servers/ directory to run inside the sandbox.";
        };

        extensions = lib.mkOption {
          type = lib.types.listOf (lib.types.enum (lib.attrNames def.extensions));
          default = [];
          description = "Harness-specific extensions from extensions/${name}/ to load.";
        };

        settings = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
          description = "Harness settings, merged over this flake's defaults (see modules/harnesses/${name}.nix).";
        };

        extraPackages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [];
          description = "Extra tools to put on PATH inside the sandbox.";
        };

        extraArgs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Arguments always passed to the harness, before the command's own.";
        };

        providers = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = ''
            OpenShell providers to attach (`--provider`). This is the safe way
            to give the agent API keys: it sees a placeholder, and OpenShell
            injects the real key only toward the provider's endpoints.
          '';
        };

        environment = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {};
          example = {HINDSIGHT_SERVER_MODE = "self-hosted";};
          description = ''
            Fixed environment variables set inside the sandbox before the
            harness starts. They are baked into the image's launcher, so
            the agent can read them: never put secrets here.
          '';
        };

        extraExtensions = lib.mkOption {
          type = lib.types.listOf (lib.types.either lib.types.path lib.types.package);
          default = [];
          description = ''
            Extension files or directories from outside this flake's
            extensions/ directory (e.g. one built from an npm package), loaded
            after `extensions`.
          '';
        };

        envFrom = lib.mkOption {
          type = lib.types.listOf (lib.types.strMatching "[A-Za-z_][A-Za-z0-9_]*");
          default = [];
          example = ["OPENAI_BASE_URL"];
          description = ''
            Host environment variables copied into the sandbox when set
            (`--env NAME=value`). The agent can read these values directly,
            and they appear in the host's process list while the CLI runs;
            use `providers` for secrets.
          '';
        };

        autoProviders = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Let OpenShell auto-attach providers it detects (off: only `providers` are attached).";
        };

        persist = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Keep per-project state (sessions) across sandboxed runs, in
            $XDG_STATE_HOME/agent-harness/<harness>-sandbox/projects/<hash of
            the project path>, mounted read-write; the agent can edit it.
          '';
        };

        keep = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Keep the sandbox after the harness exits (default: delete it, `--no-keep`).";
        };
      };
    };
  in {
    options.programs.agent-harness = {
      harnesses = lib.mapAttrs (name: def:
        lib.mkOption {
          type = lib.types.submodule (harnessModule name def);
          default = {};
          description = "The ${def.description} harness.";
        })
      harnessRegistry;

      network = {
        allow = lib.mkOption {
          type = lib.types.listOf hl.allowEntryType;
          default = [];
          example = [
            "10.0.0.5/32"
            {
              cidr = "10.0.1.0/24";
              ports = [443 22];
            }
          ];
          description = ''
            IP ranges every sandbox may connect to. A bare string allows port
            443 only. Everything else is denied.
          '';
        };

        hostPorts = lib.mkOption {
          type = lib.types.listOf lib.types.port;
          default = [];
          example = [9077];
          description = ''
            TCP ports on the host machine the sandbox may reach, as
            `host.openshell.internal:<port>`. Needs a rootless podman
            gateway, and the service must listen on a non-loopback address
            (see README.md).
          '';
        };
      };

      secretEnvFiles = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        example = {OPENAI_API_KEY = "/run/secrets/openai-key";};
        description = ''
          Environment variables whose values are read from host files at
          each launch (variable name -> file): passed into every sandbox
          with `--env`, exported by host commands. Unlike `envFrom` the
          value never comes from your shell. The agent can still read it,
          and it shows in the host process list while the sandbox CLI
          runs; use a harness's `providers` for keys the agent must not
          see. llm.nix fills this from each provider's `apiKeyFile`.
        '';
      };

      workspace = {
        mount = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Bind-mount the directory the command runs from into the sandbox,
            read-write. Needs `enable_bind_mounts = true` in the gateway's
            driver table (set by `openshell.gateway`).
          '';
        };
        target = lib.mkOption {
          type = lib.types.str;
          default = "/sandbox/work";
          description = "Where the project appears inside the sandbox (also the harness's cwd).";
        };
      };

      devshell.auto = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Load the project's dev shell into sandboxes: the directory's
          direnv `.envrc` (only if `direnv allow`ed) or else its flake's
          `devShells.<system>.default`, evaluated on the host. Its
          environment is passed in, and the host's /nix/store is mounted
          read-only. `--devshell <installable>`, `--no-devshell` and
          `$AGENT_DEVSHELL` override it per run. See README.md, "Dev shells".
        '';
      };

      openshell = {
        package = lib.mkOption {
          type = lib.types.package;
          default = flakePackages.openshell;
          defaultText = lib.literalMD "this flake's nixpkgs-unstable build";
          description = "OpenShell CLI used to create sandboxes.";
        };
        engine = lib.mkOption {
          type = lib.types.enum ["docker" "podman"];
          default = "docker";
          description = "Container engine of the local gateway's compute driver; images are loaded into it.";
        };
      };

      image.base = lib.mkOption {
        type = lib.types.package;
        # OpenShell does not support FROM-scratch / distroless images, so
        # Nix store contents are layered on a pinned Debian slim.
        default = pkgs.dockerTools.pullImage {
          imageName = "debian";
          imageDigest = "sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc";
          hash = "sha256-w7nZ4JVH7FvxtJWjzVMXGh0fIJlg/VlEx4HieWKPD9c=";
          finalImageName = "debian";
          finalImageTag = "bookworm-slim";
          os = "linux";
          arch = "amd64";
        };
        defaultText = lib.literalMD "pinned `debian:bookworm-slim` (amd64)";
        description = "Base image the harness images are layered on.";
      };

      images = lib.mkOption {
        type = lib.types.attrsOf lib.types.package;
        readOnly = true;
        default = lib.mapAttrs (_: b: b.image) built;
        description = "Image stream script per enabled harness (for inspection or pushing to a remote gateway).";
      };
    };

    config = lib.mkIf (enabled != {}) {
      assertions =
        lib.concatMap (n: let
          h = enabled.${n};
        in [
          {
            assertion = !h.host.enable || (harnessRegistry.${n}.supportsHost or false);
            message = "programs.agent-harness.harnesses.${n}.host: ${n} has no unsandboxed mode (its launch would write into the real HOME).";
          }
          {
            assertion = !h.host.enable || h.command != h.host.command;
            message = "programs.agent-harness.harnesses.${n}: `command` and `host.command` are both \"${h.command}\"; give the sandboxed and the host command different names.";
          }
        ]) (lib.attrNames enabled)
        ++ map (n: {
          assertion = builtins.match "[A-Za-z_][A-Za-z0-9_]*" n != null;
          message = "programs.agent-harness.secretEnvFiles: \"${n}\" is not a valid environment variable name.";
        }) (lib.attrNames cfg.secretEnvFiles);
      home.packages =
        [cfg.openshell.package]
        ++ lib.concatMap (b: [b.wrapper] ++ b.hostWrappers) (lib.attrValues built);
    };
  };

  flake.homeManagerModules.default = config.flake.modules.homeManager.agent-harness;
}
