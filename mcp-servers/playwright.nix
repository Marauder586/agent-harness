# Playwright MCP: browser automation (navigate, click, fill, screenshot)
# through a headless Chromium. Chromium comes bundled in nixpkgs'
# playwright-mcp, so nothing is downloaded inside the sandbox.
#
# The browser can only reach what the sandbox allowlist permits, plus
# servers listening inside the sandbox itself (e.g. a dev server on
# localhost).
#
# Shape of an MCP server file: a function taking any of
# `{pkgs, inputs, flakePackages, sandboxed}` (see hl.callWith) that returns {
#   description; server = <one mcpServers entry: command, args, env>;
#   packages = [...];  # extra tools on PATH (optional)
# }
# `sandboxed` is false when building the host command's mcp.json; there
# "@AGENT_HARNESS_STATE@" in any string is replaced with the host command's
# state directory at launch.
{
  pkgs,
  sandboxed ? true,
}: {
  description = "Browser automation with a headless Chromium (Playwright)";
  server = {
    command = pkgs.lib.getExe pkgs.playwright-mcp;
    args =
      ["--headless" "--isolated"]
      # Chromium's own sandbox needs user namespaces, which the OpenShell
      # sandbox does not grant; OpenShell is the isolation boundary there.
      # On the host, Chromium keeps its sandbox.
      ++ pkgs.lib.optional sandboxed "--no-sandbox"
      ++ [
        "--output-dir"
        # The sandbox is single-user; on the host, a per-user directory
        # instead of a /tmp path another user could pre-create.
        (
          if sandboxed
          then "/tmp/playwright-mcp"
          else "@AGENT_HARNESS_STATE@/playwright-mcp"
        )
      ];
  };
}
