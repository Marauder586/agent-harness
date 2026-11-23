# Playwright MCP: browser automation (navigate, click, fill, screenshot)
# through a headless Chromium. Chromium comes bundled in nixpkgs'
# playwright-mcp, so nothing is downloaded inside the sandbox.
#
# The browser can only reach what the sandbox allowlist permits, plus
# servers listening inside the sandbox itself (e.g. a dev server on
# localhost).
#
# Shape of an MCP server file: {pkgs}: {
#   description; server = <one mcpServers entry: command, args, env>;
#   packages = [...];  # extra tools on PATH in the sandbox (optional)
# }
{pkgs}: {
  description = "Browser automation with a headless Chromium (Playwright)";
  server = {
    command = pkgs.lib.getExe pkgs.playwright-mcp;
    args = [
      "--headless"
      "--isolated"
      # Chromium's own sandbox needs user namespaces, which the OpenShell
      # sandbox does not grant; OpenShell is the isolation boundary here.
      "--no-sandbox"
      "--output-dir"
      "/tmp/playwright-mcp"
    ];
  };
}
