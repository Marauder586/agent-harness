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
# Each enabled harness gets a command (default `agent-<harness>`) that:
#   1. loads the harness's Nix-built OCI image into docker/podman if missing,
#   2. builds an OpenShell policy from network.allow plus the root-owned
#      network.allowFile (lib/policy-gen.py),
#   3. runs `openshell sandbox create --from <image> --policy <policy>
#      --no-keep -- agent-launch "$@"`, with $PWD bind-mounted at
#      /sandbox/work.
#
# Requires a running OpenShell gateway with the matching compute driver
# (`openshell status`). Bind-mounting $PWD also needs the gateway opt-in
# described in README.md.
{
  config,
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

    mkHarness = name: hcfg: let
      def = harnessRegistry.${name};
      skillsDir = mkSkillsDir name hcfg.skills;

      # Selected MCP servers, evaluated against the consumer's pkgs, and
      # rendered once as the shared `mcpServers` JSON every harness reads.
      mcp = lib.genAttrs hcfg.mcpServers (s: mcpRegistry.${s} {inherit pkgs;});
      mcpConfig =
        if mcp == {}
        then null
        else
          pkgs.writeText "agent-${name}-mcp.json" (builtins.toJSON {
            mcpServers = lib.mapAttrs (_: m:
              m.server
              // lib.optionalAttrs (m ? description) {inherit (m) description;})
            mcp;
          });

      launcher = pkgs.writeShellScriptBin "agent-launch" ''
        set -eu
        export HOME=/sandbox
        cd ${cfg.workspace.target} 2>/dev/null || cd "$HOME"
        ${def.launch {
          inherit pkgs mcpConfig;
          inherit (hcfg) package settings;
          skills = skillsDir;
          extensions = map (e: def.extensions.${e}) hcfg.extensions;
        }}
      '';

      env = pkgs.buildEnv {
        name = "agent-${name}-env";
        paths =
          [hcfg.package launcher]
          ++ baseTools
          ++ lib.concatMap (s: skillsRegistry.${s}.packages pkgs) hcfg.skills
          ++ lib.concatMap (m: m.packages or []) (lib.attrValues mcp)
          ++ hcfg.extraPackages;
      };

      # Store paths are referenced from `config`, so they land in the image
      # closure without symlinking anything over the base image's /bin.
      # Only cacert goes in `contents`, to supply /etc/ssl/certs (the slim
      # base has none).
      image = pkgs.dockerTools.streamLayeredImage {
        name = "agent-harness-${name}";
        fromImage = cfg.image.base;
        contents = [pkgs.cacert];
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

      wrapper = pkgs.writeShellApplication {
        name = hcfg.command;
        runtimeInputs = [cfg.openshell.package pkgs.jq pkgs.python3 pkgs.coreutils];
        text = ''
          ref=${lib.escapeShellArg imageRef}
          if ! ${engine} image inspect "$ref" >/dev/null 2>&1; then
            echo "agent-harness: loading $ref into ${cfg.openshell.engine}" >&2
            ${image} | ${engine} load >&2
          fi

          policy=$(mktemp -t agent-harness-policy.XXXXXX)
          trap 'rm -f "$policy"' EXIT
          python3 -I ${policyGen} \
            --uid "$(id -u)" --gid "$(id -g)" \
            --conf ${allowConf} \
            ${lib.optionalString (cfg.network.allowFile != null) "--system-conf ${lib.escapeShellArg cfg.network.allowFile}"} \
            > "$policy"

          base=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-' | tr -s '-')
          name="${name}-''${base#-}"
          name="''${name:0:50}-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"

          args=(sandbox create --name "$name" --from "$ref" --policy "$policy")
          ${lib.optionalString (!hcfg.keep) "args+=(--no-keep)"}
          ${lib.optionalString (!hcfg.autoProviders) "args+=(--no-auto-providers)"}
          ${lib.concatMapStrings (p: "args+=(--provider ${lib.escapeShellArg p})\n") hcfg.providers}
          ${lib.concatMapStrings (v: ''
              if [ -n "''${${v}+set}" ]; then args+=(--env "${v}=''${${v}}"); fi
            '')
            hcfg.envFrom}
          ${lib.optionalString cfg.workspace.mount ''
            mount=$(jq -cn --arg src "$PWD" --arg dst ${lib.escapeShellArg cfg.workspace.target} \
              '{${cfg.openshell.engine}: {mounts: [{type: "bind", source: $src, target: $dst, read_only: false}]}}')
            args+=(--driver-config-json "$mount")
          ''}
          openshell "''${args[@]}" -- agent-launch ${lib.escapeShellArgs hcfg.extraArgs} "$@"
        '';
      };
    in {inherit image wrapper;};

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

        command = lib.mkOption {
          type = lib.types.str;
          default = "agent-${name}";
          description = "Name of the host command that starts ${name} in a sandbox.";
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
            443 only. Merged with `allowFile`. Everything else is denied.
          '';
        };

        allowFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = "/etc/openshell/network.conf";
          description = ''
            Root-owned allowlist read at every launch, same line format as
            the generated one (`<ip-or-cidr> [port,...]`). A missing file adds
            nothing. A file not owned by root, or writable by anyone but
            root, makes the launch fail. Set it with the
            `openshell-network` NixOS module, or by hand on other distros.
            Null disables it.
          '';
        };
      };

      workspace = {
        mount = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Bind-mount the directory the command runs from into the sandbox,
            read-write. Needs `allow_driver_config`, `enable_bind_mounts` and
            resource admission disabled on the gateway's driver.
          '';
        };
        target = lib.mkOption {
          type = lib.types.str;
          default = "/sandbox/work";
          description = "Where the project appears inside the sandbox (also the harness's cwd).";
        };
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
      home.packages = [cfg.openshell.package] ++ lib.mapAttrsToList (_: b: b.wrapper) built;
    };
  };

  flake.homeManagerModules.default = config.flake.modules.homeManager.agent-harness;
}
