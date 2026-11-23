# Pi coding agent harness (https://pi.dev). See claude-code.nix for the
# harness definition shape.
#
# Pi specifics:
#   - Config lives in $PI_CODING_AGENT_DIR ($AGENT_HARNESS_STATE/agent:
#     /sandbox/.pi/agent in the sandbox). Its settings.json takes absolute `skills` and `extensions`
#     paths, so both are read straight from the store, unchanged.
#   - Extensions are Pi extension files or directories under extensions/pi/
#     (e.g. ws-edit.ts → "ws-edit"); a directory is loaded through its
#     package.json `pi.extensions`.
#   - `settings` is merged over the defaults below into settings.json.
#   - MCP servers go in $PI_CODING_AGENT_DIR/mcp.json, read by Pi's
#     built-in MCP extension (builtin:mcp, on by default), or by the
#     `mcp-adapter` extension (extensions/pi/mcp-adapter/) when selected.
#     An extension whose passthru sets `disablesPiBuiltinMcp` gets
#     `-builtin:mcp` added to settings.json, so the two never both run and
#     the adapter has nothing to rewrite at startup.
#   - An extension whose passthru sets `piAgentsDir` (e.g. subagents) gets
#     that directory's *.md agent definitions copied into
#     $PI_CODING_AGENT_DIR/agents/ (writable, so the /subagents overlay can
#     toggle them).
#   - LLM providers (programs.agent-harness.llm) become models.json
#     providers, keys read from their AGENT_LLM_*_API_KEY variables; the
#     registry's `default` becomes defaultProvider/defaultModel.
#   - Pi needs fd and ripgrep on PATH or it tries to download them; both are
#     in every sandbox image's base tools.
{lib, ...}: let
  hl = import ../../lib {inherit lib;};
in {
  flake.agentHarnesses.pi = {
    description = "Pi terminal coding agent";
    defaultPackage = {flakePackages, ...}: flakePackages.pi-coding-agent;
    # launch writes only under $AGENT_HARNESS_STATE, never the real ~/.pi.
    supportsHost = true;
    extensions = hl.discoverDir ../../extensions/pi;

    launch = {
      pkgs,
      package,
      skills,
      extensions,
      settings,
      mcpConfig,
      llm,
    }: let
      llmSettings = lib.optionalAttrs (llm.default != null) {
        defaultProvider = llm.default.provider;
        defaultModel = llm.default.model;
      };
      modelsFile = pkgs.writeText "pi-models.json" (builtins.toJSON {
        providers = lib.mapAttrs (_: p:
          {
            inherit (p) baseUrl api;
            # Pi lists a provider's models only when it has a key; a
            # keyless endpoint gets a dummy one.
            apiKey =
              if p.apiKeyFile != null
              then "\$${p.keyEnv}"
              else "none";
            models = map (m:
              {inherit (m) id reasoning input;}
              // lib.optionalAttrs (m.name != null) {inherit (m) name;}
              // lib.optionalAttrs (m.contextWindow != null) {inherit (m) contextWindow;}
              // lib.optionalAttrs (m.maxTokens != null) {inherit (m) maxTokens;}
              // m.extra)
            p.models;
          }
          // lib.optionalAttrs (p.displayName != null) {name = p.displayName;}
          // lib.optionalAttrs (p.compat != {}) {inherit (p) compat;})
        llm.providers;
      });
      settingsFile = pkgs.writeText "pi-settings.json" (builtins.toJSON (lib.recursiveUpdate {
          enableInstallTelemetry = false;
          skills = ["${skills}"];
          extensions =
            map (e: "${e}") extensions
            ++ lib.optional (lib.any (e: e.disablesPiBuiltinMcp or false) extensions) "-builtin:mcp";
        }
        (lib.recursiveUpdate llmSettings settings)));
      agentsDirs = lib.unique (lib.concatMap (e: lib.optional (e ? piAgentsDir) e.piAgentsDir) extensions);
    in ''
      export PI_CODING_AGENT_DIR="$AGENT_HARNESS_STATE/agent"
      export PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0
      mkdir -p "$PI_CODING_AGENT_DIR"
      cp --no-preserve=mode ${settingsFile} "$PI_CODING_AGENT_DIR/settings.json"
      # The host command's state dir persists: drop what this launch does
      # not rewrite, so no stale file survives a config change.
      ${
        if llm.providers != {}
        then ''cp --no-preserve=mode ${modelsFile} "$PI_CODING_AGENT_DIR/models.json"''
        else ''rm -f "$PI_CODING_AGENT_DIR/models.json"''
      }
      ${
        if mcpConfig != null
        then ''cp --no-preserve=mode ${mcpConfig} "$PI_CODING_AGENT_DIR/mcp.json"''
        else ''rm -f "$PI_CODING_AGENT_DIR/mcp.json"''
      }
      rm -rf "$PI_CODING_AGENT_DIR/agents"
      ${lib.concatMapStrings (d: ''
          mkdir -p "$PI_CODING_AGENT_DIR/agents"
          cp --no-preserve=mode ${d}/*.md "$PI_CODING_AGENT_DIR/agents/"
        '')
        agentsDirs}
      exec ${lib.getExe package} "$@"
    '';
  };
}
