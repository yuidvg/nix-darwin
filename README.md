# nix-darwin

yui の macOS (nix-darwin + Home Manager) 設定。単一 flake / 単一マシン。

旧 `plural-reality/nix-darwin` の 2層 (upstream/downstream) 構成を統合し、
plural-reality への参照・依存を撤廃済み。経緯は `docs/consolidation-plan.md`。

## 適用

```bash
./apply        # = sudo darwin-rebuild switch --flake .#Yuis-MacBook-Pro
```

## 構成

| パス | 役割 |
|---|---|
| `flake.nix` | 単一 `darwinConfigurations."Yuis-MacBook-Pro"`、inputs、perSystem (Haskell/packages) |
| `modules/base.nix` | programs (git, zsh, neovim 等)、env、macOS defaults、共通 CLI (`agent-browser` 含む) |
| `modules/claude-code.nix` | Claude Code / Codex / Gemini / Cursor の dotfiles・skills・MCP |
| `modules/shared-scripts.nix` | スクリプト群の home.packages 化 |
| `personal.nix` | SOPS secrets、個人パッケージ、codex/zsh/git 個人設定 |
| `prompt/` | AI プロンプト・skills (Claude/Codex 共有ソース) |
| `packages/` | codelayer / xcodebuildmcp / desktop-skills / screenpipe |
| `scripts/` | Haskell/Python/Shell ソース |
| `secrets.yaml`, `.sops.yaml` | sops-nix 暗号化 secrets |

## 開発

```bash
nix develop    # HLS, fourmolu, cabal-gild, nixfmt
nix fmt        # nixfmt で整形
```
