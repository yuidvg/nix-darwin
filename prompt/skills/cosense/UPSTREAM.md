# Upstream

- Repository: https://github.com/helpfeel/cosense-cli
- Revision: `d41182f246bc3213c4ba7e56a9e370ddad5d221e`
- Directory: `skills/cosense/`
- Corresponding CLI release: `@helpfeel/cosense-cli` 1.16.1
- License: MIT (upstream package metadata)

Local adaptations:

- Installation and upgrades go through nix-darwin / Home Manager instead of
  global npm or the skills installer.
- Version diagnostics use this provenance file instead of Claude marketplace
  metadata, since the shared skill is projected directly to all agents.

The reading, editing, file handling, and interactive login procedures are
otherwise unchanged. Update the vendored skill with the CLI; see
`docs/cosense-cli.md` in the nix-darwin repository.
