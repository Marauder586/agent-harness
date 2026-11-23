# Runtime tools this skill needs. Added to the sandbox image of any harness
# that enables the skill; stripped from the installed skill directory.
{pkgs}: {
  packages = [pkgs.glab];
}
