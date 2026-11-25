# Home-manager aspect: long-term agent memory with Hindsight
# (https://hindsight.vectorize.io). Runs the server as a podman user
# service, lets sandboxes reach it (network.hostPorts), selects the
# `hindsight` extension in every harness that has one, and optionally
# runs the web dashboard (Control Plane) as a second container. See
# README.md, "Memory (Hindsight)".
{
  config,
  lib,
  ...
}: let
  # Harnesses that ship a `hindsight` extension (extensions/<harness>/).
  supported =
    lib.attrNames (lib.filterAttrs (_: def: def.extensions ? hindsight) config.flake.agentHarnesses);
in {
  flake.modules.homeManager.agent-harness = {
    config,
    pkgs,
    lib,
    ...
  }: let
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
        then
          ''
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
        default = "ghcr.io/vectorize-io/hindsight-api:1.2.3@sha256:2f318da3489f6493a5ec78f3d7019cd70835383fe4f4ffd1af9e080babd91d6c";
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
          default = "ghcr.io/vectorize-io/hindsight-control-plane:1.2.3@sha256:660f011039fb97aa224957e690ff805c0a4b64242656787d4532561679fb04fc";
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

        programs.agent-harness.network.hostPorts = [cfg.port];
        programs.agent-harness.harnesses = lib.genAttrs cfg.harnesses (h: {
          extensions = ["hindsight"];
          host.environment.HINDSIGHT_API_URL = "http://127.0.0.1:${toString cfg.port}";
          environment = {
            HINDSIGHT_SERVER_MODE = "self-hosted";
            HINDSIGHT_API_URL = "http://host.openshell.internal:${toString cfg.port}";
            # Pinned by Nix; the runtime must not re-stage itself from npm.
            HINDSIGHT_AUTO_UPDATE = "false";
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
