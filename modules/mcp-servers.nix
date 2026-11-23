# Discovers every MCP server under mcp-servers/. Each <name>.nix file
# describes one stdio server in the common `mcpServers` entry format that
# Claude Code, Pi and most MCP clients share (see mcp-servers/playwright.nix),
# so a server is defined once and works in every harness. Add a file and
# "<name>" becomes a valid value of every harness's `mcpServers` option.
# The registry holds each file's function; the home-manager module calls it
# through hl.callWith (modules/home/agent-harness.nix).
{lib, ...}: let
  root = ../mcp-servers;
  files =
    lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".nix" n)
    (builtins.readDir root);
in {
  flake.agentMcpServers = lib.mapAttrs' (file: _:
    lib.nameValuePair (lib.removeSuffix ".nix" file) (import (root + "/${file}")))
  files;
}
