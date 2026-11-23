# Harness CLIs and openshell from this flake's own (unstable) nixpkgs, with
# unfree allowed for claude-code. The home-manager module defaults to these,
# so a consumer on a stable channel still gets current versions; override any
# of them per harness with `package = ...`.
#
# nixpkgs builds only the openshell CLI. openshell-gateway is the
# openshell-server crate of the same source, so it is built from the CLI's
# derivation (same tag, same vendored dependencies): the versions always match.
{inputs, ...}: {
  perSystem = {system, ...}: let
    pkgs = import inputs.nixpkgs {
      inherit system;
      config.allowUnfree = true;
    };
    openshell-gateway = pkgs.openshell.overrideAttrs (old: {
      pname = "openshell-gateway";
      postPatch = ''
        substituteInPlace Cargo.toml \
          --replace-fail 'version = "0.0.0"' 'version = "${old.version}"' \
          --replace-fail 'members = ["crates/*"]' 'members = ["crates/openshell-server"]'
      '';
      cargoBuildFlags = ["-p" "openshell-server" "--bin" "openshell-gateway"];
      # System libs nixpkgs' cargo hook links instead of vendored copies:
      # aws-lc for rustls' aws-lc-rs backend, sqlite for sqlx.
      buildInputs = old.buildInputs ++ [pkgs.aws-lc pkgs.sqlite];
      # The server's tests need a container engine and network.
      doCheck = false;
      meta =
        old.meta
        // {
          description = "OpenShell gateway server (openshell-gateway)";
          mainProgram = "openshell-gateway";
        };
    });
  in {
    _module.args.pkgs = pkgs;

    packages = {
      inherit (pkgs) openshell claude-code pi-coding-agent;
      inherit openshell-gateway;
    };

    formatter = pkgs.alejandra;
  };
}
