# Shared builder for Pi extensions shipped as npm source packages (Pi loads
# their TypeScript directly): buildNpmPackage with the dependencies pinned
# by a lockfile kept next to the extension, no build step, and the package
# directory installed as is, with its production node_modules, instead of
# being `npm pack`ed.
#
# `stripFields` are deleted from package.json before npm sees it; the
# lockfile must be generated from the same stripped package.json (see each
# extension's default.nix). Any other attribute (postPatch, postInstall,
# passthru, meta, npmFlags, ...) is passed to buildNpmPackage; postPatch
# runs after the package.json/lockfile step.
{
  pkgs,
  src,
  pname,
  npmDepsHash,
  packageLock,
  stripFields ? ["devDependencies" "scripts"],
  postPatch ? "",
  ...
} @ args: let
  inherit (pkgs) lib;
in
  pkgs.buildNpmPackage (removeAttrs args ["pkgs" "packageLock" "stripFields"]
    // {
      version = (lib.importJSON "${src}/package.json").version;
      nodejs = pkgs.nodejs_24;

      postPatch =
        ''
          ${lib.getExe pkgs.jq} ${lib.escapeShellArg "del(${lib.concatMapStringsSep ", " (f: ".${f}") stripFields})"} package.json > package.json.new
          mv package.json.new package.json
          cp ${packageLock} package-lock.json
        ''
        + postPatch;

      dontNpmBuild = true;
      installPhase = ''
        runHook preInstall
        mkdir -p $out
        cp -r . $out/
        runHook postInstall
      '';
    })
