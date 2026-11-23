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

    # ── Upstream skills: see modules/skills-upstream.nix ──────
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

    # See mcp-servers/rea.nix (and its skill in modules/skills-upstream.nix).
    rea-agents = {
      url = "https://registry.npmjs.org/rea-agents/-/rea-agents-6.10.1.tgz";
      flake = false;
    };

    # See extensions/pi/hindsight/.
    hindsight-coding-agents = {
      url = "https://registry.npmjs.org/@vectorize-io/hindsight-coding-agents/-/hindsight-coding-agents-0.8.8.tgz";
      flake = false;
    };

    # See extensions/pi/mcp-adapter/.
    pi-mcp-adapter = {
      url = "https://registry.npmjs.org/pi-mcp-adapter/-/pi-mcp-adapter-7.0.1.tgz";
      flake = false;
    };

    # See extensions/pi/subagents/. Not on npm (that name is another project).
    pi-subagents = {
      url = "github:edxeth/pi-subagents/v2.9.2";
      flake = false;
    };

    # See extensions/pi/claude-bridge/.
    pi-claude-bridge = {
      url = "https://registry.npmjs.org/pi-claude-bridge/-/pi-claude-bridge-0.11.0.tgz";
      flake = false;
    };

    # See extensions/pi/ask-user-question/ (the package and its one dependency).
    rpiv-ask-user-question = {
      url = "https://registry.npmjs.org/@juicesharp/rpiv-ask-user-question/-/rpiv-ask-user-question-2.15.0.tgz";
      flake = false;
    };
    rpiv-config = {
      url = "https://registry.npmjs.org/@juicesharp/rpiv-config/-/rpiv-config-2.15.0.tgz";
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
