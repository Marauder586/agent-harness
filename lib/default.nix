# Plain helpers shared by the flake-parts modules. Not a module itself (lives
# outside modules/, so import-tree never picks it up).
{lib}: rec {
  # One allowlist entry: a CIDR (or bare IP) and the TCP ports it may be
  # reached on. A bare string is shorthand for port 443 only.
  allowEntryType = let
    entry = lib.types.submodule {
      options = {
        cidr = lib.mkOption {
          type = lib.types.str;
          example = "10.20.0.0/16";
          description = "IPv4/IPv6 address or CIDR range the sandbox may connect to.";
        };
        ports = lib.mkOption {
          type = lib.types.nonEmptyListOf lib.types.port;
          default = [443];
          example = [443 22];
          description = "TCP ports allowed on this range.";
        };
      };
    };
  in
    lib.types.coercedTo lib.types.str (cidr: {inherit cidr;}) entry;

  # Render entries in the network.conf line format read by lib/policy-gen.py:
  #   <ip-or-cidr> [port[,port...]]
  renderAllowConf = entries:
    lib.concatMapStrings (e: "${e.cidr} ${lib.concatMapStringsSep "," toString e.ports}\n") entries;

  # Every <root>/<name>/SKILL.md becomes a skill entry for
  # flake.agentSkills: `{ src; packages; }`. `src` is the directory with
  # skill.nix stripped (store name skill-<name>). `packages` is
  # pkgs -> [drv]: the union of <name>/skill.nix (when present) and
  # `extraPackages.<name>`, which lets a module declare tools for upstream
  # skills it cannot add a skill.nix to.
  discoverSkills = {
    root,
    extraPackages ? {},
  }: let
    dirs =
      lib.filterAttrs
      (n: t: t == "directory" && builtins.pathExists (root + "/${n}/SKILL.md"))
      (builtins.readDir root);
  in
    lib.mapAttrs (name: _: let
      dir = root + "/${name}";
      nixFile = dir + "/skill.nix";
    in {
      src = builtins.path {
        path = dir;
        name = "skill-${name}";
        filter = path: _: baseNameOf path != "skill.nix";
      };
      packages = pkgs:
        (
          if builtins.pathExists nixFile
          then (import nixFile {inherit pkgs;}).packages or []
          else []
        )
        ++ (extraPackages.${name} or (_: [])) pkgs;
    })
    dirs;

  # name -> path for every entry of `dir` (dotfiles skipped). A trailing
  # .ts/.js is dropped from file names, so extensions/pi/ws-edit.ts is
  # selectable as "ws-edit". Missing dir yields {}.
  discoverDir = dir:
    if !builtins.pathExists dir
    then {}
    else
      lib.mapAttrs'
      (n: _: lib.nameValuePair (lib.removeSuffix ".js" (lib.removeSuffix ".ts" n)) (dir + "/${n}"))
      (lib.filterAttrs (n: _: !lib.hasPrefix "." n) (builtins.readDir dir));
}
