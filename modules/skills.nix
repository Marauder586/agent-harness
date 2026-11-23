# Discovers every skill under skills/. A skill is a directory holding a
# SKILL.md in Agent Skills format (https://agentskills.io/specification), so
# the same directory works in any harness that implements the spec. Nothing
# here, or in any harness, lists skill names: add skills/<name>/SKILL.md and
# it becomes selectable as "<name>" in every harness's `skills` option.
#
# Optional skills/<name>/skill.nix declares the tools the skill's
# instructions or scripts call, so the skill stays self-contained:
#
#   {pkgs}: { packages = [ pkgs.glab ]; }
#
# Those packages are added to the sandbox image of any harness that enables
# the skill. skill.nix itself is stripped from the installed copy, so
# harnesses only ever see a spec-pure skill directory.
#
# Skills from upstream repos are registered the same way in
# modules/skills-upstream.nix. A name defined in both places is an
# evaluation error, not a silent override.
{lib, ...}: let
  hl = import ../lib {inherit lib;};
in {
  flake.agentSkills = hl.discoverSkills {root = ../skills;};
}
