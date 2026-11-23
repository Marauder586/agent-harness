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
#   - devshell: runs a real sandboxed wrapper against fake openshell,
#     podman, direnv and nix, and checks dev shell selection, the leading
#     flag parsing, the env filter and the mounts it asks for.
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

      devshell = let
        hm = inputs.home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            hmModule
            {
              home.username = "check";
              home.homeDirectory = "/home/check";
              home.stateVersion = "26.05";
              programs.agent-harness = {
                openshell.engine = "podman";
                openshell.gateway.enable = false;
                openshell.package = fakeOpenshell;
                harnesses.pi.enable = true;
                harnesses.claude-code.enable = true;
              };
            }
          ];
        };
        claudeWrapper = lib.getExe (lib.findFirst (p: (p.meta.mainProgram or "") == "agent-claude-code") (throw "no agent-claude-code") hm.config.home.packages);
        wrapper = lib.getExe (lib.findFirst (p: (p.meta.mainProgram or "") == "agent-pi") (throw "no agent-pi") hm.config.home.packages);
        # Records what the wrapper asked for: the arguments, the mounts, and
        # a copy of the dev shell env file (deleted when the wrapper exits).
        fakeOpenshell = pkgs.writeShellScriptBin "openshell" ''
          printf '%s\n' "$@" > "$CASE/args"
          prev=""
          for a in "$@"; do
            [ "$prev" != --driver-config-json ] || printf '%s' "$a" > "$CASE/mounts.json"
            prev=$a
          done
          src=$(${lib.getExe pkgs.jq} -r '.podman.mounts[] | select(.target == "/sandbox/.devshell") | .source' "$CASE/mounts.json")
          if [ -n "$src" ]; then
            cp "$src/env" "$CASE/env"
            stat -c %a "$src" > "$CASE/mode"
          fi
        '';
        fakePodman = pkgs.writeShellScriptBin "podman" "exit 0";
        fakeDirenv = pkgs.writeShellScriptBin "direnv" ''
          case $1 in
            status)
              if [ -n "''${FAKE_RC-}" ]; then
                printf '{"state":{"foundRC":{"allowed":%s,"path":"%s/.envrc"},"loadedRC":null}}' "$FAKE_RC" "$PWD"
              else
                echo '{"state":{"foundRC":null,"loadedRC":null}}'
              fi
              ;;
            exec)
              dir=$2
              shift 2
              if [ "$dir" != / ]; then
                [ -z "''${FAKE_FAIL-}" ] || { echo "direnv: error exit status 1" >&2; exit 1; }
                export FOO=bar HOME=/elsewhere TMPDIR=/tmp/x DIRENV_DIR=-$dir __fake=1 TERM_PROGRAM=x XDG_DATA_DIRS=/x
                export SECRET="it's \"quoted\" \$(touch pwned)
          second line"
                export PROJECT_DATA=$dir/data
                export PATH=/nix/store/fake-hello/bin:$dir/bin:/home/check/.cargo/bin:$PATH
              fi
              exec "$@"
              ;;
          esac
        '';
        devJson = pkgs.writeText "dev.json" (builtins.toJSON {
          variables = {
            PATH = {
              type = "exported";
              value = "/nix/store/fake-cowsay/bin:/path-not-set";
            };
            GREETING = {
              type = "exported";
              value = "moo";
            };
            NIX_BUILD_TOP = {
              type = "exported";
              value = "/build";
            };
            SSL_CERT_FILE = {
              type = "exported";
              value = "/no-cert-file.crt";
            };
            BASH = {
              type = "var";
              value = "/bin/bash";
            };
          };
        });
        fakeNix = pkgs.writeShellScriptBin "nix" ''
          case $1 in
            print-dev-env)
              [ -z "''${FAKE_FAIL-}" ] || exit 1
              echo "$3" > "$CASE/installable"
              cat ${devJson}
              ;;
            eval)
              [ -n "''${FAKE_FLAKE-}" ] || { echo "error: flake does not provide attribute 'devShells'" >&2; exit 1; }
              echo true
              ;;
          esac
        '';
      in
        pkgs.runCommand "check-devshell" {nativeBuildInputs = [fakePodman fakeDirenv fakeNix pkgs.jq];} ''
          fail() { echo "devshell check, case $c: $*"; exit 1; }
          export HOME=$TMPDIR/home XDG_STATE_HOME=$TMPDIR/state
          run() {
            c=$1
            shift
            export CASE=$TMPDIR/case-$c
            mkdir -p "$CASE"
            ${wrapper} "$@" 2> "$CASE/err" || { cat "$CASE/err"; fail "wrapper failed"; }
            cat "$CASE/err"
          }
          harnessArgs() { sed '1,/^agent-launch$/d' "$CASE/args"; }
          storeMounted() { jq -e '.podman.mounts | any(.target == "/nix/store" and .read_only)' "$CASE/mounts.json" >/dev/null; }
          # Loads the env file the way agent-launch does, into a sandbox-like env.
          bash=$(command -v bash)
          inSandbox() {
            env -i PATH=/base HOME=/sandbox TMPDIR=/tmp "$@" "$bash" -c \
              '. "$1"; exec ${pkgs.coreutils}/bin/env' _ "$CASE/env"
          }
          has() { inSandbox | grep -qxF -- "$1" || fail "env lacks $1"; }
          hasNot() { ! inSandbox | grep -q -- "^$1=" || fail "env has $1"; }

          mkdir proj && cd proj

          # Allowed .envrc. Flags are only taken while leading.
          FAKE_RC=0 EDITOR=vim run envrc --print -- --no-devshell
          [ "$(harnessArgs)" = "$(printf '%s\n' --print -- --no-devshell)" ] || fail "args: $(harnessArgs)"
          storeMounted || fail "no /nix/store mount"
          [ "$(cat "$CASE/mode")" = 700 ] || fail "env dir mode $(cat "$CASE/mode")"
          grep -q 'left out: /home/check/.cargo/bin' "$CASE/err" || fail "dropped PATH entry not reported"
          has FOO=bar
          has HOME=/sandbox
          has TMPDIR=/tmp
          has PROJECT_DATA=/sandbox/work/data
          has PATH=/nix/store/fake-hello/bin:/sandbox/work/bin:/base
          for v in DIRENV_DIR __fake TERM_PROGRAM XDG_DATA_DIRS EDITOR; do hasNot $v; done
          [ "$(env -i "$bash" -c '. "$1"; printf %s "$SECRET"' _ "$CASE/env")" = "$(printf '%s\n%s' "it's \"quoted\" \$(touch pwned)" "second line")" ] \
            || fail "SECRET mangled"
          [ ! -e pwned ] || fail "env file ran a command substitution"
          inSandbox FOO=mine | grep -qx FOO=mine || fail "dev shell overrode a sandbox variable"
          grep -q 'agent-launch' "$CASE/args"

          # Not allowed, failing, disabled: no dev shell, no store mount.
          FAKE_RC=1 run blocked
          grep -q 'not allowed (direnv allow); starting without dev shell' "$CASE/err" || fail "no notice"
          ! storeMounted || fail "store mounted"
          FAKE_RC=0 FAKE_FAIL=1 run broken
          grep -q 'direnv failed' "$CASE/err" || fail "no warning"
          ! storeMounted || fail "store mounted"
          FAKE_RC=0 run off --no-devshell --version
          ! storeMounted || fail "store mounted"
          [ "$(harnessArgs)" = --version ] || fail "args: $(harnessArgs)"
          FAKE_RC=0 AGENT_DEVSHELL=none run off-env
          ! storeMounted || fail "store mounted"

          # Explicit installables, in all three spellings.
          FAKE_RC=1 run flag --devshell .#cow x
          [ "$(cat "$CASE/installable")" = .#cow ] && [ "$(harnessArgs)" = x ] || fail "installable/args"
          storeMounted || fail "no /nix/store mount"
          has GREETING=moo
          has PATH=/nix/store/fake-cowsay/bin:/base
          hasNot NIX_BUILD_TOP
          hasNot SSL_CERT_FILE
          hasNot BASH
          run flag-eq --devshell=.#cow
          [ "$(cat "$CASE/installable")" = .#cow ] || fail installable
          AGENT_DEVSHELL=.#cow run flag-env
          [ "$(cat "$CASE/installable")" = .#cow ] || fail installable
          if FAKE_FAIL=1 CASE=$TMPDIR ${wrapper} --devshell .#x 2>/dev/null; then fail "explicit failure ignored"; fi
          if ${wrapper} --devshell 2>/dev/null; then fail "--devshell without a value accepted"; fi

          # Flake auto-detection, only with a default devShell.
          run none
          ! storeMounted || fail "store mounted"
          touch flake.nix
          run flake-none
          ! storeMounted || fail "store mounted"
          ! grep -qi 'dev shell\|flake' "$CASE/err" || fail "noise without a devShell"
          FAKE_FLAKE=1 run flake
          [ "$(cat "$CASE/installable")" = "$PWD#devShells.${pkgs.stdenv.hostPlatform.system}.default" ] || fail installable
          storeMounted || fail "no /nix/store mount"

          # Per-project persistent state: read-write, one dir per project path.
          persistSrc() { jq -r '.podman.mounts[] | select(.target == "/sandbox/.persist" and (.read_only | not)) | .source' "$CASE/mounts.json"; }
          p1=$(persistSrc)
          [ -d "$p1" ] && [ "$(cat "$p1/.path")" = "$PWD" ] || fail "persist dir"
          run none-again
          [ "$(persistSrc)" = "$p1" ] || fail "persist dir differs for the same project"
          mkdir other && cd other
          run other
          [ -n "$(persistSrc)" ] && [ "$(persistSrc)" != "$p1" ] || fail "persist dir shared across projects"
          # A harness that does not declare `persists` gets no persist mount.
          CASE=$TMPDIR/case-claude
          mkdir -p "$CASE"
          ${claudeWrapper} 2> "$CASE/err" || { cat "$CASE/err"; fail "claude wrapper failed"; }
          [ -z "$(persistSrc)" ] || fail "claude-code got a persist mount"
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
