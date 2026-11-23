# Home-manager aspect: long-term agent memory with Hindsight
# (https://hindsight.vectorize.io). Runs the server as a podman user
# service, lets sandboxes reach it (network.hostPorts), and selects the
# `hindsight` extension in every harness that has one. See README.md,
# "Memory (Hindsight)".
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
        warnings = lib.optional (!llmReady) ''
          programs.agent-harness.hindsight: no LLM is set (programs.agent-harness.llm.default,
          or hindsight.llm.provider), so the Hindsight server is not started and
          agents run without memory.
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
            Environment = ["PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/bin:/bin"];
            ExecStart = "${start}";
            ExecStop = "podman stop --time 75 agent-hindsight";
            # First start pulls a multi-GB image.
            TimeoutStartSec = "infinity";
            TimeoutStopSec = 90;
            Restart = "on-failure";
            RestartSec = 10;
          };
          Install.WantedBy = ["default.target"];
        };
      })
    ]);
  };
}
