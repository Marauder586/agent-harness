# Claude Code harness.
#
# A harness definition only says how to start one agent CLI with a given
# skills tree; image building, sandboxing, network policy and option
# plumbing are shared (modules/home/agent-harness.nix). Shape:
#
#   description    : str
#   defaultPackage : { flakePackages, pkgs } -> derivation
#   extensions     : { name = path; }  harness-specific add-ons, discovered
#                    from extensions/<harness>/ (never listed by hand)
#   supportsHost   : bool (optional, default false). Whether `launch` is
#                    safe to run unsandboxed on the host (host.enable).
#   persists       : bool (optional, default false). Whether the harness
#                    keeps state in $AGENT_HARNESS_PERSIST, the per-project
#                    directory the sandbox mounts at /sandbox/.persist
#                    (harnesses.<h>.persist). Unset: nothing is mounted.
#   launch         : { pkgs, package, skills, extensions, settings,
#                      mcpConfig, llm } -> str  (takes the args it names)
#                    Bash run inside the sandbox (HOME=/sandbox, cwd = the
#                    mounted project), or by the host command. Must end by
#                    exec'ing the harness with "$@". `skills` is one
#                    directory of <name>/SKILL.md entries; `extensions` is
#                    a list of store paths; `settings` is the user's
#                    free-form attrs; `mcpConfig` is null or a shell word
#                    naming a JSON file in the shared `{"mcpServers": {...}}`
#                    format; `llm` is programs.agent-harness.llm
#                    (modules/home/llm.nix).
#                    $AGENT_HARNESS_STATE is always set (sandbox:
#                    /sandbox/.<harness>). A harness with supportsHost must
#                    write only under $AGENT_HARNESS_STATE at launch.
#
# Claude Code specifics:
#   - Skills are copied into ~/.claude/skills so they keep their plain
#     names ("gitlab", not "plugin:gitlab"), matching Pi.
#   - Extensions are Claude Code plugin directories
#     (extensions/claude-code/<name>/.claude-plugin/plugin.json), loaded
#     read-only from the store with --plugin-dir.
#   - LLM registry: when programs.agent-harness.llm.default is an
#     `anthropic-messages` provider, Claude Code is pointed at it
#     (ANTHROPIC_BASE_URL, ANTHROPIC_MODEL, ANTHROPIC_AUTH_TOKEN). Other
#     APIs cannot drive Claude Code and are left out.
#   - `settings` is merged over the defaults below and passed with
#     --settings, so it never has to be written into the sandbox home.
{lib, ...}: let
  hl = import ../../lib {inherit lib;};
in {
  flake.agentHarnesses.claude-code = {
    description = "Anthropic's Claude Code CLI";
    defaultPackage = {flakePackages, ...}: flakePackages.claude-code;
    extensions = hl.discoverDir ../../extensions/claude-code;

    launch = {
      pkgs,
      package,
      skills,
      extensions,
      settings,
      mcpConfig,
      llm,
    }: let
      dp = llm.defaultProvider;
      useRegistry = dp != null && dp.api == "anthropic-messages";
      settingsFile = pkgs.writeText "claude-code-settings.json" (builtins.toJSON (lib.recursiveUpdate {
          # Nothing outside the allowlist is reachable anyway; these stop
          # Claude Code from trying (and logging) blocked connections.
          env = {
            DISABLE_TELEMETRY = "1";
            DISABLE_ERROR_REPORTING = "1";
            DISABLE_AUTOUPDATER = "1";
            CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
          };
        }
        settings));
    in ''
      ${lib.optionalString useRegistry ''
        export ANTHROPIC_BASE_URL=${lib.escapeShellArg dp.baseUrl}
        export ANTHROPIC_MODEL=${lib.escapeShellArg llm.default.model}
        ${lib.optionalString (dp.apiKeyFile != null) ''export ANTHROPIC_AUTH_TOKEN="''${${dp.keyEnv}:-}"''}
      ''}
      mkdir -p "$HOME/.claude/skills"
      cp -rL --no-preserve=mode ${skills}/. "$HOME/.claude/skills/"
      exec ${lib.getExe package} \
        --settings ${settingsFile} \
        ${lib.optionalString (mcpConfig != null) "--mcp-config ${mcpConfig} "}\
        ${lib.concatMapStrings (e: "--plugin-dir ${e} ") extensions}"$@"
    '';
  };
}
