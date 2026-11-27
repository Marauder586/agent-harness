# pi-subagents (https://github.com/edxeth/pi-subagents): named subagents for
# Pi, each a separate Pi process (see README.md).
#
# How children run inside the sandbox:
#   - `mode: background` agents are headless `pi -p` children, spawned with
#     the parent's own node + Pi entry point and environment (so the same
#     PI_CODING_AGENT_DIR, settings.json, skills and extensions). This works
#     in the sandbox as is.
#   - `mode: interactive` (upstream's default) opens a pane in herdr, cmux,
#     tmux, zellij or WezTerm. The sandboxed Pi is not started inside a
#     multiplexer, so these launches fail with a setup hint. The agents
#     shipped here are all background agents.
#   - Agents are required: the tool refuses ad-hoc children. They are read
#     from $PI_CODING_AGENT_DIR/agents/ and the project's .pi/agents/. The
#     definitions in ./agents (passthru.piAgentsDir) are copied into the
#     former at launch by modules/harnesses/pi.nix; project agents with the
#     same name win.
#   - `llm-as-a-verifier` agents are not supported: they build a Python venv
#     with pip/uv on first use, which the network policies block.
#
# Built from the pinned `pi-subagents` input (a git tag; the package is not
# on npm). It has no runtime dependencies: its only imports are Pi's own
# packages and typebox, which Pi's extension loader aliases to its copies.
{
  pkgs,
  inputs,
}: let
  inherit (pkgs) lib;
  src = inputs.pi-subagents;
in
  pkgs.runCommand "pi-subagents-${(lib.importJSON "${src}/package.json").version}" {
    passthru.piAgentsDir = ./agents;
    meta = {
      description = "Named background and interactive subagents for Pi";
      homepage = "https://github.com/edxeth/pi-subagents";
      license = lib.licenses.mit;
    };
  } ''
    # package.json's `pi.extensions` points Pi at src/index.ts.
    mkdir -p $out
    cp -r ${src}/package.json ${src}/src ${src}/LICENSE ${src}/README.md $out/
  ''
