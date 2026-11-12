# Nix Agent Tooling Runbook

Read this before changing Nix/Home Manager, Claude/Codex prompts, skills, or shared agent scripts.

## Source Of Truth

- Personal agent skills live in [`github:yuidvg/skills`](https://github.com/yuidvg/skills) (`skills/<name>/`). This repo does not vendor that tree.
- `lib/enabled-skills.nix` is the explicit list this machine installs (`skills.enable`). A skill the flake exports is not installed until its name is added there.
- Shared scripts live at `scripts/` and are wired by `modules/shared-scripts.nix`.
- Agent prompt/config projection is owned by `modules/claude-code.nix`. It imports `inputs.skills.homeManagerModules.default`.
- Live skills under `~/.claude/skills`, `~/.codex/skills`, and `~/.pi/agent/skills` are generated outputs. Claude Code gets the packaged folder. Codex and Pi get a portable `SKILL.md` (frontmatter, and `index.md` copied to `SKILL.md` for `elm`).
- Host adapters stay in this repo: `@[...]` includes from `prompt/*.md` (applied only when a skill's `SKILL.md` contains one; none do today), the impeccable `IMPECCABLE_BIN` binding, XcodeBuildMCP, Claude Desktop skill ZIPs, and Claude managed settings.
- `inputs.skills.url` is pinned to a commit. `nix flake update skills` does not move it until that URL changes. The skills flake keeps its own nixpkgs pin; do not follow this repo's nixpkgs.
- Other managed files under `~/.claude/*` and `~/.codex/*` are generated outputs.
- Downstream flakes may import this repo from GitHub or from a local `path:` checkout while agent tooling is being tested. Keep that binding in the downstream flake, not in shared modules.

## Skill Change Fast Path

1. Edit the canonical skill in a checkout of `yuidvg/skills`:

```bash
$EDITOR skills/<skill>/SKILL.md
```

`skill-import` unpacks a `.skill` archive into that checkout (`--repo` or `$SKILLS_REPO`).

2. Validate the skill there:

```bash
ruby -ryaml -e 'ARGV.each { |f| YAML.load_file(f); puts "ok #{f}" }' \
  skills/<skill>/SKILL.md

python3 ~/.codex/skills/.system/skill-creator/scripts/quick_validate.py \
  skills/<skill>
```

3. Commit and land the change in `yuidvg/skills`. The flake input sees the committed revision, not a dirty checkout.

4. In this repo, point `inputs.skills.url` at the new commit and refresh the lock:

```bash
nix flake lock
```

A new skill is not installed until its directory name is added to `lib/enabled-skills.nix`.

5. Validate the narrow output, not the whole flake:

```bash
nix build .#desktop-skills --no-link --print-out-paths
```

Confirm the ZIP exists when relevant:

```bash
ls -1 "$(nix build .#desktop-skills --no-link --print-out-paths)" | rg '^<skill>\.zip$'
```

## Downstream Refresh

When `/etc/nix-darwin` imports this repo by `path:`, refresh only that lock input before expecting the active system to see local source changes:

```bash
DOWNSTREAM="${DOWNSTREAM:-/etc/nix-darwin}"
nix flake update nix-darwin-upstream --flake "$DOWNSTREAM"
```

Then build the active system:

```bash
nix build "$DOWNSTREAM#darwinConfigurations.\"$(scutil --get LocalHostName)\".system" \
  --no-link --print-out-paths
```

Only activate after the build is known good:

```bash
sudo darwin-rebuild switch --flake "$DOWNSTREAM"
```

If the goal is only to inspect projected files, build first and inspect the store output instead of switching.

## Narrow Validation Patterns

Use targeted checks:

```bash
nix eval --json .#packages.aarch64-darwin.desktop-skills
nix build .#desktop-skills --no-link --print-out-paths
DOWNSTREAM="${DOWNSTREAM:-/etc/nix-darwin}"
nix build "$DOWNSTREAM#darwinConfigurations.\"$(scutil --get LocalHostName)\".system" --no-link --print-out-paths
```

Avoid broad checks during routine work:

```bash
nix flake show --all-systems
```

This repo has had Haskell/import-from-derivation failures on broad flake inspection. A broad failure there does not prove the touched agent tooling is broken.

## Live Projection Check

After activation, verify the live generated path:

```bash
readlink ~/.codex/skills/<skill>
readlink ~/.claude/skills/<skill>
readlink ~/.pi/agent/skills/<skill>
```

If live links are shadowed by local directories, do not edit generated files. Move the shadowing directory aside, then rerun activation.

## Rules

- Do not duplicate a skill under Claude, Codex, or Pi trees. `yuidvg/skills` is the one canonical source.
- Do not edit `~/.codex/skills`, `~/.claude/skills`, or `~/.pi/agent/skills` as source.
- Do not copy skills back under `prompt/skills`.
- Do not use `nix flake update` without an input name unless the task is dependency refresh.
- Do not use familiarity or DX as a reason to add another config boundary.
- Keep local path assumptions in the downstream launcher layer; shared modules should express the abstract contract.
