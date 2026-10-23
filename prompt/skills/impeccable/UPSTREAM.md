# Upstream

- Repository: https://github.com/pbakaus/impeccable
- Commit: 5cb95eea9c96479f57afe0732a45470d30183326
- Imported directory: .agents/skills/impeccable
- Skill version: 4.7.0; engine version: 0.1.16
- License: Apache-2.0; upstream LICENSE and NOTICE.md included.

The canonical files are vendored here and projected by modules/claude-code.nix
into Claude Code, Codex, and Pi. The Nix projection binds the launcher to the
hash-pinned engine in packages/impeccable, avoiding first-use downloads.
Desktop ZIPs preserve the upstream portable launcher.

To update, replace the skill payload from a reviewed upstream commit and update
this record plus the engine version and release checksums in packages/impeccable.
Validate and activate using docs/nix-agent-tooling-runbook.md.
