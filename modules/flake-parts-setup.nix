# Flake-level registries every other module contributes to.
#
# `flake` is freeform with `raw` values, which do not merge across files, so
# each registry is declared here as a mergeable lazyAttrsOf (same trick as
# nix-config's flake.homeConfigurations). That lets each harness file and the
# skills scanner add their own entries independently.
#
#   flake.agentSkills.<name>    — discovered from skills/ (modules/skills.nix)
#   flake.agentHarnesses.<name> — one per modules/harnesses/*.nix
#
# Also enables flake-parts' `flake.modules.<class>.<name>` option, which the
# home-manager and NixOS aspects publish themselves through.
{
  inputs,
  lib,
  ...
}: {
  imports = [inputs.flake-parts.flakeModules.modules];

  options.flake = {
    agentSkills = lib.mkOption {
      type = lib.types.lazyAttrsOf lib.types.raw;
      default = {};
      description = ''
        Harness-agnostic Agent Skills, keyed by skill name. Each value is
        `{ src; packages; }`: `src` is the skill directory (SKILL.md plus
        supporting files, skill.nix stripped) and `packages` is
        `pkgs -> [derivation]`, the runtime tools the skill needs.
      '';
    };

    agentMcpServers = lib.mkOption {
      type = lib.types.lazyAttrsOf lib.types.raw;
      default = {};
      description = ''
        Harness-agnostic MCP servers, keyed by server name. Each value is
        `{pkgs}: { description; server; packages ? []; }`, where `server` is
        one entry of the shared `mcpServers` JSON format.
      '';
    };

    agentHarnesses = lib.mkOption {
      type = lib.types.lazyAttrsOf lib.types.raw;
      default = {};
      description = ''
        Harness definitions, keyed by harness name. See
        modules/harnesses/claude-code.nix for the expected shape.
      '';
    };
  };
}
