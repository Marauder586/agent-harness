# Long-term agent memory with Hindsight (https://hindsight.vectorize.io).
# Home-manager aspect: runs the server as a podman user service, lets
# sandboxes reach it (a `hindsight` network policy), selects the `hindsight`
# extension in every harness that has one, puts the `hindsight` CLI on the
# host PATH, and optionally runs the web dashboard (Control Plane) as a
# second container. Flake aspect: packages the CLI (per-system package
# hindsight-cli). See README.md, "Memory (Hindsight)".
{
  config,
  lib,
  withSystem,
  ...
}: let
  # Harnesses that ship a `hindsight` extension (extensions/<harness>/).
  supported =
    lib.attrNames (lib.filterAttrs (_: def: def.extensions ? hindsight) config.flake.agentHarnesses);

  # The CLI and both server images move together: bump all three here.
  version = "1.3.0";

  # Release assets per platform (only linux: the binary is ELF, patched
  # for nix's glibc/openssl with autoPatchelfHook). Only x86_64-linux is
  # instantiated (modules/systems.nix); aarch64-linux is ready if
  # systems.nix grows. The repo also ships darwin binaries, unsigned.
  cliAssets = {
    x86_64-linux = {
      asset = "linux-amd64";
      hash = "sha256-+/7SHV7TBys6X45mfaYEgm4BjLsKzJJyarzIAPT7vsc=";
    };
    aarch64-linux = {
      asset = "linux-arm64";
      hash = "sha256-UbnSEqfEdOHLfeA6oO21qt5pUQ27WNVXbX7QJvK+6t0=";
    };
  };
in {
  # The Hindsight CLI (`hindsight`), the prebuilt release binary from the
  # hindsight repo — the same artifact https://hindsight.vectorize.io/get-cli
  # installs. Put on the host PATH by programs.agent-harness.hindsight.enable.
  perSystem = {
    pkgs,
    system,
    ...
  }: {
    packages.hindsight-cli = pkgs.stdenvNoCC.mkDerivation {
      pname = "hindsight-cli";
      inherit version;

      src = pkgs.fetchurl {
        url = "https://github.com/vectorize-io/hindsight/releases/download/v${version}/hindsight-${cliAssets.${system}.asset}";
        hash = cliAssets.${system}.hash;
      };

      dontUnpack = true;
      dontConfigure = true;

      # The binary links glibc, libgcc and expects libssl.so.3 /
      # libcrypto.so.3.
      nativeBuildInputs = [pkgs.autoPatchelfHook];
      buildInputs = [pkgs.libgcc pkgs.openssl];

      installPhase = ''
        runHook preInstall
        install -Dm755 $src $out/bin/hindsight
        runHook postInstall
      '';

      meta = {
        description = "Command-line client for the Hindsight semantic memory API";
        homepage = "https://hindsight.vectorize.io";
        license = pkgs.lib.licenses.mit;
        mainProgram = "hindsight";
        sourceProvenance = with pkgs.lib.sourceTypes; [binaryNativeCode];
        platforms = pkgs.lib.attrNames cliAssets;
      };
    };
  };
  flake.modules.homeManager.agent-harness = {
    config,
    pkgs,
    lib,
    ...
  }: let
    # This flake's build of the hindsight CLI (perSystem package in this
    # file).
    flakePackages = withSystem pkgs.stdenv.hostPlatform.system ({config, ...}: config.packages);
    cfg = config.programs.agent-harness.hindsight;
    llmReady = cfg.llm.provider != null;

    serverEnv =
      {
        HINDSIGHT_API_LLM_PROVIDER = cfg.llm.provider;
        HINDSIGHT_API_EMBEDDINGS_PROVIDER = "local";
        HINDSIGHT_API_EMBEDDINGS_LOCAL_MODEL = "BAAI/bge-small-en-v1.5";
        HINDSIGHT_API_EMBEDDINGS_LOCAL_FORCE_CPU = "true";
        HINDSIGHT_API_RERANKER_PROVIDER = "local";
        HINDSIGHT_API_RERANKER_LOCAL_MODEL = "hindsight-ai/hs-rerank-1";
        HINDSIGHT_API_RERANKER_LOCAL_FORCE_CPU = "true";
        HINDSIGHT_API_KB_EMBEDDINGS_PROVIDER = "text";
        # Models are preloaded in the image; never reach Hugging Face.
        HF_HUB_OFFLINE = "1";
      }
      // lib.optionalAttrs (cfg.llm.model != null) {HINDSIGHT_API_LLM_MODEL = cfg.llm.model;}
      // lib.optionalAttrs (cfg.llm.baseUrl != null) {HINDSIGHT_API_LLM_BASE_URL = cfg.llm.baseUrl;}
      // lib.optionalAttrs (cfg.mentalModelRefreshLLMMaxConcurrent != null) {
        HINDSIGHT_API_MENTAL_MODEL_REFRESH_LLM_MAX_CONCURRENT = toString cfg.mentalModelRefreshLLMMaxConcurrent;
      }
      // lib.optionalAttrs (cfg.llmMaxConcurrent != null) {
        HINDSIGHT_API_LLM_MAX_CONCURRENT = toString cfg.llmMaxConcurrent;
      }
      // lib.optionalAttrs (cfg.workerMaxSlots != null) {
        HINDSIGHT_API_WORKER_MAX_SLOTS = toString cfg.workerMaxSlots;
      }
      // lib.optionalAttrs (cfg.workers != null) {HINDSIGHT_API_WORKERS = toString cfg.workers;}
      // lib.optionalAttrs (cfg.mentalModels.minRefreshIntervalSeconds != null) {
        HINDSIGHT_API_MENTAL_MODEL_MIN_REFRESH_INTERVAL_SECONDS = toString cfg.mentalModels.minRefreshIntervalSeconds;
      }
      // lib.optionalAttrs (cfg.mentalModels.refreshTickSeconds != null) {
        HINDSIGHT_API_MENTAL_MODEL_REFRESH_TICK_SECONDS = toString cfg.mentalModels.refreshTickSeconds;
      }
      // cfg.extraEnvironment;

    start = pkgs.writeShellScript "agent-hindsight-start" ''
      set -eu
      # The image refuses to start without a key ("API key is required"),
      # so a keyless endpoint gets a dummy one.
      ${
        if cfg.llm.apiKeyFile != null
        then "HINDSIGHT_API_LLM_API_KEY=$(cat ${lib.escapeShellArg cfg.llm.apiKeyFile})"
        else "HINDSIGHT_API_LLM_API_KEY=none"
      }
      export HINDSIGHT_API_LLM_API_KEY
      exec podman run --rm --replace --name agent-hindsight \
        --pull=missing \
        --publish ${toString cfg.port}:8888 \
        --volume agent-hindsight-data:/home/hindsight/.pg0 \
        --env HINDSIGHT_API_LLM_API_KEY \
        ${lib.concatStringsSep " \\\n        " (lib.mapAttrsToList (k: v: "--env ${lib.escapeShellArg "${k}=${v}"}") serverEnv)} \
        ${lib.escapeShellArg cfg.image}
    '';
    dashEnv = {
      # The API server, through its published host port: the container
      # runs with host networking, so the dashboard's server-side proxy
      # reaches it on loopback. The browser never talks to the API
      # directly - the control plane proxies everything.
      HINDSIGHT_CP_DATAPLANE_API_URL = "http://127.0.0.1:${toString cfg.port}";
      HINDSIGHT_CP_PORT = toString cfg.dashboard.port;
    };

    # The access key, if any, is read into HINDSIGHT_CP_ACCESS_KEY by the
    # start script, so it stays off the podman command line (the API key
    # above gets the same treatment).
    dashStart = pkgs.writeShellScript "agent-hindsight-dashboard-start" ''
      set -eu
      ${
        if cfg.dashboard.accessKeyFile != null
        then ''
          HINDSIGHT_CP_ACCESS_KEY=$(cat ${lib.escapeShellArg cfg.dashboard.accessKeyFile})
          export HINDSIGHT_CP_ACCESS_KEY''
        else ""
      }
      exec podman run --rm --replace --name agent-hindsight-dashboard \
        --pull=missing \
        --network=host \
        ${lib.concatStringsSep " \\\n        " (lib.mapAttrsToList (k: v: "--env ${lib.escapeShellArg "${k}=${v}"}") dashEnv)} \
        ${lib.escapeShellArg cfg.dashboard.image}
    '';
  in {
    options.programs.agent-harness.hindsight = {
      enable = lib.mkEnableOption "Hindsight long-term memory, served from this machine";

      harnesses = lib.mkOption {
        type = lib.types.listOf (lib.types.enum supported);
        default = supported;
        description = "Harnesses that get Hindsight's extension (when they are enabled).";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 9077;
        description = ''
          Host port the server listens on, published on every host address
          (see README.md); keep it closed in the host firewall.
        '';
      };

      image = lib.mkOption {
        type = lib.types.str;
        default = "ghcr.io/vectorize-io/hindsight-api:${version}@sha256:c054765e9196fb1fe63497be06bcb55256c9024cc9314f951dc59858985ab242";
        description = "Hindsight API image (the full variant: it bundles the local embedding and rerank models).";
      };

      maxParallelRetains = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        example = 4;
        description = ''
          How many retain (memory-save) queries the harness extension sends
          to the server at once (HINDSIGHT_MAX_PARALLEL_RETAINS). Each one
          runs fact extraction, so this caps the burst of LLM calls a
          session end can trigger. Null uses the extension's default (10).
        '';
      };

      mentalModelRefreshLLMMaxConcurrent = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        example = 4;
        description = ''
          How many mental model refreshes can run at once
          (HINDSIGHT_API_MENTAL_MODEL_REFRESH_LLM_MAX_CONCURRENT), a
          server-side cap on the concurrent refresh LLM calls. Null uses
          the server's own default.
        '';
      };

      llmMaxConcurrent = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        example = 8;
        description = ''
          How many LLM calls the server runs at once across all work
          (HINDSIGHT_API_LLM_MAX_CONCURRENT). Null uses the server's own
          default.
        '';
      };

      mentalModels = {
        trigger = lib.mkOption {
          type = lib.types.enum ["cron" "auto-refresh" "manual"];
          default = "cron";
          description = ''
            When the extension's pages (Hindsight mental models) refresh
            (HINDSIGHT_PAGE_TRIGGER_TYPE): `"cron"` on `mentalModels.cron`,
            and only when new memories arrived since the last refresh;
            `"auto-refresh"` after every consolidation, i.e. whenever new
            memories are processed (most current, one LLM synthesis per page
            each time); `"manual"` never on their own. Each session re-syncs
            the pages the extension created to this, existing ones included.
          '';
        };
        cron = lib.mkOption {
          type = lib.types.str;
          default = "H * * * *";
          example = "H H(0-5) * * *";
          description = ''
            Refresh schedule for `trigger = "cron"`
            (HINDSIGHT_PAGE_TRIGGER_CRON): UTC, standard 5 fields. A field
            written as `H` gets a per-page value hashed from the bank and page
            name, so pages don't all refresh at once: `"H * * * *"` (the
            default) is hourly at each page's own minute, `"H H * * *"` daily.
          '';
        };
        minRefreshIntervalSeconds = lib.mkOption {
          type = lib.types.nullOr lib.types.ints.unsigned;
          default = null;
          example = 21600;
          description = ''
            Server-wide floor between two refreshes of one mental model
            (HINDSIGHT_API_MENTAL_MODEL_MIN_REFRESH_INTERVAL_SECONDS), whatever
            triggered them. Null uses the server's default (0, no floor).
          '';
        };
        refreshTickSeconds = lib.mkOption {
          type = lib.types.nullOr lib.types.ints.positive;
          default = null;
          example = 60;
          description = ''
            How often the server checks for cron refreshes that are due
            (HINDSIGHT_API_MENTAL_MODEL_REFRESH_TICK_SECONDS). Null uses the
            server's default (300).
          '';
        };
      };

      workerMaxSlots = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        example = 8;
        description = ''
          Slots per background worker (HINDSIGHT_API_WORKER_MAX_SLOTS):
          how many tasks one worker can process at once. Null uses the
          server's own default.
        '';
      };

      workers = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        example = 4;
        description = ''
          How many background workers the server runs
          (HINDSIGHT_API_WORKERS). Null uses the server's own default.
        '';
      };

      dashboard = {
        enable = lib.mkEnableOption ''
          the Hindsight Control Plane, the web UI for browsing banks,
          entities and recall results. It runs as a second container
          (systemd user service agent-hindsight-dashboard) next to the API
          server, on host port 9999 by default.
        '';

        port = lib.mkOption {
          type = lib.types.port;
          default = 9999;
          description = ''
            Host port the dashboard listens on. The container uses host
            networking, so it binds this port on every host address
            directly; keep it closed in the host firewall.
          '';
        };

        image = lib.mkOption {
          type = lib.types.str;
          default = "ghcr.io/vectorize-io/hindsight-control-plane:${version}@sha256:df58ce2597e837f359684cfe0e004aaa93bbb89983f1f1b8bd2cab881b457554";
          description = "Hindsight Control Plane image (stateless: the dashboard only proxies the API).";
        };

        accessKeyFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "/run/secrets/hindsight-dashboard-key";
          description = ''
            File holding the access key that protects the dashboard
            (HINDSIGHT_CP_ACCESS_KEY), read when the service starts. Null
            leaves the dashboard unauthenticated.
          '';
        };
      };

      llm = {
        provider = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "openai";
          description = ''
            Hindsight LLM provider for fact extraction and reflection
            (`openai` for any OpenAI-compatible server, `anthropic`,
            `ollama`, …). Null leaves the server stopped.
          '';
        };
        model = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Model id. Null uses Hindsight's default for the provider.";
        };
        baseUrl = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "http://spark:8000/v1";
          description = "Endpoint for self-hosted or OpenAI-compatible providers.";
        };
        apiKeyFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "/run/secrets/hindsight-llm-key";
          description = "File holding the provider API key, read when the service starts.";
        };
      };

      extraEnvironment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Extra HINDSIGHT_API_* settings for the server. Not for secrets: they show in the podman command line.";
      };
    };

    config = lib.mkIf cfg.enable (lib.mkMerge [
      {
        assertions = [
          {
            assertion = config.programs.agent-harness.openshell.engine == "podman";
            message = "programs.agent-harness.hindsight needs openshell.engine = \"podman\" (rootless podman with pasta), the only setup where sandboxes can reach host.openshell.internal.";
          }
        ];
        warnings =
          lib.optional (!llmReady) ''
            programs.agent-harness.hindsight: no LLM is set (programs.agent-harness.llm.default,
            or hindsight.llm.provider), so the Hindsight server is not started and
            agents run without memory.
          ''
          ++ lib.optional (cfg.dashboard.enable && !llmReady) ''
            programs.agent-harness.hindsight.dashboard.enable is set, but no LLM is
            configured, so the Hindsight server is not running and the dashboard
            service is not created either.
          '';

        # The server on the host, as OpenShell's alias for it. Allowed only
        # through OpenShell's trusted-gateway check (rootless podman with
        # pasta); plain TCP, so no TLS detection.
        programs.agent-harness.network.policies.hindsight = {
          endpoints = [
            {
              host = "host.openshell.internal";
              port = cfg.port;
              tls = "skip";
            }
          ];
          binaries = [{path = "/**";}];
        };

        # The `hindsight` CLI in your own terminal, pointed at the local
        # server (the CLI reads HINDSIGHT_API_URL with the highest
        # priority, so a value of your own in home.sessionVariables or a
        # shell export still wins, e.g. for a Hindsight Cloud bank).
        home.packages = [flakePackages.hindsight-cli];
        home.sessionVariables.HINDSIGHT_API_URL = "http://127.0.0.1:${toString cfg.port}";

        programs.agent-harness.harnesses = lib.genAttrs cfg.harnesses (h: {
          extensions = ["hindsight"];
          host.environment.HINDSIGHT_API_URL = "http://127.0.0.1:${toString cfg.port}";
          environment =
            {
              HINDSIGHT_SERVER_MODE = "self-hosted";
              HINDSIGHT_API_URL = "http://host.openshell.internal:${toString cfg.port}";
              # Pinned by Nix; the runtime must not re-stage itself from npm.
              HINDSIGHT_AUTO_UPDATE = "false";
              HINDSIGHT_PAGE_TRIGGER_TYPE = cfg.mentalModels.trigger;
              HINDSIGHT_PAGE_TRIGGER_CRON = cfg.mentalModels.cron;
            }
            // lib.optionalAttrs (cfg.maxParallelRetains != null) {
              HINDSIGHT_MAX_PARALLEL_RETAINS = toString cfg.maxParallelRetains;
            };
        });
      }

      (lib.mkIf llmReady {
        systemd.user.services.agent-hindsight = {
          Unit = {
            Description = "Hindsight memory server for sandboxed coding agents";
            After = ["network-online.target"];
          };
          Service = {
            # The host's podman, with its setuid uidmap helpers.
            Environment = ["PATH=/run/wrappers/bin:/run/current-system/sw/bin:${config.home.profileDirectory}/bin:/usr/bin:/bin"];
            ExecStart = "${start}";
            # A script, so podman resolves via the PATH above (systemd looks up
            # bare commands on its own fixed path).
            ExecStop = "${pkgs.writeShellScript "agent-hindsight-stop" "exec podman stop --time 75 agent-hindsight"}";
            # First start pulls a multi-GB image.
            TimeoutStartSec = "infinity";
            TimeoutStopSec = 90;
            Restart = "on-failure";
            RestartSec = 10;
          };
          Install.WantedBy = ["default.target"];
        };
      })

      (lib.mkIf (llmReady && cfg.dashboard.enable) {
        systemd.user.services.agent-hindsight-dashboard = {
          Unit = {
            Description = "Hindsight Control Plane (web dashboard) for the local Hindsight server";
            After = ["agent-hindsight.service" "network-online.target"];
          };
          Service = {
            Environment = ["PATH=/run/wrappers/bin:/run/current-system/sw/bin:${config.home.profileDirectory}/bin:/usr/bin:/bin"];
            ExecStart = "${dashStart}";
            # First start pulls the image.
            TimeoutStartSec = "infinity";
            # Stateless: no volume, no graceful-stop dance.
            Restart = "on-failure";
            RestartSec = 10;
          };
          Install.WantedBy = ["default.target"];
        };
      })
    ]);
  };
}
