# `nix flake check`:
#   - skill-names: each skills/<name>/SKILL.md declares `name: <name>`
#     (the portable form; Claude Code and other spec implementations
#     require it).
#   - policy-gen: the allowlist → policy generator accepts a sample and
#     rejects the ranges OpenShell would refuse.
#   - home-manager: evaluates the home-manager aspect with every harness on
#     and every skill and extension selected, and builds the wrappers.
#     Building a wrapper builds its image stream script, not the image.
{
  inputs,
  config,
  lib,
  ...
}: let
  skillNames = lib.attrNames config.flake.agentSkills;
  harnesses = config.flake.agentHarnesses;
  hmModule = config.flake.modules.homeManager.agent-harness;
in {
  perSystem = {pkgs, ...}: {
    checks = {
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
        hm = inputs.home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            hmModule
            {
              home.username = "check";
              home.homeDirectory = "/home/check";
              home.stateVersion = "26.05";
              programs.agent-harness = {
                network.allow = [
                  "10.0.0.5/32"
                  {
                    cidr = "10.0.1.0/24";
                    ports = [443 22];
                  }
                ];
                harnesses =
                  lib.mapAttrs (_: def: {
                    enable = true;
                    skills = skillNames;
                    mcpServers = lib.attrNames config.flake.agentMcpServers;
                    extensions = lib.attrNames def.extensions;
                  })
                  harnesses;
              };
            }
          ];
        };
      in
        pkgs.linkFarm "check-home-manager" (lib.mapAttrsToList (n: _: {
            name = n;
            path = lib.getExe (lib.findFirst (p: (p.meta.mainProgram or "") == "agent-${n}") null hm.config.home.packages);
          })
          harnesses);
    };
  };
}
