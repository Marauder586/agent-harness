# Systems this flake builds for. The pinned sandbox base image in
# modules/home/agent-harness.nix is amd64-only; add its arm64 digest there
# before adding aarch64-linux here.
{...}: {
  systems = ["x86_64-linux"];
}
