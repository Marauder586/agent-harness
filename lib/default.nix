# Plain helpers shared by the flake-parts modules. Not a module itself (lives
# outside modules/, so import-tree never picks it up).
{lib}: rec {
  # Call `f` with only the attributes of `args` it names, so a
  # `{pkgs}:` file keeps working when more arguments are offered.
  callWith = f: args: f (builtins.intersectAttrs (lib.functionArgs f) args);

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
  # selectable as "ws-edit". A directory holding a default.nix is a
  # Nix-built extension instead: its entry is that file's function, taking
  # any of `{pkgs, inputs, flakePackages}` (see callWith), called by the
  # home-manager module with the consumer's pkgs. Missing dir yields {}.
  discoverDir = dir:
    if !builtins.pathExists dir
    then {}
    else
      lib.mapAttrs'
      (n: _: let
        p = dir + "/${n}";
      in
        lib.nameValuePair (lib.removeSuffix ".js" (lib.removeSuffix ".ts" n))
        (
          if builtins.pathExists (p + "/default.nix")
          then import p
          else p
        ))
      (lib.filterAttrs (n: _: !lib.hasPrefix "." n) (builtins.readDir dir));
}
