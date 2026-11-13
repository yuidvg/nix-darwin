# Repository Instructions

Read `AGENTS.md` in this directory as the canonical repository guidance.

Claude-specific note: this repository uses `modules/claude-code.nix` to project shared prompts and the `github:yuidvg/skills` packages into Claude Code and Codex. The impeccable engine comes from that flake's `nix/impeccable-engine.nix`. This repository does not bind `IMPECCABLE_BIN`. Keep tool-specific settings in their native config formats; keep shared semantics in Nix attrsets or prompt snippets.
