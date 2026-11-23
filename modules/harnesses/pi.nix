# Pi coding agent harness (https://pi.dev). See claude-code.nix for the
# harness definition shape.
#
# Pi specifics:
#   - Config lives in $PI_CODING_AGENT_DIR (here ~/.pi/agent inside the
#     sandbox). Its settings.json takes absolute `skills` and `extensions`
#     paths, so both are read straight from the store, unchanged.
#   - Extensions are Pi extension files or directories under extensions/pi/
#     (e.g. ws-edit.ts → "ws-edit").
#   - `settings` is merged over the defaults below into settings.json.
#   - MCP servers go in $PI_CODING_AGENT_DIR/mcp.json, read by Pi's
#     built-in MCP extension (builtin:mcp, on by default).
#   - Pi needs fd and ripgrep on PATH or it tries to download them; both are
#     in every sandbox image's base tools.
{lib, ...}: let
  hl = import ../../lib {inherit lib;};
in {
  flake.agentHarnesses.pi = {
    description = "Pi terminal coding agent";
    defaultPackage = {flakePackages, ...}: flakePackages.pi-coding-agent;
    extensions = hl.discoverDir ../../extensions/pi;

    launch = {
      pkgs,
      package,
      skills,
      extensions,
      settings,
      mcpConfig,
    }: let
      settingsFile = pkgs.writeText "pi-settings.json" (builtins.toJSON (lib.recursiveUpdate {
          enableInstallTelemetry = false;
          skills = ["${skills}"];
          extensions = map (e: "${e}") extensions;
        }
        settings));
    in ''
      export PI_CODING_AGENT_DIR="$HOME/.pi/agent"
      export PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0
      mkdir -p "$PI_CODING_AGENT_DIR"
      cp --no-preserve=mode ${settingsFile} "$PI_CODING_AGENT_DIR/settings.json"
      ${lib.optionalString (mcpConfig != null) ''cp --no-preserve=mode ${mcpConfig} "$PI_CODING_AGENT_DIR/mcp.json"''}
      exec ${lib.getExe package} "$@"
    '';
  };
}
