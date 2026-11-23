{
  description = "Sandboxed coding-agent harnesses (Claude Code, Pi) with harness-agnostic skills, run inside OpenShell";

  inputs = {
    # Unstable: harness CLIs and openshell move fast, and 26.05's openshell
    # predates the 0.1.x policy schema this flake generates.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Only used by checks (evaluates the home-manager module end to end).
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # ── Upstream skills (modules/skills-upstream.nix) ─────────
    # The skill content of the Claude Code plugins enabled in nix-config's
    # remote-ai.nix, pinned to the versions installed there. Source only.
    claude-plugins-official = {
      url = "github:anthropics/claude-plugins-official";
      flake = false;
    };
    impeccable = {
      url = "github:pbakaus/impeccable/skill-v4.10.0";
      flake = false;
    };
    caveman = {
      url = "github:JuliusBrussee/caveman/v4.2.0";
      flake = false;
    };

    # ── Composability ─────────────────────────────────────────
    # Same dendritic layout as ~/nix-config: every .nix file under modules/ is
    # a flake-parts module, auto-imported by import-tree. Drop a harness file
    # in modules/harnesses/ or a skill dir in skills/ and it is wired in;
    # nothing keeps a hand-maintained list.
    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:denful/import-tree";
  };

  outputs = inputs @ {
    flake-parts,
    import-tree,
    ...
  }:
    flake-parts.lib.mkFlake {inherit inputs;} (import-tree ./modules);
}
