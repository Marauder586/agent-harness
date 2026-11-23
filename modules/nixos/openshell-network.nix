# NixOS aspect: the system-wide, root-owned sandbox allowlist.
#
# Writes /etc/openshell/network.conf (mode 0444, owned by root). Every
# agent-harness launch merges it with the user's home-manager
# `network.allow`. Users cannot edit it, and the launcher refuses to run
# if it is not root-owned. On non-NixOS hosts, create the same file by hand:
#
#   sudo install -d -m 755 /etc/openshell
#   printf '10.0.0.5/32 443,22\n' | sudo tee /etc/openshell/network.conf
#   sudo chmod 444 /etc/openshell/network.conf
{config, ...}: {
  flake.modules.nixos.openshell-network = {
    config,
    lib,
    ...
  }: let
    hl = import ../../lib {inherit lib;};
    cfg = config.services.openshell-network;
  in {
    options.services.openshell-network.allow = lib.mkOption {
      type = lib.types.listOf hl.allowEntryType;
      default = [];
      example = [
        "10.0.0.5/32"
        {
          cidr = "10.0.1.0/24";
          ports = [443 22];
        }
      ];
      description = ''
        IP ranges every agent-harness sandbox on this machine may reach,
        written to /etc/openshell/network.conf. A bare string allows port 443.
      '';
    };

    config = lib.mkIf (cfg.allow != []) {
      environment.etc."openshell/network.conf" = {
        text = "# Managed by NixOS (services.openshell-network.allow)\n" + hl.renderAllowConf cfg.allow;
        mode = "0444";
      };
    };
  };

  flake.nixosModules.openshell-network = config.flake.modules.nixos.openshell-network;
}
