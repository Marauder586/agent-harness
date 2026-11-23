# pi-claude-bridge (https://github.com/elidickinson/pi-claude-bridge): Claude
# Code as a Pi model provider. It registers the `claude-bridge` provider with
# every Claude model in pi-ai's Anthropic catalog; a turn on one of them runs
# Claude Code through the Claude Agent SDK, with Pi's tools bridged in over
# an in-process MCP server, so tool calls still go through Pi.
#
# Claude Code comes with it: passthru.packages puts this flake's
# `claude-code` package on PATH (modules/home/agent-harness.nix), and
# postPatch makes it the bridge's default executable, so selecting the
# extension is enough. The Agent SDK would otherwise run the native `claude`
# from its per-platform optional packages
# (@anthropic-ai/claude-agent-sdk-<platform>); those are removed from the
# lockfile and never fetched. A `provider.pathToClaudeCodeExecutable` in
# $PI_CODING_AGENT_DIR/claude-bridge.json still overrides the default.
#
# Authentication is Claude Code's own (see README.md).
#
# Built from the published npm tarball (the `pi-claude-bridge` input). Its
# dependencies are not bundled, so package-lock.json here pins them. It was
# generated from the tarball's package.json with devDependencies,
# peerDependencies and scripts removed (`stripFields`), using
#   npm install --package-lock-only --ignore-scripts
# and then the eight node_modules/@anthropic-ai/claude-agent-sdk-<platform>
# entries, and the SDK entry's optionalDependencies, deleted with jq.
# Regenerate it, and npmDepsHash, when bumping the input. The peer
# dependencies (@earendil-works/pi-*) are left out: Pi's extension loader
# aliases them to its own copies.
{
  pkgs,
  inputs,
  flakePackages,
}: let
  inherit (pkgs) lib;
  claude-code = flakePackages.claude-code;
in
  import ../../../lib/pi-npm-extension.nix {
    inherit pkgs;
    pname = "pi-claude-bridge";
    src = inputs.pi-claude-bridge;
    packageLock = ./package-lock.json;
    stripFields = ["devDependencies" "peerDependencies" "scripts"];
    npmDepsHash = "sha256-++5xGKw4hV236xSC0fWQds109K8ssEEB8XvnIssnZCM=";

    # Default to the Nix Claude Code instead of the SDK's bundled binary.
    postPatch = ''
      substituteInPlace src/config.ts \
        --replace-fail 'provider: { ...global.provider }' \
          'provider: { pathToClaudeCodeExecutable: "${lib.getExe claude-code}", ...global.provider }'
    '';

    passthru.packages = [claude-code];

    meta = {
      description = "Claude Code (via the Claude Agent SDK) as a Pi model provider";
      homepage = "https://github.com/elidickinson/pi-claude-bridge";
      license = lib.licenses.mit;
    };
  }
