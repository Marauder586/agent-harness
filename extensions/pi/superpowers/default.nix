# Superpowers for Pi (https://github.com/obra/superpowers): a development
# methodology built on skills that trigger automatically — brainstorming,
# spec writing, planning, red/green TDD, subagent-driven development (see
# README.md, "Pi extensions").
#
# The automatic triggering is the extension's job, not the skills': it
# injects the `using-superpowers` bootstrap into every provider request at
# session start and again after compaction, so this ships as the whole Pi
# package, not just its skills/ directory. Built from the pinned
# `superpowers` input (a git tag; the package is not on npm). Its only
# imports are node builtins and @earendil-works/pi-coding-agent, which Pi's
# extension loader aliases to its own copy — no runtime dependencies to pin.
#
# Skills reach Pi through package.json's `pi.skills`, but only when no
# settings.json `skills` entry exists: settings skills act as a filter over
# every loaded package's skills (package-manager.js applyPackageFilter), so
# with the harness's own skills selected the package's 15 register disabled.
# The passthru.piSkillsDir below hands the dir to the harness, which appends
# it to settings.json `skills` — they then load as plain user skills, once,
# and only while this extension is selected.
{
  pkgs,
  inputs,
}: let
  inherit (pkgs) lib;
  src = inputs.superpowers;
in
  pkgs.runCommand "pi-superpowers-${(lib.importJSON "${src}/package.json").version}" {
    meta = {
      description = "Superpowers development methodology for Pi: auto-triggered skills";
      homepage = "https://github.com/obra/superpowers";
      license = lib.licenses.mit;
    };
    passthru.piSkillsDir = "${src}/skills";
  } ''
    # The extension resolves the skills dir relative to its own location
    # (<packageRoot>/skills), so the layout under $out must match the repo.
    mkdir -p $out/.pi
    cp -r ${src}/skills $out/skills
    cp -r ${src}/.pi/extensions $out/.pi/extensions
    ${lib.getExe pkgs.jq} '{name, version, type, pi: {extensions: ["./.pi/extensions/superpowers.ts"], skills: ["./skills"]}}' \
      ${src}/package.json > $out/package.json
  ''
