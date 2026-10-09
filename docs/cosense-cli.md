# Official Cosense CLI

`@helpfeel/cosense-cli` supplies the `cosense` command required by Helpfeel's
official Cosense skill. It is distinct from the existing `ScrapboxCLI` (`sb*`
commands), `scrapbox-write`, and Cosense MCP server.

## Declarative installation

- `packages/cosense-cli/default.nix` pins the npm release and source hash.
- `packages/cosense-cli/package-lock.json` is the matching upstream lockfile.
- Node.js 24 and npm dependencies are built into the Nix closure. Installation
  does not use global npm, npx, or activation-time dependency downloads.
- `flake.nix` exports `packages.<system>.cosense-cli`.
- `modules/shared-scripts.nix` installs it through Home Manager.
- `prompt/skills/cosense/` contains the matching official skill, with provenance
  recorded in `UPSTREAM.md`. The existing shared projection supplies it to
  Claude Code, Codex, Pi, and the Desktop ZIP output.

This follows the repository's existing local-package pattern; an overlay is
not required to install or export the package.

## Validation and activation

Read `docs/nix-agent-tooling-runbook.md` before editing. Stage newly added source
files so flake evaluation can see them, then use the narrow checks:

```bash
nix fmt -- packages/cosense-cli/default.nix flake.nix modules/shared-scripts.nix
nix build .#cosense-cli --no-link --print-out-paths
nix run .#cosense-cli -- --version
nix run .#cosense-cli -- --help
nix build .#desktop-skills --no-link --print-out-paths
```

Build the active Darwin system before switching, following the runbook. In this
machine's local checkout, `./apply` performs the switch. Then verify:

```bash
cosense --version
cosense --help
readlink ~/.codex/skills/cosense
readlink ~/.claude/skills/cosense
readlink ~/.pi/agent/skills/cosense
```

## Authentication

The official CLI accepts a Personal Access Token or Service Account. Existing
`SCRAPBOX_SID` / `COSENSE_SID` cookies used by older tools do not authenticate it.

```bash
cosense login --help
cosense login https://scrapbox.io
cosense whoami https://scrapbox.io
```

The user runs interactive login in a terminal. The CLI stores credentials in
`~/.cosense/settings.json` (directory 0700, file 0600). Treat that file as mutable
authentication state; do not place it in Git or the Nix store or overwrite it
on rebuild. Public page reads can work without login.

For a separately managed token, the CLI supports `COSENSE_PAT`. If needed, add
it through the machine's existing sops mechanism at runtime; never embed the
token in a Nix expression or managed plaintext file.

## Updating

1. Inspect the desired npm release (`npm view @helpfeel/cosense-cli`) and its
   `gitHead`. Keep CLI source, lockfile, and skill provenance aligned.
2. Update `version`, the tarball source hash, and the matching upstream
   `package-lock.json` in `packages/cosense-cli/`.
3. Use a temporary fake `npmDepsHash`, build only `.#cosense-cli`, and replace
   it with the dependency hash reported by Nix.
4. Refresh `prompt/skills/cosense/` from the pinned upstream revision, retaining
   the documented Nix installation/upgrade adaptations. Update `UPSTREAM.md`.
5. Format, validate the CLI and skill outputs, build the active system, and
   activate it. Do not use global npm or a separate skill installer to update
   generated live paths.
