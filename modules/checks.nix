# `nix flake check`:
#   - skill-names: each skills/<name>/SKILL.md declares `name: <name>`
#     (the portable form; Claude Code and other spec implementations
#     require it).
#   - policy-gen: the allowlist → policy generator accepts a sample and
#     rejects the ranges OpenShell would refuse.
#   - home-manager: evaluates the home-manager aspect with every harness on
#     and every skill and extension selected, and builds the wrappers.
#     Building a wrapper builds its image stream script, not the image.
#     Each harness's sandboxed command takes the harness name, and host
#     commands are <name>-unleashed: the case hostBin's PATH ordering
#     (modules/home/agent-harness.nix) exists for, checked here. The host
#     mcp.json must not disable Chromium's sandbox. A few broken configs
#     are evaluated too, to check their assertions fire. The gateway
#     service and its gateway.toml are checked, and the gateway is started
#     on that config (with no container engine) to prove it parses.
#   - openshell-gateway: the gateway builds, at the CLI's version.
{
  inputs,
  config,
  lib,
  ...
}: let
  skillNames = lib.attrNames config.flake.agentSkills;
  harnesses = config.flake.agentHarnesses;
  hmModule = config.flake.modules.homeManager.agent-harness;
  hostCmd = n: "${n}-unleashed";
in {
  perSystem = {
    pkgs,
    self',
    ...
  }: {
    checks = {
      openshell-gateway = let
        gw = self'.packages.openshell-gateway;
        cli = self'.packages.openshell;
      in
        assert gw.version == cli.version || throw "openshell-gateway ${gw.version} != openshell ${cli.version}";
          pkgs.runCommand "check-openshell-gateway" {} ''
            ${lib.getExe gw} --version | grep -F ${cli.version}
            ${lib.getExe cli} --version | grep -F ${cli.version}
            touch $out
          '';

      skill-names = pkgs.runCommand "check-skill-names" {} ''
        ${lib.concatMapStrings (n: ''
            grep -qx 'name: ${n}' ${config.flake.agentSkills.${n}.src}/SKILL.md \
              || { echo "skills/${n}/SKILL.md must declare 'name: ${n}'"; exit 1; }
          '')
          skillNames}
        touch $out
      '';

      policy-gen = pkgs.runCommand "check-policy-gen" {nativeBuildInputs = [pkgs.python3];} ''
        gen() { python3 -I ${../lib/policy-gen.py} --uid 1000 --gid 100 "$@"; }
        printf '10.0.0.5 443,22\n192.168.1.0/24\n' > ok.conf
        gen --conf ok.conf > policy.yaml
        grep -q 'port: 22' policy.yaml
        grep -q '"192.168.1.0/24"' policy.yaml
        gen --conf ok.conf --host-port 9077 > host.yaml
        grep -q 'host: host.openshell.internal' host.yaml
        if gen --conf ok.conf --host-port 22 >/dev/null 2>&1; then echo "accepted host-port overlapping allowlist"; exit 1; fi
        for bad in 127.0.0.1 169.254.169.254 0.0.0.0/0 ::1 'not-an-ip'; do
          echo "$bad" > bad.conf
          if gen --conf bad.conf >/dev/null 2>&1; then echo "accepted $bad"; exit 1; fi
        done
        if python3 -I ${../lib/policy-gen.py} --uid 0 --gid 0 >/dev/null 2>&1; then
          echo "accepted root"; exit 1
        fi
        touch $out
      '';

      home-manager = let
        hmBase = {
          home.username = "check";
          home.homeDirectory = "/home/check";
          home.stateVersion = "26.05";
        };
        hmEval = cfg:
          inputs.home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = [hmModule hmBase {programs.agent-harness = cfg;}];
          };
        hm = hmEval {
          openshell.engine = "podman";
          hindsight.enable = true;
          llm = {
            providers.local = {
              baseUrl = "http://10.0.0.9:8000/v1";
              apiKeyFile = "/run/secrets/llm-key";
              models = [
                {
                  id = "test-model";
                  reasoning = true;
                  contextWindow = 131072;
                }
              ];
            };
            providers.anthropic-gw = {
              baseUrl = "http://10.0.0.10:4000";
              api = "anthropic-messages";
              models = [{id = "claude-gw";}];
            };
            default = {
              provider = "local";
              model = "test-model";
            };
          };
          network.allow = [
            "10.0.0.5/32"
            {
              cidr = "10.0.1.0/24";
              ports = [443 22];
            }
          ];
          harnesses =
            lib.mapAttrs (n: def: {
              enable = true;
              skills = skillNames;
              mcpServers = lib.attrNames config.flake.agentMcpServers;
              extensions = lib.attrNames def.extensions;
              command = n;
              host = {
                enable = def.supportsHost or false;
                command = hostCmd n;
              };
            })
            harnesses;
        };

        # Broken configs whose assertions must fail, with a word the
        # failing message must contain. Evaluated only, never built.
        mustFail = {
          loopback-provider = {
            word = "loopback";
            cfg.llm.providers.here = {
              baseUrl = "http://127.0.0.1:8000/v1";
              models = [{id = "m";}];
            };
          };
          default-without-providers = {
            word = "not in llm.providers";
            cfg.llm.default = {
              provider = "missing";
              model = "m";
            };
          };
        };
        # homeManagerConfiguration throws on failed assertions, so these
        # are evaluated with home-manager's module list directly.
        hmRawAssertions = cfg: let
          hmLib = import "${inputs.home-manager}/modules/lib/stdlib-extended.nix" lib;
        in
          (hmLib.evalModules {
            class = "homeManager";
            specialArgs.modulesPath = "${inputs.home-manager}/modules";
            modules =
              [hmModule hmBase {programs.agent-harness = cfg;}]
              ++ import "${inputs.home-manager}/modules/modules.nix" {
                inherit pkgs;
                lib = hmLib;
              };
          })
          .config
          .assertions;
        failed = lib.mapAttrsToList (n: t:
          lib.any (a: !a.assertion && lib.hasInfix t.word a.message)
          (hmRawAssertions (t.cfg // {harnesses.pi.enable = true;}))
          || throw "checks.home-manager: assertion for ${n} did not fire")
        mustFail;

        # Gateway service and config. The config is validated by starting
        # the gateway on it: it must get past parsing (gateway and driver
        # tables are deny_unknown_fields) to the podman socket probe, which
        # fails in the build sandbox.
        gwSvc = hm.config.systemd.user.services.openshell-gateway;
        gwToml = hm.config.xdg.configFile."openshell/gateway.toml".source;
        gwPkg = hm.config.programs.agent-harness.openshell.gateway.package;
        noGateway =
          (hmEval {
            harnesses.pi.enable = true;
            openshell.gateway.enable = false;
          }).config.systemd.user.services
          ? openshell-gateway;

        hostHarnesses = lib.filterAttrs (_: def: def.supportsHost or false) harnesses;
        exeOf = cmd: lib.getExe (lib.findFirst (p: (p.meta.mainProgram or "") == cmd) (throw "no ${cmd} in home.packages") hm.config.home.packages);
      in
        assert lib.all lib.id failed;
        assert !noGateway || throw "checks.home-manager: openshell.gateway.enable = false still defines the service";
        assert lib.hasInfix "--server-san host.openshell.internal" (toString gwSvc.Service.ExecStartPre);
        assert toString gwSvc.Service.ExecStart == lib.getExe gwPkg;
        assert lib.elem "podman.socket" gwSvc.Unit.Wants;
          pkgs.runCommand "check-home-manager" {} ''
            mkdir $out
            cp ${gwToml} $out/gateway.toml
            grep -qx 'compute_drivers = \["podman"\]' ${gwToml}
            grep -qx 'bind_address = "127.0.0.1:17670"' ${gwToml}
            grep -qx 'enable_bind_mounts = true' ${gwToml}
            grep -qx 'userns = "keep-id"' ${gwToml}
            export HOME=$TMPDIR/home OPENSHELL_LOCAL_TLS_DIR=$TMPDIR/tls
            ${lib.getExe gwPkg} generate-certs --output-dir $OPENSHELL_LOCAL_TLS_DIR --server-san host.openshell.internal
            rc=0
            timeout 20 ${lib.getExe gwPkg} --config ${gwToml} > gw.log 2>&1 || rc=$?
            cat gw.log
            [ $rc = 124 ] || grep -q 'responsive Podman API socket found' gw.log \
              || { echo "gateway rejected ${gwToml}"; exit 1; }
            ${lib.concatMapStrings (n: "ln -s ${exeOf n} $out/${n}\n") (lib.attrNames harnesses)}
            ${lib.concatMapStrings (n: let
              exe = lib.getExe hm.config.programs.agent-harness.harnesses.${n}.package;
              host = exeOf (hostCmd n);
            in ''
              ln -s ${host} $out/${n}-host
              first=$(sed -n 's|^export PATH="\([^:]*\):.*|\1|p' ${host})
              [ "$(ls -A "$first")" = ${baseNameOf exe} ] \
                || { echo "${n}-host: first PATH entry '$first' must hold only ${baseNameOf exe}"; exit 1; }
              [ "$(readlink -f "$first/${baseNameOf exe}")" = "$(readlink -f ${exe})" ] \
                || { echo "${n}-host: $first/${baseNameOf exe} is not the harness package"; exit 1; }
              for f in $(grep -o '/nix/store/[^ ]*-host-mcp.json' ${host}); do
                if grep -q -- --no-sandbox "$f"; then echo "${n}-host: $f disables Chromium's sandbox"; exit 1; fi
              done
            '') (lib.attrNames hostHarnesses)}
          '';
    };
  };
}
