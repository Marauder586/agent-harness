# pi-mcp-adapter (https://github.com/nicobailon/pi-mcp-adapter): replaces
# Pi's built-in MCP support with one `mcp` proxy tool and lazy servers (see
# README.md). It reads the same $PI_CODING_AGENT_DIR/mcp.json.
#
# Pi itself steps aside: an extension that registers `/mcp` replaces the
# built-in for the session (Pi docs/mcp.md, "Replace the built-in MCP
# support"), and the harness also writes `-builtin:mcp` to settings.json
# (passthru.disablesPiBuiltinMcp, read by modules/harnesses/pi.nix).
#
# Built from the published npm tarball (the `pi-mcp-adapter` input). Its
# dependencies are not bundled, so package-lock.json here pins them. It was
# generated from the tarball's package.json with devDependencies and
# scripts removed (the default `stripFields`), using
#   npm install --package-lock-only --legacy-peer-deps --ignore-scripts
# Regenerate it, and npmDepsHash, when bumping the input. Peer dependencies
# (typebox, @earendil-works/pi-*) are left out: Pi's extension loader
# aliases them to its own copies.
{
  pkgs,
  inputs,
}:
import ../../../lib/pi-npm-extension.nix {
  inherit pkgs;
  pname = "pi-mcp-adapter";
  src = inputs.pi-mcp-adapter;
  packageLock = ./package-lock.json;
  npmDepsHash = "sha256-527AKVOQm4/4pddoa5GYWnq5goHcazpAR+1bTs1Ck+U=";
  npmFlags = ["--legacy-peer-deps"];

  # Prebuilt native pieces: @napi-rs/keyring's .node and recheck's binary.
  nativeBuildInputs = [pkgs.autoPatchelfHook];
  buildInputs = [pkgs.stdenv.cc.cc.lib pkgs.zlib];

  # recheck-jar is recheck's 23 MB Java fallback; the native
  # recheck-linux-x64 is used instead, and the sandbox has no JVM.
  postInstall = ''
    rm -rf $out/node_modules/recheck-jar
    find $out -name '*.map' -delete
  '';

  passthru.disablesPiBuiltinMcp = true;

  meta = {
    description = "MCP adapter extension for Pi: proxy tool, lazy servers";
    homepage = "https://github.com/nicobailon/pi-mcp-adapter";
    license = pkgs.lib.licenses.mit;
  };
}
