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
#   launch         : { pkgs, package, skills, extensions, settings,
#                      mcpConfig } -> str
#                    Bash run inside the sandbox (HOME=/sandbox, cwd = the
#                    mounted project). Must end by exec'ing the harness
#                    with "$@". `skills` is one directory of
#                    <name>/SKILL.md entries; `extensions` is a list of
#                    store paths; `settings` is the user's free-form attrs;
#                    `mcpConfig` is null or a JSON file in the shared
#                    `{"mcpServers": {...}}` format.
#
# Claude Code specifics:
#   - Skills are copied into ~/.claude/skills so they keep their plain
#     names ("gitlab", not "plugin:gitlab"), matching Pi.
#   - Extensions are Claude Code plugin directories
#     (extensions/claude-code/<name>/.claude-plugin/plugin.json), loaded
#     read-only from the store with --plugin-dir.
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
    }: let
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
      mkdir -p "$HOME/.claude/skills"
      cp -rL --no-preserve=mode ${skills}/. "$HOME/.claude/skills/"
      exec ${lib.getExe package} \
        --settings ${settingsFile} \
        ${lib.optionalString (mcpConfig != null) "--mcp-config ${mcpConfig} "}\
        ${lib.concatMapStrings (e: "--plugin-dir ${e} ") extensions}"$@"
    '';
  };
}
