# Harness CLIs and openshell from this flake's own (unstable) nixpkgs, with
# unfree allowed for claude-code. The home-manager module defaults to these,
# so a consumer on a stable channel still gets current versions; override any
# of them per harness with `package = ...`.
{inputs, ...}: {
  perSystem = {system, ...}: let
    pkgs = import inputs.nixpkgs {
      inherit system;
      config.allowUnfree = true;
    };
  in {
    _module.args.pkgs = pkgs;

    packages = {
      inherit (pkgs) openshell claude-code pi-coding-agent;
    };

    formatter = pkgs.alejandra;
  };
}
