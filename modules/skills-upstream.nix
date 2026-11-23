# Skills from upstream repos: the skill content of the Claude Code plugins in
# nix-config's modules/home/remote-ai.nix. Each repo is a pinned
# `flake = false` input (see flake.nix), so `nix flake update <input>`
# upgrades it. Every skill directory under a source's `root` is registered
# automatically, exactly like skills/; the only thing kept here is the tools
# a skill needs, since an upstream repo cannot carry our skill.nix.
#
# Only the harness-agnostic part of each plugin comes in. Claude Code
# plugin hooks, MCP servers and LSP configs are not skills; see README.md.
{
  inputs,
  lib,
  ...
}: let
  hl = import ../lib {inherit lib;};

  # impeccable's launcher downloads its engine binary from GitHub on first
  # use, which the sandbox blocks. Fetch it here instead: version and sha256
  # are read from the pinned skill's own VERSION / engine-checksums.txt, so
  # bumping the input bumps the engine. The launcher finds it on PATH.
  impeccableEngine = pkgs: let
    scripts = "${inputs.impeccable}/.agents/skills/impeccable/scripts";
    version = lib.trim (builtins.readFile "${scripts}/VERSION");
    asset =
      {
        x86_64-linux = "impeccable-linux-x64";
        aarch64-linux = "impeccable-linux-arm64";
      }.${
        pkgs.stdenv.hostPlatform.system
      } or (throw "impeccable: no engine build for ${pkgs.stdenv.hostPlatform.system}");
    line =
      lib.findFirst (l: lib.hasPrefix "${version} ${asset} " l)
      (throw "impeccable: no checksum for ${version} ${asset}")
      (lib.splitString "\n" (builtins.readFile "${scripts}/engine-checksums.txt"));
  in
    pkgs.stdenvNoCC.mkDerivation {
      pname = "impeccable-engine";
      inherit version;
      src = pkgs.fetchurl {
        url = "https://github.com/pbakaus/impeccable/releases/download/engine-v${version}/${asset}";
        sha256 = lib.last (lib.splitString " " (lib.trim line));
      };
      dontUnpack = true;
      # Prebuilt single-file binary for a generic glibc system (the sandbox
      # image's Debian base). Strip/patchelf could corrupt an embedded
      # payload, so install it untouched.
      dontFixup = true;
      installPhase = "install -Dm755 $src $out/bin/impeccable";
      meta.mainProgram = "impeccable";
    };

  sources = {
    # anthropics/claude-plugins-official → frontend-design
    frontend-design.root = "${inputs.claude-plugins-official}/plugins/frontend-design/skills";

    # pbakaus/impeccable. .agents/ is upstream's generic Agent Skills build
    # (it says "<skill-base-dir>" where the Claude build says
    # ${CLAUDE_SKILL_DIR}).
    impeccable = {
      root = "${inputs.impeccable}/.agents/skills";
      extraPackages.impeccable = pkgs: [(impeccableEngine pkgs)];
    };

    # JuliusBrussee/caveman. The caveman-* Cloud skills (setup, manage,
    # learn, optimize, discover, evidence-review, stats) call the `caveman`
    # CLI and Caveman Cloud. Like remote-ai.nix, this flake does not install
    # that CLI, so those skills report it missing.
    caveman = {
      root = "${inputs.caveman}/skills";
      extraPackages.caveman-compress = pkgs: [
        (pkgs.python3.withPackages (ps: [ps.anthropic ps.tiktoken]))
      ];
    };

    # morluto/rea → reverse-engineer-anything. Taken from the npm tarball,
    # not the repo, so the skill matches the MCP server version
    # (mcp-servers/rea.nix). The skill only describes the tools; select the
    # `rea` MCP server alongside it.
    rea.root = "${inputs.rea-agents}/skills";
  };
in {
  flake.agentSkills = lib.mkMerge (lib.mapAttrsToList (_: s:
    hl.discoverSkills {
      root = s.root;
      extraPackages = s.extraPackages or {};
    })
  sources);
}
