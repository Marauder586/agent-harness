---
name: gitlab
description: Work with GitLab merge requests, issues, and CI pipelines using the glab CLI. Use when asked to open or review an MR, check a pipeline, or read or comment on GitLab issues.
compatibility: Needs the glab CLI and network access to the GitLab host.
---

# GitLab

Use `glab`, which reads the GitLab host from the repository's git remote. Pass `--repo <group>/<project>` when working outside a clone.

## Authentication

Run `glab auth status` first. If it fails, stop and ask the user to provide a token. Do not try to log in interactively, and never print tokens.

## Common tasks

- **List open MRs:** `glab mr list`
- **View an MR and its discussion:** `glab mr view <id> --comments`
- **Diff of an MR:** `glab mr diff <id>`
- **Open an MR from the current branch:** push the branch, then run `glab mr create --fill --target-branch <base>`. Show the title and description to the user before creating it.
- **Pipeline status for the current branch:** `glab ci status`
- **Logs of a failed job:** `glab ci trace <job-id>`
- **Issues:** `glab issue list` and `glab issue view <id> --comments`

## Rules

- Ask before any write: creating, approving, merging, or closing an MR or issue, or posting a comment.
- When a pipeline fails, read the failing job's trace before proposing a fix. Quote the decisive error line.
