# nix-darwin 統合プラン: plural-reality 2層 → yuidvg 単一 repo

- status: executed (2026-05-30, branch `consolidate-yuidvg` → `main`)
- date: 2026-05-29

## 目的

plural-reality 離脱に伴い、2層構成を解消して `yuidvg/nix-darwin` 単一 flake に統合し、
`plural-reality/nix-darwin` への参照・依存をゼロにする。

## 現状 (2層)

| 層 | repo | clone | 役割 |
|---|---|---|---|
| upstream | plural-reality/nix-darwin | `~/Developer/plural-reality/nix-darwin` | `mkSystem`/`mkDownstreamFlake` 抽象、modules・lib・packages・prompt・scripts、downstream機構、`plural-reality.cachix.org` |
| downstream | yuidvg/nix-darwin | `/private/etc/nix-darwin` (稼働中・現マシンをビルド) | `userConfig(yui)` + secrets + `personal.nix` + onnxruntime overlay + ClaudeCode managed-settings を bind |

- `~/Developer/nix-darwin/` は両層へのナビ用 symlink (`downstream`→/private/etc, `upstream`→plural-reality)。
- downstream 固有: `personal.nix`, `secrets.yaml`/`.sops.yaml`, `prompt/.../purchase-research`, `scripts/gemini-rag.ts`。
- **agent-browser はこの downstream の `purchase-research` skill が使用** → upstream `base.nix` の取りこぼしで先日壊れた (別途修正済み・本統合に同梱され復活)。

## 目標 (1層)

`yuidvg/nix-darwin` 単一 flake:

- upstream の実体 (modules/lib/packages/prompt/scripts/haskell-flake/inputs) を inline。
- `mkSystem`/`mkDownstreamFlake` 間接を畳んで `darwinConfigurations."Yuis-MacBook-Pro"` を直接定義。
- `userConfig(yui)` ハードコード、`secretsFile = ./secrets.yaml`、`personal.nix` を直接 import。

## 落とす (multi-tenant 機構)

- `downstream/` (setup.sh, migrate.sh, migrations/, templates/)
- apps: `setup-downstream`, `test-setup-downstream`, `migrate`
- `mkSystem`/`mkDownstreamFlake` (単一 config に畳む)
- substituter/key: `plural-reality.cachix.org` (※ codelayer/screenpipe 等のバイナリキャッシュを失い初回再ビルドの可能性)
- `nix-darwin-upstream` input + `github:plural-reality` 参照
- `apply`: `flake update upstream` + migrate を除去し `darwin-rebuild switch` のみに簡素化

## 直す (単一tenant 化のついで)

- `claude-code.nix` のハードコード `tkgshn` パス:
  - statusLine `bash /Users/tkgshn/.claude/statusline-command.sh` → yui (現在 yui では壊れている)
  - codex notify `/Users/tkgshn/.codex/notify_macos.sh` → yui or 削除
- codex config の二重定義を解消 (両者が `~/.codex/config.toml` を奪い合っている):
  - upstream `claude-code.nix` `codexDefaults` (python/tomlkit, gpt-5.5, mcp/profiles)
  - downstream `personal.nix` `codexConfig` (grep方式, gpt-5.3-codex, features)
  → yui の実設定 (personal側) を正として一本化。
- onnxruntime overlay の二重定義 → upstream のフル版に一本化。

## 手順 (方針確定後に実行)

1. `/private/etc/nix-darwin` で作業ブランチ作成。
2. upstream から `modules/ lib/ packages/ prompt/ scripts/` を取り込み (personal の purchase-research/gemini-rag と統合)。
3. `flake.nix` を単一tenant形に書き換え、inputs を直接化、lock は upstream の rev を踏襲して pin。
4. plural-reality 参照・downstream機構・cachix を除去、tkgshn/codex/onnxruntime を整理。
5. `darwin-rebuild build --flake .` で現行 generation と差分検証 (switch はしない)。
6. ユーザー確認 → switch → commit → push。
7. `~/Developer` の symlink 整理、plural-reality clone が参照されないことを確認。

## 決定 (2026-05-29)

- 構造: **忠実inline優先** — module分割(base/claude-code/shared-scripts + personal.nix)維持、間接化/パラメータ化のみ除去。
- git履歴: **クリーンに切る** — yuidvg 既存履歴 + 統合commit、plural-reality 履歴は引き継がない。
- 範囲: **ビルドに効く全部** — 現マシンが同一ビルドされる状態を保証。

## 後続タスク (本統合では faithful 維持、別途整理)

- codex config の二重定義 (upstream `codexDefaults` tomlkit / personal `codexConfig` grep) の一本化。
- (保留) plural-reality GitHub repo / cachix 自体の後始末。
