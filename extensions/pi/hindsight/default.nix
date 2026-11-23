# Hindsight memory for Pi: the `pi.js` extension from the pinned
# @vectorize-io/hindsight-coding-agents tarball. Selected by
# programs.agent-harness.hindsight.enable (modules/home/hindsight.nix), which
# also points it at the local server; see README.md.
#
# Only what Pi's extension uses is copied, not the 17 MB dist/ of every
# harness's hooks. pi.js bundles its dependencies, but at run time it
# spawns sibling scripts next to itself (deepen.js for the git-log seed,
# mcp-server.js and survey-supervisor.js for the codebase survey) and
# reads ../skill and ../package.json, so those come along. package.json
# gets a `pi.extensions` entry so Pi loads the directory.
{
  pkgs,
  inputs,
}: let
  inherit (pkgs) lib;
  src = inputs.hindsight-coding-agents;
in
  pkgs.runCommand "pi-hindsight-${(lib.importJSON "${src}/package.json").version}" {
    meta = {
      description = "Hindsight long-term memory extension for Pi";
      homepage = "https://hindsight.vectorize.io";
    };
  } ''
    mkdir -p $out/dist
    cp ${src}/dist/{pi,deepen,mcp-server,survey-supervisor}.js $out/dist/
    cp -r ${src}/skill $out/skill
    ${lib.getExe pkgs.jq} '{name, version, type, pi: {extensions: ["./dist/pi.js"]}}' \
      ${src}/package.json > $out/package.json
  ''
