# Home-manager aspect: one registry of LLM endpoints (`programs.agent-harness
# .llm`), wired into every enabled harness, Hindsight and the network
# policies. See README.md, "LLM providers".
#
# Warning: an `apiKeyFile` value is passed into the sandbox
# (secretEnvFiles), where the agent can read it. For a key the agent must
# not see, use an OpenShell provider (`harnesses.<h>.providers`) instead.
{...}: {
  flake.modules.homeManager.agent-harness = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.programs.agent-harness.llm;

    keyEnv = name: "AGENT_LLM_${lib.toUpper (lib.replaceStrings ["-" "."] ["_" "_"] name)}_API_KEY";

    # http(s)://<host>[:port][/...] -> { host; port; ipv4 }, or null when
    # the URL has another shape. ipv4 is the host when it is a literal
    # IPv4 address, else null.
    parseUrl = url: let
      m = builtins.match "(https?)://(\\[[^]]+]|[^/:?#]+)(:([0-9]+))?([/?#].*)?" url;
      host = builtins.elemAt m 1;
    in
      if m == null
      then null
      else {
        inherit host;
        port =
          if builtins.elemAt m 3 != null
          then lib.toInt (builtins.elemAt m 3)
          else if builtins.elemAt m 0 == "https"
          then 443
          else 80;
        ipv4 =
          if builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+" host != null
          then host
          else null;
      };

    # The OpenShell network policy entry a provider gets by default: its
    # baseUrl's host and port. A literal IPv4 host also gets an
    # `allowed_ips` entry for exactly that address, which OpenShell needs
    # for literal-IP endpoints on private ranges. No `protocol`, so traffic
    # is passed through uninspected, as an API client expects.
    policyFromUrl = url: let
      u = parseUrl url;
    in
      if u == null
      then null
      else {
        endpoints = [
          ({inherit (u) host port;}
            // lib.optionalAttrs (u.ipv4 != null) {allowed_ips = ["${u.ipv4}/32"];})
        ];
        binaries = [{path = "/**";}];
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
        # Removed: replaced by `network`. Kept hidden so setting it fails
        # with a pointer (mkRemovedOptionModule only works at the top level).
        allow = lib.mkOption {
          type = lib.types.unspecified;
          default = null;
          visible = false;
        };
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
        network = lib.mkOption {
          type = lib.types.nullOr (pkgs.formats.json {}).type;
          default = policyFromUrl config.baseUrl;
          defaultText = lib.literalMD "the baseUrl's host and port as one endpoint, for every binary";
          example = {
            endpoints = [
              {
                host = "llm.lan";
                port = 8000;
                allowed_ips = ["10.0.0.9/32"];
              }
            ];
            binaries = [{path = "/**";}];
          };
          description = ''
            The OpenShell network policy entry the sandbox needs to reach this
            endpoint, in OpenShell's schema. Added to network.policies as
            `llm-<name>`. Null adds none (e.g. when another policy covers it).
          '';
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

    # Addresses OpenShell never lets a sandbox reach (loopback, link-local),
    # checked on each provider's baseUrl so the error comes at evaluation.
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
              assertion = p.allow == null;
              message = "programs.agent-harness.llm.providers.${n}.allow was removed. The provider now gets an OpenShell network policy entry, `network` (network.policies.llm-${n}), which defaults to the baseUrl's host and port; set `network` in OpenShell's schema to change it.";
            }
            {
              assertion = parseUrl p.baseUrl != null || p.network != null;
              message = "programs.agent-harness.llm.providers.${n}: could not read a host from baseUrl; set `network` to the OpenShell policy entry the sandbox needs.";
            }
            {
              assertion = let
                u = parseUrl p.baseUrl;
              in
                u == null || !(isLocalRange (lib.removePrefix "[" (lib.removeSuffix "]" u.host)) || lib.toLower u.host == "localhost");
              message = "programs.agent-harness.llm.providers.${n}: loopback and link-local addresses (127.0.0.0/8, ::1, 169.254.0.0/16, fe80::/10) are never reachable from the sandbox. For a model served on this machine, listen on a LAN address and use that in baseUrl.";
            }
          ])
          cfg.providers);

        programs.agent-harness.network.policies =
          lib.mapAttrs' (n: p: lib.nameValuePair "llm-${n}" p.network)
          (lib.filterAttrs (_: p: p.network != null) cfg.providers);
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
