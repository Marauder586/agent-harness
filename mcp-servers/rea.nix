# REA (https://github.com/morluto/rea) over MCP; see README.md. The
# `reverse-engineer-anything` skill comes from the same tarball
# (modules/skills-upstream.nix).
#
# Built from the published npm tarball (the `rea-agents` input), not the
# repo: the tarball ships compiled dist/ and bundles its node_modules, so
# nothing is fetched at build or run time. Upstream's own mcp.json runs
# `npx rea-agents mcp`, which the sandbox network policies would block.
#
# Optional pieces not installed: the `frida` optionalDependency (runtime
# instrumentation) and native engines (Ghidra, Hopper, IDA). Static
# JavaScript/Electron analysis needs none of them. Add an engine with the
# harness's `extraPackages`, e.g. pkgs.ghidra.
{
  pkgs,
  inputs,
}: let
  inherit (pkgs) lib;
  nodejs = pkgs.nodejs_24;
  arch =
    {
      x86_64-linux = "linux-x64";
      aarch64-linux = "linux-arm64";
    }.${
      pkgs.stdenv.hostPlatform.system
    } or (throw "rea: no node-pty prebuild for ${pkgs.stdenv.hostPlatform.system}");

  rea = pkgs.stdenv.mkDerivation {
    pname = "rea-agents";
    version = (lib.importJSON "${inputs.rea-agents}/package.json").version;
    src = inputs.rea-agents;

    nativeBuildInputs = [pkgs.makeWrapper pkgs.autoPatchelfHook];
    # node-pty's prebuilt pty.node links libstdc++.
    buildInputs = [pkgs.stdenv.cc.cc.lib];

    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/rea-agents
      cp -r . $out/lib/rea-agents
      cd $out/lib/rea-agents
      # Keep only this platform's node-pty prebuild, so autoPatchelf has
      # nothing foreign (darwin/win32/other-arch) to choke on.
      for d in node_modules/@lydell/node-pty-*; do
        [ "$d" = node_modules/@lydell/node-pty-${arch} ] || rm -rf "$d"
      done
      rm -rf native/windows
      # Not read at run time: source maps, type declarations, and the
      # README's images. skills/ stays: the guidance tools read it.
      find . \( -name '*.map' -o -name '*.d.ts' \) -delete
      rm -rf website assets
      makeWrapper ${lib.getExe nodejs} $out/bin/rea \
        --add-flags $out/lib/rea-agents/scripts/rea.mjs
      runHook postInstall
    '';

    meta = {
      description = "Reverse Engineer Anything: CLI and MCP server";
      homepage = "https://github.com/morluto/rea";
      license = lib.licenses.mit;
      mainProgram = "rea";
    };
  };
in {
  description = "Reverse engineering of binaries, apps and websites (REA)";
  server = {
    command = lib.getExe rea;
    args = ["mcp"];
  };
  # `rea` on PATH too: the skill's recovery steps call the CLI directly.
  packages = [rea];
}
