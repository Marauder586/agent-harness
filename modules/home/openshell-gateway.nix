# Home-manager aspect: run the local OpenShell gateway as a systemd user
# service, the way NVIDIA's deb/rpm packages do, and register it with the
# CLI. On by default whenever a harness is enabled; set
# `programs.agent-harness.openshell.gateway.enable = false` to bring your
# own gateway. See README.md, "Prerequisites".
{withSystem, ...}: {
  flake.modules.homeManager.agent-harness = {
    config,
    pkgs,
    lib,
    ...
  }: let
    top = config.programs.agent-harness;
    cfg = top.openshell.gateway;
    engine = top.openshell.engine;
    system = pkgs.stdenv.hostPlatform.system;
    flakePackages = withSystem system ({config, ...}: config.packages);

    anyHarness = lib.any (h: h.enable) (lib.attrValues top.harnesses);
    toml = pkgs.formats.toml {};
    configFile = toml.generate "openshell-gateway.toml" cfg.settings;
    endpoint = "https://127.0.0.1:${toString cfg.port}";

    # Same layout as the upstream user unit: server PKI under the state dir,
    # the client bundle copied by generate-certs to
    # ~/.config/openshell/gateways/openshell/mtls for the CLI.
    tlsDir = "%S/openshell/tls";

    # Registers the gateway as "openshell" (the name generate-certs writes
    # the client bundle under) once; an existing registration is left alone.
    register = pkgs.writeShellScript "openshell-gateway-register" ''
      set -eu
      meta="''${XDG_CONFIG_HOME:-$HOME/.config}/openshell/gateways/openshell/metadata.json"
      if [ ! -e "$meta" ]; then
        exec ${lib.getExe top.openshell.package} gateway add ${endpoint} --local --name openshell
      fi
      if ! ${lib.getExe pkgs.jq} -e --arg e ${endpoint} '.gateway_endpoint == $e' "$meta" >/dev/null; then
        echo "openshell-gateway: gateway 'openshell' is registered with another endpoint; run" \
          "'openshell gateway remove openshell' and restart this service to re-register ${endpoint}" >&2
      fi
    '';
  in {
    options.programs.agent-harness.openshell.gateway = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Run a local OpenShell gateway (`openshell-gateway`) as a systemd
          user service while any harness is enabled, and register it with the
          CLI as `openshell`. Turn off to use a gateway you run yourself.
        '';
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = flakePackages.openshell-gateway;
        defaultText = lib.literalMD "this flake's build, from the same source as `openshell.package`";
        description = "The gateway server. Keep its version equal to `openshell.package`.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 17670;
        description = "Loopback port of the gateway's mTLS API (https://127.0.0.1:<port>).";
      };

      settings = lib.mkOption {
        inherit (toml) type;
        default = {};
        example = {openshell.gateway.log_level = "debug";};
        description = ''
          Gateway configuration, written to
          `~/.config/openshell/gateway.toml` (schema: OpenShell's "Gateway
          Configuration File" reference). Merged over defaults that bind
          the API to 127.0.0.1:`port`, select the `openshell.engine` driver,
          allow bind mounts (`workspace.mount`, dev shells) and, for podman, map your
          UID into sandboxes unchanged (`userns = "keep-id"`).
        '';
      };
    };

    config = lib.mkIf (cfg.enable && anyHarness) {
      programs.agent-harness.openshell.gateway.settings.openshell = {
        version = lib.mkDefault 1;
        gateway = {
          bind_address = lib.mkDefault "127.0.0.1:${toString cfg.port}";
          compute_drivers = lib.mkDefault [engine];
        };
        drivers.${engine} =
          # The workspace mount and the dev shell mounts (the env dir and
          # /nix/store; dev shells can be asked for per run, so always on).
          {enable_bind_mounts = lib.mkDefault true;}
          # Rootless podman maps your UID to root in the container, so the
          # sandbox user (your UID, see policy-gen) could not write the
          # mounted project. keep-id maps it to itself.
          // lib.optionalAttrs (engine == "podman") {userns = lib.mkDefault "keep-id";};
      };

      xdg.configFile."openshell/gateway.toml".source = configFile;

      systemd.user.services.openshell-gateway = {
        Unit = {
          Description = "OpenShell gateway for sandboxed coding agents";
          Documentation = "https://docs.nvidia.com/openshell/latest/about/installation";
          X-Restart-Triggers = ["${configFile}"];
          Wants = lib.optional (engine == "podman") "podman.socket";
          After = lib.optional (engine == "podman") "podman.socket";
        };
        Service = {
          Type = "simple";
          # The host's podman/docker CLI (the driver falls back to it to find
          # the API socket), with podman's setuid uidmap helpers.
          Environment = [
            "PATH=/run/wrappers/bin:/run/current-system/sw/bin:${config.home.profileDirectory}/bin:/usr/bin:/bin"
            "OPENSHELL_GATEWAY_CONFIG=${config.xdg.configHome}/openshell/gateway.toml"
            "OPENSHELL_LOCAL_TLS_DIR=${tlsDir}"
          ];
          # Optional OPENSHELL_* overrides and secrets (e.g. OPENSHELL_DB_URL).
          EnvironmentFile = "-%E/openshell/gateway.env";
          ExecStartPre = "${lib.getExe cfg.package} generate-certs --output-dir \${OPENSHELL_LOCAL_TLS_DIR} --server-san host.openshell.internal";
          ExecStart = lib.getExe cfg.package;
          # "-": a failed registration must not stop the gateway.
          ExecStartPost = "-${register}";
          Restart = "on-failure";
          RestartSec = 5;
          UMask = "0077";
        };
        Install.WantedBy = ["default.target"];
      };
    };
  };
}
