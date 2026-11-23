# Home-manager aspect: one registry of LLM endpoints (`programs.agent-harness
# .llm`), wired into every enabled harness, Hindsight and the network
# allowlist. See README.md, "LLM providers".
#
# Warning: an `apiKeyFile` value is passed into the sandbox
# (secretEnvFiles), where the agent can read it. For a key the agent must
# not see, use an OpenShell provider (`harnesses.<h>.providers`) instead.
{...}: {
  flake.modules.homeManager.agent-harness = {
    config,
    lib,
    ...
  }: let
    hl = import ../../lib {inherit lib;};
    cfg = config.programs.agent-harness.llm;

    keyEnv = name: "AGENT_LLM_${lib.toUpper (lib.replaceStrings ["-" "."] ["_" "_"] name)}_API_KEY";

    # http(s)://<ipv4>[:port][/...] → one allow entry; null for hostnames.
    allowFromUrl = url: let
      m = builtins.match "(https?)://([0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+)(:([0-9]+))?(/.*)?" url;
    in
      if m == null
      then null
      else {
        cidr = "${builtins.elemAt m 1}/32";
        ports = [
          (
            if builtins.elemAt m 3 != null
            then lib.toInt (builtins.elemAt m 3)
            else if builtins.elemAt m 0 == "https"
            then 443
            else 80
          )
        ];
      };

    modelModule = {
      options = {
        id = lib.mkOption {
          type = lib.types.str;
          description = "Model id sent to the API.";
        };
        name = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Display name.";
        };
        reasoning = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether the model supports thinking.";
        };
        input = lib.mkOption {
          type = lib.types.listOf (lib.types.enum ["text" "image"]);
          default = ["text"];
        };
        contextWindow = lib.mkOption {
          type = lib.types.nullOr lib.types.ints.positive;
          default = null;
          description = "Context window in tokens (null: harness default).";
        };
        maxTokens = lib.mkOption {
          type = lib.types.nullOr lib.types.ints.positive;
          default = null;
          description = "Maximum output tokens (null: harness default).";
        };
        extra = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
          description = "Extra fields merged into the model's Pi models.json entry (compat, samplingParams, cost, …).";
        };
      };
    };

    providerModule = {
      name,
      config,
      ...
    }: {
      options = {
        displayName = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        baseUrl = lib.mkOption {
          type = lib.types.str;
          example = "http://10.0.0.20:8000/v1";
          description = "API base URL, as the harness's client expects it (OpenAI-compatible: ending in /v1).";
        };
        api = lib.mkOption {
          type = lib.types.enum ["openai-completions" "openai-responses" "anthropic-messages"];
          default = "openai-completions";
          description = "Wire protocol. vLLM, SGLang, llama.cpp and Ollama speak openai-completions.";
        };
        apiKeyFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Host file holding the API key, read at each launch. Null: the endpoint needs no key.";
        };
        models = lib.mkOption {
          type = lib.types.listOf (lib.types.submodule modelModule);
          default = [];
          description = "Models this endpoint serves.";
        };
        compat = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
          description = "Pi `compat` overrides for the whole provider (e.g. thinkingFormat).";
        };
        allow = lib.mkOption {
          type = lib.types.listOf hl.allowEntryType;
          default = lib.optional (allowFromUrl config.baseUrl != null) (allowFromUrl config.baseUrl);
          defaultText = lib.literalMD "the baseUrl's address and port, when baseUrl uses an IP address";
          description = "Allowlist entries the sandbox needs to reach this endpoint.";
        };
        keyEnv = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = keyEnv name;
          description = "Sandbox variable holding the key (when apiKeyFile is set).";
        };
      };
    };

    defaultProvider = cfg.defaultProvider;

    # Ranges policy-gen.py refuses at launch (OpenShell would block the
    # whole endpoint), checked here so the error comes at evaluation.
    ipv4Int = a: lib.foldl (acc: x: acc * 256 + lib.toInt x) 0 (lib.splitString "." a);
    pow2 = n: lib.foldl (acc: _: acc * 2) 1 (lib.range 1 n);
    parseIpv4 = c: let
      m = builtins.match "([0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+)(/([0-9]+))?" c;
    in
      if m == null
      then null
      else {
        addr = ipv4Int (builtins.elemAt m 0);
        len =
          if builtins.elemAt m 2 == null
          then 32
          else lib.toInt (builtins.elemAt m 2);
      };
    ipv4Overlaps = cidr: net: let
      a = parseIpv4 cidr;
      b = parseIpv4 net;
      shift = pow2 (32 - lib.min a.len b.len);
    in
      a != null && a.addr / shift == b.addr / shift;
    isLocalRange = cidr: let
      c = lib.toLower cidr;
    in
      lib.any (ipv4Overlaps c) ["127.0.0.0/8" "169.254.0.0/16"]
      || builtins.match "::1(/128)?" c != null
      || builtins.match "fe[89ab][0-9a-f]?:.*" c != null;
  in {
    options.programs.agent-harness.llm = {
      providers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule providerModule);
        default = {};
        description = "LLM endpoints, wired into every enabled harness.";
      };
      default = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            provider = lib.mkOption {type = lib.types.str;};
            model = lib.mkOption {type = lib.types.str;};
          };
        });
        default = null;
        description = "Model harnesses start with, and Hindsight's extraction model.";
      };
      defaultProvider = lib.mkOption {
        type = lib.types.nullOr lib.types.attrs;
        readOnly = true;
        default =
          if cfg.default == null
          then null
          else cfg.providers.${cfg.default.provider} or null;
        defaultText = lib.literalMD "the `llm.providers` entry `default` names, or null";
        description = "The provider `default` names (null when unset).";
      };
    };

    config = lib.mkMerge [
      {
        assertions = [
          {
            assertion = cfg.default == null || defaultProvider != null;
            message = "programs.agent-harness.llm.default.provider '${toString (cfg.default.provider or "")}' is not in llm.providers.";
          }
          {
            assertion =
              defaultProvider
              == null
              || lib.any (m: m.id == cfg.default.model) defaultProvider.models;
            message = "programs.agent-harness.llm.default.model is not one of that provider's models.";
          }
        ];
      }

      (lib.mkIf (cfg.providers != {}) {
        assertions = lib.concatLists (lib.mapAttrsToList (n: p: [
            {
              assertion = p.allow != [];
              message = "programs.agent-harness.llm.providers.${n}: baseUrl uses a hostname, so set `allow` to the addresses the sandbox may reach it on.";
            }
            {
              assertion = !lib.any (e: isLocalRange e.cidr) p.allow;
              message = "programs.agent-harness.llm.providers.${n}: loopback and link-local addresses (127.0.0.0/8, ::1, 169.254.0.0/16, fe80::/10) are never reachable from the sandbox. For a model served on this machine, listen on a LAN address and use that in baseUrl.";
            }
          ])
          cfg.providers);

        programs.agent-harness.network.allow = lib.concatMap (p: p.allow) (lib.attrValues cfg.providers);
        programs.agent-harness.secretEnvFiles =
          lib.mapAttrs' (_: p: lib.nameValuePair p.keyEnv p.apiKeyFile)
          (lib.filterAttrs (_: p: p.apiKeyFile != null) cfg.providers);

        programs.agent-harness.hindsight.llm = lib.mkIf (defaultProvider != null) {
          provider = lib.mkDefault (
            if defaultProvider.api == "anthropic-messages"
            then "anthropic"
            else "openai"
          );
          baseUrl = lib.mkDefault defaultProvider.baseUrl;
          model = lib.mkDefault cfg.default.model;
          apiKeyFile = lib.mkDefault defaultProvider.apiKeyFile;
        };
      })
    ];
  };
}
